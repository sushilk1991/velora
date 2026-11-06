import copy
import pytest
from cleanup import render_messages
from cleanup.data import assign, meaning_warnings, validate
from cleanup.training import encode_example


def row():
    return {'id':'a','raw':'hello world', 'target':'Hello world.', 'mode':'default','language':'en','scenario_group':'g','split':'train','source':{'name':'synthetic','revision':'1','license':'CC0'},'teacher':{'name':'teacher','revision':'1'},'visibility':'public','quality_review':{'status':'approved','reviewer':'human'}}

HOLDOUT = [{'id':'holdout', 'raw':'something completely different', 'target':'Something completely different.'}]

def test_private_and_unreviewed_fail_closed():
    a = row(); a['visibility'] = 'private'
    with pytest.raises(ValueError, match='non-public'): validate([a], HOLDOUT)
    a = row(); a['quality_review']['status'] = 'generated'
    with pytest.raises(ValueError, match='review'): validate([a], HOLDOUT)
    validate([a], HOLDOUT, approved_only=False)

def test_group_split_and_overlap():
    a = row(); b = copy.deepcopy(a); b.update(id='b',raw='other words',target='Other words.',split='dev')
    with pytest.raises(ValueError, match='group crosses'): validate([a,b], HOLDOUT)
    assert assign([a,b], 'fixed')[0]['split'] == assign([a,b], 'fixed')[1]['split']
    a['raw'] = 'one two three four five six seven eight nine'
    with pytest.raises(ValueError, match='contamination'): validate([a], [{'id':'holdout', 'template':'zero one two three four five six seven eight'}])

def test_eos_and_boundary():
    class Tok:
        eos_token_id = 99
        def apply_chat_template(self, *a, **kw): return [1,2,3]
        def encode(self, *a, **kw): return [4,5]
    assert encode_example(Tok(), row(), 6) == ([1,2,3,4,5,99], 3)
    with pytest.raises(ValueError, match='exceeds'): encode_example(Tok(), row(), 5)

def test_prompt_and_warnings():
    assert '"romanize": false' in render_messages(row())[1]['content']
    a = row(); a['target'] = 'Hello 42 world.'
    assert 'new number' in meaning_warnings(a)


def test_cross_field_duplicate_and_malformed():
    a = row(); b = copy.deepcopy(a); b.update(id='b', raw='distinct words', target='hello world', scenario_group='h')
    with pytest.raises(ValueError, match='duplicate'): validate([a,b], HOLDOUT)
    with pytest.raises(ValueError, match='object'): validate([None], HOLDOUT)
    a['vocabulary'] = 'not a list'
    with pytest.raises(ValueError, match='prompt options'): validate([a], HOLDOUT)
    with pytest.raises(ValueError, match='unique'): validate([row()], HOLDOUT * 2)

def test_ledger_and_review():
    ledger = {'allowed_licenses':['CC0'], 'sources': {'synthetic': {'kind':'synthetic','revision':'1','license':'CC0'}}}
    validate([row()], HOLDOUT, ledger=ledger)
    ledger['sources']['synthetic']['kind'] = 'user'
    with pytest.raises(ValueError, match='source'): validate([row()], HOLDOUT, ledger=ledger)
    ledger['sources']['synthetic']['kind'] = 'public'; ledger['allowed_licenses'] = []
    with pytest.raises(ValueError, match='source'): validate([row()], HOLDOUT, ledger=ledger)


def test_null_source_ledger_cannot_disable_provenance():
    import json
    with pytest.raises(ValueError, match='source'):
        validate([row()], HOLDOUT, ledger=json.loads('null'))


def test_adapter_resume_requires_complete_matching_shapes():
    from types import SimpleNamespace
    from cleanup.provenance import validate_adapter_weights
    expected = {'layer.lora_a': (2, 4), 'layer.lora_b': (4, 2)}
    complete = {key: SimpleNamespace(shape=value) for key, value in expected.items()}
    validate_adapter_weights(complete, expected)
    with pytest.raises(ValueError, match='every expected'):
        validate_adapter_weights({'layer.lora_a': complete['layer.lora_a']}, expected)
    with pytest.raises(ValueError, match='shapes'):
        validate_adapter_weights({**complete, 'layer.lora_b': SimpleNamespace(shape=(2, 4))}, expected)

def test_preflight_reports_all_overflow_and_stable_order():
    from cleanup.training import preflight
    class Tok:
        eos_token_id = 9
        def apply_chat_template(self, *a, **kw): return [1, 2]
        def encode(self, text, **kw): return [3] * len(text)
    a = row(); a['id'] = 'z'; a['target'] = 'x' * 10
    b = row(); b.update(id='a', split='dev', target='x')
    with pytest.raises(ValueError, match='"z"'): preflight(Tok(), [a,b], 5)
    with pytest.raises(ValueError, match='at least one'): preflight(Tok(), [a,b], 5, True)
    c = row(); c.update(id='c', target='x')
    sets, overflow = preflight(Tok(), [a,b,c], 5, True)
    assert overflow == [{'id':'z', 'tokens':13}]
    assert len(sets['train']) == len(sets['dev']) == 1

