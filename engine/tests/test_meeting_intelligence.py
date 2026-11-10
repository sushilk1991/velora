"""Chapters cite real transcript blocks; no synthetic word timestamps."""
from velora_engine.meeting_intelligence import chapters_in_chunk, prepare_passages, validate_chapters
from velora_engine.meeting_notes import parse_notes_json, merge_notes


def passages():
    return [
        {"key": "me:0", "text": "The launch budget is approved.", "start_ms": 0, "end_ms": 60000},
        {"key": "them:0", "text": "We will prepare the launch plan.", "start_ms": 1000, "end_ms": 61000},
        {"key": "me:1", "text": "Now the onboarding issue: simplify the welcome screen.", "start_ms": 60000, "end_ms": 120000},
    ]


def test_chapters_keep_actual_block_ranges_and_source_text():
    result = validate_chapters([
        {"title": "Launch budget and plan", "start_key": "me:0", "end_key": "them:0"},
        {"title": "Simplify onboarding", "start_key": "me:1", "end_key": "me:1"},
    ], passages())
    assert [c["title"] for c in result] == ["Launch budget and plan", "Simplify onboarding"]
    assert result[0]["startText"] == "The launch budget is approved."
    assert result[0]["endText"] == "We will prepare the launch plan."
    assert result[1]["startKey"] == "me:1"


def test_model_may_copy_displayed_at_marker_without_losing_valid_chapters():
    proposals = [
        {"title": "Launch", "start_key": "@me:0", "end_key": "@them:0"},
        {"title": "Unknown", "start_key": "@missing", "end_key": "@missing"},
    ]
    visible = chapters_in_chunk(proposals, "[@me:0] Launch\n[@them:0] Plan")
    result = validate_chapters(visible, passages())
    assert len(result) == 1
    assert result[0]["startKey"] == "me:0" and result[0]["endKey"] == "them:0"


def test_chapters_reject_unknown_reversed_duplicate_and_overlapping_sources():
    candidates = [
        {"title": "Invented", "start_key": "missing", "end_key": "me:1"},
        {"title": "Reversed", "start_key": "me:1", "end_key": "me:0"},
        {"title": "Launch", "start_key": "me:0", "end_key": "them:0"},
        {"title": "Duplicate checkpoint", "start_key": "me:0", "end_key": "them:0"},
        {"title": "Overlapping", "start_key": "them:0", "end_key": "me:1"},
    ]
    assert len(validate_chapters(candidates, passages())) == 1


def test_invalid_passages_cannot_create_chapters():
    assert prepare_passages([{"key": "me:0", "text": "", "start_ms": 0, "end_ms": 1}]) == []
    assert prepare_passages(passages() + [passages()[0]]) == []
    assert validate_chapters([], passages()) == []
    assert validate_chapters([{"title": "Anything", "start_key": "me:0", "end_key": "me:0"}], []) == []


def test_optional_chapters_survive_map_merge_but_legacy_notes_keep_contract():
    legacy = '{"summary":"S","decisions":[],"action_items":[]}'
    assert parse_notes_json(legacy) == {"summary": "S", "decisions": [], "action_items": []}
    value = parse_notes_json(legacy[:-1] + ',"chapters":[{"title":"Launch", "start_key":"me:0", "end_key":"them:0"}]}')
    assert value and merge_notes([value])["chapters"] == value["chapters"]
    assert parse_notes_json(legacy[:-1] + ',"chapters":"bad"}') is None



def test_untrusted_chapter_keys_and_titles_are_ignored():
    assert validate_chapters([
        {"title": "Bad", "start_key": ["me:0"], "end_key": "me:0"},
        {"title": "Bad", "start_key": "me:0", "end_key": {}},
        {"title": "x" * 161, "start_key": "me:0", "end_key": "me:0"},
    ], passages()) == []
    assert prepare_passages([dict(passages()[0], key="../../outside")]) == []

# Use the isolated engine fixture, including its temporary VELORA_HOME.
import asyncio
import json
from types import SimpleNamespace
from test_server import connect, engine  # noqa: F401


