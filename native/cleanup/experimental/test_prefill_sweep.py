"""Pure CPU fixtures and fake clients; no subprocess/model or MLX execution."""
import importlib.util
import json
import os
from pathlib import Path
from types import SimpleNamespace

import pytest

SCRIPT=Path(__file__).with_name('prefill_sweep.py')
spec=importlib.util.spec_from_file_location('prefill_sweep',SCRIPT)
sweep=importlib.util.module_from_spec(spec);spec.loader.exec_module(sweep)


def response(token=7,status='length'):
    return {'event':'result','status':status,'prompt_tokens':[1,2,3],
        'output_tokens':[token],'text':'done' if status=='eos' else '',
        'partial_text':'' if status=='eos' else 'd','elapsed_ms':10,'rss_bytes':100,
        'runtime_trace':{'first_decision_ms':9}}


def args_for(tmp_path):
    payload=tmp_path/'payload.txt';payload.write_bytes(b'Please retain\r\nthis source exactly.')
    system=tmp_path/'system.txt';system.write_text('Summarize faithfully.')
    binary=tmp_path/'binary';binary.write_text('fake');binary.chmod(0o700)
    model=tmp_path/'model';model.write_text('fake GGUF')
    return SimpleNamespace(payload_file=payload,system_prompt_file=system,output=tmp_path/'out',binary=binary,
        model=model,sha256=sweep.digest(model),rounds=2,repeats=3,seed=12,context=4096,max_tokens=1,
        max_output_tokens=512,deadline_ms=1000,max_rss_mb=8192,draft_max=8,copy_draft=False,
        prefix_cache=False,bounded_swa=False,research_long_context=False,trace_runtime=True)


class FakeClient:
    seen=[]
    fail=False
    mismatch_batch=None
    def __init__(self,args,model,stderr):
        pin=json.loads((sweep.NATIVE/'UPSTREAM.json').read_text())['commit']
        self.transport=self;self.child=SimpleNamespace(returncode=None);self.unhealthy=False
        self.batch=args.native_prefill_batch
        self.ready={'event':'ready','model_sha256':args.native_sha256,'llama_commit':pin,'template_sha256':'template',
            'architecture':'lfm3','vocab_size':128000,'context_tokens':args.native_context,
            'prefill_batch_tokens':self.batch,'batch_tokens':self.batch,'ubatch_tokens':self.batch,
            'max_output_tokens':args.native_max_output_tokens,'copy_draft':args.native_copy_draft,
            'copy_draft_max':args.native_draft_max,'prefix_reuse':args.native_prefix_cache,
            'bounded_swa':args.native_bounded_swa,'swa_full':not args.native_bounded_swa,
            'trace_runtime':args.native_trace_runtime,'recurrent_rollback':args.native_recurrent_rollback,
            'recurrent_snapshots':args.native_draft_max-1 if args.native_recurrent_rollback else 0}
    def generate(self,system,user,**kwargs):
        self.seen.append((self.batch,system,user,kwargs))
        if self.fail:
            self.unhealthy=True
            return {'event':'error','status':'native_transport_failure'}
        return response(8 if self.batch==self.mismatch_batch else 7,'length' if kwargs['max_tokens']==1 else 'eos')
    def close(self):self.child.returncode=0


def test_counterbalanced_orders_reproduce_and_reverse_pairs():
    plan=sweep.orders(4,19)
    assert plan==sweep.orders(4,19)
    assert plan[1]==plan[0][::-1] and plan[3]==plan[2][::-1]
    assert all(sorted(row)==list(sweep.BATCHES) for row in plan)
    with pytest.raises(ValueError):sweep.orders(9,19)


def test_external_paths_resolve_symlinks_and_refuse_repo(tmp_path):
    with pytest.raises(ValueError,match='outside'):sweep.external(sweep.ROOT/'report.json')
    link=tmp_path/'link';link.symlink_to(sweep.ROOT,target_is_directory=True)
    with pytest.raises(ValueError,match='outside'):sweep.external(link/'report.json')


def test_diagnostic_sweep_records_all_calls_without_summary_claim(tmp_path,monkeypatch,capsys):
    args=args_for(tmp_path)
    monkeypatch.setattr(sweep,'source_hashes',lambda:{'source':'a'})
    monkeypatch.setattr(FakeClient,'seen',[])
    assert sweep.run(args,FakeClient)==0
    summary=json.loads((args.output/'summary.json').read_text())
    assert summary['complete'] and summary['exact_response_parity'] and summary['diagnostic_only']
    assert not summary['completed_summary_claim'] and not summary['all_measured_outputs_eos']
    assert summary['recorded_requests_including_warmup']==48
    assert all(row['measured_requests']==6 for row in summary['per_batch'].values())
    assert len(FakeClient.seen)==48 and all('\r\n' in row[2] for row in FakeClient.seen)
    assert all(row[3]['draft_text']=='' for row in FakeClient.seen)
    assert args.output.stat().st_mode & 0o777==0o700
    assert all(path.stat().st_mode & 0o777==0o600 for path in args.output.glob('*.json'))
    assert 'retain' not in capsys.readouterr().out
    with pytest.raises(FileExistsError):sweep.run(args,FakeClient)


