"""Action Mode fast path: decided turns and their fallback to the controller."""

# ruff: noqa: F811

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest
from test_actions import (
    FakePlanner,
    _structured_ui,
    observation,
    send_observe,
    send_start,
    turn,
)
from test_server import connect, engine  # noqa: F401 — fixture reuse

from velora_engine import action_fastpath, actions
from velora_engine.decisions import (
    STATUS_OK,
    STATUS_UNAVAILABLE,
    Answer,
    DecisionResult,
)

WHATSAPP_CHAT = "open the Shivangi Gupta chat on WhatsApp"


def answer(choice: str, p: float = 0.99, mass: float = 0.95) -> Answer:
    return Answer(choice, {choice: p, "_other": 1.0 - p}, mass)


def decided(**choices: str | Answer) -> DecisionResult:
    return DecisionResult(STATUS_OK, {
        key: value if isinstance(value, Answer) else answer(value)
        for key, value in choices.items()
    })


def session_for(transcript: str, *apps: str) -> actions.ActionSession:
    return actions.ActionSession(transcript, actions.ActionContext.from_dict({
        "frontmost_app": "Sublime Text",
        "running_apps": [*apps, "Sublime Text"],
    }))


# ---- turn 1: open the named app ------------------------------------------

def test_open_command_becomes_a_finished_open_app_turn():
    session = session_for("Open Calculator", "Calculator")
    proposal = action_fastpath.propose(session)

    assert proposal.shape == action_fastpath.SHAPE_OPEN_APP
    assert proposal.app == "Calculator"
    reply = action_fastpath.reply_for(
        session, proposal, decided(intent="open_app", delivers="no").answers)

    accepted = session.accept_reply(json.dumps(reply))

    assert accepted == {"steps": [{"do": "open_app", "app": "Calculator"}],
                        "done": True}
    assert session.sends is False


@pytest.mark.parametrize("transcript", [
    WHATSAPP_CHAT,
    "In Finder, open the Downloads folder",
    "open the general channel in Slack",
    "Open Calendar and show today",
    # What an object means depends on the app: each of these parsed as
    # navigation under a lexical gate that five review rounds kept breaking.
    "Open Slack and show the team Q3 numbers",
    "In Calendar, open Maybe",
    "In FaceTime, open Mom",
    "In WhatsApp, open Rahul Happy Diwali",
])
def test_a_compound_command_is_left_to_the_controller(transcript):
    """`sends` locks on turn 1; beyond "show this app", no lexical gate
    can prove it false, so the controller decides it."""
    session = session_for(transcript, "WhatsApp", "Finder", "Slack",
                          "Calendar", "FaceTime")

    assert action_fastpath.propose(session) is None


@pytest.mark.parametrize("transcript", [
    "send hello to Himesh on Slack",
    "open Slack and tell Himesh I'm late",
    "reply to the last WhatsApp message",
    "open Mail and forward the invoice",
])
def test_delivery_words_never_reach_the_model(transcript):
    """Turn 1 locks `sends`, so a delivering command never gets a fast
    turn 1: none of these is app-only."""
    session = session_for(transcript, "Slack", "WhatsApp", "Mail")

    assert action_fastpath.propose(session) is None


