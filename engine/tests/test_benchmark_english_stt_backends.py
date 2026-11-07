import importlib.util
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import pytest

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('backend_bench', SCRIPTS / 'benchmark_english_stt_backends.py')
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)


def test_cases_warmup_one_model_timing_and_partial():
    rows = [{'id':'a','speaker_id':'p','accent_label':'x','audio':'a'}, {'id':'b','speaker_id':'q','accent_label':'y','audio':'b'}]
    ticks = iter([0., 1., 3., 10., 11., 14., 20., 21.])
    model = object(); seen = []
    def transcribe(instance, pcm):
        assert instance is model
        seen.append(pcm)
        if pcm == 'b': raise RuntimeError('decode failed')
        return 'hello'
    cases, warmup = b.run_cases(rows, Path('/input'), 'ffmpeg', model, transcribe, warmup_first=True,
                                clock=lambda: next(ticks), convert=lambda _, path: path.name)
    assert seen == ['a','a','b']
    assert warmup['preprocess_s'] == 1 and warmup['transcribe_s'] == 2
    assert cases[0]['preprocess_s'] == 1 and cases[0]['transcribe_s'] == 3
    assert cases[1]['status'] == 'failed' and 'decode failed' in cases[1]['error']


def test_snapshot_requires_revision_and_weight_inventory(tmp_path):
    revision = 'a' * 40
    model = tmp_path / 'snapshots' / revision; model.mkdir(parents=True)
    (model / 'config.json').write_text('{"quantization":null}')
    header = json.dumps({'weight':{'dtype':'F16','shape':[1],'data_offsets':[0,2]}}).encode()
    (model / 'model.safetensors').write_bytes(len(header).to_bytes(8,'little') + header + b'xx')
    path, config = b.snapshot(model)
    assert path == model and config['quantization'] is None
    assert b.weight_inventory(model)['model.safetensors']['tensor_dtypes'] == {'F16':1}
    with pytest.raises(ValueError, match='snapshot'): b.snapshot(tmp_path)


def test_fake_and_collision_refuse(tmp_path, monkeypatch):
    monkeypatch.setenv('VELORA_FAKE_STT', '1')
    with pytest.raises(ValueError, match='FAKE'): b.run(SimpleNamespace())
    out = tmp_path / 'private' / 'out.json'; out.parent.mkdir(mode=0o700); out.write_text('keep')
    with pytest.raises(FileExistsError):
        b.main(['--backend','parakeet','--model-id','id','--model-path','x','--manifest','x','--output',str(out)])
    assert out.read_text() == 'keep'


def test_provenance_change_marks_integrity_failed(tmp_path, monkeypatch):
    model = tmp_path / 'snapshots' / ('b'*40); model.mkdir(parents=True)
    (model / 'config.json').write_text('{}')
    header = json.dumps({'weight':{'dtype':'F16','shape':[1],'data_offsets':[0,2]}}).encode()
    (model / 'model.safetensors').write_bytes(len(header).to_bytes(8,'little') + header + b'xx')
    mf = tmp_path / 'manifest'; mf.write_text('x')
    row = {'id':'a','speaker_id':'p','accent_label':'x','audio':'a','sha256':{'audio':'a','transcript':'b'}}
    monkeypatch.setattr(b.common, 'verify_manifest', lambda _: ({'rows':[row]},'hash'))
    monkeypatch.setattr(b.shutil, 'which', lambda _: '/bin/echo')
    ids = iter([{'hash':'before'}, {'hash':'after'}]); monkeypatch.setattr(b, 'identities', lambda *a: next(ids))
    monkeypatch.setattr(b.metadata, 'version', lambda _: 'test')
    monkeypatch.setattr(b, 'load_backend', lambda *a: (object(), lambda *_: 'text', object()))
    monkeypatch.setattr(b, 'memory_snapshot', lambda _: {})
    monkeypatch.setattr(b, 'run_cases', lambda *a, **kw: ([{'status':'ok','preprocess_s':1.,'transcribe_s':2.}],None))
    result = b.run(SimpleNamespace(manifest=mf,model_path=model,backend='parakeet',model_id='id',warmup_first=False))
    assert result['status'] == 'integrity_failed' and result['integrity'] == 'failed'


def test_help_blocks_heavy_imports():
    code = """import builtins,runpy,sys
old=builtins.__import__
def guarded(name,*a,**kw):
 if name.split('.')[0] in {'mlx','mlx_whisper','parakeet_mlx','numpy'}: raise RuntimeError(name)
 return old(name,*a,**kw)
builtins.__import__=guarded
sys.path.insert(0,sys.argv[1]); sys.argv=[sys.argv[2],'--help'];runpy.run_path(sys.argv[0],run_name='__main__')
"""
    r = subprocess.run([sys.executable,'-c',code,str(SCRIPTS),str(SCRIPTS/'benchmark_english_stt_backends.py')],capture_output=True,text=True)
    assert r.returncode == 0 and '--warmup-first' in r.stdout


def test_timed_cases_counts_empty_decodes_and_dtype_is_expected(tmp_path, monkeypatch):
    model = tmp_path / 'snapshots' / ('c'*40); model.mkdir(parents=True)
    (model / 'config.json').write_text('{}')
    header = json.dumps({'weight':{'dtype':'F16','shape':[1],'data_offsets':[0,2]}}).encode()
    (model / 'model.safetensors').write_bytes(len(header).to_bytes(8,'little') + header + b'xx')
    mf = tmp_path / 'manifest'; mf.write_text('x')
    row = {'id':'a','speaker_id':'p','accent_label':'x','audio':'a','sha256':{'audio':'a','transcript':'b'}}
    monkeypatch.setattr(b.common, 'verify_manifest', lambda _: ({'rows':[row]},'hash'))
    monkeypatch.setattr(b.shutil, 'which', lambda _: '/bin/echo')
    monkeypatch.setattr(b, 'identities', lambda *a: {'hash':'same'})
    monkeypatch.setattr(b.metadata, 'version', lambda _: 'test')
    monkeypatch.setattr(b, 'load_backend', lambda *a: (object(), lambda *_: 'text', object()))
    monkeypatch.setattr(b, 'memory_snapshot', lambda _: {})
    monkeypatch.setattr(b, 'run_cases', lambda *a, **kw: ([
        {'status':'ok','preprocess_s':1.,'transcribe_s':2.},
        {'status':'empty','preprocess_s':3.,'transcribe_s':4.},
        {'status':'failed'}], None))
    report = b.run(SimpleNamespace(manifest=mf,model_path=model,backend='parakeet',model_id='id',warmup_first=False))
    assert report['status'] == 'partial'
    assert report['timing_totals'] == {'successful_cases':1, 'timed_cases':2, 'preprocess_s':4., 'transcribe_s':6.}
    assert report['expected_load_dtype'] == 'bfloat16' and 'load_dtype' not in report
