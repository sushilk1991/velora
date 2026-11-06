"""Offline corpus freezing and replay must not alter private history."""
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import wave

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'benchmark_personal_recordings.py'
spec = importlib.util.spec_from_file_location('personal_bench', SCRIPT)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def test_inventory_confines_paths_and_freezes_without_history_writes(tmp_path, capsys):
    audio = tmp_path / 'audio'
    audio.mkdir()
    (audio / 'good.wav').write_bytes(b'original')
    (audio / 'link.wav').symlink_to(audio / 'good.wav')
    db = tmp_path / 'history.sqlite'
    conn = sqlite3.connect(db)
    conn.execute('CREATE TABLE dictations (id INTEGER, audio_path TEXT, raw TEXT, final TEXT, mode TEXT, bundle_id TEXT, app_name TEXT, duration_ms INTEGER)')
    conn.executemany('INSERT INTO dictations VALUES (?, ?, ?, ?, ?, ?, ?, ?)', [
        (1, 'good.wav', 'raw secret', 'final secret', None, None, None, 1000),
        (2, '../good.wav', '', '', None, None, None, 0),
        (3, 'link.wav', '', '', None, None, None, 0),
    ])
    conn.commit()
    conn.close()
    before = bench.digest(db)
    output = tmp_path / 'private'
    bench.inventory(db, audio, output)
    manifest = json.loads((output / 'manifest.json').read_text())
    assert [c['status'] for c in manifest['cases']] == ['available', 'missing_or_unsafe', 'missing_or_unsafe']
    assert 'final secret' not in (output / 'manifest.json').read_text()
    assert 'raw secret' not in capsys.readouterr().out
    assert bench.digest(db) == before
    assert output.stat().st_mode & 0o777 == 0o700
    assert (output / 'manifest.json').stat().st_mode & 0o777 == 0o600
    with pytest.raises(FileExistsError):
        bench.inventory(db, audio, output)


