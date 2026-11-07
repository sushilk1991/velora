"""Prompt-field split and holdout isolation; CPU-only, no network."""
import copy
from pathlib import Path
import sys
import pytest
from cleanup import curate, data

STOCK='Shared stock prompt for all examples, with many harmless repeated words.'
LEDGER={'duplicate_policy':'same-component-contract','isolate_prompt_fields':True,
        'shared_instruction_templates':[STOCK], 'allowed_licenses':['CC0-1.0'],
        'sources':{'test':{'kind':'synthetic','revision':'1','license':'CC0-1.0'}}}
HELD=[{'id':'held','raw':'the amber kite floats quietly above the old coastal lighthouse'}]


def row(id,raw,target=None,split='train',instructions=STOCK,vocabulary=None):
    return {'id':id,'raw':raw,'target':target or raw+'.','mode':'default','language':'en','split':split,
        'scenario_group':id,'visibility':'public','instructions':instructions,'vocabulary':vocabulary or [],
        'source':{'name':'test','revision':'1','license':'CC0-1.0'},'teacher':{'name':'a','revision':'1'},
        'quality_review':{'status':'approved','reviewer':'b'}}


def test_long_heldout_in_custom_instruction_or_vocabulary_is_rejected():
    text='prefix '+HELD[0]['raw']+' suffix'
    for kwargs in ({'instructions':text},{'vocabulary':[text]}):
        with pytest.raises(ValueError,match='holdout contamination'):
            data.validate([row('case','fresh unrelated content',**kwargs)],HELD,ledger=LEDGER)
        kept,report=curate.curate([row('case','fresh unrelated content',**kwargs)],HELD,LEDGER)
        assert not kept and report['excluded'][0]['reason']=='frozen holdout overlap'


def test_vocabulary_exact_full_heldout_only_and_short_names_do_not_connect():
    rows=[row('a','the first example',vocabulary=['Sam']),
          row('b','the second example',split='dev',vocabulary=['Sam'])]
    data.validate(rows,HELD,ledger=LEDGER)
    assert len(data.connected_components(rows,ledger=LEDGER))==2
    with pytest.raises(ValueError,match='holdout contamination'):
        data.validate([row('x','another example',vocabulary=[HELD[0]['raw']])],HELD,ledger=LEDGER)
    data.validate([row('x','another example',vocabulary=['amber'])],HELD,ledger=LEDGER)


def test_long_vocabulary_joins_components_and_cannot_cross_split():
    words='one two three four five six seven eight nine ten'
    rows=[row('a','fresh input one',vocabulary=[words]),row('b','fresh input two',split='dev',vocabulary=[words])]
    assert len(data.connected_components(rows,ledger=LEDGER))==1
    with pytest.raises(ValueError,match='crosses splits|contamination'):
        data.validate(rows,HELD,ledger=LEDGER)
    curated,_=curate.curate(rows,HELD,LEDGER)
    assert len(curated)==2 and len({r['scenario_group'] for r in curated})==1


def test_stock_template_is_excluded_only_on_exact_match_and_context_validated():
    rows=[row('a','first sample'),row('b','second sample',split='dev')]
    data.validate(rows,HELD,ledger=LEDGER)
    assert len(data.connected_components(rows,ledger=LEDGER))==2
    custom=row('c','third sample',instructions=STOCK+' '+HELD[0]['raw'])
    with pytest.raises(ValueError,match='holdout contamination'):data.validate([custom],HELD,ledger=LEDGER)
    context='the amber kite floats quietly above the old coastal lighthouse'
    value=row('d','fresh context',instructions=STOCK+'\n\nPrevious text (context only, do NOT repeat it): «'+context+'».')
    value['scenario_context']=context
    fields=dict(data.content_fields(value,ledger=LEDGER))
    assert fields['scenario_context']==context and 'instructions' not in fields
    value['instructions']=STOCK
    with pytest.raises(ValueError,match='scenario_context'):list(data.content_fields(value,ledger=LEDGER))


@pytest.mark.parametrize('key,value', [('isolate_prompt_fields','true'),('isolate_prompt_fields',1),
    ('shared_instruction_templates','not a list'),('shared_instruction_templates',['']),
    ('shared_instruction_templates',[None]),('allowed_licenses','CC0-1.0'),('allowed_licenses',['']),
    ('allowed_licenses',[None])])
def test_malformed_policy_fails_closed(key,value):
    ledger=copy.deepcopy(LEDGER);ledger[key]=value
    with pytest.raises(ValueError):data.validate([row('x','fresh input')],HELD,ledger=ledger)


def test_legacy_ledger_does_not_isolate_prompt_fields():
    ledger=copy.deepcopy(LEDGER);ledger.pop('isolate_prompt_fields');ledger.pop('shared_instruction_templates')
    candidate=row('a','separate example',instructions=HELD[0]['raw'],vocabulary=[HELD[0]['raw']])
    data.validate([candidate],HELD,ledger=ledger)


@pytest.mark.parametrize('existing',('output','sidecar','broken_output','broken_sidecar'))
def test_acquire_refuses_existing_paths_before_import_and_network(tmp_path,monkeypatch,existing):
    output=tmp_path/'raw.jsonl';sidecar=Path(str(output)+'.manifest.json')
    path=output if 'output' in existing else sidecar
    if existing.startswith('broken'):path.symlink_to(tmp_path/'absent')
    else:path.write_text('leave intact')
    before=path.readlink() if path.is_symlink() else path.read_bytes()
    monkeypatch.setitem(sys.modules,'huggingface_hub',None)
    with pytest.raises(FileExistsError):curate.acquire_sotto(output)
    assert (path.readlink() if path.is_symlink() else path.read_bytes())==before
    other=sidecar if path==output else output
    assert not other.exists() and not other.is_symlink()


def test_short_vocabulary_matches_complete_short_heldout_not_shared_glossary_hint():
    held=[{'id':'h','raw':'orchard'}]
    with pytest.raises(ValueError,match='holdout contamination'):
        data.validate([row('x','a separate sentence',vocabulary=['orchard'])],held,ledger=LEDGER)
    other=[{'id':'h','raw':'visit orchard tomorrow'}]
    data.validate([row('x','a separate sentence',vocabulary=['orchard'])],other,ledger=LEDGER)


def test_heldout_context_without_rendered_instructions_is_still_isolated():
    context='twelve distant artists painted murals beside the old railway station'
    held=[{'id':'h','raw':'different held sentence','scenario_context':context}]
    fields=dict(data.content_fields(held[0],include_template=True,ledger=LEDGER))
    assert fields['scenario_context']==context
    with pytest.raises(ValueError,match='holdout contamination'):
        data.validate([row('a','unrelated words',instructions='note '+context)],held,ledger=LEDGER)
