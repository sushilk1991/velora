#!/usr/bin/env python3
"""Private offline STT-to-formatting replay with a supervised native GGUF worker.

Never reads reference/gold text or opens history, microphones, or app sockets.
This uses a declared student or Phonon prompt contract and a distinct GGUF
artifact; it is not a backend-only comparison with production MLX.
"""
from __future__ import annotations
import argparse
import asyncio
from dataclasses import asdict
import hashlib
import json
import math
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import time
import unicodedata

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'engine/src'))
sys.path.insert(0,str(ROOT/'training/cleanup'))
from benchmark_personal_cleanup import digest, private_dir, private_write, hash_tree, snapshot_config, read_inputs, make_server, validate_stt_provenance
from benchmark_personal_student import controls, cleanup_status, source_hash
from cleanup.engine_decoder import student_messages
from velora_engine.cleanup import CleanupResult, adaptive_timeout_ms, check_divergence, restore_control_tokens, neutralize_control_tokens

NATIVE=ROOT/'native/cleanup'
CONTEXT_TOKENS=4096
DRAFT_TOKENS=8
MAX_OUTPUT=512
MAX_FRAME=1024*1024
PHONON_REPOSITORY='Infatoshi/phonon-refiner-1.7b'
PHONON_REVISION='2b0ab74bee7ab7cf364695bbe44f64ce4c47439e'
PHONON_MODEL_SHA256='059e6e503c6c2ec50cb61a39bd0d556fb6d946bb58e965fb9ddb8b0176dfc6cd'
PHONON_METADATA_SHA256='42c7febd360d3d3a2d13179f382aa2872777e6af7f7e21ae61122d7181a24db3'
PHONON_SYSTEM_PROMPT=(
    "Rewrite the raw dictation transcript into the exact text the speaker intended. "
    "Fix recognition errors and technical terms, keep the speaker's wording and casing style, "
    "do not add or drop content.")
PHONON_MODES={'default':'minimal','note':'minimal','email':'formal',
              'message':'casual','code':'prompt','terminal':'prompt'}


def load_prompt_contract(args):
    contract=getattr(args,'prompt_contract','student')
    metadata=getattr(args,'phonon_metadata',None)
    if contract=='student':
        if metadata is not None:raise ValueError('--phonon-metadata requires --prompt-contract phonon')
        return None
    if contract!='phonon' or metadata is None:
        raise ValueError('phonon prompt contract requires pinned --phonon-metadata')
    path=Path(metadata).expanduser().resolve(strict=True)
    if digest(path)!=PHONON_METADATA_SHA256:raise ValueError('Phonon metadata SHA256 mismatch')
    if (args.model_repository,args.model_revision,args.sha256)!=(PHONON_REPOSITORY,PHONON_REVISION,PHONON_MODEL_SHA256):
        raise ValueError('Phonon prompt contract requires the pinned refiner model artifact')
    marker=json.loads(path.read_text())
    if set(marker['writing_modes'])!=set(PHONON_MODES.values()):raise ValueError('unsupported Phonon writing modes')
    return marker


def phonon_context(gate,raw):
    """Map resolved production modes; never inspect reference outputs."""
    mode=gate.mode
    name=mode.name.lower()
    reasons=[]
    stock={row['name'].lower():row for row in (
        json.loads(path.read_text()) for path in (ROOT/'engine/src/velora_engine/modes_builtin').glob('*.json'))}
    if name not in PHONON_MODES or name not in stock:
        reasons.append('unsupported_explicit_mode')
    elif mode.prompt!=stock[name]['prompt']:
        reasons.append('unsupported_custom_mode_prompt')
    elif mode.formatting!=stock[name]['formatting']:
        reasons.append('unsupported_custom_formatting')
    if gate.romanize:reasons.append('unsupported_romanization')
    if any(char.isalpha() and 'LATIN' not in unicodedata.name(char,'') for char in raw):
        reasons.append('unsupported_non_latin_transcript')
    return {'writing_mode':PHONON_MODES.get(name),'supported':not reasons,'unsupported_reasons':reasons,
            'vocabulary_policy':'none; optional model vocabulary hints omitted',
            'previous_piece_policy':'omitted to retain trained bare-transcript prompt contract'}


def phonon_messages(marker,mode,raw):
    return [{'role':'system','content':PHONON_SYSTEM_PROMPT+'\n'+marker['writing_modes'][mode]},
            {'role':'user','content':neutralize_control_tokens(raw)}]


