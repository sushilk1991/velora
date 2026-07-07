# Adversarial audit v1 (codex + claude, grok judge)

## Judge
{
 "agent": "grok",
 "command": [
  "grok",
  "--prompt-file",
  "/dev/stdin",
  "--output-format",
  "plain",
  "--permission-mode",
  "plan"
 ],
 "exit_code": 127,
 "duration_s": 0.028,
 "trace_id": "1d4554475538437093329014e050cf67:judge",
 "stdout": "",
 "stderr": "Error: grok not found in PATH\n",
 "stdout_truncated": false,
 "stderr_truncated": false
}

---
## codex

**Verdict**

End state: read-only adversarial audit; no files edited. Conclusion: **not ready to publish**. The blocking issues are not style: they are wrong-target insertion, sidecar lifecycle gaps, reconnect/session races, tail-audio loss, and privacy/resource risks.

**Reasons**

1. **Critical: final text can paste into the wrong app or a secure field.**  
   Spec requires focused-field context and secure-field suppression: [docs/SPEC.md](/Users/sushil/Code/Velora/docs/SPEC.md:31), [docs/SPEC.md](/Users/sushil/Code/Velora/docs/SPEC.md:38). Code only checks secure input at recording start: [DictationController.swift](/Users/sushil/Code/Velora/Sources/Velora/App/DictationController.swift:118). At final, it inserts using stale start-time context: [DictationController.swift](/Users/sushil/Code/Velora/Sources/Velora/App/DictationController.swift:249). `TextInserter` uses `targetBundleID` only to choose paste vs typing, then posts global Cmd-V: [TextInserter.swift](/Users/sushil/Code/Velora/Sources/Velora/Insert/TextInserter.swift:21), [TextInserter.swift](/Users/sushil/Code/Velora/Sources/Velora/Insert/TextInserter.swift:53). Failure: dictate in Slack, switch focus while transcribing, final text lands wherever focus is now.

2. **Critical: published `.app` has no engine.**  
   `make-app.sh` copies only the Swift binary, plist, and sounds: [scripts/make-app.sh](/Users/sushil/Code/Velora/scripts/make-app.sh:25). `ResourceLocator.engineDirectory` requires `VELORA_ENGINE_DIR` or a repo ancestor: [ResourceLocator.swift](/Users/sushil/Code/Velora/Sources/Velora/Config/ResourceLocator.swift:45). Otherwise supervisor degrades: [EngineSupervisor.swift](/Users/sushil/Code/Velora/Sources/Velora/App/EngineSupervisor.swift:84). Failure: move `Velora.app` outside the checkout and dictation cannot start.

3. **High: engine sidecar can become a zombie.**  
   Architecture says engine exits when parent dies: [docs/ARCHITECTURE.md](/Users/sushil/Code/Velora/docs/ARCHITECTURE.md:32). Engine supports `--parent-pid`: [server.py](/Users/sushil/Code/Velora/engine/src/velora_engine/server.py:451). Supervisor does not pass it: [EngineSupervisor.swift](/Users/sushil/Code/Velora/Sources/Velora/App/EngineSupervisor.swift:93). If the app crashes or is killed, the MLX process can remain running indefinitely.

4. **High: reconnect can abort the new active session.**  
   New client drops the old writer: [server.py](/Users/sushil/Code/Velora/engine/src/velora_engine/server.py:139). The old handler’s `finally` always calls `_abort_session`: [server.py](/Users/sushil/Code/Velora/engine/src/velora_engine/server.py:172). `_abort_session` clears global `self.session`, not a client-owned session: [server.py](/Users/sushil/Code/Velora/engine/src/velora_engine/server.py:301). Failure: reconnect during dictation can discard the fresh session.

5. **High: engine crash during dictation leaves UX stuck until timeout.**  
   Architecture promises in-flight error on crash: [docs/ARCHITECTURE.md](/Users/sushil/Code/Velora/docs/ARCHITECTURE.md:31). Supervisor disconnects with `notify:false` on process exit: [EngineSupervisor.swift](/Users/sushil/Code/Velora/Sources/Velora/App/EngineSupervisor.swift:129). AppDelegate only refreshes degraded state: [AppDelegate.swift](/Users/sushil/Code/Velora/Sources/Velora/App/AppDelegate.swift:111). Dictation waits up to 20s: [DictationController.swift](/Users/sushil/Code/Velora/Sources/Velora/App/DictationController.swift:37). Failure: user releases hotkey after engine crash and stares at transcribing until timeout.

