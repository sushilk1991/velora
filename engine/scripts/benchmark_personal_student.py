#!/usr/bin/env python3
"""Offline production-gate replay using a <=2B student and its training prompt.

Private output only. Does not open gold, history, sockets or live input. This
uses the short student JSON renderer, not the production 4B model prompt.
"""
from __future__ import annotations
import argparse
import asyncio
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import resource
import sys
import time

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'engine' / 'src'))
sys.path.insert(0, str(REPO / 'training' / 'cleanup'))
from cleanup import SYSTEM_PROMPT
from cleanup.engine_decoder import StudentEngine, student_prompt, student_prompt_tokens, experimental_copy_draft_tokens
from cleanup.provenance import resolve_model, adapter_hashes, load_local_snapshot
from cleanup.lfm3_compat import lfm3_architecture
from cleanup.cache_compat import experimental_cache_api
from benchmark_personal_cleanup import (digest, private_dir, private_write, hash_tree,
    snapshot_config, read_inputs, make_server, InstrumentedCleanup, source_fingerprint, validate_stt_provenance)
from benchmark_resources import (STUDENT_CACHE_LIMIT_BYTES, configure_student_allocator,
    loaded_model_memory, write_end_resources)
from velora_engine import formatting
from velora_engine.cleanup import CleanupResult, check_divergence, restore_control_tokens

# Deliberately restricted to the previously audited <=2B snapshots; adding a
# model requires independent parameter-count and snapshot review.
AUDITED_REVISIONS = {
    '93760be4f1f69842a46bc13dbdc0f19e291392a3': 'qwen3_5',
    '562fb8ea19bbe7565a3ddf5b7d49899ea2c88d2b': 'qwen3_5',
    'ee7667f3cfccb2a41725f91820531823fcabc6b7': 'lfm3',
    '4d6d94c9c2c2f249f1f740f4f08e071b0dbfe099': 'lfm3',
}


def local_snapshot(path, revision):
    if revision not in AUDITED_REVISIONS:
        raise ValueError('snapshot revision is not an audited <=2B student')
    path = Path(path).expanduser().absolute()
    if not path.is_dir():
        raise ValueError('base must be an existing local snapshot; network is disabled')
    snapshot, hashes = resolve_model(str(path), revision)
    config = json.loads((Path(snapshot) / 'config.json').read_text())
    if config.get('model_type') != AUDITED_REVISIONS[revision]:
        raise ValueError('snapshot model type does not match audited revision')
    return snapshot, hashes


def controls(config, raw, case):
    gate = formatting.run_gate(raw, config, bundle_id=case.get('bundle_id'),
        app_name=case.get('app_name'), explicit_mode=case.get('mode'))
    instructions = []
    # The short training renderer does not automatically know strength or the
    # production terminal overlay, so pass those explicitly as instructions.
    if not gate.romanize:
        instructions.append(formatting._STRENGTH_INSTRUCTIONS.get(
            gate.mode.formatting, formatting._STRENGTH_INSTRUCTIONS['full']))
    if not config.auto_punctuation:
        instructions.append('Do not add terminal punctuation the speaker did not dictate.')
    if gate.reason == 'smart_terminal':
        instructions.append(formatting.SMART_TERMINAL_PROMPT)
    contextual = []
    formatting._append_contextual_prompt_parts(
        contextual, gate.mode, config, case.get('app_name'), gate.category, None)
    # Vocabulary has its own structured field; preserve app, mode and soft
    # correction context using the production formatter's own wording.
    instructions.extend(x for x in contextual if not x.startswith('Vocabulary —'))
    return gate, {'mode': gate.mode.name.lower(), 'language': config.language,
        'romanize': gate.romanize, 'instructions': '\n\n'.join(instructions),
        'vocabulary': list(dict.fromkeys(config.global_vocabulary + gate.mode.vocabulary))}


