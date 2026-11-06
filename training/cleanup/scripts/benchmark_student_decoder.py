#!/usr/bin/env python3
"""Run or compare public student decoder trials; never use private transcripts.

Run each decoder in a fresh process with the same public JSONL and immutable
base/adapter. compare fails unless prompts, tokens, termination and guarded
results match on every case. No test labels are read or scored.
"""
import argparse
import asyncio
import hashlib
import importlib.metadata
import json
import os
# Enable production per-call work counters uniformly in these public trials.
os.environ['VELORA_TRACE_CLEANUP'] = '1'
from pathlib import Path
import platform
import statistics
import sys
import time

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'engine/scripts'))
sys.path.insert(0,str(ROOT/'training/cleanup'))
import benchmark_personal_student as b
from benchmark_resources import STUDENT_CACHE_LIMIT_BYTES, configure_student_allocator, loaded_model_memory
from cleanup.engine_decoder import StudentEngine, student_prompt_tokens, experimental_copy_draft_tokens
from cleanup.cache_compat import experimental_cache_api
from cleanup.provenance import adapter_hashes, load_local_snapshot
from cleanup.lfm3_compat import lfm3_architecture
from velora_engine import cleanup as prod


def checksum(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def contexts(path):
    # Deliberately extract input fields only; never inspect target labels.
    result=[]
    for line in Path(path).read_text().splitlines():
        r=json.loads(line)
        if r.get('visibility') != 'public':
            raise ValueError('public decoder fixtures require explicit public visibility')
        result.append({'id':r['id'],'raw':r['raw'],'mode':r.get('mode','default'),
            'language':r.get('language','auto'),'romanize':r.get('romanize',False),
            'instructions':r.get('instructions',''),'vocabulary':r.get('vocabulary',[])})
    if not result or any(not isinstance(x['id'],str) or not x['id'] for x in result) or len({x['id'] for x in result})!=len(result):
        raise ValueError('fixture IDs must be nonempty and unique')
    return result


async def run(a):
    rows=contexts(a.data)
    if len(rows)!=64: raise ValueError('expected exactly 64 public fixtures')
    snapshot,files=b.local_snapshot(a.base,a.base_revision)
    adapter=str(a.adapter.resolve(strict=True)) if a.adapter else None
    adapter_files=adapter_hashes(adapter)
    if adapter and (Path(adapter)/'manifest.json').exists():
        m=json.loads((Path(adapter)/'manifest.json').read_text())
        if m.get('base_revision')!=a.base_revision or m.get('snapshot_files_sha256')!=files:
            raise ValueError('adapter manifest does not match snapshot')
    metadata={'data_sha256':checksum(a.data),'base_revision':a.base_revision,'base_files_sha256':files,
        'mlx_allocator_cache_limit_bytes':STUDENT_CACHE_LIMIT_BYTES,
        'copy_draft_tokens':a.copy_draft_tokens,
        'adapter_sha256':adapter_files,'decoder':a.decoder,'max_input':a.max_input,
        'max_output':a.max_output,'timeout_ms':a.timeout_ms,'python':platform.python_version(),
        'versions':{k:importlib.metadata.version(k) for k in ('mlx','mlx-lm','transformers')},
        'prompt_contract':'student short JSON; neutralize control markers in user message',
        'deadline_policy':('cooperative elapsed time including prefill; no hard watchdog' if a.decoder=='stream' else 'soft budget starts at first output; independent worker watchdog includes prefill'),
        'source_sha256':b.source_hash(),'runner_sha256':checksum(__file__),'trace_enabled':True,'lfm_port_sha256':checksum(a.lfm_port) if a.lfm_port else None}
    if a.output.exists(): raise ValueError('output already exists')
    with lfm3_architecture(a.lfm_port), experimental_cache_api(), experimental_copy_draft_tokens(a.copy_draft_tokens):
        configure_student_allocator()
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_sampler
        t0=time.perf_counter()
        if a.decoder=='stream':
            model,tok=load_local_snapshot(snapshot,adapter)
            observed={'ids':[],'eos':False}
            def capture(*args,**kwargs):
                iterator=stream_generate(*args,**kwargs)
                try:
                    for response in iterator:
                        if response.finish_reason=='stop': observed['eos']=True
                        else: observed['ids'].append(response.token)
                        yield response
                finally:
                    iterator.close()
            engine=b.StudentCleanup(model,tok,capture,make_sampler(temp=0),a.max_output,a.max_input)
        else:
            engine=StudentEngine('student-'+a.base_revision,snapshot,adapter,
                copy_draft=a.decoder=='engine-copy',max_input=a.max_input,max_output=a.max_output)
            await engine.load_async(None)
            tok=engine._tokenizer
        metadata['model_load_s']=time.perf_counter()-t0
        # Reject an over-context request first, then exercise all 64 real calls.
        # This tests bounded recovery; real watchdog recovery needs its own run.
        probe_context={k:rows[0][k] for k in ('mode','language','romanize','instructions','vocabulary')}
        gate=type('Gate',(),{'system_prompt':'public decoder context'})()
        engine.set_context(gate,probe_context)
        saved_cap=engine.max_input
        engine.max_input=1
        probe=await engine.cleanup(rows[0]['raw'],'public decoder context',timeout_ms=a.timeout_ms)
        engine.max_input=saved_cap
        metadata['recovery_probe']=probe.reason
        if probe.reason!='context_limit' or engine.unhealthy:
            raise RuntimeError('bounded-context recovery probe failed')
        metadata['records']=[]
        for row in rows:
            context={k:row[k] for k in ('mode','language','romanize','instructions','vocabulary')}
            raw=row['raw']; system='public decoder context'
            gate=type('Gate',(),{'system_prompt':system})()
            engine.set_context(gate,context)
            prompts=student_prompt_tokens(tok,context,raw)
            if a.decoder=='stream':observed.update(ids=[],eos=False)
            start=time.perf_counter()
            result=await engine.cleanup(raw,system,timeout_ms=a.timeout_ms,
                check_ratio=not row['romanize'],allowed_terms=row['vocabulary'],copy_draft=not row['romanize'])
            elapsed=time.perf_counter()-start
            if engine.unhealthy:
                # MLX thread may still be active; exit without releasing its model context.
                import os
                os._exit(70)
            memory=loaded_model_memory(engine)
            actual_prompt=prompts if a.decoder=='stream' else engine.last_prompt_tokens
            ids=observed['ids'] if a.decoder=='stream' else engine.last_output_tokens
            eos=observed['eos'] if a.decoder=='stream' else engine.last_eos
            metadata['records'].append({'id':row['id'],'prompt_token_ids':actual_prompt,
                'output_token_ids':ids,'eos':eos,'applied':result.applied,'reason':result.reason,
                'guarded_text':result.text,'seconds':elapsed,'input_tokens':result.input_tokens,
                'output_tokens':result.output_tokens,'prefix_tokens':result.prefix_tokens,
                'cache_hit':result.cache_hit,'ttft_ms':result.ttft_ms,'decode_ms':result.decode_ms,
                'peak_bytes':result.mlx_peak_bytes,'mlx_memory':memory,'work_counts':result._work_counts,'latency_ns':result._latency_ns})
        if a.decoder!='stream':engine.close()
    times=[r['seconds'] for r in metadata['records']]
    metadata['median_s']=statistics.median(times)
    metadata['p95_s']=sorted(times)[max(0,__import__('math').ceil(len(times)*.95)-1)]
    with a.output.open('x') as out:json.dump(metadata,out,ensure_ascii=False,indent=2)
    print(json.dumps({'decoder':a.decoder,'cases':len(rows),'median_s':metadata['median_s'],
        'p95_s':metadata['p95_s'],'eos':sum(r['eos'] for r in metadata['records']),'output':str(a.output)}))


def compare(paths, report=None):
    trials=[json.loads(p.read_text()) for p in paths]
    keys=('data_sha256','base_revision','base_files_sha256','adapter_sha256','max_input',
          'max_output','timeout_ms','source_sha256','runner_sha256','trace_enabled','lfm_port_sha256','versions','mlx_allocator_cache_limit_bytes','copy_draft_tokens')
    if any(t.get('mlx_allocator_cache_limit_bytes')!=STUDENT_CACHE_LIMIT_BYTES for t in trials):
        raise ValueError('student trials require the explicit 512 MiB allocator cache cap')
    if any(type(t.get('copy_draft_tokens')) is not int or t['copy_draft_tokens'] not in (3,4,6,8) for t in trials):
        raise ValueError('student trials require bounded copy_draft_tokens metadata')
    if any(any(t[k]!=trials[0][k] for k in keys) for t in trials[1:]):
        raise ValueError('trial provenance mismatch')
    if len({t['decoder'] for t in trials})!=len(trials):raise ValueError('duplicate decoder')
    if any(len(t['records'])!=64 or t.get('recovery_probe')!='context_limit' for t in trials):
        raise ValueError('each trial requires 64 cases and a passed recovery probe')
    for trial in trials:
        ids=[r.get('id') for r in trial['records']]
        if any(not isinstance(identity,str) or not identity for identity in ids) or len(set(ids))!=64:
            raise ValueError('each trial requires 64 nonempty unique case IDs')
        if any(r.get('eos') is not True for r in trial['records']):
            raise ValueError('all 64 cases must reach EOS before decoder qualification')
    reference=trials[0]['records']
    fields=('id','prompt_token_ids','output_token_ids','eos','applied','reason','guarded_text')
    failures=[]
    for trial in trials[1:]:
        if len(trial['records'])!=len(reference):raise ValueError('case count mismatch')
        for left,right in zip(reference,trial['records']):
            diff=[k for k in fields if left[k]!=right[k]]
            if diff:failures.append({'id':left['id'],'decoder':trial['decoder'],'different':diff})
    print(json.dumps({'parity':not failures,'mismatches':failures,
        'trials':[{'decoder':x['decoder'],'median_s':x['median_s'],'p95_s':x['p95_s']} for x in trials]}))
    if failures:raise SystemExit(1)
    if report is not None:
        result={k:trials[0][k] for k in keys}
        result.update({'parity':True,'all_cases_eos':True,'unique_case_ids':True,'recovery_probe':'context_limit','decoders':[t['decoder'] for t in trials],
                       'cases':64,'qualification':'prompt tokens, output tokens, eos, guards and bounded-context recovery'})
        with report.open('x') as out: json.dump(result,out,indent=2)


def main():
    p=argparse.ArgumentParser(description=__doc__);sub=p.add_subparsers(dest='cmd',required=True)
    runp=sub.add_parser('run')
    for name in ('data','base','output'):runp.add_argument('--'+name,type=Path,required=True)
    runp.add_argument('--base-revision',required=True);runp.add_argument('--adapter',type=Path)
    runp.add_argument('--lfm-port',type=Path);runp.add_argument('--decoder',required=True,choices=('stream','engine','engine-copy'))
    runp.add_argument('--max-input',type=int,default=4096);runp.add_argument('--max-output',type=int,default=1024)
    runp.add_argument('--copy-draft-tokens',type=int,choices=(3,4,6,8),default=3)
    runp.add_argument('--timeout-ms',type=int,default=60000)
    cp=sub.add_parser('compare');cp.add_argument('--report',type=Path);cp.add_argument('files',nargs='+',type=Path)
    a=p.parse_args()
    if a.cmd=='run':asyncio.run(run(a))
    else:compare(a.files,a.report)
if __name__=='__main__':main()
