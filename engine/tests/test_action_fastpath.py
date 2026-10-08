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


# ---- later turns: the press a command points at --------------------------

def _chat_list_ui(*, selected: str = "Someone Else") -> dict:
    """WhatsApp with its chat list: four rows, `selected` one open."""
    raw = _structured_ui(active=selected)
    rows = [item for item in raw["elements"] if item.get("parent_index") == 10]
    for item in rows:
        item.pop("focused", None)
        item["selected"] = item["label"] == selected
    return raw


def _poll_ui() -> dict:
    """WhatsApp with a four-option poll open in the conversation pane. Each
    option is a pressable row exactly like a chat row: only where it sits
    and what sits beside it say that pressing it votes."""
    raw = _chat_list_ui(selected="Design team")
    raw["elements"] += [
        {"index": 40, "parent_index": 26, "depth": 2, "role": "AXGroup",
         "label": "Poll: Which day works for the offsite?",
         "frame": {"x": 400, "y": 200, "w": 300, "h": 260}},
        *[
            {"index": 41 + offset, "parent_index": 40, "depth": 3,
             "role": "AXButton", "label": day, "actions": ["AXPress"],
             "frame": {"x": 410, "y": 240 + offset * 50, "w": 280, "h": 44}}
            for offset, day in enumerate(
                ("Friday", "Saturday", "Sunday", "Monday"))
        ],
    ]
    return raw


def session_on(transcript: str, ui: dict, *,
               turn_one: list[dict] | None = None,
               failed_step: str | None = None) -> actions.ActionSession:
    """A session past its controller-written turn 1 (`sends: false`), now
    looking at `ui`."""
    session = session_for(transcript, "WhatsApp")
    session.accept_reply(turn(
        turn_one or [{"do": "open_app", "app": "WhatsApp"}],
        goal=transcript, sends=False))
    session.observation_message(observation(
        frontmost_app="WhatsApp", frontmost_bundle="net.whatsapp.WhatsApp",
        ui_snapshot=ui, executed=["open_app WhatsApp"],
        failed_step=failed_step))
    return session


def press(index: int, label: str, role: str = "AXButton") -> dict:
    return actions.parse_turn(turn([
        {"do": "wait_frontmost", "app": "WhatsApp"},
        {"do": "press_ui", "index": index, "role": role, "label": label},
    ]))


def test_a_press_on_a_named_list_row_is_checked_with_its_neighbours():
    """The check sees where the target sits and what sits beside it: a chat
    row among chats, a poll option under its question."""
    session = session_on(WHATSAPP_CHAT, _chat_list_ui())

    check = action_fastpath.press_check(press(14, "Shivangi Gupta"), session)

    assert check.shape == action_fastpath.SHAPE_PRESS_CHECK
    assert [question.key for question in check.questions] == ["effect"]
    assert 'target control: Button "Shivangi Gupta"' in check.state
    assert 'inside: Group "List of chats"' in check.state
    assert '"Chat 15"' in check.state
    assert WHATSAPP_CHAT in check.state

    poll = session_on("pick Friday", _poll_ui())
    vote = action_fastpath.press_check(press(41, "Friday"), poll)

    assert ('inside: Group "Conversation" > '
            'Group "Poll: Which day works for the offsite?"') in vote.state
    assert '"Saturday"' in vote.state
    assert '"Chat 15"' not in vote.state


def test_only_presses_the_shared_exemption_would_wave_through_are_checked():
    """Every other press already goes to the UI reviewer."""
    session = session_on(WHATSAPP_CHAT, _chat_list_ui())

    # The header is one control, not a list row.
    assert action_fastpath.press_check(
        press(28, "Someone Else"), session) is None
    # A row the command does not name.
    assert action_fastpath.press_check(press(15, "Chat 15"), session) is None
    # No press at all.
    assert action_fastpath.press_check(actions.parse_turn(turn([
        {"do": "wait_frontmost", "app": "WhatsApp"}])), session) is None


