"""Action Mode fast path: decide the obvious turn instead of generating it.

The controller writes every turn as free JSON: ~3 s for a one-step turn 1.
The commonest turn 1 in the field has every argument already known: open
the app a command that asks for nothing else names ("Open Calculator",
"switch to Slack" → ``open_app``, done).

That is a closed-set decision. This module asks it as typed questions
(:mod:`velora_engine.decisions`, ~60 ms each on the loaded model) and, only
when the model is confident, writes the reply the controller would have
written. The reply then takes the controller's own path unchanged: bounds,
``ActionSession.accept_reply`` → ``validate_plan``, and the app's
independent re-validation. Any doubt, any refusal, and the controller runs
exactly as before::

    command ─► propose() ─► decide (~0.2 s) ─► reply_for()
                                                  │
                          confident ◄─────────────┴──► None
                              │                          │
                        reply JSON ─► validate           controller
                              │ refused ───────────────► (unchanged)

Turn 1 fixes ``sends`` for the whole action, and ``sends: false`` relaxes the
recipient verifier. So the fast turn takes only commands that are nothing
but "show this app", where ``false`` is provably right. Compound commands
("open the Shivangi Gupta chat on WhatsApp") go to the controller: five
review rounds broke every lexical gate for them, because what an object
means depends on the app ("show the team the numbers" shares, "In Calendar,
open Maybe" RSVPs, "In FaceTime, open Mom" may call).

Later turns of a ``sends: false`` action may be one press of the control
the command names (the chat row in "open the Shivangi Gupta chat on
WhatsApp": 0.3 s vs 1.9 s generated).

A named list row skips the UI reviewer (`turn_is_self_evident_collection_
navigation`), for the controller's presses as well as these. A poll option
("Friday") is the same kind of row, so before that exemption holds, one
more question asks what pressing the row does, with where it sits and what
sits beside it in the STATE::

    press of a named list row ─► "effect" (~0.1 s)
                                    │
             navigate, confident ◄──┴──► anything else
                    │                        │
             reviewer skipped           UI reviewer runs
                                        (a decided press: the
                                         controller runs instead)
"""

from __future__ import annotations

import difflib
import re
from collections import Counter
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from .actions import (
    MAX_TRANSCRIPT_CHARS,
    MIN_PRESS_LABEL_CHARS,
    _APP_ONLY_IGNORED_WORDS,
    _MAX_UI_LABEL_CHARS,
    _PRESENTATION_INTENT_PREFIXES,
    _UI_SOURCE_NATIVE,
    _clip,
    _collection_peers,
    command_names_app,
    command_names_only_app,
    is_app_only_presentation,
    normalized_term,
    presentation_words,
    press_label_is_committing,
    turn_is_self_evident_collection_navigation,
)
from .decisions import Answer, Question

if TYPE_CHECKING:
    from .actions import ActionSession

SHAPE_OPEN_APP = "open_app"
SHAPE_PRESS = "press"
SHAPE_PRESS_CHECK = "press_check"

# The only model the bars below were measured on. Other tiers (4B-4bit,
# 2B-4bit) keep the controller until a replay calibrates them: turn 1's
# `sends` lock must not rest on unmeasured probabilities.
CALIBRATED_MODEL_IDS = frozenset(("mlx-community/Qwen3.5-4B-MLX-8bit",))

# Confidence bars, as probabilities renormalised over the options. A wrong
# fast open finishes the action in the wrong place, so the bars sit high.
# Set from a replay of the logged commands on Qwen3.5-4B-8bit (2026-09-24,
# while turn 1 still took compound commands): every bar clears its nearest
# must-decline case.
MIN_INTENT_P = 0.85
# `sends` is decided on turn 1 and locked for the whole action. A fast
# "no" that should have been "yes" turns a send into a draft, so this is
# the strictest bar. Turn 1 now takes only app-only commands, where "no"
# already holds, so the question is a second gate there.
MIN_NO_DELIVERY_P = 0.95
# Probability the model put on ANY option letter. Below this it wanted to
# answer something else, and the renormalised distribution means little.
MIN_LABEL_MASS = 0.50

