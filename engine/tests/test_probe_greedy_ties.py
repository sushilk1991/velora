"""CPU-only bounds/provenance checks for the public same-tensor tie probe."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import pytest

SCRIPT=Path(__file__).resolve().parents[2]/'training/cleanup/scripts/probe_greedy_ties.py'
spec=importlib.util.spec_from_file_location('probe_greedy_ties',SCRIPT)
probe=importlib.util.module_from_spec(spec);spec.loader.exec_module(probe)


def test_processor_returns_exact_tensor_and_observes_only_first_three():
    seen=[]
    observer=probe.Recorder(lambda value:(seen.append(value) or {'marker':len(seen)}))
    logits=object()
    for i in range(17):assert observer(SimpleNamespace(size=116+i),logits) is logits
    assert observer.calls==17 and len(seen)==3 and len(observer.records)==3
    assert [r['history_tokens'] for r in observer.records]==[116,117,118]


def test_only_explicit_public_case046_is_loaded(tmp_path):
    path=tmp_path/'data.jsonl'
    row=dict(id=probe.CASE_ID,raw='public example',mode='default',language='hi',romanize=True,instructions='',vocabulary=[])
    path.write_text(json.dumps(row)+'\n')
    with pytest.raises(ValueError,match='explicitly be public'):probe.load_case(path)
    row['visibility']='public';row['target']='must not be used'
    path.write_text(json.dumps(row)+'\n')
    result=probe.load_case(path)
    assert 'target' not in result and result['id']==probe.CASE_ID
    path.write_text((json.dumps(row)+'\n')*2)
    with pytest.raises(ValueError,match='exactly one'):probe.load_case(path)


def test_artifact_identity_and_successful_baseline_are_required():
    baseline=dict(base_revision='pin',base_files_sha256={'tokenizer.json':'t','weights':'w'},
        adapter_sha256={'adapters':'a'},versions={'mlx':'v'},decoder='stream',
        records=[{'id':probe.CASE_ID,'eos':True,'output_token_ids':[1,2,3]}])
    assert probe.validate_identity(baseline,'pin',baseline['base_files_sha256'],baseline['adapter_sha256'],baseline['versions'])['eos']
    with pytest.raises(ValueError,match='identity differs'):
        probe.validate_identity(baseline,'other',baseline['base_files_sha256'],baseline['adapter_sha256'],baseline['versions'])
    baseline['records'][0]['eos']=False
    with pytest.raises(ValueError,match='successful case046'):
        probe.validate_identity(baseline,'pin',baseline['base_files_sha256'],baseline['adapter_sha256'],baseline['versions'])
