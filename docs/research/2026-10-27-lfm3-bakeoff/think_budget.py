"""LFM3 with no, minimal, and full thinking on Velora's three jobs.

LFM3's template has only enable_thinking on/off, so "minimal thinking" is a
reasoning budget: think up to B tokens, force </think> if still open, then
answer. Greedy throughout (Velora decodes at temperature 0).

    off   : enable_thinking=False -> prompt ends "<think></think>"
    bN    : enable_thinking=True, reasoning capped at N tokens
    full  : enable_thinking=True, reasoning capped at FULL_CAP (reported)

  prompt ─prefill─► [<think> reasoning ≤ B ] ─force </think>─► answer ≤ budget
                     └── think_tokens/ms ──┘                   └ engine budget ┘

Jobs (offline, no engine worker):
  cleanup  : 27 cases; answer budget = engine's max(96, 1.8 x input tokens);
             scored with the engine's own guard (check_divergence), postprocess
             and the cleanup bench's validate().
  decide   : 62 decisions; letter logits read right after </think>.
  action   : the 5 Action probes (hostile screen title), 2 attempts with the
             engine's repair note; scored with the probe script's _assess().

Usage (bench venv, from engine/):
  python think_budget.py <label> <model> <job> <out.jsonl> <mode> [<mode> ...]
"""
import importlib.util
import json
import os
import sys
import tempfile
import time
from pathlib import Path

import mlx.core as mx
from mlx_lm import load
from mlx_lm.models.cache import make_prompt_cache

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(Path.cwd() / "scripts"))
os.environ["VELORA_HOME"] = tempfile.mkdtemp(prefix="velora-think-")

from velora_engine import actions  # noqa: E402
from velora_engine.cleanup import (  # noqa: E402
    MIN_MAX_TOKENS, OUTPUT_TOKEN_FACTOR, check_divergence,
    neutralize_control_tokens, restore_control_tokens,
)
from velora_engine.config import Config  # noqa: E402
from velora_engine.decisions import (  # noqa: E402
    DECISION_SYSTEM_PROMPT, OPTION_LABELS, answer_from_logprobs, decision_message,
)
from velora_engine.formatting import (  # noqa: E402
    STATIC_SYSTEM_PROMPT, encode_breaks, postprocess, run_gate,
)

FULL_CAP = 1024
PREFILL_STEP = 512

label, model_path, job, out_path = sys.argv[1:5]
modes = sys.argv[5:]
model, tok = load(model_path)
THINK_END = tok.convert_tokens_to_ids("</think>")
EOS = set(tok.eos_token_ids)


def _budget(mode: str) -> int | None:
    if mode == "off":
        return None
    return FULL_CAP if mode == "full" else int(mode[1:])


def _prefill(cache, ids):
    """Feed ids through the cache; return the logits after the last one."""
    for i in range(0, len(ids) - 1, PREFILL_STEP):
        chunk = ids[i:min(i + PREFILL_STEP, len(ids) - 1)]
        model(mx.array(chunk)[None], cache=cache)
        mx.eval([c.state for c in cache])
    logits = model(mx.array(ids[-1:])[None], cache=cache)[0, -1]
    mx.eval(logits)
    return logits


def _step(cache, token):
    logits = model(mx.array([token])[None], cache=cache)[0, -1]
    mx.eval(logits)
    return logits


def think_then(messages, mode):
    """Prefill, reason within the mode's budget, close the think block.

    Returns (cache, logits at the first answer position, stats)."""
    started = time.perf_counter()
    ids = tok.apply_chat_template(messages, add_generation_prompt=True,
                                  enable_thinking=(mode != "off"))
    cache = make_prompt_cache(model)
    logits = _prefill(cache, ids)
    stats = {"prompt_tokens": len(ids), "think_tokens": 0, "think_closed_naturally": None,
             "think_text": ""}
    budget = _budget(mode)
    if budget is not None:
        thought = []
        closed = False
        while len(thought) < budget:
            token = int(mx.argmax(logits))
            logits = _step(cache, token)
            if token == THINK_END:
                closed = True
                break
            thought.append(token)
        if not closed:
            logits = _step(cache, THINK_END)  # force the block shut
        stats.update(think_tokens=len(thought), think_closed_naturally=closed,
                     think_text=tok.decode(thought)[-400:])
    stats["think_ms"] = round((time.perf_counter() - started) * 1000, 1)
    return cache, logits, stats


def answer(cache, logits, max_tokens):
    """Greedy answer until EOS or max_tokens; mirrors the engine's 'length'."""
    out = []
    while len(out) < max_tokens:
        token = int(mx.argmax(logits))
        if token in EOS:
            return tok.decode(out), "ok"
        out.append(token)
        logits = _step(cache, token)
    return tok.decode(out), "length"


def _load_module(path: Path, name: str, argv=None):
    saved = sys.argv
    sys.argv = argv or [str(path)]
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module  # dataclasses resolve annotations through it
        spec.loader.exec_module(module)
        return module
    finally:
        sys.argv = saved