# A fast press is recoverable (the loop observes, and the controller takes
# over) but spends one of eight turns. Measured 2026-09-25: right presses
# scored next >= 0.84, and "search Slack for the deploy thread" scored 0.76
# and would have pressed Threads; every right target scored >= 0.90.
MIN_PRESS_P = 0.80
MIN_TARGET_P = 0.90
# A named list row skips the UI reviewer only when pressing it is this
# surely navigation. Below the bar the reviewer decides, as for any other
# press. Replay of 40 crafted native lists (2026-10-09): every navigation
# row (chats, channels, DMs, folders, mailboxes, settings) >= 0.947; polls,
# RSVPs, tapbacks, share/assign pickers <= 0.21, except a "Forward to"
# picker with no container label at 0.893. Options that name recipients
# sank chat rows to 0.04-0.68: opening a chat also reads as picking whom.
MIN_NAVIGATE_P = 0.90
# The check's deadline, short of the decision default (6 s): it runs on
# every reviewed-or-exempt press of a turn, inside the app's 150 s backstop.
# Measured 0.13-0.6 s, 1.7 s on a loaded machine's first decision.
PRESS_CHECK_TIMEOUT_MS = 3_000

# Option letters are A-Z; one is reserved for "none of these".
MAX_PRESS_CANDIDATES = 25
# A fast press that does not finish the job is followed by another look. Two
# guesses is enough; after that the controller reasons over the screen.
MAX_FAST_PRESSES = 2
_MAX_TITLE_CHARS = 120
_MAX_LABEL_CHARS = 80
# What the press check shows around its target: the nearest labelled
# containers, and the list's other rows.
_MAX_CHECK_ANCESTORS = 2
_MAX_CHECK_PEERS = 6

# Controls whose press delivers something though no committing word in
# `press_label_is_committing` names it: reactions, votes, RSVPs, calls.
# Whole label words, so a "Calls" tab or a "Replies" view stays a place.
_DELIVERY_LABEL_WORDS = frozenset((
    "accept", "answer", "call", "decline", "dislike", "follow", "ha", "heart",
    "join", "like", "maybe", "react", "reaction", "reply", "rsvp", "share",
    "thumbs", "unfollow", "upvote", "vote",
))
# Tapbacks spelled as phrases ("Exclamation mark") rather than one word.
_DELIVERY_LABEL_PHRASES = ("exclamation mark", "question mark")
# Apps where pressing a person's row places a call.
_CALLING_APPS = frozenset(("facetime", "phone", "skype"))

# Vendor words a spoken app name may drop: "Chrome" is Google Chrome,
# "Teams" is Microsoft Teams. Any other trailing word is not enough on its
# own: "Desktop" is not Chrome Remote Desktop, "Calendar" not Notion
# Calendar, and "Settings" usually means the front app's own settings.
_DROPPABLE_APP_PREFIXES = frozenset(("adobe", "google", "microsoft"))
_WORD_RE = re.compile(r"[^\W_]+")


@dataclass(frozen=True)
class FastProposal:
    """Questions for one fast turn, plus what the reply would act on."""

    shape: str
    state: str
    questions: tuple[Question, ...]
    app: str = ""
    # Opening the app IS the whole command ("open Calculator"): the turn
    # finishes the action, as the controller's own `done: true` would.
    done: bool = False
    # Press candidates by stringified snapshot index (the target option keys).
    candidates: dict[str, dict] = field(default_factory=dict)


def propose(session: "ActionSession") -> FastProposal | None:
    """The fast-turn questions for this point of the session, or None when
    the turn is not one of the known shapes (the controller then runs)."""
    # The questions carry no history: after a failed step, or with typed
    # text a press could move or commit, the controller reads the turn.
    if (session.finished or session.state.pending_ui_index is not None
            or session.state.pending_text or session.last_step_failed):
        return None
    if session.turns_used == 0:
        return _propose_open_app(session)
    if session.sends is False:
        return _propose_press(session)
    return None


