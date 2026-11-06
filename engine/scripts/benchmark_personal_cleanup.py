#!/usr/bin/env python3
"""Offline personal-corpus cleanup replay using Velora's production formatter.

Never opens ground truth, history, or the app socket. This measures batch file
STT plus later cleanup, not live stop-to-paste latency or streaming cleanup.
"""
from __future__ import annotations
import argparse
import asyncio
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import resource
import re
import shutil
import sys
import time

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'engine' / 'src'))
sys.path.insert(0, str(REPO / 'engine' / 'scripts'))
from benchmark_personal_recordings import digest, private_dir, private_write
from benchmark_resources import loaded_model_memory, write_end_resources


def hash_tree(path):
    path = path.resolve(strict=True)
    if path.is_file():
        return digest(path)
    h = hashlib.sha256()
    for file in sorted(path.rglob('*')):
        if file.is_symlink():
            # Model snapshots commonly contain symlinks into local cache blobs.
            if file.is_file():
                pass
            else:
                raise ValueError('invalid or directory symlink in hashed tree')
        if file.is_file():
            h.update(str(file.relative_to(path)).encode() + b'\0')
            h.update(bytes.fromhex(digest(file)))
    return h.hexdigest()


def snapshot_config(source, dest):
    """Copy only formatter inputs; Config migrations operate on the copy."""
    source = source.expanduser().resolve(strict=True)
    dest.mkdir(mode=0o700)
    for name in ('config.json', 'learned.json', 'auto_learned.json'):
        path = source / name
        if path.is_symlink():
            raise ValueError('symlinked config input is not supported')
        if path.is_file():
            shutil.copyfile(path, dest / name)
            os.chmod(dest / name, 0o600)
    modes = source / 'modes'
    if modes.is_symlink():
        raise ValueError('symlinked modes directory is not supported')
    if modes.is_dir():
        target = dest / 'modes'
        target.mkdir(mode=0o700)
        for path in sorted(modes.glob('*.json')):
            if path.is_symlink():
                raise ValueError('symlinked mode is not supported')
            shutil.copyfile(path, target / path.name)
            os.chmod(target / path.name, 0o600)


def read_inputs(manifest_path, stt_path):
    manifest = json.loads(manifest_path.read_text())
    cases = manifest['cases']
    ids = [case['id'] for case in cases]
    if len(set(ids)) != len(ids):
        raise ValueError('duplicate manifest id')
    results = {}
    for line in stt_path.read_text().splitlines():
        result = json.loads(line)
        if result['id'] in results:
            raise ValueError('duplicate STT id')
        results[result['id']] = result
    if set(ids) != set(results):
        raise ValueError('STT output must contain every frozen case exactly once')
    for case in cases:
        result = results[case['id']]
        if result.get('input_sha256') != case.get('input_sha256'):
            raise ValueError('STT input hash differs from manifest')
    return cases, results


def validate_stt_provenance(manifest_path,stt_path,metadata_path,config=None):
    """Require the production-global-glossary turbo replay for comparisons."""
    manifest_path=Path(manifest_path).resolve(strict=True)
    stt_path=Path(stt_path).resolve(strict=True)
    metadata_path=Path(metadata_path).resolve(strict=True)
    if metadata_path.parent!=stt_path.parent or stt_path.name!='stt.jsonl' or metadata_path.name!='stt-run.json':
        raise ValueError('STT metadata and results must be the original paired stt-run.json/stt.jsonl files')
    info=json.loads(metadata_path.read_text())
    if info.get('manifest_sha256')!=digest(manifest_path) or info.get('model')!='mlx-community/whisper-large-v3-turbo':
        raise ValueError('STT metadata differs from the frozen manifest or production turbo model')
    def hashes(value):
        return isinstance(value,dict) and bool(value) and all(isinstance(key,str) and key and isinstance(sha,str) and re.fullmatch('[0-9a-f]{64}',sha) for key,sha in value.items())
    if not hashes(info.get('model_files_sha256')):
        raise ValueError('STT metadata requires nonempty model_files_sha256 provenance')
    glossary=info.get('glossary')
    if (not isinstance(glossary,dict) or glossary.get('mode')!='production global glossary; no historical screen entities'
            or not isinstance(glossary.get('sha256'),str) or not re.fullmatch('[0-9a-f]{64}',glossary['sha256'])
            or not hashes(glossary.get('source_sha256'))):
        raise ValueError('STT metadata requires the explicit production glossary and source-config hashes')
    if config is not None:
        from velora_engine.stt import build_glossary_prompt
        expected=build_glossary_prompt(config.user_vocabulary,config.learned_vocabulary,config.auto_vocabulary,[])
        if hashlib.sha256((expected or '').encode()).hexdigest()!=glossary['sha256']:
            raise ValueError('STT glossary SHA256 differs from the frozen cleanup config')
    return info