@pytest.mark.parametrize("transcript", [
    # Inflected delivery verbs.
    "open WhatsApp, I'm sending Rahul the address",
    "open Slack and keep messaging Priya about the deploy",
    "open Messages, texting Mom that I landed",
    # Delivery phrasings with no bare delivery verb.
    "open WhatsApp and let Rahul know I'm late",
    "open Messages and remind Dad about dinner",
    "open WhatsApp and thank Mom for dinner",
    "open Slack and congratulate Priya on the launch",
    # The app's name used as the verb: subtracting it must not hide that.
    "WhatsApp Rahul that I'm running late",
    "open Slack and Slack Priya the link",
    # No English presentation verb: the model's answer would be the only
    # gate, and it was only ever measured on English.
    "abre WhatsApp y dile a Rahul que llego tarde",
    "In WhatsApp, text Rahul that I'm late",
    # Delivery verbs no stem list anticipates: only an allowlist holds.
    "open WhatsApp and write Rahul that I am late",
    "open Slack and follow up with Priya about the deploy",
    "open Messages and iMessage Mom that I landed",
    "open Messages and FaceTime Mom",
    "open WhatsApp and Rahul ko bolo main late hoon",
    "open Slack and update the team that the deploy is done",
    "open WhatsApp and contact Rahul",
    # Messages spelled only in navigation words, or tucked into a name or a
    # place: only a whole-command grammar with an end anchor refuses them.
    "Open WhatsApp with Rahul, can you take me to JFK?",
    "Open WhatsApp with Rahul, can you pick me up at 5?",
    "Open WhatsApp with Rahul can you pick me up at 5",
    "Open WhatsApp with Mom, I'd like to take you to Olive Garden",
    "Open WhatsApp with Rahul, Happy Diwali!",
    "Open WhatsApp with Rahul Happy Diwali",
    "In Slack, the standup is cancelled today",
    "Open the family group on WhatsApp, my flight lands today",
    "Open Slack, Update Team Deploy Done",
    "Open WhatsApp: Write Rahul Running Late",
    "Open Messages: iMessage Mom Landed",
    "show Mom pictures in WhatsApp",
    "show Rahul the photo in WhatsApp",
    # A reaction is a delivery; presses are left to the controller.
    "open Slack and click Like",
    # A contraction is a sentence, not a name.
    "In WhatsApp, open Rahul I'm late",
    "open the Rahul I'm late chat on WhatsApp",
    "In WhatsApp, open Rahul what's up",
    "In WhatsApp, open Mom let's talk tonight",
    "In WhatsApp, open Rahul I\u02bcm late",
    # "select" presses: a Tapback, a poll vote, an RSVP.
    "In Messages, select Heart",
    "Open WhatsApp and select Friday",
    "In Calendar, select Maybe",
    "Open Slack and select heart reaction",
    # Showing "my" something shares it; a huddle rings; "bring up" raises.
    "Show my screen in Slack",
    "Show my location in Messages",
    "In Slack, open huddle",
    "Bring up the Q3 numbers in Slack",
    # A script without spaces is one token whatever it says ("Rahul, I'll
    # be late"); an underscore must not vanish between names.
    "In WhatsApp, open \u62c9\u80e1\u5c14\u6211\u665a\u70b9\u5230",
    "In WhatsApp, open Rahul_happy_diwali",
])
def test_delivery_phrasings_never_reach_the_model(transcript):
    """`sends: false` locks on turn 1 and relaxes the recipient verifier.
    Only app-only commands get a fast turn 1, so the model's "no" is a
    second gate, never the only one."""
    session = session_for(transcript, "Slack", "WhatsApp", "Messages",
                          "Calendar")

    assert action_fastpath.propose(session) is None


@pytest.mark.parametrize("transcript", [
    "Open Finder",
    "please switch to Finder",
    "could you please open the Finder app",
    "take me to Finder.",
    "bring up Finder",
])
def test_a_command_that_only_asks_for_the_app_gets_a_fast_open(transcript):
    proposal = action_fastpath.propose(session_for(transcript, "Finder"))

    assert proposal.app == "Finder"
    assert proposal.done is True


@pytest.mark.parametrize(("transcript", "app"), [
    ("Open Messages", "Messages"),
    ("Open FaceTime", "FaceTime"),
    ("Open Chrome", "Google Chrome"),
    ("open Teams", "Microsoft Teams"),
    ("Open the App Store", "App Store"),
    ("Open The Unarchiver", "The Unarchiver"),
])
def test_an_app_named_whole_or_without_its_vendor_gets_a_fast_open(
        transcript, app):
    assert action_fastpath.propose(session_for(transcript, app)).app == app


