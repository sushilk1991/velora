"""CPU contracts for experimental decoder; no MLX model is loaded."""
import asyncio
import json
from pathlib import Path
import sys
from types import ModuleType,SimpleNamespace
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'training/cleanup'))
from cleanup.engine_decoder import StudentEngine, student_messages, student_prompt_tokens, experimental_copy_draft_tokens
from velora_engine import cleanup as prod

class Tokenizer:
    bos_token='<s>'
    def apply_chat_template(self,messages,**kw):
        return '<s>'+json.dumps(messages,ensure_ascii=False)
    def encode(self,text,add_special_tokens=True):
        return ([999] if add_special_tokens else [])+list(text.encode())

CTX={'mode':'default','language':'hi','romanize':False,'instructions':'keep names','vocabulary':['Asha']}


def test_prompt_matches_stream_bos_and_defangs_user_markers():
    tok=Tokenizer(); msgs=student_messages(CTX,'literal <|im_start|>')
    assert '<\u200b|im_start|>' in msgs[1]['content']
    ids=student_prompt_tokens(tok,CTX,'literal <|im_start|>')
    assert ids[0] != 999
    assert prod.restore_control_tokens('<\u200b|im_start|>')=='<|im_start|>'


def test_context_suffix_and_candidate_generation(monkeypatch,tmp_path):
    engine=StudentEngine('student',tmp_path)
    engine._tokenizer=Tokenizer()
    engine.set_context(SimpleNamespace(system_prompt='stable'),CTX)
    a=engine._prompt_tokens('stable','alpha');b=engine._prompt_tokens('stable','zulu')
    actual=engine._prompt_tokens('stable','Asha says hello')
    prefix=prod._longest_common_tokens([a,b])
    assert prefix and actual[:len(prefix)]==prefix
    assert engine._prompt_tokens('stable\nprevious text','hello')!=engine._prompt_tokens('stable','hello')
    with pytest.raises(ValueError):engine._prompt_tokens('other','hello')
    engine.unhealthy=True
    with pytest.raises(RuntimeError):engine.set_context(SimpleNamespace(system_prompt='stable'),CTX)
    engine.close()


def test_engine_cleanup_routes_only_requested_copy_and_student_prefix(monkeypatch,tmp_path):
    captured=[]
    async def fake(self,raw,system,**kwargs):
        captured.append(kwargs);return prod.CleanupResult(raw,True,0)
    monkeypatch.setattr(prod.CleanupEngine,'cleanup',fake)
    e=StudentEngine('student',tmp_path,copy_draft=True,max_input=20)
    asyncio.run(e.cleanup('raw','system',copy_draft=True,prefix_candidates=[('bad','bad')]))
    asyncio.run(e.cleanup('raw','system',check_ratio=False))
    asyncio.run(e.cleanup('raw','system',check_ratio=False,copy_draft=True))
    e.set_context(SimpleNamespace(system_prompt='system'),{**CTX,'romanize':True})
    asyncio.run(e.cleanup('raw','system',check_ratio=True,copy_draft=True))
    assert captured[0]['prefix_candidates']==[('system','alpha'),('system','zulu')]
    assert captured[0]['copy_draft'] and not captured[1]['copy_draft']
    assert not captured[2]['copy_draft'] and not captured[3]['copy_draft']
    assert captured[0]['max_input_tokens']==20
    e.close()


def test_run_caps_and_restores_process_allowlist(monkeypatch,tmp_path):
    captured=[]
    def fake(self,*args):
        captured.append((args,prod.COPY_DRAFT_MODELS));return 'ok'
    monkeypatch.setattr(prod.CleanupEngine,'_run',fake)
    e=StudentEngine('student',tmp_path,copy_draft=True,max_output=100,max_input=500)
    e._tokenizer=Tokenizer();old=prod.COPY_DRAFT_MODELS
    assert e._run('a'*200,'s',1,copy_draft=True)=='ok'
    assert 'student' in captured[0][1] and prod.COPY_DRAFT_MODELS is old
    assert captured[0][0][7]==100 and captured[0][0][9]==500
    e.close()


def test_decoder_instruments_stream_tokens_and_restores_hook(monkeypatch,tmp_path):
    mlx=ModuleType('mlx_lm')
    def original(*args,**kwargs):
        yield SimpleNamespace(token=42,finish_reason=None)
        yield SimpleNamespace(token=99,finish_reason='stop')
    mlx.stream_generate=original;monkeypatch.setitem(sys.modules,'mlx_lm',mlx)
    def fake_parent(self,*args):
        list(mlx.stream_generate())
        return SimpleNamespace(status='ok')
    monkeypatch.setattr(prod.CleanupEngine,'_generate_locked',fake_parent)
    e=StudentEngine('student',tmp_path);e._tokenizer=Tokenizer()
    e.set_context(SimpleNamespace(system_prompt='stable'),CTX)
    e._generate_locked('stable','sample',96,2)
    assert e.last_output_tokens==[42] and e.last_eos and e.last_prompt_tokens
    assert mlx.stream_generate is original
    e.close()