def test_replay_hash_failures_and_resume(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv('VELORA_FAKE_STT', '1')
    audio = tmp_path / 'audio'
    audio.mkdir()
    clip = audio / 'clip.wav'
    with wave.open(str(clip), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b'\0\0' * 16000)
    manifest = tmp_path / 'manifest.json'
    manifest.write_text(json.dumps({'audio_root': str(audio), 'cases': [
        {'id': 1, 'audio_path': 'clip.wav', 'input_sha256': bench.digest(clip), 'status': 'available'},
        {'id': 2, 'audio_path': 'clip.wav', 'input_sha256': 'changed', 'status': 'available'},
        {'id': 3, 'audio_path': 'missing.wav', 'input_sha256': None, 'status': 'missing_or_unsafe'},
    ]}))
    output = tmp_path / 'out'
    bench.replay(manifest, output, 'fake', 'auto', None)
    results = output / 'stt.jsonl'
    rows = [json.loads(line) for line in results.read_text().splitlines()]
    assert [r['status'] for r in rows] == ['ok', 'failed', 'failed']
    assert rows[0]['raw']
    assert rows[0]['cleanup_s'] is None
    original = results.read_bytes()
    bench.replay(manifest, output, 'fake', 'auto', None)
    assert results.read_bytes() == original
    assert 'hello world' not in capsys.readouterr().out
    with pytest.raises(ValueError, match='metadata differs'):
        bench.replay(manifest, output, 'fake', 'en', None)


def test_production_glossary_is_reset_on_every_batch_chunk(tmp_path, monkeypatch):
    monkeypatch.setenv('VELORA_FAKE_STT', '1')
    from types import SimpleNamespace
    import numpy as np
    from velora_engine import stt, media, config
    audio = tmp_path/'audio'; audio.mkdir()
    clip = audio/'clip.wav'; clip.write_bytes(b'private-fixture')
    manifest = tmp_path/'manifest.json'
    manifest.write_text(json.dumps({'audio_root':str(audio), 'cases':[
        {'id':1,'audio_path':'clip.wav','input_sha256':bench.digest(clip),'status':'available'}]}))
    home = tmp_path/'config'; home.mkdir(); (home/'config.json').write_text('{}')
    monkeypatch.setattr(config,'Config',lambda _:SimpleNamespace(
        user_vocabulary=['Velora'],learned_vocabulary=['Muse'],auto_vocabulary=[]))
    backend = SimpleNamespace(load=lambda:None,initial_prompt=None)
    observed=[]
    def transcribe(instance, chunk):
        observed.append(instance.initial_prompt)
        instance.initial_prompt = 'changed by intervening work'
        return 'fixture'
    monkeypatch.setattr(stt,'create_backend',lambda *args:backend)
    monkeypatch.setattr(stt,'transcribe_clip',transcribe)
    monkeypatch.setattr(media,'load_media',lambda _:np.zeros(32000,dtype=np.float32))
    monkeypatch.setattr(media,'split_for_batch',lambda pcm:[pcm[:16000],pcm[16000:]])
    output=tmp_path/'private'
    bench.replay(manifest,output,'fake','auto',None,home)
    assert observed==['Muse, Velora.','Muse, Velora.']
    info=json.loads((output/'stt-run.json').read_text())
    assert info['glossary']['mode'].startswith('production global')
    assert info['glossary']['sha256']


def test_glossary_replay_migrates_only_private_snapshot(tmp_path, monkeypatch):
    monkeypatch.setenv('VELORA_FAKE_STT', '1')
    audio = tmp_path / 'audio'; audio.mkdir()
    home = tmp_path / 'home'; home.mkdir()
    config = home / 'config.json'; config.write_text('{}')
    before = config.read_bytes()
    manifest = tmp_path / 'manifest.json'
    manifest.write_text(json.dumps({'audio_root': str(audio), 'cases': []}))
    output = tmp_path / 'out'
    bench.replay(manifest, output, 'fake', 'auto', None, home)
    assert config.read_bytes() == before
    assert not (home / 'modes').exists()
    assert (output / 'config-snapshot' / 'modes').is_dir()
    assert all(p.stat().st_mode & 0o777 == 0o600
               for p in (output / 'config-snapshot').rglob('*') if p.is_file())
    assert json.loads((output / 'config-snapshot' / 'config.json').read_text()).get('builtin_modes_rev')
    bench.replay(manifest, output, 'fake', 'auto', None, home)
    assert config.read_bytes() == before


def test_replay_rejects_stale_results_and_duplicate_manifest_before_load(tmp_path, monkeypatch):
    monkeypatch.setenv('VELORA_FAKE_STT', '1')
    audio = tmp_path / 'audio'; audio.mkdir()
    manifest = tmp_path / 'manifest.json'
    case = {'id': 1, 'input_sha256': 'frozen', 'status': 'missing_or_unsafe'}
    manifest.write_text(json.dumps({'audio_root': str(audio), 'cases': [case]}))
    output = tmp_path / 'out'
    bench.replay(manifest, output, 'fake', 'auto', None)
    results = output / 'stt.jsonl'
    original = results.read_text()
    from velora_engine import stt
    monkeypatch.setattr(stt, 'create_backend', lambda *args: pytest.fail('model loaded before validation'))
    for bad, message in [
        ({'id': 2, 'input_sha256': 'frozen'}, 'not in frozen manifest'),
        ({'id': 1, 'input_sha256': 'wrong'}, 'hash differs'),
    ]:
        results.write_text(json.dumps(bad) + '\n')
        with pytest.raises(ValueError, match=message):
            bench.replay(manifest, output, 'fake', 'auto', None)
    results.write_text(original + original)
    with pytest.raises(ValueError, match='duplicate result'):
        bench.replay(manifest, output, 'fake', 'auto', None)
    manifest.write_text(json.dumps({'audio_root': str(audio), 'cases': [case, case]}))
    with pytest.raises(ValueError, match='duplicate manifest'):
        bench.replay(manifest, tmp_path / 'other', 'fake', 'auto', None)
