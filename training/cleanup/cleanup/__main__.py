import argparse
import json
from pathlib import Path
from .data import assign, meaning_warnings, read, validate


def main():
    parser = argparse.ArgumentParser(description='Public cleanup student pipeline')
    subs = parser.add_subparsers(dest='command', required=True)
    for name in ('validate', 'split'):
        p = subs.add_parser(name)
        p.add_argument('--data', required=True); p.add_argument('--holdout', required=True); p.add_argument('--ledger', required=True)
        if name == 'split':
            p.add_argument('--out', required=True); p.add_argument('--seed', default='velora-cleanup-v1'); p.add_argument('--dev-percent', type=int, default=20)
    p = subs.add_parser('acquire-sotto')
    p.add_argument('--out', required=True)
    p = subs.add_parser('curate')
    p.add_argument('--input', action='append', required=True, help='reviewed JSONL; repeat in precedence order')
    for name in ('holdout', 'ledger', 'out', 'report'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--sotto-raw', help='raw-only JSONL from acquire-sotto')
    p.add_argument('--seed', default='velora-public-20261106-v1')
    p.add_argument('--dev-percent', type=int, default=20)
    p = subs.add_parser('train')
    for name in ('data', 'holdout', 'ledger', 'base', 'base-revision', 'out'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--warmup-updates', type=int, default=0); p.add_argument('--lora-scale', type=float, default=20.0); p.add_argument('--clip-grad-norm', type=float, default=1.0); p.add_argument('--lr-schedule', choices=('constant', 'cosine'), default='constant'); p.add_argument('--val-batches', type=int, default=8); p.add_argument('--report-every', type=int, default=25); p.add_argument('--eval-every', type=int); p.add_argument('--save-every', type=int); p.add_argument('--gated-delta-source'); p.add_argument('--seed', type=int, default=42); p.add_argument('--skip-overlength', action='store_true'); p.add_argument('--adapter'); p.add_argument('--iters', type=int, default=200); p.add_argument('--rank', type=int, default=16); p.add_argument('--lr', type=float, default=1e-4); p.add_argument('--grad-accum', type=int, default=4); p.add_argument('--max-seq', type=int, default=512)
    p = subs.add_parser('score-checkpoints')
    for name in ('data', 'holdout', 'ledger', 'base', 'base-revision', 'adapter', 'out'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--checkpoint', action='append', required=True)
    p.add_argument('--max-seq', type=int, default=512)
    p = subs.add_parser('generate-eval')
    for name in ('data', 'base', 'base-revision', 'out'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--adapter'); p.add_argument('--max-tokens', type=int, default=256)
    args = parser.parse_args()
    if args.command == 'acquire-sotto':
        from .curate import acquire_sotto
        print(json.dumps(acquire_sotto(args.out), indent=2))
    elif args.command == 'curate':
        from .curate import run
        run(args)
    elif args.command in ('validate', 'split'):
        rows = read(args.data); holdout = read(args.holdout)
        validate(rows, holdout, ledger=json.loads(Path(args.ledger).read_text()), require_splits=args.command == 'validate', approved_only=False)
        if args.command == 'split':
            rows = assign(rows, args.seed, args.dev_percent)
            validate(rows, holdout, ledger=json.loads(Path(args.ledger).read_text()), approved_only=False)
            Path(args.out).write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in rows))
        warnings = [{'id': r['id'], 'warnings': meaning_warnings(r)} for r in rows if meaning_warnings(r)]
        print(json.dumps({'rows': len(rows), 'warnings': warnings}, ensure_ascii=False, indent=2))
    elif args.command == 'train':
        if min(args.iters, args.rank, args.grad_accum, args.max_seq) <= 0 or args.lr <= 0:
            parser.error('training parameters must be positive')
        if args.iters % args.grad_accum or args.warmup_updates < 0 or args.warmup_updates >= args.iters // args.grad_accum or args.lora_scale <= 0 or args.clip_grad_norm <= 0:
            parser.error('iters must be divisible by grad-accum, warmup less than updates, and scale/clip positive')
        if args.val_batches != -1 and args.val_batches < 1 or args.report_every < 1 or (args.eval_every is not None and args.eval_every < 1) or (args.save_every is not None and args.save_every < 1):
            parser.error('cadence must be positive; val-batches may also be -1')
        from .training import run
        run(args)
    elif args.command == 'score-checkpoints':
        from .scoring import run
        run(args)
    else:
        from .evaluation import run
        run(args)

if __name__ == '__main__':
    main()