def test_a_parent_cycle_ends_the_walks_above_a_press():
    """Snapshots arrive over IPC; a malformed one may link parents in a
    loop. The walks for the check's STATE must still end."""
    by_index = {
        1: {"index": 1, "parent_index": 2, "role": "AXGroup", "label": "A"},
        2: {"index": 2, "parent_index": 1, "role": "AXGroup", "label": "B"},
        3: {"index": 3, "parent_index": 1, "role": "AXButton", "label": "C"},
    }

    ancestors = action_fastpath._labelled_ancestors(by_index[3], by_index)
    holder = action_fastpath._row_holding(by_index[3], [], by_index)

    assert [item["label"] for item in ancestors] == ["A", "B"]
    assert holder is None


@pytest.mark.parametrize(("effect", "goes_somewhere"), [
    (answer("navigate"), True),
    (answer("navigate", p=0.60), False),
    (answer("navigate", mass=0.30), False),
    (answer("answer"), False),
    (None, False),
])
def test_only_a_confident_navigate_skips_the_reviewer(effect, goes_somewhere):
    answers = {} if effect is None else {"effect": effect}

    assert action_fastpath.press_goes_somewhere(answers) is goes_somewhere


def test_a_later_turn_proposes_the_row_the_command_names():
    session = session_on(WHATSAPP_CHAT, _chat_list_ui())

    proposal = action_fastpath.propose(session)

    assert proposal.shape == action_fastpath.SHAPE_PRESS
    assert [question.key for question in proposal.questions] == [
        "next", "target"]
    assert 'Button "Shivangi Gupta"' in proposal.state
    # The selected row is where the app already is: pressing it moves
    # nothing forward, so it is never a candidate.
    assert 'Button "Someone Else"' not in proposal.state


def test_a_confident_press_answer_becomes_a_checked_press_turn():
    session = session_on(WHATSAPP_CHAT, _chat_list_ui())
    proposal = action_fastpath.propose(session)

    reply = action_fastpath.reply_for(
        session, proposal, decided(next="press", target="14").answers)

    assert reply == {"steps": [
        {"do": "wait_frontmost", "app": "WhatsApp"},
        {"do": "press_ui", "index": 14, "role": "AXButton",
         "label": "Shivangi Gupta"},
    ]}
    accepted = session.accept_reply(json.dumps(reply))
    assert accepted["steps"][-1]["index"] == 14


@pytest.mark.parametrize("answers", [
    {"next": answer("press", p=0.79), "target": answer("14")},
    {"next": answer("type"), "target": answer("14")},
    {"next": answer("press"), "target": answer("14", p=0.89)},
    {"next": answer("press"), "target": answer("none")},
    {"next": answer("press"), "target": answer("99")},
    {"next": answer("press")},
])
def test_an_unsure_or_unlisted_press_answer_falls_back(answers):
    session = session_on(WHATSAPP_CHAT, _chat_list_ui())
    proposal = action_fastpath.propose(session)

    assert action_fastpath.reply_for(session, proposal, answers) is None


@pytest.mark.parametrize("label", [
    "Heart", "Thumbs up", "Maybe", "Join", "Reply", "Vote", "Call",
    # Committing words are refused by the validator; never propose them.
    "Send", "Delete chat",
])
def test_reactions_answers_and_commits_are_never_candidates(label):
    ui = _chat_list_ui()
    ui["elements"].append(
        {"index": 50, "parent_index": 26, "depth": 2, "role": "AXButton",
         "label": label, "actions": ["AXPress"],
         "frame": {"x": 700, "y": 620, "w": 60, "h": 30}})
    session = session_on(f"{label} Shivangi Gupta", ui)

    proposal = action_fastpath.propose(session)

    assert f'"{label}"' not in proposal.state


def test_a_press_is_never_proposed_where_the_controller_must_read_history():
    """The questions carry no history: after a failed step, with `sends`
    true, or once two fast presses ran, the controller decides."""
    failed = session_on(WHATSAPP_CHAT, _chat_list_ui(),
                        failed_step="press_ui Shivangi Gupta: no change")
    assert action_fastpath.propose(failed) is None

    sending = session_for("send hi to Shivangi Gupta on WhatsApp", "WhatsApp")
    sending.accept_reply(turn([{"do": "open_app", "app": "WhatsApp"}],
                              goal="send hi", sends=True))
    sending.observation_message(observation(
        frontmost_app="WhatsApp", frontmost_bundle="net.whatsapp.WhatsApp",
        ui_snapshot=_chat_list_ui(), executed=["open_app WhatsApp"]))
    assert action_fastpath.propose(sending) is None

    spent = session_on(WHATSAPP_CHAT, _chat_list_ui())
    spent.fast_press_labels.update({"chat 15", "chat 16"})
    assert action_fastpath.propose(spent) is None


