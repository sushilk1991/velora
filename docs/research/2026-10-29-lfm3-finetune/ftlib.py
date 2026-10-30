"""Shared pieces for the LFM3 fine-tune study: production prompts, guards, items.

Every model is judged the way the engine judges it: the gate builds the
system prompt, the model answers greedily with thinking off, then the
engine's acceptance path (length guard, check_divergence, postprocess) runs
and the cleanup bench's validate() scores the result.

  item ─run_gate─► messages ─model (greedy, no think)─► answer
                                                         │
             check_divergence / length / empty ◄─────────┘
                         │ accepted → postprocess(answer) ; rejected → raw
                         ▼
                 bench.validate(case, output, applied)   (27 bench cases)
                 agreement with the 4B teacher           (held-out owner takes)
"""
import importlib.util
import os
import sqlite3
import sys
import tempfile
import time
from pathlib import Path

ENGINE = Path(__file__).resolve().parents[3] / "engine"
sys.path.insert(0, str(ENGINE / "scripts"))
os.environ.setdefault("VELORA_HOME", tempfile.mkdtemp(prefix="velora-ft-"))

from velora_engine.cleanup import (  # noqa: E402
    MIN_MAX_TOKENS, OUTPUT_TOKEN_FACTOR, check_divergence,
    neutralize_control_tokens, restore_control_tokens,
)
from velora_engine.config import Config  # noqa: E402
from velora_engine.formatting import (  # noqa: E402
    STATIC_SYSTEM_PROMPT, encode_breaks, postprocess, run_gate,
)

HISTORY = Path.home() / ".velora" / "history.sqlite3"
DEV_FRACTION = 0.10  # newest 10% of owner takes are held out, never trained on
SKIP_MODES = {"action"}  # Action takes go to the planner, not cleanup


def load_module(path: Path, name: str):
    saved = sys.argv
    sys.argv = [str(path)]
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module  # dataclasses resolve annotations through it
        spec.loader.exec_module(module)
        return module
    finally:
        sys.argv = saved


def _prepare(config, raw, bundle_id, app_name, explicit_mode, mode_prompt=None):
    """The engine's prompt for one dictation, or None when no LLM runs."""
    provisional = run_gate(raw, config, bundle_id=bundle_id, app_name=app_name,
                           explicit_mode=explicit_mode)
    mode_key = provisional.mode.name.lower()
    old = config.modes[mode_key].prompt
    if mode_prompt is not None:
        config.modes[mode_key].prompt = mode_prompt
    try:
        gate = run_gate(raw, config, bundle_id=bundle_id, app_name=app_name,
                        explicit_mode=explicit_mode)
    finally:
        config.modes[mode_key].prompt = old
    if not gate.use_llm:
        return None
    text = gate.text if gate.romanize else encode_breaks(gate.text)
    return {
        "gate": gate,
        "raw": text,
        "check_ratio": not gate.romanize,
        "allowed": list(dict.fromkeys(config.global_vocabulary + gate.mode.vocabulary)),
        "messages": [
            {"role": "system", "content": gate.system_prompt or STATIC_SYSTEM_PROMPT},
            {"role": "user", "content": neutralize_control_tokens(text)},
        ],
    }


def bench_items():
    """The 27 cleanup bench cases with their production prompts."""
    bench = load_module(ENGINE / "scripts" / "benchmark_cleanup_quality.py", "bench")
    config = Config()
    items = []
    for case in bench.CASES:
        config.data["romanize_output"] = case.romanize
        item = _prepare(config, case.raw, case.bundle_id, case.app_name,
                        case.explicit_mode, case.mode_prompt)
        item.update(name=case.name, case=case)
        items.append(item)
    return bench, items


def owner_items():
    """Owner takes that reach the LLM, oldest first, split by time.

    Returns (train, dev). Read-only: the history database is opened with
    mode=ro so nothing here can write the owner's store."""
    db = sqlite3.connect(f"file:{HISTORY}?mode=ro", uri=True)
    rows = db.execute(
        "select id, ts, bundle_id, app_name, mode, raw from dictations "
        "where length(raw) > 0 order by ts").fetchall()
    config = Config()
    items = []
    for row_id, ts, bundle_id, app_name, mode, raw in rows:
        if (mode or "").lower() in SKIP_MODES:
            continue
        item = _prepare(config, raw, bundle_id, app_name, mode)
        if item is None:
            continue
        item.update(name=f"take-{row_id}", ts=ts)
        items.append(item)
    cut = int(len(items) * (1 - DEV_FRACTION))
    return items[:cut], items[cut:]


