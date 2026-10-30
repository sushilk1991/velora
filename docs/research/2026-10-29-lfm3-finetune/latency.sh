#!/bin/sh
# Bracketed latency on the 27 bench cases: A B C C B A, one process per pass,
# so each pair of passes spans the same stretch of machine load. Quality rows
# from these passes are not used; only wall_ms / ttft_ms / answer_tokens.
#
#   A = shipped 4B-8bit   B = shipped small tier, Qwen 2B-4bit
#   C = LFM3-8bit with the run-1 LoRA (2 epochs) fused in, greedy like A and B
set -e
S=$(cd "$(dirname "$0")" && pwd)
PY=$S/venvA/bin/python
A=${QWEN4B:?set QWEN4B to the pinned Qwen3.5-4B-8bit snapshot dir}
B=$(ls -d ~/.cache/huggingface/hub/models--mlx-community--Qwen3.5-2B-MLX-4bit/snapshots/*)
C=$S/runs/fused-lfm3-8bit-r1
LOCK=/tmp/velora-bench.lock
mkdir "$LOCK" 2>/dev/null || { echo "bench lock held by another run"; exit 1; }
trap 'rmdir "$LOCK"' EXIT
mkdir -p "$S/runs/latency"
cd "$S"
pass=0
for arm in A B C C B A; do
  pass=$((pass + 1))
  eval model=\$$arm
  echo "pass $pass arm $arm load1 $(sysctl -n vm.loadavg | awk '{print $2}')"
  $PY evalrun.py "lat-$arm-$pass" "$model" "runs/latency/$pass-$arm.jsonl" bench < /dev/null > "runs/latency/$pass-$arm.log" 2>&1
done
echo "latency passes done"