async def test_note_model_proposes_semantic_chapters_with_verified_sources(engine):
    eng, sock = engine
    seen = []

    class Cleanup:
        loaded = True
        unhealthy = False

        async def cleanup(self, raw, system_prompt, **kwargs):
            seen.append((raw, system_prompt))
            return SimpleNamespace(applied=True, text=json.dumps({
                "summary": "Launch approved; onboarding needs simplification.",
                "decisions": ["Approve launch budget"], "action_items": [],
                "chapters": [
                    {"title": "Launch approval", "start_key": "me:0", "end_key": "them:0"},
                    {"title": "Unsupported", "start_key": "invented", "end_key": "invented"},
                    {"title": "Onboarding", "start_key": "me:1", "end_key": "me:1"},
                ],
            }))

    eng.cleanup = Cleanup()
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "meeting_notes", "id": "chapters", "meeting_id": "meeting",
                            "transcript": "A real meeting.", "passages": passages()})
    await client.recv_event("meeting_notes_accepted")
    ready = await client.recv_event("meeting_notes_ready")
    assert [c["title"] for c in ready["chapters"]] == ["Launch approval", "Onboarding"]
    assert ready["chapters"][0]["startText"] == passages()[0]["text"]
    assert "[@me:0]" in seen[0][0]
    assert "never fixed time intervals" in seen[0][1]
    assert not eng._meeting_notes_running


async def test_cancelled_chapter_generation_has_no_ready_result(engine):
    eng, sock = engine
    entered, release = asyncio.Event(), asyncio.Event()

    class Cleanup:
        loaded = True
        unhealthy = False

        async def cleanup(self, raw, system_prompt, **kwargs):
            entered.set()
            await release.wait()
            return SimpleNamespace(applied=True, text=json.dumps({
                "summary": "S", "decisions": [], "action_items": [],
                "chapters": [{"title": "Launch", "start_key": "me:0", "end_key": "them:0"}],
            }))

    eng.cleanup = Cleanup()
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "meeting_notes", "id": "cancel-chapters", "meeting_id": "meeting",
                            "transcript": "A real meeting.", "passages": passages()})
    await client.recv_event("meeting_notes_accepted")
    await asyncio.wait_for(entered.wait(), timeout=2)
    await client.send_json({"cmd": "meeting_notes_cancel", "id": "cancel-chapters"})
    # The command must be processed before the in-flight model returns.
    for _ in range(100):
        if eng._meeting_notes_cancel:
            break
        await asyncio.sleep(0.01)
    assert eng._meeting_notes_cancel
    release.set()
    failed = await client.recv_event("meeting_notes_failed")
    assert failed["code"] == "cancelled"
    assert not eng._meeting_notes_running


def test_adjacent_same_topics_merge_without_duplicate_checkpoint_chapters():
    result = validate_chapters([
        {"title": "Launch", "start_key": "me:0", "end_key": "me:0"},
        {"title": "launch", "start_key": "them:0", "end_key": "them:0"},
    ], passages())
    assert len(result) == 1 and result[0]["endKey"] == "them:0"


def test_model_chapters_must_cite_only_the_chunk_it_saw():
    assert chapters_in_chunk([
        {"title": "Launch", "start_key": "me:0", "end_key": "me:0"},
        {"title": "Unseen real block", "start_key": "me:0", "end_key": "me:1"},
        {"title": "Malformed", "start_key": [], "end_key": {}},
    ], "[@me:0] A launch discussion") == [
        {"title": "Launch", "start_key": "me:0", "end_key": "me:0"}]


async def test_foreground_preemption_retries_same_chapter_context(engine):
    eng, sock = engine
    calls = []

    class Cleanup:
        loaded = True
        unhealthy = False

        async def cleanup(self, raw, system_prompt, **kwargs):
            calls.append(raw)
            if len(calls) == 1:
                eng._meeting_notes_preempt.set()
            return SimpleNamespace(applied=True, text=json.dumps({
                "summary": "Launch approved", "decisions": [], "action_items": [],
                "chapters": [{"title": "Launch", "start_key": "me:0", "end_key": "them:0"}],
            }))

    eng.cleanup = Cleanup()
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "meeting_notes", "id": "preempt", "meeting_id": "meeting",
                            "transcript": "A real meeting.", "passages": passages()})
    await client.recv_event("meeting_notes_accepted")
    ready = await client.recv_event("meeting_notes_ready")
    assert len(calls) == 2 and calls[0] == calls[1]
    assert len(ready["chapters"]) == 1
    assert not eng._meeting_notes_running


async def test_chapter_schema_error_still_reports_notes_failure(engine):
    eng, sock = engine

    class Cleanup:
        loaded = True
        unhealthy = False

        async def cleanup(self, raw, system_prompt, **kwargs):
            return SimpleNamespace(applied=True, text='{"summary":42,"chapters":[]}')

    eng.cleanup = Cleanup()
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "meeting_notes", "id": "invalid", "meeting_id": "meeting",
                            "transcript": "A real meeting.", "passages": passages()})
    await client.recv_event("meeting_notes_accepted")
    failed = await client.recv_event("meeting_notes_failed")
    assert failed["code"] == "generation_failed"
    assert not eng._meeting_notes_running
