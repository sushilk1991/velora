#!/usr/bin/env python3
"""Qualify local LFM3 artifacts on explicit public inputs; no labels are scored.

Run each artifact separately. Fusion can change outputs; comparison reports that
boundary while requiring byte-identical input data and exact prompt token IDs.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'training/cleanup'))
sys.path.insert(0, str(ROOT / 'engine/src'))
from cleanup.engine_decoder import student_prompt_tokens
from cleanup.lfm3_compat import lfm3_architecture, SOURCE_SHA256
from cleanup.provenance import resolve_model, adapter_hashes, load_local_snapshot

AUDITED_REVISION = '4d6d94c9c2c2f249f1f740f4f08e071b0dbfe099'
DEFAULT_PORT = ROOT / 'docs/research/2026-10-27-lfm3-bakeoff/lfm3.py'
ALLOCATOR_CACHE_LIMIT_BYTES = 512 * 1024 * 1024


def digest(path):
    with Path(path).open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def public_inputs(path):
    rows = []
    for line in Path(path).read_text().splitlines():
        value = json.loads(line)
        if value.get('visibility') != 'public':
            raise ValueError('every fixture must explicitly declare public visibility')
        rows.append({'id': value['id'], 'raw': value['raw'], 'mode': value.get('mode', 'default'),
            'language': value.get('language', 'auto'), 'romanize': value.get('romanize', False),
            'instructions': value.get('instructions', ''), 'vocabulary': value.get('vocabulary', [])})
    ids = [row['id'] for row in rows]
    if not rows or any(not isinstance(i, str) or not i for i in ids) or len(set(ids)) != len(ids):
        raise ValueError('public input IDs must be nonempty and unique')
    return rows


def validate_fused(path, provenance):
    path = Path(path).expanduser().resolve(strict=True)
    provenance = Path(provenance).expanduser().resolve(strict=True)
    if not path.is_dir() or provenance != path / 'export-provenance.json':
        raise ValueError('fused export requires its own export-provenance.json')
    info = json.loads(provenance.read_text())
    files = info.get('output_files_sha256')
    if info.get('status') != 'exported' or info.get('base_revision') != AUDITED_REVISION or info.get('port_sha256') != SOURCE_SHA256:
        raise ValueError('unqualified export provenance')
    if not isinstance(files, dict) or not files or 'config.json' not in files or not any(n.endswith('.safetensors') for n in files):
        raise ValueError('incomplete export file hashes')
    required = {'config.json', 'tokenizer.json', 'tokenizer_config.json'}
    if not required.issubset(files):
        raise ValueError('incomplete export tokenizer assets')
    config = json.loads((path/'config.json').read_text())
    tokenizer_config = json.loads((path/'tokenizer_config.json').read_text())
    if config.get('model_type') != 'lfm3' or config.get('architectures') != ['Lfm3ForCausalLM']:
        raise ValueError('unsupported fused model configuration')
    if not (('chat_template.jinja' in files and (path/'chat_template.jinja').read_text().strip())
            or tokenizer_config.get('chat_template')):
        raise ValueError('missing chat template')
    actual = {p.name for p in path.iterdir() if p.is_file() and p.name != provenance.name}
    if actual != set(files) or any(Path(n).name != n or (path/n).is_symlink() or digest(path/n) != sha for n, sha in files.items()):
        raise ValueError('fused export file hash mismatch')
    return str(path), {'kind':'fused_hf_export', 'files_sha256':files,
        'export_provenance_sha256':digest(provenance), 'source_base_revision':info['base_revision'],
        'source_base_files_sha256':info.get('base_files_sha256'), 'source_adapter_files_sha256':info.get('adapter_files_sha256')}


def capture_stream(responses, clock=time.perf_counter):
    """Capture final non-EOS token even when finish_reason is length."""
    started = clock(); first = None; ids = []; parts = []; status = 'incomplete'
    for response in responses:
        if first is None:
            first = clock()
        if response.finish_reason != 'stop':
            ids.append(int(response.token))
        parts.append(response.text)
        if response.finish_reason in ('stop', 'length'):
            status = 'eos' if response.finish_reason == 'stop' else 'length'
    ended = clock()
    return {'output_token_ids':ids, 'eos':status == 'eos', 'status':status,
        'answer':''.join(parts), 'first_response_s':None if first is None else first-started,
        'after_first_response_s':None if first is None else ended-first, 'total_s':ended-started,
        'output_tokens':len(ids)}


def write_json(path, value):
    with Path(path).open('x') as out:
        json.dump(value, out, ensure_ascii=False, indent=2); out.write('\n')


def run(args):
    if not 1 <= args.max_output <= 1024:
        raise ValueError('max output must be 1..1024')
    rows = public_inputs(args.data)
    if args.output.expanduser().resolve() == args.native_reference.expanduser().resolve():
        raise ValueError('run output and native reference must be different files')
    if args.output.exists() or args.native_reference.exists():
        raise ValueError('output already exists')
    if args.fused:
        if not args.export_provenance or args.base_revision or args.adapter:
            raise ValueError('fused export requires provenance and cannot use base revision or adapter')
        path, identity = validate_fused(args.fused, args.export_provenance)
        adapter = None
    else:
        if args.export_provenance or args.base_revision != AUDITED_REVISION:
            raise ValueError('original base requires audited revision; no export provenance')
        base = args.base.expanduser().absolute()
        if not base.is_dir():
            raise ValueError('local base directory required')
        path, files = resolve_model(str(base), args.base_revision)
        adapter = str(args.adapter.expanduser().resolve(strict=True)) if args.adapter else None
        adapter_files = adapter_hashes(adapter)
        if adapter and (Path(adapter)/'manifest.json').exists():
            manifest = json.loads((Path(adapter)/'manifest.json').read_text())
            if manifest.get('base_revision') != args.base_revision or manifest.get('snapshot_files_sha256') != files:
                raise ValueError('adapter manifest differs from base')
        identity = {'kind':'original_mlx', 'base_revision':args.base_revision,
            'base_files_sha256':files, 'adapter_files_sha256':adapter_files,
            'adapter_manifest_sha256':digest(Path(adapter)/'manifest.json') if adapter and (Path(adapter)/'manifest.json').exists() else None}
    port = args.lfm_port.expanduser().resolve(strict=True)
    source_files = [Path(__file__), ROOT/'training/cleanup/cleanup/__init__.py',
        ROOT/'training/cleanup/cleanup/engine_decoder.py', ROOT/'training/cleanup/cleanup/provenance.py',
        ROOT/'training/cleanup/cleanup/lfm3_compat.py', ROOT/'engine/src/velora_engine/cleanup.py']
    result = {'schema':1, 'data_sha256':digest(args.data), 'artifact':identity,
        'source_sha256':{str(p.relative_to(ROOT)):digest(p) for p in source_files},
        'port_sha256':digest(port), 'max_output':args.max_output, 'python':platform.python_version(),
        'versions':{name:importlib.metadata.version(name) for name in ('mlx','mlx-lm','transformers')},
        'method':'greedy stream_generate; no app watchdog, warmup, labels or quality scoring',
        'timing':'first_response_s measures first stream response, including EOS; it is not visible-text TTFT',
        'mlx_allocator_cache_limit_bytes':ALLOCATOR_CACHE_LIMIT_BYTES, 'records':[]}
    with lfm3_architecture(port):
        import mlx.core as mx
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_sampler
        mx.set_cache_limit(ALLOCATOR_CACHE_LIMIT_BYTES)
        started=time.perf_counter(); model, tokenizer = load_local_snapshot(path, adapter)
        result['model_load_s'] = time.perf_counter()-started
        sampler=make_sampler(temp=0)
        for row in rows:
            context={k:row[k] for k in ('mode','language','romanize','instructions','vocabulary')}
            tokens=student_prompt_tokens(tokenizer, context, row['raw'])
            response=stream_generate(model, tokenizer, prompt=tokens, max_tokens=args.max_output, sampler=sampler)
            try:
                record=capture_stream(response)
            finally:
                response.close()
            record.update(id=row['id'], prompt_token_ids=tokens, input_tokens=len(tokens),
                memory={'mlx_active_bytes':int(mx.get_active_memory()), 'mlx_peak_bytes':int(mx.get_peak_memory()),
                        'mlx_cache_bytes':int(mx.get_cache_memory())})
            result['records'].append(record)
        # Destroy loaded objects while the architecture registration remains active.
        del model, tokenizer
    reference={'rows':[{'id':r['id'],'tokens':r['prompt_token_ids']} for r in result['records']]}
    write_json(args.output, result)
    write_json(args.native_reference, reference)
    print(json.dumps({'cases':len(rows), 'eos':sum(r['eos'] for r in result['records']),
                      'output':str(args.output), 'native_reference':str(args.native_reference)}))


def compare(left, right):
    if left.get('data_sha256') != right.get('data_sha256'):
        raise ValueError('input data hashes differ')
    for key in ('max_output','versions','port_sha256','source_sha256','mlx_allocator_cache_limit_bytes'):
        if left.get(key) != right.get(key) or key not in left or key not in right:
            raise ValueError('qualification runtime provenance differs: '+key)
    if left['mlx_allocator_cache_limit_bytes'] != ALLOCATOR_CACHE_LIMIT_BYTES:
        raise ValueError('unexpected allocator cache limit')
    artifacts=[left.get('artifact', {}), right.get('artifact', {})]
    original=next((x for x in artifacts if x.get('kind') == 'original_mlx'), None)
    fused=next((x for x in artifacts if x.get('kind') == 'fused_hf_export'), None)
    if original is None or fused is None:
        raise ValueError('compare requires one original and one fused artifact')
    if (original.get('base_revision') != fused.get('source_base_revision')
        or not original.get('base_files_sha256')
        or original.get('base_files_sha256') != fused.get('source_base_files_sha256')
        or not original.get('adapter_files_sha256')
        or original.get('adapter_files_sha256') != fused.get('source_adapter_files_sha256')):
        raise ValueError('original and fused artifact lineage differs')
    a=left['records']; b=right['records']
    if not a or len(a)!=len(b) or len({r['id'] for r in a})!=len(a) or len({r['id'] for r in b})!=len(b):
        raise ValueError('case count or IDs differ')
    if any(x['id']!=y['id'] or x['prompt_token_ids']!=y['prompt_token_ids'] for x,y in zip(a,b)):
        raise ValueError('prompt IDs or token IDs differ')
    for record in a+b:
        if record.get('status') not in ('eos','length','incomplete') or not isinstance(record.get('eos'), bool):
            raise ValueError('missing or invalid completion status')
        if record['eos'] != (record['status'] == 'eos'):
            raise ValueError('inconsistent eos and completion status')
    changed=[x['id'] for x,y in zip(a,b) if any(x[k]!=y[k] for k in ('output_token_ids','status','eos','answer'))]
    counts = {side: {status: sum(r['status'] == status for r in records)
                     for status in ('eos','length','incomplete')}
              for side,records in (('left',a),('right',b))}
    incomplete_ids = [x['id'] for x,y in zip(a,b) if x['status'] != 'eos' or y['status'] != 'eos']
    return {'schema':1, 'data_sha256':left['data_sha256'], 'cases':len(a), 'prompt_parity':True,
        'exact_output_parity':not changed and not incomplete_ids, 'changed_output_ids':changed,
        'completion_counts':counts, 'incomplete_case_ids':incomplete_ids,
        'note':'Output differences are allowed across fusion; they require separate quality assessment.'}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    trial=sub.add_parser('run')
    trial.add_argument('--data',type=Path,required=True)
    group=trial.add_mutually_exclusive_group(required=True)
    group.add_argument('--base',type=Path);group.add_argument('--fused',type=Path)
    trial.add_argument('--base-revision');trial.add_argument('--adapter',type=Path)
    trial.add_argument('--export-provenance',type=Path)
    trial.add_argument('--lfm-port',type=Path,default=DEFAULT_PORT)
    trial.add_argument('--output',type=Path,required=True);trial.add_argument('--native-reference',type=Path,required=True)
    trial.add_argument('--max-output',type=int,default=1024)
    comparison=sub.add_parser('compare')
    comparison.add_argument('--left',type=Path,required=True);comparison.add_argument('--right',type=Path,required=True)
    comparison.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if args.command == 'run':run(args)
    else:
        report=compare(json.loads(args.left.read_text()),json.loads(args.right.read_text()))
        report.update(left_sha256=digest(args.left),right_sha256=digest(args.right))
        write_json(args.output,report);print(json.dumps(report))


if __name__=='__main__':main()
