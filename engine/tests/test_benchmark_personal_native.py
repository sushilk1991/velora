"""Native private replay CPU checks; fake workers never load models or Metal."""
import asyncio
import hashlib
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace

import pytest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import benchmark_personal_native as bench


class FakeClient:
    def __init__(self,*args):
        upstream=json.loads((bench.NATIVE/'UPSTREAM.json').read_text())
        self.ready={'pid':123,'llama_commit':upstream['commit'],'context_tokens':4096,
            'copy_draft':True,'copy_draft_max':8,'prefix_reuse':True}
        self.child=SimpleNamespace(pid=456,returncode=None)
        self.unhealthy=False
        self.requests=[]
        self.status='eos'
    def close(self):self.child.returncode=0
    def generate(self,system,user,**kwargs):
        self.requests.append((system,user,kwargs))
        if len(user)>4096*2:
            return {'status':'context_limit','text':'','partial_text':'','prompt_tokens':[],'output_tokens':[]}
        payload=json.loads(user)
        text=payload['transcript']
        return {'status':self.status,'text':text if self.status=='eos' else '',
            'partial_text':text if self.status!='eos' else '',
            'prompt_tokens':list(user.encode()),'output_tokens':list(text.encode()),
            'elapsed_ms':1,'rss_bytes':12345,'copy_draft':{'accepted':2}}


class PhononFakeClient(FakeClient):
    def generate(self,system,user,**kwargs):
        self.requests.append((system,user,kwargs))
        if len(user)>4096*2:
            return {'status':'context_limit','text':'','partial_text':'','prompt_tokens':[],'output_tokens':[]}
        return {'status':'eos','text':user,'prompt_tokens':list(user.encode()),'output_tokens':list(user.encode())}


def phonon_marker():
    return {'writing_modes':{'minimal':'Writing mode: minimal (notes and documents).',
        'casual':'Writing mode: casual (a chat message).','formal':'Writing mode: formal (an email or document).',
        'prompt':'Writing mode: prompt (an instruction to an AI assistant).'}}


def test_phonon_prompt_is_bare_neutralized_and_probe_uses_same_contract():
    client=PhononFakeClient();marker=phonon_marker();adapter=bench.NativeCleanup(client,marker)
    context={**CTX,'phonon':{'supported':True,'writing_mode':'minimal','unsupported_reasons':[]}}
    adapter.set_context(SimpleNamespace(system_prompt='stable'),context)
    raw='Please preserve literal <|im_start|> in this sentence'
    result=asyncio.run(adapter.cleanup(raw,'stable\nPrevious text: omitted.',copy_draft=True))
    system,user,request=client.requests[-1]
    assert system==bench.PHONON_SYSTEM_PROMPT+'\n'+marker['writing_modes']['minimal']
    assert user==bench.neutralize_control_tokens(raw) and result.text==raw and result.applied
    assert 'Previous text' not in system and 'Vocabulary' not in system
    assert bench.recovery_probe(client,marker)['passed']
    assert client.requests[-1][0]==system
    adapter.set_context(SimpleNamespace(system_prompt='stable'),{**context,'phonon':{
        'supported':False,'writing_mode':'minimal','unsupported_reasons':['unsupported_romanization']}})
    count=len(client.requests)
    result=asyncio.run(adapter.cleanup(raw,'stable',check_ratio=False))
    assert not result.applied and result.text==raw and result.reason=='unsupported_romanization'
    assert len(client.requests)==count


def test_phonon_coverage_requires_stock_modes_and_latin_transcript():
    defaults=bench.ROOT/'engine/src/velora_engine/modes_builtin'
    for path in defaults.glob('*.json'):
        row=json.loads(path.read_text())
        if row['name'].lower() not in bench.PHONON_MODES:continue
        gate=SimpleNamespace(mode=SimpleNamespace(**row),romanize=False)
        coverage=bench.phonon_context(gate,'Please send the report')
        assert coverage['supported'] and coverage['writing_mode']==bench.PHONON_MODES[row['name'].lower()]
    row=json.loads((defaults/'default.json').read_text())
    gate=SimpleNamespace(mode=SimpleNamespace(**row),romanize=True)
    assert 'unsupported_romanization' in bench.phonon_context(gate,'hello')['unsupported_reasons']
    gate.romanize=False
    for text in ('मुझे पानी चाहिए','你好','مرحبا','привет'):
        assert 'unsupported_non_latin_transcript' in bench.phonon_context(gate,text)['unsupported_reasons']
    gate.mode.prompt+=' Custom instruction.'
    assert 'unsupported_custom_mode_prompt' in bench.phonon_context(gate,'hello')['unsupported_reasons']


