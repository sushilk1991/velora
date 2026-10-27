"""Reference logits from Liquid's own modeling_lfm3.py (transformers 5.12.1,
trust_remote_code, fp32, CPU, eager attention)."""
import json, sys
import numpy as np
import torch
from transformers import AutoModelForCausalLM

path, ids_file, out = sys.argv[1], sys.argv[2], sys.argv[3]
model = AutoModelForCausalLM.from_pretrained(path, trust_remote_code=True, dtype=torch.float32,
                                             attn_implementation="eager").eval()
ids = json.loads(open(ids_file).read())
res = {}
with torch.no_grad():
    for name, seq in ids.items():
        x = torch.tensor([seq])
        logits = model(x).logits[0].float().numpy()
        gen = model.generate(x, max_new_tokens=24, do_sample=False, repetition_penalty=1.0, top_k=None, temperature=None)[0, len(seq):].tolist()
        np.save(f"{out}_{name}_last.npy", logits[-8:])
        res[name] = {"argmax": logits.argmax(-1).tolist(), "greedy": gen}
        print(name, len(seq), "greedy", gen[:12], flush=True)
open(f"{out}.json", "w").write(json.dumps(res))