def output_budget(raw, check_ratio=True):
    # UTF-8 bytes are a conservative sizing proxy for byte-level tokenizers,
    # not a measured token count. Report the estimate and actual worker IDs.
    estimate=len(raw.encode('utf-8'))
    return min(MAX_OUTPUT,max(96,math.ceil(estimate*(1.8 if check_ratio else 3.0))))


class NativeClient:
    """Bounded serial client; supervise.py owns hard deadlines and worker reap."""
    def __init__(self,binary,model,sha256,stderr_path,max_rss_mb=8192):
        self.unhealthy=False
        self.buffer=b''
        self.counter=0
        self.child=None
        self.ready={}
        fd=os.open(stderr_path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'w') as stderr:
            self.child=subprocess.Popen([sys.executable,str(NATIVE/'supervise.py'),str(binary),str(model),sha256,
                '--context',str(CONTEXT_TOKENS),'--max-rss-mb',str(max_rss_mb),
                '--prefix-cache','--copy-draft','--draft-max',str(DRAFT_TOKENS)],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=stderr,bufsize=0,start_new_session=True)
        os.set_blocking(self.child.stdin.fileno(),False)
        os.set_blocking(self.child.stdout.fileno(),False)
        try:
            self.ready=self.read(time.monotonic()+125)
            if self.ready.get('event')!='ready' or self.ready.get('model_sha256')!=sha256:
                raise RuntimeError('native ready/model identity mismatch')
        except BaseException:
            self.unhealthy=True
            self.close()
            raise

    def write(self,value,deadline):
        data=(json.dumps(value,ensure_ascii=False)+'\n').encode()
        if len(data)>MAX_FRAME:
            raise ValueError('native client frame exceeds 1 MiB')
        while data:
            remaining=deadline-time.monotonic()
            if remaining<=0 or not select.select([], [self.child.stdin], [], remaining)[1]:
                raise TimeoutError('native client write deadline')
            try:
                written=os.write(self.child.stdin.fileno(),data)
            except BlockingIOError:
                continue
            data=data[written:]

    def read(self,deadline):
        while b'\n' not in self.buffer:
            remaining=deadline-time.monotonic()
            if remaining<=0 or not select.select([self.child.stdout], [], [], remaining)[0]:
                raise TimeoutError('native client receive deadline')
            try:
                data=os.read(self.child.stdout.fileno(),65536)
            except BlockingIOError:
                continue
            if not data:
                raise RuntimeError('native supervisor closed output')
            self.buffer+=data
            if len(self.buffer)>2*MAX_FRAME:
                raise RuntimeError('native response buffer exceeded')
        line,self.buffer=self.buffer.split(b'\n',1)
        if len(line)>MAX_FRAME:
            raise RuntimeError('native response frame exceeded')
        value=json.loads(line)
        if not isinstance(value,dict):
            raise RuntimeError('native response is not an object')
        if value.get('event') in ('fatal','supervisor_failure'):
            raise RuntimeError('native process failure: '+str(value.get('error','unknown')))
        return value

    def generate(self,system,user,*,max_tokens,deadline_ms,draft_text='',cancel=None):
        if self.unhealthy:
            return {'event':'error','status':'native_unhealthy','error':'native_unhealthy'}
        self.counter+=1
        identity='native-'+str(self.counter)
        end=time.monotonic()+deadline_ms/1000+7
        try:
            self.write({'op':'generate','id':identity,'system':system,'user':user,
                'max_tokens':max_tokens,'deadline_ms':deadline_ms,'draft_text':draft_text},min(end,time.monotonic()+3))
            cancel_sent=False
            while True:
                if cancel is not None and cancel.is_set() and not cancel_sent:
                    self.write({'op':'cancel','id':identity},min(end,time.monotonic()+1))
                    cancel_sent=True
                # Poll cancellation while the independent supervisor bounds
                # native work. A short poll timeout is not a request failure.
                try:
                    response=self.read(min(end,time.monotonic()+.1))
                except TimeoutError:
                    if time.monotonic()<end:
                        continue
                    raise
                if response.get('id')==identity and response.get('event') in ('result','error'):
                    return response
        except (OSError,ValueError,RuntimeError,TimeoutError) as exc:
            self.unhealthy=True
            self.close()
            return {'event':'error','status':'native_transport_failure','error_type':type(exc).__name__}

    def close(self):
        child=self.child
        if child is None:
            return
        if child.poll() is None:
            try:
                self.write({'op':'shutdown'},time.monotonic()+1)
            except (OSError,ValueError,RuntimeError,TimeoutError):
                pass
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.send_signal(signal.SIGTERM)
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    # The existing supervisor normally reaps its independent
                    # worker group on TERM. Bound a wedged owner as a last resort.
                    worker_pid=self.ready.get('pid')
                    if isinstance(worker_pid,int) and worker_pid>1:
                        try:os.killpg(worker_pid,signal.SIGKILL)
                        except ProcessLookupError:pass
                    child.kill();child.wait()
        for pipe in (child.stdin,child.stdout):
            if pipe and not pipe.closed:
                pipe.close()


