# Download Recovery Implementation Plan

> Execute component seams serially, with regression tests and independent review before integration.

**Goal:** Recover interrupted model downloads from onboarding and Settings, then release on GitHub and Homebrew.

**Architecture:** One engine coordinator owns transfer state and a cancellable child process. Server owns model adoption; Swift renders authoritative snapshots and requests recovery. Completed verified files are reused; partial resume requires unchanged identity and valid Range responses.

**Tech Stack:** Python 3.12, Hugging Face Hub, SwiftPM/AppKit/SwiftUI.

## Ownership board

Multi-seam: transfer/cache, server adoption/protocol, Swift UI are independently testable contracts. Writers run serially in an isolated feature worktree; parent integrates reviewed component commits and owns documentation/release.

1. Transfer writer: `downloads.py`, `download_worker.py`, `download_cache.py`, `models.py` and corresponding engine tests only.
2. Server writer: `server.py`, `test_server.py`, `test_server_downloads.py` only, after transfer handoff.
3. Swift writer: EngineClient download types/events, EngineSupervisor, onboarding, Settings model/views/storage, recovery view and Selftest only, after server handoff.
4. Integration owner: contract reconciliation and full gates after all component handoffs. No issue-wide writer commission.

## Contract

Add `download_status` events with `schema:1`, `engine_id`, increasing `sequence`, `snapshot:true`, and full `downloads` list. Per-item fields: `model`, `kind` (`stt|cleanup`), nullable `revision`, `attempt`, `state` (`queued|downloading|verifying|loading|retry_wait|ready|failed`), `bytes_received`, nullable `bytes_total`, `retry_index`, nullable `retry_at`, nullable structured `error` (`category,code,message,retryable`), `resume` (`none|partial|completed_files|file_restarted`), `retry_allowed`, `restart_allowed`, nullable `active_model`.

Commands: `download_status`; `retry_download` and `restart_download` with exact `model,kind,attempt`. Reject stale keys with error code `stale_download_attempt` and authoritative snapshot. Duplicate requests cannot spawn competing transfers. Ready means live model adoption, not persisted cache status. No tokens or signed URLs in persisted/wire data.

Coordinator API: async `ensure(model_id,kind)` returns result with local path/revision/attempt; async `retry(model_id,kind,attempt,*,restart=False)` accepts without awaiting transfer; `snapshot()`; async `mark_loading`, `mark_ready`, `mark_failed`, `close`. Explicitly report any necessary contract amendment to parent.

## Task 1: Transfer and cache

Write failing tests first and run them. Implement owned partials, immutable manifests, safe Range/If-Range and Content-Range validation, atomic promotion, unique-byte progress, offline complete-cache checks and process locking/reaping. Never delete another downloader's partials. Preserve pinned Q8 SHA. Inspect installed Hub source before using its APIs. Byte-stall deadline 60 s; metadata 60 s; verification 300 s; network backoff 2/5/15 s. Auth/disk failures do not auto-retry. Restart confirms and removes only owned partial state after worker exit.

Gate: `cd engine && uv run pytest -q tests/test_models.py tests/test_downloads.py tests/test_download_worker.py tests/test_download_cache.py`. Required fixtures: interrupted body/resume, heartbeat without bytes, invalid/ignored ranges, changed identity, 416, disk/auth failure, corrupt/missing shard, cancellation/reaping, restart containment, duplicate requests and offline cache.

## Task 2: Server

Write red regressions for pre-ready commands, startup speech failure, optional writing failure, responsive switching, reconnect snapshots and failed-switch preservation. Integrate coordinator into startup, switches and other model acquisitions. Keep connection alive on download failure. Track adoption jobs rather than blocking command dispatch. Retain old model/config until candidate success. Speech readiness is independent of writing. Quarantine timed-out STT executor work until it settles; never claim thread cancellation or permit overlapping loads.

Gate: focused transfer/server tests then `cd engine && uv run pytest -q`.

## Task 3: Swift

Write failing Selftests for schema/order/actions/readiness. Share supervisor-owned state across onboarding and Models. Do not infer readiness from pong or setup-complete alone. Show truthful waiting/failure/verifying/loading state, Retry Now and confirmed Restart Download; preserve recovery after setup closes. Gate dictation on loaded speech only. Commit model selection only on authoritative acceptance. Protect active/pending caches from storage removal and count unique storage objects.

Gate: `swift build && .build/debug/Velora --selftest`.

## Task 4: Integration and release

Review each component independently and fix valid blockers. Run `make test`; verify real Hub/Xet HTTP compatibility and signed-app recovery where available. Update architecture protocol documentation. Inspect exact final diff and release prerequisites; report skipped checks honestly.

Check current published versions, bump a fresh version, write notes, commit, push reviewed PR and merge main. Build from merged main with Developer ID and Direct provisioning profile using `./scripts/make-dmg.sh release none`. Follow `docs/RELEASING.md`: notarize, staple, verify, publisher dry-run and publish. Verify latest GitHub asset and exact Homebrew checksum with `brew fetch --cask sushilk1991/tap/velora`.

Approved HTML: `docs/plans/download-recovery-proposal.html`. Leave pre-existing `.orca/` untouched. Stop for infrastructure failure, missing release credentials, destructive action requiring confirmation, or an unapproved architectural change.
