"""Fake-worker CPU regression: CLI exit/metadata and low-budget probes agree."""
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

NATIVE=Path(__file__).resolve().parent
ROOT=NATIVE.parents[1]


@pytest.mark.parametrize('matching_reference',(True,False))
def test_reference_parity_and_low_output_limit_are_real_cli_gates(tmp_path,matching_reference):
    log=tmp_path/'requests.jsonl'
    worker=tmp_path/'fake-worker'
    worker.write_text('#!'+sys.executable+'\n'+'''import json,os,sys
log=sys.argv[1]
print(json.dumps({'event':'ready','pid':os.getpid()}),flush=True)
for line in sys.stdin:
 r=json.loads(line)
 with open(log,'a') as f:f.write(json.dumps(r)+'\\n')
 if r['op']=='shutdown':break
 if r['op']=='cancel':
  print(json.dumps({'event':'result','id':r['id'],'status':'cancelled'}),flush=True)
  continue
 if r['op']!='generate':continue
 if r['max_tokens']>8:
  print(json.dumps({'event':'error','id':r['id'],'error':'output limit'}),flush=True)
  continue
 if r['id']=='cancel-probe':continue
 overflow=r['id']=='context-overflow'
 result={'event':'result','id':r['id'],'status':'context_limit' if overflow else 'eos',
   'text':'' if overflow else 'Edited.','partial_text':'',
   'prompt_tokens':[1,5] if r['id']=='system-change' else [1,2],
   'output_tokens':[] if overflow else [3],'elapsed_ms':1,'rss_bytes':123}
 print(json.dumps(result),flush=True)
''')
    worker.chmod(0o700)
    data=tmp_path/'public.jsonl';data.write_text(json.dumps({'id':'case','visibility':'public','raw':'edit this phrase',
        'mode':'default','language':'en'})+'\n')
    reference=tmp_path/'reference.json'
    reference.write_text(json.dumps({'rows':[{'id':'case','tokens':[1,2] if matching_reference else [9,9]}]}))
    output=tmp_path/'output.jsonl'
    env={**os.environ,'PYTHONPATH':str(ROOT/'training/cleanup')}
    result=subprocess.run([sys.executable,str(NATIVE/'benchmark.py'),'--binary',str(worker),
        '--model',str(log),'--sha256','0'*64,'--data',str(data),'--out',str(output),
        '--reference-tokens',str(reference),'--max-output-tokens','8','--max-tokens','8'],
        env=env,capture_output=True,text=True,timeout=15)
    report=json.loads(Path(str(output)+'.meta.json').read_text())
    assert report['all_main_rows_eos'] and report['repeat_equal'] and report['state_recovery']['passed']
    assert report['cancel_status']=='cancelled' and report['after_cancel_status']=='eos'
    assert report['backend_token_parity'] is matching_reference
    assert report['runtime_qualified'] is matching_reference
    assert result.returncode==(0 if matching_reference else 1),result.stderr
    assert report['prompt_mismatch_ids']==([] if matching_reference else ['case'])
    requests=[json.loads(line) for line in log.read_text().splitlines()]
    after=next(row for row in requests if row.get('id')=='after-cancel')
    assert after['max_tokens']==8
    assert all(row['max_tokens']<=8 for row in requests if row['op']=='generate')
