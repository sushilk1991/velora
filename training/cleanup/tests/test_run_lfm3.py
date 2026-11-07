"""Portable LFM3 wrapper safety without importing models or allocating GPU state."""
from contextlib import contextmanager
import importlib.util
import json
from pathlib import Path
import sys
import subprocess
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


@pytest.mark.parametrize('command', ['train', 'generate-eval', 'score-checkpoints'])
@pytest.mark.parametrize('existing', ['output', 'output.lfm3-architecture.json', 'output.meta.json'])
def test_no_overwrite_before_registration(tmp_path, existing, command):
    argv = args(tmp_path, command)
    path = tmp_path / existing
    path.write_text('preserved')
    with pytest.raises(FileExistsError):
        wrapper.main(argv, architecture=lambda _: pytest.fail('must not register'))
    assert path.read_text() == 'preserved'


@pytest.mark.parametrize('command', ['train', 'generate-eval', 'score-checkpoints'])
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
                      if command != 'train' else ['enter', 'run', 'exit'])
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


@pytest.mark.parametrize('command', ['train', 'generate-eval', 'score-checkpoints'])
def test_help_is_forwarded_without_required_arguments_or_registration(command):
    seen = []
    wrapper.main([command, '--help'], runner=lambda: seen.extend(sys.argv[1:]),
                 architecture=lambda _: pytest.fail('must not register'))
    assert seen == [command, '--help']


def test_reject_other_commands_and_abbreviated_override(tmp_path):
    with pytest.raises(SystemExit):
        wrapper.main(['validate'])
    argv = args(tmp_path) + ['--base-rev', 'bad']
    with pytest.raises(SystemExit):
        wrapper.main(argv, architecture=lambda _: pytest.fail('must not register'))
    assert not list(tmp_path.glob('*.json'))


def test_score_preserves_repeated_checkpoints_and_strict_options(tmp_path):
    argv = args(tmp_path, 'score-checkpoints') + [
        '--data', 'dev.jsonl', '--holdout', 'guard.jsonl', '--ledger', 'ledger.json',
        '--adapter', 'adapter', '--checkpoint', 'first', '--checkpoint=second',
        '--max-seq', '1024']
    seen = []
    @contextmanager
    def architecture(_):
        yield {'source_sha256': wrapper.SOURCE_SHA256}
    wrapper.main(argv, runner=lambda: seen.extend(sys.argv[1:]), architecture=architecture,
                 cache_limit=lambda _: None)
    assert seen == argv
    assert json.loads((tmp_path / 'output.lfm3-architecture.json').read_text())['effective_invocation'] == argv
    with pytest.raises(SystemExit):
        wrapper.main(args(tmp_path / 'other', 'score-checkpoints') + ['--check', 'bad'])


@pytest.mark.parametrize('command', ['train', 'generate-eval', 'score-checkpoints'])
def test_real_help_forwarding_blocks_heavy_imports(command):
    code = """import builtins, runpy, sys
original = builtins.__import__
def guarded(name, *args, **kwargs):
    if name.split('.')[0] in {'mlx', 'mlx_lm', 'torch'}:
        raise RuntimeError('heavy import: ' + name)
    return original(name, *args, **kwargs)
builtins.__import__ = guarded
sys.argv = [sys.argv[1], sys.argv[2], '--help']
runpy.run_path(sys.argv[0], run_name='__main__')
"""
    result = subprocess.run([sys.executable, '-c', code, str(SCRIPT), command],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert 'usage:' in result.stdout and command in result.stdout
    if command == 'score-checkpoints':
        assert '--checkpoint' in result.stdout and '--holdout' in result.stdout
