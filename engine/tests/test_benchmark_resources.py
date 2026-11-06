"""Resource metrics without MLX imports, model loading, or vmmap execution."""
import builtins
import json
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import benchmark_resources as resources
from benchmark_personal_recordings import private_write


def test_allocator_and_metrics_use_injected_backend(monkeypatch):
    original=builtins.__import__
    def no_mlx(name,*args,**kwargs):
        if name.startswith('mlx'):
            raise AssertionError('CPU test imported MLX')
        return original(name,*args,**kwargs)
    monkeypatch.setattr(builtins,'__import__',no_mlx)
    configured=[]
    fake=SimpleNamespace(set_cache_limit=configured.append,get_active_memory=lambda:111,
        get_peak_memory=lambda:333,get_cache_memory=lambda:222)
    assert resources.configure_student_allocator(fake)==512*1024*1024
    assert configured==[512*1024*1024]
    expected={'mlx_active_bytes':111,'mlx_peak_bytes':333,'mlx_cache_bytes':222}
    assert resources.sample_mlx_memory(fake)==expected
    assert resources.loaded_model_memory(SimpleNamespace(model=None))['available'] is False
    engine=SimpleNamespace(model=None,memory_provider=lambda:expected)
    assert resources.loaded_model_memory(engine)=={'available':True,**expected}
    engine.unhealthy=True
    engine.memory_provider=lambda:(_ for _ in ()).throw(AssertionError('queried unhealthy model'))
    assert resources.loaded_model_memory(engine)['available'] is False


def test_end_artifact_keeps_only_footprint_lines_and_private_permissions(tmp_path):
    seen=[]
    def runner(command,**kwargs):
        seen.append((command,kwargs))
        return SimpleNamespace(returncode=0,stdout='Process: secret\nAddress 0xabc\n Physical footprint: 123.4M\nPhysical footprint (peak): 155.0M\nPRIVATE MAPPING\n')
    engine=SimpleNamespace(model=None,memory_provider=lambda:{'mlx_active_bytes':7,'mlx_peak_bytes':9,'mlx_cache_bytes':2})
    path=resources.write_end_resources(tmp_path,engine,private_write,runner)
    result=json.loads(path.read_text())
    assert result['physical_footprint_lines']==['Physical footprint: 123.4M','Physical footprint (peak): 155.0M']
    assert result['mlx_memory']['mlx_peak_bytes']==9
    assert 'secret' not in path.read_text() and '0xabc' not in path.read_text()
    assert seen[0][0][:2]==['/usr/bin/vmmap','-summary'] and seen[0][1]['timeout']==10
    assert path.stat().st_mode & 0o777==0o600
    assert path.parent.stat().st_mode & 0o777==0o700