class NativeCleanup:
    def __init__(self,client,phonon_marker=None):
        self.client=client
        self.context=None
        self.calls=[]
        self.loaded=True
        self.phonon_marker=phonon_marker

    @property
    def unhealthy(self):
        return self.client.unhealthy

    def set_context(self,gate,context):
        if self.unhealthy:
            raise RuntimeError('retire unhealthy native process')
        self.context=(gate.system_prompt,dict(context))

    async def cleanup(self,raw,system_prompt,**kwargs):
        started=time.perf_counter()
        response={}
        budget=output_budget(raw,kwargs.get('check_ratio',True))
        def finish(text,applied,reason):
            elapsed=(time.perf_counter()-started)*1000
            result=CleanupResult(text,applied,int(elapsed),reason,
                input_tokens=len(response.get('prompt_tokens',[])),
                output_tokens=len(response.get('output_tokens',[])))
            metrics=asdict(result)
            metrics.pop('text',None)
            # MLX allocation metrics do not apply to a native worker.
            for key in tuple(metrics):
                if key.startswith('mlx_'):metrics.pop(key)
            metrics.update(native=response,eos=response.get('status')=='eos',
                prompt_contract='phonon' if self.phonon_marker else 'student',
                system_prompt_sha256=hashlib.sha256(system_prompt.encode()).hexdigest(),
                output_budget=budget,output_budget_proxy='UTF-8 byte count; not actual tokenizer count')
            self.calls.append(metrics)
            return result
        if self.context is None:
            return finish(raw,False,'missing_student_context')
        base,context=self.context
        if not base or not system_prompt.startswith(base):
            return finish(raw,False,'student_context_mismatch')
        if self.unhealthy:
            return finish(raw,False,'native_unhealthy')
        cancel=kwargs.get('cancel_event')
        if cancel is not None and cancel.is_set():
            return finish(raw,False,'cancelled')
        if self.phonon_marker:
            support=context['phonon']
            if not support['supported']:
                return finish(raw,False,support['unsupported_reasons'][0])
            messages=phonon_messages(self.phonon_marker,support['writing_mode'],raw)
        else:
            messages=student_messages(context,raw,system_prompt[len(base):])
        copy=kwargs.get('copy_draft',False) and kwargs.get('check_ratio',True) and not context.get('romanize',False)
        deadline=kwargs.get('timeout_ms')
        deadline=adaptive_timeout_ms(raw) if deadline is None else deadline
        deadline=max(1,min(120000,int(deadline)))
        response=self.client.generate(messages[0]['content'],messages[1]['content'],max_tokens=budget,
            deadline_ms=deadline,draft_text=raw if copy else '',cancel=cancel)
        status=response.get('status','request_error')
        if status!='eos':
            return finish(raw,False,status)
        text=restore_control_tokens(response.get('text',''))
        reason=check_divergence(raw,text,kwargs.get('allowed_terms')) if kwargs.get('check_ratio',True) else ('empty_output' if not text.strip() else None)
        return finish(raw if reason else text.strip(),not bool(reason),reason)


