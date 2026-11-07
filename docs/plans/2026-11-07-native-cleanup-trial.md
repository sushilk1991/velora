# Native English cleanup personal trial

## Goal and scope

Provide a signed personal test build with an explicit, default-off LFM3 native
dictation switch. Keep the selected standard cleanup model for other work and
keep Whisper unchanged. This authorizes a personal build, not a public release
or a production model-default change. Existing rejected prompt/calibration
experiments are not enabled. User-approved scope: native trial, easy rollback,
raw recovery, fresh feedback, and closing integration gaps.

Use the previously measured G Q4 artifact, canonical student JSON/system prompt,
copy8, ordinary system prefix reuse, batch128, context4096, output512,
thinking disabled, student-header cache off. No new training or decoder rewrite.

## Runtime contract

The personal package lives at
`<VELORA_HOME>/experimental/lfm3-native-v1/`, containing `manifest.json`,
`model.gguf`, `velora-cleanup-native`, `supervise.py`, and license/lineage notes.
No model download or Python import from research/training directories at runtime.
Fixed identities:

- Model SHA256: `ec3710cf3bc12c0fbdfcf24587e5f87a2bf197f4c3129d390052af67e3d1a666`
- Worker SHA256: `6b5ab148f586b881d27577f5a61a5dafa551d1a24edb140213c29321ec044a3c`
- Supervisor SHA256: `fd06b212cff24db00b855265dfae20b403623a15a379ef1e72eec39e106e0b02`
- llama.cpp commit: `4b77dee0524c64b8471869232e2958bd9589607d`

`velora_engine.native_runtime` exposes `discover_package(home=None)` returning
`NativePackage | None`. A package has `root`, `model_path`, `binary_path`,
`supervisor_path` and `verify()`. Discovery validates manifest identities, fixed
regular-file paths and sizes without repeatedly hashing a gigabyte model.
`verify()` hashes the executable/supervisor; the worker independently verifies
the model from its open descriptor at every load. Manifest fields: schema1,
model_sha256, binary_sha256, supervisor_sha256, model_bytes, and checkpoint G.

`NativeRuntime(package)` exposes async `load(cancel_event=None)`,
`generate(system, user, *, max_tokens, deadline_ms, draft_text='', cancel_event=None)`
returning the native result dictionary, and `aclose()`. State: `ready`, `loaded`,
`unhealthy`, and `pid` (GPU worker). Closing is bounded and reaps both owned
processes before succeeding; load may start a fresh lifetime after close.
Use the existing supervisor with strict identity/ready checks, finite JSONL,
deadlines, cancellation and repeat/context recovery. Transport failures retire
the process. Partial/failed generated text must never become accepted output.

## App integration

The standard model remains `config.cleanup_model`. New engine-owned boolean
`experimental_native_cleanup` defaults false. A router uses native only for
supported short, stock-mode, Latin-script English/auto dictation. Long/chunked
recordings, custom/screen-aware contexts, romanization, other explicitly selected
languages, control-token literals, editing, decisions, actions and summaries use
the standard model. Preserve existing gates, divergence guards and postprocess.
Full app instructions/vocabulary are rendered with the tested canonical student
contract; do not silently enable the rejected compact-context helper.

The router stops/reaps the active cleanup backend before loading the other.
Native mode suppresses unnecessary standard-model prefix warming and idle
vocabulary mining; explicit unsupported work still works through the standard
model. Preserve shutdown/recovery/hibernation ownership and cancellation.
Record effective backend/checkpoint in trial history metrics so a standard-model
fallback cannot masquerade as a native result. Preserve raw history recovery.

Settings uses the existing design under Models: a separate default-off
"LFM3 Native — Experimental" choice, shown when the local trial package is
available or the experiment was selected. Explain English dictation scope and
possible missed corrections/omissions. Standard model selection stays available.
Only adopt the experiment setting after an engine acknowledgement.

Engine command: `set_native_cleanup`, with boolean `enabled` and string
`request_id`. Status fields: `native_cleanup_available`, `native_cleanup_enabled`,
`native_cleanup_switching`, `native_cleanup_request_id`, `native_cleanup_error`.
Reject changes during capture/background work/adoption, preserve old choice on
failure, and settle the requesting UI with authoritative status. Switching off
must work even if the package is missing. No changes to built-in mode prompts.

## Implementation units and ownership

1. Native package/client (`native_runtime.py`, runtime tests and dummy child
   fixture): independent bounded process ownership, fixed artifact checks.
2. Settings choice (`SettingsModel.swift`, `SettingsViews.swift`): independent
   UI/command contract above; no engine/config writes or full builds by worker.
3. Router/server/config integration and meaningful tests: depend on runtime
   unit; retain normal backend behavior and actual request context.
4. Local package installer, history diagnostics, signed personal build and
   documentation: no public model upload or version bump.

Units1/2 may run in parallel from the committed contract, with exclusive paths.
Workers do not stage/commit or run mutating full builds. Host owns integration,
verification, review and main landing. No standing external execution route is
configured; use the native harness. Scratch progress stays outside this file.

## Verification and definition of done

- Proof-first tests for new behavior: artifact mismatch/missing package, ready
  mismatch, cancellation, EOF/timeout, close/reload, no accepted partial output,
  busy selection, failed activation rollback, disabled default, language/mode
  routing, preserved raw text, and one-backend lifetime ordering.
- Real child-process integration tests (dummy workers without model/GPU), plus
  actual pinned native GPU smoke/repeat/cancel and actual formatting replay.
- Model/UI acknowledgement logic tests in Swift selftest where appropriate;
  inspect the new Models UI in the signed build.
- `make test` passes using installed SDK26.5 if SDK27's macro-plugin problem
  persists. Run focused checks for new native functionality and package install.
- Actual user recordings remain private; report coverage and failures honestly.
  Native/standard timing distinguishes cold load from warm cleanup. No claims of
  whole-app RAM reduction based on model file size.
- Complete code review and apply findings, land finished work on `main`, and
  produce signed `build/Velora.app` with the existing stable identity using
  `./scripts/make-app.sh release none`. Preserve permissions and current default.
- Install the verified local trial kit; user can enable the experiment and
  return to standard cleanup without editing files. Report limits and gaps.