@pytest.mark.parametrize(("transcript", "app"), [
    ("Open Chrome", "Chrome Remote Desktop"),
    ("Open Desktop", "Chrome Remote Desktop"),
    ("Open Phone", "iPhone Mirroring"),
    ("Open Time", "FaceTime"),
    ("Open Mail", "Gmail"),
    ("Open Activity", "Activity Monitor"),
    ("Open Calendar", "Notion Calendar"),
    ("Open Store", "App Store"),
    ("Open Store app", "App Store"),
    ("Open Unarchiver", "The Unarchiver"),
    # "Settings" usually means the front app's own settings.
    ("Open Settings", "System Settings"),
])
def test_a_partial_app_name_is_left_to_the_controller(transcript, app):
    """The shared alias matcher takes prefixes and substrings: right for
    checking a window, wrong for choosing what to open and calling it done."""
    assert action_fastpath.propose(session_for(transcript, app)) is None


def session_over_slack(transcript: str, app: str,
                       label: str) -> actions.ActionSession:
    """`transcript` said with Slack in front, showing a control `label`."""
    return actions.ActionSession(transcript, actions.ActionContext.from_dict({
        "frontmost_app": "Slack",
        "running_apps": [app, "Slack"],
        "ui_snapshot": {
            "id": "snap-slack", "app_name": "Slack", "source": "native",
            "complete": True, "elements": [
                {"index": 0, "depth": 0, "role": "AXWindow", "label": "Slack"},
                {"index": 1, "parent_index": 0, "depth": 1,
                 "role": "AXButton", "label": label, "actions": ["AXPress"]},
            ]},
    }))


@pytest.mark.parametrize(("transcript", "app", "label"), [
    ("Open Home", "Home", "Home"),
    ("Open Home", "Home", "Home, 2 unread"),
    ("Open the App Store", "App Store", "App Store"),
])
def test_a_destination_on_screen_is_not_mistaken_for_an_app(
        transcript, app, label):
    """"Open Home" in Slack, whose sidebar has a Home button, most likely
    means that button, not Home.app."""
    session = session_over_slack(transcript, app, label)

    assert action_fastpath.propose(session) is None


def test_a_label_that_only_shares_letters_does_not_block_the_open():
    session = session_over_slack("Open Home", "Home", "Homework")

    assert action_fastpath.propose(session).app == "Home"


def test_the_named_app_own_screen_does_not_block_its_fast_open():
    """Slack's own window is titled Slack; that is the app, not a control."""
    session = actions.ActionSession("Open Slack", actions.ActionContext.from_dict({
        "frontmost_app": "Slack",
        "running_apps": ["Slack"],
        "ui_snapshot": {
            "id": "snap-slack", "app_name": "Slack", "source": "native",
            "complete": True, "elements": [
                {"index": 0, "depth": 0, "role": "AXButton", "label": "Slack",
                 "actions": ["AXPress"]},
            ]},
    }))

    assert action_fastpath.propose(session).app == "Slack"


@pytest.mark.parametrize("transcript", [
    "Open Slack in the browser",
    "Open slack.com",
])
def test_web_intent_is_left_to_the_controller(transcript):
    assert action_fastpath.propose(session_for(transcript, "Slack")) is None


@pytest.mark.parametrize("transcript", [
    "search YouTube for cat videos",
    "open Slack and Notes",
])
def test_no_single_named_app_means_no_fast_turn(transcript):
    session = session_for(transcript, "Slack", "Notes")

    assert action_fastpath.propose(session) is None


