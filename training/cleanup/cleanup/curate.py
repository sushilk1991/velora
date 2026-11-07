"""Acquire public raw inputs and curate reviewed examples without private data."""
import collections
import copy
import json
import os
from pathlib import Path
from .data import assign, content_fields, digest, duplicate_policy, grams, norm, read, task_contract, validate

SOTTO_REPO = 'juanquivilla/sotto-transcript-cleanup'
SOTTO_REVISION = '183cc8fd58532f13fa192980185214de1bcd5acc'


def acquire_sotto(out):
    """Fetch pinned public source; expose only inputs, never upstream targets."""
    out=Path(out)
    sidecar=Path(str(out)+'.manifest.json')
    if os.path.lexists(out) or os.path.lexists(sidecar):
        raise FileExistsError('Sotto output or acquisition sidecar already exists')
    from huggingface_hub import snapshot_download
    import pyarrow.parquet as parquet
    snapshot = Path(snapshot_download(repo_id=SOTTO_REPO, repo_type='dataset', revision=SOTTO_REVISION))
    if snapshot.name != SOTTO_REVISION:
        raise ValueError('Sotto snapshot revision mismatch')
    manifest = {'repository': SOTTO_REPO, 'revision': SOTTO_REVISION, 'license': 'MIT', 'files': {}}
    with open(out, 'x') as output:
        for split in ('train', 'validation'):
            path = snapshot / 'data' / f'{split}-00000-of-00001.parquet'
            manifest['files'][str(path.relative_to(snapshot))] = digest(path)
            table = parquet.read_table(path, columns=['input'])
            for index, raw in enumerate(table.column('input').to_pylist()):
                if not isinstance(raw, str) or not raw.strip():
                    raise ValueError(f'invalid input: {split}:{index}')
                row = {'id': f'sotto-{split}-{index:06d}', 'raw': raw, 'source': {'name': 'sotto-transcript-cleanup', 'revision': SOTTO_REVISION, 'license': 'MIT'}}
                output.write(json.dumps(row, ensure_ascii=False) + '\n')
    manifest['output_sha256'] = digest(out)
    with sidecar.open('x') as output:
        output.write(json.dumps(manifest, indent=2) + '\n')
    return manifest


def curate(rows, holdout, ledger, seed='velora-public-20261106-v1', dev_percent=20):
    """Reference-order dedupe, then union group and 8-gram connected components."""
    if not holdout:
        raise ValueError('external holdout must not be empty')
    held_text = {norm(value) for r in holdout for _,value in content_fields(r, include_template=True,ledger=ledger)}
    held_grams = set().union(*(grams(value) for r in holdout for _,value in content_fields(r, include_template=True,ledger=ledger)))
    policy = duplicate_policy(ledger)
    kept, excluded, seen, ids, contracts = [], [], set(), set(), {}
    for source_row in rows:
        # Validate every row's public origin even if its label will be excluded.
        row = copy.deepcopy(source_row)
        if not isinstance(row, dict) or not isinstance(row.get('quality_review'), dict):
            raise ValueError('invalid row or quality review')
        status = row['quality_review'].get('status')
        if status not in ('approved', 'generated', 'rejected'):
            raise ValueError('unknown quality review status')
        row['quality_review']['status'] = 'approved'
        validate([row], [{'id': '__curation_validation__', 'raw': 'nonoverlapping sentinel'}], ledger=ledger, require_splits=False)
        if row['id'] in ids:
            raise ValueError(f"duplicate id: {row['id']}")
        ids.add(row['id'])
        reason = None
        values = {norm(value) for _,value in content_fields(row,ledger=ledger)}
        holdout_values = list(content_fields(row,ledger=ledger,include_short_vocabulary=True))
        if status != 'approved':
            reason = 'not independently approved'
        elif any(norm(value) in held_text or grams(value) & held_grams for _,value in holdout_values):
            reason = 'frozen holdout overlap'
        elif policy == 'strict' and values & seen:
            reason = 'duplicate normalized content'
        elif policy == 'same-component-contract':
            key = (task_contract(row), row['raw'])
            if key in contracts:
                if contracts[key] != row['target']:
                    raise ValueError(f"{row['id']}: conflicting targets for task contract and raw")
                reason = 'duplicate task contract and pair'
        if reason:
            excluded.append({'id': row['id'], 'reason': reason})
            continue
        seen.update(values)
        if policy == 'same-component-contract':contracts[(task_contract(row),row['raw'])]=row['target']
        kept.append(copy.deepcopy(source_row))
    parent = list(range(len(kept)))
    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    def union(x, y):
        a, b = find(x), find(y)
        if a != b:
            parent[max(a, b)] = min(a, b)
    owners, families, text_owners = {}, {}, {}
    for i, row in enumerate(kept):
        family = row['scenario_group']
        if family in families:
            union(i, families[family])
        else:
            families[family] = i
        if policy == 'same-component-contract':
            for value in {norm(value) for _,value in content_fields(row,ledger=ledger)}:
                if value in text_owners:union(i,text_owners[value])
                else:text_owners[value]=i
        for gram in set().union(*(grams(value) for _,value in content_fields(row,ledger=ledger))):
            if gram in owners:
                union(i, owners[gram])
            else:
                owners[gram] = i
    for i, row in enumerate(kept):
        row['scenario_group'] = 'component-' + kept[find(i)]['id']
    kept = assign(kept, seed=seed, dev_percent=dev_percent)
    validate(kept, holdout, ledger=ledger)
    report = {'rows': len(kept), 'split': dict(collections.Counter(r['split'] for r in kept)), 'language_split': dict(collections.Counter(r['language'] + ':' + r['split'] for r in kept)), 'excluded': excluded, 'scenario_components': len({r['scenario_group'] for r in kept}), 'seed': seed, 'dev_percent': dev_percent}
    return kept, report


def run(args):
    ledger = json.loads(Path(args.ledger).read_text())
    inputs = [read(path) for path in args.input]
    candidates = [row for batch in inputs for row in batch]
    sotto_rows = [row for row in candidates if isinstance(row, dict) and isinstance(row.get('source'), dict) and row['source'].get('name') == 'sotto-transcript-cleanup']
    if sotto_rows and not args.sotto_raw:
        raise ValueError('Sotto reviewed rows require --sotto-raw acquired from the pinned source')
    if args.sotto_raw:
        raw_rows = read(args.sotto_raw)
        source = {'name': 'sotto-transcript-cleanup', 'revision': SOTTO_REVISION, 'license': 'MIT'}
        if any(not isinstance(r, dict) or r.get('source') != source or not isinstance(r.get('raw'), str) for r in raw_rows):
            raise ValueError('invalid Sotto raw input provenance')
        available = {r['raw'] for r in raw_rows}
        if any(r.get('raw') not in available for r in sotto_rows):
            raise ValueError('reviewed Sotto raw does not occur in acquired inputs')
    rows, report = curate(candidates, read(args.holdout), ledger, args.seed, args.dev_percent)
    with open(args.out, 'x') as out:
        for row in rows:
            out.write(json.dumps(row, ensure_ascii=False) + '\n')
    report.update({'inputs_sha256': [digest(path) for path in args.input], 'holdout_sha256': digest(args.holdout), 'ledger_sha256': digest(args.ledger), 'dataset_sha256': digest(args.out), 'sotto_raw_sha256': digest(args.sotto_raw) if args.sotto_raw else None})
    with open(args.report, 'x') as output:
        json.dump(report, output, ensure_ascii=False, indent=2)
        output.write('\n')
    print(json.dumps({'rows': len(rows), 'split': report['split'], 'excluded': len(report['excluded'])}))
