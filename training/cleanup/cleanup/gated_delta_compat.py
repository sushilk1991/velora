"""Opt-in, process-local Qwen3.5 training optimization; never used by the app.

Loads unmodified upstream MIT-licensed mlx-vlm source supplied locally. The
caller must retain its upstream LICENSE when redistributing that source.
Single-threaded training only: this context temporarily changes a module global.
BF16, masked/long sequences and real-model quality still require measured gates.
"""
from contextlib import contextmanager
from functools import wraps
import hashlib
import inspect
from pathlib import Path
import types

SOURCE_URL = ('https://raw.githubusercontent.com/Blaizzy/mlx-vlm/v0.7.12/'
              'mlx_vlm/models/qwen3_5/gated_delta.py')
SOURCE_SHA256 = '71da97ef25a013e185c4d19168b39c452b90f40d5462f4d08ff084a82e922d2f'
_ACTIVE = False


def _load_source(path):
    # Hash and execute the same bytes, avoiding a check/read race.
    source = Path(path).read_bytes()
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise ValueError('gated delta source checksum mismatch')
    module = types.ModuleType('_velora_upstream_gated_delta')
    exec(compile(source, str(path), 'exec'), module.__dict__)
    return module


@contextmanager
def training_gated_delta(source_path=None):
    """Yield provenance; restore the original callable even if training fails.

    None is a no-op and does not import MLX. Only use_kernel=False (the model's
    training path) is substituted. Keep Qwen's caller-side normalization intact.
    Masked calls and lower-bound/negative-eigenvalue variants use the original
    path: upstream chunking differs in its outputs at masked positions.
    No inference kernel is forced and no package files are modified.
    """
    global _ACTIVE
    if source_path is None:
        yield None
        return
    if _ACTIVE:
        raise RuntimeError('gated delta training context is already active')
    upstream = _load_source(source_path)
    from mlx_lm.models import qwen3_5
    original = qwen3_5.gated_delta_update
    signature = inspect.signature(original)
    required = {'q', 'k', 'v', 'a', 'b', 'A_log', 'dt_bias', 'state', 'mask',
                'use_kernel', 'lower_bound', 'allow_neg_eigval'}
    if set(signature.parameters) != required:
        raise RuntimeError('unsupported mlx-lm gated delta signature')

    provenance = {'source_url': SOURCE_URL, 'source_sha256': SOURCE_SHA256,
                  'source_path': str(Path(source_path).resolve()),
                  'target': 'mlx_lm.models.qwen3_5.gated_delta_update',
                  'scope': 'training only; use_kernel=False',
                  'python_dispatch_counts': {'optimized': 0, 'fallback': 0},
                  'counter_note': 'Python dispatch/tracing counts, not compiled forward-pass counts'}

    @wraps(original)
    def update(*args, **kwargs):
        bound = signature.bind(*args, **kwargs)
        bound.apply_defaults()
        values = bound.arguments
        if (values['use_kernel'] or values['lower_bound'] is not None
                or values['allow_neg_eigval'] or values['mask'] is not None):
            provenance['python_dispatch_counts']['fallback'] += 1
            return original(*args, **kwargs)
        # Upstream update owns decay/beta construction and chunk selection;
        # it expects q/k normalized by Qwen3.5, just like the original.
        provenance['python_dispatch_counts']['optimized'] += 1
        return upstream.gated_delta_update(**{
            key: value for key, value in values.items()
            if key not in {'lower_bound', 'allow_neg_eigval'}
        })

    _ACTIVE = True
    qwen3_5.gated_delta_update = update
    try:
        yield provenance
    finally:
        qwen3_5.gated_delta_update = original
        _ACTIVE = False
