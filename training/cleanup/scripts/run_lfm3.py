#!/usr/bin/env python3
"""Portable, explicitly scoped LFM3 train/evaluation entry point.

The historical experiments used a separate operator wrapper. This entry point
records its own provenance; it does not replace those historical wrapper hashes.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'training/cleanup'))
from cleanup.lfm3_compat import lfm3_architecture, SOURCE_SHA256, SOURCE_REPO_PATH

BASE_REVISION = '4d6d94c9c2c2f249f1f740f4f08e071b0dbfe099'
EVAL_CACHE_BYTES = 512 * 1024 * 1024
PORT = ROOT / SOURCE_REPO_PATH
COMMON_OPTIONS = {'--data', '--base', '--base-revision', '--out', '--adapter'}
SCORE_OPTIONS = {'--holdout', '--ledger', '--checkpoint', '--max-seq'}
TRAIN_OPTIONS = {'--holdout', '--ledger', '--warmup-updates', '--lora-scale',
                 '--clip-grad-norm', '--lr-schedule', '--val-batches', '--report-every',
                 '--eval-every', '--save-every', '--seed', '--skip-overlength',
                 '--iters', '--rank', '--lr', '--grad-accum', '--max-seq'}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _write_new(path, payload):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as handle:
        json.dump(payload, handle, indent=2)
        handle.write('\n')


def _call(argv, runner):
    previous = sys.argv
    try:
        sys.argv = [str(Path(__file__)), *argv]
        if runner is None:
            from cleanup.__main__ import main
            runner = main
        return runner()
    finally:
        sys.argv = previous


def _set_eval_cache_limit(size):
    import mlx.core as mx
    mx.set_cache_limit(size)


def main(argv=None, *, runner=None, architecture=None, cache_limit=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('command', choices=('train', 'generate-eval', 'score-checkpoints'))
    parser.add_argument('--base', required=True, help='existing local snapshots/<audited revision>')
    parser.add_argument('--base-revision', required=True)
    parser.add_argument('--out', required=True, help='fresh output with an existing parent directory')
    if argv and argv[0] in ('train', 'generate-eval', 'score-checkpoints') and any(x in ('-h', '--help') for x in argv[1:]):
        return _call([argv[0], '--help'], runner)
    args, _ = parser.parse_known_args(argv)
    allowed = COMMON_OPTIONS | {'train': TRAIN_OPTIONS, 'generate-eval': {'--max-tokens'},
                                'score-checkpoints': SCORE_OPTIONS}[args.command]
    # The downstream parser accepts abbreviations. Reject them here so an
    # abbreviated duplicate cannot bypass the audited base/output checks.
    for token in argv[1:]:
        if token.startswith('--') and token.split('=', 1)[0] not in allowed:
            parser.error('unsupported or abbreviated option: ' + token.split('=', 1)[0])
    if args.base_revision != BASE_REVISION:
        raise ValueError('only the audited LFM3 base revision is supported')
    base = Path(args.base).expanduser().resolve(strict=True)
    if not base.is_dir() or base.name != BASE_REVISION or base.parent.name != 'snapshots':
        raise ValueError('base must be the audited local snapshots/<revision> directory')
    if json.loads((base / 'config.json').read_text()).get('model_type') != 'lfm3':
        raise ValueError('base config must declare lfm3')
    if digest(PORT) != SOURCE_SHA256:
        raise ValueError('LFM3 architecture source checksum mismatch')
    out = Path(args.out).expanduser().absolute()
    sidecar = Path(str(out) + '.lfm3-architecture.json')
    for path in (out, sidecar, Path(str(out) + '.meta.json')):
        if os.path.lexists(path):
            raise FileExistsError('refusing to overwrite ' + str(path))
    if not out.parent.is_dir():
        raise ValueError('output parent directory must already exist')
    effective = list(argv)
    for index, token in enumerate(effective):
        for option, value in (('--base', str(base)), ('--out', str(out))):
            if token == option:
                effective[index + 1] = value
            elif token.startswith(option + '='):
                effective[index] = option + '=' + value
    architecture = lfm3_architecture if architecture is None else architecture
    with architecture(PORT) as info:
        if args.command != 'train':
            (cache_limit or _set_eval_cache_limit)(EVAL_CACHE_BYTES)
        payload = {**info, 'wrapper_sha256': digest(__file__),
                   'wrapper_source': 'training/cleanup/scripts/run_lfm3.py',
                   'base_revision': BASE_REVISION, 'invocation': argv, 'effective_invocation': effective,
                   'evaluation_allocator_cache_limit_bytes': EVAL_CACHE_BYTES if args.command != 'train' else None}
        _write_new(sidecar, payload)
        result = _call(effective, runner)
        if out.is_dir():
            _write_new(out / 'architecture.json', payload)
        return result


if __name__ == '__main__':
    main()
