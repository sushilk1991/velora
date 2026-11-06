#!/usr/bin/env python3
"""Private offline Qwen3-ASR replay of a frozen personal recording manifest.

Run in the isolated MLX Audio environment; never reads gold labels or app history.
An output with termination='unknown' is not evidence of EOS.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import resource
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'engine' / 'scripts'))
sys.path.insert(0, str(REPO / 'engine' / 'src'))
from benchmark_personal_recordings import confined, digest, private_dir, private_write
from benchmark_personal_cleanup import hash_tree

SOURCE_REV = '2d7700c299e66b93e28ed211fc6e4922d6b8e238'
MODEL_REV = 'a8379a2e2f9e313c9292cdf1af4055ab56d50d55'
RATE = 16000
MAX_TOKENS = 2048


def source_hash(root):
    """Hash source files, including the local offline-only patch, not caches."""
    h = hashlib.sha256()
    files = sorted((root / 'mlx_audio').rglob('*.py')) + [root / 'pyproject.toml']
    for path in files:
        if path.is_symlink() or not path.is_file():
            raise ValueError('unsafe source file')
        h.update(str(path.relative_to(root)).encode() + b'\0' + bytes.fromhex(digest(path)))
    return h.hexdigest()


def versions():
    result = {'python': sys.version, 'executable': str(Path(sys.executable).resolve())}
    for name in ('mlx-audio', 'mlx', 'mlx-lm', 'transformers', 'huggingface-hub', 'numpy', 'soundfile'):
        try:
            result[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            result[name] = None
    return result


def provenance(manifest, model, source, max_duration):
    source = source.resolve(strict=True)
    model = model.resolve(strict=True)
    if not model.is_dir() or model.name != MODEL_REV:
        raise ValueError('model must be the pinned local snapshot')
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != SOURCE_REV:
        raise ValueError('unexpected MLX Audio source revision')
    qwen = (source / 'mlx_audio/stt/models/qwen3_asr/qwen3_asr.py').read_text()
    if 'trust_remote_code=False, local_files_only=True' not in qwen or 'str(model_path), local_files_only=True' not in qwen:
        raise ValueError('offline-only Qwen tokenizer and extractor patch missing')
    return {'schema': 1, 'manifest_sha256': digest(manifest), 'model_path': str(model),
            'model_revision': MODEL_REV, 'model_sha256': hash_tree(model),
            'mlx_audio_source_path': str(source), 'mlx_audio_source_revision': revision,
            'mlx_audio_source_sha256': source_hash(source), 'runner_sha256': digest(Path(__file__)),
            'media_sha256': digest(REPO / 'engine/src/velora_engine/media.py'),
            'recordings_helper_sha256': digest(REPO / 'engine/scripts/benchmark_personal_recordings.py'),
            'cleanup_helper_sha256': digest(REPO / 'engine/scripts/benchmark_personal_cleanup.py'),
            'versions': versions(), 'max_duration_s': max_duration,
            'generate': {'max_tokens': MAX_TOKENS, 'chunk_duration': 30, 'language': None,
                         'temperature': 0, 'verbose': False},
            'termination': 'EOS not exposed; token cap or incomplete segment coverage fails',
            'rss_scope': 'process lifetime peak, native ru_maxrss units',
            'method': 'offline batch file STT; no gold, cleanup, or live capture'}


def assess(result, duration):
    text = getattr(result, 'text', None)
    tokens = getattr(result, 'generation_tokens', None)
    segments = getattr(result, 'segments', None)
    if not isinstance(text, str):
        raise ValueError('invalid text')
    if not isinstance(tokens, int) or isinstance(tokens, bool) or tokens < 0:
        raise ValueError('invalid generation count')
    if not isinstance(segments, list) or not segments:
        raise ValueError('missing segments')
    ends = [s.get('end') for s in segments if isinstance(s, dict)]
    if len(ends) != len(segments) or any(not isinstance(x, (int, float)) or not math.isfinite(x) for x in ends):
        raise ValueError('invalid segment coverage')
    # The implementation records chunk end at the end of the input audio.
    covered = max(ends)
    if tokens >= MAX_TOKENS:
        return text, tokens, covered, 'length_limit'
    if covered + 0.05 < duration:
        return text, tokens, covered, 'incomplete_audio'
    return text, tokens, covered, 'unknown'


def replay(manifest_path, output, model_path, source_path, *, loader=None, decode=None, retry_failures=False):
    manifest_path = manifest_path.expanduser().resolve(strict=True)
    manifest = json.loads(manifest_path.read_text())
    cases = manifest['cases']
    ids = [c['id'] for c in cases]
    if len(set(ids)) != len(ids):
        raise ValueError('duplicate case id')
    # Historical duration_ms is approximate; use a fixed bound, not a
    # per-recording cutoff that might discard a valid final frame.
    max_duration = 600.0
    root = Path(manifest['audio_root']).expanduser().resolve(strict=True)
    info = provenance(manifest_path, model_path, source_path, max_duration)
    output = private_dir(output)
    meta = output / 'stt-run.json'
    if meta.exists():
        if json.loads(meta.read_text()) != info:
            raise ValueError('existing run provenance differs')
    else:
        if any(output.iterdir()):
            raise ValueError('output directory is not empty')
        private_write(meta, info)
    case_dir = output / 'cases'
    case_dir.mkdir(mode=0o700, exist_ok=True)
    os.chmod(case_dir, 0o700)
    paths = [case_dir / (hashlib.sha256(str(c['id']).encode()).hexdigest() + '.json') for c in cases]
    pending = []
    for case, path in zip(cases, paths):
        if path.exists():
            row = json.loads(path.read_text())
            if row.get('id') != case['id'] or row.get('input_sha256') != case.get('input_sha256'):
                raise ValueError('existing case mismatch')
            if row.get('status') == 'ok' or not retry_failures:
                continue
        pending.append((case, path))
    if pending:
        # Enforce offline behavior before MLX or Transformers imports.
        os.environ['HF_HUB_OFFLINE'] = '1'
        os.environ['TRANSFORMERS_OFFLINE'] = '1'
        if loader is None:
            from mlx_audio.stt.utils import load_model
            import mlx_audio
            if not Path(mlx_audio.__file__).resolve().is_relative_to(source_path.resolve(strict=True)):
                raise ValueError('MLX Audio imported from unexpected source')
            loader = lambda p: load_model(p, strict=True)
        if decode is None:
            from velora_engine.media import load_media
            decode = load_media
        start = time.perf_counter()
        model = loader(model_path.expanduser().resolve(strict=True))
        load_s = time.perf_counter() - start
        for case, dest in pending:
            begin = time.perf_counter()
            row = {'id': case['id'], 'input_sha256': case.get('input_sha256'), 'status': 'failed',
                   'raw': None, 'audio_read_s': None, 'stt_s': None, 'total_s': None}
            try:
                if case['status'] != 'available':
                    raise ValueError('unavailable at inventory')
                path = confined(root, case['audio_path'])
                if digest(path) != case['input_sha256']:
                    raise ValueError('input hash changed')
                started = time.perf_counter()
                pcm = decode(str(path))
                row['audio_read_s'] = time.perf_counter() - started
                import numpy as np
                if not isinstance(pcm, np.ndarray) or pcm.ndim != 1 or pcm.dtype != np.float32 or not np.isfinite(pcm).all():
                    raise ValueError('invalid mono float32 audio')
                duration = len(pcm) / RATE
                row['audio_duration_s'] = duration
                if duration < 0.2 or duration > max_duration:
                    raise ValueError('audio duration outside frozen bounds')
                if digest(path) != case['input_sha256']:
                    raise ValueError('input changed during decode')
                started = time.perf_counter()
                try:
                    result = model.generate(pcm, max_tokens=MAX_TOKENS, chunk_duration=30,
                                            language=None, temperature=0, verbose=False)
                finally:
                    row['stt_s'] = time.perf_counter() - started
                text, tokens, covered, termination = assess(result, duration)
                row.update(raw=text, generation_tokens=tokens, segment_end_s=covered,
                           termination=termination, status='ok' if termination == 'unknown' else termination)
            except Exception as exc:
                row['error_type'] = type(exc).__name__
            row['total_s'] = time.perf_counter() - begin
            row['peak_rss_native'] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
            tmp = dest.with_suffix('.tmp')
            tmp.unlink(missing_ok=True)
            private_write(tmp, row)
            os.replace(tmp, dest)
    else:
        load_s = None
    # Atomically regenerate the compatibility JSONL from complete case records.
    result_path = output / 'stt.jsonl'
    tmp = output / 'stt.jsonl.tmp'
    tmp.unlink(missing_ok=True)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f:
        for path in paths:
            if path.exists():
                f.write(json.dumps(json.loads(path.read_text()), ensure_ascii=False) + '\n')
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, result_path)
    print(json.dumps({'output': str(result_path), 'total_cases': len(cases),
                      'completed': sum(p.exists() for p in paths), 'model_load_s': load_s}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--model-path', type=Path, required=True)
    parser.add_argument('--source-path', type=Path, required=True)
    parser.add_argument('--retry-failures', action='store_true')
    args = parser.parse_args()
    replay(args.manifest, args.output, args.model_path, args.source_path, retry_failures=args.retry_failures)


if __name__ == '__main__':
    main()
