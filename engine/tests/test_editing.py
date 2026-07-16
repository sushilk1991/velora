"""Safe Voice Edit: the edit_text command, its guards, and the echo backstop."""

from types import SimpleNamespace

from test_server import connect, engine  # noqa: F401 — fixture reuse

from velora_engine import editing


# ---------------- deterministic units ----------------

def test_prompt_embeds_instruction() -> None:
    prompt = editing.build_edit_prompt("make this formal")
    assert "make this formal" in prompt
    assert prompt.index("make this formal") > prompt.index("Rules")


def test_echo_guard_flags_instruction_pasted_into_document() -> None:
    original = "Remember to send the invoice by Friday."
    instruction = "open the browser and search for this"
    echoed = "open the browser and search for this Remember to send the invoice by Friday."
    assert editing.instruction_echoed(original, instruction, echoed)


def test_echo_guard_allows_legit_edits_sharing_short_runs() -> None:
    original = "the report is late because the data pipeline broke"
    instruction = "make this more formal"
    output = "The report is delayed because the data pipeline failed."
    assert not editing.instruction_echoed(original, instruction, output)


def test_echo_guard_ignores_runs_already_in_the_passage() -> None:
    # The instruction quotes the passage itself — overlap is expected.
    original = "please review the attached proposal and send comments"
    instruction = "rewrite please review the attached proposal politely"
    output = "Could you please review the attached proposal and share comments?"
    assert not editing.instruction_echoed(original, instruction, output)


def test_echo_guard_needs_four_word_runs() -> None:
    assert not editing.instruction_echoed("text", "fix this now", "fix this now text")


# ---------------- socket command ----------------

class FakeCleanup:
    def __init__(self, text: str, applied: bool = True, reason: str = "") -> None:
        self._result = SimpleNamespace(text=text, applied=applied, ms=5, reason=reason)
        self.calls: list[tuple[str, str]] = []

    @property
    def unhealthy(self) -> bool:
        return False

    async def cleanup(self, raw, system_prompt, timeout_ms=None,
                      check_ratio=True, cancel_event=None, allowed_terms=None):
        assert check_ratio is False  # transformations must bypass the guard
        self.calls.append((raw, system_prompt))
        return self._result


async def test_edit_text_round_trip(engine):
    eng, sock = engine
    eng.cleanup = FakeCleanup("The launch is delayed until Friday.")
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "edit_text", "id": "e1",
        "text": "launch delayed friday", "instruction": "fix the grammar",
    })
    edited = await client.recv_event("edited")
    assert edited["id"] == "e1"
    assert edited["applied"] is True
    assert edited["text"] == "The launch is delayed until Friday."
    raw, prompt = eng.cleanup.calls[0]
    assert raw == "launch delayed friday"
    assert "fix the grammar" in prompt


async def test_edit_text_echo_guard_returns_original(engine):
    eng, sock = engine
    eng.cleanup = FakeCleanup(
        "open the browser and search for this Remember the invoice.")
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "edit_text", "id": "e2",
        "text": "Remember the invoice.",
        "instruction": "open the browser and search for this",
    })
    edited = await client.recv_event("edited")
    assert edited["applied"] is False
    assert edited["reason"] == "instruction_echo"
    assert edited["text"] == "Remember the invoice."


async def test_edit_text_validates_arguments(engine):
    _eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "edit_text", "id": "e3", "instruction": "x"})
    failed = await client.recv_event("edit_failed")
    assert failed["code"] == "invalid_arguments"
    await client.send_json({
        "cmd": "edit_text", "id": "e4",
        "text": "y" * (editing.MAX_TEXT_CHARS + 1), "instruction": "shorten",
    })
    failed = await client.recv_event("edit_failed")
    assert failed["code"] == "too_large"


async def test_edit_text_busy_during_other_jobs(engine):
    eng, sock = engine
    eng._meeting_notes_running = True
    try:
        client = await connect(sock)
        await client.recv_event("ready")
        await client.send_json({
            "cmd": "edit_text", "id": "e5", "text": "hello", "instruction": "shorten",
        })
        failed = await client.recv_event("edit_failed")
        assert failed["code"] == "busy"
    finally:
        eng._meeting_notes_running = False