def test_a_refused_press_is_never_proposed_again():
    session = session_on(WHATSAPP_CHAT, _chat_list_ui())
    action_fastpath.record_refused(session, press(14, "Shivangi Gupta"))

    proposal = action_fastpath.propose(session)

    assert proposal is None or '"Shivangi Gupta"' not in proposal.state
    assert session.fast_press_labels == set(), "a refused press never ran"


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
        self.decision_timeouts: list[int | None] = []

    async def cleanup(self, raw, system_prompt, timeout_ms=None, **kwargs):
        self.timeouts.append(timeout_ms)
        return await super().cleanup(raw, system_prompt, timeout_ms, **kwargs)

    async def decide(self, state, questions, *, cancel_event=None,
                     max_input_tokens=None, timeout_ms=None, **_kwargs):
        assert max_input_tokens == actions.ACTION_MAX_INPUT_TOKENS
        assert cancel_event is not None
        self.decided.append([question.key for question in questions])
        self.decision_timeouts.append(timeout_ms)
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


# ---- server: presses on later turns --------------------------------------

REVIEWER = "independent UI-action reviewer"


async def start_on(client, transcript: str, ui: dict) -> None:
    """Start `transcript`, take the controller's turn 1 (open WhatsApp,
    `sends: false`), and show `ui` for turn 2."""
    await client.recv_event("ready")
    await send_start(client, transcript=transcript,
                     context={"frontmost_app": "Sublime Text",
                              "frontmost_bundle": "com.sublimetext.4",
                              "running_apps": ["WhatsApp", "Sublime Text"]})
    await client.recv_event("action_turn")
    await send_observe(client, observation=observation(
        frontmost_app="WhatsApp", frontmost_bundle="net.whatsapp.WhatsApp",
        ui_snapshot=ui, executed=["open_app WhatsApp"]))


def open_whatsapp(transcript: str) -> str:
    return turn([{"do": "open_app", "app": "WhatsApp"}],
                goal=transcript, sends=False)


def controller_press(index: int, label: str) -> str:
    return turn([{"do": "wait_frontmost", "app": "WhatsApp"},
                 {"do": "press_ui", "index": index, "role": "AXButton",
                  "label": label}])


POLL_COMMAND = "In WhatsApp, pick Friday in the offsite poll"


async def test_a_poll_option_the_command_names_goes_to_the_reviewer(engine):
    """A poll option is a list row like a chat row, and the command names
    it. Only the press check tells that pressing it votes."""
    eng, sock = engine
    eng.cleanup = DecidingPlanner(
        open_whatsapp(POLL_COMMAND), controller_press(41, "Friday"),
        json.dumps({"safe": True}),
        decisions=[decided(next="other"), decided(effect="answer")])
    client = await connect(sock)
    await start_on(client, POLL_COMMAND, _poll_ui())

    await client.recv_event("action_turn")

    assert eng.cleanup.decided == [["next", "target"], ["effect"]]
    assert REVIEWER in eng.cleanup.calls[2][1]


async def test_a_chat_row_checked_as_navigation_skips_the_reviewer(engine):
    eng, sock = engine
    eng.cleanup = DecidingPlanner(
        open_whatsapp(WHATSAPP_CHAT), controller_press(14, "Shivangi Gupta"),
        decisions=[decided(next="other"), decided(effect="navigate")])
    client = await connect(sock)
    await start_on(client, WHATSAPP_CHAT, _chat_list_ui())

    event = await client.recv_event("action_turn")

    assert event["steps"][-1]["label"] == "Shivangi Gupta"
    assert len(eng.cleanup.calls) == 2
    assert all(REVIEWER not in prompt for _, prompt in eng.cleanup.calls)
    # Every controller attempt can run one: its deadline is part of the
    # turn's worst case under the app's 150 s backstop.
    assert eng.cleanup.decision_timeouts[-1] == (
        action_fastpath.PRESS_CHECK_TIMEOUT_MS)