class InstrumentedCleanup:
    """Adapt CleanupEngine to the server proxy's interface, collecting metrics."""
    def __init__(self, engine, trace=False):
        self.engine = engine
        self.trace = trace
        self.calls = []

    @property
    def loaded(self):
        return self.engine.loaded

    @property
    def unhealthy(self):
        return self.engine.unhealthy

    async def cleanup(self, raw, system_prompt, **kwargs):
        kwargs.pop('queue_timeout_s', None)  # proxy-only argument
        result = await self.engine.cleanup(raw, system_prompt, **kwargs)
        metrics = asdict(result)
        metrics.pop('text', None)
        if not self.trace:
            metrics.pop('_latency_ns', None)
            metrics.pop('_work_counts', None)
        metrics['system_prompt_sha256'] = hashlib.sha256(system_prompt.encode()).hexdigest()
        prefixes = kwargs.get('prefix_candidates') or []
        metrics['prefix_candidates_sha256'] = hashlib.sha256(
            json.dumps(prefixes, ensure_ascii=False).encode()).hexdigest()
        # The public CleanupResult does not reveal whether an accepted response
        # ended at EOS. A rejected token cap is explicitly reason='length'.
        metrics['eos'] = 'not_exposed'
        self.calls.append(metrics)
        return result


def make_server(config, cleanup):
    # Use the actual production formatting and long-piece logic, but never
    # initialize Engine's socket, history, STT, action, or background workers.
    from velora_engine.server import Engine
    server = Engine.__new__(Engine)
    server.config = config
    server.cleanup = cleanup
    async def ready(_cancel):
        return cleanup.loaded
    async def warmup(*args, **kwargs):
        return None
    server._ensure_cleanup_loaded = ready
    server._finish_cleanup_warmup = warmup
    return server


def source_fingerprint():
    h = hashlib.sha256()
    paths = [Path(__file__), REPO/'engine/scripts/benchmark_resources.py', REPO/'engine/src/velora_engine/server.py',
             REPO/'engine/src/velora_engine/formatting.py',
             REPO/'engine/src/velora_engine/cleanup.py',
             REPO/'engine/src/velora_engine/config.py']
    for path in paths:
        h.update(path.name.encode() + bytes.fromhex(digest(path)))
    h.update(bytes.fromhex(hash_tree(REPO/'engine/src/velora_engine/modes_builtin')))
    return h.hexdigest()