class StudentCleanup:
    """CleanupEngine-compatible wrapper around greedy short-renderer inference."""
    def __init__(self, model, tokenizer, stream, sampler, max_output=1024, max_input=4096,
                 *, memory_provider=None):
        if not 1 <= max_output <= 1024 or max_input < 1:
            raise ValueError('invalid inference caps')
        self.model, self.tokenizer, self.stream, self.sampler = model, tokenizer, stream, sampler
        self.max_output, self.max_input = max_output, max_input
        self.context = None
        self.loaded = True
        self.unhealthy = False
        self.memory_provider = memory_provider

    def set_context(self, gate, context):
        self.context = (gate.system_prompt, dict(context))

    async def cleanup(self, raw, system_prompt, **kwargs):
        if self.context is None:
            raise RuntimeError('per-case context is required')
        base, ctx = self.context
        if not base or not system_prompt.startswith(base):
            raise ValueError('production prompt does not match current gate')
        # The server appends bounded previous-piece context verbatim. Preserve
        # it as task context, without parsing the production prompt itself.
        suffix = system_prompt[len(base):]
        ctx = dict(ctx)
        prompt = student_prompt(self.tokenizer, ctx, raw, suffix)
        input_tokens = len(student_prompt_tokens(self.tokenizer, ctx, raw, suffix))
        raw_tokens = len(self.tokenizer.encode(raw))
        check_ratio = kwargs.get('check_ratio', True)
        cap = min(self.max_output, max(96, int(raw_tokens * (1.8 if check_ratio else 3.0))))
        t0 = time.perf_counter()
        def result(text, applied, reason, out=0):
            memory = loaded_model_memory(self)
            return CleanupResult(text, applied, int((time.perf_counter()-t0)*1000),
                reason, input_tokens=input_tokens, output_tokens=out,
                **{key:value for key,value in memory.items() if key.startswith('mlx_')})
        if input_tokens > self.max_input:
            return result(raw, False, 'context_limit')
        timeout = kwargs.get('timeout_ms', 30000) / 1000
        cancel = kwargs.get('cancel_event')
        parts, last, count = [], None, 0
        try:
            for response in self.stream(self.model, self.tokenizer, prompt=prompt,
                                        max_tokens=cap, sampler=self.sampler):
                count = getattr(response, 'generation_tokens', len(parts) + 1)
                if cancel is not None and cancel.is_set():
                    return result(raw, False, 'cancelled', count)
                if time.perf_counter()-t0 > timeout:
                    return result(raw, False, 'timeout', count)
                parts.append(response.text)
                last = response
        except Exception:
            return result(raw, False, 'generation_error', count)
        if last is None:
            return result(raw, False, 'empty_generation')
        count = getattr(last, 'generation_tokens', len(parts))
        if last.finish_reason != 'stop':
            return result(raw, False, 'length' if last.finish_reason == 'length' else 'generation_incomplete', count)
        text = restore_control_tokens(''.join(parts))
        reason = check_divergence(raw, text, kwargs.get('allowed_terms')) if check_ratio else ('empty_output' if not text.strip() else None)
        return result(raw if reason else text.strip(), not bool(reason), reason, count)


def verify_resume(meta, expected):
    if any(meta.get(k) != v for k, v in expected.items()):
        raise ValueError('run provenance changed; use a new output directory')


def cleanup_status(calls, applied, reason):
    """Retain mixed successful/fallback pieces as partial cleanup."""
    # A failed seam attempt can be retried successfully. The server's final
    # piece-level result is authoritative; failed attempts remain in calls.
    if reason == 'partial_cleanup':
        return 'cleanup_partial'
    if calls and not applied:
        return 'cleanup_fallback'
    return 'ok'


def source_hash():
    h = hashlib.sha256(bytes.fromhex(source_fingerprint()))
    for p in [Path(__file__), *sorted((REPO/'training/cleanup/cleanup').glob('*.py'))]:
        h.update(p.name.encode() + bytes.fromhex(digest(p)))
    return h.hexdigest()