6. **High: final audio tail is dropped.**  
   Capture emits only full 1600-frame chunks: [AudioCapture.swift](/Users/sushil/Code/Velora/Sources/Velora/Capture/AudioCapture.swift:80). `stop()` clears pending samples without flushing: [AudioCapture.swift](/Users/sushil/Code/Velora/Sources/Velora/Capture/AudioCapture.swift:111). Failure: last syllable/short word before release is never sent to STT.

7. **Medium: unbounded engine audio queue can OOM.**  
   Session queue is unbounded: [server.py](/Users/sushil/Code/Velora/engine/src/velora_engine/server.py:57). Audio frames are `put_nowait`: [server.py](/Users/sushil/Code/Velora/engine/src/velora_engine/server.py:292). Protocol permits frames up to 32 MiB: [protocol.py](/Users/sushil/Code/Velora/engine/src/velora_engine/protocol.py:23). Failure: slow STT or a local same-user client grows memory without backpressure.

8. **Medium: pasteboard path leaks dictated text and can paste previous clipboard.**  
   Dictated text is placed on global pasteboard, Cmd-V is posted, then clipboard restores after fixed 300ms: [TextInserter.swift](/Users/sushil/Code/Velora/Sources/Velora/Insert/TextInserter.swift:16), [TextInserter.swift](/Users/sushil/Code/Velora/Sources/Velora/Insert/TextInserter.swift:53), [TextInserter.swift](/Users/sushil/Code/Velora/Sources/Velora/Insert/TextInserter.swift:58). Failure: clipboard managers capture dictated text; delayed paste can insert the previous clipboard instead.

**Risks**

I did not run build/tests because the delegation is read-only and the sandbox blocked temp writes. These findings are source-evidence based, not runtime reproduced.

The strongest possible counterargument is that manual testing already avoids focus changes, crashes, and app relocation. That does not hold for publishing: those are normal user behaviors and distribution paths.

**Recommendation**

Smallest next step that would change the conclusion: create one fake-engine UI/integration harness that delays `final` by 2s, then test: start in TextEdit, switch focus before final, focus a password field before final, kill engine mid-recording, reconnect during recording, and run the built `.app` outside the repo. Fix every failure before publishing.

Verified: source read only; no edits; findings above cite concrete file lines.  
Inferred: failure scenarios are derived from control flow; they still need runtime reproduction on macOS with TCC permissions.

---
## claude

# Second opinion: Velora open-source readiness audit

**Contract**: adversarial read-only audit of `Sources/Velora` + `engine/src/velora_engine` for correctness/resource/security/UX defects with concrete failure paths, ranked, cited file:line. I read every Swift source, all 8 engine modules, `docs/ARCHITECTURE.md`, and `.gitignore`. I could not build or run anything (read-only delegation), so dynamic claims are labeled.

## Verdict

**Not ready.** The protocol, SQL, and formatting layers are solid, but there are four must-fix defects — a guaranteed engine-orphaning path, two insertion-path defects that paste the wrong thing or paste into the wrong app, and a settings write that destroys user config — plus a cluster of races and privacy gaps that will become embarrassing public bug reports within days of release.

## Reasons (ranked findings)

### High severity

**H1 — Zombie engine processes holding gigabytes of RAM.** The supervisor spawns the engine without `--parent-pid` (`EngineSupervisor.swift:95`: `["run", "--project", engineDir.path, "velora-engine"]`), yet the engine's *only* self-exit paths require a known parent pid — `_watch_parent` returns immediately when `parent_pid is None` (`server.py:127-129`) and the disconnect-exit is gated on `self.parent_pid is not None` (`server.py:179-181`). ARCHITECTURE.md:32 promises "it also self-exits if socket closes / parent pid dies"; that mechanism exists and is simply not wired up. Failure scenario: app crashes or is force-quit → a Python process holding STT + Qwen3-4B weights (~3-4 GB unified memory) lives forever; each app relaunch spawns a fresh one that unlinks and rebinds the socket, so orphans accumulate invisibly. Compounding it: on normal quit, the SIGKILL fallback is scheduled 2 s out on a background queue (`EngineSupervisor.swift:148-150`) but the app process exits before it fires, so a wedged engine survives.

