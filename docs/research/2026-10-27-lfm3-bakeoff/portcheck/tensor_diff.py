"""Dequantize Liquid's MLX-4bit tensors and compare each with the bf16
checkpoint: quantization noise is a few percent relative error; a layout
mismatch is ~100%+."""
import sys, glob
import mlx.core as mx

q = {}
for f in glob.glob(sys.argv[1] + "/*.safetensors"):
    q.update(mx.load(f))
ref = mx.load(sys.argv[2] + "/model.safetensors")
rows = []
for name, w in ref.items():
    qn = "language_model." + name
    qb = qn[:-len(".weight")] if qn.endswith(".weight") else qn
    if qb + ".scales" in q:
        deq = mx.dequantize(q[qn], q[qb + ".scales"], q[qb + ".biases"], group_size=64, bits=4)
    elif qn in q:
        deq = q[qn]
    else:
        rows.append((name, "MISSING", 0)); continue
    w32 = w.astype(mx.float32)
    deq = deq.astype(mx.float32)
    if deq.shape != w32.shape:
        if deq.ndim == 3:
            deq = deq.transpose(0, 2, 1)
        if deq.shape != w32.shape:
            rows.append((name, f"shape {deq.shape} vs {w32.shape}", 0)); continue
    rel = float(mx.linalg.norm((deq - w32).reshape(-1)) / (mx.linalg.norm(w32.reshape(-1)) + 1e-12))
    rows.append((name, "q4" if qb + ".scales" in q else "raw", rel))
extra = [k for k in q if not k.endswith((".scales", ".biases")) and k.replace("language_model.", "", 1) not in ref]
print("extra tensors in 4bit:", extra[:5])
import collections
by = collections.defaultdict(list)
for n, kind, rel in rows:
    key = (kind, n.split(".")[-2] if "layers" in n else n)
    by[key].append(rel)
for (kind, k), v in sorted(by.items()):
    print(f"{kind:5} {k:28} n={len(v):3} rel_err mean={sum(v)/len(v):.4f} max={max(v):.4f}")