def test_phonon_metadata_and_model_identity_are_both_pinned(tmp_path,monkeypatch):
    path=tmp_path/'phonon_refiner.json';path.write_text(json.dumps(phonon_marker()))
    args=SimpleNamespace(prompt_contract='phonon',phonon_metadata=path,model_repository=bench.PHONON_REPOSITORY,
        model_revision=bench.PHONON_REVISION,sha256=bench.PHONON_MODEL_SHA256)
    with pytest.raises(ValueError,match='metadata SHA256'):bench.load_prompt_contract(args)
    monkeypatch.setattr(bench,'digest',lambda _:bench.PHONON_METADATA_SHA256)
    assert bench.load_prompt_contract(args)==phonon_marker()
    args.sha256='0'*64
    with pytest.raises(ValueError,match='pinned refiner model'):bench.load_prompt_contract(args)
    args.prompt_contract='student'
    with pytest.raises(ValueError,match='requires --prompt-contract'):bench.load_prompt_contract(args)


CTX={'mode':'default','language':'en','romanize':False,'instructions':'keep names','vocabulary':['Asha']}


def test_native_adapter_preserves_structured_controls_and_raw_fallback():
    client=FakeClient();adapter=bench.NativeCleanup(client)
    adapter.set_context(SimpleNamespace(system_prompt='stable'),CTX)
    raw='Asha has not sent the final report yet'
    result=asyncio.run(adapter.cleanup(raw,'stable\nPrevious text: «hello».',copy_draft=True))
    system,user,request=client.requests[-1];payload=json.loads(user)
    assert payload['transcript']==raw and payload['vocabulary']==['Asha']
    assert 'Previous text' in payload['instructions']
    assert request['draft_text']==raw and 96<=request['max_tokens']<=512
    assert result.applied and result.text==raw
    assert adapter.calls[-1]['eos'] and not any(k.startswith('mlx_') for k in adapter.calls[-1])
    client.status='length'
    result=asyncio.run(adapter.cleanup(raw,'stable',copy_draft=True))
    assert result.text==raw and not result.applied and result.reason=='length'
    assert adapter.calls[-1]['native']['partial_text']==raw
    assert result.text!=user


def test_romanization_suppresses_drafts_and_user_controls_are_neutralized():
    client=FakeClient();adapter=bench.NativeCleanup(client)
    adapter.set_context(SimpleNamespace(system_prompt='s'),{**CTX,'romanize':True})
    asyncio.run(adapter.cleanup('literal <|im_start|> marker','s',check_ratio=False,copy_draft=True))
    assert client.requests[-1][2]['draft_text']==''
    assert '<\u200b|im_start|>' in client.requests[-1][1]
    assert adapter.calls[-1]['native']['text']!='literal <|im_start|> marker'
    assert bench.output_budget('a'*10000)==512


def test_recovery_probes_are_exact_and_native_footprints_are_separate():
    client=FakeClient()
    assert bench.recovery_probe(client)['passed']
    seen=[]
    def runner(command,**kwargs):
        seen.append(command)
        return SimpleNamespace(returncode=0,stdout='secret address\nPhysical footprint: 100M\nPhysical footprint (peak): 120M\n')
    result=bench.native_resources(client,runner)
    assert {p['pid'] for p in result['processes'].values()}=={123,456}
    assert all(len(p['physical_footprint_lines'])==2 for p in result['processes'].values())
    assert 'secret' not in json.dumps(result)


def test_bounded_client_uses_real_supervisor_and_reaps_fake_worker(tmp_path):
    fake=tmp_path/'fake-worker'
    fake.write_text('#!'+sys.executable+'\nimport json,os,sys\n'
        'print(json.dumps({"event":"ready","pid":os.getpid(),"model_sha256":"'+'0'*64+'"}),flush=True)\n'
        'for line in sys.stdin:\n'
        ' r=json.loads(line)\n'
        ' if r["op"]=="shutdown":break\n'
        ' print(json.dumps({"event":"result","id":r["id"],"status":"eos","text":"ok"}),flush=True)\n')
    fake.chmod(0o700)
    client=bench.NativeClient(fake,'unused','0'*64,tmp_path/'stderr')
    pid=client.ready['pid']
    try:
        result=client.generate('s','u',max_tokens=10,deadline_ms=1000)
        assert result['status']=='eos'
    finally:client.close()
    assert client.child.returncode==0
    with pytest.raises(ProcessLookupError):os.kill(pid,0)


