#!/usr/bin/env python3
"""Nonblocking bounded JSONL owner; hard-reap one independently grouped worker.

One in-flight generation. Keep stdin open until results arrive. EOF cancels work.
No model, template or network logic runs here.
"""
import argparse,json,os,selectors,signal,subprocess,sys,time
MAX_FRAME=1024*1024
MAX_QUEUE=2*MAX_FRAME

def main():
    p=argparse.ArgumentParser()
    p.add_argument('binary');p.add_argument('model');p.add_argument('sha256')
    p.add_argument('--gpu-layers',type=int,default=99);p.add_argument('--context',type=int,default=4096)
    p.add_argument('--max-rss-mb',type=int,default=8192)
    p.add_argument('--copy-draft',action='store_true');p.add_argument('--prefix-cache',action='store_true');p.add_argument('--verbose',action='store_true')
    p.add_argument('--draft-max',type=int,choices=range(1,9),default=3)
    p.add_argument('--prefill-batch',type=int,choices=(16,32,64,128,256,512),default=128)
    p.add_argument('--research-long-context',action='store_true')
    p.add_argument('--max-output-tokens',type=int,default=512)
    for flag in ('recurrent-rollback','backend-sampling','backend-token-only','direct-argmax','trace-runtime','bounded-swa','student-prefix-cache'):p.add_argument('--'+flag,action='store_true')
    p.add_argument('--startup-deadline-ms',type=int,default=120000)
    p.add_argument('--hard-grace-ms',type=int,default=2000)
    a=p.parse_args()
    if not 1<=a.startup_deadline_ms<=120000 or not 0<=a.hard_grace_ms<=10000:p.error('invalid deadline bound')
    if not (128<=a.context<=4096 or a.research_long_context and a.context in (8192,16384)):p.error('invalid context research bound')
    if not 1<=a.max_output_tokens<=(2048 if a.research_long_context else 512):p.error('invalid output research bound')
    termination_signal=None
    def owner_signal(signum,frame):
        nonlocal termination_signal
        termination_signal=signum
    for signum in [signal.SIGTERM,signal.SIGHUP,signal.SIGINT]:signal.signal(signum,owner_signal)
    flags=(['--copy-draft'] if a.copy_draft else [])+(['--prefix-cache'] if a.prefix_cache else [])+(['--verbose'] if a.verbose else [])
    flags+=['--draft-max='+str(a.draft_max)]
    flags+=['--prefill-batch='+str(a.prefill_batch),'--max-output-tokens='+str(a.max_output_tokens)]
    if a.research_long_context:flags+=['--research-long-context']
    flags+=['--'+flag for flag in ('recurrent-rollback','backend-sampling','backend-token-only','direct-argmax','trace-runtime','bounded-swa','student-prefix-cache') if getattr(a,flag.replace('-','_'))]
    child=subprocess.Popen([a.binary,a.model,a.sha256,str(a.gpu_layers),str(a.context),str(a.max_rss_mb)]+flags,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=None,start_new_session=True,bufsize=0)
    selector=selectors.DefaultSelector();input_fd=sys.stdin.fileno();output_fd=sys.stdout.fileno()
    write_fd=child.stdin.fileno();read_fd=child.stdout.fileno()
    for fd in [input_fd,output_fd,write_fd,read_fd]:os.set_blocking(fd,False)
    selector.register(input_fd,selectors.EVENT_READ,'input');selector.register(read_fd,selectors.EVENT_READ,'output')
    buffers={'input':b'','output':b''};queues={write_fd:b'',output_fd:b''}
    pending={};ready=False;startup=time.monotonic()+a.startup_deadline_ms/1000;shutdown=None;next_rss=0;failure=None
    def enqueue(fd,data):
        if len(queues[fd])+len(data)>MAX_QUEUE:raise ValueError('bounded write queue exceeded')
        if not queues[fd]:selector.register(fd,selectors.EVENT_WRITE,'write')
        queues[fd]+=data
    def emit(value):enqueue(output_fd,(json.dumps(value)+'\n').encode())
    def reject(identity,message):emit({'event':'error','id':identity,'error':message})
    def handle(value,line,kind):
        nonlocal ready,shutdown
        if kind=='output':
            if value.get('event')=='ready':ready=True
            if value.get('event') in ['result','error']:pending.pop(value.get('id'),None)
            enqueue(output_fd,line+b'\n');return
        op=value.get('op');identity=value.get('id')
        if op=='generate':
            if not ready:reject(identity,'not_ready');return
            if pending:reject(identity,'busy');return
            ms=value.get('deadline_ms',10000)
            if not isinstance(ms,int) or isinstance(ms,bool) or not 1<=ms<=120000:reject(identity,'invalid_deadline');return
            if not isinstance(identity,str) or not identity or len(identity)>128:reject(None,'invalid_id');return
            pending[identity]=time.monotonic()+ms/1000+a.hard_grace_ms/1000
        elif op=='cancel':
            if not isinstance(identity,str) or not identity or len(identity)>128:reject(None,'invalid_id');return
            if identity in pending:pending[identity]=min(pending[identity],time.monotonic()+a.hard_grace_ms/1000)
        elif op=='shutdown':shutdown=time.monotonic()+3
        elif op!='ping':reject(identity,'unknown_operation');return
        enqueue(write_fd,line+b'\n')
    try:
        exited_at=None
        while True:
            now=time.monotonic()
            if termination_signal is not None:raise RuntimeError('supervisor received signal '+str(termination_signal))
            if child.poll() is not None:
                if exited_at is None:exited_at=now
                # Drain pending output briefly, never block on a non-reading client.
                if now-exited_at>1 or (not queues[output_fd] and read_fd not in selector.get_map()):break
            else:
                if not ready and now>startup:raise TimeoutError('worker readiness deadline')
                if shutdown and now>shutdown:raise TimeoutError('worker shutdown deadline')
                if pending and now>min(pending.values()):raise TimeoutError('worker request/cancel deadline')
                if now>=next_rss:
                    next_rss=now+.25
                    try:
                        measured=subprocess.run(['/bin/ps','-o','rss=','-p',str(child.pid)],capture_output=True,text=True,timeout=.25)
                    except (OSError,subprocess.SubprocessError):
                        measured=None
                    if measured is not None and measured.returncode==0 and int(measured.stdout.strip() or 0)*1024>a.max_rss_mb*1024*1024:raise MemoryError('worker process RSS limit')
            for key,mask in selector.select(.02):
                fd=key.fd
                if key.data=='write':
                    try:n=os.write(fd,queues[fd])
                    except BlockingIOError:continue
                    except BrokenPipeError:raise RuntimeError('output peer closed pipe')
                    queues[fd]=queues[fd][n:]
                    if not queues[fd]:selector.unregister(fd)
                    continue
                kind=key.data
                try:data=os.read(fd,65536)
                except BlockingIOError:continue
                if not data:
                    selector.unregister(fd)
                    if kind=='output' and child.poll() is None and shutdown is None:
                        raise RuntimeError('unexpected worker stdout EOF')
                    if kind=='input' and child.poll() is None:
                        enqueue(write_fd,b'{"op":"shutdown"}\n');shutdown=time.monotonic()+3
                    continue
                buffers[kind]+=data
                if len(buffers[kind])>MAX_FRAME and b'\n' not in buffers[kind]:raise ValueError('frame exceeds1MiB')
                while b'\n' in buffers[kind]:
                    line,buffers[kind]=buffers[kind].split(b'\n',1)
                    if len(line)>MAX_FRAME:raise ValueError('frame exceeds1MiB')
                    value=json.loads(line)
                    if not isinstance(value,dict):raise ValueError('JSON object required')
                    handle(value,line,kind)
    except BaseException as exc:
        failure=repr(exc)
        # Best-effort nonblocking error; termination never depends on delivering it.
        try:os.write(output_fd,(json.dumps({'event':'supervisor_failure','error':failure})+'\n').encode())
        except (BlockingIOError,BrokenPipeError):pass
    finally:
        if child.poll() is None:
            os.killpg(child.pid,signal.SIGTERM)
            try:child.wait(timeout=.5)
            except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
        selector.close()
    return 1 if failure else child.returncode

if __name__=='__main__':sys.exit(main())
