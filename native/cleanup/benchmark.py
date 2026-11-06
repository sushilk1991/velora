#!/usr/bin/env python3
"""Public-data native worker benchmark; requires explicit reserved GPU window."""
import argparse,hashlib,json,os,pathlib,selectors,statistics,subprocess,sys,time
p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--model',required=True);p.add_argument('--sha256',required=True);p.add_argument('--data',required=True);p.add_argument('--out',required=True);p.add_argument('--reference-tokens');p.add_argument('--reference-output');p.add_argument('--limit',type=int,default=64);p.add_argument('--context',type=int,default=4096);p.add_argument('--copy-draft',action='store_true');p.add_argument('--prefix-cache',action='store_true');p.add_argument('--verbose',action='store_true');
for flag in ('recurrent-rollback','backend-sampling','backend-token-only','direct-argmax','trace-runtime','bounded-swa','student-prefix-cache'):p.add_argument('--'+flag,action='store_true')
p.add_argument('--draft-max',type=int,choices=range(1,9),default=3)
p.add_argument('--prefill-batch',type=int,choices=(16,32,64,128,256,512),default=128)
p.add_argument('--research-long-context',action='store_true')
p.add_argument('--max-output-tokens',type=int,default=512)
p.add_argument('--max-tokens',type=int,default=256)
p.add_argument('--deadline-ms',type=int,default=10000)
a=p.parse_args()
if not (128<=a.context<=4096 or a.research_long_context and a.context in (8192,16384)):p.error('context above4096 requires research-long-context and8192/16384')
if not 1<=a.max_tokens<=a.max_output_tokens<=(2048 if a.research_long_context else 512):p.error('invalid output bounds')
if not 1<=a.deadline_ms<=120000:p.error('invalid request deadline')
from cleanup import render_messages
from benchmark_checks import record_result,summarize,repeat_matches,state_recovery_checks,runtime_qualification,header_evidence,output_reference_check
rows=[json.loads(s) for s in pathlib.Path(a.data).read_text().splitlines() if s.strip()][:a.limit]
if not rows or any(r.get('visibility')!='public' for r in rows):raise ValueError('public examples required')
if pathlib.Path(a.out).exists():raise FileExistsError(a.out)
reference={r['id']:r['tokens'] for r in json.loads(pathlib.Path(a.reference_tokens).read_text())['rows']} if a.reference_tokens else None
reference_output=None;reference_output_meta={};reference_output_error=None
if a.reference_output:
 try:
  reference_path=pathlib.Path(a.reference_output)
  reference_output=[json.loads(line) for line in reference_path.read_text().splitlines() if line.strip()]
  reference_output_meta=json.loads(pathlib.Path(str(reference_path)+'.meta.json').read_text())
 except (OSError,ValueError,TypeError) as exc:reference_output_error=type(exc).__name__
child=subprocess.Popen([sys.executable,str(pathlib.Path(__file__).with_name('supervise.py')),a.binary,a.model,a.sha256,'--context',str(a.context),'--prefill-batch',str(a.prefill_batch),'--max-output-tokens',str(a.max_output_tokens)]+(['--research-long-context'] if a.research_long_context else [])+(['--copy-draft'] if a.copy_draft else [])+(['--prefix-cache'] if a.prefix_cache else [])+(['--verbose'] if a.verbose else [])+['--draft-max',str(a.draft_max)]+['--'+flag for flag in ('recurrent-rollback','backend-sampling','backend-token-only','direct-argmax','trace-runtime','bounded-swa','student-prefix-cache') if getattr(a,flag.replace('-','_'))],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=None,bufsize=0)
selector=selectors.DefaultSelector();selector.register(child.stdout,selectors.EVENT_READ);buffer=b'';events=[]
def read(timeout=130):
 global buffer
 end=time.monotonic()+timeout
 while b'\n' not in buffer:
  if not selector.select(max(0,end-time.monotonic())):raise TimeoutError('client receive deadline')
  part=os.read(child.stdout.fileno(),65536)
  if not part:raise RuntimeError('worker closed output')
  buffer+=part
 line,buffer=buffer.split(b'\n',1)
 value=json.loads(line);events.append(value)
 if value.get('event') in ['fatal','supervisor_failure']:raise RuntimeError(value)
 return value

