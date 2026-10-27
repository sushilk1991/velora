"""Same ids through the MLX port (bf16 checkpoint cast to fp32): full forward,
chunked prefill through the cache, and greedy decode; compare with torch."""
import json, sys
import numpy as np
import mlx.core as mx
from mlx_lm import load
from mlx_lm.models.cache import make_prompt_cache

path, ids_file, ref = sys.argv[1], sys.argv[2], sys.argv[3]
model, tok = load(path)
if len(sys.argv) > 4 and sys.argv[4] == "fp32":
    model.set_dtype(mx.float32)
ids = json.loads(open(ids_file).read())
refj = json.loads(open(f"{ref}.json").read())
for name, seq in ids.items():
    full = model(mx.array(seq)[None])[0].astype(mx.float32)
    # Chunked prefill (64-token steps) through the cache, then the last token.
    cache = make_prompt_cache(model)
    for i in range(0, len(seq) - 1, 64):
        model(mx.array(seq[i:min(i + 64, len(seq) - 1)])[None], cache=cache)
    cached_last = model(mx.array(seq[-1:])[None], cache=cache)[0, -1].astype(mx.float32)
    # Greedy decode from the cache.
    out, nxt = [], int(mx.argmax(cached_last))
    for _ in range(24):
        out.append(nxt)
        nxt = int(mx.argmax(model(mx.array([nxt])[None], cache=cache)[0, -1]))
    r_last = np.load(f"{ref}_{name}_last.npy")
    m_last = np.array(full[-8:])
    agree = float(np.mean(np.array(full.argmax(-1)) == np.array(refj[name]["argmax"])))
    print(json.dumps({
        "prompt": name, "tokens": len(seq),
        "max_abs_logit_diff_last8": float(np.abs(m_last - r_last).max()),
        "logit_scale_last8": float(np.abs(r_last).max()),
        "argmax_agreement_all_positions": round(agree, 4),
        "cache_vs_full_max_diff": float(mx.abs(cached_last - full[-1]).max()),
        "greedy_match_tokens": sum(a == b for a, b in zip(out, refj[name]["greedy"])),
        "greedy_mlx": tok.decode(out), "greedy_ref": tok.decode(refj[name]["greedy"]),
    }, ensure_ascii=False))
