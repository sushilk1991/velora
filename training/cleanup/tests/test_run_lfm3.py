"""Portable LFM3 wrapper safety without importing models or allocating GPU state."""
from contextlib import contextmanager
import importlib.util
import json
from pathlib import Path
import sys
import pytest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/run_lfm3.py'
spec = importlib.util.spec_from_file_location('run_lfm3', SCRIPT)
wrapper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wrapper)


def args(tmp_path, command='train'):
    base = tmp_path / 'snapshots' / wrapper.BASE_REVISION
    base.mkdir(parents=True)
    (base / 'config.json').write_text('{"model_type":"lfm3"}')
    return [command, '--base', str(base), '--base-revision', wrapper.BASE_REVISION,
            '--out', str(tmp_path / 'output')]


def test_revision_rejected_before_writes_or_registration(tmp_path):
    argv = args(tmp_path)
    argv[4] = 'bad-revision'
    with pytest.raises(ValueError, match='audited'):
        wrapper.main(argv, architecture=lambda _: pytest.fail('must not register'))
    assert not (tmp_path / 'output').exists()
    assert not list(tmp_path.glob('*.json'))


@pytest.mark.parametrize('existing', ['output', 'output.lfm3-architecture.json', 'output.meta.json'])
def test_no_overwrite_before_registration(tmp_path, existing):
    argv = args(tmp_path)
    path = tmp_path / existing
    path.write_text('preserved')
    with pytest.raises(FileExistsError):
        wrapper.main(argv, architecture=lambda _: pytest.fail('must not register'))
    assert path.read_text() == 'preserved'


@pytest.mark.parametrize('command', ['train', 'generate-eval'])
def test_scoped_registration_provenance_and_eval_only_cache_cap(tmp_path, command):
    argv = args(tmp_path, command)
    events = []
    original_argv = sys.argv
    @contextmanager
    def architecture(port):
        assert port == wrapper.PORT
        events.append('enter')
        try:
            yield {'source_sha256': wrapper.SOURCE_SHA256}
        finally:
            events.append('exit')
    def runner():
        assert events[0] == 'enter' and 'exit' not in events
        assert sys.argv[1:] == argv
        events.append('run')
        if command == 'train':
            (tmp_path / 'output').mkdir()
        else:
            (tmp_path / 'output').write_text('fake prediction')
    wrapper.main(argv, runner=runner, architecture=architecture,
                 cache_limit=lambda size: events.append(('cap', size)))
    assert events == (['enter', ('cap', wrapper.EVAL_CACHE_BYTES), 'run', 'exit']
                      if command == 'generate-eval' else ['enter', 'run', 'exit'])
    assert sys.argv is original_argv
    payload = json.loads((tmp_path / 'output.lfm3-architecture.json').read_text())
    assert payload['wrapper_sha256'] == wrapper.digest(SCRIPT)
    assert payload['source_sha256'] == wrapper.SOURCE_SHA256
    if command == 'train':
        assert json.loads((tmp_path / 'output/architecture.json').read_text()) == payload


def test_scope_and_argv_restored_on_runner_failure(tmp_path):
    argv = args(tmp_path)
    exited = []
    original = sys.argv
    @contextmanager
    def architecture(_):
        try:
            yield {'source_sha256': wrapper.SOURCE_SHA256}
        finally:
            exited.append(True)
    def fail():
        raise RuntimeError('fake failure')
    with pytest.raises(RuntimeError, match='fake failure'):
        wrapper.main(argv, runner=fail, architecture=architecture)
    assert exited == [True] and sys.argv is original
    assert (tmp_path / 'output.lfm3-architecture.json').is_file()


def test_help_is_forwarded_without_required_arguments_or_registration():
    seen = []
    wrapper.main(['train', '--help'], runner=lambda: seen.extend(sys.argv[1:]),
                 architecture=lambda _: pytest.fail('must not register'))
    assert seen == ['train', '--help']


def test_reject_other_commands_and_abbreviated_override(tmp_path):
    with pytest.raises(SystemExit):
        wrapper.main(['score-checkpoints'])
    argv = args(tmp_path) + ['--base-rev', 'bad']
    with pytest.raises(SystemExit):
        wrapper.main(argv, architecture=lambda _: pytest.fail('must not register'))
    assert not list(tmp_path.glob('*.json'))
