import pytest

from velora_engine import batch_priority
from velora_engine.config import Config


@pytest.fixture(autouse=True)
def no_darwin_background(monkeypatch):
    """Neutralize batch-job process demotion under pytest.

    Engine batch jobs demote the *engine* process to Darwin background — in
    tests that is the pytest process itself, and the resulting timer
    throttling turns fast event-loop tests into multi-minute timeouts.
    Batch-priority tests bypass this via a from-import of the real function.
    """
    monkeypatch.setattr(
        batch_priority, "set_background", lambda pid, background: False)


@pytest.fixture
def home(tmp_path, monkeypatch):
    """Isolated ~/.velora for tests."""
    monkeypatch.setenv("VELORA_HOME", str(tmp_path / "velora-home"))
    return tmp_path / "velora-home"


@pytest.fixture
def config(home):
    return Config()


@pytest.fixture
def fake_stt(monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT", "1")
