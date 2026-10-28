#!/usr/bin/env python3
"""Synthetic screen-state screenshots for d1-2B's vision path.

    python vision_set.py OUT_DIR    # renders PNGs with headless Chrome

Two screen-state decisions Velora has no detector for today (it polls AX
and waits 250 ms after a press):

    modal   is a dialog covering the window?   8 screens × {open, closed}
    loaded  has the page finished loading?     8 screens × {loaded, loading}

Each pair is the same screen with one difference, so a model that reads
the layout and not the state scores chance. Rendered at 1200×760, the size
the 2026-10-09 d1-3B probe used. Writes OUT_DIR/vision_set.jsonl.

Two variants per question. "easy" carries the loud cue: a dimming scrim
behind the dialog, a spinner on the loading page. "hard" drops it: a
macOS-style sheet hung from the title bar with nothing dimmed, and a
loading page of grey skeleton bars under a thin progress line.
"""

from __future__ import annotations

import html
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WIDTH, HEIGHT = 1200, 760

BASE_CSS = """
body{margin:0;font:14px -apple-system,Helvetica,Arial,sans-serif;background:#e9e9ee}
.win{position:absolute;inset:16px;background:#fff;border-radius:10px;box-shadow:0 8px 30px #0003;overflow:hidden}
.bar{height:38px;background:#f3f3f5;border-bottom:1px solid #ddd;display:flex;align-items:center;padding:0 12px;gap:8px}
.dot{width:12px;height:12px;border-radius:6px}
.side{position:absolute;top:38px;bottom:0;left:0;width:230px;background:#f7f7f9;border-right:1px solid #e3e3e3;padding:10px}
.row{padding:9px 10px;border-radius:6px;margin-bottom:4px;color:#222}
.sel{background:#d8e6ff}
.main{position:absolute;top:38px;left:231px;right:0;bottom:0;padding:22px}
.msg{margin:10px 0;padding:10px 14px;border-radius:12px;background:#f0f0f3;max-width:60%}
.me{background:#dcf8c6;margin-left:auto}
.scrim{position:absolute;inset:0;background:#0006}
.dialog{position:absolute;left:50%;top:44%;transform:translate(-50%,-50%);width:420px;background:#fff;border-radius:12px;
 box-shadow:0 18px 50px #0006;padding:22px}
.btn{display:inline-block;padding:7px 16px;border-radius:7px;border:1px solid #bbb;margin-right:8px;background:#f5f5f5}
.primary{background:#0a64ff;color:#fff;border-color:#0a64ff}
.skel{background:linear-gradient(90deg,#eee,#f6f6f6,#eee);border-radius:6px;height:14px;margin:10px 0}
.spinner{width:42px;height:42px;border:5px solid #ddd;border-top-color:#0a64ff;border-radius:50%;margin:120px auto}
.card{border:1px solid #e5e5e5;border-radius:10px;padding:14px;margin:10px 0}
.sheet{position:absolute;left:50%;top:38px;transform:translateX(-50%);width:440px;background:#fbfbfc;
 border:1px solid #d0d0d4;border-top:none;border-radius:0 0 10px 10px;box-shadow:0 10px 24px #0003;padding:20px}
.progress{height:3px;background:#0a64ff;width:38%}
"""

APPS = [
    ("WhatsApp", ["Priya Nair", "Shivangi Gupta", "Family", "Rahul Sharma", "Mom"],
     ["Lunch tomorrow?", "Sure, 1 pm works", "See you then!"]),
    ("Slack", ["# general", "# deploys", "# design", "Priya Sharma", "Himesh Singh"],
     ["Deploy 2.3 is green", "Thanks! Shipping the notes now", "Review moved to 4"]),
    ("Mail", ["Inbox", "Drafts", "Sent", "Receipts", "Travel"],
     ["Invoice 2026-117 from ACME", "Your flight to Delhi", "Weekly digest"]),
    ("Notes", ["All iCloud", "Recipes", "Work", "Travel", "Recently Deleted"],
     ["Groceries: eggs, apples, books", "Launch checklist", "Trip ideas"]),
]
DIALOGS = [
    ("Save changes to “Launch checklist”?", "Your changes will be lost if you don't save them.", ["Don't Save", "Cancel", "Save"]),
    ("“Velora” would like to send you notifications", "Notifications may include alerts, sounds and badges.", ["Don't Allow", "Allow"]),
    ("Sign in to continue", "Your session expired. Enter your password to keep going.", ["Cancel", "Sign In"]),
    ("Delete this conversation?", "This can't be undone.", ["Cancel", "Delete"]),
]
PAGES = [
    ("YouTube — lofi hip hop", ["lofi hip hop radio 📚 beats to relax/study to", "1 A.M Study Session 📚",
                                "Coffee shop lofi", "Rainy night jazz"]),
    ("Google — on-device speech recognition", ["On-device speech recognition - Wikipedia",
                                               "Speech recognition on Apple silicon", "Whisper vs Parakeet", "MLX audio"]),
    ("GitHub — sushilk1991/velora", ["README.md", "engine/", "Sources/Velora/", "docs/"]),
    ("Linear — My Issues", ["VEL-212 Fix the Chrome type_text path", "VEL-209 Background launch",
                            "VEL-201 YouTube play", "VEL-198 Audit rerun"]),
]


