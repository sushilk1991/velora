"""Resolve immutable public model snapshots and hash their actual contents."""
import json
import re
from pathlib import Path
from .data import digest


def resolve_model(base, revision):
    if not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('base revision must be a full immutable 40-character commit hash')
    path = Path(base).expanduser()
    if path.exists():
        path = path.absolute()
        if path.name != revision or path.parent.name != 'snapshots':
            raise ValueError('local base must be the matching Hugging Face snapshots/<revision> directory')
    else:
        from huggingface_hub import snapshot_download
        path = Path(snapshot_download(repo_id=base, revision=revision))
        if path.name != revision:
            raise ValueError('downloaded snapshot revision mismatch')
    files = {str(p.relative_to(path)): digest(p) for p in sorted(path.rglob('*')) if p.is_file() and p.suffix in ('.json', '.safetensors', '.model', '.tiktoken', '.jinja', '.txt')}
    if 'config.json' not in files or not any(name.endswith('.safetensors') for name in files):
        raise ValueError('snapshot missing config.json or model weights')
    return str(path), files


def adapter_hashes(path):
    if not path:
        return None
    root = Path(path)
    return {name: digest(root / name) for name in ('adapter_config.json', 'adapters.safetensors')}


def check_adapter(path, config):
    previous = json.loads((Path(path) / 'adapter_config.json').read_text())
    if previous != config:
        raise ValueError('initial adapter configuration differs from requested LoRA configuration')
    return adapter_hashes(path)


def validate_adapter_weights(weights, expected_shapes):
    if not expected_shapes or set(weights) != set(expected_shapes):
        raise ValueError('adapter weights must contain every expected LoRA key and no others')
    if any(tuple(weights[key].shape) != tuple(shape) for key, shape in expected_shapes.items()):
        raise ValueError('adapter weight shapes differ from the model LoRA parameters')


def load_local_snapshot(snapshot, adapter=None):
    """Keep tokenizer and architecture code local; reject partial LoRA loads."""
    from mlx_lm import load
    model, tokenizer = load(snapshot, adapter_path=adapter, trust_remote_code=False,
        tokenizer_config={'trust_remote_code': False, 'local_files_only': True})
    if adapter:
        import mlx.core as mx
        from mlx.utils import tree_flatten
        shapes = {name: value.shape for name, value in tree_flatten(model.parameters())
                  if name.rsplit('.', 1)[-1] in ('lora_a', 'lora_b')}
        validate_adapter_weights(mx.load(str(Path(adapter) / 'adapters.safetensors')), shapes)
    return model, tokenizer
