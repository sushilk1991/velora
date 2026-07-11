# Live HUD, Streaming Preview, and Clipboard Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a compact transcript-first HUD, earlier non-blocking Whisper previews, and a guarantee that every final dictation is retained on the clipboard.

**Architecture:** Keep authoritative Whisper and Qwen inference unchanged. Split Whisper's display-only preview into request creation and serialized decode, let the server run one coalesced preview task without blocking socket ingestion, and render its revisions inside a fixed-size SwiftUI card. Stage final text on the pasteboard before choosing any insertion path.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, Python 3.12 / asyncio / NumPy / MLX Whisper, pytest, Swift headless selftest, SwiftPM, Developer ID app packaging.

## Global Constraints

- Keep `mlx-community/whisper-large-v3-turbo` unchanged.
- Keep `mlx-community/Qwen3.5-4B-MLX-8bit` unchanged.
- Do not alter final Whisper decode settings, committed-segment thresholds, or the <=45-second whole-clip versus >45-second stitched-final rule.
- The recording HUD is approximately 348 x 72 points and never resizes for partial text.
- Keep the frontmost app icon and detected mode visible as secondary context.
- Every non-command final result must be on the general pasteboard before insertion is attempted.
- A user's later clipboard write always wins.
- No new runtime dependency.

---

### Task 1: Make final-output clipboard staging an invariant

**Files:**
- Modify: `Sources/Velora/Insert/TextInserter.swift`
- Modify: `Sources/Velora/App/DictationController.swift`
- Modify: `Sources/Velora/Selftest/Selftest.swift`

**Interfaces:**
- Produces: `TextInserter.init(pasteboard: NSPasteboard = .general)` and `stageFinalOutput(_ text: String)`.
- Consumes: existing paste/typing/own-window insertion methods and pasteboard change-count restore guard.

- [ ] **Step 1: Write the failing selftest**

Add `testClipboardStaging()` to `Selftest.run()` and use a uniquely named pasteboard:

```swift
private static func testClipboardStaging() {
    let name = NSPasteboard.Name("com.velora.selftest.\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    pasteboard.clearContents()
    let inserter = TextInserter(pasteboard: pasteboard)
    inserter.stageFinalOutput("A final sentence.")
    expect(
        pasteboard.string(forType: .string) == "A final sentence.",
        "final output remains available for manual paste")
    pasteboard.releaseGlobally()
}
```

- [ ] **Step 2: Run the selftest and verify it fails to compile**

Run: `swift build && .build/debug/Velora --selftest`

Expected: compilation fails because `TextInserter` has no pasteboard initializer or `stageFinalOutput` method.

- [ ] **Step 3: Add the injectable pasteboard and staging API**

Use the injected pasteboard everywhere in `TextInserter`:

```swift
private let pasteboard: NSPasteboard

init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
}

func stageFinalOutput(_ text: String) {
    let changeCount = writeDictation(text, to: pasteboard)
    NSLog("Velora: staged final output chars=%ld changeCount=%ld", text.count, changeCount)
}

func copyToClipboard(_ text: String) {
    stageFinalOutput(text)
}
```

Change `insertViaPasteboard` to use `self.pasteboard`, not `NSPasteboard.general`.

- [ ] **Step 4: Stage once after command/empty gates and before every insertion branch**

In `DictationController.finishInsertion`, immediately after the non-empty guard and before the own-window branch:

```swift
inserter.stageFinalOutput(text)
```

Remove the redundant fallback-only `copyToClipboard` call. Voice commands remain above this line and therefore never enter the clipboard.

- [ ] **Step 5: Verify the clipboard test and existing Swift checks**

Run: `swift build && .build/debug/Velora --selftest`

Expected: build succeeds and all selftest checks pass, including `final output remains available for manual paste`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Velora/Insert/TextInserter.swift Sources/Velora/App/DictationController.swift Sources/Velora/Selftest/Selftest.swift
git commit -m "fix: retain every final dictation on clipboard"
```

---

### Task 2: Separate Whisper preview requests from authoritative decode state

**Files:**
- Modify: `engine/src/velora_engine/stt.py`
- Modify: `engine/tests/test_stt_segmenting.py`

**Interfaces:**
- Produces: immutable `WhisperPreviewRequest(audio: np.ndarray, committed_segments: tuple[str, ...])`.
- Produces: `WhisperBackend.take_preview_request() -> WhisperPreviewRequest | None`.
- Produces: `WhisperBackend.decode_preview(request: WhisperPreviewRequest) -> str | None`.
- Produces: `WhisperBackend.discard_preview_request() -> None`.
- Consumes: existing `_audio_span`, `_decode`, `_segments`, `_decoded_samples`, and silence tracker.

- [ ] **Step 1: Write failing preview-request tests**

Add tests that feed two seconds of speech, verify no synchronous model call, pull one request, and decode it explicitly:

```python
def test_preview_is_requested_early_without_decoding_in_feed(whisper):
    backend, fake = whisper(["early words"], previews=True)
    feed_seconds(backend, 2.0)
    assert fake.calls == []
    request = backend.take_preview_request()
    assert request is not None
    assert len(request.audio) == int(2.0 * SAMPLE_RATE)
    assert backend.decode_preview(request) == "early words"


