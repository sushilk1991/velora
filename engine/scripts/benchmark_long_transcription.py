#!/usr/bin/env python3
"""Offline meeting transcription of an external CAF/M4A through app STT code.

No capture, history, app sockets, downloads, or personal glossary. Run only
with an explicitly supplied pre-existing local Whisper MLX model directory.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib
from importlib import metadata
import json
import os
from pathlib import Path
import resource
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'engine' / 'src'))
from velora_engine.media import load_meeting_media, plan_meeting_slices
from velora_engine.stt import SAMPLE_RATE, WhisperBackend, transcribe_clip


def outside_repo(path: Path) -> Path:
    value = path.expanduser().resolve()
    if value == ROOT or ROOT in value.parents:
        raise ValueError('audio and output must be outside the repository')
    return value


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def input_identity(audio, model, sources=None):
    """Bind a run to bytes, including HF snapshot files backed by symlinks."""
    if sources is None:
        sources = [Path(__file__), ROOT / 'engine/src/velora_engine/media.py',
                   ROOT / 'engine/src/velora_engine/stt.py']
    files = {str(p.relative_to(model)): digest(p)
             for p in sorted(model.rglob('*')) if p.is_file()}
    if not files:
        raise ValueError('local model directory has no files')
    return {'audio_sha256': digest(audio), 'model_files_sha256': files,
            'source_sha256': {str(p.resolve()): digest(p) for p in sources}}


def identity_changes(before, after):
    return [key for key in before if before[key] != after.get(key)]


def verify_ranges(ranges, count):
    if not ranges or ranges[0][0] != 0 or ranges[-1][1] != count:
        raise ValueError('audio plan does not cover track endpoints')
    if any(a >= b for a, b in ranges) or any(x[1] != y[0] for x, y in zip(ranges, ranges[1:])):
        raise ValueError('audio plan has a gap, overlap, or empty span')


def clock(sample):
    seconds = sample // SAMPLE_RATE
    return f'{seconds // 3600:02d}:{seconds // 60 % 60:02d}:{seconds % 60:02d}'


def decode_track(track, backend, ranges, transcriber=transcribe_clip):
    verify_ranges(ranges, len(track))
    rows = []
    for index, (start, end) in enumerate(ranges):
        t0 = time.perf_counter()
        try:
            pcm = track.read(start, end, cancel=lambda: False)
            if len(pcm) != end - start:
                raise ValueError('incomplete audio read')
            text = transcriber(backend, pcm)
            rows.append({'index': index, 'start_sample': start, 'end_sample': end,
                         'start_ms': start * 1000 // SAMPLE_RATE,
                         'end_ms': end * 1000 // SAMPLE_RATE,
                         'status': 'ok' if text.strip() else 'empty', 'text': text.strip(),
                         'elapsed_ms': (time.perf_counter() - t0) * 1000})
        except Exception as exc:
            rows.append({'index': index, 'start_sample': start, 'end_sample': end,
                         'start_ms': start * 1000 // SAMPLE_RATE,
                         'end_ms': end * 1000 // SAMPLE_RATE, 'status': 'failed',
                         'error_type': type(exc).__name__, 'text': '',
                         'elapsed_ms': (time.perf_counter() - t0) * 1000})
    return rows


def report_status(rows):
    # Empty model output is not evidence of silence; require independent audio
    # evidence before considering that slice covered.
    return 'complete' if rows and all(row['status'] == 'ok' for row in rows) else 'partial'


def write_private(path, data):
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(data)


def run(args):
    audio = outside_repo(args.audio).resolve(strict=True)
    output = outside_repo(args.output)
    transcript = outside_repo(args.transcript)
    if output == transcript or output.exists() or transcript.exists():
        raise FileExistsError('choose distinct new output paths')
    model = args.model_path.expanduser().resolve(strict=True)
    if not model.is_dir():
        raise ValueError('a local MLX model directory is required')
    if audio.suffix.lower() not in ('.caf', '.m4a'):
        raise ValueError('app meeting media accepts CAF or M4A; convert external source first')
    t0 = time.perf_counter()
    identity = input_identity(audio, model)
    verify_before_ms = (time.perf_counter() - t0) * 1000
    t0 = time.perf_counter()
    track = load_meeting_media(str(audio), meeting_root=audio.parent, cancel=lambda: False)
    converted_ms = (time.perf_counter() - t0) * 1000
    try:
        t0 = time.perf_counter()
        ranges = plan_meeting_slices(track, SAMPLE_RATE, cancel=lambda: False)
        verify_ranges(ranges, len(track))
        plan_ms = (time.perf_counter() - t0) * 1000
        # Match WhisperBackend.load without ensure_downloaded: this benchmark
        # accepts only an already-present local path and never resolves a hub ID.
        os.environ['HF_HUB_OFFLINE'] = '1'
        import mlx.core as mx
        loader = importlib.import_module('mlx_whisper.load_models')
        def deny_remote(*_args, **_kwargs):
            raise RuntimeError('benchmark forbids remote model acquisition')
        loader.snapshot_download = deny_remote
        from mlx_whisper.transcribe import ModelHolder
        backend = WhisperBackend(args.model_id, language=args.language)
        backend._model_path = str(model)
        backend.initial_prompt = None
        t0 = time.perf_counter()
        weights = ModelHolder.get_model(str(model), mx.float16)
        mx.eval(weights.parameters())
        backend._loaded = True
        load_ms = (time.perf_counter() - t0) * 1000
        rows = decode_track(track, backend, ranges)
        lines = [f'[{clock(row["start_sample"])}] {row["text"]}' for row in rows if row['text']]
        # Every span is also recorded in JSON, including silent or failed spans.
        t0 = time.perf_counter()
        try:
            errors = identity_changes(identity, input_identity(audio, model))
        except (OSError, ValueError) as exc:
            errors = ['input_recheck_failed:' + type(exc).__name__]
        verify_after_ms = (time.perf_counter() - t0) * 1000
        if not errors:
            write_private(transcript, '\n'.join(lines) + ('\n' if lines else ''))
        versions = {}
        for package in ('mlx', 'mlx-whisper', 'numpy', 'soundfile'):
            try:
                versions[package] = metadata.version(package)
            except metadata.PackageNotFoundError:
                versions[package] = None
        report = {'status': 'integrity_failed' if errors else report_status(rows),
                  **identity, 'integrity_errors': errors, 'transcript_written': not errors,
                  'verify_before_ms': verify_before_ms, 'verify_after_ms': verify_after_ms,
                  'versions': versions, 'audio_samples': len(track),
                  'sample_rate': SAMPLE_RATE, 'plan': 'production quiet-boundary meeting planner',
                  'model_id': args.model_id, 'model_path': str(model), 'language': args.language,
                  'initial_prompt': None, 'convert_ms': converted_ms, 'plan_ms': plan_ms,
                  'model_load_ms': load_ms, 'peak_rss_native': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                  'spans': rows, 'limitations': 'Offline single-track app batch STT; no diarization, live timing or accuracy judgment. Empty output may be silence or a missed utterance.'}
        write_private(output, json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        return 0 if report['status'] == 'complete' else 2
    finally:
        track.close()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--audio', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--transcript', required=True, type=Path)
    p.add_argument('--model-id', required=True)
    p.add_argument('--model-path', required=True, type=Path)
    p.add_argument('--language', default='auto')
    return run(p.parse_args())

if __name__ == '__main__':
    raise SystemExit(main())
