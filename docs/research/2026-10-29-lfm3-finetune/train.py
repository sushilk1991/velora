"""LoRA-distil the shipped 4B's cleanups into a small model.

Usage (venvA):
  python train.py <base model> <teacher.jsonl> <adapter dir> [--iters N]
                  [--rank R] [--lr LR]

Each example is the exact production prompt the student will see at
inference (system prompt, neutralized transcript, thinking off) followed by
the teacher's answer and the end-of-turn token. Loss covers only the answer.

  [ system prompt … user transcript … assistant header ][ teacher answer <|im_end|> ]
  └──────────────── offset (no loss) ─────────────────┘└──────── loss ─────────────┘

Only teacher answers the engine accepted (no length stop, no divergence
guard) are used: a rejected answer is not a cleanup the owner ever saw.
The same recipe (rank, scale, every layer, lr, steps) trains every student.
"""
import argparse
import json
import time
from pathlib import Path

import mlx.core as mx
import mlx.optimizers as optim
from mlx_lm import load
from mlx_lm.tuner.trainer import TrainingArgs, train
from mlx_lm.tuner.utils import linear_to_lora_layers

import ftlib

MAX_SEQ = 4096
SCALE = 20.0  # mlx-lm's default LoRA scale
WARMUP = 20
SYNTH_REPEAT = 2  # hand-written coverage items, seen twice per epoch

parser = argparse.ArgumentParser()
parser.add_argument("base")
parser.add_argument("teacher")
parser.add_argument("out")
parser.add_argument("--iters", type=int, default=0, help="0 = two epochs")
parser.add_argument("--rank", type=int, default=16)
parser.add_argument("--lr", type=float, default=1e-4)
parser.add_argument("--grad-accum", type=int, default=4)
parser.add_argument("--epochs", type=int, default=2)
parser.add_argument("--val-batches", type=int, default=0, help="0 = every dev example")
args = parser.parse_args()

mx.set_cache_limit(1 << 30)
model, tok = load(args.base)
end_of_turn = tok.convert_tokens_to_ids("<|im_end|>")
assert end_of_turn in tok.eos_token_ids, (end_of_turn, tok.eos_token_ids)

labels = {}
with open(args.teacher) as f:
    for row in map(json.loads, f):
        if row["applied"] and row["status"] == "ok":
            labels[(row["set"], row["name"])] = row["raw_answer"]

train_items, dev_items = ftlib.owner_items()


def examples(items, set_name):
    out = []
    for item in items:
        answer = labels.get((set_name, item["name"]))
        if answer is None:
            continue
        prompt = tok.apply_chat_template(item["messages"], add_generation_prompt=True,
                                         enable_thinking=False)
        tokens = prompt + tok.encode(answer, add_special_tokens=False) + [end_of_turn]
        if len(tokens) > MAX_SEQ:
            continue
        out.append((tokens, len(prompt)))
    return out


train_set = examples(train_items, "train") + examples(ftlib.synth_items(), "synth") * SYNTH_REPEAT
dev_set = examples(dev_items, "dev")
print(f"examples: train {len(train_set)}, dev {len(dev_set)}", flush=True)

model.freeze()
num_layers = len(model.layers)
lora = {"rank": args.rank, "scale": SCALE, "dropout": 0.0}
linear_to_lora_layers(model, num_layers, lora)
trainable = sum(v.size for _, v in __import__("mlx.utils", fromlist=["x"]).tree_flatten(
    model.trainable_parameters()))
print(f"trainable parameters: {trainable / 1e6:.2f} M over {num_layers} layers", flush=True)

out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)
(out / "adapter_config.json").write_text(json.dumps({
    "fine_tune_type": "lora", "num_layers": num_layers, "lora_parameters": lora,
    "base": args.base, "teacher": args.teacher, "lr": args.lr, "grad_accum": args.grad_accum,
}, indent=2))

iters = args.iters or args.epochs * len(train_set)
schedule = optim.join_schedules(
    [optim.linear_schedule(1e-7, args.lr, WARMUP),
     optim.cosine_decay(args.lr, max(1, iters // args.grad_accum - WARMUP), 1e-6)],
    [WARMUP])
optimizer = optim.Adam(learning_rate=schedule)

started = time.perf_counter()
train(model, optimizer, train_set, dev_set, args=TrainingArgs(
    batch_size=1, iters=iters, val_batches=args.val_batches or len(dev_set), steps_per_report=25,
    steps_per_eval=max(100, iters // 4), steps_per_save=max(100, iters // 4),
    max_seq_length=MAX_SEQ, adapter_file=str(out / "adapters.safetensors"),
    grad_checkpoint=True, grad_accumulation_steps=args.grad_accum))
print(f"trained {iters} iters in {(time.perf_counter() - started) / 60:.1f} min", flush=True)