def test_mismatches_and_transport_failure_never_pass(tmp_path,monkeypatch):
    args=args_for(tmp_path);monkeypatch.setattr(sweep,'source_hashes',lambda:{'source':'a'})
    monkeypatch.setattr(FakeClient,'mismatch_batch',32)
    assert sweep.run(args,FakeClient)==1
    report=json.loads((args.output/'summary.json').read_text())
    assert report['complete'] and report['response_mismatches'] and report['first_output_mismatches']
    assert report['same_prompt_tokens'] and not report['fixed_prompt_backend_comparison_gate']
    args.output=tmp_path/'failed';monkeypatch.setattr(FakeClient,'fail',True)
    assert sweep.run(args,FakeClient)==1
    report=json.loads((args.output/'summary.json').read_text())
    assert not report['complete'] and report['recorded_arms']==1 and report['recorded_requests_including_warmup']==1


def test_eos_arm_requires_eos_and_ready_configuration_matches(tmp_path,monkeypatch):
    args=args_for(tmp_path);args.max_tokens=1024;args.max_output_tokens=2048
    args.research_long_context=True;args.context=8192
    monkeypatch.setattr(sweep,'source_hashes',lambda:{'source':'a'})
    assert sweep.run(args,FakeClient)==0
    report=json.loads((args.output/'summary.json').read_text())
    assert report['all_measured_outputs_eos'] and not report['diagnostic_only']
    assert not sweep.response_valid(response(status='length'),1024)
    assert not sweep.response_valid({'event':'result','status':'eos','prompt_tokens':[],'output_tokens':[]},1024)
    options=sweep.client_options(args,16);client=FakeClient(options,args.model,None)
    client.ready['prefill_batch_tokens']=128
    with pytest.raises(ValueError,match='ready configuration'):
        sweep.validate_ready(client.ready,args,16,client.ready['llama_commit'])


def test_empty_eos_rejected_for_multi_token_and_labeled_for_diagnostic():
    empty={'event':'result','status':'eos','prompt_tokens':[1,2],
        'output_tokens':[],'text':'','partial_text':''}
    assert not sweep.response_valid(empty,128)
    assert sweep.response_valid(empty,1)
    arms=[{'arm_id':str(batch),'batch':batch,'ready':{},'supervisor_exit_code':0,
        'requests':[{'phase':phase,'index':i,'wall_ms':1,'response':dict(empty)}
            for i,phase in enumerate(('warmup','measured'))]} for batch in sweep.BATCHES]
    diagnostic=sweep.summarize(arms,1,1,1)
    assert diagnostic['diagnostic_only'] and diagnostic['diagnostic_immediate_eos_no_output']
    multi=sweep.summarize(arms,1,1,128)
    assert not multi['fixed_prompt_backend_comparison_gate'] and multi['invalid_responses']
    assert not multi['diagnostic_immediate_eos_no_output']


def test_selected_two_batches_counterbalance_and_accounting(tmp_path,monkeypatch):
    plan=sweep.orders(2,7,[128,256])
    assert set(plan[0])=={128,256} and plan[1]==plan[0][::-1]
    args=args_for(tmp_path);args.batches=[128,256];args.max_tokens=4
    monkeypatch.setattr(sweep,'source_hashes',lambda:{'source':'a'})
    assert sweep.run(args,FakeClient)==0
    manifest=json.loads((args.output/'manifest.json').read_text())
    report=json.loads((args.output/'summary.json').read_text())
    assert manifest['selected_batches']==[128,256]
    assert report['selected_batches']==[128,256] and report['expected_arms']==4
    assert report['recorded_requests_including_warmup']==16 and report['exact_response_parity']
    assert set(report['per_batch'])=={'128','256'}
    assert all(v['expected_requests']==6 and v['measured_requests']==6 for v in report['per_batch'].values())


@pytest.mark.parametrize('batches',[[128],[128,128],[16,999],[]])
def test_batches_reject_invalid_and_duplicate_selections(batches):
    with pytest.raises(ValueError,match='two unique supported'):
        sweep.orders(2,3,batches)


def test_recurrent_rollback_passthrough_and_ready_gate(tmp_path,monkeypatch):
    args=args_for(tmp_path);args.batches=[128,256];args.recurrent_rollback=True;args.copy_draft=True
    monkeypatch.setattr(sweep,'source_hashes',lambda:{'source':'a'})
    options=sweep.client_options(args,128)
    assert options.native_recurrent_rollback
    client=FakeClient(options,args.model,None)
    sweep.validate_ready(client.ready,args,128,client.ready['llama_commit'])
    client.ready['recurrent_rollback']=False
    with pytest.raises(ValueError,match='recurrent_rollback'):
        sweep.validate_ready(client.ready,args,128,client.ready['llama_commit'])
    client.ready['recurrent_rollback']=True;client.ready['recurrent_snapshots']=0
    with pytest.raises(ValueError,match='recurrent_snapshots'):
        sweep.validate_ready(client.ready,args,128,client.ready['llama_commit'])
    assert sweep.run(args,FakeClient)==0
    manifest=json.loads((args.output/'manifest.json').read_text())
    assert manifest['parameters']['recurrent_rollback'] is True
