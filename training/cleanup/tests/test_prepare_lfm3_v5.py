import copy
import importlib.util
import json
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'prepare_lfm3_v5.py'
spec = importlib.util.spec_from_file_location('prepare_lfm3_v5', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
LEDGER = {'allowed_licenses': ['CC0-1.0'], 'sources': {'fixture': {'kind': 'synthetic', 'revision': '1', 'license': 'CC0-1.0'}}}
HELD = [{'id': 'held', 'raw': 'external completely isolated heldout'}]
TRAIN = 'alpha bravo charlie delta echo foxtrot golf hotel'
DEV = 'india juliet kilo lima mike november oscar papa'


def row(id, raw, group=None, split='train', **kw):
    return dict(id=id, raw=raw, target=raw + '.', mode='default', language='en', scenario_group=group or id,
                visibility='public', source={'name': 'fixture', 'revision': '1', 'license': 'CC0-1.0'},
                teacher={'name': 'fixture', 'revision': '1'}, quality_review={'status': 'approved', 'reviewer': 'fixture'}, split=split, **kw)


def base():
    return [row('oldtrain', TRAIN + ' original'), row('olddev', DEV + ' original', split='dev')]


def test_base_overlap_is_fatal_not_silently_removed():
    with pytest.raises(ValueError, match='holdout contamination'):
        module.prepare(base(), [{'id': 'test', 'raw': TRAIN + ' final test'}], [], LEDGER)


def test_components_force_split_preserve_original():
    old = base(); before = copy.deepcopy(old)
    additions = [row('train-near', TRAIN + ' new'), row('dev-near', DEV + ' new')]
    combined, report = module.prepare(old, HELD, additions, LEDGER)
    assert old == before and combined[:2] == old
    assert {r['id']: r['split'] for r in combined[2:]} == {'train-near': 'train', 'dev-near': 'dev'}
    assert report['original_dev_ids'] == ['olddev'] and report['new_dev_ids'] == ['dev-near']
    assert all(r['scenario_group'].startswith('v5-add-') for r in combined[2:])


def test_exact_duplicate_drops_whole_connected_component():
    old = base()
    additions = [row('dupe', old[0]['raw'], 'duplicate-family'),
                 row('sibling', 'distinct duplicate sibling', 'duplicate-family'),
                 row('connected', TRAIN + ' connected member')]
    combined, report = module.prepare(old, HELD, additions, LEDGER)
    assert combined == old
    assert {r['id'] for r in report['addition_excluded']} == {'dupe', 'sibling', 'connected'}
    assert all('exact duplicate' in r['reason'] for r in report['addition_excluded'])


def test_bridge_drops_whole_transitive_component():
    additions = [row('train-near', TRAIN + ' new'), row('dev-near', DEV + ' new'),
                 row('bridge-train', TRAIN + ' bridge', 'bridge'), row('bridge-dev', DEV + ' bridge', 'bridge')]
    combined, report = module.prepare(base(), HELD, additions, LEDGER)
    assert combined == base()
    assert len(report['addition_excluded']) == 4
    assert all('bridges original train and dev' in r['reason'] for r in report['addition_excluded'])


def test_target_to_raw_overlap_and_transitive_connected_component():
    additions = [row('a', 'new unique raw first'), row('b', 'new unique raw second', 'linked'),
                 row('c', 'new unique raw third', 'linked')]
    additions[0]['target'] = TRAIN + ' new target'
    additions[1]['target'] = TRAIN + ' another target'
    result, _ = module.prepare(base(), HELD, additions, LEDGER)
    assert {r['split'] for r in result[2:]} == {'train'}
    assert len({r['scenario_group'] for r in result[2:]}) == 1


def test_independent_families_keep_seeded_assignment():
    additions = [row(f'n{i}', f'unique synthetic family number {i}') for i in range(40)]
    expected, _ = module.curate(additions, HELD, LEDGER, seed='fixed', dev_percent=20)
    result, report = module.prepare(base(), HELD, additions, LEDGER, seed='fixed')
    assert [(r['id'], r['split']) for r in result[2:]] == [(r['id'], r['split']) for r in expected]
    assert set(report['splits']['new']) == {'train', 'dev'}


def test_approval_holdout_and_provenance_checks():
    rejected = row('rejected', 'rejected synthetic fixture'); rejected['quality_review']['status'] = 'rejected'
    overlap = row('overlap', HELD[0]['raw'])
    result, report = module.prepare(base(), HELD, [rejected, overlap], LEDGER)
    assert result == base() and len(report['addition_excluded']) == 2
    rejected['visibility'] = 'private'
    with pytest.raises(ValueError, match='non-public'):
        module.prepare(base(), HELD, [rejected], LEDGER)
    with pytest.raises(ValueError, match='IDs overlap'):
        module.prepare(base(), HELD, [row('oldtrain', 'unrelated new text')], LEDGER)


def test_sotto_membership_and_revision_for_original_and_new():
    ledger = copy.deepcopy(LEDGER)
    ledger['allowed_licenses'].append('MIT')
    ledger['sources']['sotto-transcript-cleanup'] = {'kind': 'public', 'revision': module.SOTTO_REVISION, 'license': 'MIT'}
    original = base(); original[0]['source'] = {'name': 'sotto-transcript-cleanup', 'revision': module.SOTTO_REVISION, 'license': 'MIT'}
    with pytest.raises(ValueError, match='require --sotto-raw'):
        module.prepare(original, HELD, [], ledger)
    raw = [{'raw': original[0]['raw'], 'source': original[0]['source']}]
    assert module.prepare(original, HELD, [], ledger, raw)[0] == original
    with pytest.raises(ValueError, match='missing from pinned'):
        module.prepare(original, HELD, [], ledger, [])
    bad = copy.deepcopy(raw); bad[0]['source']['revision'] = 'wrong'
    with pytest.raises(ValueError, match='invalid Sotto raw provenance'):
        module.prepare(original, HELD, [], ledger, bad)


def test_cli_preserves_original_bytes_and_writes_provenance(tmp_path):
    files = {'base': base(), 'old-guard': HELD, 'fresh': [{'id': 'fresh', 'raw': 'other independent test example'}],
             'additions': [row('new', 'new separate row')], 'sotto-raw': []}
    args = []
    for name, rows in files.items():
        path = tmp_path / (name + '.jsonl')
        path.write_bytes(b'\r\n'.join(json.dumps(r, ensure_ascii=False, separators=(',', ': ')).encode() for r in rows))
        args.extend(['--' + name, str(path)])
    ledger = tmp_path / 'ledger.json'; ledger.write_text(json.dumps(LEDGER))
    out = tmp_path / 'new'
    args += ['--ledger', str(ledger), '--out', str(out), '--expected-base-rows', '2', '--expected-base-dev', '1']
    module.main(args)
    original = (tmp_path / 'base.jsonl').read_bytes()
    assert (out / 'reviewed.jsonl').read_bytes().startswith(original + b'\n')
    assert module.read(out / 'reviewed.jsonl')[:2] == base()
    report = json.loads((out / 'curation.json').read_text())
    assert report['original_byte_prefix_length'] == len(original)
    assert report['outputs_sha256']['reviewed.jsonl'] == module.digest(out / 'reviewed.jsonl')
    assert report['splits']['original'] == {'train': 1, 'dev': 1}
    with pytest.raises(FileExistsError):
        module.main(args)