def send(value):child.stdin.write((json.dumps(value,ensure_ascii=False)+'\n').encode());child.stdin.flush()
def generate_messages(system,user,identity,max_tokens=None,draft_text=""):
 send({'op':'generate','id':identity,'system':system,'user':user,'draft_text':draft_text if a.copy_draft else '', 'max_tokens':a.max_tokens if max_tokens is None else max_tokens,'deadline_ms':a.deadline_ms})
 while True:
  response=read(a.deadline_ms/1000+5)
  if response.get('id')==identity and response.get('event') in ['result','error']:return response
def generate(row,identity,max_tokens=None):
 messages=render_messages(row)
 return generate_messages(messages[0]['content'],messages[1]['content'],identity,max_tokens,row['raw'])
records=[]
meta={'runtime_qualified':False,'model_sha256':a.sha256,'quantization':'official GGUF Q8_0; differs from MLX8bit','data_sha256':hashlib.sha256(pathlib.Path(a.data).read_bytes()).hexdigest(),'copy_draft':a.copy_draft,'draft_max_tokens':a.draft_max,'recurrent_rollback':a.recurrent_rollback,'backend_sampling':a.backend_sampling,'backend_token_only':a.backend_token_only,'direct_argmax':a.direct_argmax,'trace_runtime':a.trace_runtime,'prefix_reuse':a.prefix_cache,'context_tokens':a.context,'verbose':a.verbose,'temperature':0,'max_tokens':256}
meta.update(prefill_batch_tokens=a.prefill_batch,research_long_context=a.research_long_context,max_tokens=a.max_tokens,
            max_output_tokens=a.max_output_tokens,deadline_ms=a.deadline_ms,bounded_swa=a.bounded_swa,
            student_prefix_cache=a.student_prefix_cache,
            quantization='explicit GGUF artifact identified by SHA256; no inferred quantization or backend-only parity')
meta.update(reference_output_supplied=bool(a.reference_output),reference_output_sha256=hashlib.sha256(pathlib.Path(a.reference_output).read_bytes()).hexdigest() if a.reference_output and reference_output_error is None else None,
            output_reference_parity=False,output_reference_errors=[reference_output_error] if reference_output_error else [],
            reference_tokens_supplied=reference is not None,
            reference_tokens_sha256=hashlib.sha256(pathlib.Path(a.reference_tokens).read_bytes()).hexdigest() if reference is not None else None,
            reference_parity_scope='prompt_tokens only; generated-output parity requires separate evidence')
