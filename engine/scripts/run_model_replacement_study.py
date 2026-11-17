#!/usr/bin/env python3
"""Run the bounded public study serially inside one Baton ML allocation."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from benchmark_model_replacement import contamination, host_snapshot
from compare_model_replacement import compare, load_run

HUB = Path.home() / '.cache/huggingface/hub'
BASELINE = ('mlx-community/Qwen3.5-4B-MLX-8bit', HUB / '.velora-downloads/15402d3d1555d0f44d9d7d265c6d779320e0c307f89dc65cb0cb9d91314c4b6b/snapshots/5319bbbe4f1cbe6c0b3c80f4f7de4f0338c3906d', 'production')
CANDIDATES = [
    ('mlx-community/Qwen3.5-2B-MLX-4bit', '93760be4f1f69842a46bc13dbdc0f19e291392a3', 'production',
     'Reduce capacity and packed bandwidth while preserving the general instruction contract.'),
    ('Muesli-HQ/qwen35-2b-muesli-cleanup-v12-mlx-8bit', '0fbfa48e98f1f8f28a0e3ca692066c823812db4e', 'muesli',
     'If general 2B loses cleanup quality, try task fine-tuning at higher precision and equal capacity.'),
    ('heyvedu/vedu-scribe-0.8b', '7dced5841c58d7d6e0118c4c123f222b35057871', 'vedu',
     'Try a smaller specialist with explicit trained formatting controls.'),
    ('Muesli-HQ/qwen35-0.8b-muesli-cleanup-v12-mlx-8bit', 'd557e9528ba42a47026372d372e071e6f2db33e2', 'muesli',
     'Separate specialist training from model capacity using the same Muesli prompt and precision.'),
    ('mlx-community/Qwen3.5-2B-MLX-8bit', 'e6ffd0033d03c9efa880984e611028e0da63905f', 'production',
     'Return to the general 2B architecture at higher precision to distinguish capacity loss from 4-bit quantization loss.'),
]


def wait_for_host(out: Path, deadline: float) -> None:
    stable = []
    while time.monotonic() < deadline:
        s = host_snapshot()
        with (out / 'admission.jsonl').open('a') as f:
            f.write(json.dumps(s) + '\n')
        stable.append(s)
        stable = stable[-16:]
        if len(stable) == 16 and not contamination(stable):
            return
        time.sleep(2)
    raise RuntimeError('host did not sustain 30 seconds without load, pressure or swap contamination')


def execute(out: Path, name: str, model: tuple, deadline: float, options=()) -> Path:
    wait_for_host(out, deadline)
    identity, path, style = model
    target = out / name
    cmd = [sys.executable, str(Path(__file__).with_name('benchmark_model_replacement.py')),
           '--model-id', identity, '--model-path', str(path), '--prompt-style', style,
           '--output', str(target), *options]
    print(json.dumps({'event': 'run_start', 'name': name, 'model': identity}), flush=True)
    with (out / (name + '.log')).open('w') as f:
        finished = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, env=os.environ)
    print(json.dumps({'event': 'run_end', 'name': name, 'exit_code': finished.returncode}), flush=True)
    if not (target / 'result.json').exists():
        raise RuntimeError(f'{name} produced no result; inspect {name}.log')
    return target


def critique(a, b):
    old = {c['case']: set(c['failures']) for c in a['cases']}
    new = {c['case']: set(c['failures']) for c in b['cases']}
    regressions = {n: sorted(new.get(n, {'missing'}) - errs)
                   for n, errs in old.items() if new.get(n, {'missing'}) - errs}
    result = b['result']
    return {'quality_regressions': regressions,
            'baseline_passed': sum(not c['failures'] for c in a['cases']),
            'candidate_passed': sum(not c['failures'] for c in b['cases']),
            'contamination': result['contamination'], 'error': result['error'],
            'nondeterministic_cases': [c['case'] for c in b['cases'] if c['unique_outputs'] != 1]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--resume-from', type=Path)
    parser.add_argument('--rerun-cycles', default='', help='Comma-separated cycle IDs requiring an adapter repair')
    parser.add_argument('--admission-timeout-seconds', type=int, default=1800)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    deadline = time.monotonic() + args.admission_timeout_seconds
    records = []
    rerun = {int(i) for i in args.rerun_cycles.split(',') if i}
    prior_paths = {}
    if args.resume_from and (args.resume_from / 'cycles.json').exists():
        prior_paths = {r['cycle']: Path(r['run_dir']) for r in json.loads(
            (args.resume_from / 'cycles.json').read_text())}
    try:
        a1 = execute(args.output, 'baseline-a1', BASELINE, deadline)
        a = load_run(a1)
        if a['result']['contamination'] or a['result']['error']:
            raise RuntimeError('baseline contaminated; retain raw evidence and rerun on idle hardware')
        for i, (identity, revision, style, hypothesis) in enumerate(CANDIDATES, 1):
            options = ()
            if args.resume_from and i not in rerun:
                previous = prior_paths.get(i, args.resume_from / f'cycle-{i}-b1')
                if (previous / 'result.json').exists():
                    prior = load_run(previous)
                    has_failure = any(str(r.get('reason') or '').startswith(
                        ('error', 'timeout', 'llm_', 'worker_')) for r in prior['requests'])
                    prior_review = critique(a, prior)
                    if not has_failure and not prior_review['contamination'] and prior_review['quality_regressions']:
                        record = {'cycle': i, 'model': identity, 'hypothesis': hypothesis,
                                  'run_dir': str(previous), **prior_review,
                                  'decision': 'reject early: quality gate failed; reuse valid earlier screen'}
                        records.append(record)
                        (args.output / 'cycles.json').write_text(json.dumps(records, indent=2) + '\n')
                        print(json.dumps(record), flush=True)
                        continue
            refinement_source = None
            if i == 5 and records and not any(records[0][k] for k in (
                    'quality_regressions', 'error', 'nondeterministic_cases', 'contamination')):
                identity, revision, style = CANDIDATES[0][:3]
                hypothesis = ('Compact retained predicate quality: test target-verified copy drafts '
                              'and a 512 MiB unused-buffer cache before changing capacity or runtime.')
                options = ('--copy-draft', '--cache-limit-mb', '512')
                refinement_source = args.output / 'cycle-1-b1'
            root = HUB / ('models--' + identity.replace('/', '--')) / 'snapshots' / revision
            if not root.is_dir():
                # New public artifacts use task-owned scratch; existing caches
                # and installed model metadata are never changed.
                import tempfile
                offline = os.environ.pop('HF_HUB_OFFLINE', None)
                try:
                    from huggingface_hub import snapshot_download
                    root = Path(snapshot_download(
                        repo_id=identity, revision=revision, token=False,
                        cache_dir=Path(tempfile.gettempdir()) / 'velora-model-study-2026-11-18-models'))
                finally:
                    if offline is not None:
                        os.environ['HF_HUB_OFFLINE'] = offline
            b1 = execute(args.output, f'cycle-{i}-b1', (identity, root, style), deadline, options)
            review = critique(a, load_run(b1))
            if refinement_source:
                original = load_run(refinement_source)
                refined = load_run(b1)
                if [r['text'] for r in original['requests']] != [r['text'] for r in refined['requests']]:
                    review['quality_regressions']['copy_draft_output_equality'] = ['raw outputs changed']
            record = {'cycle': i, 'model': identity, 'hypothesis': hypothesis,
                      'options': list(options), 'run_dir': str(b1), **review}
            records.append(record)
            (args.output / 'cycles.json').write_text(json.dumps(records, indent=2) + '\n')
            print(json.dumps(record), flush=True)
            if 'inference_failure' in review['contamination']:
                raise RuntimeError('inference failure; inspect raw reasons before continuing')
            if review['error']:
                raise RuntimeError('worker failed: ' + str(review['error']))
            if review['quality_regressions'] or review['nondeterministic_cases']:
                record['decision'] = 'reject early: quality or reliability gate failed'
            elif review['contamination']:
                record['decision'] = 'unqualified: host contamination'
            else:
                b2 = execute(args.output, f'cycle-{i}-b2', (identity, root, style), deadline, options)
                a2 = execute(args.output, f'cycle-{i}-a2', BASELINE, deadline)
                comparison = compare([load_run(p) for p in (a1, b1, b2, a2)])
                (args.output / f'cycle-{i}-comparison.json').write_text(json.dumps(comparison, indent=2) + '\n')
                record['decision'] = 'screen survivor; full qualification required' if comparison['screen_passed'] else 'reject: paired gates failed'
                record['failures'] = comparison['failures']
                if comparison['screen_passed']:
                    break
            (args.output / 'cycles.json').write_text(json.dumps(records, indent=2) + '\n')
    except Exception as exc:
        (args.output / 'blocked.json').write_text(json.dumps({'error': repr(exc), 'cycles': records}, indent=2) + '\n')
        raise
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
