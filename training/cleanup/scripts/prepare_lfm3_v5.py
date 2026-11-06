#!/usr/bin/env python3
"""Extend the frozen public V4 dataset without moving or removing original rows."""
import argparse
import collections
import copy
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cleanup.curate import SOTTO_REVISION, curate
from cleanup.data import digest, grams, norm, read, validate

DEFAULT_SEED = 'velora-public-lfm3-v5-20261107'


def check_sotto(rows, sotto_raw):
    selected = [r for r in rows if isinstance(r, dict) and isinstance(r.get('source'), dict)
                and r['source'].get('name') == 'sotto-transcript-cleanup']
    if selected and sotto_raw is None:
        raise ValueError('Sotto reviewed rows require --sotto-raw')
    if sotto_raw is None:
        return
    expected = {'name': 'sotto-transcript-cleanup', 'revision': SOTTO_REVISION, 'license': 'MIT'}
    if any(not isinstance(r, dict) or r.get('source') != expected or
           not isinstance(r.get('raw'), str) or not r['raw'].strip() for r in sotto_raw):
        raise ValueError('invalid Sotto raw provenance')
    available = {r['raw'] for r in sotto_raw}
    if any(r.get('source') != expected or r.get('raw') not in available for r in selected):
        raise ValueError('reviewed Sotto raw missing from pinned public export or wrong provenance')


def prepare(base, held, additions, ledger, sotto_raw=None, *, seed=DEFAULT_SEED, dev_percent=20):
    # A contaminated old row is a fatal experiment-design error: never silently
    # delete rows which the warm-start checkpoint has already seen.
    validate(base, held, ledger=ledger)
    if not base:
        raise ValueError('base dataset must not be empty')
    held_ids = {r['id'] for r in held}
    base_ids = {r['id'] for r in base}
    if base_ids & held_ids:
        raise ValueError('base IDs overlap held-out union')
    if any(isinstance(r, dict) and r.get('id') in base_ids | held_ids for r in additions):
        raise ValueError('addition IDs overlap base or held-out union')
    check_sotto(base + additions, sotto_raw)
    curated, curation = curate(additions, held, ledger, seed=seed, dev_percent=dev_percent)
    exact, gram_splits = set(), collections.defaultdict(set)
    for row in base:
        for field in ('raw', 'target'):
            exact.add(norm(row[field]))
            for gram in grams(row[field]):
                gram_splits[gram].add(row['split'])
    components = collections.defaultdict(list)
    for row in curated:
        components[row['scenario_group']].append(row)
    selected, excluded, decisions = [], list(curation['excluded']), []
    original_groups = {r['id']: r['scenario_group'] for r in additions}
    base_groups = {r['scenario_group'] for r in base}
    for group, rows in components.items():
        duplicate = any(norm(r[f]) in exact for r in rows for f in ('raw', 'target'))
        touched = set().union(*(gram_splits[g] for r in rows for f in ('raw', 'target') for g in grams(r[f])))
        new_group = 'v5-add-' + group
        if new_group in base_groups:
            raise ValueError('new component group collides with original group')
        reason = ('component contains exact duplicate of base' if duplicate else
                  'component bridges original train and dev' if len(touched) > 1 else None)
        split = None if reason else (next(iter(touched)) if touched else rows[0]['split'])
        decision = {'component': new_group, 'ids': [r['id'] for r in rows],
                    'original_scenario_groups': sorted({original_groups[r['id']] for r in rows}),
                    'touched_original_splits': sorted(touched), 'split': split,
                    'decision': reason or ('forced to original split' if touched else 'seeded component assignment')}
        decisions.append(decision)
        if reason:
            excluded.extend({'id': r['id'], 'reason': reason} for r in rows)
            continue
        selected.extend(dict(r, scenario_group=new_group, split=split) for r in rows)
    combined = copy.deepcopy(base) + selected
    validate(combined, held, ledger=ledger)
    assert combined[:len(base)] == base
    newdev = [r for r in selected if r['split'] == 'dev']
    report = {'seed': seed, 'dev_percent': dev_percent, 'original_rows_preserved': True,
              'base_excluded': [], 'addition_excluded': excluded, 'addition_curation': curation,
              'component_decisions': decisions,
              'splits': {name: dict(collections.Counter(r['split'] for r in rows))
                         for name, rows in [('original', base), ('new', selected), ('combined', combined)]},
              'original_dev_ids': [r['id'] for r in base if r['split'] == 'dev'],
              'new_dev_ids': [r['id'] for r in newdev],
              'new_dev_scenarios': [{'id': r['id'], 'scenario_group': r['scenario_group'],
                                     'original_scenario_group': original_groups[r['id']]} for r in newdev],
              'selected_addition_ids': [r['id'] for r in selected],
              'review_status': 'model-assisted independent review; not human review'}
    return combined, report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('base', 'old-guard', 'fresh', 'additions', 'ledger', 'sotto-raw', 'out'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--seed', default=DEFAULT_SEED)
    parser.add_argument('--dev-percent', type=int, default=20)
    parser.add_argument('--expected-base-rows', type=int, default=1838)
    parser.add_argument('--expected-base-dev', type=int, default=362)
    args = parser.parse_args(argv)
    out = Path(args.out)
    if out.exists():
        raise FileExistsError(f'destination already exists: {out}')
    inputs = {name: Path(getattr(args, name)) for name in ('base', 'old_guard', 'fresh', 'additions', 'ledger', 'sotto_raw')}
    hashes = {name: digest(path) for name, path in inputs.items()}
    base_bytes = inputs['base'].read_bytes()
    base = read(inputs['base'])
    if len(base) != args.expected_base_rows or sum(r.get('split') == 'dev' for r in base) != args.expected_base_dev:
        raise ValueError('frozen base row/dev counts do not match expected counts')
    ledger_bytes = inputs['ledger'].read_bytes()
    held = read(inputs['old_guard']) + read(inputs['fresh'])
    combined, report = prepare(base, held,
                               read(inputs['additions']), json.loads(ledger_bytes), read(inputs['sotto_raw']),
                               seed=args.seed, dev_percent=args.dev_percent)
    if hashes != {name: digest(path) for name, path in inputs.items()}:
        raise ValueError('input changed during preparation')
    # Preserve the entire original byte prefix, including serialization, order,
    # whitespace, and line endings. A missing final newline needs a separator.
    suffix = ''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in combined[len(base):]).encode()
    separator = b'\n' if suffix and base_bytes and not base_bytes.endswith((b'\n', b'\r')) else b''
    out.mkdir(parents=True, exist_ok=False)
    (out / 'reviewed.jsonl').write_bytes(base_bytes + separator + suffix)
    (out / 'sources.json').write_bytes(ledger_bytes)
    report.update(inputs_sha256=hashes,
                  outputs_sha256={name: digest(out / name) for name in ('reviewed.jsonl', 'sources.json')},
                  source_sha256={str(Path(__file__).name): digest(__file__),
                                 'cleanup/curate.py': digest(Path(__file__).resolve().parents[1] / 'cleanup/curate.py'),
                                 'cleanup/data.py': digest(Path(__file__).resolve().parents[1] / 'cleanup/data.py')},
                  original_byte_prefix_length=len(base_bytes), original_byte_prefix_sha256=hashes['base'],
                  original_row_count=len(base), held_out_count=len(held))
    (out / 'curation.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'rows': len(combined), 'splits': report['splits'], 'excluded': len(report['addition_excluded'])}))


if __name__ == '__main__':
    main()
