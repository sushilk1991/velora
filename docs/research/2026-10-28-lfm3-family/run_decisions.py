#!/usr/bin/env python3
"""Score one model arm on the study's decision items; one JSON line per item.

    # Qwen (engine venv: mlx-lm 0.31.3, the shipping runtime)
    python run_decisions.py letters  MODEL_PATH ITEMS.jsonl OUT.jsonl
    # d1 (mlx-vlm venv at 29e033aeec)
    python run_decisions.py native   MODEL_PATH ITEMS.jsonl OUT.jsonl
    python run_decisions.py d1-letters MODEL_PATH ITEMS.jsonl OUT.jsonl

Arms:

    letters     Velora's production readout: DECISION_SYSTEM_PROMPT + STATE +
                lettered options, thinking off, one forward pass, the option
                letters' log-probabilities renormalised (decisions.py).
    d1-letters  The same prompt and readout through d1's causal LM head: what
                swapping the model under today's engine code would give.
    native      d1's own interface: `system_one(state, {q: typed question})`
                with its set attention, answer slots and calibration.json.

Every row records the 1-minute load average and MLX active/peak memory at
the time it ran, so a latency number never travels without its machine
state. Item order is fixed; the first item is run once more untimed to warm
kernels.
"""

from __future__ import annotations

import json
import os
import sys
import time

LETTERS = tuple("ABCDEFGHIJKLMNOPQRSTUVWXYZ")


def _softmax_letters(logprobs: list[float]) -> tuple[list[float], float]:
    """Renormalised option probabilities and the raw letter mass."""
    import math

    peak = max(logprobs)
    weights = [math.exp(value - peak) for value in logprobs]
    total = sum(weights)
    return [w / total for w in weights], min(1.0, math.exp(peak) * total)


def letters_arm(model_path: str):
    """Qwen (mlx-lm) or any mlx-lm model: production letter logits."""
    import mlx.core as mx
    from mlx_lm import load

    model, tokenizer = load(model_path)
    letter_ids = [tokenizer.encode(label)[0] for label in LETTERS]
    assert all(len(tokenizer.encode(label)) == 1 for label in LETTERS)

    def score(item):
        messages = [{"role": "system", "content": item["system"]},
                    {"role": "user", "content": item["user"]}]
        ids = tokenizer.apply_chat_template(messages, add_generation_prompt=True,
                                            enable_thinking=False)
        logits = model(mx.array(ids)[None])[0, -1].astype(mx.float32)
        logprobs = logits - mx.logsumexp(logits)
        n = len(item["question"]["options"])
        picked = logprobs[mx.array(letter_ids[:n])]
        top = mx.argmax(logprobs)
        mx.eval(picked, top)
        probs, mass = _softmax_letters(picked.tolist())
        return probs, mass, len(ids), tokenizer.decode([int(top)])

    return score, mx


def d1_letters_arm(model_path: str):
    """d1 through its causal LM head with Velora's prompt."""
    import mlx.core as mx
    from mlx_vlm import load

    model, processor = load(model_path)
    tokenizer = processor.tokenizer
    letter_ids = [tokenizer.encode(label, add_special_tokens=False)[0] for label in LETTERS]
    assert all(len(tokenizer.encode(label, add_special_tokens=False)) == 1 for label in LETTERS)

    def score(item):
        messages = [{"role": "system", "content": item["system"]},
                    {"role": "user", "content": item["user"]}]
        ids = tokenizer.apply_chat_template(messages, add_generation_prompt=True,
                                            enable_thinking=False, tokenize=True)
        if not isinstance(ids, list):  # transformers 5 returns a BatchEncoding
            ids = list(ids["input_ids"])
        out = model.language_model(mx.array(ids)[None])
        logits = out.logits[0, -1].astype(mx.float32)
        logprobs = logits - mx.logsumexp(logits)
        n = len(item["question"]["options"])
        picked = logprobs[mx.array(letter_ids[:n])]
        top = mx.argmax(logprobs)
        mx.eval(picked, top)
        probs, mass = _softmax_letters(picked.tolist())
        return probs, mass, len(ids), tokenizer.decode([int(top)])

    return score, mx


def native_arm(model_path: str):
    """d1's system_one with the item's typed question."""
    import mlx.core as mx
    from mlx_vlm import load

    model, _processor = load(model_path)

    def score(item):
        keys = [key for key, _ in item["question"]["options"]]
        out = model.system_one(item["state"], {"q": item["d1"]})
        answer = out["answers"]["q"]
        if item["d1"]["type"] == "noul":
            p_yes = float(answer["noul"])
            # true/false and no/yes pairs: map P(yes) onto the option keys.
            probs = [p_yes, 1 - p_yes] if keys == ["true", "false"] else [1 - p_yes, p_yes]
        else:
            table = answer["probabilities"]
            probs = [float(table[key]) for key in keys]
        return probs, 1.0, int(out["usage"]["input_tokens"]), ""

    return score, mx


ARMS = {"letters": letters_arm, "d1-letters": d1_letters_arm, "native": native_arm}


def main() -> int:
    arm, model_path, items_path, out_path = sys.argv[1:5]
    only = set(sys.argv[5].split(",")) if len(sys.argv) > 5 else None
    items = [json.loads(line) for line in open(items_path)]
    if only:
        items = [item for item in items if item["set"] in only]

    started = time.perf_counter()
    score, mx = ARMS[arm](model_path)
    load_ms = (time.perf_counter() - started) * 1000
    score(items[0])  # warm-up: kernel compilation is not decision latency

    with open(out_path, "w") as stream:
        for item in items:
            keys = [key for key, _ in item["question"]["options"]]
            t0 = time.perf_counter()
            probs, mass, tokens, top = score(item)
            ms = (time.perf_counter() - t0) * 1000
            best = max(range(len(keys)), key=probs.__getitem__)
            stream.write(json.dumps({
                "event": "item", "arm": arm, "model": model_path, "set": item["set"],
                "id": item["id"], "cat": item["cat"], "gold": item["gold"],
                "pred": keys[best], "conf": round(probs[best], 6),
                "p_gold": round(probs[keys.index(item["gold"])], 6),
                "probs": dict(zip(keys, (round(p, 6) for p in probs))),
                "label_mass": round(mass, 6), "top_token": top, "tokens": tokens,
                "ms": round(ms, 1), "load1": round(os.getloadavg()[0], 2),
                "mlx_active": int(mx.get_active_memory()),
            }, ensure_ascii=False) + "\n")
            stream.flush()
        stream.write(json.dumps({
            "event": "memory", "arm": arm, "model": model_path, "load_ms": round(load_ms),
            "peak_bytes": int(mx.get_peak_memory()), "active_bytes": int(mx.get_active_memory()),
            "load1": round(os.getloadavg()[0], 2),
        }) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
