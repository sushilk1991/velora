"""Action Mode skills: fixed plans for commands whose steps are known."""

# ruff: noqa: F811

from __future__ import annotations

import json

import pytest
from test_action_fastpath import DecidingPlanner, session_for
from test_actions import send_start
from test_server import connect, engine  # noqa: F401 — fixture reuse

from velora_engine import action_skills, actions

LOFI = "Can you open YouTube and play Bollywood Lo-Fi music for me?"
LOFI_URL = ("https://www.youtube.com/results"
            "?search_query=Bollywood+Lo-Fi+music")


# ---- which commands are "play X on YouTube" -------------------------------

@pytest.mark.parametrize(("transcript", "query"), [
    (LOFI, "Bollywood Lo-Fi music"),
    ("Play Arijit Singh songs on YouTube", "Arijit Singh songs"),
    ("play lofi beats on youtube please", "lofi beats"),
    ("YouTube, play Despacito", "Despacito"),
    ("Open YouTube and play some jazz", "some jazz"),
    ("please play Kishore Kumar hits on YouTube.", "Kishore Kumar hits"),
    ("Go to YouTube and play Coke Studio", "Coke Studio"),
    # "then" between the two halves: the 2026-09-28 17:13 live failure.
    ("Can you open YouTube and then play any pop song latest 2026 pop songs?",
     "any pop song latest 2026 pop songs"),
    ("Open YouTube, then play Despacito", "Despacito"),
    ("open YouTube then play lofi", "lofi"),
    # A hyphen inside a word is not a clause break.
    ("play Lo-Fi beats on YouTube", "Lo-Fi beats"),
])
def test_a_youtube_play_command_yields_its_query(transcript, query):
    assert action_skills.youtube_play_query(transcript) == query


@pytest.mark.parametrize("transcript", [
    "Open YouTube",
    # A search is one open_url and done: the controller's rule 1.
    "search YouTube for cat videos",
    # Compound commands deliver something: the controller's.
    "play Despacito on YouTube and send it to Priya",
    "open YouTube and play Despacito and share it with Rahul",
    # Another app.
    "play Despacito on YouTube Music",
    "play Despacito",
    "pause YouTube",
    # Deictic: the user means what is already on screen.
    "play this video on YouTube",
    "play it on YouTube",
    "open YouTube and play the first video",
    "open YouTube and then play it",
    # A comma-joined second task is still a compound command (review, 0.28).
    "YouTube, play lofi, text it to Priya",
    "Open YouTube and play lofi, WhatsApp it to Priya",
    "play lofi on YouTube; delete my watch history",
    "YouTube, play lofi, subscribe to the channel",
    "play lofi then subscribe on YouTube",
    # So is one after a sentence break or a spaced dash (review, 0.28).
    "Open YouTube and play lofi. Text it to Priya.",
    "YouTube, play lofi. Delete my watch history.",
    "YouTube, play lofi? Text it to Priya",
    "YouTube, play lofi - text it to Priya",
    "YouTube, play lofi — text it to Priya",
])
def test_anything_else_is_left_to_the_planner(transcript):
    assert action_skills.youtube_play_query(transcript) is None


# ---- the skill's turn ------------------------------------------------------

def test_the_skill_opens_the_results_and_plays_the_first_video():
    session = session_for(LOFI, "Google Chrome")

    reply = action_skills.reply_for(session)
    accepted = session.accept_reply(json.dumps(reply))

    assert accepted == {"steps": [
        {"do": "open_url", "url": LOFI_URL},
        {"do": "play_first_video"},
    ], "done": True}
    assert session.sends is False


def test_the_skill_takes_only_the_first_turn():
    session = session_for(LOFI, "Google Chrome")
    session.accept_reply(json.dumps(action_skills.reply_for(session)))

    assert action_skills.reply_for(session) is None


def test_a_non_skill_command_gets_no_skill_turn():
    assert action_skills.reply_for(
        session_for("Open Calculator", "Calculator")) is None


# ---- the validator: play_first_video only right after its results page ----

def plan(*steps: dict) -> dict:
    return {"goal": "play", "sends": False, "steps": list(steps)}


def lofi_state() -> actions.SessionState:
    return actions.SessionState(spoken_command=LOFI)


def test_play_first_video_after_its_results_page_validates():
    validated = actions.validate_plan(plan(
        {"do": "open_url", "url": LOFI_URL},
        {"do": "play_first_video"},
    ), lofi_state())

    assert validated["steps"][-1] == {"do": "play_first_video"}


@pytest.mark.parametrize(("steps", "error"), [
    ([{"do": "play_first_video"}], "YouTube results"),
    ([{"do": "open_url", "url": "https://www.google.com/search?q=lofi"},
      {"do": "play_first_video"}], "YouTube results"),
    ([{"do": "open_url", "url": LOFI_URL},
      {"do": "play_first_video"},
      {"do": "pause", "ms": 100}], "last step"),
    ([{"do": "open_url", "url": LOFI_URL},
      {"do": "play_first_video", "index": 3}], "unsupported mechanics"),
])
def test_play_first_video_anywhere_else_is_refused(steps, error):
    with pytest.raises(actions.PlanError, match=error):
        actions.validate_plan(plan(*steps), lofi_state())


def test_play_first_video_needs_a_spoken_youtube_play_command():
    with pytest.raises(actions.PlanError, match="spoken command"):
        actions.validate_plan(plan(
            {"do": "open_url", "url": LOFI_URL},
            {"do": "play_first_video"},
        ), actions.SessionState(spoken_command="search YouTube for lofi"))


# ---- server: the skill needs no model --------------------------------------

async def test_a_youtube_play_command_needs_no_model(engine):
    eng, sock = engine
    eng.cleanup = DecidingPlanner()
    # Skills are rules, not calibrated probabilities: any tier gets them.
    eng.cleanup.model_id = "mlx-community/Qwen3.5-2B-MLX-4bit"
    client = await connect(sock)
    await client.recv_event("ready")
    await send_start(client, transcript=LOFI,
                     context={"frontmost_app": "Orca",
                              "running_apps": ["Google Chrome", "Orca"]})

    event = await client.recv_event("action_turn")

    assert event["steps"] == [
        {"do": "open_url", "url": LOFI_URL},
        {"do": "play_first_video"},
    ]
    assert event["done"] is True
    assert event["sends"] is False
    assert eng.cleanup.calls == []
    assert eng.cleanup.decided == []