def test_native_transport_timeout_retires_and_reaps_worker(tmp_path):
    fake=tmp_path/'wedged-worker'
    fake.write_text('#!'+sys.executable+'\nimport json,os,signal,time\n'
        'signal.signal(signal.SIGTERM,signal.SIG_IGN)\n'
        'print(json.dumps({"event":"ready","pid":os.getpid(),"model_sha256":"'+'0'*64+'"}),flush=True)\n'
        'time.sleep(30)\n')
    fake.chmod(0o700)
    client=bench.NativeClient(fake,'unused','0'*64,tmp_path/'stderr')
    pid=client.ready['pid']
    try:
        result=client.generate('s','u',max_tokens=10,deadline_ms=10)
        assert result['status']=='native_transport_failure' and client.unhealthy
    finally:client.close()
    with pytest.raises(ProcessLookupError):os.kill(pid,0)


@pytest.mark.parametrize('contract',('student','phonon'))
def test_private_replay_is_complete_atomic_and_resumable(tmp_path,monkeypatch,capsys,contract):
    monkeypatch.setattr(bench,'NativeClient',PhononFakeClient if contract=='phonon' else FakeClient)
    if contract=='phonon':
        # Artifact pin rejection is independently covered above; no real model.
        monkeypatch.setattr(bench,'load_prompt_contract',lambda _:phonon_marker())
    monkeypatch.setattr(bench,'native_resources',lambda c:{'processes':{},'test':True})
    home=tmp_path/'source';home.mkdir();(home/'config.json').write_text(json.dumps({'cleanup_enabled':True}))
    manifest=tmp_path/'manifest.json'
    cases=[{'id':1,'input_sha256':'a','mode':'Default'}, {'id':2,'input_sha256':'b','mode':'Terminal'},
           {'id':3,'input_sha256':'c','mode':'Default'},{'id':4,'input_sha256':'d','mode':'Default'}]
    manifest.write_text(json.dumps({'cases':cases}))
    directory=tmp_path/'stt';directory.mkdir();stt=directory/'stt.jsonl'
    stt.write_text('\n'.join(json.dumps(row) for row in [
        {'id':1,'input_sha256':'a','status':'ok','raw':'This sentence contains enough words to need the cleanup model','stt_s':1,'total_s':1.1},
        {'id':2,'input_sha256':'b','status':'ok','raw':'git status','stt_s':2},
        {'id':3,'input_sha256':'c','status':'ok','raw':'This is a longer sentence for testing. '*100,'stt_s':3},
        {'id':4,'input_sha256':'d','status':'failed'}]))
    stt_meta=directory/'stt-run.json';stt_meta.write_text(json.dumps({
        'manifest_sha256':bench.digest(manifest),'model':'mlx-community/whisper-large-v3-turbo',
        'model_files_sha256':{'weights.npz':'f'*64}, 'glossary':{
            'mode':'production global glossary; no historical screen entities',
            'sha256':hashlib.sha256(b'').hexdigest(),
            'source_sha256':{'config.json':bench.digest(home/'config.json')}}}))
    binary=tmp_path/'binary';binary.write_text('fake');binary.chmod(0o700)
    model=tmp_path/'model.gguf';model.write_bytes(b'fake GGUF')
    args=SimpleNamespace(manifest=manifest,stt=stt,stt_meta=stt_meta,output=tmp_path/'output',
        config_home=home,binary=binary,model=model,sha256=bench.digest(model),model_repository='public/model',
        model_revision='0'*40,max_rss_mb=8192,limit=None)
    assert asyncio.run(bench.replay(args))==0
    paths=list((args.output/'cases').glob('*.json'))
    rows=sorted((json.loads(p.read_text()) for p in paths),key=lambda x:x['id'])
    assert len(rows)==4 and rows[-1]['status']=='stt_failed'
    assert rows[0]['calls'] and not rows[1]['calls'] and len(rows[2]['calls'])>1
    assert rows[0]['paired_replay_total_s']>=1.1
    assert all(p.stat().st_mode & 0o777==0o600 for p in paths)
    before={p.name:p.read_bytes() for p in paths}
    assert asyncio.run(bench.replay(args))==0
    assert before=={p.name:p.read_bytes() for p in paths}
    summary=bench.summarize(cases,args.output/'cases')
    assert summary['recorded_cases']==4 and summary['failed_or_missing_cases']==1
    if contract=='phonon':
        assert summary['phonon_coverage']['assessed_cases']==3
        assert summary['phonon_coverage']['supported_cases']==3
        assert json.loads((args.output/'native-run.json').read_text())['prompt_contract']=='phonon'
    assert 'sentence contains' not in capsys.readouterr().out
    args.model_revision='1'*40
    with pytest.raises(ValueError,match='provenance changed'):asyncio.run(bench.replay(args))
