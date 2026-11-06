import importlib.util
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'prepare_lfm3_v4.py'
spec = importlib.util.spec_from_file_location('prepare_lfm3_v4', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

LEDGER = {'allowed_licenses': ['CC0-1.0'], 'sources': {'fixture': {'kind': 'synthetic', 'revision': '1', 'license': 'CC0-1.0'}}}


def row(id, raw, group, split='train', status='approved', visibility='public'):
    return {'id': id, 'raw': raw, 'target': raw + '.', 'mode': 'default', 'language': 'en', 'scenario_group': group,
            'visibility': visibility, 'source': {'name': 'fixture', 'revision': '1', 'license': 'CC0-1.0'},
            'teacher': {'name': 'fixture', 'revision': '1'}, 'quality_review': {'status': status, 'reviewer': 'fixture'}, 'split': split}


def test_group_contamination_family_exclusion_and_stable_dev():
    base = [row('leak', 'one two three four five six seven eight nine', 'leak-family'),
            row('sibling', 'a separate unrelated sentence', 'leak-family'),
            row('train', 'baseline exact duplicate content', 'base-train'),
            row('dev', 'a distinct untouched dev record', 'dev-family', 'dev')]
    held = [{'id': 'held', 'raw': 'one two three four five six seven eight different'}]
    additions = [row('duplicate', 'baseline exact duplicate content', 'addition-family'),
                 row('family', 'other unrelated new content', 'addition-family'),
                 row('dev-overlap', 'a distinct untouched dev record', 'other-family'),
                 row('kept', 'entirely separate approved training text', 'kept-family')]
    baseline, augmented, _, report = module.prepare(base, held, additions, LEDGER)
    assert [r['id'] for r in baseline] == ['train', 'dev']
    assert [r for r in augmented if r['split'] == 'dev'] == [base[3]]
    assert [r['id'] for r in augmented] == ['train', 'dev', 'kept']
    assert augmented[-1]['scenario_group'].startswith('v4-add-')
    assert {x['id'] for x in report['addition_excluded']} == {'duplicate', 'family', 'dev-overlap'}


def test_rejected_private_addition_is_still_rejected_by_validator():
    with pytest.raises(ValueError, match='non-public'):
        module.prepare([row('base', 'public base row', 'base')], [{'id': 'held', 'raw': 'external text'}],
                       [row('bad', 'secret text', 'secret', status='rejected', visibility='private')], LEDGER)


def test_existing_output_is_never_overwritten(tmp_path):
    with pytest.raises(FileExistsError):
        module.main(['--base', 'unused', '--old-guard', 'unused', '--fresh', 'unused', '--additions', 'unused',
                     '--ledger', 'unused', '--out', str(tmp_path)])
