import hashlib
import sys
import types
import pytest
from cleanup import lfm3_compat as compat


def test_noop_wrong_family_and_checksum(tmp_path):
    with compat.lfm3_architecture() as provenance:
        assert provenance is None
    with pytest.raises(ValueError, match='only lfm3'):
        with compat.lfm3_architecture('unused', model_type='qwen3_5'):
            pass
    path = tmp_path / 'bad.py'
    path.write_text('raise AssertionError("untrusted code executed")')
    with pytest.raises(ValueError, match='checksum'):
        with compat.lfm3_architecture(path):
            pass


def fixture_source(tmp_path, monkeypatch, source):
    path = tmp_path / 'port.py'
    path.write_text(source)
    monkeypatch.setattr(compat, 'SOURCE_SHA256', hashlib.sha256(path.read_bytes()).hexdigest())
    parent = types.ModuleType('mlx_lm.models')
    monkeypatch.setattr(compat.importlib, 'import_module', lambda name: parent)
    monkeypatch.delitem(sys.modules, compat.MODULE_NAME, raising=False)
    return path, parent


def test_registration_provenance_and_exception_cleanup(tmp_path, monkeypatch):
    path, parent = fixture_source(tmp_path, monkeypatch, '''
from dataclasses import dataclass
@dataclass
class ModelArgs:
    model_type: str = 'lfm3'
    @classmethod
    def from_dict(cls, value): return cls(**value)
class Model: pass
''')
    with pytest.raises(ValueError, match='evaluation failed'):
        with compat.lfm3_architecture(path) as provenance:
            assert parent.lfm3 is sys.modules[compat.MODULE_NAME]
            assert provenance['source_sha256'] == compat.SOURCE_SHA256
            assert parent.lfm3.ModelArgs.from_dict({}).model_type == 'lfm3'
            with pytest.raises(RuntimeError, match='already registered'):
                with compat.lfm3_architecture(path): pass
            raise ValueError('evaluation failed')
    assert compat.MODULE_NAME not in sys.modules
    assert not hasattr(parent, 'lfm3')


def test_partial_import_failure_cleans_registration(tmp_path, monkeypatch):
    path, parent = fixture_source(tmp_path, monkeypatch, 'raise ImportError("missing dependency")')
    with pytest.raises(ImportError, match='missing dependency'):
        with compat.lfm3_architecture(path): pass
    assert compat.MODULE_NAME not in sys.modules
    assert not hasattr(parent, 'lfm3')


def test_existing_module_preserved(tmp_path, monkeypatch):
    path, parent = fixture_source(tmp_path, monkeypatch, '')
    original = types.ModuleType(compat.MODULE_NAME)
    monkeypatch.setitem(sys.modules, compat.MODULE_NAME, original)
    with pytest.raises(RuntimeError, match='already registered'):
        with compat.lfm3_architecture(path): pass
    assert sys.modules[compat.MODULE_NAME] is original
