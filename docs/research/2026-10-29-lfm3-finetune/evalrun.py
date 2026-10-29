"""Run one model over item sets with Velora's production prompt and guards.

Usage (venvA):
  python evalrun.py <label> <model> <out.jsonl> <set>[,<set>...] [--adapter DIR]
                    [--check-cache N]

Sets: bench (27 cleanup cases, scored by validate), train / dev (owner
takes, split by time). The teacher run over train+dev provides the labels
that train.py fits and that dev rows are compared with.

--check-cache N decodes the first N items twice, with and without the
restored system-prompt prefix, and stops if the answers differ.
"""
import argparse
import json
import random
import sys
import time

import mlx.core as mx
from mlx_lm import load

import ftlib

TRAIN_ORDER_SEED = 1028

parser = argparse.ArgumentParser()
parser.add_argument("label")
parser.add_argument("model")
parser.add_argument("out")
parser.add_argument("sets")
parser.add_argument("--adapter")
parser.add_argument("--check-cache", type=int, default=0)
parser.add_argument("--rep-penalty", type=float)
args = parser.parse_args()

mx.set_cache_limit(1 << 30)  # same 1 GB buffer cap as the earlier bakeoffs
model, tok = load(args.model, adapter_path=args.adapter)
decoder = ftlib.Greedy(model, tok, rep_penalty=args.rep_penalty)
sets = args.sets.split(",")

work = []
if "bench" in sets:
    bench, items = ftlib.bench_items()
    work += [("bench", item) for item in items]
if "synth" in sets:
    work += [("synth", item) for item in ftlib.synth_items()]
if "train" in sets or "dev" in sets:
    train, dev = ftlib.owner_items()
    print(f"owner takes: train {len(train)}, dev {len(dev)}", flush=True)
    # Dev first, then train in a seeded random order: a run stopped early
    # still holds every held-out label and a uniform sample of train takes.
    if "dev" in sets:
        work += [("dev", item) for item in dev]
    if "train" in sets:
        order = list(train)
        random.Random(TRAIN_ORDER_SEED).shuffle(order)
        work += [("train", item) for item in order]

done = set()
try:
    with open(args.out) as f:
        done = {(row["set"], row["name"]) for row in map(json.loads, f)}
except FileNotFoundError:
    pass

with open(args.out, "a") as f:
    for index, (set_name, item) in enumerate(work):
        if (set_name, item["name"]) in done:
            continue
        budget = ftlib.max_tokens(tok, item)
        text, status, stats = decoder.run(item["messages"], budget)
        if index < args.check_cache:
            # Same item without the prefix snapshot: must decode identically.
            again, _, _ = decoder.run(item["messages"], budget, reuse=False)
            if again != text:
                print(f"CACHE MISMATCH on {item['name']}", file=sys.stderr, flush=True)
                sys.exit(2)
        applied, reason, output = ftlib.accept(item, text, status)
        row = {"set": set_name, "name": item["name"], "model": args.label,
               "status": status, "applied": applied, "reason": reason,
               "raw_answer": text, "output": output, **stats,
               "mode": item["gate"].mode.name}
        if set_name == "bench":
            row["failures"] = sorted(bench.validate(item["case"], output, applied))
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
        f.flush()
        mark = ""
        if set_name == "bench":
            mark = " FAIL " + ",".join(row["failures"]) if row["failures"] else " ok"
        elif not applied:
            mark = f" rejected:{reason}"
        print(f"{time.strftime('%H:%M:%S')} {set_name} {index + 1}/{len(work)} "
              f"{item['name']} {stats['wall_ms']:.0f}ms{mark}", flush=True)
        mx.clear_cache()
