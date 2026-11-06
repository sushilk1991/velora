#!/usr/bin/env python3
"""Private, offline batch replay of a frozen personal dictation corpus.

Inventory snapshots history metadata, not gold labels. Replay follows the
production transcribe_file batch STT path; it is not live stop-to-paste timing.
Outputs contain private text and must stay outside the checkout.
"""
from __future__ import annotations
import argparse
import hashlib
import shutil
import json
import os
from pathlib import Path
import resource
import sqlite3
import sys
import time

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'engine' / 'src'))


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def private_dir(path):
    path = path.expanduser().resolve()
    if path == REPO or REPO in path.parents:
        raise ValueError('private output must be outside the repository')
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def private_write(path, value):
    # Refuse replacement: a frozen cohort must never silently change.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as out:
        json.dump(value, out, ensure_ascii=False, indent=2)
        out.write('\n')


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


def confined(root, name):
    if not isinstance(name, str) or not name or Path(name).name != name or name in ('.', '..'):
        raise ValueError('invalid audio basename')
    path = root / name
    if path.is_symlink() or path.resolve().parent != root or not path.is_file():
        raise ValueError('missing or unsafe audio')
    return path


def inventory(database, audio_root, output):
    audio_root = audio_root.expanduser().resolve(strict=True)
    output = private_dir(output)
    con = sqlite3.connect(database.expanduser().resolve(strict=True).as_uri() + '?mode=ro', uri=True)
    con.row_factory = sqlite3.Row
    con.execute('PRAGMA query_only=ON')
    try:
        rows = con.execute('SELECT id, audio_path, raw, mode, bundle_id, app_name, duration_ms '
                           'FROM dictations WHERE audio_path IS NOT NULL AND audio_path != "" ORDER BY id').fetchall()
    finally:
        con.close()
    cases = []
    for row in rows:
        item = dict(row)
        item['historical_raw_unverified'] = item.pop('raw')
        try:
            path = confined(audio_root, item['audio_path'])
            item.update(input_sha256=digest(path), input_bytes=path.stat().st_size, status='available')
        except (OSError, ValueError):
            item.update(input_sha256=None, input_bytes=None, status='missing_or_unsafe')
        cases.append(item)
    manifest = {'schema': 1, 'audio_root': str(audio_root), 'cases': cases,
                'reference_status': 'historical raw is unverified; no historical final included'}
    path = output / 'manifest.json'
    private_write(path, manifest)
    available = sum(c['status'] == 'available' for c in cases)
    print(json.dumps({'manifest': str(path), 'sha256': digest(path), 'rows': len(cases),
                      'available': available, 'missing_or_unsafe': len(cases)-available}))


