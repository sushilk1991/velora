#!/usr/bin/env python3
"""Private-history replays through production CleanupProcess; metadata only.

matrix -> ABBA blocks -> isolated interpreter -> CleanupProcess -> worker
           whole matrix holds /tmp/velora-bench.lock
History text stays in memory. Results contain hashes, never transcript text.
"""
from __future__ import annotations

import argparse
import asyncio
from dataclasses import asdict
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

_ROOT = Path(__file__).resolve().parents[2]
_LOCK = Path('/tmp/velora-bench.lock')
_MODEL = 'mlx-community/Qwen3.5-4B-MLX-8bit'
_ORDER = ('A', 'B', 'B', 'A')
_RAW_CHAR_LIMITS = (100, 1800)
_REPLAY_TIMEOUT_MS = 10_000
_COLD_IDLE_S = 10.0
sys.path.insert(0, str(_ROOT / 'engine' / 'src'))


def _digest(text):
    # Compare exact UTF-8 output without retaining any owner text.
    return hashlib.sha256(text.encode()).hexdigest()


def _worker():
    # Adapters alter this disposable worker only, preserving production paths.
    os.environ.setdefault('VELORA_TRACE_CLEANUP', '1')
    from velora_engine import cleanup, cleanup_worker
    adapter = os.environ.get('VELORA_BENCH_ADAPTER')
    if adapter:
        spec = importlib.util.spec_from_file_location('latency_adapter', adapter)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        if hasattr(module, 'install'):
            module.install(cleanup)
        else:
            module._install(cleanup_worker.Worker)
    sys.argv.remove('--worker')
    cleanup_worker.main()


def _load_rows(database, count):
    # SQLite refuses writes; filter lengths before loading a bounded corpus.
    connection = sqlite3.connect(database.resolve().as_uri() + '?mode=ro', uri=True)
    connection.row_factory = sqlite3.Row
    connection.execute('PRAGMA query_only=ON')
    try:
        return [dict(row) for row in connection.execute(
            'SELECT id, raw, bundle_id, app_name, mode FROM dictations '
            'WHERE cleanup_applied=1 AND length(raw) BETWEEN ? AND ? '
            'ORDER BY id DESC LIMIT ?', (*_RAW_CHAR_LIMITS, count))]
    finally:
        connection.close()


async def _replay(args):
    # Copy settings outside the repository: Config may migrate built-in modes.
    os.environ.setdefault('VELORA_TRACE_CLEANUP', '1')
    from velora_engine.cleanup_process import CleanupProcess
    from velora_engine.config import Config
    from velora_engine.formatting import (
        STATIC_SYSTEM_PROMPT, build_prefill_prompt_candidates, encode_breaks,
        postprocess, run_gate,
    )
    rows = _load_rows(args.database, args.cases)
    if not rows:
        raise SystemExit('No eligible history rows')
    if args.trace_pair:
        rows = rows[:1] * (3 if args.trace_prime else 2)
    with tempfile.TemporaryDirectory(prefix='velora-replay-') as temporary:
        home = Path(temporary)
        source = Path.home() / '.velora'
        shutil.copy2(source / 'config.json', home / 'config.json')
        shutil.copytree(source / 'modes', home / 'modes')
        config = Config(home)
        process = CleanupProcess(
            args.model, local_model_path=args.model_path,
            worker_command=(sys.executable, str(Path(__file__).resolve()), '--worker'),
        )
        load_started = time.perf_counter_ns()
        await process.load_async(STATIC_SYSTEM_PROMPT)
        load_ns = time.perf_counter_ns() - load_started
        if args.ready_file:
            # A targeted recorder attaches after model load, before replay work.
            args.ready_file.write_text(json.dumps({'pid':process.pid}))
            while not args.go_file.exists():
                await asyncio.sleep(0.05)
        try:
            for index, row in enumerate(rows):
                gate = run_gate(row['raw'], config, bundle_id=row['bundle_id'],
                                app_name=row['app_name'], explicit_mode=row['mode'])
                if not gate.use_llm:
                    continue
                candidates = build_prefill_prompt_candidates(
                    config, row['bundle_id'], row['app_name'], row['mode'],
                    romanize=gate.romanize,
                )
                if args.prepare:
                    await process.prepare_prefix(candidates)
                # Idle interval is outside total: test the next actual request.
                cold_index = 1 if args.trace_prime else 0
                idle_s = (_COLD_IDLE_S if index == cold_index else 0.0) if args.trace_pair else args.idle_s
                await asyncio.sleep(idle_s)
                load1 = os.getloadavg()[0]
                started = time.perf_counter_ns()
                result = await process.cleanup(
                    gate.text if gate.romanize else encode_breaks(gate.text),
                    gate.system_prompt or STATIC_SYSTEM_PROMPT,
                    timeout_ms=_REPLAY_TIMEOUT_MS, check_ratio=not gate.romanize,
                    allowed_terms=list(dict.fromkeys(config.global_vocabulary + gate.mode.vocabulary)),
                    prefix_candidates=candidates, copy_draft=not args.no_draft,
                )
                finished = time.perf_counter_ns()
                output = postprocess(result.text, gate) if result.applied else result.text
                record = asdict(result)
                record.pop('text')
                record.update(
                    index=index, row_id=row['id'], input_sha256=_digest(row['raw']),
                    output_sha256=_digest(output), prompt_sha256=_digest(gate.system_prompt or STATIC_SYSTEM_PROMPT),
                    output_bytes=len(output.encode()), elapsed_ns=finished-started,
                    postprocess_ns=time.perf_counter_ns()-finished, load1=load1,
                    load1_end=os.getloadavg()[0], model=args.model,
                    model_path=str(args.model_path), load_ns=load_ns,
                    idle_s=idle_s, prepare=args.prepare, copy_draft=not args.no_draft,
                    trace_stage=('prime' if args.trace_prime and index == 0 else
                                 'cold' if idle_s else 'warm') if args.trace_pair else None,
                )
                with args.output.open('a') as stream:
                    stream.write(json.dumps(record) + '\n')
                print(json.dumps({'index':index,'ms':record['ms'],'ttft_ms':record['ttft_ms'],
                                  'load1':load1,'applied':record['applied']}), flush=True)
        finally:
            await process.aclose()


