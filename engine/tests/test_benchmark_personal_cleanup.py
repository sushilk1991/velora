"""Personal cleanup replay is isolated, complete and resumable."""
import asyncio
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'benchmark_personal_cleanup.py'
spec = importlib.util.spec_from_file_location('personal_cleanup', SCRIPT)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def test_stt_provenance_requires_production_glossary_and_frozen_config(tmp_path):
    from velora_engine.stt import build_glossary_prompt
    manifest=tmp_path/'manifest.json';manifest.write_text('{"cases":[]}')
    stt=tmp_path/'stt.jsonl';stt.write_text('')
    metadata=tmp_path/'stt-run.json'
    config=SimpleNamespace(user_vocabulary=['Velora'],learned_vocabulary=[],auto_vocabulary=[])
    prompt=build_glossary_prompt(config.user_vocabulary,[],[],[])
    info={'manifest_sha256':bench.digest(manifest),'model':'mlx-community/whisper-large-v3-turbo',
        'model_files_sha256':{'weights.npz':'a'*64},'glossary':{
            'mode':'production global glossary; no historical screen entities',
            'sha256':bench.hashlib.sha256(prompt.encode()).hexdigest(),
            'source_sha256':{'config.json':'b'*64}}}
    metadata.write_text(json.dumps(info))
    assert bench.validate_stt_provenance(manifest,stt,metadata,config)==info
    wrong=SimpleNamespace(user_vocabulary=[],learned_vocabulary=[],auto_vocabulary=[])
    with pytest.raises(ValueError,match='frozen cleanup config'):
        bench.validate_stt_provenance(manifest,stt,metadata,wrong)
    for key,value in [('glossary','none; explicit unbiased reference/control pass'),
                      ('model_files_sha256',{}),('manifest_sha256','0'*64),('model','other')]:
        metadata.write_text(json.dumps({**info,key:value}))
        with pytest.raises(ValueError,match='STT metadata'):
            bench.validate_stt_provenance(manifest,stt,metadata,config)
    metadata.write_text(json.dumps(info))
    other=tmp_path/'elsewhere';other.mkdir()
    copied=other/'stt-run.json';copied.write_text(json.dumps(info))
    with pytest.raises(ValueError,match='original paired'):
        bench.validate_stt_provenance(manifest,stt,copied,config)


def test_read_inputs_requires_full_matching_cohort(tmp_path):
    manifest = tmp_path/'manifest.json'
    stt = tmp_path/'stt.jsonl'
    manifest.write_text(json.dumps({'cases': [{'id': 1, 'input_sha256': 'x'}, {'id': 2, 'input_sha256': 'y'}]}))
    stt.write_text(json.dumps({'id': 1, 'input_sha256': 'x'}) + '\n')
    with pytest.raises(ValueError, match='every frozen case'):
        bench.read_inputs(manifest, stt)
    stt.write_text('\n'.join(json.dumps(x) for x in [
        {'id': 1, 'input_sha256': 'wrong'}, {'id': 2, 'input_sha256': 'y'}]))
    with pytest.raises(ValueError, match='hash differs'):
        bench.read_inputs(manifest, stt)


