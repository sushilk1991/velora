"""Tests for the privacy-safe installed-runtime audio replay benchmark."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import subprocess
import sys
from types import ModuleType

import pytest


ENGINE_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ENGINE_ROOT / "scripts" / "benchmark_installed_replay.py"
REQUIRED_STT = "mlx-community/whisper-large-v3-turbo"
REQUIRED_CLEANUP = "mlx-community/Qwen3.5-4B-MLX-8bit"


def _load_script() -> ModuleType:
    assert SCRIPT.is_file(), "installed replay benchmark script has not been implemented"
    spec = importlib.util.spec_from_file_location("benchmark_installed_replay", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _manifest(audio: str = "clips/sample.flac") -> dict:
    return {
        "schema_version": 1,
        "privacy": {"transcript_text_included": False},
        "cases": [
            {
                "case_id": "history-7",
                "audio": audio,
                "mode": "Note",
                "duration_ms": 12_345,
                "duration_bucket": "10_to_25s",
            }
        ],
    }


def _write_manifest(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload), encoding="utf-8")


def _models() -> dict[str, object]:
    return {
        "source": "installed_status_plus_readonly_config",
        "stt_model": REQUIRED_STT,
        "cleanup_model": REQUIRED_CLEANUP,
        "cleanup_enabled": True,
        "app_running": True,
        "engine_ready": True,
        "access_enabled": True,
        "transcribe_capable": True,
    }


def _clock(*values: float):
    iterator = iter(values)
    return lambda: next(iterator)


def test_manifest_accepts_only_existing_relative_files_inside_explicit_root(tmp_path):
    module = _load_script()
    audio_root = tmp_path / "private-audio"
    clip = audio_root / "clips" / "sample.flac"
    clip.parent.mkdir(parents=True)
    clip.write_bytes(b"synthetic audio")
    manifest = tmp_path / "manifest.json"
    _write_manifest(manifest, _manifest())

    cases = module.load_manifest(manifest, audio_root)

    assert len(cases) == 1
    assert cases[0].case_id == "history-7"
    assert cases[0].audio_path == clip.resolve()
    assert cases[0].mode == "Note"
    assert cases[0].duration_ms == 12_345


@pytest.mark.parametrize("audio", ["/private/absolute.flac", "../escape.flac"])
def test_manifest_rejects_absolute_and_traversal_audio_without_echoing_it(
    tmp_path, audio
):
    module = _load_script()
    audio_root = tmp_path / "private-audio-CANARY-a031"
    audio_root.mkdir()
    manifest = tmp_path / "manifest.json"
    _write_manifest(manifest, _manifest(audio))

    with pytest.raises(module.BenchmarkError) as raised:
        module.load_manifest(manifest, audio_root)

    message = str(raised.value)
    assert audio not in message
    assert str(audio_root) not in message
    assert "history-7" in message


def test_manifest_rejects_a_symlink_that_resolves_outside_audio_root(tmp_path):
    module = _load_script()
    audio_root = tmp_path / "private-audio"
    audio_root.mkdir()
    outside = tmp_path / "SECRET-OUTSIDE-audio.flac"
    outside.write_bytes(b"private")
    (audio_root / "escape.flac").symlink_to(outside)
    manifest = tmp_path / "manifest.json"
    _write_manifest(manifest, _manifest("escape.flac"))

    with pytest.raises(module.BenchmarkError) as raised:
        module.load_manifest(manifest, audio_root)

    assert str(outside) not in str(raised.value)
    assert "history-7" in str(raised.value)


def test_model_proof_uses_installed_status_and_read_only_config(tmp_path):
    module = _load_script()
    cli = tmp_path / "velora"
    cli.write_bytes(b"synthetic executable")
    config = tmp_path / "config.json"
    config.write_text(
        json.dumps(
            {
                "stt_model": REQUIRED_STT,
                "cleanup_model": REQUIRED_CLEANUP,
                "cleanup_enabled": True,
            }
        ),
        encoding="utf-8",
    )
    before = config.read_bytes()
    observed: list[str] = []

    def status_runner(command, **kwargs):
        observed.extend(command)
        assert kwargs["capture_output"] is True
        assert kwargs["text"] is True
        assert kwargs["timeout"] == 2
        return subprocess.CompletedProcess(
            command,
            0,
            stdout=json.dumps({
                "app_running": True,
                "engine_ready": True,
                "access_enabled": True,
                "capabilities": ["transcribe"],
            }),
            stderr="",
        )

    proof = module.read_installed_model_proof(
        config_path=config,
        cli_path=cli,
        timeout_s=2,
        command_runner=status_runner,
    )

    assert observed == [str(cli), "status", "--json"]
    assert proof == _models()
    assert config.read_bytes() == before


@pytest.mark.parametrize(
    "status",
    [
        {**_models(), "stt_model": "mlx-community/whisper-small"},
        {**_models(), "cleanup_model": "mlx-community/Qwen3.5-2B-MLX-8bit"},
        {**_models(), "cleanup_enabled": False},
        {**_models(), "engine_ready": False},
        {**_models(), "app_running": False},
        {**_models(), "access_enabled": False},
        {**_models(), "transcribe_capable": False},
    ],
)
def test_benchmark_refuses_to_run_without_the_exact_required_model_pair(
    tmp_path, status
):
    module = _load_script()
    audio_root = tmp_path / "audio"
    audio_root.mkdir()
    (audio_root / "sample.flac").write_bytes(b"audio")
    manifest = tmp_path / "manifest.json"
    _write_manifest(manifest, _manifest("sample.flac"))
    called = False

    def forbidden_runner(*_args, **_kwargs):
        nonlocal called
        called = True
        raise AssertionError("transcription must not start")

    with pytest.raises(module.ModelRefusalError, match="required model pair"):
        module.run_benchmark(
            manifest_path=manifest,
            audio_root=audio_root,
            output_path=tmp_path / "result.json",
            repeats=1,
            timeout_s=10,
            status_provider=lambda: status,
            command_runner=forbidden_runner,
            clock=_clock(0, 1),
        )

    assert called is False
    assert not (tmp_path / "result.json").exists()


def test_cli_output_is_hashed_in_memory_and_never_retained_or_mislabeled(tmp_path):
    module = _load_script()
    audio_root = tmp_path / "PRIVATE-AUDIO-ROOT-83c1"
    audio_root.mkdir()
    clip = audio_root / "PRIVATE-CLIP-f43b.flac"
    clip.write_bytes(b"audio")
    transcript = "TRANSCRIPT-CANARY-5f0a café 👋"
    cases = module.load_manifest(
        _make_manifest_file(tmp_path, _manifest(clip.name)), audio_root
    )
    observed_command: list[str] = []

    def command_runner(command, **kwargs):
        observed_command.extend(command)
        assert kwargs["capture_output"] is True
        assert kwargs["text"] is True
        assert kwargs["timeout"] == 9
        return subprocess.CompletedProcess(
            command,
            0,
            stdout=json.dumps(
                {
                    "text": transcript,
                    "path": str(clip),
                    "duration_ms": 12_300,
                    # Current server measures this around the whole file job,
                    # including explicit-mode cleanup. It is not STT-only.
                    "stt_ms": 777,
                    "mode": "Note",
                }
            ),
            stderr="",
        )

    result = module.run_case(
        cases[0],
        repeat=2,
        cli_path=Path("/Applications/Velora.app/Contents/Resources/bin/velora"),
        timeout_s=9,
        command_runner=command_runner,
        clock=_clock(10.0, 11.25),
    )

    assert observed_command == [
        "/Applications/Velora.app/Contents/Resources/bin/velora",
        "transcribe",
        str(clip.resolve()),
        "--mode",
        "Note",
        "--json",
    ]
    assert result == {
        "repeat": 2,
        "wall_ms": 1_250,
        "engine_total_inference_ms": 777,
        "character_count": len(transcript),
        "text_sha256": hashlib.sha256(transcript.encode("utf-8")).hexdigest(),
    }
    emitted = json.dumps(result, ensure_ascii=False)
    assert transcript not in emitted
    assert str(clip) not in emitted
    assert "stt_ms" not in result
    assert "cleanup_ms" not in result


def _make_manifest_file(tmp_path: Path, payload: dict) -> Path:
    path = tmp_path / "manifest.json"
    _write_manifest(path, payload)
    return path


def test_subprocess_timeout_is_sanitized_and_does_not_leave_output(tmp_path):
    module = _load_script()
    audio_root = tmp_path / "PRIVATE-ROOT-CANARY-6a0c"
    audio_root.mkdir()
    clip = audio_root / "PRIVATE-FILE-CANARY-6bb2.flac"
    clip.write_bytes(b"audio")
    manifest = _make_manifest_file(tmp_path, _manifest(clip.name))
    transcript = "TIMEOUT-TRANSCRIPT-CANARY-b17a"

    def timeout_runner(command, **_kwargs):
        raise subprocess.TimeoutExpired(command, 3, output=transcript, stderr=str(clip))

    with pytest.raises(module.BenchmarkError) as raised:
        module.run_benchmark(
            manifest_path=manifest,
            audio_root=audio_root,
            output_path=tmp_path / "result.json",
            repeats=1,
            timeout_s=3,
            status_provider=_models,
            command_runner=timeout_runner,
            clock=_clock(0),
        )

    message = str(raised.value)
    assert "timed out" in message
    assert transcript not in message
    assert str(clip) not in message
    assert not (tmp_path / "result.json").exists()


def test_subprocess_error_and_invalid_json_are_sanitized(tmp_path):
    module = _load_script()
    audio_root = tmp_path / "PRIVATE-ROOT-CANARY-1f12"
    audio_root.mkdir()
    clip = audio_root / "PRIVATE-FILE-CANARY-c22d.flac"
    clip.write_bytes(b"audio")
    case = module.load_manifest(
        _make_manifest_file(tmp_path, _manifest(clip.name)), audio_root
    )[0]
    transcript = "ERROR-TRANSCRIPT-CANARY-061b"

    def failed(command, **_kwargs):
        return subprocess.CompletedProcess(
            command, 7, stdout=transcript, stderr=f"failed for {clip}"
        )

    with pytest.raises(module.BenchmarkError) as failed_error:
        module.run_case(
            case,
            repeat=1,
            cli_path=Path("/Applications/Velora.app/Contents/Resources/bin/velora"),
            timeout_s=5,
            command_runner=failed,
            clock=_clock(0, 1),
        )
    assert "exit 7" in str(failed_error.value)
    assert transcript not in str(failed_error.value)
    assert str(clip) not in str(failed_error.value)

    def invalid_json(command, **_kwargs):
        return subprocess.CompletedProcess(
            command, 0, stdout=f"not-json {transcript} {clip}", stderr=""
        )

    with pytest.raises(module.BenchmarkError) as json_error:
        module.run_case(
            case,
            repeat=1,
            cli_path=Path("/Applications/Velora.app/Contents/Resources/bin/velora"),
            timeout_s=5,
            command_runner=invalid_json,
            clock=_clock(0, 1),
        )
    assert "invalid JSON" in str(json_error.value)
    assert transcript not in str(json_error.value)
    assert str(clip) not in str(json_error.value)


def test_repeat_report_aggregates_wall_and_available_phase_metrics_only(tmp_path):
    module = _load_script()
    audio_root = tmp_path / "audio"
    audio_root.mkdir()
    clip = audio_root / "sample.flac"
    clip.write_bytes(b"audio")
    case = module.load_manifest(
        _make_manifest_file(tmp_path, _manifest(clip.name)), audio_root
    )[0]
    runs = [
        {
            "repeat": 1,
            "wall_ms": 100,
            "engine_total_inference_ms": 80,
            "character_count": 10,
            "text_sha256": "a" * 64,
        },
        {
            "repeat": 2,
            "wall_ms": 300,
            "engine_total_inference_ms": None,
            "character_count": 12,
            "text_sha256": "b" * 64,
        },
    ]

    report = module.build_report([case], {case.case_id: runs}, repeats=2, status=_models())

    item = report["cases"][0]
    assert item["case_id"] == "history-7"
    assert item["duration_ms"] == 12_345
    assert item["mode"] == "Note"
    assert item["runs"] == runs
    assert item["metrics"]["wall_ms"]["p50"] == 200
    assert item["metrics"]["wall_ms"]["p95"] == 290
    assert item["metrics"]["engine_total_inference_ms"]["available"] == 1
    assert item["metrics"]["engine_total_inference_ms"]["missing"] == 1
    assert report["aggregate"]["wall_ms"]["p50"] == 200
    assert report["aggregate"]["engine_total_inference_ms"]["available"] == 1
    assert report["model_proof"]["stt_model"] == REQUIRED_STT
    assert report["model_proof"]["source"] == "installed_status_plus_readonly_config"
    assert report["model_proof"]["engine_ready"] is True
    assert report["model_proof"]["transcribe_capable"] is True
    assert report["metric_semantics"]["engine_total_inference_ms"].startswith(
        "CLI stt_ms is total"
    )
    serialized = json.dumps(report)
    assert str(clip) not in serialized
    assert "audio" not in report["cases"][0]


def test_private_result_is_atomically_written_owner_only(tmp_path):
    module = _load_script()
    output = tmp_path / "result.json"
    output.write_text("old", encoding="utf-8")
    output.chmod(0o644)

    module.write_private_json(output, {"schema_version": 1, "cases": []})

    assert json.loads(output.read_text()) == {"cases": [], "schema_version": 1}
    assert stat.S_IMODE(output.stat().st_mode) == 0o600
    assert not list(tmp_path.glob(".result.json.*"))