def reply_for(session: "ActionSession", proposal: FastProposal,
              answers: dict[str, Answer]) -> dict | None:
    """The controller-shaped reply the answers support, or None."""
    if proposal.shape == SHAPE_OPEN_APP:
        if not (_confident(answers.get("intent"), "open_app", MIN_INTENT_P)
                and _confident(answers.get("delivers"), "no",
                               MIN_NO_DELIVERY_P)):
            return None
        return {
            "goal": session.goal,
            "sends": False,
            "steps": [{"do": "open_app", "app": proposal.app}],
            "done": proposal.done,
        }

    if proposal.shape != SHAPE_PRESS:
        return None
    target = answers.get("target")
    if not (_confident(answers.get("next"), "press", MIN_PRESS_P)
            and target is not None and target.choice in proposal.candidates
            and _confident(target, target.choice, MIN_TARGET_P)):
        return None

    # Pin focus to the observed app first: the press must never land in
    # whatever app happens to be in front.
    element = proposal.candidates[target.choice]
    return {
        "steps": [
            {"do": "wait_frontmost", "app": proposal.app},
            {"do": "press_ui", "index": element["index"],
             "role": element["role"], "label": _label(element)},
        ],
    }


def record_accepted(session: "ActionSession", turn: dict) -> None:
    """Remember the controls an ACCEPTED fast turn presses, so no later
    fast turn proposes one again.

    Only after review and validation: a refused press never ran, so it
    neither spends the fast-press budget nor hides that control.
    """
    session.fast_press_labels.update(_pressed_terms(turn))


def record_refused(session: "ActionSession", turn: dict) -> None:
    """Remember the controls a fast turn would have pressed when it fell
    back: refused, over the review's context limit, or unreviewable.

    Proposing one again would pay a decision and a reviewer call on every
    later turn before the controller runs. The press never ran, so it
    spends none of the fast-press budget.
    """
    session.fast_refused_labels.update(_pressed_terms(turn))


def _pressed_terms(turn: dict) -> set[str]:
    return {
        normalized_term(str(step.get("label") or ""))
        for step in turn.get("steps") or []
        if isinstance(step, dict) and step.get("do") == "press_ui"
    }


def _confident(answer: Answer | None, key: str, bar: float) -> bool:
    return (answer is not None and answer.choice == key
            and answer.p(key) >= bar and answer.label_mass >= MIN_LABEL_MASS)


def _words(text: str) -> set[str]:
    return set(_WORD_RE.findall(text.casefold()))


def _delivers(label: str) -> bool:
    """Whether pressing this label reacts, votes, RSVPs, calls, or shares."""
    if _words(label) & _DELIVERY_LABEL_WORDS:
        return True
    spoken = " ".join(_WORD_RE.findall(label.casefold()))
    return any(phrase in spoken for phrase in _DELIVERY_LABEL_PHRASES)


def _control(element: dict) -> str:
    """`Button "Shivangi Gupta"`: role without its AX prefix, clipped label."""
    role = str(element.get("role") or "").removeprefix("AX")
    return f'{role} "{_clip(_label(element), _MAX_LABEL_CHARS)}"'


def _label(element: dict) -> str:
    return " ".join(str(element.get("label") or "").split())


def _command_line(session: "ActionSession") -> str:
    return f'command (spoken): "{_clip(session.transcript, MAX_TRANSCRIPT_CHARS)}"'


# ---- turn 1: open the named app ------------------------------------------

def _named_app(session: "ActionSession") -> str | None:
    """The one app the command names, by the same lexical binding that
    grants foreground authority elsewhere (`command_names_only_app`)."""
    apps = session.state.app_names
    # Cheap pass first: the exclusive check compares every candidate pair.
    mentioned = [app for app in apps if command_names_app(session.transcript, app)]
    named = {app for app in mentioned
             if command_names_only_app(session.transcript, app, apps)}
    return named.pop() if len(named) == 1 else None


