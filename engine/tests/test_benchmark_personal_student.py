"""CPU-only contracts for private student replay; no model or private corpus."""
import asyncio
import importlib.util
import json
import sys
from pathlib import Path
from types import SimpleNamespace
import pytest

SCRIPT = Path(__file__).resolve().parents[1]/'scripts'/'benchmark_personal_student.py'
sys.path.insert(0, str(SCRIPT.parent))
spec=importlib.util.spec_from_file_location('personal_student',SCRIPT)
bench=importlib.util.module_from_spec(spec);spec.loader.exec_module(bench)

class Tokenizer:
    bos_token = None
    def apply_chat_template(self, messages, **kwargs):
        assert kwargs == {'tokenize':False,'add_generation_prompt':True,'enable_thinking':False}
        self.messages=messages
        return json.dumps(messages,ensure_ascii=False)
    def encode(self,text,**kwargs): return list(text)


def adapter(text,finish='stop',max_input=10000):
    tok=Tokenizer()
    def stream(*args,**kwargs):
        yield SimpleNamespace(text=text,finish_reason=finish,generation_tokens=len(text))
    return bench.StudentCleanup(None,tok,stream,None,max_output=1024,max_input=max_input),tok


def config(tmp_path, **overrides):
    from velora_engine.config import Config
    home=tmp_path/'home';home.mkdir()
    (home/'config.json').write_text(json.dumps({'cleanup_enabled':True,**overrides}))
    return Config(home)


def test_context_is_from_resolved_mode_and_config(tmp_path):
    cfg=config(tmp_path, language='hi',romanize_output=True,vocabulary=['Asha'])
    gate,ctx=bench.controls(cfg,'आज मुझे बाज़ार जाना है और बाद में खाना बनाना है',{'mode':'Default'})
    assert gate.use_llm and ctx['romanize'] and ctx['language']=='hi'
    assert 'Asha' in ctx['vocabulary'] and ctx['mode']=='default'
    assert gate.system_prompt


def test_off_short_and_shell_paths_never_call_student(tmp_path):
    cfg=config(tmp_path)
    student,tok=adapter('unexpected')
    calls=bench.InstrumentedCleanup(student);server=bench.make_server(cfg,calls)
    for raw,mode in [('hello','Default'),('git status','Terminal'),('hello world','Raw')]:
        gate,ctx=bench.controls(cfg,raw,{'mode':mode});student.set_context(gate,ctx)
        result=asyncio.run(server._apply_formatting(raw,None,None,mode))
        assert not result[3]
    assert not calls.calls


def test_generation_renders_controls_preserves_piece_suffix_and_rejects_length():
    student,tok=adapter('partial','length')
    gate=SimpleNamespace(system_prompt='stable system')
    student.set_context(gate,{'mode':'default','language':'hi','romanize':False,'instructions':'Keep names','vocabulary':['Asha']})
    raw='Asha has not sent the report yet'
    result=asyncio.run(student.cleanup(raw,'stable system\n\nPrevious text (context only, do NOT repeat it): «Hello».',timeout_ms=20000))
    assert not result.applied and result.reason=='length' and result.text==raw
    payload=json.loads(tok.messages[1]['content'])
    assert payload['transcript']==raw and payload['language']=='hi' and payload['vocabulary']==['Asha']
    assert 'Previous text' in payload['instructions']
    with pytest.raises(ValueError,match='does not match'):
        asyncio.run(student.cleanup(raw,'different prompt',timeout_ms=20000))


def test_guards_empty_output_and_input_cap():
    student,_=adapter('')
    student.set_context(SimpleNamespace(system_prompt='s'),{'mode':'default','language':'en','romanize':True,'instructions':'','vocabulary':[]})
    result=asyncio.run(student.cleanup('hello world','s',check_ratio=False,timeout_ms=20000))
    assert not result.applied and result.reason=='empty_output'
    student,_=adapter('unseen',max_input=3)
    student.set_context(SimpleNamespace(system_prompt='s'),{'mode':'default','language':'en','romanize':False,'instructions':'','vocabulary':[]})
    result=asyncio.run(student.cleanup('hello world','s',timeout_ms=20000))
    assert result.reason=='context_limit' and result.text=='hello world'


