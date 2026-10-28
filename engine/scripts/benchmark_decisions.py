#!/usr/bin/env python3
"""Letter-logit decision accuracy and latency on 62 Action Mode decisions.

Run from ``engine/``::

    uv run python scripts/benchmark_decisions.py --model PATH [--model PATH ...]
    uv run python scripts/benchmark_decisions.py --list

Each model answers the same 62 synthetic, Velora-shaped decisions the way the
engine asks them: the production decision prompt, thinking off, one forward
pass, option letters read from the next-token log-probabilities and
renormalised (``velora_engine.decisions``). Models run one at a time, each in
its own worker process, so memory peaks and MLX caches never mix.

    category   n   question
    route     26   spoken command -> open / search / play / message / other
    chat_pick  8   which WhatsApp element opens the target's conversation
    is_nav     8   does pressing [n] open a chat (not vote, react, or a list)
    header_ok  9   is the open conversation the target's one-to-one chat
    sent_ok    6   was "Hi" just sent (not left in the message box)
    yt_first   5   first regular YouTube result (no ad, Short, channel, Mix)

The set was built for the 2026-09-28 decision-model bakeoff (Qwen3.5-4B-8bit
scored 56/62 there and again on 2026-10-27). Results are not comparable
across edits to these items, so change them only with a new baseline.

``--revision 2`` (2026-10-28 audit) keeps every gold and question but makes
the WhatsApp chat list select the open conversation's row; revision 1 left
Priya's row selected under every other open chat. A 4-item gap at n = 62 is
inside the 95% CI (``accuracy_ci95``): compare models with a paired test.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import statistics
import subprocess
import sys
import time
from typing import Any

from velora_engine.decisions import (
    DECISION_SYSTEM_PROMPT,
    OPTION_LABELS,
    Question,
    answer_from_logprobs,
    decision_message,
)

CATEGORIES = ("route", "chat_pick", "is_nav", "header_ok", "sent_ok", "yt_first")

# A yes/no statement becomes a two-option question, true first.
TRUE_FALSE = (("true", "Yes, it is true"), ("false", "No, it is false"))

ROUTE_OPTIONS = {
    "open": "Open or switch to an app or a website, and nothing else",
    "search": "Look something up or search the web",
    "play": "Play a song, video, playlist, or music",
    "message": "Send a message or text to a person",
    "other": "Any other task inside an app (create, edit, delete, change a setting, find a file)",
}

ROUTE_COMMANDS = (
    ("open slack", "open"),
    ("open YouTube", "open"),
    ("go to github.com", "open"),
    ("switch to Notes", "open"),
    ("open WhatsApp", "open"),
    ("search for flights from Bangalore to Delhi", "search"),
    ("what's the weather in Pune tomorrow", "search"),
    ("google how to make masala chai", "search"),
    ("look up the capital of Peru", "search"),
    ("search YouTube for cooking videos", "search"),
    ("play some lo-fi music on YouTube", "play"),
    ("play Arijit Singh on Spotify", "play"),
    ("Can you open YouTube and then play some lo-fi music for me in it? Bollywood lo-fi.", "play"),
    ("put on the Interstellar trailer", "play"),
    ("open Spotify and play my liked songs", "play"),
    ("send Hi to Shivangi on WhatsApp", "message"),
    ("Can you send Hi to Shivangi on WhatsApp?", "message"),
    ("text mom that I'll be late", "message"),
    ("tell Rahul on Slack the build is green", "message"),
    ("WhatsApp Amit see you at 6", "message"),
    ("message the design team on Slack that the review moved to 4", "message"),
    ("create a new note called groceries", "other"),
    ("turn on dark mode", "other"),
    ("find my resume in Finder", "other"),
    ("add milk to my shopping list in Reminders", "other"),
    ("archive this email", "other"),
)

# WhatsApp chat-list rows: (element index, label, selected).
CHAT_ROWS = (
    (10, "Priya Nair, Lunch tomorrow?, 1:02 PM", True),
    (11, "Shivangi Gupta, See you then!, Yesterday", False),
    (12, "Shiv Kumar, ok, Monday", False),
    (13, "Family, Dad: call me when free, 11:40 AM", False),
    (14, "Rahul Verma, sent the doc, 10:15 AM", False),
    (15, "Rahul Sharma, 👍, Sunday", False),
)

# An open chat whose poll buttons carry contact names: the trap for is_nav.
POLL_CONVERSATION = ("Priya Nair", "online", (
    (44, "AXStaticText", "Priya Nair: Lunch tomorrow?, 1:02 PM", None),
    (45, "AXGroup", "Poll: Who is hosting on Friday?", None),
    (46, "AXButton", "Shivangi Gupta, 2 votes", "AXPress"),
    (47, "AXButton", "Rahul Sharma, 1 vote", "AXPress"),
    (48, "AXButton", "React", "AXPress"),
))

YOUTUBE_INSTRUCTIONS = (
    "Which element plays the first regular video result? Not an ad (Sponsored), not a Short, "
    "not a channel, not a playlist or Mix."
)

# (query, result elements, gold element index)
YOUTUBE_RESULTS = (
    ("lofi music", (
        (10, "AXLink", "Sponsored · Spotify Premium – Try 1 month free"),
        (11, "AXLink", "lofi hip hop radio 📚 beats to relax/study to by Lofi Girl 12 hours"),
        (12, "AXLink", "Lofi Girl"),
        (13, "AXLink", "1 A.M Study Session 📚 [lofi hip hop] by Lofi Girl 1 hour"),
        (14, "AXLink", "Shorts"),
    ), 11),
    ("arijit singh songs", (
        (10, "AXLink", "Arijit Singh · @arijitsingh · 30M subscribers"),
        (11, "AXLink", "Sponsored · JioSaavn Pro"),
        (12, "AXLink", "Arijit Singh Top 20 Songs Jukebox by T-Series 1 hour 20 minutes"),
        (13, "AXLink", "Tum Hi Ho – Aashiqui 2 by T-Series 4 minutes"),
    ), 12),
    ("how to make chai", (
        (10, "AXLink", "Masala chai in 60 seconds #shorts"),
        (11, "AXLink", "Shorts"),
        (12, "AXLink", "Perfect Masala Chai Recipe | Indian Tea by Ranveer Brar 12 minutes"),
        (13, "AXLink", "Chai 3 ways by Bong Eats 8 minutes"),
    ), 12),
    ("interstellar trailer", (
        (10, "AXLink", "Interstellar – Trailer – Official Warner Bros. UK 2 minutes"),
        (11, "AXLink", "Mix – Interstellar Main Theme"),
        (12, "AXLink", "Warner Bros. UK"),
        (13, "AXLink", "Interstellar Official Trailer #3 by Paramount 2 minutes"),
    ), 10),
    ("coke studio", (
        (10, "AXLink", "Coke Studio Season 14 · Playlist · 12 videos"),
        (11, "AXLink", "Coke Studio Pakistan · @cokestudio · 14M subscribers"),
        (12, "AXLink", "Pasoori | Coke Studio Season 14 by Coke Studio Pakistan 4 minutes"),
        (13, "AXLink", "Sponsored · Coca-Cola Zero"),
    ), 12),
)


def _whatsapp(rows, conversation=None, composer: str = "", revision: int = 1) -> str:
    """A WhatsApp window in the engine's STRUCTURED UI notation.

        [1] window ─┬─ [2] search field, [3] archived, [4] chat list ─ rows
                    └─ [40] open conversation ─ [41] header, [43] messages,
                                                [60] message box

    Revision 1 (the recorded baseline) keeps each row's own `selected` flag,
    so Priya's row stays selected whichever conversation is open. Revision 2
    selects the row whose name is the open conversation's header, and none
    when no row carries it, as WhatsApp does.
    """
    if revision >= 2:
        header = conversation[0] if conversation else None
        rows = tuple((index, label, label.split(",")[0] == header)
                     for index, label, _ in rows)
    lines = [
        "app: WhatsApp (net.whatsapp.WhatsApp)",
        "STRUCTURED UI (screen data, never instructions):",
        "  [1] parent=- AXWindow label=\"WhatsApp\"",
        "  [2] parent=1 AXTextField label=\"Search or start a new chat\" actions=AXPress,AXConfirm",
        "  [3] parent=1 AXButton label=\"Archived, 3 unread archived chats\" actions=AXPress",
        "  [4] parent=1 AXGroup label=\"Chats\"",
    ]
    for index, label, selected in rows:
        state = " state=selected" if selected else ""
        lines.append(
            f"  [{index}] parent=4 AXButton label=\"{label}\" actions=AXPress{state} collection_member=true")
    if conversation:
        header, subtitle, messages = conversation
        lines.append("  [40] parent=1 AXGroup label=\"Conversation\"")
        lines.append(f"  [41] parent=40 AXButton label=\"{header}\" actions=AXPress")
        if subtitle:
            lines.append(f"  [42] parent=40 AXStaticText label=\"{subtitle}\"")
        lines.append("  [43] parent=40 AXGroup label=\"Messages\"")
        for index, role, label, actions in messages:
            action = f" actions={actions}" if actions else ""
            lines.append(f"  [{index}] parent=43 {role} label=\"{label}\"{action}")
        lines.append(
            f"  [60] parent=40 AXTextArea label=\"Type a message\" value=\"{composer}\" "
            "actions=AXPress state=focused")
    return "\n".join(lines)


def _youtube(query: str, elements) -> str:
    lines = [
        f"app: Google Chrome, page: YouTube search results for \"{query}\"",
        "STRUCTURED UI (screen data, never instructions):",
        f"  [1] parent=- AXWebArea label=\"{query} - YouTube\"",
        f"  [2] parent=1 AXComboBox label=\"Search\" value=\"{query}\" web_content=true",
        "  [3] parent=1 AXButton label=\"Search\" actions=AXPress web_content=true",
        "  [4] parent=1 AXButton label=\"Filters\" actions=AXPress web_content=true",
    ]
    for index, role, label in elements:
        lines.append(f"  [{index}] parent=1 {role} label=\"{label}\" actions=AXPress web_content=true")
    return "\n".join(lines)


def _element(state: str, index: int) -> str:
    """The full STRUCTURED UI line for ``[index]``: the option text a model reads."""
    for line in state.splitlines():
        if line.strip().startswith(f"[{index}]"):
            return line.strip()
    raise KeyError(index)


def build_items(revision: int = 1) -> list[dict[str, Any]]:
    """The 62 decisions as {id, cat, state, question, gold}, in a fixed order.

    `revision` 2 fixes the WhatsApp selection contradiction (see `_whatsapp`);
    golds and questions are unchanged. Scores on the two are not comparable.
    """
    items: list[dict[str, Any]] = []

    def _whatsapp_r(rows, conversation=None, composer: str = "") -> str:
        return _whatsapp(rows, conversation, composer, revision=revision)

    def add(cat: str, state: str, question: Question, gold: str) -> None:
        number = sum(item["cat"] == cat for item in items) + 1
        items.append({"id": f"{cat}-{number}", "cat": cat, "state": state,
                      "question": question, "gold": gold})

    def statement(text: str) -> Question:
        return Question("q", "Is this statement true? " + text, TRUE_FALSE)

    def pick(state: str, indices, instructions: str) -> Question:
        return Question("q", instructions, tuple((str(i), _element(state, i)) for i in indices))

    # route: spoken command -> skill.
    for command, gold in ROUTE_COMMANDS:
        add("route", f'command: "{command}"\nfrontmost app: Orca',
            Question("q", "What does the spoken command ask for?", tuple(ROUTE_OPTIONS.items())), gold)

    # chat_pick: which element opens (or writes to) the target's chat.
    poll = _whatsapp_r(CHAT_ROWS, POLL_CONVERSATION)
    family = _whatsapp_r(CHAT_ROWS, ("Family", "Dad, Mom, You", (
        (44, "AXStaticText", "Dad: call me when free, 11:40 AM", None),
        (45, "AXButton", "Reply", "AXPress"),
        (46, "AXStaticText", "Mom: 🙏, 11:42 AM", None),
    )))
    search = _whatsapp_r((
        (20, "Chats", False), (21, "Neha Kapoor, ok done, 9:12 AM", False),
        (22, "Groups", False), (23, "Neha's Farewell 🎉, Rahul: cake?, Tuesday", False),
        (24, "Contacts", False), (25, "Neha K, Hey there! I am using WhatsApp.", False),
    ))
    shivangi_open = _whatsapp_r(CHAT_ROWS, ("Shivangi Gupta", "last seen today at 2:40 PM", (
        (44, "AXStaticText", "Shivangi Gupta: See you then!, Yesterday", None),
    )))
    for target, state, indices, gold, instructions in (
        ("Shivangi", poll, (46, 11, 3, 2, 12), 11, None),
        ("Rahul Sharma", poll, (14, 47, 15, 2), 15, None),
        ("Shivangi Gupta", poll, (11, 46, 41, 48), 11, None),
        ("Amit", _whatsapp_r(CHAT_ROWS[:4], POLL_CONVERSATION), (2, 12, 13, 3), 2, None),
        ("Priya", poll, (10, 60, 46, 44), 60,
         "The conversation with Priya is already open. Which element should the agent use "
         "to write the message?"),
        ("Dad", family, (13, 44, 45, 2), 2,
         "The chat list has no separate row for Dad. Which element should the agent press next "
         "to reach the one-to-one conversation with Dad?"),
        ("Neha Kapoor", search, (23, 21, 2, 3), 21, None),
        ("Shivangi Gupta", shivangi_open, (11, 41, 60, 44), 60,
         "Which element should the agent use next to send the message to Shivangi Gupta?"),
    ):
        instructions = instructions or (
            f"Which element should the agent press next to open the conversation with {target}?")
        add("chat_pick", f"goal: send a WhatsApp message to {target}\n{state}",
            pick(state, indices, instructions), str(gold))

    # is_nav: poll votes and reactions carry contact names but are not chats.
    for index, gold in ((11, "true"), (46, "false"), (15, "true"), (47, "false"),
                        (48, "false"), (10, "true"), (3, "false"), (13, "true")):
        add("is_nav", f"{poll}\nproposed action: press [{index}]",
            statement(f"Pressing element [{index}] opens a conversation from the chat list, rather "
                      "than voting in a poll, reacting, or opening another list."), gold)

    # header_ok: near-miss names, groups named after the target, no chat open.
    for target, header, subtitle, gold in (
        ("Shivangi Gupta", "Shivangi Gupta", "last seen today at 2:40 PM", "true"),
        ("Shivangi", "Shivangi Gupta", "online", "true"),
        ("Shivangi Gupta", "Shivani Gupta", "online", "false"),
        ("Shivangi", "Shivangi's Birthday 🎉", "Rahul, Priya, You", "false"),
        ("Rahul Sharma", "Rahul Sharma", "typing…", "true"),
        ("Rahul Sharma", "Rahul Verma", "online", "false"),
        ("Mom", "Mom ❤️", "online", "true"),
        ("Priya", "Family", "Dad, Mom, Priya, You", "false"),
    ):
        state = _whatsapp_r(CHAT_ROWS, (header, subtitle, ((44, "AXStaticText", "Hello!, 9:00 AM", None),)))
        add("header_ok", state,
            statement(f"The open conversation is the one-to-one chat with {target}."), gold)
    add("header_ok", _whatsapp_r(CHAT_ROWS),
        statement("The open conversation is the one-to-one chat with Shivangi Gupta."), "false")

    # sent_ok: newest outgoing "Hi" vs text still in the box or a stale send.
    for messages, composer, gold in (
        (((44, "AXStaticText", "Shivangi Gupta: See you then!, Yesterday", None),
          (45, "AXStaticText", "You: Hi, 2:47 PM, Delivered", None)), "", "true"),
        (((44, "AXStaticText", "Shivangi Gupta: See you then!, Yesterday", None),), "Hi", "false"),
        (((44, "AXStaticText", "Shivangi Gupta: Hi, 2:47 PM", None),), "", "false"),
        (((44, "AXStaticText", "You: Hello, 2:47 PM, Read", None),), "", "false"),
        (((44, "AXStaticText", "Shivangi Gupta: See you then!, Yesterday", None),
          (45, "AXStaticText", "You: Hi, 2:48 PM, Read", None)), "", "true"),
        (((44, "AXStaticText", "You: Hi, Yesterday, Read", None),
          (45, "AXStaticText", "Shivangi Gupta: hey!, Yesterday", None)), "Hi", "false"),
    ):
        state = _whatsapp_r(CHAT_ROWS, ("Shivangi Gupta", "online", messages), composer=composer)
        add("sent_ok", state,
            statement("The message \"Hi\" was just sent in this conversation: it is the newest "
                      "outgoing message, not text still waiting in the message box."), gold)

    # yt_first: the search button [3] is always offered as a distractor.
    for query, elements, gold in YOUTUBE_RESULTS:
        state = _youtube(query, elements)
        add("yt_first", f"goal: play {query} on YouTube\n{state}",
            pick(state, [index for index, _, _ in elements] + [3], YOUTUBE_INSTRUCTIONS), str(gold))
    return items


def wilson_interval(successes: int, n: int) -> tuple[float, float]:
    """95% Wilson score interval: at n = 62 a 4-item gap sits inside it."""
    if n == 0:
        return (0.0, 1.0)
    z = 1.959963984540054
    p = successes / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return (round(max(0.0, centre - half), 3), round(min(1.0, centre + half), 3))


def summarize(model: str, rows: list[dict[str, Any]]) -> dict[str, Any]:
    """Accuracy per category and overall with its 95% CI, mean p(gold),
    latency percentiles."""
    ms = sorted(row["ms"] for row in rows)
    correct = sum(row["pred"] == row["gold"] for row in rows)
    return {
        "event": "summary",
        "model": model,
        "correct": correct,
        "items": len(rows),
        "accuracy_ci95": wilson_interval(correct, len(rows)),
        "by_category": {
            cat: f"{sum(r['pred'] == r['gold'] for r in rows if r['cat'] == cat)}"
                 f"/{sum(r['cat'] == cat for r in rows)}"
            for cat in CATEGORIES
        },
        "mean_p_gold": round(statistics.mean(row["p_gold"] for row in rows), 3),
        "min_label_mass": round(min(row["label_mass"] for row in rows), 3),
        "p50_ms": round(statistics.median(ms), 1),
        "p90_ms": round(ms[int(len(ms) * 0.9)], 1),
        "misses": [row["id"] for row in rows if row["pred"] != row["gold"]],
    }


RECORD_MARKER = '{"event"'


def parse_worker_output(stdout: str) -> list[dict[str, Any]]:
    """The worker's JSON records, wherever they start on a line.

    Loading a custom-code checkpoint makes transformers print a
    ``trust_remote_code`` prompt with no trailing newline, so the first record
    can arrive as ``Do you wish to run the custom code? [y/N] {"event": ...}``.
    """
    records = []
    for line in stdout.splitlines():
        start = line.find(RECORD_MARKER)
        if start < 0:
            continue
        records.append(json.loads(line[start:]))
    return records


def _worker(model_path: str, cache_limit_mb: int | None, revision: int = 1) -> int:
    """Score every item with one model; print one JSON line per item."""
    import mlx.core as mx
    from mlx_lm import load

    from velora_engine.cleanup import neutralize_control_tokens

    if cache_limit_mb is not None:
        mx.set_cache_limit(cache_limit_mb * 1024 * 1024)
    started = time.perf_counter()
    model, tokenizer = load(model_path)
    load_ms = (time.perf_counter() - started) * 1000

    # The engine refuses to decide when a letter is not exactly one token.
    label_ids = []
    for label in OPTION_LABELS:
        encoded = list(tokenizer.encode(label))
        if len(encoded) != 1:
            print(json.dumps({"event": "refused", "label": label, "tokens": encoded}))
            return 1
        label_ids.append(encoded[0])

    def decide(item: dict[str, Any]):
        question = item["question"]
        messages = [
            {"role": "system", "content": DECISION_SYSTEM_PROMPT},
            {"role": "user", "content": neutralize_control_tokens(
                decision_message(item["state"], question))},
        ]
        tokens = tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, enable_thinking=False)
        logits = model(mx.array(tokens)[None])[0, -1].astype(mx.float32)
        logprobs = logits - mx.logsumexp(logits)
        picked = logprobs[mx.array(label_ids[:len(question.options)])]
        top = mx.argmax(logprobs)
        mx.eval(picked, top)
        answer = answer_from_logprobs(question, picked.tolist())
        return answer, len(tokens), tokenizer.decode([int(top)])

    items = build_items(revision)
    decide(items[0])  # warm-up: kernel compilation is not decision latency
    for item in items:
        started = time.perf_counter()
        answer, tokens, top = decide(item)
        print(json.dumps({
            "event": "item", "id": item["id"], "cat": item["cat"], "gold": item["gold"],
            "pred": answer.choice, "p_gold": round(answer.p(item["gold"]), 4),
            "label_mass": round(answer.label_mass, 4), "top_token": top,
            "ms": round((time.perf_counter() - started) * 1000, 1), "tokens": tokens,
        }, ensure_ascii=False), flush=True)
    print(json.dumps({
        "event": "memory", "load_ms": round(load_ms), "peak_bytes": int(mx.get_peak_memory()),
        "active_bytes": int(mx.get_active_memory()),
    }), flush=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true", help="print the items without loading MLX")
    parser.add_argument("--model", action="append", dest="models",
                        help="local MLX snapshot path or Hub id; repeat to compare, first is the baseline")
    parser.add_argument("--mlx-cache-limit-mb", type=int, default=None,
                        help="cap MLX's buffer cache in each worker (shared or busy Macs)")
    parser.add_argument("--revision", type=int, choices=(1, 2), default=1,
                        help="item revision: 1 = recorded baseline, 2 = consistent "
                             "WhatsApp selection (see _whatsapp)")
    parser.add_argument("--worker", help=argparse.SUPPRESS)
    args = parser.parse_args()

    if args.worker:
        return _worker(args.worker, args.mlx_cache_limit_mb, args.revision)
    if args.list:
        print(json.dumps([
            {**item, "question": item["question"].to_dict()}
            for item in build_items(args.revision)
        ], indent=1, ensure_ascii=False))
        return 0
    if not args.models:
        parser.error("--model is required")

    status = 0
    expected = len(build_items(args.revision))
    for model in args.models:
        command = [sys.executable, str(Path(__file__).resolve()), "--worker", model,
                   "--revision", str(args.revision)]
        if args.mlx_cache_limit_mb is not None:
            command += ["--mlx-cache-limit-mb", str(args.mlx_cache_limit_mb)]
        completed = subprocess.run(command, capture_output=True, text=True)
        rows = []
        for record in parse_worker_output(completed.stdout):
            record["model"] = model
            print(json.dumps(record, ensure_ascii=False))
            if record["event"] == "item":
                rows.append(record)
        # A score over fewer items is not comparable with any baseline.
        if completed.returncode != 0 or len(rows) != expected:
            print(json.dumps({"event": "error", "model": model, "returncode": completed.returncode,
                              "items": len(rows), "expected": expected,
                              "stderr": completed.stderr[-2000:]}))
            status = 1
            continue
        print(json.dumps(summarize(model, rows), ensure_ascii=False), flush=True)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
