"""Run the production worker with tiny local loader doubles; forbid acquisition."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import huggingface_hub
import mlx_lm
import mlx_lm.tokenizer_utils as tokenizer_utils
import mlx_lm.utils as utils

from velora_engine import cleanup_worker, models
from velora_engine.cleanup import CleanupEngine


# Record each real child load, allowing the parent to check identity and source:
# CleanupProcess -> production CLI -> Worker -> CleanupEngine -> local loaders.
record_path = Path(sys.argv.pop(1))
model_id = sys.argv[sys.argv.index("--model") + 1]


def forbidden(*args, **kwargs):
    raise AssertionError("offline cleanup attempted acquisition")


def load_model(path):
    config = utils.load_config(path)
    with record_path.open("a") as stream:
        stream.write(json.dumps({"model_id": model_id, "source": str(path)}) + "\n")
    return object(), config


def load_tokenizer(path, config, eos_token_ids=None):
    assert config == {"local_files_only": True, "trust_remote_code": False}
    assert path.is_dir()
    return object()


def warm(self, prompt):
    with record_path.open("a") as stream:
        stream.write(json.dumps({"prompt": prompt}) + "\n")


# All acquisition surfaces raise rather than relying on a prepopulated cache.
models.ensure_downloaded = forbidden
mlx_lm.load = forbidden
utils._download = forbidden
utils.snapshot_download = forbidden
huggingface_hub.snapshot_download = forbidden
huggingface_hub.hf_hub_download = forbidden
utils.load_model = load_model
tokenizer_utils.load = load_tokenizer
CleanupEngine._warm = warm
cleanup_worker.main()