def recovery_probe(client,phonon_marker=None):
    context={'mode':'default','language':'en','romanize':False,'instructions':'','vocabulary':[]}
    messages=(phonon_messages(phonon_marker,'minimal','Please send the report tomorrow.') if phonon_marker
              else student_messages(context,'Please send the report tomorrow.'))
    def request(user):
        return client.generate(messages[0]['content'],user,max_tokens=128,deadline_ms=10000)
    first=request(messages[1]['content'])
    repeat=request(messages[1]['content'])
    overflow=request(' x'*(CONTEXT_TOKENS+1))
    recovered=request(messages[1]['content'])
    fields=('status','text','partial_text','prompt_tokens','output_tokens')
    passed=(first.get('status')=='eos' and all(all(first.get(k)==row.get(k) for k in fields) for row in (repeat,recovered))
        and overflow.get('status')=='context_limit' and not overflow.get('text') and not overflow.get('partial_text'))
    return {'passed':passed,'reference':first,'repeat':repeat,'context_overflow':overflow,'recovered':recovered}


def native_resources(client,runner=None):
    result={'scope':'end of replay, before shutdown, outside case timers','processes':{},
        'warning':'Worker and supervisor are separate observations; do not sum physical footprints or compare them as MLX allocation.'}
    for name,pid in (('worker',client.ready.get('pid')),('supervisor',client.child.pid)):
        row={'pid':pid,'physical_footprint_lines':[]}
        if not isinstance(pid,int) or pid<2:
            row['error']='invalid process id';result['processes'][name]=row;continue
        try:
            completed=(runner or subprocess.run)(['/usr/bin/vmmap','-summary',str(pid)],capture_output=True,text=True,timeout=10)
            row['vmmap_exit_code']=completed.returncode
            row['physical_footprint_lines']=[line.strip() for line in completed.stdout.splitlines()
                if line.strip().startswith(('Physical footprint:','Physical footprint (peak):'))]
        except (OSError,subprocess.SubprocessError) as exc:
            row['error_type']=type(exc).__name__
        result['processes'][name]=row
    return result


def summarize(cases,case_dir):
    results=[json.loads(p.read_text()) for p in case_dir.glob('*.json')]
    ids={r['id'] for r in results}
    missing=[c['id'] for c in cases if c['id'] not in ids]
    counts={status:sum(r['status']==status for r in results) for status in sorted({r['status'] for r in results})}
    coverage=[r['phonon_coverage'] for r in results if 'phonon_coverage' in r]
    coverage_reasons=sorted({reason for row in coverage for reason in row['unsupported_reasons']})
    return {'expected_cases':len(cases),'recorded_cases':len(results),'status_counts':counts,
        'phonon_coverage':{'assessed_cases':len(coverage),'supported_cases':sum(row['supported'] for row in coverage),
            'unsupported_cases':sum(not row['supported'] for row in coverage),
            'reason_counts':{reason:sum(reason in row['unsupported_reasons'] for row in coverage) for reason in coverage_reasons}},
        'missing_ids':missing,'failed_or_missing_cases':len(missing)+sum(r['status']!='ok' for r in results),
        'length_limit_calls':sum(call.get('reason')=='length' for r in results for call in r['calls'])}


