"""Pure CPU cache schema/ownership checks; no MLX or model load."""
import sys
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/"training/cleanup"))
from cleanup import cache_compat as c

def cache_type(name):
    def state(self): return self.value
    def restore(cls,value):
        obj=cls(); obj.value=value; return obj
    return type(name,(),{"__module__":"mlx_lm.models.cache","state":property(state),"from_state":classmethod(restore)})

def test_full_state_isolates_containers_and_retains_all_metadata():
    for name, values in [("ArraysCache",([1,2],[3],[4])),("KVCache",([1],[2],17))]:
        obj=cache_type(name)();obj.value=values
        snapshot=c.snapshot_full_state([obj]);one=c.restore_full_state(snapshot)[0];two=c.restore_full_state(snapshot)[0]
        assert one.value==two.value==values
        one.value[0].append(99)
        assert two.value==values and obj.value==values
        assert snapshot[0][1]==values
    with pytest.raises(ValueError):c.snapshot_full_state([object()])
    with pytest.raises(ValueError):c.restore_full_state([(type(obj),values,"wrong")])

def test_process_patch_restores_after_failure_and_refuses_nested(monkeypatch):
    monkeypatch.setattr(c,"version",lambda _:"0.32.2")
    original=(c.production._snapshot_prompt_cache,c.production._restore_prompt_cache)
    with pytest.raises(RuntimeError,match="sentinel"):
        with c.experimental_cache_api():
            assert c.production._snapshot_prompt_cache is c.snapshot_full_state
            with pytest.raises(RuntimeError,match="already active"):
                with c.experimental_cache_api(): pass
            raise RuntimeError("sentinel")
    assert original==(c.production._snapshot_prompt_cache,c.production._restore_prompt_cache)
    monkeypatch.setattr(c,"version",lambda _:"0.33.0")
    with pytest.raises(ValueError):
        with c.experimental_cache_api(): pass
