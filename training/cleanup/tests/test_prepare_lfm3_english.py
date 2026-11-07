import copy
import importlib.util
import json
from pathlib import Path
import pytest

SCRIPT=Path(__file__).resolve().parents[1]/'scripts/prepare_lfm3_english.py'
spec=importlib.util.spec_from_file_location('english_prep',SCRIPT)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
LEDGER={'duplicate_policy':'same-component-contract','allowed_licenses':['CC0-1.0'],
        'sources':{'fixture':{'kind':'synthetic','revision':'1','license':'CC0-1.0'}}}
HELD=[{'id':'held','raw':'wholly separate public holdout sentence'}]

def row(id,raw,target,group=None,split='train',**kw):
    r={'id':id,'raw':raw,'target':target,'mode':'default','language':'en','scenario_group':group or id,
       'visibility':'public','source':{'name':'fixture','revision':'1','license':'CC0-1.0'},
       'teacher':{'name':'fixture','revision':'1'},'quality_review':{'status':'approved','reviewer':'other'},'split':split}
    r.update(kw);return r

def base():
    return [row('old','red crate','red crate.'),row('dev','blue folder','blue folder.',split='dev'),
            row('hindi','नमस्ते','नमस्ते।',language='hi')]

def test_identity_and_different_contract_survive_same_short_component():
    old=base();before=copy.deepcopy(old)
    additions=[row('repair','read crate','red crate.'),row('identity','red crate.','red crate.'),
               row('other','red crate','red crate.',mode='code')]
    rows,report=m.prepare(old,HELD,additions,LEDGER)
    assert old==before and rows[:2]==old[:2] and len(rows)==5
    assert all(r['split']=='train' for r in rows[2:])
    assert len({r['scenario_group'] for r in rows[2:]})==1
    component=next(c for c in report['effective_components'] if 'old' in c['ids'])
    assert set(component['ids'])=={'old','repair','identity','other'} and component['split']=='train'
    assert report['non_english_base_rows_excluded']==1
    m.validate(rows,HELD,ledger=LEDGER)


def test_contract_conflicts_duplicate_and_short_cross_split():
    with pytest.raises(ValueError,match='conflicting targets'):
        m.prepare(base(),HELD,[row('bad','red crate','blue crate')],LEDGER)
    for change in ({'mode':'code'},{'vocabulary':['name']},{'instructions':'Keep all text.'}):
        rows,_=m.prepare(base(),HELD,[row('variant','red crate','different allowed',**change)],LEDGER)
        assert len(rows)==3 and rows[-1]['split']=='train'
    rows,report=m.prepare(base(),HELD,[row('dupe','red crate','red crate.')],LEDGER)
    assert len(rows)==2 and 'duplicate base' in report['addition_excluded'][0]['reason']
    with pytest.raises(ValueError,match='crosses splits'):
        m.validate([row('a','one','two'),row('b','two','three',split='dev')],HELD,ledger=LEDGER)
    with pytest.raises(ValueError,match='conflicting targets'):
        m.curate([row('a','same','one'),row('b','same','two')],HELD,LEDGER)


def test_bridge_and_holdout_excluded_non_english_reported():
    adds=[row('bridge','red crate','blue folder.',mode='code'),row('held-overlap',HELD[0]['raw'],'different'),
          row('hindi-new','नया','नया।',language='hi')]
    rows,report=m.prepare(base(),HELD,adds,LEDGER)
    assert len(rows)==2
    assert {r['id'] for r in report['addition_excluded']}=={'bridge','held-overlap','hindi-new'}
    assert any('bridges' in r['reason'] for r in report['addition_excluded'])


def test_default_policy_still_rejects_shared_content():
    strict={k:v for k,v in LEDGER.items() if k!='duplicate_policy'}
    with pytest.raises(ValueError,match='duplicate'):
        m.validate([row('a','first','second'),row('b','second','third')],HELD,ledger=strict)
    result,report=m.curate([row('a','first','second'),row('b','second','third')],HELD,strict)
    assert len(result)==1 and 'duplicate normalized' in report['excluded'][0]['reason']


def test_transitive_short_component_cannot_bridge_and_holdout_8gram_rejected():
    adds=[row('a','red crate','joint content',mode='code'),
          row('b','joint content','blue folder.',mode='message'),
          row('c','one two three four five six seven eight nine','safe')]
    held=HELD+[{'id':'longheld','raw':'zero one two three four five six seven eight nine ten'}]
    rows,report=m.prepare(base(),held,adds,LEDGER)
    assert len(rows)==2
    reasons={r['id']:r['reason'] for r in report['addition_excluded']}
    assert 'bridges' in reasons['a'] and 'bridges' in reasons['b']
    assert 'holdout overlap' in reasons['c']