@pytest.mark.parametrize("answers", [
    {"intent": answer("open_app", p=0.70), "delivers": answer("no")},
    {"intent": answer("web"), "delivers": answer("no")},
    {"intent": answer("open_app"), "delivers": answer("no", p=0.94)},
    {"intent": answer("open_app"), "delivers": answer("yes")},
    {"intent": answer("open_app", mass=0.30), "delivers": answer("no")},
    {"intent": answer("open_app")},
])
def test_unconfident_or_delivering_answers_fall_back(answers):
    session = session_for("Open Calculator", "Calculator")
    proposal = action_fastpath.propose(session)

    assert action_fastpath.reply_for(session, proposal, answers) is None


def test_open_mail_is_not_a_delivery_but_mailing_someone_is():
    """The app's own name is not the delivery verb it happens to spell."""
    assert action_fastpath.propose(session_for("Open Mail", "Mail")) is not None
    assert action_fastpath.propose(
        session_for("open Mail and mail Sam the report", "Mail")) is None


def test_later_turns_stay_with_the_controller():
    """A decided chat-row press skips the UI reviewer exactly like a poll
    option the command names ("Friday"): later turns wait for a gate that
    can tell navigation from an answer."""
    session = session_for(WHATSAPP_CHAT, "WhatsApp")
    session.accept_reply(turn([{"do": "open_app", "app": "WhatsApp"}],
                              goal=WHATSAPP_CHAT, sends=False))
    session.observation_message(observation(
        frontmost_app="WhatsApp", frontmost_bundle="net.whatsapp.WhatsApp",
        ui_snapshot=_structured_ui(active="Someone Else"),
        executed=["open_app WhatsApp"]))

    assert action_fastpath.propose(session) is None


# ---- server: the fast turn rides the controller's pipeline ---------------

class DecidingPlanner(FakePlanner):
    """FakePlanner plus scripted decisions. The decisions stand in for the
    model's answers only; every policy above them is production code."""

    def __init__(self, *replies: str, decisions=()) -> None:
        super().__init__(*replies)
        self.decisions = list(decisions)
        self.decided: list[list[str]] = []
        self.model_id = "mlx-community/Qwen3.5-4B-MLX-8bit"
        self.timeouts: list[int | None] = []

    async def cleanup(self, raw, system_prompt, timeout_ms=None, **kwargs):
        self.timeouts.append(timeout_ms)
        return await super().cleanup(raw, system_prompt, timeout_ms, **kwargs)

    async def decide(self, state, questions, *, cancel_event=None,
                     max_input_tokens=None, **_kwargs):
        assert max_input_tokens == actions.ACTION_MAX_INPUT_TOKENS
        assert cancel_event is not None
        self.decided.append([question.key for question in questions])
        if not self.decisions:
            return DecisionResult(STATUS_UNAVAILABLE, reason="unscripted")
        return self.decisions.pop(0)


class RefusingPlanner(DecidingPlanner):
    """The first `times` generations come back unapplied with `reason`:
    refused before a worker ran them (a replacement still loading), or
    timed out."""

    def __init__(self, *replies: str, reason: str, times: int = 1,
                 decisions=()) -> None:
        super().__init__(*replies, decisions=decisions)
        self.reason = reason
        self.times = times

    async def cleanup(self, raw, system_prompt, timeout_ms=None, **kwargs):
        if not self.times:
            return await super().cleanup(raw, system_prompt, timeout_ms, **kwargs)

        self.timeouts.append(timeout_ms)
        self.times -= 1
        return SimpleNamespace(text="", applied=False, ms=0, reason=self.reason,
                               input_tokens=0)


async def start_calculator(client):
    await client.recv_event("ready")
    await send_start(client, transcript="Open Calculator",
                     context={"frontmost_app": "Sublime Text",
                              "running_apps": ["Calculator", "Sublime Text"]})


async def test_open_command_needs_no_generation(engine):
    eng, sock = engine
    eng.cleanup = DecidingPlanner(
        decisions=[decided(intent="open_app", delivers="no")])
    client = await connect(sock)
    await client.recv_event("ready")
    await send_start(client, transcript="Open Calculator",
                     context={"frontmost_app": "Sublime Text",
                              "running_apps": ["Calculator", "Sublime Text"]})

    event = await client.recv_event("action_turn")

    assert event["steps"] == [{"do": "open_app", "app": "Calculator"}]
    assert event["done"] is True
    assert event["sends"] is False
    assert eng.cleanup.calls == []
    assert eng.cleanup.decided == [["intent", "delivers"]]