def run_cleanup(f, mode):
    bench = _load_module(Path.cwd() / "scripts" / "benchmark_cleanup_quality.py", "bench")
    config = Config()
    for case in bench.CASES:
        config.data["romanize_output"] = case.romanize
        provisional = run_gate(case.raw, config, bundle_id=case.bundle_id,
                               app_name=case.app_name, explicit_mode=case.explicit_mode)
        mode_key = provisional.mode.name.lower()
        old = config.modes[mode_key].prompt
        if case.mode_prompt is not None:
            config.modes[mode_key].prompt = case.mode_prompt
        try:
            gate = run_gate(case.raw, config, bundle_id=case.bundle_id,
                            app_name=case.app_name, explicit_mode=case.explicit_mode)
        finally:
            config.modes[mode_key].prompt = old
        system = gate.system_prompt or STATIC_SYSTEM_PROMPT
        raw = gate.text if gate.romanize else encode_breaks(gate.text)
        check_ratio = not gate.romanize
        factor = OUTPUT_TOKEN_FACTOR if check_ratio else 3.0
        max_tokens = max(MIN_MAX_TOKENS, int(len(tok.encode(raw)) * factor))
        allowed = list(dict.fromkeys(config.global_vocabulary + gate.mode.vocabulary))

        started = time.perf_counter()
        messages = [{"role": "system", "content": system},
                    {"role": "user", "content": neutralize_control_tokens(raw)}]
        cache, logits, stats = think_then(messages, mode)
        text, status = answer(cache, logits, max_tokens)
        wall = (time.perf_counter() - started) * 1000

        # The engine's acceptance path after generation (CleanupLLM._cleanup_sync).
        text = restore_control_tokens(text)
        reason = None
        if status == "length":
            reason = "length"
        elif check_ratio:
            reason = check_divergence(raw, text, allowed)
        elif not text.strip():
            reason = "empty_output"
        applied = reason is None
        output = postprocess(text.strip(), gate) if applied else raw
        failures = sorted(bench.validate(case, output, applied))
        leak = ("<think>" in text) or ("</think>" in text)
        f.write(json.dumps({
            "job": "cleanup", "model": label, "mode": mode, "case": case.name,
            "wall_ms": round(wall, 1), "answer_ms": round(wall - stats["think_ms"], 1),
            **stats, "applied": applied, "reason": reason, "think_tag_in_answer": leak,
            "raw_answer": text, "output": output, "failures": failures,
        }, ensure_ascii=False) + "\n")
        f.flush()
        print(f"cleanup {mode} {case.name}: think={stats['think_tokens']} "
              f"{round(wall)}ms {'FAIL ' + ','.join(failures) if failures else 'ok'}", flush=True)
        mx.clear_cache()


def run_decide(f, mode):
    bench = _load_module(Path.cwd() / "scripts" / "benchmark_decisions.py", "decisions_bench")
    label_ids = [tok.encode(letter)[0] for letter in OPTION_LABELS]
    for item in bench.build_items():
        question = item["question"]
        messages = [{"role": "system", "content": DECISION_SYSTEM_PROMPT},
                    {"role": "user", "content": neutralize_control_tokens(
                        decision_message(item["state"], question))}]
        started = time.perf_counter()
        _, logits, stats = think_then(messages, mode)
        logprobs = (logits.astype(mx.float32) - mx.logsumexp(logits.astype(mx.float32)))
        picked = logprobs[mx.array(label_ids[:len(question.options)])]
        mx.eval(picked)
        result = answer_from_logprobs(question, picked.tolist())
        f.write(json.dumps({
            "job": "decide", "model": label, "mode": mode, "id": item["id"], "cat": item["cat"],
            "gold": item["gold"], "pred": result.choice, "p_gold": round(result.p(item["gold"]), 4),
            "label_mass": round(result.label_mass, 4),
            "ms": round((time.perf_counter() - started) * 1000, 1), **stats,
        }, ensure_ascii=False) + "\n")
        f.flush()
        mx.clear_cache()
    print(f"decide {mode} done", flush=True)


def run_action(f, mode):
    probes = _load_module(HERE / "action_probes.py", "action_probes", argv=["action_probes.py"])
    for case in probes.CASES:
        session = actions.ActionSession(case["command"], probes._context())
        message = session.first_message()
        last_error, accepted, attempts = "", None, []
        for attempt in range(2):
            prompt = session.system_prompt()
            if attempt:
                prompt += "\n" + actions.turn_repair_note(last_error)
            started = time.perf_counter()
            cache, logits, stats = think_then(
                [{"role": "system", "content": prompt},
                 {"role": "user", "content": neutralize_control_tokens(message)}], mode)
            text, status = answer(cache, logits, actions.PLAN_MAX_TOKENS)
            record = {"attempt": attempt + 1, "status": status,
                      "wall_ms": round((time.perf_counter() - started) * 1000, 1),
                      "think_tokens": stats["think_tokens"], "reply": text}
            attempts.append(record)
            if status != "ok":
                last_error = f"model unavailable ({status})"
                continue
            try:
                accepted = session.accept_reply(text.strip())
                break
            except actions.PlanError as exc:
                last_error = str(exc)
                record["validation_error"] = last_error
        failures = ([f"plan_not_accepted:{last_error}"] if accepted is None
                    else probes._assess(case["expect"], session, accepted, attempts[-1]["reply"]))
        f.write(json.dumps({
            "job": "action", "model": label, "mode": mode, "case": case["name"],
            "attempts": attempts, "accepted_turn": accepted, "sends": session.sends,
            "failures": failures,
        }, ensure_ascii=False) + "\n")
        f.flush()
        print(f"action {mode} {case['name']}: {'FAIL ' + ','.join(failures) if failures else 'ok'}",
              flush=True)
        mx.clear_cache()


JOBS = {"cleanup": run_cleanup, "decide": run_decide, "action": run_action}
with open(out_path, "a") as f:
    for mode in modes:
        JOBS[job](f, mode)
print("peak GB", round(mx.get_peak_memory() / 1e9, 2))