source_dir=pathlib.Path(__file__).resolve().parent
meta['binary_sha256']=hashlib.sha256(pathlib.Path(a.binary).read_bytes()).hexdigest()
meta['source_sha256']={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(source_dir.iterdir()) if f.is_file()}
meta['upstream']=json.loads((source_dir/'UPSTREAM.json').read_text())
try:
 before=time.perf_counter();meta['ready']=read();meta['load_seconds']=time.perf_counter()-before
 if meta['ready'].get('event')!='ready':raise RuntimeError('no ready event')
 if a.student_prefix_cache and meta['ready'].get('student_prefix_cache') is not True:raise RuntimeError('student prefix flag not activated')
 if a.bounded_swa and (meta['ready'].get('bounded_swa') is not True or meta['ready'].get('swa_full') is not False):raise RuntimeError('bounded SWA flag not activated')
 warmup=generate(rows[0],'warmup',1);meta['warmup_status']=warmup.get('status','request_error')
 if meta['warmup_status'] not in ['length','eos']:raise RuntimeError('warmup failed: '+str(warmup))
 mismatches=[]
 with open(a.out,'x') as out:
  for row in rows:
   before=time.perf_counter();response=generate(row,row['id']);seconds=time.perf_counter()-before
   if reference is not None and response.get('prompt_tokens',[])!=reference.get(row['id']):mismatches.append(row['id'])
   result=record_result(row['id'],response,seconds);records.append(result)
   out.write(json.dumps(result,ensure_ascii=False)+'\n');out.flush()
 meta.update(summarize(records,len(rows)));meta['prompt_mismatch_ids']=mismatches
 # Fixed repeated request must reset recurrent/KV state and reproduce.
 first=generate(rows[0],'repeat-a');second=generate(rows[0],'repeat-b')
 meta['repeat_equal']=repeat_matches(first,second)
 meta['repeat_statuses']=[first.get('status'),second.get('status')]
 messages=render_messages(rows[0]);send({'op':'generate','id':'cancel-probe','system':messages[0]['content'],'user':messages[1]['content'],'draft_text':rows[0]['raw'] if a.copy_draft else '', 'max_tokens':min(512,a.max_output_tokens),'deadline_ms':10000});time.sleep(.005);send({'op':'cancel','id':'cancel-probe'})
 while True:
  response=read(5)
  if response.get('id')=='cancel-probe' and response.get('event')=='result':meta['cancel_status']=response['status'];break
 meta['after_cancel_status']=generate(rows[0],'after-cancel',a.max_tokens).get('status','request_error')
 # Actual model-state invalidation/error fixtures, excluded from the timed64 rows.
 original_system,original_user=messages[0]['content'],messages[1]['content']
 changed_system=generate_messages(original_system+'\nPreserve the meaning of the dictated text.',original_user,'system-change',draft_text=rows[0]['raw'])
 restored_system=generate(rows[0],'system-restored')
 context_error=generate_messages(original_system,original_user+' x'*(a.context+1),'context-overflow')
 context_recovery=generate(rows[0],'after-context-overflow')
 meta['state_recovery']=state_recovery_checks(first,changed_system,restored_system,context_error,context_recovery,a.prefix_cache,a.student_prefix_cache)
 meta['state_recovery']['responses']={'changed_system':changed_system,'restored_system':restored_system,'context_error':context_error,'context_recovery':context_recovery}

 meta['backend_token_parity']=reference is not None and not mismatches
 meta['prompt_token_parity']=meta['backend_token_parity']
 meta['student_header_evidence']=header_evidence(records)
 meta['student_header_exercised']=meta['student_header_evidence']['exercised']
 if reference_output is not None:
  checked=output_reference_check(records,reference_output,reference_output_meta,meta,[row['id'] for row in rows])
  meta['output_reference_parity']=checked['passed'];meta['output_reference_errors']=checked['errors']
 meta['protocol_recovery_passed']=(meta['all_main_rows_eos'] and meta['repeat_equal']
     and meta['cancel_status']=='cancelled' and meta['after_cancel_status']=='eos'
     and meta['state_recovery']['passed'])
 meta['runtime_qualified']=runtime_qualification(meta,reference is not None)
 try:
  vm=subprocess.run(['/usr/bin/vmmap','-summary',str(meta['ready']['pid'])],text=True,capture_output=True,timeout=10)
  meta['physical_footprint']=[s.strip() for s in vm.stdout.splitlines() if 'Physical footprint' in s]
 except Exception as exc:meta['footprint_error']=repr(exc)
finally:
 try:send({'op':'shutdown'})
 except (BrokenPipeError,OSError):pass
 try:child.wait(timeout=5)
 except subprocess.TimeoutExpired:child.terminate();child.wait(timeout=5)
 selector.close();meta['supervisor_exit_code']=child.returncode
 meta.update(summarize(records,len(rows)))
 meta['runtime_qualified']=runtime_qualification(meta,reference is not None)
 pathlib.Path(a.out+'.meta.json').write_text(json.dumps(meta,indent=2)+'\n')
print(json.dumps(meta,indent=2))
sys.exit(0 if meta['runtime_qualified'] else 1)
