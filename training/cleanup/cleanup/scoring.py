"""Select a checkpoint by dev loss, without evaluating frozen test labels."""
import json
from pathlib import Path
from .data import digest, read, validate
from .provenance import adapter_hashes, resolve_model, load_local_snapshot, validate_adapter_weights
from .training import encode_example
from .optimization import answer_loss



def dev_examples(rows):
    dev = sorted((r for r in rows if r['split'] == 'dev'), key=lambda r: r['id'])
    if not dev:
        raise ValueError('dev split is empty')
    return dev


def select_best(results):
    import math
    if not results or any(not math.isfinite(item['dev_loss']) for item in results):
        raise ValueError('checkpoint losses must be finite and nonempty')
    return min(results, key=lambda item: item['dev_loss'])

def run(args):
    rows, guard = read(args.data), read(args.holdout)
    validate(rows, guard, ledger=json.loads(Path(args.ledger).read_text()))
    dev = dev_examples(rows)
    snapshot, files = resolve_model(args.base, args.base_revision)
    manifest = json.loads((Path(args.adapter) / 'manifest.json').read_text())
    if manifest.get('base_revision') != args.base_revision:
        raise ValueError('adapter manifest base revision mismatch')
    original_files = manifest.get('snapshot_files_sha256', {})
    if not original_files or files != original_files:
        raise ValueError('adapter manifest base file hashes differ')
    import mlx.core as mx
    from mlx_lm.tuner.trainer import evaluate
    model, tokenizer = load_local_snapshot(snapshot, args.adapter)
    examples = [encode_example(tokenizer, row, args.max_seq) for row in dev]
    reference = {name: value.shape for name, value in mx.load(str(Path(args.adapter) / 'adapters.safetensors')).items()}
    results = []
    for checkpoint in args.checkpoint:
        weights = mx.load(checkpoint)
        validate_adapter_weights(weights, reference)
        model.load_weights(list(weights.items()), strict=False)
        mx.eval(model.parameters())
        loss = float(evaluate(model, examples, batch_size=1, num_batches=-1, max_seq_length=args.max_seq, loss=answer_loss))
        if not __import__('math').isfinite(loss):
            raise ValueError(f'{checkpoint}: non-finite dev loss')
        results.append({'checkpoint': checkpoint, 'sha256': digest(checkpoint), 'dev_loss': loss})
    best = select_best(results)
    report = {'selection': 'minimum full dev answer-token loss', 'best': best, 'results': results, 'dev_examples': len(dev), 'data_sha256': digest(args.data), 'holdout_guard_sha256': digest(args.holdout), 'ledger_sha256': digest(args.ledger), 'base_revision': args.base_revision, 'snapshot_files_sha256': files, 'adapter_sha256': adapter_hashes(args.adapter)}
    with open(args.out, 'x') as out:
        json.dump(report, out, indent=2)
        out.write('\n')
    print(json.dumps(best))