**H2 — Text is inserted into whatever is frontmost at `final` time, with no recheck.** `finishInsertion` (`DictationController.swift:250`) → `TextInserter.insert` uses `targetBundleID` only to *choose paste-vs-type strategy* (`TextInserter.swift:23-30`); it never verifies the session's target app is still frontmost, and secure-input is checked only at recording start (`DictationController.swift:119`), never at insertion. Failure scenario: transcription takes 0.5–20 s; user ⌘-tabs away (or a password prompt steals focus) → the transcript is ⌘V'd into the wrong app, including a secure/password field. For a dictation app this is the canonical trust-destroying bug.

**H3 — Pasteboard restore race pastes the user's *old clipboard* instead of the dictation.** `insertViaPasteboard` restores the snapshot on a fixed 300 ms timer with no `changeCount` check (`TextInserter.swift:17, 58-63`). If the target app services the synthetic ⌘V after 300 ms — likely on exactly this machine, which just ran 4B-parameter LLM inference milliseconds earlier, or in a busy Electron app — the paste delivers the restored previous clipboard, and the dictated text is gone from the pasteboard entirely. Anything the user copies during the 300 ms window is also silently clobbered by the restore.

**H4 — App settings writes destroy engine config (silent user data loss).** `AppConfig.writeEngineConfig` rewrites `~/.velora/config.json` with only `{stt_model, language, auto_punctuation}` (`AppConfig.swift:253-261`), deleting the engine-owned keys `cleanup_model`, `cleanup_enabled`, `vocabulary`, `replacements`, `default_mode` (`config.py:24-31`). Toggling auto-punctuation triggers this write plus `reload_config` (`SettingsModel.swift:87-92`), and the engine reload merges the gutted file over defaults (`config.py:121-127`) — so user vocabulary, replacements, and cleanup preferences are wiped both on disk and live. Bonus defect: the engine never reads `language` or `auto_punctuation` at all (no such properties in `config.py`), so those two settings are UI-only no-ops.

### Medium severity

**M1 — Engine death mid-dictation = talking into the void, then a 20 s hang.** `DictationController` observes only `EngineEvent`s (`DictationController.swift:213-238`); nothing routes supervisor state changes or disconnects to it. Engine crashes while recording → `EngineClient.send` silently drops frames (fd guard, `EngineClient.swift:122`), HUD stays "listening", the eventual `stop` is dropped, and the user waits the full 20 s timeout (`DictationController.swift:38, 174-182`) for an error. ARCHITECTURE.md:31 promises "HUD shows error state if a dictation was in flight" — not implemented.

**M2 — Data race on the capture buffer.** `pending` is appended on the realtime audio tap thread (`AudioCapture.swift:81-84`) and cleared on the main thread in `stop()`/`start()` (`AudioCapture.swift:57, 116`) with zero synchronization; `removeTap` does not fence an in-flight tap callback. Concurrent Swift `Array` mutation is memory-unsafe — this races on *every* dictation stop and will surface as rare heap-corruption crashes that are miserable to triage from public bug reports.

**M3 — Last <100 ms of speech is discarded.** Only full 1600-sample chunks are emitted (`AudioCapture.swift:82`); the partial tail is thrown away in `stop()` (`AudioCapture.swift:116`). Parakeet pads finalize with silence (`stt.py:102`) but the real audio is gone — final phonemes/words get clipped, a direct transcription-quality defect.

**M4 — Unbounded buffers + no duration cap on locked recordings.** `session.queue.put_nowait` is unbounded (`server.py:293`); if MLX STT falls below realtime (thermal throttle, LLM warming concurrently on the same GPU) the queue grows without bound. Worse, `WhisperBackend` accumulates *all* PCM and batch-transcribes at stop (`stt.py:192-208`): double-tap lock is a supported feature, so an hour-long locked session on the Whisper backend accumulates ~230 MB and then a batch transcription that is guaranteed to blow the app's 20 s timeout — an hour of speech lost.

**M5 — fd-recycle race in the socket client.** `disconnect()` closes the fd while `readLoop` may be blocked in `read()` (`EngineClient.swift:82-96, 159`); a blocked read on macOS does not reliably unblock on close, and a subsequent `connect()` (`EngineClient.swift:43`) can be assigned the same fd number. The stale loop checks `isCurrent()` only between frames (`EngineClient.swift:172`), so it can steal bytes from the new connection → frame desync on both loops during engine restarts. Mirror race engine-side: a displaced old client handler's `finally` calls `_abort_session` unconditionally (`server.py:177`), which can discard a session the *new* client just started.