async def test_a_press_check_bug_sends_the_press_to_the_reviewer(
        engine, monkeypatch):
    """The check is a gate on an exemption: its own failure costs the
    exemption, never the action."""
    eng, sock = engine

    def broken(_parsed, _session):
        raise RuntimeError("press check bug")

    monkeypatch.setattr(action_fastpath, "press_check", broken)
    eng.cleanup = DecidingPlanner(
        open_whatsapp(WHATSAPP_CHAT), controller_press(14, "Shivangi Gupta"),
        json.dumps({"safe": True}),
        decisions=[decided(next="other")])
    client = await connect(sock)
    await start_on(client, WHATSAPP_CHAT, _chat_list_ui())

    event = await client.recv_event("action_turn")

    assert event["steps"][-1]["label"] == "Shivangi Gupta"
    assert REVIEWER in eng.cleanup.calls[2][1]


async def test_an_unavailable_press_check_goes_to_the_reviewer(engine):
    eng, sock = engine
    eng.cleanup = DecidingPlanner(
        open_whatsapp(WHATSAPP_CHAT), controller_press(14, "Shivangi Gupta"),
        json.dumps({"safe": True}),
        decisions=[decided(next="other"),
                   DecisionResult(STATUS_UNAVAILABLE, reason="timeout")])
    client = await connect(sock)
    await start_on(client, WHATSAPP_CHAT, _chat_list_ui())

    await client.recv_event("action_turn")

    assert REVIEWER in eng.cleanup.calls[2][1]


@pytest.mark.parametrize("model_id", [
    "mlx-community/Qwen3.5-4B-MLX-8bit",
    # No check runs on an uncalibrated tier, and this rule needs none.
    "mlx-community/Qwen3.5-2B-MLX-4bit",
])
async def test_a_row_in_a_calling_app_always_goes_to_the_reviewer(
        engine, model_id):
    """In FaceTime a person's row may place the call. The check's options
    name votes, RSVPs and reactions, not calls, so its "navigate" is no
    proof there."""
    eng, sock = engine
    command = "In FaceTime, open Shivangi Gupta"
    ui = _chat_list_ui()
    ui.update(app_name="FaceTime", bundle_id="com.apple.FaceTime",
              window_title="FaceTime")
    eng.cleanup = DecidingPlanner(
        turn([{"do": "open_app", "app": "FaceTime"}], goal=command,
             sends=False),
        turn([{"do": "wait_frontmost", "app": "FaceTime"},
              {"do": "press_ui", "index": 14, "role": "AXButton",
               "label": "Shivangi Gupta"}]),
        json.dumps({"safe": True}),
        decisions=[decided(effect="navigate")])
    eng.cleanup.model_id = model_id
    client = await connect(sock)
    await client.recv_event("ready")
    await send_start(client, transcript=command,
                     context={"frontmost_app": "Sublime Text",
                              "frontmost_bundle": "com.sublimetext.4",
                              "running_apps": ["FaceTime", "Sublime Text"]})
    await client.recv_event("action_turn")
    await send_observe(client, observation=observation(
        frontmost_app="FaceTime", frontmost_bundle="com.apple.FaceTime",
        ui_snapshot=ui, executed=["open_app FaceTime"]))

    await client.recv_event("action_turn")

    assert eng.cleanup.decided == []
    assert REVIEWER in eng.cleanup.calls[2][1]


async def test_an_uncalibrated_model_keeps_the_collection_exemption(engine):
    """Smaller tiers were never measured on the check. Sending them to the
    reviewer would break chat opening, which it refused 3 of 3 times."""
    eng, sock = engine
    eng.cleanup = DecidingPlanner(
        open_whatsapp(WHATSAPP_CHAT), controller_press(14, "Shivangi Gupta"))
    eng.cleanup.model_id = "mlx-community/Qwen3.5-2B-MLX-4bit"
    client = await connect(sock)
    await start_on(client, WHATSAPP_CHAT, _chat_list_ui())

    await client.recv_event("action_turn")

    assert eng.cleanup.decided == []
    assert len(eng.cleanup.calls) == 2