def _propose_open_app(session: "ActionSession") -> FastProposal | None:
    app = _named_app(session)
    if app is None:
        return None

    # Only a command that is nothing but "show this app" ("Open Mail",
    # "please switch to Slack"): its `sends: false` is provably right, since
    # opening the app is the whole command. Anything more is the controller's.
    if not is_app_only_presentation(
            session.transcript, app, candidate_apps=session.state.app_names):
        return None

    # The shared alias matcher also takes prefixes and substrings ("Phone"
    # binds iPhone Mirroring): fine for checking a window, wrong for picking
    # what to open and calling the action done. Here the spoken name must be
    # the app's whole name, less at most a vendor word. Filler words ("the",
    # "app") are skipped on both sides, but a name made of them must still
    # be said whole and in order: "Open the App Store" binds App Store,
    # "Open Store" and "Open Store app" do not.
    said = _spoken_app_words(session.transcript)
    spoken = _meaningful(said)
    app_words = _WORD_RE.findall(app.casefold())
    full_name = (spoken == _meaningful(app_words)
                 and _contains_run(said, app_words))
    vendor_dropped = (len(app_words) > 1
                      and app_words[0] in _DROPPABLE_APP_PREFIXES
                      and spoken == app_words[1:])
    if not full_name and not vendor_dropped:
        return None

    # "Open Home" said over Slack, whose sidebar has a Home button, most
    # likely means the button, not Home.app.
    if _names_a_control_elsewhere(session, app, (spoken, app_words)):
        return None

    state = "\n".join([
        _command_line(session),
        f"app named in the command: {_clip(app, 60)}",
        f"frontmost app: {_clip(session.context.frontmost_app, 60) or 'unknown'}",
    ])
    questions = (
        Question("intent", "What does the command ask for?", (
            ("open_app", f"open, show, or switch to {app}, possibly then do "
                         "something inside it"),
            ("web", "search the web, or open a website or a link"),
            ("other", f"something else, or it is not about the app {app}"),
        )),
        # Spelled-out options: bare yes/no left "open the X chat" at p(no)
        # 0.92 and "wish Rahul a happy birthday" at 0.44; these put every
        # logged non-delivering command at >= 0.95 and every delivering
        # one at <= 0.84 (measured on compound commands, 2026-09-24).
        Question("delivers",
                 "Would carrying out the command send, post, reply, or "
                 "otherwise deliver anything to another person?", (
                     ("no", "no: it only opens, shows, finds, plays, types, "
                            "or drafts"),
                     ("yes", "yes: it sends, posts, replies, or delivers "
                             "something to someone"),
                 )),
    )
    return FastProposal(SHAPE_OPEN_APP, state, questions, app=app, done=True)


def _spoken_app_words(transcript: str) -> list[str]:
    """The words after the presentation verb, as `is_app_only_presentation`
    reads them: "could you open the Finder app" → ["the", "finder", "app"]."""
    words = presentation_words(transcript)
    prefix = next((item for item in _PRESENTATION_INTENT_PREFIXES
                   if tuple(words[:len(item)]) == item), ())
    return words[len(prefix):]


def _meaningful(words: list[str]) -> list[str]:
    """Words minus filler: ["the", "finder", "app"] → ["finder"]."""
    return [word for word in words if word not in _APP_ONLY_IGNORED_WORDS]


def _contains_run(words: list[str], run: list[str]) -> bool:
    """Whether `run` appears in `words` unbroken and in order:
    ["open", "the", "app", "store"] contains ["app", "store"]."""
    width = len(run)
    return any(words[start:start + width] == run
               for start in range(len(words) - width + 1))


