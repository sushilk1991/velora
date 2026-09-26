import pytest
from fixtures.fake_cleanup_worker import PID_DIR_ENV, kill_leaked

import velora_engine.cleanup_process as cleanup_process_mod
from velora_engine import batch_priority, diarization
from velora_engine.config import Config


@pytest.fixture(autouse=True, scope="session")
def no_leaked_fake_workers(tmp_path_factory):
    """SIGKILL every fake cleanup worker this run started that still lives.

    A test that ends with its worker wedged (SIGTERM ignored, SIGKILL patched
    to land late) would otherwise leave it running after pytest exits.
    Workers register their pids in PID_DIR_ENV, which they inherit.
    """
    pid_dir = tmp_path_factory.mktemp("fake-worker-pids")
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv(PID_DIR_ENV, str(pid_dir))
        yield
    kill_leaked(pid_dir)


@pytest.fixture(autouse=True)
def forget_retired_workers():
    """The retired-worker registry is process-wide. A worker whose test loop
    closed before it exited would otherwise hold the next test's spawns, in
    any module that runs a real CleanupProcess."""
    yield
    cleanup_process_mod._retired_workers.clear()


@pytest.fixture(autouse=True)
def no_diarization_downloads(monkeypatch):
    """Keep unit tests off the network.

    Meeting transcription of a 'them' track plans via diarization when the
    backend is importable — in a test home with no cached models that means a
    46MB GitHub download with 60s urlopen timeouts, turning the resume tests
    into network-dependent multi-minute flakes. Tests of the diarized path
    re-patch `available`/`ensure_models`/`diarize` explicitly.
    """
    monkeypatch.setattr(diarization, "available", lambda: False)


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