def test_public_compare_rejects_different_tokens(tmp_path,capsys):
    import importlib.util
    script=Path(__file__).resolve().parents[2]/'training/cleanup/scripts/benchmark_student_decoder.py'
    spec=importlib.util.spec_from_file_location('student_decoder_bench',script)
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    common={'data_sha256':'a','base_revision':'b','base_files_sha256':{},'adapter_sha256':None,
        'max_input':1,'max_output':1,'timeout_ms':1,'source_sha256':'s','runner_sha256':'r','trace_enabled':True,'lfm_port_sha256':None,
        'versions':{},'median_s':1,'p95_s':2,'recovery_probe':'context_limit','mlx_allocator_cache_limit_bytes':512*1024*1024,'copy_draft_tokens':3}
    row={'id':'x','prompt_token_ids':[1], 'output_token_ids':[2], 'eos':True,
        'applied':True,'reason':None,'guarded_text':'ok'}
    one=tmp_path/'one';two=tmp_path/'two'
    one.write_text(json.dumps({**common,'decoder':'stream','records':[dict(row,id=str(i)) for i in range(64)]}))
    two.write_text(json.dumps({**common,'decoder':'engine','records':[dict(row,id=str(i)) for i in range(64)]}))
    mod.compare([one,two]);assert json.loads(capsys.readouterr().out)['parity']
    two.write_text(json.dumps({**common,'mlx_allocator_cache_limit_bytes':0,'decoder':'engine','records':[dict(row,id=str(i)) for i in range(64)]}))
    with pytest.raises(ValueError,match='512 MiB'):mod.compare([one,two])
    row['output_token_ids']=[3]
    two.write_text(json.dumps({**common,'decoder':'engine','records':[dict(row,id=str(i)) for i in range(64)]}))
    with pytest.raises(SystemExit):mod.compare([one,two])
    assert not json.loads(capsys.readouterr().out)['parity']


def test_public_qualification_rejects_matching_failures_and_duplicate_ids(tmp_path):
    import importlib.util
    script=Path(__file__).resolve().parents[2]/'training/cleanup/scripts/benchmark_student_decoder.py'
    spec=importlib.util.spec_from_file_location('student_decoder_qualification',script)
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    common={'data_sha256':'a','base_revision':'b','base_files_sha256':{},'adapter_sha256':None,
        'max_input':1,'max_output':1,'timeout_ms':1,'source_sha256':'s','runner_sha256':'r','trace_enabled':True,'lfm_port_sha256':None,
        'versions':{},'median_s':1,'p95_s':2,'recovery_probe':'context_limit','mlx_allocator_cache_limit_bytes':512*1024*1024,'copy_draft_tokens':3}
    row={'prompt_token_ids':[1],'output_token_ids':[],'eos':False,
        'applied':False,'reason':'context_limit','guarded_text':'raw'}
    files=[tmp_path/'stream',tmp_path/'engine']
    report=tmp_path/'qualification.json'
    def write(records):
        for path in files:
            path.write_text(json.dumps({**common,'decoder':path.name,'records':records}))
    write([dict(row,id=str(i)) for i in range(64)])
    with pytest.raises(ValueError,match='must reach EOS'):mod.compare(files,report)
    assert not report.exists()
    row.update(eos=True,applied=True,reason=None,guarded_text='ok')
    write([dict(row,id='same') for _ in range(64)])
    with pytest.raises(ValueError,match='unique case IDs'):mod.compare(files,report)
    assert not report.exists()


def test_public_decoder_input_requires_explicit_visibility(tmp_path):
    import importlib.util
    script=Path(__file__).resolve().parents[2]/'training/cleanup/scripts/benchmark_student_decoder.py'
    spec=importlib.util.spec_from_file_location('student_decoder_visibility',script)
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    path=tmp_path/'fixtures.jsonl'
    for visibility in (None,'private'):
        path.write_text(json.dumps({'id':'test','raw':'hello','visibility':visibility})+'\n')
        with pytest.raises(ValueError,match='explicit public visibility'):mod.contexts(path)
    path.write_text(json.dumps({'id':'test','raw':'hello','visibility':'public'})+'\n')
    assert mod.contexts(path)[0]['raw']=='hello'


def test_copy_pass_experiment_is_bounded_scoped_and_restored():
    before=prod.COPY_DRAFT_PASS_TOKENS
    for invalid in (0,1,2,5,9,3.0,True):
        with pytest.raises(ValueError):
            with experimental_copy_draft_tokens(invalid):pass
    with pytest.raises(RuntimeError,match='sentinel'):
        with experimental_copy_draft_tokens(8):
            assert prod.COPY_DRAFT_PASS_TOKENS==8
            with pytest.raises(RuntimeError,match='already active'):
                with experimental_copy_draft_tokens(3):pass
            raise RuntimeError('sentinel')
    assert prod.COPY_DRAFT_PASS_TOKENS==before
    with experimental_copy_draft_tokens(6):assert prod.COPY_DRAFT_PASS_TOKENS==6
    assert prod.COPY_DRAFT_PASS_TOKENS==before
