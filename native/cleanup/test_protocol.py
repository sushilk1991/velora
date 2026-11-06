"""CPU-only checks; never initialize a model or run Metal."""
import argparse,json,subprocess,tempfile,pathlib
p=argparse.ArgumentParser();p.add_argument('binary');a=p.parse_args()
def run(*args):
 r=subprocess.run([a.binary,*args],capture_output=True,text=True,timeout=10)
 return r,[json.loads(line) for line in r.stdout.splitlines()]
r,events=run('--selftest');assert r.returncode==0 and events[0]['event']=='selftest' and events[0]['ok'] and events[0]['model_loaded'] is False
assert events[0]['llama_commit']==json.loads(pathlib.Path(__file__).with_name('UPSTREAM.json').read_text())['commit']
with tempfile.TemporaryDirectory() as directory:
 path=pathlib.Path(directory)/'not-a-model.gguf';path.write_bytes(b'not model weights')
 r,events=run(str(path),'0'*64);assert r.returncode!=0 and events[-1]['error']=='model SHA256 mismatch'
r,events=run('/definitely/missing/velora.gguf','0'*64);assert r.returncode!=0 and events[-1]['error']=='local model file missing'
r,events=run('/unused','not-a-sha');assert r.returncode!=0 and 'SHA256' in events[-1]['error']
for flags,message in [(['--prefill-batch=17'],'prefill-batch'),
                      (['--max-output-tokens=513'],'research-long-context'),
                      (['--research-long-context','--max-output-tokens=2049'],'maximum2048')]:
 r,events=run('/unused','0'*64,'99','4096','8192',*flags)
 assert r.returncode!=0 and message.replace(' ','') in events[-1]['error'].replace(' ','')
r,events=run('/unused','0'*64,'99','8192','8192')
assert r.returncode!=0 and 'research-long-context' in events[-1]['error']
r,events=run('/unused','0'*64,'99','16384','8192','--research-long-context','--prefill-batch=512','--max-output-tokens=2048')
assert r.returncode!=0 and events[-1]['error']=='local model file missing'
r,events=run('/unused','0'*64,'99','4096','8192','--bounded-swa')
assert r.returncode!=0 and events[-1]['error']=='local model file missing'
print('native protocol CPU checks OK (no model loaded)')
