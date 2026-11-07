#!/usr/bin/env python3
"""Create an English-only extension without altering the frozen multilingual corpus.

The ledger must opt in to ``same-component-contract``. Original English rows
retain their serialization, order, IDs, groups and split. New rows must be
independently approved public or synthetic examples. Exact normalized raw/target
content, eight-word overlaps and scenario families connect rows, including short
identity repairs; connected additions touching both frozen splits are excluded.
Exact task-contract/raw duplicates are dropped only if the target is identical;
conflicting targets for the same exact contract/raw are rejected. Frozen holdout
exact and eight-word overlap is excluded, including on target text. Sotto rows
must occur verbatim in the pinned public raw-only export. This prepares data; it
does not certify label quality or train a model.
"""
import argparse
import collections
import copy
import hashlib
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from cleanup.curate import SOTTO_REPO, SOTTO_REVISION, curate
from cleanup.data import connected_components, content_fields, digest, grams, norm, read, task_contract, validate
from prepare_lfm3_v5 import check_sotto

DEFAULT_SEED = 'velora-public-lfm3-english-20261107'
SOTTO_RAW_SHA256 = '8ae733269c7471a027c690daa2bea7268d228ebbfcb81ac50323a93c2c234f79'
SOTTO_SOURCE_FILES = {
    'data/train-00000-of-00001.parquet':'9ea6d4241905a5ff141d95ffd9519813dce7ccd0d383d1f72a48e55652565a69',
    'data/validation-00000-of-00001.parquet':'d1304f3ff4fdcbe90d2d5dd6df081bf61e57daf1d3acc0951101860630deeb39'}


