"""Local evaluation resource sampling; imports MLX only for real model work."""
import os
from pathlib import Path
import resource
import subprocess
import time

STUDENT_CACHE_LIMIT_BYTES = 512 * 1024 * 1024


def configure_student_allocator(mx_module=None):
    if mx_module is None:
        import mlx.core as mx_module
    mx_module.set_cache_limit(STUDENT_CACHE_LIMIT_BYTES)
    return STUDENT_CACHE_LIMIT_BYTES


def sample_mlx_memory(mx_module=None):
    if mx_module is None:
        import mlx.core as mx_module
    return {'mlx_active_bytes':int(mx_module.get_active_memory()),
            'mlx_peak_bytes':int(mx_module.get_peak_memory()),
            'mlx_cache_bytes':int(mx_module.get_cache_memory())}


def loaded_model_memory(engine, metrics_provider=None):
    if getattr(engine, 'unhealthy', False):
        return {'available':False,'reason':'unhealthy model process must retire without further MLX calls'}
    provider = metrics_provider or getattr(engine, 'memory_provider', None)
    model = getattr(engine, '_model', None)
    if model is None:
        model = getattr(engine, 'model', None)
    if provider is None and model is None:
        return {'available':False,'reason':'no real model or injected metrics provider'}
    return {'available':True, **(provider or sample_mlx_memory)()}


def end_process_resources(engine, runner=None):
    """Call after case timers, while loaded model remains resident.

    Retain only footprint lines, never vmmap's addresses or mapping inventory.
    Peak MLX allocation and ru_maxrss describe this process lifetime, not a
    standalone physical-memory requirement or per-case allocation peak.
    """
    result = {'scope':'end of replay, model still resident; outside case timers',
              'pid':os.getpid(),'sampled_at_unix_s':time.time(),
              'peak_rss_native':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
              'peak_rss_units':'bytes on macOS','mlx_memory':loaded_model_memory(engine),
              'physical_footprint_lines':[]}
    try:
        response = (runner or subprocess.run)(['/usr/bin/vmmap','-summary',str(os.getpid())],
            capture_output=True,text=True,timeout=10)
        result['vmmap_exit_code'] = response.returncode
        result['physical_footprint_lines'] = [line.strip() for line in response.stdout.splitlines()
            if line.strip().startswith('Physical footprint:') or line.strip().startswith('Physical footprint (peak):')]
    except (OSError, subprocess.SubprocessError) as exc:
        result['vmmap_error_type'] = type(exc).__name__
    return result


def write_end_resources(output, engine, private_write, runner=None):
    directory = Path(output)/'resources'
    directory.mkdir(mode=0o700,exist_ok=True)
    os.chmod(directory,0o700)
    path = directory/f'end-{time.time_ns()}-{os.getpid()}.json'
    private_write(path,end_process_resources(engine,runner))
    return path
