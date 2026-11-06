import copy
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

SCRIPT = Path(__file__).with_name('qualify_bounded_swa.py')
spec = importlib.util.spec_from_file_location('swa_probe', SCRIPT)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


def fake_response(system, user, *, draft='', cancel=None, context=8192):
    try:
        padding = json.loads(user)['vocabulary'][0].count(' x')
        n = 130 + padding
    except (ValueError, KeyError):
        n = context + 20
    status = 'context_limit' if n > context else 'cancelled' if cancel is not None else 'eos'
    return {'event': 'result', 'status': status, 'prompt_tokens': [7]*n,
            'output_tokens': [1,2,3] if status == 'eos' else [],
            'text': m.RAW if status == 'eos' else '', 'partial_text': '',
            'prefix_cache': {'hit': True}, 'copy_draft': {'proposed': 8 if draft else 0,
            'rollbacks': int(bool(draft) and draft != m.RAW)}}


def fixture():
    targets = (*m.BOUNDARIES, 4097)
    cases = []
    for n in targets:
        system,user = m.payload(n-130)
        cases.append({'target_tokens':n,'system':system,'user':user,'prompt_tokens':[7]*n})
    arms = []
    for name in ('full','bounded'):
        arm={'name':name,'requests':[],'exit_code':0}; previous=None
        def request(label,system,user,*,draft='',cancel=None):
            nonlocal previous
            result=fake_response(system,user,draft=draft,cancel=cancel)
            result['prefix_cache']['hit'] = previous == system
            previous=system
            arm['requests'].append({'name':label,'response':result})
            return result
        m.exercise(cases,request,128,8192);arms.append(arm)
    return arms,cases,targets


def test_full_boundary_and_recovery_fixture_qualifies():
    arms,cases,targets=fixture()
    assert m.summarize(arms,cases,128,targets)['qualified']
    assert len(arms)==2 and len(cases)==7
    result=m.summarize(arms,cases,128,targets)
    assert result['recovery_targets_total_prompt_tokens']==[513,4097]
    for n in targets:
        assert any(r['name']==f'{n}:repeat_after_wrong_copy' for r in arms[0]['requests'])


@pytest.mark.parametrize('change', ['output','prompt','length','missing','copy','rollback','recovery','ready','post_wrong','null_copy','null_cache','long_recovery'])
def test_all_parity_and_coverage_gates_fail_closed(change):
    arms,cases,targets=fixture(); arm=arms[1]
    def response(name):return next(x['response'] for x in arm['requests'] if x['name']==name)
    if change=='output':response('257:copy')['output_tokens']=[9]
    if change=='prompt':response('255:scalar')['prompt_tokens']=[7]*254
    if change=='length':response('512:scalar')['status']='length'
    if change=='missing':arm['requests'].pop()
    if change=='copy':response('4097:copy')['copy_draft']['proposed']=0
    if change=='rollback':response('511:wrong_copy')['copy_draft']['rollbacks']=0
    if change=='recovery':response('513:after_cancel')['output_tokens']=[8]
    if change=='post_wrong':response('512:repeat_after_wrong_copy')['output_tokens']=[8]
    if change=='null_copy':response('511:wrong_copy')['copy_draft']=None
    if change=='null_cache':response('511:repeat')['prefix_cache']=None
    if change=='long_recovery':response('4097:after_context_error')['output_tokens']=[8]
    if change=='ready':arm['ready']={'model_sha256':'wrong'}
    assert not m.summarize(arms,cases,128,targets)['qualified']


def test_calibration_uses_measured_tokens_and_bounded_attempts():
    calls=[]
    def request(name,system,user,*,budget):
        calls.append(name)
        result=fake_response(system,user)
        result['prompt_tokens'] += [7]*11
        result['status']='length';result['output_tokens']=[1]
        return result
    case=m.calibrate(255,request)
    assert len(case['prompt_tokens'])==255 and len(calls)==2
    def impossible(*args,**kwargs):return {'event':'result','status':'length','prompt_tokens':[7]*1000}
    with pytest.raises(RuntimeError,match='boundary not reached'):m.calibrate(255,impossible)


def test_cancel_partial_tokens_are_not_claimed_deterministic():
    arms,cases,targets=fixture()
    cancel=next(x['response'] for x in arms[1]['requests'] if x['name']=='513:cancel')
    cancel['output_tokens']=[99];cancel['partial_text']='interrupted'
    assert m.summarize(arms,cases,128,targets)['qualified']
    cancel['status']='eos'
    assert not m.summarize(arms,cases,128,targets)['qualified']


def test_runner_retires_transport_failure_and_writes_private_report(tmp_path,monkeypatch):
    binary=tmp_path/'worker';binary.write_text('fake');binary.chmod(0o700)
    model=tmp_path/'model';model.write_bytes(b'fake')
    args=SimpleNamespace(binary=binary,model=model,sha256=m.shared.digest(model),out=tmp_path/'out',
        context=8192,long_tokens=4097,max_tokens=128,deadline_ms=1000,max_rss_mb=8192,prefill_batch=128)
    created=[]
    class Fake:
        def __init__(self,options,path,stderr):
            created.append(self)
            self.transport=SimpleNamespace(ready={'architecture':'lfm3'},unhealthy=True,
                child=SimpleNamespace(returncode=None),generate=lambda *a,**k:{'event':'error','status':'native_transport_failure'})
        def close(self):self.transport.child.returncode=0
    monkeypatch.setattr(m.shared,'validate_ready',lambda *a:None)
    monkeypatch.setattr(m,'sources',lambda:{'fake':'unchanged'})
    assert m.run(args,Fake)==1
    assert len(created)==1 and created[0].transport.child.returncode==0
    assert not json.loads((args.out/'summary.json').read_text())['qualified']
    for path in args.out.glob('*.json'):assert path.stat().st_mode & 0o777 == 0o600
