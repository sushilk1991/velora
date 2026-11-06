#!/usr/bin/env python3
"""Reproduce the public LFM3 v4 baseline and augmentation without resplitting dev."""
import argparse
import collections
import copy
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cleanup.curate import SOTTO_REVISION, curate
from cleanup.data import digest, grams, norm, read, validate


def prepare(base, held, additions, ledger, sotto_raw=None):
    """Return baseline, augmented, extended ledger and auditable exclusions."""
    ledger = copy.deepcopy(ledger)
    entry = {'kind': 'synthetic', 'revision': '20261106', 'license': 'CC0-1.0'}
    sources = ledger.setdefault('sources', {})
    if 'velora-muse-lfm3-long-v4' in sources and sources['velora-muse-lfm3-long-v4'] != entry:
        raise ValueError('conflicting v4 source ledger entry')
    sources['velora-muse-lfm3-long-v4'] = entry
    if 'CC0-1.0' not in ledger.get('allowed_licenses', []):
        raise ValueError('base ledger does not allow CC0-1.0')
    sotto = [r for r in additions if isinstance(r, dict) and isinstance(r.get('source'), dict) and r['source'].get('name') == 'sotto-transcript-cleanup']
    if sotto and sotto_raw is None:
        raise ValueError('Sotto additions require --sotto-raw')
    if sotto_raw is not None:
        expected = {'name': 'sotto-transcript-cleanup', 'revision': SOTTO_REVISION, 'license': 'MIT'}
        if any(not isinstance(r, dict) or r.get('source') != expected or not isinstance(r.get('raw'), str) for r in sotto_raw):
            raise ValueError('invalid Sotto raw provenance')
        available = {r['raw'] for r in sotto_raw}
        if any(r.get('raw') not in available for r in sotto):
            raise ValueError('Sotto addition raw missing from pinned public export')
    if not held:
        raise ValueError('held-out union must not be empty')
    held_text = {norm(r[f]) for r in held for f in ('raw', 'target', 'template') if isinstance(r.get(f), str)}
    held_grams = set().union(*(grams(r[f]) for r in held for f in ('raw', 'target', 'template') if isinstance(r.get(f), str)))
    contaminated = {r['scenario_group'] for r in base if any(norm(r[f]) in held_text or grams(r[f]) & held_grams for f in ('raw', 'target'))}
    baseline = [copy.deepcopy(r) for r in base if r['scenario_group'] not in contaminated]
    base_excluded = [{'id': r['id'], 'reason': 'scenario group overlaps frozen holdout'} for r in base if r['scenario_group'] in contaminated]
    validate(baseline, held, ledger=ledger)
    dev = [r for r in baseline if r['split'] == 'dev']
    # IDs in the external holdout and dev must remain distinct for validation.
    addition_held = held + dev
    curated, report = curate(additions, addition_held, ledger)
    base_text = {norm(r[f]) for r in baseline for f in ('raw', 'target')}
    duplicate_components = {r['scenario_group'] for r in curated if any(norm(r[f]) in base_text for f in ('raw', 'target'))}
    selected = []
    excluded = list(report['excluded'])
    for row in curated:
        if row['scenario_group'] in duplicate_components:
            excluded.append({'id': row['id'], 'reason': 'component contains exact duplicate of baseline'})
        else:
            row['scenario_group'] = 'v4-add-' + row['scenario_group']
            row['split'] = 'train'
            selected.append(row)
    augmented = baseline + selected
    validate(augmented, held, ledger=ledger)
    return baseline, augmented, ledger, {'base_excluded': base_excluded, 'addition_excluded': excluded, 'addition_curation': report, 'selected_addition_ids': [r['id'] for r in selected], 'review_status': 'model-assisted independent review; not human review'}


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('base', 'old-guard', 'fresh', 'additions', 'ledger', 'out'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--sotto-raw')
    args = parser.parse_args(argv)
    destination = Path(args.out)
    if destination.exists():
        raise FileExistsError(f'destination already exists: {destination}')
    base, held = read(args.base), read(args.old_guard) + read(args.fresh)
    baseline, augmented, ledger, report = prepare(base, held, read(args.additions), json.loads(Path(args.ledger).read_text()), read(args.sotto_raw) if args.sotto_raw else None)
    destination.mkdir(parents=True, exist_ok=False)
    for name, rows in [('baseline.jsonl', baseline), ('augmented.jsonl', augmented)]:
        (destination / name).write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in rows))
    write_json(destination / 'sources.json', ledger)
    report['inputs_sha256'] = {name: digest(getattr(args, name)) for name in ('base', 'old_guard', 'fresh', 'additions', 'ledger')}
    report['inputs_sha256']['sotto_raw'] = digest(args.sotto_raw) if args.sotto_raw else None
    report['outputs_sha256'] = {name: digest(destination / name) for name in ('baseline.jsonl', 'augmented.jsonl', 'sources.json')}
    report['splits'] = {name: dict(collections.Counter(r['split'] for r in rows)) for name, rows in [('baseline', baseline), ('augmented', augmented)]}
    report['membership'] = {name: {split: [r['id'] for r in rows if r['split'] == split] for split in ('train', 'dev')} for name, rows in [('baseline', baseline), ('augmented', augmented)]}
    write_json(destination / 'metadata.json', report)
    print(json.dumps({'baseline': len(baseline), 'augmented': len(augmented), 'splits': report['splits']}))


if __name__ == '__main__':
    main()
