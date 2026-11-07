#!/usr/bin/env python3
"""Local VCTK research benchmark. Decode explicitly or score prior JSON without model imports.

This measures normalized token alignment, not semantic correctness or accent generality.
Score input is a recognition report from this script; candidate JSON is a list of
{id, text} objects (or an object with a cases list). Both must cover every case.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib
import importlib.util
from importlib import metadata
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import unicodedata

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'engine/src'))


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def tokens(text):
    # Punctuation becomes whitespace, not deletion joining adjacent words.
    return ''.join(' ' if unicodedata.category(c).startswith('P') else c
                   for c in unicodedata.normalize('NFKC', text).casefold()).split()


def align(reference, hypothesis):
    """Levenshtein; backtrack ties in order match/substitution, deletion, insertion."""
    r, h = tokens(reference), tokens(hypothesis)
    d = [[0] * (len(h) + 1) for _ in range(len(r) + 1)]
    for i in range(len(r) + 1): d[i][0] = i
    for j in range(len(h) + 1): d[0][j] = j
    for i in range(1, len(r) + 1):
        for j in range(1, len(h) + 1):
            d[i][j] = min(d[i-1][j-1] + (r[i-1] != h[j-1]), d[i-1][j]+1, d[i][j-1]+1)
    states = [None] * len(r)
    insertions = 0
    i, j = len(r), len(h)
    while i or j:
        if i and j and d[i][j] == d[i-1][j-1] + (r[i-1] != h[j-1]):
            states[i-1] = 'match' if r[i-1] == h[j-1] else 'substitution'
            i -= 1; j -= 1
        elif i and d[i][j] == d[i-1][j] + 1:
            states[i-1] = 'deletion'; i -= 1
        else:
            insertions += 1; j -= 1
    return {'reference_tokens': r, 'reference_states': states, 'insertions': insertions,
            'errors': d[-1][-1], 'wer': d[-1][-1] / len(r) if r else None}


def compare(reference, raw, candidate):
    before, after = align(reference, raw), align(reference, candidate)
    repairs = [i for i, (a, b) in enumerate(zip(before['reference_states'], after['reference_states'])) if a != 'match' and b == 'match']
    damage = [i for i, (a, b) in enumerate(zip(before['reference_states'], after['reference_states'])) if a == 'match' and b != 'match']
    delta = after['insertions'] - before['insertions']
    assert after['errors'] - before['errors'] == len(damage) - len(repairs) + delta
    return {'before': before, 'after': after, 'repaired_reference_positions': repairs,
            'damaged_reference_positions': damage, 'insertion_delta': delta,
            'error_delta': after['errors'] - before['errors']}


def verify_manifest(path):
    path = path.resolve(strict=True)
    manifest_hash = digest(path)
    data = json.loads(path.read_text(encoding='utf-8'))
    rows = data['rows']
    if not rows or len({r['id'] for r in rows}) != len(rows):
        raise ValueError('manifest rows empty or duplicate IDs')
    for row in rows:
        for kind in ('audio', 'transcript'):
            source = (path.parent / row[kind]).resolve(strict=True)
            if path.parent not in source.parents or not source.is_file():
                raise ValueError('manifest source outside corpus or not a file')
            if digest(source) != row['sha256'][kind]:
                raise ValueError(f"{row['id']} {kind} checksum mismatch")
    return data, manifest_hash


def files_identity(model, ffmpeg, package_files=()):
    files = {str(p.relative_to(model)): digest(p) for p in sorted(model.rglob('*')) if p.is_file()}
    if not files: raise ValueError('empty model directory')
    sources = [Path(__file__), ROOT / 'engine/src/velora_engine/stt.py',
               ROOT / 'engine/src/velora_engine/models.py', Path(ffmpeg), *package_files]
    return {'model_files_sha256': files, 'source_sha256': {str(p): digest(p) for p in sources}}


def read_cases(path):
    obj = json.loads(path.read_text(encoding='utf-8'))
    cases = obj if isinstance(obj, list) else obj['cases']
    if not isinstance(cases, list) or any(not isinstance(x.get('text'), str) for x in cases):
        raise ValueError('cases must have string text')
    result = {x['id']: x for x in cases}
    if len(result) != len(cases): raise ValueError('duplicate case IDs')
    return result


def snapshot_revision(model_path):
    # Only a Hugging Face-style snapshot path carries an explicit revision.
    if not isinstance(model_path, str):
        return None
    path = Path(model_path)
    return path.name if path.parent.name == 'snapshots' and re.fullmatch(r'[0-9a-f]{40}', path.name) else None


def recognition_model_provenance(report):
    before, after = report.get('identity_before'), report.get('identity_after')
    if not isinstance(before, dict) or before != after:
        raise ValueError('recognition model identity missing or changed')
    files = before.get('model_files_sha256')
    if not isinstance(files, dict) or not files or any(
        not isinstance(k, str) or not isinstance(v, str) or not re.fullmatch(r'[0-9a-f]{64}', v)
        for k, v in files.items()
    ):
        raise ValueError('recognition model file hashes missing or invalid')
    revision = snapshot_revision(report.get('model_path'))
    if report.get('snapshot_revision') is not None and report['snapshot_revision'] != revision:
        raise ValueError('recognition snapshot revision disagrees with model path')
    return {'model_id': report.get('model_id'),
            'model_id_role': 'operator-supplied unverified label; not proof of model identity',
            'model_path': report.get('model_path'), 'snapshot_revision': revision,
            'model_files_sha256': files}


def score(manifest_path, recognition_path, candidate_path):
    manifest, mh = verify_manifest(manifest_path)
    recognition_hash, candidate_hash = digest(recognition_path), digest(candidate_path)
    original = json.loads(recognition_path.read_text(encoding='utf-8'))
    if original.get('status') != 'complete' or original.get('integrity') != 'verified' or original.get('manifest_sha256') != mh:
        raise ValueError('recognition report incomplete or from different manifest')
    model_provenance = recognition_model_provenance(original)
    raw, candidate = read_cases(recognition_path), read_cases(candidate_path)
    ids = {r['id'] for r in manifest['rows']}
    if set(raw) != ids or set(candidate) != ids or any(raw[i].get('status') != 'ok' for i in ids):
        raise ValueError('recognition and candidate must cover all successful cases')
    cases = []
    for row in manifest['rows']:
        ref = (manifest_path.resolve().parent / row['transcript']).read_text(encoding='utf-8')
        cases.append({'id': row['id'], 'accent_label': row['accent_label'],
                      'metrics': compare(ref, raw[row['id']]['text'], candidate[row['id']]['text'])})
    if verify_manifest(manifest_path)[1] != mh or digest(recognition_path) != recognition_hash or digest(candidate_path) != candidate_hash:
        raise ValueError('score inputs changed')
    return {'status': 'complete', 'manifest_sha256': mh, 'recognition_sha256': recognition_hash,
            'candidate_sha256': candidate_hash, 'recognition_model': model_provenance, 'cases': cases,
            'limitations': 'Complete means scoring completed, not proof of model name. Normalized token alignment only; not semantic truth or accent generality. Positions are zero-based and ties use diagonal, deletion, insertion.'}


def decode(manifest_path, model_path, model_id):
    if os.environ.get('VELORA_FAKE_STT'):
        raise ValueError('VELORA_FAKE_STT must be unset')
    manifest, mh = verify_manifest(manifest_path)
    model = model_path.expanduser().resolve(strict=True)
    if not model.is_dir(): raise ValueError('model path must be a local directory')
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg: raise ValueError('ffmpeg is required')
    ffmpeg = str(Path(ffmpeg).resolve())
    spec = importlib.util.find_spec('mlx_whisper')
    if spec is None or not spec.submodule_search_locations: raise ValueError('mlx-whisper is not installed')
    package_files = sorted(Path(next(iter(spec.submodule_search_locations))).rglob('*.py'))
    if not package_files: raise ValueError('mlx-whisper source files not found')
    identity = files_identity(model, ffmpeg, package_files)
    report = {'status': 'failed', 'manifest_sha256': mh, 'model_id': model_id,
              'model_path': str(model), 'snapshot_revision': snapshot_revision(str(model)),
              'model_id_role': 'operator-supplied unverified label; not proof of model identity',
              'identity_before': identity, 'cases': [],
              'sample_rate': 16000, 'language': 'en',
              'versions': {name: metadata.version(name) for name in ('mlx', 'mlx-whisper', 'numpy')},
              'preprocessing': 'ffmpeg mono 16kHz float32 PCM',
              'limitations': 'Offline app Whisper STT on a small selected corpus; no accent generality or semantic certification.'}
    try:
        os.environ['HF_HUB_OFFLINE'] = '1'
        os.environ['TRANSFORMERS_OFFLINE'] = '1'
        import numpy as np
        import mlx.core as mx
        loader = importlib.import_module('mlx_whisper.load_models')
        def deny_remote(*args, **kwargs): raise RuntimeError('remote downloads forbidden')
        loader.snapshot_download = deny_remote
        from mlx_whisper.transcribe import ModelHolder
        from velora_engine.stt import WhisperBackend, transcribe_clip
        backend = WhisperBackend(model_id, language='en')
        backend._model_path = str(model)
        backend.initial_prompt = None
        weights = ModelHolder.get_model(str(model), mx.float16)
        mx.eval(weights.parameters())
        backend._loaded = True
        for row in manifest['rows']:
            case = {'id': row['id'], 'speaker_id': row['speaker_id'], 'accent_label': row['accent_label']}
            try:
                pcm = subprocess.run([ffmpeg, '-v', 'error', '-nostdin', '-i', str(manifest_path.resolve().parent / row['audio']),
                                      '-ac', '1', '-ar', '16000', '-f', 'f32le', '-'],
                                     check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
                audio = np.frombuffer(pcm, dtype='<f4').copy()
                if not len(audio) or not np.isfinite(audio).all(): raise ValueError('empty or invalid PCM')
                text = transcribe_clip(backend, audio)
                case.update(text=text, status='ok' if text.strip() else 'empty', audio_samples=len(audio))
            except Exception as exc:
                case.update(text='', status='failed', error_type=type(exc).__name__, error=str(exc))
            report['cases'].append(case)
        report['status'] = 'complete' if all(c['status'] == 'ok' for c in report['cases']) else 'partial'
    except Exception as exc:
        report['error'] = f'{type(exc).__name__}: {exc}'
    finally:
        try:
            _, after_manifest = verify_manifest(manifest_path)
            report['identity_after'] = files_identity(model, ffmpeg, package_files)
            if after_manifest != mh or report['identity_after'] != identity:
                raise ValueError('manifest, model, or source changed during decode')
            report['integrity'] = 'verified'
        except Exception as exc:
            report['integrity'] = 'failed'
            report['integrity_error'] = f'{type(exc).__name__}: {exc}'
            report['status'] = 'integrity_failed'
    return report


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    p.add_argument('--manifest', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--stt-model', help='operator-supplied model label, unverified; required for decode')
    p.add_argument('--model-path', type=Path, help='existing local MLX model directory; required for decode')
    p.add_argument('--score-only', type=Path, metavar='RECOGNITION_JSON')
    p.add_argument('--candidate', type=Path, help='candidate JSON; required with --score-only')
    args = p.parse_args(argv)
    if args.score_only:
        if not args.candidate or args.stt_model or args.model_path: p.error('score-only requires --candidate and no model arguments')
    elif not args.stt_model or not args.model_path or args.candidate:
        p.error('decode requires --stt-model and --model-path; no candidate')
    output = args.output.expanduser().absolute()
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if output.parent.stat().st_mode & 0o077: raise ValueError('output directory must be private (0700)')
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        try:
            report = score(args.manifest, args.score_only, args.candidate) if args.score_only else decode(args.manifest, args.model_path, args.stt_model)
        except Exception as exc:
            report = {'status': 'failed', 'error': f'{type(exc).__name__}: {exc}'}
        json.dump(report, f, ensure_ascii=False, indent=2); f.write('\n')
    return 0 if report['status'] == 'complete' else 2


if __name__ == '__main__':
    raise SystemExit(main())
