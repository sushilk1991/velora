import inspect
import sys
import types

import pytest
from cleanup import gated_delta_compat as compat


def test_noop_and_checksum_fail_before_import(tmp_path):
    with compat.training_gated_delta() as provenance:
        assert provenance is None
    source = tmp_path / 'wrong.py'
    source.write_text('raise AssertionError("must never execute")')
    with pytest.raises(ValueError, match='checksum'):
        with compat.training_gated_delta(source):
            pass


def test_training_route_signature_restore_and_provenance(monkeypatch):
    calls = []
    def original(q, k, v, a, b, A_log, dt_bias, state=None, mask=None,
                 *, use_kernel=True, lower_bound=None, allow_neg_eigval=False):
        calls.append('original')
        return 'original'
    def upstream(**kwargs):
        assert kwargs['use_kernel'] is False
        assert 'lower_bound' not in kwargs
        calls.append('upstream')
        return 'upstream'
    fake = types.SimpleNamespace(gated_delta_update=original)
    monkeypatch.setitem(sys.modules, 'mlx_lm.models', types.SimpleNamespace(qwen3_5=fake))
    monkeypatch.setattr(compat, '_load_source', lambda path: types.SimpleNamespace(gated_delta_update=upstream))
    args = (1, 2, 3, 4, 5, 6, 7)
    with pytest.raises(RuntimeError, match='training failed'):
        with compat.training_gated_delta('/tmp/source.py') as provenance:
            assert provenance['source_sha256'] == compat.SOURCE_SHA256
            assert inspect.signature(fake.gated_delta_update) == inspect.signature(original)
            assert fake.gated_delta_update(*args) == 'original'
            assert fake.gated_delta_update(*args, use_kernel=False) == 'upstream'
            assert fake.gated_delta_update(*args, use_kernel=False, lower_bound=.1) == 'original'
            assert fake.gated_delta_update(*args, use_kernel=False, allow_neg_eigval=True) == 'original'
            assert fake.gated_delta_update(*args, use_kernel=False, mask='padding') == 'original'
            with pytest.raises(RuntimeError, match='already active'):
                with compat.training_gated_delta('/tmp/source.py'):
                    pass
            raise RuntimeError('training failed')
    assert fake.gated_delta_update is original
    assert not compat._ACTIVE
    assert calls == ['original', 'upstream', 'original', 'original', 'original']
