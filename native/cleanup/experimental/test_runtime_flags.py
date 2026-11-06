"""CPU-only argument checks. Every accepted flag stops before backend init."""
import argparse
import json
import subprocess

p = argparse.ArgumentParser()
p.add_argument("binary")
a = p.parse_args()


def error(*flags):
    process = subprocess.run(
        [a.binary, "/definitely/missing/velora.gguf", "0" * 64,
         "99", "4096", "8192", *flags],
        capture_output=True, text=True, timeout=10,
    )
    assert process.returncode != 0
    return json.loads(process.stdout.splitlines()[-1])["error"]


for flags in [
    ["--direct-argmax"], ["--backend-sampling"], ["--trace-runtime"],
    ["--backend-sampling", "--backend-token-only"],
    ["--copy-draft", "--recurrent-rollback", "--draft-max=8"],
    ["--copy-draft", "--draft-max=1"],
    ["--copy-draft", "--recurrent-rollback", "--backend-sampling", "--trace-runtime"],
]:
    assert error(*flags) == "local model file missing", flags

for flags, expected in [
    (["--draft-max=0"], "draft-max must be 1..8"),
    (["--draft-max=9"], "draft-max must be 1..8"),
    (["--draft-max=3x"], "draft-max must be an integer"),
    (["--draft-max="], "draft-max must be an integer"),
    (["--draft-max=-1"], "draft-max must be an integer"),
    (["--backend-sampling", "--direct-argmax"], "sampling experiments are mutually exclusive"),
    (["--backend-token-only"], "backend-token-only requires backend-sampling"),
    (["--recurrent-rollback"], "recurrent rollback requires copy-draft and draft-max >=2"),
    (["--copy-draft", "--recurrent-rollback", "--draft-max=1"],
     "recurrent rollback requires copy-draft and draft-max >=2"),
]:
    assert error(*flags) == expected, flags

print("native runtime experiment CPU checks OK (no model loaded)")