def test_snapshot_hash_and_resume_config(tmp_path):
    import json
    from cleanup.provenance import resolve_model, check_adapter
    revision = 'a' * 40
    p = tmp_path / 'snapshots' / revision; p.mkdir(parents=True)
    (p/'config.json').write_text('{}'); (p/'weights.safetensors').write_bytes(b'weights')
    resolved, files = resolve_model(str(p), revision)
    assert resolved == str(p) and len(files['weights.safetensors']) == 64
    with pytest.raises(ValueError, match='revision'): resolve_model(str(p), 'b' * 40)
    adapter = tmp_path/'adapter'; adapter.mkdir()
    (adapter/'adapter_config.json').write_text(json.dumps({'rank': 1})); (adapter/'adapters.safetensors').write_bytes(b'x')
    assert check_adapter(adapter, {'rank': 1})['adapters.safetensors']
    with pytest.raises(ValueError, match='configuration'): check_adapter(adapter, {'rank': 2})

def test_gradient_and_loss_diagnostics_reject_nonfinite():
    from cleanup.training import require_finite_metrics, FiniteLossCallback
    assert require_finite_metrics(1.0, True, 2)['finite']
    for loss, finite, count in [(float('nan'),True,2), (1.0,False,2), (1.0,True,0)]:
        with pytest.raises(ValueError, match='non-finite'): require_finite_metrics(loss, finite, count)
    with pytest.raises(ValueError, match='training loss'):
        FiniteLossCallback().on_train_loss_report({'train_loss':float('inf')})

def test_manifest_pins_inputs_and_preflight(tmp_path):
    from types import SimpleNamespace
    from cleanup.training import build_manifest
    paths = []
    for name in ('data', 'holdout', 'ledger'):
        path = tmp_path/name; path.write_text(name); paths.append(str(path))
    args = SimpleNamespace(base='repo', base_revision='a'*40, data=paths[0], holdout=paths[1], ledger=paths[2], seed=42)
    manifest = build_manifest(args, '/snapshot', {'config.json':'hash'}, None, [{'id':'x','tokens':513}], {'train':[1], 'dev':[2]})
    assert manifest['parameters']['seed'] == 42
    assert len(manifest['data_sha256']) == 64
    assert manifest['snapshot_files_sha256']['config.json'] == 'hash'
    assert manifest['preflight']['skipped_overlength'][0]['id'] == 'x'

def test_indic_normalization_preserves_combining_marks():
    from cleanup.data import norm
    assert norm('कल') != norm('काल')
    assert norm('किताब') != norm('कताब')
    assert norm('क़लम') == norm('क़लम')

def test_metrics_callback_writes_jsonl_and_rejects_nonfinite(tmp_path):
    import json
    from cleanup.training import FiniteLossCallback
    path = tmp_path / 'metrics.jsonl'
    cb = FiniteLossCallback(path)
    cb.on_train_loss_report({'iteration': 1, 'train_loss': 1.2})
    cb.on_val_loss_report({'iteration': 2, 'val_loss': 1.1})
    assert [json.loads(line)['kind'] for line in path.read_text().splitlines()] == ['train', 'val']
    with pytest.raises(ValueError): cb.on_val_loss_report({'val_loss': float('nan')})

def test_curate_transitive_components_and_exclusions():
    from cleanup.curate import curate
    ledger = {'allowed_licenses':['CC0'], 'sources': {'synthetic': {'kind':'synthetic','revision':'1','license':'CC0'}}}
    a = row(); a.update(id='a', raw='one two three four five six seven eight alpha', target='Alpha unique', scenario_group='first')
    b = row(); b.update(id='b', raw='one two three four five six seven eight beta', target='Beta unique', scenario_group='second')
    c = row(); c.update(id='c', raw='entirely distinct content', target='Gamma unique', scenario_group='second')
    d = row(); d.update(id='d', raw='hello world', target='Delta unique'); d['quality_review']['status'] = 'rejected'
    e = row(); e.update(id='e', raw='Something completely different.', target='Epsilon unique')
    rows, report = curate([a,b,c,d,e], HOLDOUT, ledger)
    assert len(rows) == 3 and len({r['scenario_group'] for r in rows}) == 1
    assert len({r['split'] for r in rows}) == 1
    assert [x['reason'] for x in report['excluded']] == ['not independently approved', 'frozen holdout overlap']
    assert a['scenario_group'] == 'first'

def test_curate_rejects_private_even_when_unapproved():
    from cleanup.curate import curate
    a = row(); a['visibility'] = 'private'; a['quality_review']['status'] = 'rejected'
    with pytest.raises(ValueError, match='non-public'): curate([a], HOLDOUT, {})

