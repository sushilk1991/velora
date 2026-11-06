#!/usr/bin/env python3
"""Public-data native worker benchmark; requires explicit reserved GPU window."""
import argparse,hashlib,json,os,pathlib,selectors,statistics,subprocess,sys,time
p=argparse.ArgumentParser();p.add_argument('--binary',required=True);p.add_argument('--model',required=True);p.add_argument('--sha256',required=True);p.add_argument('--data',required=True);p.add_argument('--out',required=True);p.add_argument('--reference-tokens');p.add_argument('--limit',type=int,default=64);p.add_argument('--context',type=int,default=4096);p.add_argument('--copy-draft',action='store_true');p.add_argument('--prefix-cache',action='store_true');p.add_argument('--verbose',action='store_true');a=p.parse_args()
if not 128<=a.context<=4096:p.error('context must be 128..4096')
from cleanup import render_messages
from benchmark_checks import record_result,summarize,repeat_matches,state_recovery_checks
rows=[json.loads(s) for s in pathlib.Path(a.data).read_text().splitlines() if s.strip()][:a.limit]
if not rows or any(r.get('visibility')!='public' for r in rows):raise ValueError('public examples required')
if pathlib.Path(a.out).exists():raise FileExistsError(a.out)
reference={r['id']:r['tokens'] for r in json.loads(pathlib.Path(a.reference_tokens).read_text())['rows']} if a.reference_tokens else None
child=subprocess.Popen([sys.executable,str(pathlib.Path(__file__).with_name('supervise.py')),a.binary,a.model,a.sha256,'--context',str(a.context)]+(['--copy-draft'] if a.copy_draft else [])+(['--prefix-cache'] if a.prefix_cache else [])+(['--verbose'] if a.verbose else []),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=None,bufsize=0)
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
def generate_messages(system,user,identity,max_tokens=256,draft_text=""):
 send({'op':'generate','id':identity,'system':system,'user':user,'draft_text':draft_text if a.copy_draft else '', 'max_tokens':max_tokens,'deadline_ms':10000})
 while True:
  response=read(15)
  if response.get('id')==identity and response.get('event') in ['result','error']:return response
def generate(row,identity,max_tokens=256):
 messages=render_messages(row)
 return generate_messages(messages[0]['content'],messages[1]['content'],identity,max_tokens,row['raw'])
records=[]
meta={'runtime_qualified':False,'model_sha256':a.sha256,'quantization':'official GGUF Q8_0; differs from MLX8bit','data_sha256':hashlib.sha256(pathlib.Path(a.data).read_bytes()).hexdigest(),'copy_draft':a.copy_draft,'draft_max_tokens':3,'prefix_reuse':a.prefix_cache,'context_tokens':a.context,'verbose':a.verbose,'temperature':0,'max_tokens':256}
source_dir=pathlib.Path(__file__).resolve().parent
meta['binary_sha256']=hashlib.sha256(pathlib.Path(a.binary).read_bytes()).hexdigest()
meta['source_sha256']={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(source_dir.iterdir()) if f.is_file()}
meta['upstream']=json.loads((source_dir/'UPSTREAM.json').read_text())
try:
 before=time.perf_counter();meta['ready']=read();meta['load_seconds']=time.perf_counter()-before
 if meta['ready'].get('event')!='ready':raise RuntimeError('no ready event')
 warmup=generate(rows[0],'warmup',1);meta['warmup_status']=warmup.get('status','request_error')
 if meta['warmup_status'] not in ['length','eos']:raise RuntimeError('warmup failed: '+str(warmup))
 mismatches=[]
 with open(a.out,'x') as out:
  for row in rows:
   before=time.perf_counter();response=generate(row,row['id']);seconds=time.perf_counter()-before
   if reference is not None and response.get('prompt_tokens',[])!=reference[row['id']]:mismatches.append(row['id'])
   result=record_result(row['id'],response,seconds);records.append(result)
   out.write(json.dumps(result,ensure_ascii=False)+'\n');out.flush()
 meta.update(summarize(records,len(rows)));meta['prompt_mismatch_ids']=mismatches
 # Fixed repeated request must reset recurrent/KV state and reproduce.
 first=generate(rows[0],'repeat-a');second=generate(rows[0],'repeat-b')
 meta['repeat_equal']=repeat_matches(first,second)
 meta['repeat_statuses']=[first.get('status'),second.get('status')]
 messages=render_messages(rows[0]);send({'op':'generate','id':'cancel-probe','system':messages[0]['content'],'user':messages[1]['content'],'draft_text':rows[0]['raw'] if a.copy_draft else '', 'max_tokens':512,'deadline_ms':10000});time.sleep(.005);send({'op':'cancel','id':'cancel-probe'})
 while True:
  response=read(5)
  if response.get('id')=='cancel-probe' and response.get('event')=='result':meta['cancel_status']=response['status'];break
 meta['after_cancel_status']=generate(rows[0],'after-cancel',256).get('status','request_error')
 # Actual model-state invalidation/error fixtures, excluded from the timed64 rows.
 original_system,original_user=messages[0]['content'],messages[1]['content']
 changed_system=generate_messages(original_system+'\nPreserve the meaning of the dictated text.',original_user,'system-change',draft_text=rows[0]['raw'])
 restored_system=generate(rows[0],'system-restored')
 context_error=generate_messages(original_system,original_user+' x'*(a.context+1),'context-overflow')
 context_recovery=generate(rows[0],'after-context-overflow')
 meta['state_recovery']=state_recovery_checks(first,changed_system,restored_system,context_error,context_recovery,a.prefix_cache)
 meta['state_recovery']['responses']={'changed_system':changed_system,'restored_system':restored_system,'context_error':context_error,'context_recovery':context_recovery}

 meta['runtime_qualified']=meta['all_main_rows_eos'] and meta['repeat_equal'] and meta['cancel_status']=='cancelled' and meta['after_cancel_status']=='eos' and meta['state_recovery']['passed']
 meta['backend_token_parity']=reference is not None and not mismatches
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
 meta['runtime_qualified']=meta['runtime_qualified'] and child.returncode==0
 pathlib.Path(a.out+'.meta.json').write_text(json.dumps(meta,indent=2)+'\n')
print(json.dumps(meta,indent=2))
sys.exit(0 if meta['runtime_qualified'] else 1)