async def test_a_decided_chat_press_needs_no_generation(engine):
    eng, sock = engine
    eng.cleanup = DecidingPlanner(
        open_whatsapp(WHATSAPP_CHAT),
        decisions=[decided(next="press", target="14"),
                   decided(effect="navigate")])
    client = await connect(sock)
    await start_on(client, WHATSAPP_CHAT, _chat_list_ui())

    event = await client.recv_event("action_turn")

    assert [step["do"] for step in event["steps"]] == [
        "wait_frontmost", "press_ui"]
    assert event["steps"][1] == {
        "do": "press_ui", "snapshot": "snap-1", "index": 14,
        "role": "AXButton", "label": "Shivangi Gupta"}
    assert len(eng.cleanup.calls) == 1, "only turn 1 was generated"
    assert eng.cleanup.decided == [["next", "target"], ["effect"]]
    assert eng._action_session.fast_press_labels == {
        actions.normalized_term("Shivangi Gupta")}


PAUSE = turn([{"do": "wait_frontmost", "app": "WhatsApp"},
              {"do": "pause", "ms": 300}])


async def test_a_doubted_fast_press_runs_the_controller(engine):
    """A decided press the check doubts goes to the controller without a
    review: the guess was not obvious, so the controller reads the screen."""
    eng, sock = engine
    eng.cleanup = DecidingPlanner(
        open_whatsapp(WHATSAPP_CHAT), PAUSE,
        decisions=[decided(next="press", target="14"),
                   decided(effect="answer")])
    client = await connect(sock)
    await start_on(client, WHATSAPP_CHAT, _chat_list_ui())

    event = await client.recv_event("action_turn")

    assert [step["do"] for step in event["steps"]] == [
        "wait_frontmost", "pause"]
    assert all(REVIEWER not in prompt for _, prompt in eng.cleanup.calls)
    assert "You are the action agent" in eng.cleanup.calls[1][1]
    assert "Your previous reply was rejected" not in eng.cleanup.calls[1][1]
    session = eng._action_session
    assert session.fast_refused_labels == {
        actions.normalized_term("Shivangi Gupta")}
    assert session.fast_press_labels == set()


async def test_a_refused_fast_press_runs_the_controller(engine):
    """A decided press the reviewer refuses goes to the controller, never to
    the reviewer-refusal path that ends the action: no model has yet
    concluded the command cannot go on."""
    eng, sock = engine
    command = "show the Archived chats on WhatsApp"
    ui = _chat_list_ui()
    # One toolbar button, not a list row: its press is always reviewed.
    ui["elements"].append({
        "index": 50, "parent_index": 0, "depth": 1, "role": "AXButton",
        "label": "Archived", "actions": ["AXPress"],
        "frame": {"x": 10, "y": 60, "w": 280, "h": 30}})
    eng.cleanup = DecidingPlanner(
        open_whatsapp(command),
        json.dumps({"safe": False, "reason": "not navigation"}), PAUSE,
        decisions=[decided(next="press", target="50")])
    client = await connect(sock)
    await start_on(client, command, ui)

    event = await client.recv_event("action_turn")

    assert [step["do"] for step in event["steps"]] == [
        "wait_frontmost", "pause"]
    assert eng.cleanup.decided == [["next", "target"]]
    assert REVIEWER in eng.cleanup.calls[1][1]
    assert "You are the action agent" in eng.cleanup.calls[2][1]
    assert "Your previous reply was rejected" not in eng.cleanup.calls[2][1]
    session = eng._action_session
    assert session.fast_refused_labels == {actions.normalized_term("Archived")}
    assert session.fast_press_labels == set()


async def test_a_turn_that_already_ran_long_skips_the_fast_press(
        engine, monkeypatch):
    """A decision and its review on top of the controller's worst case must
    fit the app's 150 s backstop."""
    from velora_engine import server
    monkeypatch.setattr(server, "_FAST_ATTEMPT_MAX_ELAPSED_S", 0.0)
    eng, sock = engine
    eng.cleanup = DecidingPlanner(open_whatsapp(WHATSAPP_CHAT), PAUSE)
    client = await connect(sock)
    await start_on(client, WHATSAPP_CHAT, _chat_list_ui())

    await client.recv_event("action_turn")

    assert eng.cleanup.decided == []
