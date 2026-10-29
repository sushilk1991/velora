"""LFM3-VL-2B (mlx-vlm main) on the 27 cleanup cases, text only.

Usage (venvB):  python vl_eval.py <label> <model> <out.jsonl> <sampler>

sampler: greedy (Velora's setting) or card (temperature 0.1, top_k 50,
repetition penalty 1.1 from generation_config.json). Thinking off in both:
Velora cannot afford a reasoning pass per dictation.
"""
import json
import sys
import time

import mlx.core as mx
from mlx_vlm import load
from mlx_vlm.generate import stream_generate

import ftlib

label, model_path, out_path, sampler = sys.argv[1:5]
SAMPLERS = {
    "greedy": {"temperature": 0.0},
    "card": {"temperature": 0.1, "top_k": 50, "repetition_penalty": 1.1},
}

mx.set_cache_limit(1 << 30)
model, processor = load(model_path)
tok = processor.tokenizer if hasattr(processor, "tokenizer") else processor
bench, items = ftlib.bench_items()

with open(out_path, "w") as f:
    for item in items:
        prompt = tok.apply_chat_template(item["messages"], add_generation_prompt=True,
                                         enable_thinking=False, tokenize=False)
        budget = max(ftlib.MIN_MAX_TOKENS, int(len(tok.encode(item["raw"])) *
                     (ftlib.OUTPUT_TOKEN_FACTOR if item["check_ratio"] else 3.0)))
        mx.random.seed(0)
        started = time.perf_counter()
        pieces, last, first = [], None, None
        for result in stream_generate(model, processor, prompt, max_tokens=budget,
                                      **SAMPLERS[sampler]):
            if first is None:
                first = time.perf_counter()
            pieces.append(result.text)
            last = result
        wall = (time.perf_counter() - started) * 1000
        status = "length" if last.generation_tokens >= budget and last.finish_reason != "stop" else "ok"
        text = "".join(pieces)
        applied, reason, output = ftlib.accept(item, text, status)
        failures = sorted(bench.validate(item["case"], output, applied))
        f.write(json.dumps({
            "set": "bench", "name": item["name"], "model": label, "sampler": sampler,
            "status": status, "finish_reason": last.finish_reason, "applied": applied,
            "reason": reason, "raw_answer": text, "output": output, "failures": failures,
            "prompt_tokens": last.prompt_tokens, "answer_tokens": last.generation_tokens,
            "ttft_ms": round((first - started) * 1000, 1), "wall_ms": round(wall, 1),
        }, ensure_ascii=False) + "\n")
        f.flush()
        print(f"{item['name']} {wall:.0f}ms {'FAIL ' + ','.join(failures) if failures else 'ok'}"
              f" ({reason or status})", flush=True)
        mx.clear_cache()
