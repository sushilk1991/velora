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

Later turns stay with the controller. A decided press of the chat row a
command names was measured at 0.3 s vs 1.9 s, but a poll option ("Friday")
is structurally the same collection row and skips the same UI reviewer, so
it waits until that shared exemption can tell navigation from an answer.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import TYPE_CHECKING

from .actions import (
    MAX_TRANSCRIPT_CHARS,
    _APP_ONLY_IGNORED_WORDS,
    _PRESENTATION_INTENT_PREFIXES,
    _clip,
    command_names_app,
    command_names_only_app,
    is_app_only_presentation,
    normalized_term,
    presentation_words,
)
from .decisions import Answer, Question

if TYPE_CHECKING:
    from .actions import ActionSession

SHAPE_OPEN_APP = "open_app"

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


def propose(session: "ActionSession") -> FastProposal | None:
    """The fast-turn questions for this point of the session, or None when
    the turn is not one of the known shapes (the controller then runs)."""
    if session.finished or session.turns_used != 0:
        return None
    return _propose_open_app(session)


def reply_for(session: "ActionSession", proposal: FastProposal,
              answers: dict[str, Answer]) -> dict | None:
    """The controller-shaped reply the answers support, or None."""
    if proposal.shape != SHAPE_OPEN_APP:
        return None
    if not (_confident(answers.get("intent"), "open_app", MIN_INTENT_P)
            and _confident(answers.get("delivers"), "no", MIN_NO_DELIVERY_P)):
        return None
    return {
        "goal": session.goal,
        "sends": False,
        "steps": [{"do": "open_app", "app": proposal.app}],
        "done": proposal.done,
    }


def _confident(answer: Answer | None, key: str, bar: float) -> bool:
    return (answer is not None and answer.choice == key
            and answer.p(key) >= bar and answer.label_mass >= MIN_LABEL_MASS)


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