def _window(app: str, rows: list[str], messages: list[str], extra: str = "") -> str:
    side = "".join(f'<div class="row{" sel" if i == 0 else ""}">{html.escape(r)}</div>' for i, r in enumerate(rows))
    body = "".join(f'<div class="msg{" me" if i % 2 else ""}">{html.escape(m)}</div>' for i, m in enumerate(messages))
    return (f'<div class="win"><div class="bar"><span class="dot" style="background:#ff5f57"></span>'
            f'<span class="dot" style="background:#febc2e"></span><span class="dot" style="background:#28c840"></span>'
            f'<b style="margin-left:10px">{html.escape(app)}</b></div><div class="side">{side}</div>'
            f'<div class="main"><h3>{html.escape(rows[0])}</h3>{body}</div>{extra}</div>')


def _dialog(title: str, text: str, buttons: list[str], hard: bool) -> str:
    btns = "".join(f'<span class="btn{" primary" if i == len(buttons) - 1 else ""}">{html.escape(b)}</span>'
                   for i, b in enumerate(buttons))
    inner = (f'<b style="font-size:16px">{html.escape(title)}</b>'
             f'<p style="color:#555">{html.escape(text)}</p><div style="text-align:right">{btns}</div>')
    if hard:
        return f'<div class="sheet">{inner}</div>'
    return f'<div class="scrim"></div><div class="dialog">{inner}</div>'


def _page(title: str, results: list[str], loaded: bool, hard: bool) -> str:
    progress = ""
    if loaded:
        content = "".join(f'<div class="card"><b>{html.escape(r)}</b><div style="color:#666">'
                          f'example.com · 12 minutes · 2.1M views</div></div>' for r in results)
    elif hard:
        # Card outlines in place, text not yet in: what a slow page shows.
        progress = '<div class="progress"></div>'
        content = "".join('<div class="card"><div class="skel" style="width:%d%%"></div>'
                          '<div class="skel" style="width:40%%"></div></div>' % w for w in (70, 55, 80, 62))
    else:
        content = ('<div class="spinner"></div>' + "".join('<div class="skel" style="width:%d%%"></div>' % w
                                                          for w in (90, 70, 80, 60, 85, 50)))
    return (f'<div class="win"><div class="bar"><span class="dot" style="background:#ff5f57"></span>'
            f'<span class="dot" style="background:#febc2e"></span><span class="dot" style="background:#28c840"></span>'
            f'<div style="margin-left:14px;flex:1;background:#fff;border:1px solid #ddd;border-radius:6px;padding:4px 10px">'
            f'{html.escape(title)}</div></div>{progress}<div style="padding:24px 40px">'
            f'<h2>{html.escape(title.split(" — ")[-1])}</h2>{content}</div></div>')


def render(markup: str, out: Path) -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as page:
        page.write(f"<!doctype html><meta charset=utf-8><style>{BASE_CSS}</style>{markup}")
    # A throwaway profile: with the default one, headless Chrome attaches to
    # the user's running browser and never exits.
    # On this Mac headless Chrome writes the PNG and then lingers, so wait
    # for the file to land and stop growing, then end the process.
    with tempfile.TemporaryDirectory() as profile:
        chrome = subprocess.Popen(
            [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
             "--no-first-run", f"--user-data-dir={profile}",
             f"--window-size={WIDTH},{HEIGHT}", f"--screenshot={out}", f"file://{page.name}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        size, deadline = -1, time.monotonic() + 90
        while time.monotonic() < deadline:
            time.sleep(0.5)
            if chrome.poll() is not None:
                break
            if out.exists() and out.stat().st_size == size and size > 0:
                break
            size = out.stat().st_size if out.exists() else -1
        # Helpers (renderer, crashpad) outlive the main process: end the group.
        try:
            os.killpg(chrome.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        chrome.wait()
    if not out.exists():
        raise RuntimeError(f"no screenshot for {out.name}")
    Path(page.name).unlink()


def main() -> int:
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    rows = []
    # Every app meets two different dialogs across the 8 screens.
    pairs = [(APPS[i % 4], DIALOGS[(i // 4 + i) % 4]) for i in range(8)]
    for variant, offset in (("easy", 0), ("hard", 8)):
        hard = variant == "hard"
        for n, ((app, side, msgs), dialog) in enumerate(pairs, start=1 + offset):
            for state in ("open", "closed"):
                path = out / f"modal{n}_{state}.png"
                render(_window(app, side, msgs, _dialog(*dialog, hard) if state == "open" else ""), path)
                rows.append({"id": f"modal{n}_{state}", "q": "modal", "variant": variant,
                             "path": str(path), "gold": state == "open", "app": app})
        for n in range(8):
            title, results = PAGES[n % 4]
            for state in ("loaded", "loading"):
                path = out / f"page{n + 1 + offset}_{state}.png"
                shown = results if n < 4 else list(reversed(results))
                render(_page(title, shown, state == "loaded", hard), path)
                rows.append({"id": f"page{n + 1 + offset}_{state}", "q": "loaded", "variant": variant,
                             "path": str(path), "gold": state == "loaded", "app": title})
    with open(out / "vision_set.jsonl", "w") as stream:
        for row in rows:
            stream.write(json.dumps(row) + "\n")
    print(len(rows), "screens")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
