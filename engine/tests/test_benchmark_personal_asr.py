"""CPU-only replay checks; no MLX import, model load, or personal data."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'benchmark_personal_asr.py'
spec = importlib.util.spec_from_file_location('personal_asr', SCRIPT)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def test_replay_confinement_resume_cap_and_offline(tmp_path, monkeypatch, capsys):
    audio = tmp_path / 'audio'
    audio.mkdir()
    good = audio / 'good.wav'
    good.write_bytes(b'fixture')
    (audio / 'link.wav').symlink_to(good)
    cases = [
        {'id': 1, 'audio_path': 'good.wav', 'input_sha256': bench.digest(good), 'status': 'available'},
        {'id': 2, 'audio_path': '../good.wav', 'input_sha256': 'x', 'status': 'available'},
        {'id': 3, 'audio_path': 'link.wav', 'input_sha256': bench.digest(good), 'status': 'available'},
        {'id': 4, 'audio_path': 'good.wav', 'input_sha256': 'changed', 'status': 'available'},
        {'id': 5, 'audio_path': 'good.wav', 'input_sha256': bench.digest(good), 'status': 'available'},
    ]
    manifest = tmp_path / 'manifest.json'
    manifest.write_text(json.dumps({'audio_root': str(audio), 'cases': cases}))
    monkeypatch.setattr(bench, 'provenance', lambda *args: {'manifest_sha256': bench.digest(manifest)})
    calls = []
    class Stub:
        def generate(self, pcm, **kwargs):
            calls.append(kwargs)
            n = 2048 if len(calls) == 2 else 20
            return SimpleNamespace(text='private transcript', generation_tokens=n, segments=[{'end': 1.0}])
    loaded = []
    def loader(path):
        assert bench.os.environ['HF_HUB_OFFLINE'] == '1'
        loaded.append(path)
        return Stub()
    model_path = tmp_path / 'model'
    model_path.mkdir()
    out = tmp_path / 'private'
    bench.replay(manifest, out, model_path, tmp_path, loader=loader, decode=lambda _: np.zeros(16000, dtype=np.float32))
    result = out / 'stt.jsonl'
    rows = [json.loads(line) for line in result.read_text().splitlines()]
    assert [r['status'] for r in rows] == ['ok', 'failed', 'failed', 'failed', 'length_limit']
    assert rows[0]['termination'] == 'unknown'
    assert calls[0] == {'max_tokens': 2048, 'chunk_duration': 30, 'language': None, 'temperature': 0, 'verbose': False}
    assert out.stat().st_mode & 0o777 == 0o700
    assert result.stat().st_mode & 0o777 == 0o600
    assert all(p.stat().st_mode & 0o777 == 0o600 for p in (out / 'cases').glob('*.json'))
    before = result.read_bytes()
    bench.replay(manifest, out, model_path, tmp_path, loader=loader, decode=lambda _: None)
    assert result.read_bytes() == before and len(loaded) == 1
    assert 'private transcript' not in capsys.readouterr().out
    manifest.write_text(json.dumps({'audio_root': str(audio), 'cases': cases[::-1]}))
    with pytest.raises(ValueError, match='provenance'):
        bench.replay(manifest, out, model_path, tmp_path, loader=loader, decode=lambda _: None)


def test_termination_requires_valid_segments():
    def output(tokens, end):
        return SimpleNamespace(text='ok', generation_tokens=tokens, segments=[{'end': end}])
    assert bench.assess(output(5, 1), 1)[-1] == 'unknown'
    assert bench.assess(output(2048, 1), 1)[-1] == 'length_limit'
    assert bench.assess(output(10, 0.4), 1)[-1] == 'incomplete_audio'
    with pytest.raises(ValueError):
        bench.assess(SimpleNamespace(text='x', generation_tokens=2, segments=None), 1)