def _names_a_control_elsewhere(
        session: "ActionSession", app: str,
        names: tuple[list[str], ...]) -> bool:
    """Whether another app's screen shows a control labelled with one of the
    app's spoken `names`, decorated or not: "Home, 2 unread" names Home."""
    snapshot = session.current_ui_snapshot
    shown_app = normalized_term(str(snapshot.get("app_name") or ""))
    if not shown_app or shown_app == normalized_term(app):
        return False

    for item in snapshot.get("elements") or []:
        label_words = _WORD_RE.findall(_label(item).casefold())
        if any(name and _contains_run(label_words, name) for name in names):
            return True
    return False


# ---- later turns: press the control the command points at ----------------

def _press_candidates(session: "ActionSession") -> list[dict]:
    """Controls a fast turn may propose, most command-like first.

    Only what `validate_plan` would accept for ``press_ui`` AND is
    unambiguous: enabled, AXPress, a label long enough to bind, not clipped
    past the validator's cap, not committing, not a delivery ("Heart",
    "Reply"), appearing exactly once, and not already fast-pressed or
    refused. Web content is left to the controller: page text is
    attacker-chosen.

    A selected control is left out too. Pressing it moves nothing forward,
    and it is how "already there" shows: asked whether the command was
    already complete, the model answered yes merely because the target
    was visible, so completion is read from state instead.
    """
    elements = session.current_ui_snapshot.get("elements") or []
    counts = Counter(normalized_term(_label(item)) for item in elements)
    command = normalized_term(session.transcript)
    command_words = _words(session.transcript)

    candidates = []
    for item in elements:
        label = _label(item)
        term = normalized_term(label)
        if ("AXPress" not in (item.get("actions") or [])
                or item.get("enabled") is False
                or item.get("selected") is True
                or item.get("in_web_content") is True
                or len(term) < MIN_PRESS_LABEL_CHARS
                or len(label) > _MAX_UI_LABEL_CHARS
                or counts[term] != 1
                or _delivers(label)
                or term in session.fast_press_labels
                or term in session.fast_refused_labels
                or press_label_is_committing(label)):
            continue
        candidates.append(item)

    # Shared words first, then overall similarity; sorted() is stable, so
    # ties keep on-screen order.
    def rank(item: dict) -> tuple[int, float]:
        label = _label(item)
        shared = len(_words(label) & command_words)
        similarity = difflib.SequenceMatcher(
            None, normalized_term(label), command).ratio()
        return (-shared, -similarity)

    return sorted(candidates, key=rank)[:MAX_PRESS_CANDIDATES]


def presses_may_call(session: "ActionSession") -> bool:
    """Whether the screen is a calling app's, where a person's row may
    place the call (FaceTime, Phone)."""
    app = str(session.current_ui_snapshot.get("app_name") or "")
    return normalized_term(app) in _CALLING_APPS


def _propose_press(session: "ActionSession") -> FastProposal | None:
    snapshot = session.current_ui_snapshot
    app = str(snapshot.get("app_name") or "").strip()
    if (snapshot.get("source") != _UI_SOURCE_NATIVE
            or snapshot.get("complete") is not True
            or not snapshot.get("id") or not app
            or presses_may_call(session)
            or len(session.fast_press_labels) >= MAX_FAST_PRESSES):
        return None
    candidates = _press_candidates(session)
    if not candidates:
        return None

    # Screen labels stay inside the STATE, which the system prompt fences as
    # data; the options only point at them ("control 3"), so a label cannot
    # speak from the QUESTION section.
    controls = [f"control {number}: {_control(item)}"
                for number, item in enumerate(candidates, start=1)]
    state = "\n".join([
        _command_line(session),
        f"app: {_clip(app, 60)}",
        "window: " + _clip(str(snapshot.get("window_title") or ""),
                           _MAX_TITLE_CHARS),
        "controls on screen:",
        *controls,
    ])
    options = [(str(item["index"]), f"control {number}")
               for number, item in enumerate(candidates, start=1)]
    questions = (
        Question("next", "What should happen next to carry out the command "
                         "on this screen?", (
            ("press", "press one of the controls on screen"),
            ("type", "type, paste, or edit text"),
            ("other", "something else: scroll, search, a keyboard shortcut, "
                      "another app, or media playback"),
        )),
        Question("target", "Which control should be pressed next?",
                 (*options, ("none", "none of these"))),
    )
    return FastProposal(
        SHAPE_PRESS, state, questions, app=app,
        candidates={str(item["index"]): item for item in candidates},
    )


