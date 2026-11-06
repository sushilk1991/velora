"""Process-scoped cache bridge for the isolated MLX-LM 0.32.2 experiment.

The shipped engine uses 0.31's split state/meta_state protocol. 0.32.2 stores
KV offsets and recurrent padding/lengths inside state itself. No engine file,
dependency installation, array values or disk cache is modified here.
"""
from contextlib import contextmanager
from importlib.metadata import version
from velora_engine import cleanup as production

_TAG = 'mlx-lm-0.32.2-full-state'
_active = False


def snapshot_full_state(cache):
    result = []
    for item in cache:
        cls = type(item)
        if cls.__module__ != 'mlx_lm.models.cache' or cls.__name__ not in ('KVCache', 'ArraysCache'):
            raise ValueError('unaudited experimental cache type')
        result.append((cls, production._copy_cache_containers(item.state), _TAG))
    return result


def restore_full_state(snapshot):
    result = []
    for cls, state, tag in snapshot:
        if tag != _TAG or cls.__module__ != 'mlx_lm.models.cache' or cls.__name__ not in ('KVCache', 'ArraysCache'):
            raise ValueError('unaudited experimental cache snapshot')
        result.append(cls.from_state(production._copy_cache_containers(state)))
    return result


@contextmanager
def experimental_cache_api():
    """One isolated, serial model lifetime; never enter in the installed app."""
    global _active
    release = version('mlx-lm')
    if release == '0.31.3':
        yield 'original-0.31.3'
        return
    if release != '0.32.2':
        raise ValueError('experimental cache bridge requires audited MLX-LM 0.32.2')
    if _active:
        raise RuntimeError('experimental cache bridge is already active')
    old_snapshot = production._snapshot_prompt_cache
    old_restore = production._restore_prompt_cache
    _active = True
    production._snapshot_prompt_cache = snapshot_full_state
    production._restore_prompt_cache = restore_full_state
    try:
        yield _TAG
    finally:
        production._snapshot_prompt_cache = old_snapshot
        production._restore_prompt_cache = old_restore
        _active = False