**M6 — "Local-first" app phones huggingface.co on every engine start.** `from_pretrained` (`stt.py:65-68`) and `mlx_lm.load` (`cleanup.py:75-78`) neither pass `local_files_only` nor set `HF_HUB_OFFLINE`; hub etag checks (and hub telemetry, unless disabled) run on every launch even with fully-cached models, and offline starts stall on network timeouts. Only `set_model`'s `ensure_downloaded` does cache-first correctly (`models.py:71-77`). For a privacy-marketed open-source release this is the first thing someone will Wireshark and tweet.

**M7 — Transcript privacy gaps.** `~/.velora` is created with default (umask) permissions (`AppConfig.swift:240-241`, `config.py:113`), so `history.sqlite3` — every raw+final dictation — is 0644 world-readable, and `engine.log` receives transcript snippets via the Whisper guard (`stt.py:157, 160`). The socket is chmod'd 0600 only *after* bind (`server.py:109-110`), a small pre-chmod window. Dictated text is placed on the general pasteboard without `org.nspasteboard.TransientType`/`ConcealedType` (`TextInserter.swift:53-54`), so every dictation is permanently captured by clipboard managers.

### Low severity

- **L1** — `engine.log` is truncated on every spawn (`FileManager.createFile` overwrites, `EngineSupervisor.swift:106`), destroying crash evidence on the restart that follows the crash.
- **L2** — Session-less engine error events abort an active dictation (`DictationController.swift:231-234`): any global error (e.g. a stray unknown command) cancels the user's recording.
- **L3** — Doc drift: ARCHITECTURE.md:15 says `parakeet-tdt-0.6b-v3`; code defaults to v2 (`AppConfig.swift:92`, `config.py:21`).

### What I looked for and did *not* find (clearing the named suspects)

No SQL injection — history is fully parameterized with `SQLITE_TRANSIENT` binds (`HistoryStore.swift:81-98`). No shell injection — the engine is spawned via `Process` argv, no shell (`EngineSupervisor.swift:93-95`). Framing is symmetric, length-capped both directions (`protocol.py:23`, `EngineClient.swift:176`), and both sides survive malformed JSON/audio (`server.py:209-214`, `stt.py:263-270`, `EngineClient.swift:181-186`). The previous-clipboard snapshot/restore itself preserves all representations. `.venv` and `spikes/` are gitignored.

## Risks (of my analysis)

- **UNVERIFIED (no runtime):** I could not build the Swift package or run the engine/tests, so H3's paste-latency window, M2's crash frequency, M5's blocked-read behavior on macOS, and M6's exact network calls are code-derived, not observed. The strongest refutation candidate is M6: if `parakeet_mlx.from_pretrained`/`mlx_lm.load` internally pass cache-first flags, that finding downgrades — I checked the call sites, not the vendored library internals.
- H1's uv signal-forwarding detail (whether `uv run` execs or forwards SIGTERM) is inferred; the crash/force-quit orphan path does not depend on it and stands on `server.py:127-129, 179-181` alone.
- I did not audit `tests/`, `scripts/`, Settings/Onboarding view code, or git history for secrets — out of the flows named in the task.

## Recommendation

Block release on four fixes, each small: (1) append `--parent-pid <pid>` to the spawn args in `EngineSupervisor.swift:95`; (2) before `postCommandV` and before restore, recheck frontmost bundle == session target and `SecureInput.isActive`, and guard the restore with an `NSPasteboard.changeCount` comparison; (3) make `writeEngineConfig` read-modify-write `config.json` (and either wire `language`/`auto_punctuation` into the engine or drop the toggles); (4) route `engineClientDidDisconnect`/state changes into `DictationController` to fail fast mid-dictation. Then fix M2 (serialize `pending` onto one queue) and M3 (flush the tail chunk on stop) in the same pass, and set `HF_HUB_OFFLINE`-style cache-first loading before calling the app "local-first" in the README. The single cheapest conclusion-changing check once a runtime is available: force-quit the app mid-dictation and run `ps aux | grep velora-engine` — if a process survives, H1 is confirmed exactly as written.

**Verified** (quoted from source this session): all file:line citations above — spawn args without `--parent-pid`; engine exit gates on `parent_pid`; 300 ms unconditional restore; 3-key config rewrite vs engine's 6-key default dict; unsynchronized `pending` mutation across the tap thread and main thread; unbounded `put_nowait`; Whisper full-buffer batch path; post-bind chmod; parameterized SQL.
**Inferred** (mechanism sound, not executed): paste-after-300 ms timing under inference load; fd reuse after close on macOS; HF hub network behavior inside `from_pretrained`/`mlx_lm.load`; uv signal forwarding.