def test_pending_preview_coalesces_to_latest_bounded_window(whisper):
    backend, _fake = whisper(["latest"], previews=True)
    feed_seconds(backend, 2.0)
    first = backend.take_preview_request()
    assert first is not None
    feed_seconds(backend, 10.0)
    latest = backend.take_preview_request()
    assert latest is not None
    assert len(latest.audio) <= int(PREVIEW_WINDOW_S * SAMPLE_RATE)
```

Update existing preview tests to call `take_preview_request()` and `decode_preview()` instead of expecting preview text directly from `feed_chunk`.

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `cd engine && uv run pytest tests/test_stt_segmenting.py -q`

Expected: failures for missing `WhisperPreviewRequest`, `take_preview_request`, `decode_preview`, and `PREVIEW_WINDOW_S`.

- [ ] **Step 3: Implement request creation with early and adaptive cadence**

Add constants and request state:

```python
PREVIEW_FIRST_S = 2.0
PREVIEW_PAUSE_S = 0.3
PREVIEW_BASE_INTERVAL_S = 1.5
PREVIEW_MAX_INTERVAL_S = 4.0
PREVIEW_WINDOW_S = 10.0
PREVIEW_BACKOFF = 1.5

@dataclass(frozen=True)
class WhisperPreviewRequest:
    audio: np.ndarray
    committed_segments: tuple[str, ...]
```

When a preview is due, snapshot only the newest bounded uncommitted window, replace `_pending_preview` with the latest request, update `_last_preview_samples`, and return from `feed_chunk` without calling `_decode`. A committed segment clears the pending preview before performing its unchanged authoritative segment decode.

- [ ] **Step 4: Implement serialized preview decode and measured backoff**

```python
def take_preview_request(self) -> WhisperPreviewRequest | None:
    request = self._pending_preview
    self._pending_preview = None
    return request

def discard_preview_request(self) -> None:
    self._pending_preview = None

def decode_preview(self, request: WhisperPreviewRequest) -> str | None:
    started = time.perf_counter()
    try:
        text = self._decode(request.audio)
    except Exception:  # preview failure cannot affect final STT
        log.exception("preview decode failed - final transcription remains available")
        return None
    finally:
        elapsed = time.perf_counter() - started
        self._preview_interval_s = min(
            PREVIEW_MAX_INTERVAL_S,
            max(PREVIEW_BASE_INTERVAL_S, elapsed * PREVIEW_BACKOFF),
        )
    if not text:
        return None
    return " ".join((*request.committed_segments, text)).strip()