async def replay(args):
    from velora_engine.config import Config
    if not 1 <= args.max_output <= 1024 or args.max_input < 1:
        raise ValueError('invalid inference caps')
    manifest = args.manifest.expanduser().resolve(strict=True)
    stt_path = args.stt.expanduser().resolve(strict=True)
    stt_meta_path = args.stt_meta.expanduser().resolve(strict=True)
    stt_meta=validate_stt_provenance(manifest,stt_path,stt_meta_path)
    cases, stt = read_inputs(manifest, stt_path)
    if args.limit is not None:
        if args.limit <= 0: raise ValueError('limit must be positive')
        cases = cases[:args.limit]
    snapshot, files = local_snapshot(args.base, args.base_revision)
    adapter = str(args.adapter.expanduser().resolve(strict=True)) if args.adapter else None
    adapter_files = adapter_hashes(adapter)
    adapter_manifest_sha256 = None
    if adapter:
        manifest_file = Path(adapter)/'manifest.json'
        if manifest_file.exists():
            adapter_manifest_sha256 = digest(manifest_file)
            adapter_manifest = json.loads(manifest_file.read_text())
            if adapter_manifest.get('base_revision') != args.base_revision or adapter_manifest.get('snapshot_files_sha256') != files:
                raise ValueError('adapter training manifest does not match base snapshot')
    qualification_sha256 = None
    if args.decoder != 'stream':
        if not args.qualification:
            raise ValueError('engine decoders require a successful public parity qualification')
        qualification_path = args.qualification.expanduser().resolve(strict=True)
        q = json.loads(qualification_path.read_text())
        expected_qualification = {'parity':True,'all_cases_eos':True,'unique_case_ids':True,'recovery_probe':'context_limit','cases':64,
            'copy_draft_tokens':args.copy_draft_tokens,
            'mlx_allocator_cache_limit_bytes':STUDENT_CACHE_LIMIT_BYTES,
            'base_revision':args.base_revision,'base_files_sha256':files,'adapter_sha256':adapter_files,
            'max_input':args.max_input,'max_output':args.max_output,'source_sha256':source_hash(),
            'runner_sha256':digest(REPO/'training/cleanup/scripts/benchmark_student_decoder.py'),
            'trace_enabled':True,
            'versions':{name:importlib.metadata.version(name) for name in ('mlx','mlx-lm','transformers')},
            'lfm_port_sha256':digest(args.lfm_port.resolve(strict=True)) if args.lfm_port else None}
        if any(q.get(k)!=v for k,v in expected_qualification.items()) or args.decoder not in q.get('decoders',[]) or 'stream' not in q.get('decoders',[]):
            raise ValueError('public parity qualification does not match this decoder and artifacts')
        qualification_sha256=digest(qualification_path)
    output = private_dir(args.output)
    config_snapshot = output/'config-snapshot'
    metadata_path = output/'student-run.json'
    versions = {name:importlib.metadata.version(name) for name in ('mlx','mlx-lm','transformers')}
    case_ids_hash = hashlib.sha256(json.dumps([x['id'] for x in cases], separators=(',',':')).encode()).hexdigest()
    expected = {'schema':1, 'manifest_sha256':digest(manifest), 'stt_sha256':digest(stt_path), 'stt_metadata_sha256':digest(stt_meta_path),
        'stt_glossary_sha256':stt_meta['glossary']['sha256'],
        'base':snapshot, 'base_revision':args.base_revision, 'base_files_sha256':files,
        'adapter':adapter, 'adapter_sha256':adapter_files, 'adapter_manifest_sha256':adapter_manifest_sha256, 'source_sha256':source_hash(),
        'lfm_port_sha256':digest(args.lfm_port.resolve(strict=True)) if args.lfm_port else None,
        'max_output_tokens':args.max_output, 'max_input_tokens':args.max_input, 'limit':args.limit,
        'copy_draft_tokens':args.copy_draft_tokens,
        'mlx_allocator_cache_limit_bytes':STUDENT_CACHE_LIMIT_BYTES,
        'case_count':len(cases), 'case_ids_sha256':case_ids_hash, 'versions':versions, 'decoder':args.decoder, 'qualification_sha256':qualification_sha256,
        'python':platform.python_version(), 'temperature':0}
    if not metadata_path.exists():
        if config_snapshot.exists(): raise ValueError('incomplete setup; use a new output directory')
        snapshot_config(args.config_home, config_snapshot)
        config = Config(config_snapshot)
        validate_stt_provenance(manifest,stt_path,stt_meta_path,config)
        for file in config_snapshot.rglob('*'):
            os.chmod(file, 0o700 if file.is_dir() else 0o600)
        expected['snapshot_sha256'] = hash_tree(config_snapshot)
        meta = {**expected, 'backend':'production formatting gate and postprocess; MLX-LM student short JSON renderer',
            'prompt_difference':'student training system prompt and structured controls, not production 4B system prompt',
            'student_system_prompt':SYSTEM_PROMPT, 'prompt_contract':'short training JSON with production control-token neutralization; differs from unneutralized training evaluation for control-token text', 'timing':'offline batch STT and later cleanup; excludes capture and paste',
            'timeout':('cooperative between tokens; not a hard watchdog' if args.decoder == 'stream' else 'production watchdog; unhealthy process exits'),
            'deadline_policy':('soft budget includes prefill' if args.decoder == 'stream' else 'soft budget starts at first output; independent worker watchdog includes prefill'),
            'deadline_comparison_caveat':'Stream and engine use different soft-timeout origins. Compare timeout/fallback reasons separately from model-quality changes.',
            'context':'frozen copied config, manifest mode and app; no entities; long-piece suffix preserved; student training did not specifically cover appended previous-piece context'}
        private_write(metadata_path, meta)
    else:
        expected['snapshot_sha256'] = hash_tree(config_snapshot)
        verify_resume(json.loads(metadata_path.read_text()), expected)
        config = Config(config_snapshot)
        if hash_tree(config_snapshot) != expected['snapshot_sha256']:
            raise ValueError('config snapshot changed during load')
        validate_stt_provenance(manifest,stt_path,stt_meta_path,config)
    case_dir=output/'cases';case_dir.mkdir(mode=0o700,exist_ok=True);os.chmod(case_dir,0o700)
    expected_names={hashlib.sha256(str(case['id']).encode()).hexdigest()+'.json' for case in cases}
    if any(path.name not in expected_names or path.is_symlink() for path in case_dir.glob('*.json')):
        raise ValueError('unexpected or unsafe case result in output directory')
    with lfm3_architecture(args.lfm_port), experimental_cache_api(), experimental_copy_draft_tokens(args.copy_draft_tokens):
        configure_student_allocator()
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_sampler
        start=time.perf_counter()
        if args.decoder == 'stream':
            model, tokenizer=load_local_snapshot(snapshot, adapter)
            student=StudentCleanup(model,tokenizer,stream_generate,make_sampler(temp=0),args.max_output,args.max_input)
        else:
            student=StudentEngine('student-'+args.base_revision,snapshot,adapter,
                copy_draft=args.decoder=='engine-copy',max_input=args.max_input,max_output=args.max_output)
            # No warmup before a case context exists; the first request installs
            # an exact student-specific prefix while processing the request.
            await student.load_async(None)
        load_s=time.perf_counter()-start
        instrumented=InstrumentedCleanup(student)
        server=make_server(config,instrumented)
        for case in cases:
            cid=case['id'];dest=case_dir/(hashlib.sha256(str(cid).encode()).hexdigest()+'.json')
            if dest.exists():
                existing=json.loads(dest.read_text())
                if existing.get('id')!=cid or existing.get('input_sha256')!=case.get('input_sha256'):
                    raise ValueError('existing case result mismatch')
                continue
            source=stt[cid]
            rec={'id':cid,'input_sha256':case.get('input_sha256'),'status':'stt_failed',
                'stt_s':source.get('stt_s'),'audio_read_s':source.get('audio_read_s'),
                'stt_total_s':source.get('total_s'),'cleanup_s':None,'paired_stt_cleanup_s':None,
                'paired_replay_total_s':None,'calls':[]}
            if source.get('status')=='ok' and isinstance(source.get('raw'),str):
                instrumented.calls=[]; start=time.perf_counter()
                try:
                    gate,ctx=controls(config,source['raw'],case);student.set_context(gate,ctx)
                    text,mode,ms,applied,reason=await server._apply_formatting(source['raw'],case.get('bundle_id'),case.get('app_name'),case.get('mode'))
                    status = cleanup_status(instrumented.calls, applied, reason)
                    rec.update(status=status,
                        text=text,mode=mode,cleanup_model_ms=ms,cleanup_applied=applied,cleanup_reason=reason)
                except Exception as exc:
                    rec.update(status='cleanup_failed',error_type=type(exc).__name__)
                rec['cleanup_s']=time.perf_counter()-start;rec['calls']=instrumented.calls
                if isinstance(rec['stt_s'],(float,int)):rec['paired_stt_cleanup_s']=rec['stt_s']+rec['cleanup_s']
                if isinstance(rec['stt_total_s'],(float,int)):rec['paired_replay_total_s']=rec['stt_total_s']+rec['cleanup_s']
            rec['peak_rss_native']=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
            rec['mlx_memory']=loaded_model_memory(student)
            temp=dest.with_suffix('.tmp')
            if temp.exists():temp.unlink()
            private_write(temp,rec);os.replace(temp,dest)
            if student.unhealthy:
                # A wedged model thread must not outlive its LFM registration or
                # consume another case's context; the caller can resume safely.
                os._exit(70)
        try:
            write_end_resources(output,student,private_write)
        finally:
            if args.decoder != 'stream':
                student.close()
    all_results=[json.loads(p.read_text()) for p in case_dir.glob('*.json')]
    print(json.dumps({'output':str(case_dir),'total_cases':len(cases),'completed':len(all_results),
        'ok':sum(x['status']=='ok' for x in all_results),'failed':sum(x['status']!='ok' for x in all_results),
        'length_limit_calls':sum(c.get('reason')=='length' for x in all_results for c in x['calls']), 'model_load_s':load_s}))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for flag in ('manifest','stt','stt-meta','output','base'):p.add_argument('--'+flag,type=Path,required=True)
    p.add_argument('--config-home',type=Path,default=Path.home()/'.velora')
    p.add_argument('--base-revision',required=True);p.add_argument('--adapter',type=Path)
    p.add_argument('--lfm-port',type=Path);p.add_argument('--limit',type=int)
    p.add_argument('--decoder',choices=('stream','engine','engine-copy'),default='stream')
    p.add_argument('--qualification',type=Path,help='successful public compare report, required for engine decoders')
    p.add_argument('--max-output',type=int,default=1024);p.add_argument('--max-input',type=int,default=4096)
    p.add_argument('--copy-draft-tokens',type=int,choices=(3,4,6,8),default=3)
    args=p.parse_args();asyncio.run(replay(args))
if __name__=='__main__':main()