def test_cli_preserves_original_english_lines_and_records_hashes(tmp_path,monkeypatch):
    source=base();files={'base':source,'old-guard':HELD,
        'fresh':[{'id':'fresh','raw':'isolated fresh test set'}],
        'additions':[row('new','read crate','red crate.')],'sotto-raw':[]}
    argv=[]
    for name,items in files.items():
        path=tmp_path/(name+'.jsonl')
        path.write_bytes(b''.join(json.dumps(r,ensure_ascii=False,separators=(',',': ')).encode()+b'\r\n' for r in items))
        argv.extend(['--'+name,str(path)])
    sotto=tmp_path/'sotto-raw.jsonl';monkeypatch.setattr(m,'SOTTO_RAW_SHA256',m.digest(sotto))
    Path(str(sotto)+'.manifest.json').write_text(json.dumps({'repository':m.SOTTO_REPO,'revision':m.SOTTO_REVISION,
        'license':'MIT','files':m.SOTTO_SOURCE_FILES,'output_sha256':m.SOTTO_RAW_SHA256}))
    ledger=tmp_path/'ledger.json';ledger.write_text(json.dumps(LEDGER))
    out=tmp_path/'out';argv.extend(['--ledger',str(ledger),'--out',str(out),
                                   '--expected-base-rows','2','--expected-base-dev','1'])
    m.main(argv)
    lines=(tmp_path/'base.jsonl').read_bytes().splitlines(keepends=True)
    result=(out/'reviewed.jsonl').read_bytes()
    assert result.startswith(lines[0]+lines[1]) and lines[2] not in result
    report=json.loads((out/'curation.json').read_text())
    assert report['outputs_sha256']['reviewed.jsonl']==m.digest(out/'reviewed.jsonl')
    assert report['splits']['original']=={'train':1,'dev':1}
    with pytest.raises(FileExistsError):m.main(argv)


def test_cli_rejects_tampered_sotto_raw_or_sidecar(tmp_path,monkeypatch):
    path=tmp_path/'sotto.jsonl';path.write_text('')
    monkeypatch.setattr(m,'SOTTO_RAW_SHA256',m.digest(path))
    side=Path(str(path)+'.manifest.json')
    side.write_text(json.dumps({'repository':m.SOTTO_REPO,'revision':m.SOTTO_REVISION,
        'license':'MIT','files':m.SOTTO_SOURCE_FILES,'output_sha256':m.SOTTO_RAW_SHA256}))
    argv=[]
    for name in ('base','old-guard','fresh','additions'):
        f=tmp_path/(name+'.jsonl');f.write_text('');argv.extend(['--'+name,str(f)])
    ledger=tmp_path/'ledger.json';ledger.write_text(json.dumps(LEDGER))
    argv+=['--ledger',str(ledger),'--sotto-raw',str(path),'--out',str(tmp_path/'out')]
    path.write_text('tampered')
    with pytest.raises(ValueError,match='pinned source'):m.main(argv)
    path.write_text('');side.write_text('{}')
    with pytest.raises(ValueError,match='pinned source'):m.main(argv)


def test_addition_rejects_self_review():
    candidate=row('self','independent text','independent text.')
    candidate['quality_review']['reviewer']=candidate['teacher']['name']
    with pytest.raises(ValueError,match='independent'):
        m.prepare(base(),HELD,[candidate],LEDGER)


def test_held_parent_quarantines_identity_child_and_keeps_unrelated():
    held=[{'id':'guard','template':'please check the blue folder before leaving the library today'}]
    additions=[row('parent','please check the blue folder before leaving the library today','safe short result','family'),
               row('child','safe short result','safe short result.','family'),
               row('unrelated','separate kettle','separate kettle.')]
    result,report=m.prepare(base(),held,additions,LEDGER)
    assert [r['id'] for r in result]==['old','dev','unrelated']
    blocked=report['holdout_blocked_components']
    assert len(blocked)==1 and set(blocked[0]['ids'])=={'parent','child'}
    assert blocked[0]['matches']==[
        {'id':'parent','field':'raw','kind':'exact','held_ids':['guard']},
        {'id':'parent','field':'raw','kind':'eight-word','held_ids':['guard']}]
    assert {r['id'] for r in report['addition_excluded']}=={'parent','child'}


def test_held_component_crosses_declared_families_via_short_target():
    additions=[row('a',HELD[0]['raw'],'short bridge','one'),
               row('b','short bridge','new outcome','two'),
               row('c','new outcome','final wording','three')]
    result,report=m.prepare(base(),HELD,additions,LEDGER)
    assert result==base()[:2]
    assert set(report['holdout_blocked_components'][0]['ids'])=={'a','b','c'}


def test_rejected_holdout_member_still_quarantines_family():
    rejected=row('rejected',HELD[0]['raw'],'distinct wording','shared')
    rejected['quality_review']['status']='rejected'
    child=row('child','a different input','different output','shared')
    result,report=m.prepare(base(),HELD,[rejected,child],LEDGER)
    assert result==base()[:2]
    assert set(report['holdout_blocked_components'][0]['ids'])=={'rejected','child'}


def test_invalid_provenance_on_blocked_addition_is_fatal():
    candidate=row('bad',HELD[0]['raw'],'different','family')
    candidate['visibility']='private'
    with pytest.raises(ValueError,match='non-public'):
        m.prepare(base(),HELD,[candidate,row('child','safe input','safe output','family')],LEDGER)