def replay(manifest_path, output, model, language, model_path, config_home=None):
    from velora_engine.media import load_media, split_for_batch
    from velora_engine.stt import SAMPLE_RATE, create_backend, transcribe_clip
    from velora_engine import models
    output = private_dir(output)
    metadata = output / 'stt-run.json'
    snapshot = output / 'config-snapshot'
    glossary = None
    glossary_info = 'none; explicit unbiased reference/control pass'
    if config_home is not None:
        from velora_engine.config import Config
        from velora_engine.stt import build_glossary_prompt
        home = config_home.expanduser().resolve(strict=True)
        if not metadata.exists():
            if snapshot.exists():
                raise ValueError('incomplete setup: choose a new output directory')
            snapshot_config(home, snapshot)
        elif not snapshot.is_dir():
            raise ValueError('missing frozen configuration snapshot')
        before = {str(p.relative_to(snapshot)): digest(p) for p in sorted(snapshot.rglob('*')) if p.is_file()}
        config = Config(snapshot)
        for path in snapshot.rglob('*'):
            os.chmod(path, 0o700 if path.is_dir() else 0o600)
        after = {str(p.relative_to(snapshot)): digest(p) for p in sorted(snapshot.rglob('*')) if p.is_file()}
        if metadata.exists() and before != after:
            raise ValueError('configuration snapshot changed during load')
        glossary = build_glossary_prompt(config.user_vocabulary,
            config.learned_vocabulary, config.auto_vocabulary, [])
        glossary_info = {'mode': 'production global glossary; no historical screen entities',
            'sha256': hashlib.sha256((glossary or '').encode()).hexdigest(),
            'config_home': str(home),
            'source_sha256': after}
    manifest_path = manifest_path.resolve(strict=True)
    manifest = json.loads(manifest_path.read_text())
    root = Path(manifest['audio_root']).resolve(strict=True)
    cases_by_id = {case['id']: case for case in manifest['cases']}
    if len(cases_by_id) != len(manifest['cases']):
        raise ValueError('duplicate manifest id')
    results = output / 'stt.jsonl'
    info = {'schema': 1, 'manifest_sha256': digest(manifest_path), 'model': model,
            'language': language, 'model_path': str(model_path.resolve()) if model_path else None,
            'method': 'offline production transcribe_file batch STT; no live capture, cleanup or insertion',
            'glossary': glossary_info, 'rss_scope': 'process lifetime peak; platform native ru_maxrss units',
            'runner_sha256': digest(Path(__file__)),
            'stt_source_sha256': digest(REPO/'engine/src/velora_engine/stt.py'),
            'media_source_sha256': digest(REPO/'engine/src/velora_engine/media.py')}
    if model_path:
        local = model_path.expanduser().resolve(strict=True)
        info['model_files_sha256'] = {str(p.relative_to(local)): digest(p)
            for p in sorted(local.rglob('*')) if p.is_file()
            and p.suffix in ('.json', '.npz', '.safetensors', '.tiktoken', '.txt')}
    if metadata.exists():
        if json.loads(metadata.read_text()) != info:
            raise ValueError('existing run metadata differs; choose another output directory')
    else:
        if results.exists():
            raise ValueError('result file exists without run metadata')
        private_write(metadata, info)
    done = set()
    if results.exists():
        for line in results.read_text().splitlines():
            row = json.loads(line)
            identity = row['id']
            if identity in done:
                raise ValueError('duplicate result id')
            if identity not in cases_by_id:
                raise ValueError('result id is not in frozen manifest')
            if row.get('input_sha256') != cases_by_id[identity].get('input_sha256'):
                raise ValueError('result input hash differs from frozen manifest')
            done.add(identity)
    if not model_path and os.environ.get('VELORA_FAKE_STT') != '1':
        raise ValueError('--model-path is required for offline replay')
    if model_path:
        resolved_model = model_path.expanduser().resolve(strict=True)
        def local_only(name):
            if name != model:
                raise ValueError('unexpected model requested during offline replay')
            return str(resolved_model)
        models.ensure_downloaded = local_only
    backend = create_backend(model, language)
    started = time.perf_counter()
    backend.load()
    load_s = time.perf_counter() - started
    fd = os.open(results, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.chmod(results, 0o600)
    with os.fdopen(fd, 'a', buffering=1) as out:
        for case in manifest['cases']:
            if case['id'] in done:
                continue
            begin = time.perf_counter()
            record = {'id': case['id'], 'input_sha256': case['input_sha256'], 'status': 'failed',
                      'audio_read_s': None, 'stt_s': None, 'cleanup_s': None, 'total_s': None}
            try:
                if case['status'] != 'available':
                    raise ValueError('unavailable_at_inventory')
                path = confined(root, case['audio_path'])
                if digest(path) != case['input_sha256']:
                    raise ValueError('input_hash_changed')
                t = time.perf_counter()
                pcm = load_media(str(path))
                record['audio_read_s'] = time.perf_counter() - t
                record['audio_duration_s'] = len(pcm) / SAMPLE_RATE
                if len(pcm) < SAMPLE_RATE * 0.2:
                    raise ValueError('audio_under_0.2_seconds')
                t = time.perf_counter()
                pieces = []
                for chunk in split_for_batch(pcm):
                    # Match Engine._run_transcribe_file: reset the configured
                    # recognition glossary before every chunk, not only load.
                    backend.initial_prompt = glossary
                    pieces.append(transcribe_clip(backend, chunk).strip())
                record['stt_s'] = time.perf_counter() - t
                record['raw'] = ' '.join(piece for piece in pieces if piece)
                record['status'] = 'ok'
            except Exception as exc:
                # Error text may contain private paths or text. Keep class only.
                record['error_type'] = type(exc).__name__
            record['total_s'] = time.perf_counter() - begin
            record['peak_rss_native'] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
            out.write(json.dumps(record, ensure_ascii=False) + '\n')
            out.flush()
            os.fsync(out.fileno())
    all_rows = [json.loads(line) for line in results.read_text().splitlines()]
    ok = sum(r['status'] == 'ok' for r in all_rows)
    print(json.dumps({'output': str(results), 'total_cases': len(manifest['cases']),
                      'completed': len(all_rows), 'ok': ok, 'failed': len(all_rows)-ok,
                      'model_load_s': load_s}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('inventory')
    p.add_argument('--database', type=Path, default=Path.home()/'.velora/history.sqlite3')
    p.add_argument('--audio-root', type=Path, default=Path.home()/'.velora/audio')
    p.add_argument('--output', required=True, type=Path)
    p = sub.add_parser('stt')
    p.add_argument('--manifest', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--model', required=True)
    p.add_argument('--language', default='auto')
    p.add_argument('--model-path', type=Path)
    p.add_argument('--config-home', type=Path,
                   help='frozen config for the production recognition glossary; omit only for a declared no-glossary reference pass')
    args = parser.parse_args()
    if args.command == 'inventory':
        inventory(args.database, args.audio_root, args.output)
    else:
        replay(args.manifest, args.output, args.model, args.language, args.model_path, args.config_home)

if __name__ == '__main__':
    main()