def test_replay_snapshots_and_resumes_without_model_or_history(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(bench, 'write_end_resources', lambda *a: None)
    from velora_engine import cleanup
    class Fake:
        loaded = True
        unhealthy = False
        loads = 0
        token_settings = []
        def __init__(self, model, local_model_path):
            pass
        async def load_async(self, prompt):
            Fake.loads += 1
            Fake.token_settings.append(cleanup.COPY_DRAFT_PASS_TOKENS)
        async def cleanup(self, raw, prompt, **kwargs):
            return cleanup.CleanupResult(raw + '.', True, 7, output_tokens=9, _latency_ns={'sample': 4})
        def close(self):
            pass
    monkeypatch.setattr(cleanup, 'CleanupEngine', Fake)
    home = tmp_path/'home'
    home.mkdir()
    (home/'config.json').write_text(json.dumps({'cleanup_enabled': True}))
    original = (home/'config.json').read_bytes()
    model = tmp_path/'model'
    model.mkdir()
    (model/'weight').write_bytes(b'weights')
    manifest = tmp_path/'manifest.json'
    manifest.write_text(json.dumps({'cases': [
        {'id': 1, 'input_sha256': 'x', 'mode': 'Default', 'bundle_id': None, 'app_name': None},
        {'id': 2, 'input_sha256': 'y', 'mode': None, 'bundle_id': None, 'app_name': None},
        {'id': 3, 'input_sha256': 'z', 'mode': 'Default', 'bundle_id': None, 'app_name': None},
    ]}))
    stt = tmp_path/'stt.jsonl'
    stt.write_text('\n'.join(json.dumps(x) for x in [
        {'id': 1, 'input_sha256': 'x', 'status': 'ok', 'raw': 'this is a longer phrase that needs cleanup and punctuation please', 'stt_s': 2.0},
        {'id': 2, 'input_sha256': 'y', 'status': 'failed', 'stt_s': None},
        {'id': 3, 'input_sha256': 'z', 'status': 'ok', 'raw': 'This is a longer sentence for testing. ' * 100, 'stt_s': 3.0},
    ]))
    output = tmp_path/'out'
    args = (manifest, stt, output, home, 'fake', model)
    asyncio.run(bench.replay(*args))
    rows = [json.loads(p.read_text()) for p in (output/'cases').glob('*.json')]
    rows.sort(key=lambda x: x['id'])
    assert rows[0]['status'] == 'ok'
    assert rows[0]['calls'] and rows[0]['calls'][0]['eos'] == 'not_exposed'
    assert rows[0]['paired_stt_cleanup_s'] >= 2.0
    assert rows[1]['status'] == 'stt_failed'
    assert rows[2]['status'] == 'ok' and len(rows[2]['calls']) > 1
    assert (home/'config.json').read_bytes() == original
    assert output.stat().st_mode & 0o777 == 0o700
    assert all(p.stat().st_mode & 0o777 == 0o600 for p in (output/'cases').glob('*.json'))
    prior = {p.name: p.read_bytes() for p in (output/'cases').glob('*.json')}
    asyncio.run(bench.replay(*args))
    assert prior == {p.name: p.read_bytes() for p in (output/'cases').glob('*.json')}
    assert 'longer phrase' not in capsys.readouterr().out
    stale = output/'cases'/'extra.json'
    stale.write_text(json.dumps({'id': 999, 'status': 'ok'}))
    with pytest.raises(ValueError, match='unexpected or unsafe'):
        asyncio.run(bench.replay(*args))
    stale.unlink()
    target = next((output/'cases').glob('*.json'))
    saved = target.read_bytes()
    target.unlink()
    target.symlink_to(output/'cleanup-run.json')
    with pytest.raises(ValueError, match='unexpected or unsafe'):
        asyncio.run(bench.replay(*args))
    target.unlink(); target.write_bytes(saved)
    smoke = tmp_path/'smoke'
    asyncio.run(bench.replay(manifest, stt, smoke, home, 'fake', model, 6, 1, True))
    meta = json.loads((smoke/'cleanup-run.json').read_text())
    assert (meta['copy_draft_tokens'], meta['trace'], meta['limit'], meta['case_count']) == (6, True, 1, 1)
    assert Fake.token_settings[-1] == 6
    smoke_rows = [json.loads(p.read_text()) for p in (smoke/'cases').glob('*.json')]
    assert len(smoke_rows) == 1
    assert smoke_rows[0]['calls'][0]['_latency_ns'] == {'sample': 4}
    with pytest.raises(ValueError, match='provenance changed'):
        asyncio.run(bench.replay(manifest, stt, smoke, home, 'fake', model, 3, 1, True))
    (model/'weight').write_bytes(b'changed')
    with pytest.raises(ValueError, match='provenance changed'):
        asyncio.run(bench.replay(*args))


def test_partial_piece_cleanup_is_not_a_full_fallback():
    calls = [{'reason': None}, {'reason': 'timeout'}]
    assert bench.cleanup_status(calls, False, 'partial_cleanup') == 'cleanup_partial'
    assert bench.cleanup_status(calls, False, 'cleanup_unavailable') == 'cleanup_fallback'
    assert bench.cleanup_status(calls, True, 'chunked') == 'ok'
