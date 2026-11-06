#!/usr/bin/env python3
"""Root-scheduled fixed-prompt native sweep; imports never load a model.

Inputs and all artifacts must be outside the repository. One-token length stops
are diagnostic results, never completed summaries or semantic qualification.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import signal
import statistics
import sys
import time
from types import SimpleNamespace

ROOT=Path(__file__).resolve().parents[3]
NATIVE=ROOT/'native/cleanup'
BATCHES=(16,32,64,128,256,512)
READY_SHARED=('model_sha256','llama_commit','template_sha256','architecture','vocab_size','context_tokens',
              'max_output_tokens','copy_draft','copy_draft_max','prefix_reuse','bounded_swa','swa_full','trace_runtime',
              'recurrent_rollback','recurrent_snapshots')


def digest(path):
    with Path(path).open('rb') as handle:return hashlib.file_digest(handle,'sha256').hexdigest()


def external(path):
    path=Path(path).expanduser().resolve()
    if path==ROOT or ROOT in path.parents:raise ValueError('inputs and artifacts must be outside the repository')
    return path


def private_json(path,value):
    temporary=path.with_suffix(path.suffix+'.tmp')
    fd=os.open(temporary,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
    with os.fdopen(fd,'w') as handle:
        json.dump(value,handle,indent=2,ensure_ascii=False,allow_nan=False);handle.write('\n')
    os.replace(temporary,path)


def validate_batches(batches):
    batches=tuple(batches)
    if len(batches)<2 or len(set(batches))!=len(batches) or any(type(b) is not int or b not in BATCHES for b in batches):
        raise ValueError('select at least two unique supported batches')
    return batches


def orders(rounds,seed,batches=BATCHES):
    batches=validate_batches(batches)
    if not 1<=rounds<=8:raise ValueError('rounds must be 1..8')
    rng=random.Random(seed);result=[]
    while len(result)<rounds:
        order=list(batches);rng.shuffle(order);result.append(order)
        if len(result)<rounds:result.append(list(reversed(order)))
    return result


def source_hashes():
    paths=[Path(__file__),*sorted(p for p in NATIVE.iterdir() if p.is_file()),
        *[ROOT/'engine/scripts'/name for name in ('benchmark_long_notes.py','benchmark_personal_native.py',
            'benchmark_personal_student.py','benchmark_personal_cleanup.py','benchmark_personal_recordings.py','benchmark_resources.py')],
        ROOT/'engine/src/velora_engine/cleanup.py',ROOT/'engine/src/velora_engine/meeting_notes.py',
        *sorted((ROOT/'training/cleanup/cleanup').glob('*.py'))]
    return {str(path.relative_to(ROOT)):digest(path) for path in paths}


def client_options(args,batch):
    return SimpleNamespace(native_binary=args.binary,native_sha256=args.sha256,native_context=args.context,
        native_max_rss_mb=args.max_rss_mb,native_prefill_batch=batch,native_max_output_tokens=args.max_output_tokens,
        native_draft_max=args.draft_max,native_research_long_context=args.research_long_context,
        native_copy_draft=args.copy_draft,native_prefix_cache=args.prefix_cache,
        native_bounded_swa=args.bounded_swa,native_trace_runtime=args.trace_runtime,
        native_recurrent_rollback=getattr(args,'recurrent_rollback',False))


def validate_ready(ready,args,batch,pin):
    expected={'event':'ready','model_sha256':args.sha256,'llama_commit':pin,'context_tokens':args.context,
        'prefill_batch_tokens':batch,'batch_tokens':min(batch,args.context),'ubatch_tokens':min(batch,args.context),
        'max_output_tokens':args.max_output_tokens,'copy_draft':args.copy_draft,'copy_draft_max':args.draft_max,
        'prefix_reuse':args.prefix_cache,'bounded_swa':args.bounded_swa,'swa_full':not args.bounded_swa,
        'trace_runtime':args.trace_runtime,'recurrent_rollback':getattr(args,'recurrent_rollback',False),
        'recurrent_snapshots':args.draft_max-1 if getattr(args,'recurrent_rollback',False) else 0}
    bad=[key for key,value in expected.items() if ready.get(key)!=value]
    if bad:raise ValueError('ready configuration mismatch: '+','.join(bad))


def response_valid(response,max_tokens):
    prompt=response.get('prompt_tokens');tokens=response.get('output_tokens')
    if (response.get('event')!='result' or not isinstance(prompt,list) or not prompt or not isinstance(tokens,list)
            or any(type(token) is not int for token in prompt+tokens)):
        return False
    status=response.get('status')
    if max_tokens==1:return status=='length' and len(tokens)==1 or status=='eos' and not tokens
    return (status=='eos' and 0<len(tokens)<max_tokens
            and isinstance(response.get('text'),str) and bool(response['text'].strip()))


def summarize(arms,round_count,repeats,max_tokens,integrity_errors=(),batches=BATCHES):
    batches=validate_batches(batches)
    expected_arms=round_count*len(batches)
    records=[(arm,row) for arm in arms for row in arm.get('requests',[])]
    measured=[(arm,row) for arm,row in records if row['phase']=='measured']
    baseline=next(((arm,row) for arm,row in records if response_valid(row['response'],max_tokens)),None)
    mismatches=[];first_mismatches=[];prompt_mismatches=[];invalid=[];ready_mismatches=[]
    if baseline:
        reference=baseline[1]['response'];ready=baseline[0]['ready']
        for arm in arms:
            if any(arm.get('ready',{}).get(key)!=ready.get(key) for key in READY_SHARED):ready_mismatches.append(arm['arm_id'])
        for arm,row in records:
            result=row['response'];identity=f"{arm['arm_id']}:{row['phase']}:{row['index']}"
            if not response_valid(result,max_tokens):invalid.append(identity)
            if result.get('prompt_tokens')!=reference['prompt_tokens']:prompt_mismatches.append(identity)
            first=lambda r:r.get('output_tokens',[None])[:1] if r.get('output_tokens') else ('immediate_eos' if r.get('status')=='eos' else 'missing')
            if first(result)!=first(reference):first_mismatches.append(identity)
            if any(result.get(key)!=reference.get(key) for key in ('prompt_tokens','output_tokens','status','text','partial_text')):
                mismatches.append(identity)
    else:invalid=[f"{arm['arm_id']}:{row['phase']}:{row['index']}" for arm,row in records]
    def median(values):
        values=[value for value in values if isinstance(value,(int,float)) and not isinstance(value,bool)]
        return statistics.median(values) if values else None
    def status_of(row):
        value=row['response'].get('status')
        return value if isinstance(value,str) else 'request_error'
    per_batch={}
    for batch in batches:
        selected=[row for arm,row in measured if arm['batch']==batch]
        eligible=[row for row in selected if response_valid(row['response'],max_tokens)]
        per_batch[str(batch)]={'measured_requests':len(selected),'eligible_requests':len(eligible),
            'expected_requests':round_count*repeats,
            'status_counts':{status:sum(status_of(row)==status for row in selected)
                for status in sorted({status_of(row) for row in selected})},
            'all_attempts_wall_median_ms':median([row['wall_ms'] for row in selected]),
            'eligible_worker_median_ms':median([row['response'].get('elapsed_ms') for row in eligible]),
            'eligible_wall_median_ms':median([row['wall_ms'] for row in eligible]),
            'eligible_first_decision_median_ms':median([(row['response'].get('runtime_trace') or {}).get('first_decision_ms') for row in eligible]),
            'worker_rss_max_bytes':max([row['response']['rss_bytes'] for row in selected
                if type(row['response'].get('rss_bytes')) is int] or [0])}
    complete=(len(arms)==expected_arms and len(records)==expected_arms*(repeats+1)
        and all(sum(arm.get('batch')==batch for arm in arms)==round_count for batch in batches)
        and all(not arm.get('error') and arm.get('supervisor_exit_code')==0 for arm in arms))
    parity=bool(baseline) and complete and not (invalid or mismatches or ready_mismatches or integrity_errors)
    return {'diagnostic_only':max_tokens==1,
        'diagnostic_immediate_eos_no_output':max_tokens==1 and any(row['response'].get('status')=='eos' and not row['response'].get('output_tokens') for _,row in records),
        'completed_summary_claim':False,'semantic_quality_evaluated':False,
        'scope':'fixed prompt only; this is not full runtime or meeting-summary qualification',
        'reference_request':({'arm_id':baseline[0]['arm_id'],'phase':baseline[1]['phase'],'index':baseline[1]['index']} if baseline else None),
        'selected_batches':list(batches),'expected_arms':expected_arms,'recorded_arms':len(arms),'complete':complete,
        'expected_requests_including_warmup':expected_arms*(repeats+1),'recorded_requests_including_warmup':len(records),
        'same_prompt_tokens':bool(baseline) and not prompt_mismatches,
        'same_first_output_token_or_immediate_eos':bool(baseline) and not first_mismatches,
        'exact_response_parity':parity,'fixed_prompt_backend_comparison_gate':parity,
        'all_measured_outputs_eos':bool(measured) and all(row['response'].get('status')=='eos' for _,row in measured),
        'invalid_responses':invalid,'response_mismatches':mismatches,'prompt_mismatches':prompt_mismatches,
        'first_output_mismatches':first_mismatches,'ready_mismatches':ready_mismatches,
        'integrity_errors':list(integrity_errors),'per_batch':per_batch}


def run(args,client_factory=None):
    payload_path=external(args.payload_file);system_path=external(args.system_prompt_file)
    output=external(args.output)
    if output.exists():raise FileExistsError('choose a fresh output directory')
    payload=payload_path.read_bytes().decode('utf-8');system=system_path.read_bytes().decode('utf-8')
    if not payload or len(payload.encode())>65536 or not system or len(system.encode())>16384:
        raise ValueError('native payload/system byte bounds exceeded or empty input')
    if any(marker in text for text in (system,payload) for marker in ('<|','<think>','</think>')):
        raise ValueError('control delimiters require explicitly prepared neutralized input files')
    if not (128<=args.context<=4096 or args.research_long_context and args.context in (8192,16384)):
        raise ValueError('invalid context bound')
    if not 1<=args.max_tokens<=args.max_output_tokens<=(2048 if args.research_long_context else 512):raise ValueError('invalid output bound')
    if not 1<=args.repeats<=10 or not 1<=args.deadline_ms<=120000 or not 512<=args.max_rss_mb<=32768:
        raise ValueError('invalid repeats, deadline or RSS bound')
    args.binary=args.binary.expanduser().resolve(strict=True);args.model=args.model.expanduser().resolve(strict=True)
    if not os.access(args.binary,os.X_OK) or not args.binary.is_file() or not args.model.is_file():raise ValueError('local binary/model required')
    if digest(args.model)!=args.sha256:raise ValueError('GGUF SHA256 mismatch')
    batches=validate_batches(getattr(args,'batches',BATCHES))
    order=orders(args.rounds,args.seed,batches)
    upstream=json.loads((NATIVE/'UPSTREAM.json').read_text());sources=source_hashes()
    identities={str(path):digest(path) for path in (payload_path,system_path,args.binary,args.model)}
    output.mkdir(parents=True,mode=0o700);os.chmod(output,0o700)
    manifest={'schema':1,'created_unix_s':time.time(),'input_files_sha256':identities,'source_files_sha256':sources,
        'upstream':upstream,'selected_batches':list(batches),'batch_order':order,'seed':args.seed,'paired_reverse_rounds_complete':args.rounds%2==0,
        'parameters':{key:str(value) if isinstance(value,Path) else value for key,value in vars(args).items()},
        'prompt_policy':'exact UTF-8 file contents; no chat rendering or semantic chunking in driver',
        'timing':'new worker for each arm; model load and one warmup excluded; first_decision is not streaming TTFT',
        'diagnostic_only':args.max_tokens==1,'semantic_quality_evaluated':False,'completed_summary_claim':False}
    private_json(output/'manifest.json',manifest)
    if client_factory is None:
        sys.path.insert(0,str(ROOT/'engine/scripts'))
        from benchmark_long_notes import NotesNativeClient
        client_factory=NotesNativeClient
    arms=[];integrity=[];abort=False
    try:
        for round_index,round_batches in enumerate(order):
            if abort:break
            for position,batch in enumerate(round_batches):
                arm={'arm_id':f'r{round_index+1:02d}-p{position+1:02d}-b{batch}',
                     'round':round_index+1,'position':position+1,'batch':batch,'requests':[]}
                arms.append(arm);client=None;arm_path=output/(arm['arm_id']+'.json')
                try:
                    started=time.perf_counter()
                    client=client_factory(client_options(args,batch),args.model,output/(arm['arm_id']+'.stderr.log'))
                    arm['load_wall_ms']=(time.perf_counter()-started)*1000
                    arm['ready']=client.transport.ready
                    validate_ready(arm['ready'],args,batch,upstream['commit'])
                    for index in range(args.repeats+1):
                        started=time.perf_counter()
                        response=client.transport.generate(system,payload,max_tokens=args.max_tokens,deadline_ms=args.deadline_ms,
                            draft_text=payload if args.copy_draft else '')
                        arm['requests'].append({'phase':'warmup' if index==0 else 'measured','index':index,
                            'wall_ms':(time.perf_counter()-started)*1000,'response':response})
                        private_json(arm_path,arm)
                        if client.transport.unhealthy:
                            arm['error']='native_transport_unhealthy';abort=True;break
                except (Exception,KeyboardInterrupt) as exc:
                    arm['error']=type(exc).__name__+': '+str(exc);abort=True
                finally:
                    if client is not None:
                        try:
                            client.close();arm['supervisor_exit_code']=client.transport.child.returncode
                            if arm['supervisor_exit_code']!=0:abort=True
                        except (Exception,KeyboardInterrupt) as exc:
                            arm['error']='close_failed:'+type(exc).__name__;abort=True
                    private_json(arm_path,arm)
                if abort:break
    finally:
        for path,sha in identities.items():
            try:
                if digest(path)!=sha:integrity.append('input_or_binary_changed:'+path)
            except OSError:integrity.append('input_or_binary_unreadable:'+path)
        try:
            if source_hashes()!=sources:integrity.append('source_files_changed_during_sweep')
        except OSError:integrity.append('source_files_unreadable_after_sweep')
        summary=summarize(arms,args.rounds,args.repeats,args.max_tokens,integrity,batches)
        private_json(output/'summary.json',summary)
    print(json.dumps({'output':str(output),'complete':summary['complete'],'exact_response_parity':summary['exact_response_parity'],
        'diagnostic_only':summary['diagnostic_only'],'completed_summary_claim':False}))
    return 0 if summary['fixed_prompt_backend_comparison_gate'] else 1


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for flag in ('payload-file','system-prompt-file','output','binary','model'):parser.add_argument('--'+flag,type=Path,required=True)
    parser.add_argument('--sha256',required=True)
    parser.add_argument('--rounds',type=int,default=2);parser.add_argument('--repeats',type=int,default=3)
    parser.add_argument('--seed',type=int,default=20261106)
    parser.add_argument('--batches',type=int,nargs='+',choices=BATCHES,default=list(BATCHES))
    parser.add_argument('--context',type=int,default=4096)
    parser.add_argument('--max-tokens',type=int,default=1);parser.add_argument('--max-output-tokens',type=int,default=512)
    parser.add_argument('--deadline-ms',type=int,default=120000);parser.add_argument('--max-rss-mb',type=int,default=8192)
    parser.add_argument('--draft-max',type=int,choices=range(1,9),default=8)
    for flag in ('copy-draft','prefix-cache','bounded-swa','research-long-context','recurrent-rollback'):parser.add_argument('--'+flag,action='store_true')
    parser.add_argument('--trace-runtime',action=argparse.BooleanOptionalAction,default=True)
    args=parser.parse_args()
    def stop(signum,frame):raise InterruptedError('sweep interrupted by signal '+str(signum))
    for signum in (signal.SIGTERM,signal.SIGHUP):signal.signal(signum,stop)
    return run(args)


if __name__=='__main__':raise SystemExit(main())