async def test_a_declined_open_decision_runs_the_controller(engine):
    eng, sock = engine
    eng.cleanup = DecidingPlanner(
        turn([{"do": "open_app", "app": "Calculator"}],
             goal="Open Calculator", sends=False, done=True),
        decisions=[decided(intent=answer("open_app", p=0.5), delivers="no")])
    client = await connect(sock)
    await start_calculator(client)

    event = await client.recv_event("action_turn")

    assert event["steps"] == [{"do": "open_app", "app": "Calculator"}]
    assert eng.cleanup.decided == [["intent", "delivers"]]
    assert len(eng.cleanup.calls) == 1
    assert "Your previous reply was rejected" not in eng.cleanup.calls[0][1]


async def test_a_fast_reply_the_validator_refuses_runs_the_controller(
        engine, monkeypatch):
    """A refused decided turn is not the controller's mistake: no repair
    note, no rejection count, and the controller keeps its cold budget."""
    eng, sock = engine
    invalid = {"goal": "Open Calculator", "sends": False, "done": True,
               "steps": [{"do": "open_app", "app": "Calculator"},
                         {"do": "key", "key": "return"}]}
    monkeypatch.setattr(action_fastpath, "reply_for",
                        lambda *_args: invalid)
    eng.cleanup = DecidingPlanner(
        turn([{"do": "open_app", "app": "Calculator"}],
             goal="Open Calculator", sends=False, done=True),
        decisions=[decided(intent="open_app", delivers="no")])
    client = await connect(sock)
    await start_calculator(client)

    event = await client.recv_event("action_turn")

    assert event["steps"] == [{"do": "open_app", "app": "Calculator"}]
    [(_, prompt)] = eng.cleanup.calls
    assert "Your previous reply was rejected" not in prompt
    assert eng.cleanup.timeouts == [actions.FIRST_TURN_TIMEOUT_MS]
    assert eng._action_session._repeated_rejected_replies == 0


async def test_first_controller_call_after_a_fast_turn_gets_the_cold_budget(engine):
    """A decided turn 1 never prefills the controller prompt. When its open
    fails and the loop goes on, the controller's first call is still cold."""
    eng, sock = engine
    eng.cleanup = DecidingPlanner(
        turn([{"do": "open_app", "app": "WhatsApp"}]),
        decisions=[decided(intent="open_app", delivers="no")],
    )
    client = await connect(sock)
    await client.recv_event("ready")
    await send_start(client, transcript="Open WhatsApp",
                     context={"frontmost_app": "Sublime Text",
                              "running_apps": ["WhatsApp", "Sublime Text"]})
    await client.recv_event("action_turn")
    await send_observe(client, observation=observation(
        frontmost_app="Sublime Text", executed=[],
        failed_step="open_app WhatsApp: the app did not come to the front"))

    await client.recv_event("action_turn")

    assert eng.cleanup.timeouts == [actions.FIRST_TURN_TIMEOUT_MS]
    assert eng.cleanup.decided == [["intent", "delivers"]], (
        "only turn 1 is decided")


@pytest.mark.parametrize("reason", [
    "llm_recovering", "llm_not_loaded", "llm_unhealthy", "timeout_queue",
    "error:cleanup worker is not connected"])