def _matrix(args):
    # One lock covers all arms and subprocess lifetimes; builds stay outside it.
    plan = json.loads(args.matrix.read_text())
    with _LOCK.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        running = subprocess.run(['pgrep', '-x', 'Velora'], capture_output=True)
        if running.returncode == 0:
            raise SystemExit('Quit Velora before measuring')
        for repetition in range(args.rounds):
            for block, arm in enumerate(_ORDER):
                settings = plan[arm]
                target = args.output / f'{repetition}-{block}-{arm}.jsonl'
                target.parent.mkdir(parents=True, exist_ok=True)
                if target.exists():
                    raise SystemExit(f'Refusing to append existing {target}')
                command = [settings['python'], str(Path(__file__).resolve()), '--run',
                           '--output', str(target), '--cases', str(args.cases),
                           '--database', str(args.database),
                           '--idle-s', str(args.idle_s), '--model',settings.get('model',_MODEL)]
                if settings.get('model_path'):
                    command += ['--model-path', settings['model_path']]
                if args.prepare:
                    command.append('--prepare')
                if args.no_draft:
                    command.append('--no-draft')
                environment = dict(os.environ, **settings.get('env', {}))
                if settings.get('adapter'):
                    environment['VELORA_BENCH_ADAPTER'] = settings['adapter']
                environment['PYTHONPATH'] = str(_ROOT / 'engine' / 'src')
                # Worker stderr includes metrics but never requests or outputs.
                with target.with_suffix('.stderr').open('w') as stderr:
                    subprocess.run(command, env=environment, stderr=stderr, check=True)


def _main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--matrix',type=Path)
    parser.add_argument('--run',action='store_true')
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--database',type=Path,default=Path.home()/'.velora/history.sqlite3')
    parser.add_argument('--model',default=_MODEL)
    parser.add_argument('--model-path',type=Path)
    parser.add_argument('--cases',type=int,default=12)
    parser.add_argument('--rounds',type=int,default=2)
    parser.add_argument('--idle-s',type=float,default=0)
    parser.add_argument('--prepare',action='store_true')
    parser.add_argument('--no-draft',action='store_true')
    parser.add_argument('--trace-pair',action='store_true')
    parser.add_argument('--trace-prime',action='store_true')
    parser.add_argument('--ready-file',type=Path)
    parser.add_argument('--go-file',type=Path)
    args = parser.parse_args()
    if bool(args.ready_file) != bool(args.go_file):
        parser.error('--ready-file and --go-file must be used together')
    if args.trace_prime and not args.trace_pair:
        parser.error('--trace-prime requires --trace-pair')
    if args.matrix:
        _matrix(args)
        return
    asyncio.run(_replay(args))


if __name__ == '__main__':
    if '--worker' in sys.argv:
        _worker()
    else:
        _main()