def context_row(item, context):
    item['scenario_context']=context
    item['instructions']='Shared instruction.\n\nPrevious text (context only, do NOT repeat it): «'+context+'».'
    return item


def test_context_heldout_quarantines_parent_and_family():
    parent=context_row(row('parent','independent input','independent output','family'),
                       'previous public passage one two three four five six seven eight')
    child=row('child','another input','another output','family')
    held=[{'id':'guard','scenario_context':'previous public passage one two three four five six seven eight'}]
    result,report=m.prepare(base(),held,[parent,child],LEDGER)
    assert result==base()[:2]
    assert set(report['holdout_blocked_components'][0]['ids'])=={'parent','child'}
    assert any(match['field']=='scenario_context' for match in report['holdout_blocked_components'][0]['matches'])


def test_context_links_addition_to_base_split_and_blocks_bridge():
    original=base()
    original[0]=context_row(original[0],'short train context')
    original[1]=context_row(original[1],'one two three four five six seven eight nine')
    addition=context_row(row('bridge','short train context','fresh result',mode='note'),
                         'zero one two three four five six seven eight ten')
    result,report=m.prepare(original,HELD,[addition],LEDGER)
    assert result==original[:2]
    assert 'bridges' in report['addition_excluded'][0]['reason']


def test_rejected_connector_quarantines_new_train_dev_bridge():
    x=row('x','red crate','short link x','x-family',mode='code')
    y=row('y','short link x','short link z','y-family')
    y['quality_review']['status']='rejected'
    z=row('z','short link z','blue folder','z-family',mode='message')
    old=base();before=copy.deepcopy(old)
    result,report=m.prepare(old,HELD,[x,y,z],LEDGER)
    assert result==before[:2] and old==before
    assert {e['id'] for e in report['addition_excluded']}=={'x','y','z'}
    bridge=next(d for d in report['component_decisions'] if 'x' in d['ids'])
    assert set(bridge['ids'])=={'x','z'} and bridge['connector_ids']==['y']
    assert bridge['touched_original_splits']==['dev','train']


def test_base_duplicate_connector_quarantines_new_bridge():
    # Duplicate of train base is dropped, but its declared family connects z.
    duplicate=row('duplicate','red crate','red crate.','shared')
    z=row('z','separate input','blue folder','shared',mode='message')
    old=base();result,report=m.prepare(old,HELD,[duplicate,z],LEDGER)
    assert result==old[:2]
    assert {e['id'] for e in report['addition_excluded']}=={'duplicate','z'}
    bridge=next(d for d in report['component_decisions'] if 'z' in d['ids'])
    assert bridge['connector_ids']==['duplicate'] and bridge['touched_original_splits']==['dev','train']


def test_excluded_connector_uses_first_eligible_representative_for_split():
    rejected=row('rejected','link alpha','link beta','rejected-family')
    rejected['quality_review']['status']='rejected'
    a=row('a','link alpha','independent result','family-a')
    b=row('b','link beta','other result','family-b')
    rows,report=m.prepare(base(),HELD,[rejected,a,b],LEDGER)
    expected,_=m.curate([a],HELD,LEDGER)
    added=[r for r in rows if r['id'] in {'a','b'}]
    assert len(added)==2 and {r['split'] for r in added}=={expected[0]['split']}
    assert len({r['scenario_group'] for r in added})==1
    assert report['component_decisions'][0]['connector_ids']==['rejected']


def test_report_does_not_claim_independent_model_review():
    _,report=m.prepare(base(),HELD,[row('new','unique input text','unique output text')],LEDGER)
    assert 'declared' in report['review_status']
    assert 'actual independence not verified' in report['review_status']


def test_optin_held_prompt_quarantines_connected_family():
    ledger={**LEDGER,'isolate_prompt_fields':True,'shared_instruction_templates':['Generic cleanup.']}
    held=[{'id':'guard','raw':'an orange train crosses the long stone bridge today'}]
    parent=row('parent','fresh dictated text','fresh clean text','family',
               instructions='Please note an orange train crosses the long stone bridge today carefully.')
    child=row('child','separate dictated text','separate clean text','family',instructions='Generic cleanup.')
    result,report=m.prepare(base(),held,[parent,child],ledger)
    assert result==base()[:2]
    assert set(report['holdout_blocked_components'][0]['ids'])=={'parent','child'}
    assert any(match['field']=='instructions' for match in report['holdout_blocked_components'][0]['matches'])


def test_optin_short_vocabulary_matches_whole_heldout_only():
    ledger={**LEDGER,'isolate_prompt_fields':True,'shared_instruction_templates':[]}
    held=[{'id':'guard','raw':'Marigold'}]
    parent=row('parent','fresh dictated text','fresh clean text','family',vocabulary=['Marigold'])
    child=row('child','another dictated text','another clean text','family')
    result,report=m.prepare(base(),held,[parent,child],ledger)
    assert result==base()[:2]
    assert set(report['holdout_blocked_components'][0]['ids'])=={'parent','child'}
    assert any(match['field']=='vocabulary' for match in report['holdout_blocked_components'][0]['matches'])