async def test_a_call_that_never_ran_leaves_the_cold_budget(engine, reason):
    """A refused call warmed nothing and rejected nothing: the call after
    it, on a new worker, is still the session's first prefill and gets the
    cold-start budget and the plain prompt."""
    eng, sock = engine
    eng.cleanup = RefusingPlanner(
        turn([{"do": "open_app", "app": "Calculator"}],
             goal="Open Calculator", sends=False, done=True),
        reason=reason)
    client = await connect(sock)
    await start_calculator(client)

    await client.recv_event("action_turn")

    assert eng.cleanup.timeouts == [actions.FIRST_TURN_TIMEOUT_MS,
                                    actions.FIRST_TURN_TIMEOUT_MS]
    # Nothing was rejected, so no repair note describes a reply that never
    # existed.
    [(_, prompt)] = eng.cleanup.calls
    assert "Your previous reply was rejected" not in prompt


async def test_two_calls_that_never_ran_report_the_model_unavailable(engine):
    eng, sock = engine
    eng.cleanup = RefusingPlanner(reason="llm_recovering", times=2)
    client = await connect(sock)
    await start_calculator(client)

    event = await client.recv_event("action_failed")

    assert event["code"] == "planner_unavailable"
    assert "llm_recovering" in event["error"]


async def test_a_plan_error_after_a_call_that_never_ran_is_the_reported_one(
        engine):
    """The user sees what went wrong with the plan, not the model's brief
    absence before it."""
    eng, sock = engine
    eng.cleanup = RefusingPlanner("not json", reason="llm_recovering")
    client = await connect(sock)
    await start_calculator(client)

    event = await client.recv_event("action_failed")

    assert event["code"] == "plan_invalid"
    assert "model unavailable" not in event["error"]


async def test_the_repair_after_a_cold_call_gets_the_warm_budget(engine):
    """The first call prefilled the controller prompt, so its repair rides a
    warm prefix. Two cold budgets (2 x 35 s) outran the app's backstop."""
    eng, sock = engine
    eng.cleanup = DecidingPlanner(
        "not json",
        turn([{"do": "open_app", "app": "Calculator"}],
             goal="Open Calculator", sends=False, done=True))
    client = await connect(sock)
    await start_calculator(client)

    await client.recv_event("action_turn")

    assert eng.cleanup.timeouts == [actions.FIRST_TURN_TIMEOUT_MS,
                                    actions.PLAN_TIMEOUT_MS]


async def test_an_uncalibrated_model_keeps_the_controller(engine):
    """The confidence bars were measured on one model; a smaller tier's
    probabilities would lock `sends` on numbers nobody checked."""
    eng, sock = engine
    eng.cleanup = DecidingPlanner(
        turn([{"do": "open_app", "app": "Calculator"}],
             goal="Open Calculator", sends=False, done=True),
        decisions=[decided(intent="open_app", delivers="no")])
    eng.cleanup.model_id = "mlx-community/Qwen3.5-2B-MLX-4bit"
    client = await connect(sock)
    await client.recv_event("ready")
    await send_start(client, transcript="Open Calculator",
                     context={"frontmost_app": "Sublime Text",
                              "running_apps": ["Calculator", "Sublime Text"]})

    await client.recv_event("action_turn")

    assert eng.cleanup.decided == []
    assert len(eng.cleanup.calls) == 1


async def test_a_fast_path_bug_never_fails_the_action(engine, monkeypatch):
    """The fast path is an optimisation: its own failure runs the controller."""
    eng, sock = engine

    def broken(_session):
        raise RuntimeError("fast path bug")

    monkeypatch.setattr(action_fastpath, "propose", broken)
    eng.cleanup = DecidingPlanner(turn(
        [{"do": "open_app", "app": "Calculator"}],
        goal="Open Calculator", sends=False, done=True))
    client = await connect(sock)
    await client.recv_event("ready")
    await send_start(client, transcript="Open Calculator",
                     context={"frontmost_app": "Sublime Text",
                              "running_apps": ["Calculator", "Sublime Text"]})

    event = await client.recv_event("action_turn")

    assert event["steps"] == [{"do": "open_app", "app": "Calculator"}]
    assert len(eng.cleanup.calls) == 1
