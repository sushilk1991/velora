"""Token ids for the port check: one short chat prompt and one real Velora
cleanup prompt (static system prompt + a transcript), long enough to cross the
256-token sliding window several times. Run in the engine venv."""
import json, sys
from pathlib import Path
from mlx_lm.tokenizer_utils import load as load_tokenizer
from velora_engine.formatting import STATIC_SYSTEM_PROMPT

tok = load_tokenizer(Path(sys.argv[1]))
short = [{"role": "user", "content": "Name three primary colours."}]
long = [{"role": "system", "content": STATIC_SYSTEM_PROMPT},
        {"role": "user", "content": "the performance issues was much worse yesterday and the "
                                    "background animations keeps running when the window is hidden"}]
ids = {name: list(tok.apply_chat_template(m, add_generation_prompt=True, enable_thinking=False))
       for name, m in (("short", short), ("long", long))}
Path(sys.argv[2]).write_text(json.dumps(ids))
print({k: len(v) for k, v in ids.items()})
