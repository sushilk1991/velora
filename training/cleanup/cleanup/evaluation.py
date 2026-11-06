"""Greedy evaluation with bounded outputs and reproducible provenance."""
import json
import importlib.metadata
import platform
import time
from pathlib import Path
from . import SYSTEM_PROMPT, render_messages
from .data import digest, read
from .provenance import adapter_hashes, resolve_model, load_local_snapshot


def run(args):
    if not 1 <= args.max_tokens <= 1024:
        raise ValueError('max tokens must be between 1 and 1024')
    snapshot, files = resolve_model(args.base, args.base_revision)
    import mlx.core as mx
    from mlx_lm import stream_generate
    from mlx_lm.sample_utils import make_sampler
    model, tok = load_local_snapshot(snapshot, args.adapter)
    rows = read(args.data)
    if not rows or any(not isinstance(r, dict) or not isinstance(r.get('id'), str) for r in rows) or len({r['id'] for r in rows}) != len(rows):
        raise ValueError('evaluation needs nonempty rows with unique ids')
    meta = {'base': args.base, 'base_revision': args.base_revision, 'snapshot_files_sha256': files, 'adapter_sha256': adapter_hashes(args.adapter), 'data_sha256': digest(args.data), 'system_prompt': SYSTEM_PROMPT, 'max_tokens': args.max_tokens, 'temperature': 0,
            'python': platform.python_version(), 'mlx': importlib.metadata.version('mlx'),
            'mlx_lm': importlib.metadata.version('mlx-lm'),
            'transformers': importlib.metadata.version('transformers'),
            'timing_scope': 'one pass after model load; no shared prompt cache; includes first request',
            'runner_files_sha256': {p.name: digest(p) for p in sorted(Path(__file__).parent.glob('*.py'))}}
    started = time.perf_counter()
    with open(args.out, 'x') as out:
        for row in rows:
            prompt = tok.apply_chat_template(render_messages(row), tokenize=False, add_generation_prompt=True, enable_thinking=False)
            before = time.perf_counter()
            parts = []
            final = None
            for response in stream_generate(model, tok, prompt=prompt, max_tokens=args.max_tokens, sampler=make_sampler(temp=0)):
                parts.append(response.text)
                final = response
            if final is None:
                raise RuntimeError('generation returned no completion metadata')
            out.write(json.dumps({'id': row['id'], 'answer': ''.join(parts),
                'seconds': round(time.perf_counter() - before, 4),
                'finish_reason': final.finish_reason, 'prompt_tokens': final.prompt_tokens,
                'generation_tokens': final.generation_tokens}, ensure_ascii=False) + '\n')
    meta.update({'elapsed_seconds': round(time.perf_counter() - started, 4), 'peak_memory_bytes': mx.get_peak_memory(), 'predictions_sha256': digest(args.out)})
    Path(args.out + '.meta.json').write_text(json.dumps(meta, indent=2) + '\n')
