"""MLX adapter training. Heavy dependencies are loaded only on execution."""
import json
import platform
import math
import time
import importlib.metadata
from pathlib import Path
from . import SYSTEM_PROMPT, render_messages
from .data import digest, read, validate
from .provenance import check_adapter, resolve_model, load_local_snapshot, validate_adapter_weights


def encode_example(tokenizer, row, max_seq=None):
    prompt = tokenizer.apply_chat_template(render_messages(row), tokenize=True, add_generation_prompt=True, enable_thinking=False)
    eos = tokenizer.eos_token_id
    if eos is None:
        raise ValueError('tokenizer has no EOS token')
    tokens = list(prompt) + list(tokenizer.encode(row['target'], add_special_tokens=False)) + [eos]
    if max_seq is not None and len(tokens) > max_seq:
        raise ValueError(f"{row['id']}: sequence exceeds {max_seq} tokens")
    return tokens, len(prompt)


def preflight(tokenizer, rows, max_seq, skip=False):
    sets = {'train': [], 'dev': []}; overflow = []
    for row in sorted(rows, key=lambda r: r['id']):
        example = encode_example(tokenizer, row)
        if len(example[0]) > max_seq:
            overflow.append({'id': row['id'], 'tokens': len(example[0])})
        else:
            sets[row['split']].append(example)
    if overflow and not skip:
        raise ValueError(f'overlength examples (limit {max_seq}): {json.dumps(overflow)}; use --skip-overlength to exclude explicitly')
    if not all(sets.values()):
        raise ValueError('preflight requires at least one train and one dev example')
    return sets, overflow



def require_finite_metrics(loss, finite_gradients, count):
    if not count or not math.isfinite(loss) or not finite_gradients:
        raise ValueError('non-finite loss or gradients in preflight')
    return {'loss': loss, 'gradient_arrays': count, 'finite': True}


class FiniteLossCallback:
    def __init__(self, path=None):
        self.path = path

    def _record(self, kind, metrics):
        if not math.isfinite(metrics[kind + '_loss']):
            raise ValueError('non-finite ' + ('training' if kind == 'train' else 'validation') + ' loss')
        if self.path is not None:
            with open(self.path, 'a') as output:
                output.write(json.dumps({'kind': kind, **metrics}, allow_nan=False) + '\n')

    def on_train_loss_report(self, metrics):
        self._record('train', metrics)

    def on_val_loss_report(self, metrics):
        self._record('val', metrics)


def build_manifest(args, snapshot, files, initial_hashes, overflow, sets):
    return {'schema_version': 2,
            'loss': 'answer tokens including EOS; padding excluded',
            'runner_files_sha256': {p.name: digest(p) for p in sorted(Path(__file__).parent.glob('*.py'))},
            'base': args.base, 'snapshot': snapshot, 'base_revision': args.base_revision, 'snapshot_files_sha256': files, 'initial_adapter_sha256': initial_hashes, 'data_sha256': digest(args.data), 'holdout_sha256': digest(args.holdout), 'ledger_sha256': digest(args.ledger), 'system_prompt': SYSTEM_PROMPT, 'parameters': vars(args), 'preflight': {'skipped_overlength': overflow, 'counts': {k: len(v) for k,v in sets.items()}}, 'python': platform.python_version(), 'mlx_lm': importlib.metadata.version('mlx-lm'), 'mlx': importlib.metadata.version('mlx')}


def run(args):
    rows, holdout = read(args.data), read(args.holdout)
    ledger = json.loads(Path(args.ledger).read_text())
    validate(rows, holdout, ledger=ledger)
    snapshot, files = resolve_model(args.base, args.base_revision)
    import mlx.core as mx
    import numpy as np
    from mlx_lm.tuner.trainer import TrainingArgs, train
    from mlx.utils import tree_flatten
    import mlx.nn as nn
    from .gated_delta_compat import training_gated_delta
    from .optimization import answer_loss, schedule_value, make_optimizer
    from mlx_lm.tuner.utils import linear_to_lora_layers
    mx.random.seed(args.seed); np.random.seed(args.seed)
    model, tok = load_local_snapshot(snapshot)
    sets, overflow = preflight(tok, rows, args.max_seq, args.skip_overlength)
    model.freeze()
    lora = {'rank': args.rank, 'scale': args.lora_scale, 'dropout': 0.0}
    config = {'fine_tune_type': 'lora', 'num_layers': len(model.layers), 'lora_parameters': lora}
    initial_hashes = check_adapter(args.adapter, config) if args.adapter else None
    linear_to_lora_layers(model, len(model.layers), lora)
    if args.adapter:
        weights = mx.load(str(Path(args.adapter) / 'adapters.safetensors'))
        validate_adapter_weights(weights, {name: value.shape for name, value in tree_flatten(model.trainable_parameters())})
        model.load_weights(list(weights.items()), strict=False)
    out = Path(args.out); out.mkdir(parents=True, exist_ok=False)
    (out / 'adapter_config.json').write_text(json.dumps(config, indent=2) + '\n')
    manifest = build_manifest(args, snapshot, files, initial_hashes, overflow, sets)
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest['preflight']), flush=True)
    manifest['hardware'] = {'platform': platform.platform(), 'machine': platform.machine(), 'mlx_device': str(mx.default_device()), 'device_info': mx.device_info()}
    updates = args.iters // args.grad_accum
    learning_rate = lambda step: schedule_value(step, peak=args.lr, total_updates=updates, warmup_updates=args.warmup_updates, cosine=args.lr_schedule == 'cosine', backend=mx)
    optimizer = make_optimizer(learning_rate, args.clip_grad_norm)
    started = time.perf_counter()
    with training_gated_delta(args.gated_delta_source) as gated_provenance:
        model.train()
        tokens, offset = sets['train'][0]
        batch = mx.array([tokens]); lengths = mx.array([[offset, len(tokens)]])
        (loss, _), grads = nn.value_and_grad(model, answer_loss)(model, batch, lengths)
        leaves = [v for _, v in tree_flatten(grads)]
        mx.eval(loss, *leaves)
        loss_value = float(loss.item())
        finite = bool(leaves) and all(bool(mx.all(mx.isfinite(g)).item()) for g in leaves)
        diagnostics = require_finite_metrics(loss_value, finite, len(leaves))
        manifest['gradient_preflight'] = diagnostics
        manifest['gated_delta'] = gated_provenance
        (out / 'manifest.json').write_text(json.dumps(manifest, indent=2, default=str) + '\n')
        train(model, optimizer, sets['train'], sets['dev'], args=TrainingArgs(batch_size=1, iters=args.iters, val_batches=args.val_batches, steps_per_report=args.report_every, steps_per_eval=args.eval_every or max(1, args.iters // 4), steps_per_save=args.save_every or max(1, args.iters // 4), max_seq_length=args.max_seq, adapter_file=str(out / 'adapters.safetensors'), grad_checkpoint=True, grad_accumulation_steps=args.grad_accum), loss=answer_loss, training_callback=FiniteLossCallback(out / 'metrics.jsonl'))
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2, default=str) + '\n')
    (out / 'result.json').write_text(json.dumps({'status': 'complete', 'adapter_sha256': digest(out / 'adapters.safetensors'), 'elapsed_seconds': round(time.perf_counter() - started, 4), 'peak_memory_bytes': mx.get_peak_memory()}, indent=2) + '\n')
