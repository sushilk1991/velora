#!/usr/bin/env python3
"""Offline local Whisper/Parakeet corpus benchmark. Explicit invocation only.

No download or quantization cache. Output remains private and contains raw STT.
Timing and the small selected VCTK corpus are not general quality claims.
"""
from __future__ import annotations
import argparse
import importlib
import importlib.util
from importlib import metadata
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import struct
from collections import Counter
import sys
import time

import benchmark_english_accents as common

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'engine/src'))


def package_sources(package):
    spec = importlib.util.find_spec(package)
    if spec is None or not spec.submodule_search_locations:
        raise ValueError(f'{package} unavailable')
    files = sorted(p for p in Path(next(iter(spec.submodule_search_locations))).rglob('*')
                   if p.is_file() and p.suffix in ('.py', '.so', '.dylib'))
    if not files: raise ValueError(f'{package} has no Python sources')
    return files


def snapshot(model_path):
    model = model_path.expanduser().resolve(strict=True)
    if not model.is_dir() or model.parent.name != 'snapshots' or not re.fullmatch(r'[0-9a-f]{40}', model.name):
        raise ValueError('model must be an explicit local snapshots/<40-hex-revision> directory')
    config = json.loads((model / 'config.json').read_text())
    if not (model / 'model.safetensors').is_file() and not list(model.glob('*.safetensors')):
        raise ValueError('snapshot must contain local safetensors weights')
    return model, config


def weight_inventory(model):
    inventory = {}
    for path in sorted(model.glob('*.safetensors')):
        with path.open('rb') as f:
            header_length = struct.unpack('<Q', f.read(8))[0]
            if header_length > 100_000_000: raise ValueError('unreasonable safetensors header')
            header = json.loads(f.read(header_length))
        tensors = {k:v for k,v in header.items() if k != '__metadata__'}
        inventory[path.name] = {'tensor_dtypes': dict(Counter(v['dtype'] for v in tensors.values())),
                                'quantization_named_tensors': [k for k in tensors if k.endswith(('.scales', '.biases'))]}
    return inventory


def identities(model, ffmpeg, backend):
    package = 'parakeet_mlx' if backend == 'parakeet' else 'mlx_whisper'
    extra = [Path(__file__), *package_sources(package), *package_sources('mlx'), *package_sources('numpy')]
    return common.files_identity(model, ffmpeg, extra)


def _deny(*args, **kwargs):
    raise RuntimeError('benchmark forbids remote downloads')


def load_backend(kind, model_id, model):
    import mlx.core as mx
    from velora_engine.stt import ParakeetBackend, WhisperBackend, transcribe_clip
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    if kind == 'parakeet':
        import parakeet_mlx
        import parakeet_mlx.utils as utils
        # from_pretrained attempts hub first, catches failure, and reads local files.
        utils.hf_hub_download = _deny
        backend = ParakeetBackend(model_id)
        backend._model = parakeet_mlx.from_pretrained(str(model))
        mx.eval(backend._model.parameters())
    else:
        loader = importlib.import_module('mlx_whisper.load_models')
        loader.snapshot_download = _deny
        from mlx_whisper.transcribe import ModelHolder
        backend = WhisperBackend(model_id, language='en')
        backend._model_path = str(model)
        backend.initial_prompt = None
        weights = ModelHolder.get_model(str(model), mx.float16)
        mx.eval(weights.parameters())
        backend._loaded = True
    return backend, transcribe_clip, mx