def test_provenance_resume_and_local_model_restriction(tmp_path):
    bench.verify_resume({'x':1,'y':2},{'x':1})
    with pytest.raises(ValueError,match='provenance changed'):bench.verify_resume({'x':2},{'x':1})
    with pytest.raises(ValueError,match='audited'):bench.local_snapshot(tmp_path,'0'*40)
    with pytest.raises(ValueError,match='existing local'):bench.local_snapshot(tmp_path/'absent',next(iter(bench.AUDITED_REVISIONS)))


def test_full_replay_private_resume_and_long_pieces(tmp_path,monkeypatch,capsys):
    from types import ModuleType
    from contextlib import nullcontext
    cfg_home=tmp_path/'source';cfg_home.mkdir()
    (cfg_home/'config.json').write_text(json.dumps({'cleanup_enabled':True}))
    manifest=tmp_path/'manifest.json'
    cases=[{'id':1,'input_sha256':'a','mode':'Default'},
           {'id':2,'input_sha256':'b','mode':'Terminal'},
           {'id':3,'input_sha256':'c','mode':'Default'}]
    manifest.write_text(json.dumps({'cases':cases}))
    stt_dir=tmp_path/'stt';stt_dir.mkdir();stt=stt_dir/'stt.jsonl'
    stt.write_text('\n'.join(json.dumps(x) for x in [
        {'id':1,'input_sha256':'a','status':'ok','raw':'This sentence contains enough words for the formatting model to run','stt_s':1},
        {'id':2,'input_sha256':'b','status':'ok','raw':'git status','stt_s':2},
        {'id':3,'input_sha256':'c','status':'ok','raw':'This is a longer sentence for testing. '*100,'stt_s':3}]))
    stt_meta=stt_dir/'stt-run.json'
    stt_meta.write_text(json.dumps({'manifest_sha256':bench.digest(manifest),'model':'mlx-community/whisper-large-v3-turbo',
        'model_files_sha256':{'weights.npz':'f'*64}, 'glossary':{
            'mode':'production global glossary; no historical screen entities',
            'sha256':bench.hashlib.sha256(b'').hexdigest(),
            'source_sha256':{'config.json':bench.digest(cfg_home/'config.json')}}}))
    model_dir=tmp_path/'model';model_dir.mkdir(); (model_dir/'weight').write_text('weights')
    monkeypatch.setattr(bench,'local_snapshot',lambda p,r:(str(model_dir),{'weight':'pinned'}))
    monkeypatch.setattr(bench,'load_local_snapshot',lambda *a:(None,Tokenizer()))
    monkeypatch.setattr(bench,'lfm3_architecture',lambda *a:nullcontext())
    monkeypatch.setattr(bench,'configure_student_allocator',lambda:512*1024*1024)
    monkeypatch.setattr(bench,'write_end_resources',lambda *a:None)
    monkeypatch.setattr(bench.importlib.metadata,'version',lambda _: 'test-version')
    mlx=ModuleType('mlx_lm');samplers=ModuleType('mlx_lm.sample_utils')
    def generate(model,tok,prompt,max_tokens,sampler):
        messages=json.loads(prompt);payload=json.loads(messages[1]['content'])
        yield SimpleNamespace(text=payload['transcript'],finish_reason='stop',generation_tokens=1)
    mlx.stream_generate=generate;samplers.make_sampler=lambda **kw:None
    monkeypatch.setitem(sys.modules,'mlx_lm',mlx);monkeypatch.setitem(sys.modules,'mlx_lm.sample_utils',samplers)
    args=SimpleNamespace(manifest=manifest,stt=stt,stt_meta=stt_meta,output=tmp_path/'out',
        config_home=cfg_home,base=model_dir,base_revision='a'*40,adapter=None,lfm_port=None,
        max_output=1024,max_input=10000,limit=None,decoder='stream',copy_draft_tokens=3)
    asyncio.run(bench.replay(args))
    rows=sorted((json.loads(p.read_text()) for p in (args.output/'cases').glob('*.json')),key=lambda x:x['id'])
    assert len(rows)==3 and all(x['status']=='ok' for x in rows)
    assert rows[0]['calls'] and not rows[1]['calls'] and len(rows[2]['calls'])>1
    assert args.output.stat().st_mode & 0o777 == 0o700
    assert all(p.stat().st_mode & 0o777 == 0o600 for p in (args.output/'cases').glob('*.json'))
    prior={p.name:p.read_bytes() for p in (args.output/'cases').glob('*.json')}
    asyncio.run(bench.replay(args))
    assert prior=={p.name:p.read_bytes() for p in (args.output/'cases').glob('*.json')}
    assert 'sentence contains' not in capsys.readouterr().out
    stt_meta.write_text(json.dumps({'manifest_sha256':bench.digest(manifest),'model':'other'}))
    with pytest.raises(ValueError,match='STT metadata'):
        asyncio.run(bench.replay(args))


