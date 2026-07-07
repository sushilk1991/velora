#!/usr/bin/env python3
"""E2E smoke harness for velora-engine.

Connects to a RUNNING engine, streams a WAV file's PCM as real-time-ish audio
chunks between start/stop, and prints partial/transcript/final events with
latencies. Standalone: stdlib only (no engine imports).

Usage:
    uv --project engine run velora-engine --socket /tmp/velora-smoke.sock &
    python3 scripts/engine-smoke.py --wav spikes/engine/samples/jfk.wav \
        --socket /tmp/velora-smoke.sock --bundle-id com.apple.Notes --app-name Notes

The WAV must be 16 kHz mono (int16 or float32), e.g. the spike samples.
"""

from __future__ import annotations

import argparse
import json
import socket
import struct
import sys
import time
import uuid
import wave
from pathlib import Path

FRAME_JSON = 0x01
FRAME_AUDIO = 0x02


def encode_frame(frame_type: int, payload: bytes) -> bytes:
    # frame = u32 length LE | u8 type | payload; length = 1 + len(payload)
    return struct.pack("<I", 1 + len(payload)) + bytes([frame_type]) + payload


def send_json(sock: socket.socket, obj: dict) -> None:
    sock.sendall(encode_frame(FRAME_JSON, json.dumps(obj, separators=(",", ":")).encode()))


class FrameReader:
    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.buf = b""

    def read_frame(self, timeout: float | None = None) -> tuple[int, bytes]:
        self.sock.settimeout(timeout)
        while True:
            if len(self.buf) >= 4:
                (length,) = struct.unpack("<I", self.buf[:4])
                if len(self.buf) >= 4 + length:
                    frame = self.buf[4 : 4 + length]
                    self.buf = self.buf[4 + length :]
                    return frame[0], frame[1:]
            data = self.sock.recv(65536)
            if not data:
                raise ConnectionError("engine closed the connection")
            self.buf += data

    def read_event(self, timeout: float | None = None) -> dict:
        frame_type, payload = self.read_frame(timeout)
        if frame_type != FRAME_JSON:
            raise ValueError(f"unexpected frame type 0x{frame_type:02x} from engine")
        return json.loads(payload)


def load_wav_float32le(path: Path) -> tuple[bytes, float]:
    """Return (float32 LE PCM bytes, duration seconds). Requires 16kHz mono."""
    with wave.open(str(path), "rb") as wf:
        rate, channels, width = wf.getframerate(), wf.getnchannels(), wf.getsampwidth()
        if rate != 16_000 or channels != 1:
            sys.exit(f"error: {path} is {rate}Hz/{channels}ch; need 16000Hz mono "
                     f"(convert: ffmpeg -i in.wav -ar 16000 -ac 1 out.wav)")
        raw = wf.readframes(wf.getnframes())
        n = wf.getnframes()
    if width == 2:  # int16 → float32
        import array

        ints = array.array("h")
        ints.frombytes(raw)
        floats = array.array("f", (s / 32768.0 for s in ints))
        pcm = floats.tobytes()
    elif width == 4:
        pcm = raw  # assume float32 LE
    else:
        sys.exit(f"error: unsupported sample width {width}")
    return pcm, n / 16_000.0


def main() -> None:
    ap = argparse.ArgumentParser(description="velora-engine E2E smoke client")
    ap.add_argument("--wav", required=True, help="16kHz mono WAV to stream")
    ap.add_argument("--socket", default=str(Path.home() / ".velora" / "engine.sock"))
    ap.add_argument("--bundle-id", default=None, help="frontmost-app bundle id for mode resolution")
    ap.add_argument("--app-name", default=None)
    ap.add_argument("--mode", default=None, help="explicit mode name (overrides app matching)")
    ap.add_argument("--chunk-ms", type=int, default=100)
    ap.add_argument("--speed", type=float, default=1.0, help="pacing multiplier (1.0 = real time)")
    args = ap.parse_args()

    pcm, duration = load_wav_float32le(Path(args.wav))
    chunk_bytes = int(16_000 * args.chunk_ms / 1000) * 4
    print(f"wav: {args.wav} ({duration:.1f}s), streaming {args.chunk_ms}ms chunks at {args.speed}x")

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(args.socket)
    reader = FrameReader(sock)

    t0 = time.perf_counter()
    ready = reader.read_event(timeout=120)
    assert ready.get("event") == "ready", f"expected ready, got {ready}"
    print(f"ready ({(time.perf_counter() - t0) * 1000:.0f}ms): stt={ready.get('stt_model')}")

    session = str(uuid.uuid4())
    send_json(sock, {"cmd": "start", "session": session,
                     "context": {"bundle_id": args.bundle_id, "app_name": args.app_name, "mode": args.mode}})

    # Stream chunks, printing partials as they arrive (non-blocking-ish poll).
    sock.setblocking(True)
    interval = args.chunk_ms / 1000.0 / args.speed
    n_chunks = 0
    t_stream = time.perf_counter()
    for off in range(0, len(pcm), chunk_bytes):
        target = t_stream + n_chunks * interval
        delay = target - time.perf_counter()
        if delay > 0:
            time.sleep(delay)
        sock.sendall(encode_frame(FRAME_AUDIO, pcm[off : off + chunk_bytes]))
        n_chunks += 1
        # drain any pending partials without blocking
        try:
            while True:
                evt = reader.read_event(timeout=0.001)
                if evt.get("event") == "partial":
                    print(f"  partial: {evt['text'][:80]!r}")
        except (TimeoutError, socket.timeout):
            pass
        finally:
            sock.settimeout(None)  # timeout also governs sendall backpressure

    t_stop = time.perf_counter()
    send_json(sock, {"cmd": "stop", "session": session})
    print(f"streamed {n_chunks} chunks in {t_stop - t_stream:.1f}s; sent stop")

    transcript_ms = final_ms = None
    while True:
        evt = reader.read_event(timeout=60)
        kind = evt.get("event")
        if kind == "partial":
            print(f"  partial: {evt['text'][:80]!r}")
        elif kind == "transcript":
            transcript_ms = (time.perf_counter() - t_stop) * 1000
            print(f"\ntranscript (stop→transcript {transcript_ms:.0f}ms, engine stt_ms={evt.get('ms')}):")
            print(f"  raw: {evt.get('raw')!r}")
        elif kind == "final":
            final_ms = (time.perf_counter() - t_stop) * 1000
            print(f"\nfinal (stop→final {final_ms:.0f}ms, mode={evt.get('mode')}, "
                  f"cleanup_ms={evt.get('cleanup_ms')}, cleanup_applied={evt.get('cleanup_applied')}):")
            print(f"  text: {evt.get('text')!r}")
            break
        elif kind == "error":
            sys.exit(f"engine error: {evt.get('message')}")
        else:
            print(f"  (event: {evt})")

    print(f"\nlatency summary: stop→transcript {transcript_ms:.0f}ms | stop→final {final_ms:.0f}ms "
          f"| budget: transcript<300ms final<1500ms")
    sock.close()


if __name__ == "__main__":
    main()
