import pytest

from velora_engine.config import Config


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