def test_snapshot_hash_includes_templates(tmp_path):
    from cleanup.provenance import resolve_model
    revision = 'a'*40; root = tmp_path/'snapshots'/revision; root.mkdir(parents=True)
    (root/'config.json').write_text('{}'); (root/'weights.safetensors').write_text('weights')
    (root/'chat_template.jinja').write_text('template'); (root/'vocab.txt').write_text('vocab')
    _, files = resolve_model(str(root), revision)
    assert 'chat_template.jinja' in files and 'vocab.txt' in files

def test_curation_command_requires_and_checks_sotto_inputs(tmp_path):
    import json
    from types import SimpleNamespace
    from cleanup.curate import run, SOTTO_REVISION
    source = {'name':'sotto-transcript-cleanup', 'revision':SOTTO_REVISION, 'license':'MIT'}
    a = row(); a['source'] = source
    ledger = {'allowed_licenses':['MIT'], 'sources': {source['name']:{'kind':'public','revision':SOTTO_REVISION,'license':'MIT'}}}
    def write(name, obj, lines=False):
        path = tmp_path/name
        path.write_text(''.join(json.dumps(x)+'\n' for x in obj) if lines else json.dumps(obj))
        return str(path)
    args = SimpleNamespace(input=[write('reviewed', [a], True)], holdout=write('holdout', HOLDOUT, True), ledger=write('ledger', ledger), out=str(tmp_path/'out'), report=str(tmp_path/'report'), seed='fixed', dev_percent=20, sotto_raw=None)
    with pytest.raises(ValueError, match='require --sotto-raw'): run(args)
    args.sotto_raw = write('raw', [{'raw':'unrelated', 'source':source}], True)
    with pytest.raises(ValueError, match='does not occur'): run(args)
    args.sotto_raw = write('raw2', [{'raw':a['raw'], 'source':source}], True)
    run(args)
    report = json.loads((tmp_path/'report').read_text())
    assert report['rows'] == 1 and len(report['sotto_raw_sha256']) == 64

def test_schedule_uses_optimizer_updates():
    from cleanup.optimization import schedule_value
    def rate(i): return schedule_value(i, peak=1.0, total_updates=9, warmup_updates=2, cosine=True)
    assert rate(0) == 0 and rate(1) == 0.5 and rate(2) == 1.0
    assert rate(8) == 0 and 0 < rate(5) < 1


def test_constant_schedule_is_reportable_before_first_accumulated_update():
    import mlx.core as mx
    from cleanup.optimization import make_optimizer, schedule_value
    with mx.stream(mx.cpu):
        optimizer = make_optimizer(lambda step: schedule_value(step, peak=1e-5,
            total_updates=2, warmup_updates=0, cosine=False, backend=mx), 1.0)
        assert abs(optimizer.learning_rate.item() - 1e-5) < 1e-10

def test_answer_loss_excludes_first_pad_and_includes_eos():
    import mlx.core as mx
    import mlx.nn as nn
    from cleanup.optimization import answer_loss
    with mx.stream(mx.cpu):
        # Prompt [1,2], answer [3], EOS [4], pad [0].
        batch = mx.array([[1,2,3,4,0]])
        class Model:
            def __call__(self, x):
                # Correct answer and EOS predictions, deliberately poor pad prediction.
                return mx.array([[[0.,0.,0.,0.,0.], [0.,0.,0.,5.,0.], [0.,0.,0.,0.,5.], [0.,5.,0.,0.,0.]]])
        loss, count = answer_loss(Model(), batch, mx.array([[2,4]]))
        expected = nn.losses.cross_entropy(Model()(batch[:,:-1])[:,1:3,:], mx.array([[3,4]])).mean()
        assert count.item() == 2
        assert abs(loss.item() - expected.item()) < 1e-6

def test_clipped_adam_receives_scaled_global_gradient():
    import mlx.core as mx
    import mlx.nn as nn
    from cleanup.optimization import make_optimizer
    with mx.stream(mx.cpu):
        model = nn.Linear(2, 1, bias=False)
        opt = make_optimizer(0.01, 1.0)
        grads = {'weight': mx.array([[3.,4.]])}
        # Adam's second moment directly exposes the gradient after clipping.
        opt.update(model, grads)
        mx.eval(opt.state)
        v = opt.state['weight']['v'].tolist()[0]
        assert abs(v[0] / v[1] - (3/4)**2) < 1e-5
        assert abs(v[0] + v[1] - 0.001) < 1e-6

def test_checkpoint_selection_only_uses_dev_and_finite_loss():
    from cleanup.scoring import dev_examples, select_best
    assert [r['id'] for r in dev_examples([{'id':'train','split':'train'}, {'id':'b','split':'dev'}, {'id':'a','split':'dev'}])] == ['a','b']
    assert select_best([{'checkpoint':'a','dev_loss':2.0},{'checkpoint':'b','dev_loss':1.0}])['checkpoint'] == 'b'
    with pytest.raises(ValueError): select_best([{'dev_loss':float('nan')}])