def prepare(base, held, additions, ledger, sotto_raw=None, *, seed=DEFAULT_SEED, dev_percent=20):
    if ledger.get('duplicate_policy') != 'same-component-contract':
        raise ValueError('English expansion requires same-component-contract ledger opt-in')
    original = [copy.deepcopy(r) for r in base if r.get('language') == 'en']
    if not original:
        raise ValueError('English base must not be empty')
    validate(original, held, ledger=ledger)
    base_ids={r['id'] for r in base};held_ids={r['id'] for r in held}
    if base_ids & held_ids or any(isinstance(r,dict) and r.get('id') in base_ids|held_ids for r in additions):
        raise ValueError('base, additions and held-out IDs must be disjoint')
    # Validate provenance on every addition before filtering languages.
    for row in additions:
        if not isinstance(row,dict) or not isinstance(row.get('quality_review'),dict):
            raise ValueError('invalid addition or quality review')
        probe=copy.deepcopy(row)
        if probe['quality_review'].get('status') not in ('approved','generated','rejected'):
            raise ValueError('invalid review status')
        if (probe['quality_review']['status']=='approved' and isinstance(probe.get('teacher'),dict)
            and isinstance(probe['teacher'].get('name'),str) and isinstance(probe['quality_review'].get('reviewer'),str)
            and probe['teacher']['name'].strip().casefold()==probe['quality_review']['reviewer'].strip().casefold()):
            raise ValueError(f"{row.get('id')}: teacher and reviewer must be independent")
        probe['quality_review']['status']='approved'
        validate([probe], [{'id':'__validation__','raw':'unrelated sentinel phrase for isolated validation'}],
                 ledger=ledger,require_splits=False)
    check_sotto(original + additions, sotto_raw)
    if len({r['id'] for r in additions}) != len(additions):
        raise ValueError('duplicate addition ID')
    # Form the graph before excluding any review status, language, or duplicate.
    # Otherwise a rejected parent can hide a held-out link from its approved child.
    held_text=collections.defaultdict(set);held_grams=collections.defaultdict(set)
    for row in held:
        for _,value in content_fields(row, include_template=True, ledger=ledger):
            held_text[norm(value)].add(row['id'])
            for gram in grams(value):held_grams[gram].add(row['id'])
    addition_components=connected_components(additions, ledger=ledger)
    blocked_ids=set();blocked_components=[]
    for component in addition_components:
        matches=[]
        for row in component:
            for field,value in content_fields(row, ledger=ledger, include_short_vocabulary=True):
                exact=held_text.get(norm(value),set())
                overlap=set().union(*(held_grams.get(g,set()) for g in grams(value)))
                if exact:matches.append({'id':row['id'],'field':field,'kind':'exact','held_ids':sorted(exact)})
                if overlap:matches.append({'id':row['id'],'field':field,'kind':'eight-word','held_ids':sorted(overlap)})
        if matches:
            ids=[row['id'] for row in component];blocked_ids.update(ids)
            blocked_components.append({'ids':ids,'reason':'component frozen holdout overlap','matches':matches})
    excluded=[{'id':r['id'],'reason':'component frozen holdout overlap'} for r in additions if r['id'] in blocked_ids]
    excluded.extend({'id':r['id'],'reason':'non-English addition'} for r in additions
                    if r['id'] not in blocked_ids and r.get('language')!='en')
    candidates=[r for r in additions if r['id'] not in blocked_ids and r.get('language')=='en']
    existing={(task_contract(r),r['raw']):r['target'] for r in original}
    accepted=[]
    for row in candidates:
        key=(task_contract(row),row['raw'])
        if row['quality_review']['status']=='approved' and key in existing:
            if existing[key]!=row['target']:
                raise ValueError(f"{row['id']}: conflicting targets for base task contract and raw")
            excluded.append({'id':row['id'],'reason':'duplicate base task contract and pair'})
        else:accepted.append(row)
    curated, report=curate(accepted,held,ledger,seed=seed,dev_percent=dev_percent)
    excluded.extend(report['excluded'])
    texts=collections.defaultdict(set);gram_splits=collections.defaultdict(set);families=collections.defaultdict(set)
    for row in original:
        families[row['scenario_group']].add(row['split'])
        for _,value in content_fields(row, ledger=ledger):
            texts[norm(value)].add(row['split'])
            for gram in grams(value):gram_splits[gram].add(row['split'])
    # Keep excluded rows as graph connectors when mapping additions to frozen
    # splits. They never enter the output, but can bridge eligible rows.
    curated_by_id={row['id']:row for row in curated}
    selected=[];decisions=[];base_groups={r['scenario_group'] for r in original}
    for component in addition_components:
        rows=[curated_by_id[row['id']] for row in component if row['id'] in curated_by_id]
        if not rows:
            continue
        touched=set()
        for row in component:
            touched.update(families[row['scenario_group']])
            for _,value in content_fields(row, ledger=ledger):
                touched.update(texts[norm(value)])
                for gram in grams(value):touched.update(gram_splits[gram])
        # Use the first eligible representative to preserve established split
        # assignment for components with no link to a frozen split.
        name='english-add-'+rows[0]['scenario_group']
        if name in base_groups:raise ValueError('new component group collides with original')
        reason='component bridges original train and dev' if len(touched)>1 else None
        split=None if reason else next(iter(touched)) if touched else rows[0]['split']
        decisions.append({'component':name,'ids':[r['id'] for r in rows],
                          'connector_ids':[r['id'] for r in component if r['id'] not in curated_by_id],
                          'touched_original_splits':sorted(touched),'split':split,'decision':reason or 'accepted'})
        if reason:excluded.extend({'id':r['id'],'reason':reason} for r in rows)
        else:selected.extend(dict(r,scenario_group=name,split=split) for r in rows)
    result=original+selected
    validate(result,held,ledger=ledger)
    return result, {'duplicate_policy':'same-component-contract','seed':seed,'dev_percent':dev_percent,
        'original_english_rows':len(original),'non_english_base_rows_excluded':len(base)-len(original),
        'non_english_base_ids_excluded':[r['id'] for r in base if r.get('language')!='en'],
        'original_rows_preserved':True,'addition_excluded':excluded,'component_decisions':decisions,
        'holdout_blocked_components':blocked_components,
        'effective_components':[{'ids':[r['id'] for r in c], 'split':c[0]['split']}
                                for c in connected_components(result, ledger=ledger)],
        'splits':{name:dict(collections.Counter(r['split'] for r in rows)) for name,rows in
                  [('original',original),('new',selected),('combined',result)]},
        'review_status':'approved provenance declared; distinct teacher and reviewer strings checked for approved additions; reviewer type and actual independence not verified'}


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    for flag in ('base','old-guard','fresh','additions','ledger','sotto-raw','out'):
        parser.add_argument('--'+flag,required=True,type=Path)
    parser.add_argument('--seed',default=DEFAULT_SEED);parser.add_argument('--dev-percent',type=int,default=20)
    parser.add_argument('--expected-base-rows',type=int,default=1466);parser.add_argument('--expected-base-dev',type=int,default=233)
    args=parser.parse_args(argv)
    if args.out.exists():raise FileExistsError(args.out)
    sidecar=Path(str(args.sotto_raw)+'.manifest.json')
    inputs={name:getattr(args,name) for name in ('base','old_guard','fresh','additions','ledger','sotto_raw')}
    inputs['sotto_manifest']=sidecar
    hashes={name:digest(path) for name,path in inputs.items()}
    sotto_manifest=json.loads(sidecar.read_text())
    if (sotto_manifest.get('repository')!=SOTTO_REPO or sotto_manifest.get('revision')!=SOTTO_REVISION
        or sotto_manifest.get('license')!='MIT' or sotto_manifest.get('files')!=SOTTO_SOURCE_FILES
        or sotto_manifest.get('output_sha256')!=SOTTO_RAW_SHA256 or hashes['sotto_raw']!=SOTTO_RAW_SHA256):
        raise ValueError('Sotto raw-only export or acquisition manifest differs from pinned source')
    raw_lines=args.base.read_bytes().splitlines(keepends=True)
    base=read(args.base)
    if len(raw_lines)!=len(base) or any(not line.strip() for line in raw_lines):
        raise ValueError('base must contain exactly one nonempty JSON object per line')
    english=[r for r in base if r.get('language')=='en']
    if len(english)!=args.expected_base_rows or sum(r.get('split')=='dev' for r in english)!=args.expected_base_dev:
        raise ValueError('frozen English base row/dev counts do not match')
    held=read(args.old_guard)+read(args.fresh);ledger=json.loads(args.ledger.read_text())
    rows,report=prepare(base,held,read(args.additions),ledger,read(args.sotto_raw),seed=args.seed,dev_percent=args.dev_percent)
    if hashes!={name:digest(path) for name,path in inputs.items()}:raise ValueError('input changed during preparation')
    prefix=b''.join(line for line,row in zip(raw_lines,base) if row.get('language')=='en')
    suffix=''.join(json.dumps(row,ensure_ascii=False)+'\n' for row in rows[len(english):]).encode()
    separator=b'\n' if suffix and prefix and not prefix.endswith((b'\n',b'\r')) else b''
    args.out.mkdir(parents=True,exist_ok=False)
    (args.out/'reviewed.jsonl').write_bytes(prefix+separator+suffix)
    (args.out/'sources.json').write_bytes(args.ledger.read_bytes())
    report.update(inputs_sha256=hashes,outputs_sha256={name:digest(args.out/name) for name in ('reviewed.jsonl','sources.json')},
        source_sha256={str(p.relative_to(Path(__file__).resolve().parents[1])):digest(p) for p in
            (Path(__file__).resolve(),Path(__file__).resolve().parents[1]/'cleanup/curate.py',
             Path(__file__).resolve().parents[1]/'cleanup/data.py',Path(__file__).resolve().parent/'prepare_lfm3_v5.py')},
        original_english_serialization_sha256=hashlib.sha256(prefix).hexdigest(),held_out_count=len(held))
    (args.out/'curation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'rows':len(rows),'splits':report['splits'],'excluded':len(report['addition_excluded'])}))


if __name__=='__main__':main()