def test_generation_error_falls_back_and_divergence_is_guarded():
    student,_=adapter('an entirely unrelated output full of invented things')
    ctx={'mode':'default','language':'en','romanize':False,'instructions':'','vocabulary':[]}
    student.set_context(SimpleNamespace(system_prompt='s'),ctx)
    raw='Please keep the garden gate closed this evening'
    result=asyncio.run(student.cleanup(raw,'s',timeout_ms=20000))
    assert not result.applied and result.text==raw
    def broken(*a,**kw):
        raise RuntimeError('failure')
        yield
    student.stream=broken
    result=asyncio.run(student.cleanup(raw,'s',timeout_ms=20000))
    assert not result.applied and result.text==raw and result.reason=='generation_error'


def test_mixed_long_piece_cleanup_keeps_partial_status(tmp_path):
    cfg=config(tmp_path)
    student,tok=adapter('unused')
    generated=0
    def partly_fails(model,tokenizer,prompt,max_tokens,sampler):
        nonlocal generated
        generated+=1
        payload=json.loads(json.loads(prompt)[1]['content'])
        yield SimpleNamespace(text=payload['transcript'],
            finish_reason='length' if generated in (2,3) else 'stop',generation_tokens=1)
    student.stream=partly_fails
    calls=bench.InstrumentedCleanup(student);server=bench.make_server(cfg,calls)
    raw='This is a longer sentence for testing. '*100
    gate,ctx=bench.controls(cfg,raw,{'mode':'Default'});student.set_context(gate,ctx)
    result=asyncio.run(server._apply_formatting(raw,None,None,'Default'))
    assert len(calls.calls)>1 and any(c['applied'] for c in calls.calls) and any(not c['applied'] for c in calls.calls)
    assert not result[3] and result[4]=='partial_cleanup'
    assert bench.cleanup_status(calls.calls,result[3],result[4])=='cleanup_partial'
    assert bench.cleanup_status([{'applied':False}],False,'length')=='cleanup_fallback'
    assert bench.cleanup_status([{'applied':False},{'applied':True}],True,'chunked')=='ok'
    assert bench.cleanup_status([],False,'off')=='ok'


def test_stream_results_report_injected_memory_including_rejected_calls():
    student,_=adapter('unchanged')
    student.memory_provider=lambda:{'mlx_active_bytes':123,'mlx_peak_bytes':456,'mlx_cache_bytes':78}
    student.set_context(SimpleNamespace(system_prompt='s'),{'mode':'default','language':'en','romanize':False,'instructions':'','vocabulary':[]})
    student.max_input=1
    result=asyncio.run(student.cleanup('hello world','s',timeout_ms=20000))
    assert result.reason=='context_limit'
    assert (result.mlx_active_bytes,result.mlx_peak_bytes,result.mlx_cache_bytes)==(123,456,78)


@pytest.mark.parametrize('failure', ['timeout', 'cancelled'])
def test_stream_failure_keeps_generated_token_count(monkeypatch, failure):
    from threading import Event
    student, _ = adapter('unused')
    student.set_context(SimpleNamespace(system_prompt='s'),
        {'mode':'default','language':'en','romanize':False,'instructions':'','vocabulary':[]})
    cancel = Event()
    now = [0.0]
    monkeypatch.setattr(bench.time, 'perf_counter', lambda: now[0])
    def stream(*args, **kwargs):
        for count in range(1, 4):
            if count == 3:
                if failure == 'cancelled': cancel.set()
                else: now[0] = 2.0
            yield SimpleNamespace(text='x',finish_reason=None,generation_tokens=count)
    student.stream = stream
    raw = 'please retain this raw transcript'
    result = asyncio.run(student.cleanup(raw, 's', timeout_ms=1000, cancel_event=cancel))
    assert not result.applied and result.text == raw and result.reason == failure
    assert result.output_tokens == 3