# ---- any turn: does pressing a named list row go somewhere? -------------

def press_check(parsed: dict, session: "ActionSession") -> FastProposal | None:
    """The question that decides whether a press may skip the UI reviewer,
    or None when the press is not one the shared exemption covers.

    The STATE places the target the way a person reads the screen: the
    containers it sits in and the list's other rows. A chat row sits among
    chats; a poll option sits under its question beside the other answers.
    """
    if not turn_is_self_evident_collection_navigation(parsed, session):
        return None
    snapshot = session.current_ui_snapshot
    index = next(step["index"] for step in parsed["steps"]
                 if isinstance(step, dict) and step.get("do") == "press_ui")
    by_index = {item["index"]: item for item in snapshot["elements"]}
    target = by_index[index]

    peers = _collection_peers(snapshot, index)
    holder = _row_holding(target, peers, by_index)
    others = [f'"{_clip(_label(peer), _MAX_LABEL_CHARS)}"'
              for peer in peers if peer is not holder][:_MAX_CHECK_PEERS]
    containers = [_control(item) for item in _labelled_ancestors(
        holder or target, by_index)][:_MAX_CHECK_ANCESTORS]

    lines = [
        _command_line(session),
        f"app: {_clip(str(snapshot.get('app_name') or ''), 60)}",
        "window: " + _clip(str(snapshot.get("window_title") or ""),
                           _MAX_TITLE_CHARS),
    ]
    if containers:
        lines.append("inside: " + " > ".join(reversed(containers)))
    lines.append(f"target control: {_control(target)}")
    if others:
        lines.append("other items in the same list: " + "; ".join(others))

    # Wording measured on Qwen3.5-4B-8bit (2026-10-09); see MIN_NAVIGATE_P.
    # Adding "picks a recipient" to the answer option caught pickers but
    # pulled chat rows below the bar, so the options stay as they are.
    question = Question(
        "effect",
        "The command will press the target control. What does pressing it do?",
        (("navigate", "goes somewhere: opens a chat, channel, page, tab, "
                      "folder, or item to look at"),
         ("answer", "answers or acts: votes, picks an answer, RSVPs, reacts, "
                    "joins, or confirms something")))
    return FastProposal(SHAPE_PRESS_CHECK, "\n".join(lines), (question,))


def press_goes_somewhere(answers: dict[str, Answer]) -> bool:
    """Whether the press check is sure enough the press is navigation."""
    return _confident(answers.get("effect"), "navigate", MIN_NAVIGATE_P)


def _row_holding(target: dict, peers: list[dict],
                 by_index: dict[int, dict]) -> dict | None:
    """The peer that is the target or contains it: the list row it is in."""
    peer_ids = {id(peer) for peer in peers}
    # A malformed snapshot may link parents in a loop; each node once.
    seen: set[int] = set()
    item: dict | None = target
    while item is not None and id(item) not in seen:
        if id(item) in peer_ids:
            return item
        seen.add(id(item))
        parent = item.get("parent_index")
        item = by_index.get(parent) if isinstance(parent, int) else None
    return None


def _labelled_ancestors(item: dict, by_index: dict[int, dict]) -> list[dict]:
    """Labelled containers above `item`, nearest first, short of the window
    (its title is already in the STATE)."""
    found = []
    # A malformed snapshot may link parents in a loop; each node once.
    seen: set[int] = set()
    parent = item.get("parent_index")
    while (isinstance(parent, int) and parent in by_index
           and parent not in seen):
        seen.add(parent)
        ancestor = by_index[parent]
        if ancestor.get("role") != "AXWindow" and _label(ancestor):
            found.append(ancestor)
        parent = ancestor.get("parent_index")
    return found