```

Reset pending request and adaptive interval in `reset()`; do not change finalization.

- [ ] **Step 5: Run segmenting tests**

Run: `cd engine && uv run pytest tests/test_stt_segmenting.py -q`

Expected: all segmenting, preview, short-final, long-stitch, and failure-fallback tests pass.

- [ ] **Step 6: Commit**

```bash
git add engine/src/velora_engine/stt.py engine/tests/test_stt_segmenting.py
git commit -m "perf: decouple whisper preview requests"
```

---

### Task 3: Run one coalesced preview task without blocking socket ingestion

**Files:**
- Modify: `engine/src/velora_engine/server.py`
- Modify: `engine/tests/test_server.py`

**Interfaces:**
- Consumes: `take_preview_request`, `decode_preview`, and `discard_preview_request` from Task 2 through `getattr` so Parakeet and FakeBackend remain unchanged.
- Produces: `Session.preview_task: asyncio.Task[None] | None` and `Session.last_partial: str`.
- Produces: `_emit_partial`, `_start_preview_if_ready`, `_run_preview`, and `_drain_preview` server helpers.

- [ ] **Step 1: Write a failing socket-level non-blocking preview test**

Monkeypatch the fake backend with a preview decode held by a `threading.Event`. Send one audio frame to start it, then send another frame plus `ping` while decode is blocked. Assert the second frame increments `session.samples`, `pong` arrives, and only one preview decode runs. Release the event, assert the `partial` text is `early words`, stop, and assert the normal final still arrives.

- [ ] **Step 2: Write a failing stop-order test**

Start the same held preview, send `stop`, and assert no stale partial is emitted after the session is detached. Release preview and assert `transcript` then `final` arrive with the unchanged fake final text.

- [ ] **Step 3: Run focused server tests and verify failure**

Run: `cd engine && uv run pytest tests/test_server.py -k 'preview' -q`

Expected: tests fail because the server does not consume preview requests or track an in-flight preview.

- [ ] **Step 4: Add session preview state and a shared partial emitter**

```python
self.preview_task: asyncio.Task[None] | None = None
self.last_partial = ""
```

Both committed and preview partials call `_emit_partial`; it verifies the session is current, deduplicates text, records `last_partial` before awaiting `_send`, and never sends after stop/cancel.

- [ ] **Step 5: Schedule at most one preview and prioritize queued audio**

After each feed, first drain already-queued PCM through `feed_chunk`. Only when the queue is caught up and the session is still current may `_start_preview_if_ready` pop the latest request and create `_run_preview`. The preview decode uses the existing single STT executor, preserving MLX thread affinity; new socket frames continue entering the 60-second bounded queue.

- [ ] **Step 6: Drain preview work before reset or final decode**

After `_drain_feeder`, call `_drain_preview`. It awaits an already-running decode, discards an unscheduled request, suppresses optional preview failures, and relies on `_emit_partial` to reject results for detached sessions. Then run the existing reset/finalize call on the same executor.

- [ ] **Step 7: Verify server and streaming suites**

Run: `cd engine && uv run pytest tests/test_server.py tests/test_server_streaming.py -q`

Expected: all tests pass; the new tests prove socket responsiveness, single-flight preview work, stale-partial suppression, and unchanged final ordering.

- [ ] **Step 8: Commit**

```bash
git add engine/src/velora_engine/server.py engine/tests/test_server.py
git commit -m "perf: stream whisper previews off audio ingest"
```

---

### Task 4: Stabilize provisional transcript rendering

**Files:**
- Modify: `Sources/Velora/HUD/HUDModel.swift`
- Modify: `Sources/Velora/HUD/HUDStyle.swift`
- Modify: `Sources/Velora/Selftest/Selftest.swift`

**Interfaces:**
- Produces: `HUDModel.transcriptStablePrefix` and `HUDModel.transcriptProvisionalSuffix`.
- Produces fixed geometry constants: `recordingWidth = 348`, `recordingHeight = 72`, `cornerRadius = 20`, `successWidth = 112`, `successHeight = 40`, and compact waveform size.
- Consumes: existing `HUDTranscript.select` whole-word tail selection.

- [ ] **Step 1: Add failing stable-prefix and geometry selftests**

```swift
let model = HUDModel()
model.beginSession(context: nil)
model.updatePartial("the design is")
model.updatePartial("the design is much better")
expect(model.transcriptStablePrefix == "the design is", "common words stay stable")
expect(model.transcriptProvisionalSuffix == "much better", "only new words remain provisional")
expect(HUDGeometry.recordingWidth == 348, "recording card has approved fixed width")
expect(HUDGeometry.recordingHeight == 72, "recording card has approved fixed height")
```

- [ ] **Step 2: Run selftest and verify compile failure**

Run: `swift build && .build/debug/Velora --selftest`

Expected: missing stable/provisional properties and fixed geometry constants.

- [ ] **Step 3: Compute a longest common whole-word prefix**

On each non-empty update, compare the previous selected words with the new selected words. Publish the common prefix and remaining suffix separately, with no character slicing. Reset both in `beginSession`.

- [ ] **Step 4: Replace dynamic geometry constants**

Remove transcript-driven min/max widths and the two-row expansion constants. Define one fixed recording card, compact success pill, 32 x 24 waveform, 14-point transcript font, 14-point app icon, and 10.5-point secondary mode/footer typography.

- [ ] **Step 5: Verify selftests**

Run: `swift build && .build/debug/Velora --selftest`

Expected: all checks pass, including stable-prefix and fixed-card assertions.

- [ ] **Step 6: Commit**

```bash
git add Sources/Velora/HUD/HUDModel.swift Sources/Velora/HUD/HUDStyle.swift Sources/Velora/Selftest/Selftest.swift
git commit -m "feat: stabilize live transcript presentation"
```

---

### Task 5: Build the quiet native live card

**Files:**
- Modify: `Sources/Velora/HUD/HUDView.swift`
- Modify: `Sources/Velora/HUD/WaveformView.swift`
- Modify: `Sources/Velora/HUD/HUDPanel.swift`
- Modify: `Sources/Velora/Selftest/Selftest.swift`

**Interfaces:**
- Consumes: fixed geometry and stable/provisional transcript fields from Task 4.
- Produces: fixed live-card listening/polishing UI and compact `Copied` success confirmation.

- [ ] **Step 1: Replace the recording hierarchy**

Render a fixed rounded rectangle with a small seven-bar waveform at leading,
and a trailing text column containing the two-line transcript plus footer. The
footer retains app icon + mode at leading and elapsed time at trailing. Before
the first partial show `Listening...`; while transcribing show `Polishing` in
the footer and hold the last preview.

- [ ] **Step 2: Remove visual noise and layout animation**

Delete the rotating ring, pulsing red dot, dynamic width measurement, per-partial
spring, full-text opacity transition, and shimmer. Keep only the entrance,
final success collapse, error transition, and hidden exit animation.

- [ ] **Step 3: Render stable and provisional text without moving the shell**

Build one `Text` value from the stable prefix at primary opacity and the
provisional suffix at secondary opacity. Give it a fixed two-line region,
leading alignment, and no animation keyed to transcript content.

- [ ] **Step 4: Compact the waveform**

Draw seven centered bars using the existing spectrum level store, compute bar
spacing from the 32 x 24 canvas, use violet-to-white tint while listening, and
settle to low neutral bars while polishing. Do not shimmer.

- [ ] **Step 5: Update panel bounds, positioning, and hit testing**

Set the host panel just large enough for the 348 x 72 card plus entrance offset
and soft shadow. Position from the fixed recording height and use the fixed card
width/height for the draggable hit-test rectangle.

- [ ] **Step 6: Show a truthful success state**

After final delivery, morph once to a 112 x 40 pill containing `checkmark` and
`Copied`, hold briefly, then use the existing success dismissal.

- [ ] **Step 7: Verify build, selftests, and idle rendering**

Run:

```bash
swift build
.build/debug/Velora --selftest
swift build -c release
```

Expected: all commands succeed; no hidden `TimelineView` is active, and panel
selftests prove the host contains the card plus shadow.

- [ ] **Step 8: Commit**

```bash
git add Sources/Velora/HUD/HUDView.swift Sources/Velora/HUD/WaveformView.swift Sources/Velora/HUD/HUDPanel.swift Sources/Velora/Selftest/Selftest.swift
git commit -m "feat: redesign dictation HUD as live card"
```

---

### Task 6: Full verification, installed-app QA, and release

**Files:**
- Modify if results changed: `docs/research/2026-07-11-performance-quality-validation.md`
- Modify: `VERSION`
- Modify: `Resources/Info.plist`

**Interfaces:**
- Consumes: all preceding tasks.
- Produces: tested, signed, installed, committed, pushed patch build.

- [ ] **Step 1: Run the complete automated suite**

Run:

```bash
cd engine && uv run pytest -q
cd .. && swift build -c release
.build/release/Velora --selftest
git diff --check
```

Expected: Python suite, Release build, and Swift selftest pass with no whitespace errors.

- [ ] **Step 2: Run the exact-model smoke path**

Use `scripts/engine-smoke.py` with the installed configuration and a spoken clip longer than four seconds. Capture event timing and verify the first `partial` arrives before `stop`, final text is unchanged by the preview lane, and no audio-overflow event appears.

- [ ] **Step 3: Build and install a signed patch app**

Run:

```bash
./scripts/make-app.sh release patch
ditto build/Velora.app /Applications/Velora.app
pkill -x Velora || true
open -a /Applications/Velora.app
```

Expected: version advances by one patch, Developer ID signing succeeds, and the running executable resolves inside `/Applications/Velora.app`.

- [ ] **Step 4: Perform live visual and clipboard QA**

Record a 10-15 second dictated sentence into a normal text target. Verify from the running app that:

- the 348 x 72 card stays fixed while words update;
- app icon and mode remain readable but secondary;
- an early partial appears during speech;
- release changes the footer to `Polishing` without shimmer;
- success shows `Copied`;
- automatic paste lands once;
- a subsequent manual Command-V pastes the same final text.

Capture a screenshot for direct visual inspection against the supplied bad-state screenshot.

- [ ] **Step 5: Verify runtime identity and idle CPU**

Use `ps`, `codesign --verify --deep --strict`, `spctl --assess`, and a 10-sample `top` run. Expected: the active process comes from `/Applications/Velora.app`, the bundle is signed, and hidden idle CPU stays below 1 percent.

- [ ] **Step 6: Run adversarial review and fix material findings**

Run a read-only `yoyo` review scoped to model-quality invariants, preview task ordering, stale partials, clipboard overwrite behavior, HUD hierarchy, hidden animation, and release blockers. Re-run every affected test after any fix.

- [ ] **Step 7: Commit release metadata and validation evidence**

```bash
git add VERSION Resources/Info.plist docs/research/2026-07-11-performance-quality-validation.md
git commit -m "build: release live HUD update"
```

- [ ] **Step 8: Push and prove remote state**

```bash
git push origin main
git status --short --branch
git ls-remote origin refs/heads/main
```

Expected: clean `main...origin/main`, and the remote SHA equals local `HEAD`.

