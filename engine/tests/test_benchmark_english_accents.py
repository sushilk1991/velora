import importlib.util
import json
from pathlib import Path
import subprocess
import sys

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/benchmark_english_accents.py'
spec = importlib.util.spec_from_file_location('accent_bench', SCRIPT)
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


def test_alignment_decomposes_repair_damage_and_insertion():
    result = b.compare('one two three four', 'one wrong three four', 'one two changed four extra')
    assert result['repaired_reference_positions'] == [1]
    assert result['damaged_reference_positions'] == [2]
    assert result['insertion_delta'] == 1
    assert result['error_delta'] == 1
    assert result['before']['wer'] == .25 and result['after']['wer'] == .5


def test_alignment_repeated_tokens_is_deterministic_and_empty_is_defined():
    assert b.align('a a', 'a')['reference_states'] == ['deletion', 'match']
    assert b.align('Hello, WORLD!', 'hello world')['errors'] == 0
    assert b.align('', 'extra')['wer'] is None
    assert b.align('', 'extra')['insertions'] == 1
    assert b.align('x', '')['reference_states'] == ['deletion']
    assert b.compare('', '', '')['error_delta'] == 0


def corpus(tmp_path):
    (tmp_path / 'audio.flac').write_bytes(b'audio')
    (tmp_path / 'ref.txt').write_text('one two')
    row = {'id': 'sample', 'speaker_id': 'p1', 'accent_label': 'test', 'audio': 'audio.flac', 'transcript': 'ref.txt',
           'sha256': {'audio': b.digest(tmp_path / 'audio.flac'), 'transcript': b.digest(tmp_path / 'ref.txt')}}
    manifest = tmp_path / 'manifest.json'
    manifest.write_text(json.dumps({'rows': [row]}))
    return manifest


def recognition_identity():
    return {'model_files_sha256': {'model.safetensors': 'a' * 64}, 'source_sha256': {'stt.py': 'b' * 64}}


def test_score_only_and_tamper_and_private_collision(tmp_path):
    manifest = corpus(tmp_path)
    recognition = tmp_path / 'recognition.json'
    recognition.write_text(json.dumps({'status':'complete', 'integrity':'verified', 'manifest_sha256':b.digest(manifest),
                                       'model_id':'wrong-unverified-label', 'model_path':'/cache/snapshots/' + 'c' * 40,
                                       'identity_before':recognition_identity(), 'identity_after':recognition_identity(),
                                       'cases':[{'id':'sample','status':'ok','text':'one wrong'}]}))
    candidate = tmp_path / 'candidate.json'
    candidate.write_text(json.dumps([{'id':'sample','text':'one two'}]))
    result = b.score(manifest, recognition, candidate)
    assert result['cases'][0]['metrics']['repaired_reference_positions'] == [1]
    model = result['recognition_model']
    assert model['model_id'] == 'wrong-unverified-label' and 'unverified' in model['model_id_role']
    assert model['snapshot_revision'] == 'c' * 40
    assert model['model_files_sha256'] == recognition_identity()['model_files_sha256']
    assert result['recognition_sha256'] == b.digest(recognition)
    output = tmp_path / 'private' / 'score.json'
    assert b.main(['--manifest',str(manifest),'--output',str(output),'--score-only',str(recognition),'--candidate',str(candidate)]) == 0
    assert output.stat().st_mode & 0o777 == 0o600
    assert output.parent.stat().st_mode & 0o777 == 0o700
    with pytest.raises(FileExistsError):
        b.main(['--manifest',str(manifest),'--output',str(output),'--score-only',str(recognition),'--candidate',str(candidate)])
    (tmp_path / 'ref.txt').write_text('tampered')
    with pytest.raises(ValueError, match='checksum'):
        b.score(manifest, recognition, candidate)


def test_score_rejects_failed_missing_and_duplicate_cases(tmp_path):
    manifest = corpus(tmp_path)
    recognition = tmp_path / 'r.json'; candidate = tmp_path / 'c.json'
    recognition.write_text(json.dumps({'status':'partial','manifest_sha256':b.digest(manifest),'cases':[]}))
    candidate.write_text('[]')
    with pytest.raises(ValueError, match='incomplete'): b.score(manifest, recognition, candidate)
    recognition.write_text(json.dumps({'status':'complete','integrity':'verified','manifest_sha256':b.digest(manifest),'identity_before':recognition_identity(),'identity_after':recognition_identity(),'cases':[{'id':'sample','status':'failed','text':''}]}))
    candidate.write_text(json.dumps([{'id':'sample','text':''}]))
    with pytest.raises(ValueError, match='successful'): b.score(manifest, recognition, candidate)
    candidate.write_text(json.dumps([{'id':'sample','text':''},{'id':'sample','text':''}]))
    with pytest.raises(ValueError, match='duplicate'): b.score(manifest, recognition, candidate)


def test_help_has_no_heavy_imports():
    code = """import builtins, runpy, sys
old = builtins.__import__
def guarded(name, *a, **kw):
    if name.split('.')[0] in {'mlx','mlx_whisper','numpy'}: raise RuntimeError(name)
    return old(name, *a, **kw)
builtins.__import__ = guarded
sys.argv = [sys.argv[1], '--help']
runpy.run_path(sys.argv[0], run_name='__main__')
"""
    result = subprocess.run([sys.executable, '-c', code, str(SCRIPT)], capture_output=True, text=True)
    assert result.returncode == 0 and '--score-only' in result.stdout


def test_score_rejects_missing_or_changed_model_hashes_and_backend_compatibility(tmp_path):
    manifest = corpus(tmp_path)
    recognition, candidate = tmp_path / 'r.json', tmp_path / 'c.json'
    candidate.write_text(json.dumps([{'id':'sample','text':'one two'}]))
    original = {'status':'complete', 'integrity':'verified', 'manifest_sha256':b.digest(manifest),
                'model_id':'parakeet-label', 'model_path':'/cache/snapshots/' + 'd' * 40,
                'snapshot_revision':'d' * 40, 'identity_before':recognition_identity(),
                'identity_after':recognition_identity(), 'cases':[{'id':'sample','status':'ok','text':'one two'}]}
    recognition.write_text(json.dumps(original))
    assert b.score(manifest, recognition, candidate)['recognition_model']['snapshot_revision'] == 'd' * 40
    original['identity_after']['model_files_sha256']['model.safetensors'] = 'e' * 64
    recognition.write_text(json.dumps(original))
    with pytest.raises(ValueError, match='identity missing or changed'): b.score(manifest, recognition, candidate)
    original.pop('identity_before')
    recognition.write_text(json.dumps(original))
    with pytest.raises(ValueError, match='identity missing or changed'): b.score(manifest, recognition, candidate)