def preprocess(ffmpeg, audio_path):
    import numpy as np
    pcm = subprocess.run([ffmpeg, '-v', 'error', '-nostdin', '-i', str(audio_path),
                          '-ac', '1', '-ar', '16000', '-f', 'f32le', '-'],
                         check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
    audio = np.frombuffer(pcm, dtype='<f4').copy()
    if not len(audio) or not np.isfinite(audio).all(): raise ValueError('empty or invalid PCM')
    return audio


def memory_snapshot(mx):
    result = {'peak_rss_native': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}
    for key, name in [('mlx_active_bytes', 'get_active_memory'), ('mlx_peak_bytes', 'get_peak_memory'), ('mlx_cache_bytes', 'get_cache_memory')]:
        try: result[key] = getattr(mx, name)()
        except (AttributeError, RuntimeError) as exc: result[key] = None; result[key + '_error'] = str(exc)
    try:
        proc = subprocess.run(['vmmap', '-summary', str(os.getpid())], text=True, capture_output=True, timeout=30, check=True)
        result['vmmap_physical_footprint_lines'] = [line.strip() for line in proc.stdout.splitlines() if 'physical footprint' in line.lower()]
        if not result['vmmap_physical_footprint_lines']: result['vmmap_error'] = 'no physical footprint line'
    except (OSError, subprocess.SubprocessError) as exc:
        result['vmmap_physical_footprint_lines'] = []
        result['vmmap_error'] = f'{type(exc).__name__}: {exc}'
    return result


def run_cases(rows, corpus, ffmpeg, backend, transcribe, *, warmup_first=False, clock=time.perf_counter, convert=preprocess):
    cases, warmup = [], None
    def perform(row):
        start = clock(); pcm = convert(ffmpeg, corpus / row['audio']); converted = clock()
        text = transcribe(backend, pcm); done = clock()
        if not isinstance(text, str): raise TypeError('STT result must be text')
        return {'status': 'ok' if text.strip() else 'empty', 'text': text,
                'audio_samples': len(pcm), 'preprocess_s': converted-start, 'transcribe_s': done-converted}
    if warmup_first:
        try: warmup = {'id': rows[0]['id'], **perform(rows[0])}
        except Exception as exc: warmup = {'id': rows[0]['id'], 'status': 'failed', 'error': f'{type(exc).__name__}: {exc}'}
    for row in rows:
        case = {k: row[k] for k in ('id', 'speaker_id', 'accent_label')}
        try: case.update(perform(row))
        except Exception as exc: case.update(status='failed', text='', error=f'{type(exc).__name__}: {exc}')
        cases.append(case)
    return cases, warmup


def run(args):
    if os.environ.get('VELORA_FAKE_STT'): raise ValueError('VELORA_FAKE_STT must be unset')
    manifest, manifest_sha = common.verify_manifest(args.manifest)
    model, config = snapshot(args.model_path)
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg: raise ValueError('ffmpeg is required')
    ffmpeg = str(Path(ffmpeg).resolve())
    identity = identities(model, ffmpeg, args.backend)
    report = {'status':'failed', 'manifest_sha256':manifest_sha, 'backend':args.backend,
              'model_id':args.model_id, 'model_path':str(model), 'snapshot_revision':model.name,
              'manifest_path':str(args.manifest.resolve()),
              'corpus_sha256_before':{r['id']:r['sha256'] for r in manifest['rows']},
              'model_config':config, 'weight_inventory':weight_inventory(model), 'identity_before':identity, 'cases':[], 'sample_rate':16000,
              'preprocessing':'ffmpeg mono 16kHz float32 PCM', 'language':'en' if args.backend == 'whisper' else 'model default',
              'expected_load_dtype':'bfloat16' if args.backend == 'parakeet' else 'float16',
              'quantization':'No runtime quantization or derived cache; model config and weight inventory identify source weights.',
              'model_id_note':'Operator-supplied label; the local snapshot and content hashes are the model identity.',
              'versions':{n:metadata.version(n) for n in ('mlx','numpy', 'parakeet-mlx' if args.backend == 'parakeet' else 'mlx-whisper')},
              'limitations':'Selected small corpus, not general accent or semantic quality. Peak RSS uses platform native units.'}
    try:
        start = time.perf_counter()
        backend, transcribe, mx = load_backend(args.backend, args.model_id, model)
        report['model_load_s'] = time.perf_counter() - start
        report['memory_after_load'] = memory_snapshot(mx)
        cases, warmup = run_cases(manifest['rows'], args.manifest.resolve().parent, ffmpeg, backend, transcribe, warmup_first=args.warmup_first)
        report['cases'], report['warmup'] = cases, warmup
        report['memory_after_decode'] = memory_snapshot(mx)
        report['timing_totals'] = {'successful_cases':sum(c['status'] == 'ok' for c in cases),
                                   'timed_cases':sum('preprocess_s' in c and 'transcribe_s' in c for c in cases),
                                   'preprocess_s':sum(c['preprocess_s'] for c in cases if 'preprocess_s' in c) if any('preprocess_s' in c for c in cases) else None,
                                   'transcribe_s':sum(c['transcribe_s'] for c in cases if 'transcribe_s' in c) if any('transcribe_s' in c for c in cases) else None}
        report['status'] = 'complete' if all(c['status'] == 'ok' for c in cases) and (warmup is None or warmup['status'] == 'ok') else 'partial'
    except Exception as exc:
        report['error'] = f'{type(exc).__name__}: {exc}'
    finally:
        try:
            manifest_after, mh_after = common.verify_manifest(args.manifest)
            report['corpus_sha256_after'] = {r['id']:r['sha256'] for r in manifest_after['rows']}
            report['identity_after'] = identities(model, ffmpeg, args.backend)
            if mh_after != manifest_sha or report['identity_after'] != identity: raise ValueError('inputs changed during decode')
            report['integrity'] = 'verified'
        except Exception as exc:
            report['status'] = 'integrity_failed'; report['integrity'] = 'failed'
            report['integrity_error'] = f'{type(exc).__name__}: {exc}'
    return report


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    p.add_argument('--backend', choices=('whisper','parakeet'), required=True)
    p.add_argument('--model-id', required=True)
    p.add_argument('--model-path', type=Path, required=True)
    p.add_argument('--manifest', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--warmup-first', action='store_true')
    args = p.parse_args(argv)
    output = args.output.expanduser().absolute()
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if output.parent.stat().st_mode & 0o077: raise ValueError('output directory must be private (0700)')
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        try: report = run(args)
        except Exception as exc: report = {'status':'failed','error':f'{type(exc).__name__}: {exc}'}
        json.dump(report, f, ensure_ascii=False, indent=2); f.write('\n')
    return 0 if report['status'] == 'complete' else 2


if __name__ == '__main__': raise SystemExit(main())