async def replay(args):
    from velora_engine.config import Config
    manifest=args.manifest.expanduser().resolve(strict=True)
    stt_path=args.stt.expanduser().resolve(strict=True)
    stt_meta_path=args.stt_meta.expanduser().resolve(strict=True)
    stt_meta=validate_stt_provenance(manifest,stt_path,stt_meta_path)
    cases,stt=read_inputs(manifest,stt_path)
    if args.limit is not None:
        if args.limit<1:raise ValueError('positive limit required')
        cases=cases[:args.limit]
    if not cases:raise ValueError('empty cohort')
    binary=args.binary.expanduser().resolve(strict=True)
    model=args.model.expanduser().resolve(strict=True)
    if not binary.is_file() or not os.access(binary,os.X_OK) or not model.is_file():
        raise ValueError('executable binary and local GGUF regular file required')
    if not re.fullmatch('[0-9a-f]{64}',args.sha256) or digest(model)!=args.sha256:
        raise ValueError('local GGUF SHA256 mismatch')
    if not re.fullmatch('[0-9a-f]{40}',args.model_revision):raise ValueError('full immutable model revision required')
    phonon_marker=load_prompt_contract(args)
    output=private_dir(args.output)
    upstream=json.loads((NATIVE/'UPSTREAM.json').read_text())
    expected={'schema':1,'manifest_sha256':digest(manifest),'stt_sha256':digest(stt_path),'stt_metadata_sha256':digest(stt_meta_path),
        'prompt_contract':'phonon' if phonon_marker else 'student',
        'phonon_metadata_sha256':PHONON_METADATA_SHA256 if phonon_marker else None,
        'phonon_vocabulary_policy':'none' if phonon_marker else None,
        'stt_glossary_sha256':stt_meta['glossary']['sha256'],
        'binary_sha256':digest(binary),'model_sha256':args.sha256,'model_repository':args.model_repository,'model_revision':args.model_revision,
        'source_sha256':source_hash(),'runner_sha256':digest(Path(__file__)),
        'native_source_sha256':{p.name:digest(p) for p in sorted(NATIVE.iterdir()) if p.is_file()},
        'upstream_runtime':{key:upstream[key] for key in ('repository','commit','license','source_tree_sha256')},
        'context_tokens':CONTEXT_TOKENS,'copy_draft_tokens':DRAFT_TOKENS,'prefix_cache':True,'max_output_tokens':MAX_OUTPUT,
        'max_rss_mb':args.max_rss_mb,'limit':args.limit,'case_count':len(cases),
        'case_ids_sha256':hashlib.sha256(json.dumps([c['id'] for c in cases],separators=(',',':')).encode()).hexdigest()}
    config_path=output/'config-snapshot';meta_path=output/'native-run.json'
    if not meta_path.exists():
        if config_path.exists():raise ValueError('incomplete setup; use a new output directory')
        snapshot_config(args.config_home,config_path);config=Config(config_path)
        validate_stt_provenance(manifest,stt_path,stt_meta_path,config)
        for path in config_path.rglob('*'):os.chmod(path,0o700 if path.is_dir() else 0o600)
        expected['snapshot_sha256']=hash_tree(config_path)
        private_write(meta_path,{**expected,'backend':'native GGUF worker; declared prompt contract; production formatting gate/splitting/postprocess',
            'phonon_limitations':('Stock resolved writing modes only; Latin transcript coverage is not an English-language classifier. '
                'No optional vocabulary hints or previous-piece prompt context; custom prompts/formatting and romanization fall back. '
                'Uses our pinned llama.cpp worker, not Phonon application runtime or its DFlash drafter.') if phonon_marker else None,
            'semantic_quality_evaluated':False,'model_qualified':False,
            'comparison_limit':'Different model artifact, quantization and prompt from production MLX; not backend-only parity.',
            'timing':'paired saved offline STT plus later cleanup; excludes capture, insertion, model load and probes',
            'output_budget':'min(512,max(96,ceil(UTF8_bytes*(1.8 or 3.0)))); estimate, not tokenizer count',
            'deadline_policy':'native whole request includes prefill; cooperative deadline plus supervisor2s hard grace; differs from MLX soft first-token budget',
            'memory':'native worker RSS and separate process physical footprints; MLX allocation not applicable',
            'resume':'retired worker exits70 after persisting the current failure; resume retains failed cases and processes remaining cases'})
    else:
        expected['snapshot_sha256']=hash_tree(config_path)
        saved=json.loads(meta_path.read_text())
        if any(saved.get(k)!=v for k,v in expected.items()):raise ValueError('run provenance changed; choose a new output directory')
        config=Config(config_path)
        if hash_tree(config_path)!=expected['snapshot_sha256']:raise ValueError('config snapshot mutated during load')
        validate_stt_provenance(manifest,stt_path,stt_meta_path,config)
    case_dir=output/'cases';case_dir.mkdir(mode=0o700,exist_ok=True);os.chmod(case_dir,0o700)
    names={hashlib.sha256(str(c['id']).encode()).hexdigest()+'.json' for c in cases}
    if any(p.name not in names or p.is_symlink() for p in case_dir.glob('*.json')):raise ValueError('unexpected/unsafe case result')
    run_tag=str(time.time_ns())
    run={'started_at_unix_s':time.time(),'model_loaded':False}
    client=None
    exit_code=0
    try:
        started=time.perf_counter()
        client=NativeClient(binary,model,args.sha256,output/f'native-{run_tag}.stderr.log',args.max_rss_mb)
        run.update(model_loaded=True,load_seconds=time.perf_counter()-started,ready=client.ready)
        if client.ready.get('llama_commit')!=upstream['commit']:raise RuntimeError('native upstream pin mismatch')
        expected_ready={'context_tokens':CONTEXT_TOKENS,'copy_draft':True,'copy_draft_max':DRAFT_TOKENS,'prefix_reuse':True}
        if any(client.ready.get(key)!=value for key,value in expected_ready.items()):
            raise RuntimeError('native worker did not activate the requested experiment flags')
        run['before_recovery']=recovery_probe(client,phonon_marker)
        if not run['before_recovery']['passed']:raise RuntimeError('native startup recovery probe failed')
        cleanup=NativeCleanup(client,phonon_marker);server=make_server(config,cleanup)
        for case in cases:
            cid=case['id'];destination=case_dir/(hashlib.sha256(str(cid).encode()).hexdigest()+'.json')
            if destination.exists():
                prior=json.loads(destination.read_text())
                if prior.get('id')!=cid or prior.get('input_sha256')!=case.get('input_sha256'):raise ValueError('existing case identity mismatch')
                continue
            source=stt[cid]
            record={'id':cid,'input_sha256':case.get('input_sha256'),'status':'stt_failed',
                'stt_s':source.get('stt_s'),'audio_read_s':source.get('audio_read_s'),'stt_total_s':source.get('total_s'),
                'cleanup_s':None,'paired_stt_cleanup_s':None,'paired_replay_total_s':None,'calls':[]}
            if source.get('status')=='ok' and isinstance(source.get('raw'),str):
                cleanup.calls=[];started=time.perf_counter()
                try:
                    gate,context=controls(config,source['raw'],case)
                    if phonon_marker:
                        context['phonon']=phonon_context(gate,source['raw'])
                        record['phonon_coverage']=context['phonon']
                    cleanup.set_context(gate,context)
                    text,mode,ms,applied,reason=await server._apply_formatting(source['raw'],case.get('bundle_id'),case.get('app_name'),case.get('mode'))
                    record.update(status=cleanup_status(cleanup.calls,applied,reason),text=text,mode=mode,
                        cleanup_model_ms=ms,cleanup_applied=applied,cleanup_reason=reason)
                    if phonon_marker and not context['phonon']['supported']:
                        record['status']='unsupported_fallback'
                except Exception as exc:
                    record.update(status='cleanup_failed',error_type=type(exc).__name__)
                record['cleanup_s']=time.perf_counter()-started;record['calls']=cleanup.calls
                if isinstance(record['stt_s'],(int,float)):record['paired_stt_cleanup_s']=record['stt_s']+record['cleanup_s']
                if isinstance(record['stt_total_s'],(int,float)):record['paired_replay_total_s']=record['stt_total_s']+record['cleanup_s']
            temp=destination.with_suffix('.tmp')
            if temp.exists():temp.unlink()
            private_write(temp,record);os.replace(temp,destination)
            if client.unhealthy:
                exit_code=70;break
        if not client.unhealthy:
            run['after_recovery']=recovery_probe(client,phonon_marker)
            if not run['after_recovery']['passed']:exit_code=1
            if not client.unhealthy:run['resources']=native_resources(client)
    except (Exception,KeyboardInterrupt) as exc:
        run.update(error_type=type(exc).__name__,error=str(exc));exit_code=1
    finally:
        if client is not None:
            client.close();run['supervisor_exit_code']=client.child.returncode
            if client.child.returncode and exit_code==0:exit_code=1
        run['summary']=summarize(cases,case_dir)
        run['exit_code']=exit_code
        private_write(output/f'native-session-{run_tag}.json',run)
    print(json.dumps({'output':str(case_dir),**run['summary'],'exit_code':exit_code}))
    return exit_code


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('manifest','stt','stt-meta','output','binary','model'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--sha256',required=True)
    parser.add_argument('--model-repository',required=True);parser.add_argument('--model-revision',required=True)
    parser.add_argument('--prompt-contract',choices=('student','phonon'),default='student')
    parser.add_argument('--phonon-metadata',type=Path,help='Pinned phonon_refiner.json; required with phonon contract')
    parser.add_argument('--config-home',type=Path,default=Path.home()/'.velora')
    parser.add_argument('--max-rss-mb',type=int,default=8192);parser.add_argument('--limit',type=int)
    args=parser.parse_args()
    if not 512<=args.max_rss_mb<=32768:parser.error('max-rss-mb must be512..32768')
    def terminate(signum,frame):
        raise InterruptedError('native replay received signal '+str(signum))
    for signum in (signal.SIGTERM,signal.SIGHUP):signal.signal(signum,terminate)
    return asyncio.run(replay(args))


if __name__=='__main__':raise SystemExit(main())