async def replay(manifest_path, stt_path, output, config_home, model, model_path,
                 copy_draft_tokens=3, limit=None, trace=False, stt_meta_path=None):
    if copy_draft_tokens not in (2, 3, 4, 6, 8):
        raise ValueError('unsupported draft token count')
    if limit is not None and limit <= 0:
        raise ValueError('limit must be positive')
    if trace:
        os.environ['VELORA_TRACE_CLEANUP'] = '1'
    else:
        os.environ.pop('VELORA_TRACE_CLEANUP', None)
    from velora_engine import cleanup as cleanup_module
    cleanup_module.COPY_DRAFT_PASS_TOKENS = copy_draft_tokens
    CleanupEngine = cleanup_module.CleanupEngine
    from velora_engine.config import Config
    from velora_engine.formatting import STATIC_SYSTEM_PROMPT
    manifest_path = manifest_path.expanduser().resolve(strict=True)
    stt_path = stt_path.expanduser().resolve(strict=True)
    stt_info=validate_stt_provenance(manifest_path,stt_path,stt_meta_path) if stt_meta_path is not None else None
    model_path = model_path.expanduser().resolve(strict=True)
    if not model_path.is_dir():
        raise ValueError('cleanup model path must be a local directory')
    cases, stt = read_inputs(manifest_path, stt_path)
    if limit is not None:
        cases = cases[:limit]
    subset_sha256 = hashlib.sha256(json.dumps([case['id'] for case in cases], separators=(',', ':')).encode()).hexdigest()
    output = private_dir(output)
    snapshot = output / 'config-snapshot'
    metadata_path = output / 'cleanup-run.json'
    if not metadata_path.exists():
        if snapshot.exists():
            raise ValueError('incomplete setup: choose a new output directory')
        snapshot_config(config_home, snapshot)
        config = Config(snapshot)  # migrations affect snapshot only
        if stt_meta_path is not None:validate_stt_provenance(manifest_path,stt_path,stt_meta_path,config)
        for file in snapshot.rglob('*'):
            if file.is_file():
                os.chmod(file, 0o600)
            elif file.is_dir():
                os.chmod(file, 0o700)
        meta = {'schema': 1, 'manifest_sha256': digest(manifest_path),
                'stt_metadata_sha256':digest(Path(stt_meta_path)) if stt_meta_path is not None else None,
                'stt_glossary_sha256':stt_info['glossary']['sha256'] if stt_info else None,
                'stt_sha256': digest(stt_path), 'snapshot_sha256': hash_tree(snapshot),
                'model': model, 'model_path': str(model_path),
                'mlx_allocator_cache_limit_bytes':cleanup_module.ALLOCATOR_CACHE_LIMITS.get(model),
                'copy_draft_tokens': copy_draft_tokens, 'trace': trace,
                'limit': limit, 'case_count': len(cases), 'case_ids_sha256': subset_sha256,
                'model_sha256': hash_tree(model_path), 'source_sha256': source_fingerprint(),
                'backend': 'production CleanupEngine and Engine._apply_formatting',
                'context': 'history mode, bundle and app; no entities; copied current config',
                'timing': 'paired offline STT and later cleanup; excludes live capture and paste'}
        private_write(metadata_path, meta)
    else:
        meta = json.loads(metadata_path.read_text())
        current = {'manifest_sha256': digest(manifest_path), 'stt_sha256': digest(stt_path),
                   'stt_metadata_sha256':digest(Path(stt_meta_path)) if stt_meta_path is not None else None,
                   'stt_glossary_sha256':stt_info['glossary']['sha256'] if stt_info else None,
                   'snapshot_sha256': hash_tree(snapshot), 'model': model,
                   'model_path': str(model_path), 'model_sha256': hash_tree(model_path),
                   'source_sha256': source_fingerprint(),
                   'mlx_allocator_cache_limit_bytes':cleanup_module.ALLOCATOR_CACHE_LIMITS.get(model),
                   'copy_draft_tokens': copy_draft_tokens, 'trace': trace,
                   'limit': limit, 'case_count': len(cases), 'case_ids_sha256': subset_sha256}
        if any(meta.get(k) != v for k, v in current.items()):
            raise ValueError('run provenance changed; use a new output directory')
        config = Config(snapshot)
        if hash_tree(snapshot) != meta['snapshot_sha256']:
            raise ValueError('configuration snapshot changed during load')
        if stt_meta_path is not None:validate_stt_provenance(manifest_path,stt_path,stt_meta_path,config)
    case_dir = output / 'cases'
    case_dir.mkdir(mode=0o700, exist_ok=True)
    os.chmod(case_dir, 0o700)
    engine = CleanupEngine(model, local_model_path=model_path)
    started = time.perf_counter()
    await engine.load_async(STATIC_SYSTEM_PROMPT)
    load_s = time.perf_counter() - started
    instrumented = InstrumentedCleanup(engine, trace=trace)
    server = make_server(config, instrumented)
    try:
        for case in cases:
            case_id = case['id']
            # Filename is independent of arbitrary manifest data.
            name = hashlib.sha256(str(case_id).encode()).hexdigest() + '.json'
            dest = case_dir / name
            if dest.exists():
                existing = json.loads(dest.read_text())
                if existing.get('id') != case_id or existing.get('input_sha256') != case.get('input_sha256'):
                    raise ValueError('existing case result mismatch')
                continue
            source = stt[case_id]
            record = {'id': case_id, 'input_sha256': case.get('input_sha256'),
                      'status': 'stt_failed', 'stt_s': source.get('stt_s'),
                      'audio_read_s': source.get('audio_read_s'), 'stt_total_s': source.get('total_s'),
                      'cleanup_s': None, 'paired_stt_cleanup_s': None,
                      'paired_replay_total_s': None, 'calls': []}
            if source.get('status') == 'ok' and isinstance(source.get('raw'), str):
                instrumented.calls = []
                begin = time.perf_counter()
                try:
                    text, mode, infer_ms, applied, reason = await server._apply_formatting(
                        source['raw'], case.get('bundle_id'), case.get('app_name'), case.get('mode'))
                    status = 'cleanup_fallback' if instrumented.calls and not applied else 'ok'
                    record.update(status=status, text=text, mode=mode, cleanup_model_ms=infer_ms,
                                  cleanup_applied=applied, cleanup_reason=reason)
                except Exception as exc:
                    record.update(status='cleanup_failed', error_type=type(exc).__name__)
                record['cleanup_s'] = time.perf_counter() - begin
                record['calls'] = instrumented.calls
                if isinstance(record['stt_s'], (int, float)):
                    record['paired_stt_cleanup_s'] = record['stt_s'] + record['cleanup_s']
                if isinstance(record['stt_total_s'], (int, float)):
                    record['paired_replay_total_s'] = record['stt_total_s'] + record['cleanup_s']
            record['peak_rss_native'] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
            record['mlx_memory'] = loaded_model_memory(engine)
            # Atomic publish: a killed run cannot leave a half-written case.
            temp = dest.with_suffix('.tmp')
            if temp.exists():
                temp.unlink()
            private_write(temp, record)
            os.replace(temp, dest)
    finally:
        try:
            if not getattr(engine,'unhealthy',False):
                write_end_resources(output,engine,private_write)
        finally:
            engine.close()
    all_results = [json.loads(p.read_text()) for p in case_dir.glob('*.json')]
    ok = sum(r['status'] == 'ok' for r in all_results)
    print(json.dumps({'output': str(case_dir), 'total_cases': len(cases),
                      'completed': len(all_results), 'ok': ok,
                      'failed': len(all_results)-ok,
                      'cleanup_fallback': sum(r['status'] == 'cleanup_fallback' for r in all_results),
                      'length_limit_calls': sum(c.get('reason') == 'length' for r in all_results for c in r['calls']),
                      'model_load_s': load_s}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--stt', required=True, type=Path)
    parser.add_argument('--stt-meta', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--config-home', type=Path, default=Path.home()/'.velora')
    parser.add_argument('--model', required=True)
    parser.add_argument('--model-path', required=True, type=Path)
    parser.add_argument('--copy-draft-tokens', type=int, choices=(2, 3, 4, 6, 8), default=3)
    parser.add_argument('--limit', type=int, help='smoke test only: first N frozen cases')
    parser.add_argument('--trace', action='store_true', help='retain private cleanup trace metrics')
    args = parser.parse_args()
    asyncio.run(replay(args.manifest, args.stt, args.output, args.config_home, args.model, args.model_path,
                       args.copy_draft_tokens, args.limit, args.trace,args.stt_meta))

if __name__ == '__main__':
    main()
