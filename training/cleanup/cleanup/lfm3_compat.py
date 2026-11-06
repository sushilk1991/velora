"""Register one audited experimental LFM3 port in an isolated process.

No download, package modification, model construction or production integration.
Keep this context alive for the entire model lifetime (including LoRA/fusion).
The port uses full KV caches with sliding masks; it is not a bounded-cache port.
"""
from contextlib import contextmanager
import hashlib
import importlib
from pathlib import Path
import sys
import types

MODULE_NAME = 'mlx_lm.models.lfm3'
SOURCE_SHA256 = '40e87df07edf678baf6c1bdc1719bd5b6fb0e8eb88acaca1fdbfc9196ce94a58'
SOURCE_REPO_PATH = 'docs/research/2026-10-27-lfm3-bakeoff/lfm3.py'
_MISSING = object()


@contextmanager
def lfm3_architecture(source_path=None, *, model_type='lfm3'):
    """Yield provenance for the exact local port; None is a no-op.

    Single-threaded evaluation/training only. Never replaces an already-loaded
    LFM3 module. Import/API checks validate availability, not checkpoint parity.
    The caller must independently pin the model/tokenizer/adapter artifacts.
    """
    if source_path is None:
        yield None
        return
    if model_type != 'lfm3':
        raise ValueError('this architecture context supports only lfm3')
    path = Path(source_path).resolve()
    source = path.read_bytes()
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise ValueError('LFM3 architecture source checksum mismatch')
    parent = importlib.import_module('mlx_lm.models')
    old_attribute = getattr(parent, 'lfm3', _MISSING)
    if MODULE_NAME in sys.modules or old_attribute is not _MISSING:
        raise RuntimeError('LFM3 architecture is already registered')
    module = types.ModuleType(MODULE_NAME)
    module.__file__ = str(path)
    module.__package__ = 'mlx_lm.models'
    # Dataclasses resolve annotation modules during execution.
    sys.modules[MODULE_NAME] = module
    try:
        exec(compile(source, str(path), 'exec'), module.__dict__)
        for name in ('Model', 'ModelArgs'):
            if not isinstance(getattr(module, name, None), type):
                raise RuntimeError(f'LFM3 port missing {name} class')
        if not callable(getattr(module.ModelArgs, 'from_dict', None)):
            raise RuntimeError('LFM3 ModelArgs lacks mlx-lm config compatibility')
        setattr(parent, 'lfm3', module)
        yield {'model_type': 'lfm3', 'module': MODULE_NAME,
               'source_path': str(path), 'source_sha256': SOURCE_SHA256,
               'source_repo_path': SOURCE_REPO_PATH,
               'scope': 'experimental process-local architecture registration'}
    finally:
        sys.modules.pop(MODULE_NAME, None)
        if old_attribute is _MISSING:
            if hasattr(parent, 'lfm3'):
                delattr(parent, 'lfm3')
        else:
            setattr(parent, 'lfm3', old_attribute)