def synth_items():
    """Hand-written dictations that cover lists, prose and Hindi/Chinese.

    The owner's takes hold few lists (4.5% of the 4B's outputs) and almost no
    non-Latin script, while 12 of the 27 bench cases need a list. These fill
    that gap for training only; their topics avoid every bench case."""
    import json
    config = Config()
    items = []
    for index, spec in enumerate(json.loads((Path(__file__).parent / "synth.json").read_text())):
        config.data["romanize_output"] = spec.get("romanize", False)
        item = _prepare(config, spec["raw"], None, None, spec["mode"])
        if item is None:
            continue
        item.update(name=f"synth-{index}")
        items.append(item)
    config.data["romanize_output"] = False
    return items


def max_tokens(tok, item):
    factor = OUTPUT_TOKEN_FACTOR if item["check_ratio"] else 3.0
    return max(MIN_MAX_TOKENS, int(len(tok.encode(item["raw"])) * factor))


def accept(item, text, status):
    """The engine's acceptance path after generation (CleanupLLM._cleanup_sync)."""
    text = restore_control_tokens(text)
    reason = None
    if status == "length":
        reason = "length"
    elif item["check_ratio"]:
        reason = check_divergence(item["raw"], text, item["allowed"])
    elif not text.strip():
        reason = "empty_output"
    applied = reason is None
    output = postprocess(text.strip(), item["gate"]) if applied else item["raw"]
    return applied, reason, output


class Greedy:
    """Greedy decoding with thinking off and a reused system-prompt prefix.

    The system prompt is identical across takes of one mode, so its prefill is
    snapshotted once and restored per take (the engine's own snapshot helpers),
    like the engine's prompt cache."""

    PREFILL_STEP = 512

    REP_WINDOW = 20  # mlx-lm's repetition_context_size default

    def __init__(self, model, tok, rep_penalty=None):
        import mlx.core as mx
        from mlx_lm.models.cache import make_prompt_cache
        from velora_engine.cleanup import _restore_prompt_cache, _snapshot_prompt_cache
        self.mx, self.model, self.tok = mx, model, tok
        self.make = lambda: make_prompt_cache(model)
        self.snap, self.restore = _snapshot_prompt_cache, _restore_prompt_cache
        self.eos = set(tok.eos_token_ids)
        self.rep_penalty = rep_penalty
        self.prefixes = {}

    def _feed(self, cache, ids):
        mx = self.mx
        logits = None
        for start in range(0, len(ids), self.PREFILL_STEP):
            chunk = mx.array(ids[start:start + self.PREFILL_STEP])[None]
            logits = self.model(chunk, cache=cache)[:, -1, :]
            mx.eval(logits, [c.state for c in cache])
        return logits

    def ids(self, messages):
        return self.tok.apply_chat_template(messages, add_generation_prompt=True,
                                            enable_thinking=False)

    def run(self, messages, max_tokens, reuse=True):
        mx = self.mx
        started = time.perf_counter()
        ids = self.ids(messages)
        system = messages[0]["content"]
        if not reuse:
            cache = self.make()
            logits = self._feed(cache, ids)
        elif system not in self.prefixes:
            head = self.ids(messages[:1] + [{"role": "user", "content": "x"}])
            common = 0
            while common < min(len(head), len(ids)) and head[common] == ids[common]:
                common += 1
            common -= 1  # keep at least one token of the user turn to feed
            cache = self.make()
            self._feed(cache, ids[:common])
            self.prefixes[system] = (common, ids[:common], self.snap(cache))
        if reuse:
            common, prefix, snapshot = self.prefixes[system]
            if ids[:common] == prefix:
                cache = self.restore(snapshot)
                logits = self._feed(cache, ids[common:])
            else:
                cache = self.make()
                logits = self._feed(cache, ids)
        ttft = (time.perf_counter() - started) * 1000
        out = []
        status = "length"
        while len(out) < max_tokens:
            if self.rep_penalty and out:
                # mlx-lm's repetition penalty over the last REP_WINDOW generated
                # tokens: copying transcript words stays free, loops do not.
                recent = mx.array(sorted(set(out[-self.REP_WINDOW:])))
                picked = logits[:, recent]
                picked = mx.where(picked < 0, picked * self.rep_penalty,
                                  picked / self.rep_penalty)
                logits[:, recent] = picked
            token = int(mx.argmax(logits, axis=-1).item())
            if token in self.eos:
                status = "ok"
                break
            out.append(token)
            logits = self.model(mx.array([[token]]), cache=cache)[:, -1, :]
        wall = (time.perf_counter() - started) * 1000
        return self.tok.decode(out), status, {
            "prompt_tokens": len(ids), "answer_tokens": len(out),
            "ttft_ms": round(ttft, 1), "wall_ms": round(wall, 1)}
