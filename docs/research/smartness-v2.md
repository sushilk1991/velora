# Smartness v2 — self-learning loop + instruction-smart cleanup

Round 11 design (2026-07-08). Owner-set goal: make Velora *smart* — learn from
the user continuously, handle spoken self-corrections, stay 100% local, and
never trade away speed. Beat Wispr Flow; absorb what makes FluidVoice good.

## Measured facts this design stands on (M5 Max, Qwen3.5-4B-8bit, real engine)

1. **Self-corrections already work — the guard was the bug.** With the
   divergence guard bypassed, the stock prompt resolves every tricky case in
   ~360-420ms: "3 p.m no no 6 p.m" → "Let's meet at 6 p.m."; "scratch that";
   "no delete this line"; emphasis-"no no no" preserved. The length-ratio
   guard (`ratio_low < 0.55`) vetoes precisely the cases where the model
   correctly deletes retracted text, and raw text gets inserted instead.
   → Fix the guard, not the model.
2. **Long dictations are killed by cleanup latency, not STT.** whisper-turbo
   batch decode is ~97× realtime (191s audio → 1.97s). But Qwen generation is
   ~70 tok/s: a 532-word cleanup needs ~5-10s (> the 6s ceiling → falls back
   to raw), and *sequential chunked* cleanup at stop costs 1.4s/chunk (10.7s
   total for 8 chunks). → Chunk cleanup must run **during speech**, where
   there is idle compute; only the tail may be processed after stop.
3. **The 0.2.0 "no punctuation" report** was Terminal mode: dictating into
   Claude Code in a terminal hits `formatting:"off"` (verbatim by design).
   Terminals now host AI chats — long prose there must be cleaned.
4. `mlx_whisper.transcribe` accepts `initial_prompt` → STT-level vocabulary
   biasing is available without fine-tuning.

## The five changes

### 1. Containment guard (replaces length-ratio veto) — unlocks self-corrections

`check_divergence` v2, in order:
- empty output → reject (as today).
- `ratio_high > 1.6` → reject (as today: the model added content).
- **Novel-content check**: tokenize both sides to lowercase alphanumeric
  words; if > 15% of output words do not occur in the input, reject
  (`novel_content`). This is the *direct* test for hallucination/answering —
  cleanup may delete words, but it may not invent them.
- **Shrink floor, marker-adaptive**: if the raw text contains a retraction
  marker (`no no`, `no wait`, `wait no`, `actually`, `scratch that`,
  `delete that/this`, `i mean`, `correction`, `rather`), allow output down to
  15% of input length; without a marker, floor at 40% (rescues the known
  heavy-filler false-trip at 0.49 while still catching pathological
  truncation). Markers only *relax the guard* — all semantics stay in the LLM
  (owner's explicit "no deterministic rewriting" steer).

Prompt refinement (rule 5): after a retraction, keep **everything** after the
correction phrase verbatim ("scratch all of that just tell him i'll call
back" → "Just tell him I'll call back." — the model currently over-deletes
"just tell him"), and keep the corrected wording exact (no "moved to
wednesday" → "is Wednesday" compression). Add regression tests that run only
the gate/guard logic deterministically + an opt-in real-model bench script.

### 2. Streaming segment pipeline — flat stop→final latency at any length

WhisperBackend gains in-session segmenting (whisper stays batch *per
segment*):
- Engine-side energy VAD on incoming frames (RMS trailing-silence tracker; no
  new deps). When un-decoded audio ≥ ~12s AND a ≥0.7s pause is seen (hard cap
  ~25s regardless), decode the pending audio on the STT thread (~0.2-0.5s),
  run the existing hallucination guard per segment, emit the running text as
  a `partial` event — **live HUD transcript for whisper, which never had
  partials**.
- As each segment's text finalizes, the server starts its LLM cleanup
  concurrently (cleanup thread is idle during recording). Chunk prompt gets
  the previous cleaned tail (~15 words, fenced as context) so seams
  punctuate/capitalize correctly. Segment boundaries are pauses, so they land
  at clause/sentence edges — no mid-word chunk artifacts (fixed-70-word
  chunking produced "…and if I / Edited that…" in the bench).
- **Cross-boundary self-correction**: if a new RAW segment *starts* with a
  retraction marker, don't clean it alone — merge it with the previous raw
  segment and re-clean the pair as one chunk (one extra ~1s generation, rare;
  marker only decides *scope*, the LLM does the edit).
- `stop` → decode only the tail (≤12s → ~0.3s), clean the last chunk
  (~0.5-1s), stitch cleaned chunks, run `postprocess` (replacements/tags) on
  the whole. **stop→final ≈ 1s regardless of dictation length**, vs today's
  raw fallback for anything past ~150 words.
- Short dictations (< first segment threshold): exactly today's path.
  Non-LLM modes (Raw/Terminal-short): segments still give partials; no
  cleanup. Reprocess: unchanged batch. Rich stop-entities: apply to the tail
  chunk + postprocess (during-speech chunks use start-time entities).
- Failure containment: any segment-cleanup failure falls back to
  deterministic cleanup for that chunk only; any pipeline error falls back to
  whole-batch finalize (today's path). Config flag `streaming_cleanup`
  (default true).

### 3. Smart Terminal gate — prose vs command

Terminals host both shells and AI chats (Claude Code, codex). In Terminal
mode (`formatting:"off"`) with `smart_terminal` config (default true): a
dictation ≥ 12 words routes to the LLM with a terminal-aware prompt (clean
prose lightly; keep anything command/code-like verbatim; never add a trailing
period). Short utterances stay verbatim. No mode-file migration — implemented
in the gate, mode files untouched, user Raw modes unaffected.

### 4. Learning loop v2 — the self-learning flywheel, all local

Today: user edits → CorrectionDiff → learned.json (spelling pairs, 2×
confirm) → cleanup vocab/replacements. New:

- **Idle vocabulary miner (engine)**: after `final`, once idle ~20s (aborts
  if a session starts), the cleanup LLM extracts proper nouns / product
  names / jargon from recent history rows (reads `~/.velora/history.sqlite3`
  directly; incremental checkpoint by row id, small batches ≈ one ~0.5s
  generation per idle window). Terms seen in ≥2 distinct dictations are
  committed to `~/.velora/auto_learned.json` (capped, deterministic
  eviction). This is the owner's "LLM works in the background when nothing is
  happening".
- **STT contextual biasing**: whisper `initial_prompt` = capped glossary
  (user vocab + learned + mined terms + current screen-context entity names,
  ~25 terms). Fixes "Velora"→"valora", "Wispr Flow"→"whisper flow" at the
  *recognition* level, and biases toward the person/file names on screen.
  Guarded: short comma-list format, existing per-segment hallucination guard
  stays, cap keeps prompt ≪ whisper's 224-token prompt budget.
- **Deferred edit capture (app)**: today edits are only diffed when the NEXT
  dictation starts. Add a one-shot ~45s post-insert re-check (same off-main
  AX read + diff path), so corrections are learned even when no follow-up
  dictation happens.
- **Management UI**: auto-learned terms listed in Settings (view/delete,
  reload_config on change), same as learned corrections.
- Embeddings model: **not now** — at O(100) terms, retrieval adds nothing a
  capped glossary doesn't; revisit if the vocab grows past ~500 terms.

### 5. Research deltas (from the three research agents, 2026-07-08)

**Papers (DRES arXiv:2509.20321, GER line arXiv:2409.09554, biasing
arXiv:2410.18363 + whisper#1150, edit-mining arXiv:2310.00141, streaming
arXiv:2307.14743/2506.17077):**
- Generic "fix the errors" LLM passes barely help Whisper output (~2.6% WERR)
  and add hallucination risk — Velora's formatting/disfluency framing +
  conservative bias is the validated shape. Keep it; strengthen the guard
  (novel-content containment) rather than the rewrite mandate.
- DRES: Qwen-family under-deletes (the safe failure mode); retraction
  commands are *commands, not disfluencies* — they must be explicitly
  enumerated in the prompt with exemplars, and no public benchmark measures
  them → we keep our own eval set (`spikes/engine/bench_selfcorrect.py`).
  Chunking transcripts into short segments *improves* cleanup stability —
  supports the segment pipeline.
- initial_prompt biasing: works as soft biasing; keep ≤~25 terms, natural
  phrasing ("Glossary: …"), highest-value terms LAST (attention favors the
  tail), never bare word dumps; add an echo guard (drop a segment that
  contains the glossary preamble — known leak mode on silence). Do the heavy
  personal-vocab lifting in the cleanup prompt with a phonetic-similarity
  instruction ("a transcript word that sounds like a glossary term should be
  spelled as the glossary term").
- Streaming: pause-aligned (VAD-closed) segments + per-segment cleanup +
  keeping the seam repairable is the WhisperKit-style dual-stream pattern;
  boundary-spanning self-repairs have NO published solution — our
  marker-triggered merge-and-reclean is the pragmatic guard.
- Open-ended voice *editing* ("rewrite that sentence") sits at ~30% accuracy
  for small models (TERTiUS) → explicitly out of scope; inline commands only.

**Wispr Flow:** edit-learning = watch the pasted field, diff, auto-add
proper-noun spellings (446 auto-learned terms in a 90-day review) — our
architecture already matches; their styles only touch caps/punctuation; their
engineering blog concedes personalization must move on-device ("local RL
policy" aspiration, unshipped). Their felt latency 1-2s (700ms p99 claimed).
Their KPI: zero-edit rate. Privacy scandal (always-on keystroke tap, cloud
uploads) is Velora's positioning wedge.

**FluidVoice (6.8k★):** virality = speed + live overlay partials + free local
cleanup (private fine-tuned "Fluid-1"). They do decode-time CTC vocabulary
boosting from the user dictionary — initial_prompt is our equivalent. Gaps we
exploit: no learning-from-edits (issue #545 requests it), closed-source
brain, ~3.5GB pinned RAM (our tiers adapt), PostHog on by default (we ship
zero telemetry). Worth stealing later: voice-trained dictionary ("say the
hard word 3×, save misheard variants"), local HTTP API for agent workflows.

### Design adjustments after research

- Segment pipeline is **dual-stream**: segment decodes give live HUD partials
  for ALL dictations (whisper finally gets streaming preview — FluidVoice's
  headline UX); the *final* text uses today's whole-clip decode + single
  cleanup for short/medium dictations (< ~45s audio — identical quality to
  today), and stitched segment-cleanups + tail only for long ones (which
  today fall to raw anyway — strictly better, and DRES says chunking helps).
- initial_prompt glossary: capped, tail-weighted, echo-guarded (above).
- Prompt gains few-shot exemplars (cheap: static prefix is KV-cached):
  positive self-repair cases, retraction commands, and negative cases
  (emphasis "no no no", content "no").

## Verified end-to-end (2026-07-08, real models over the socket)

- Self-correction eval: **11/11** (spikes/engine/bench_selfcorrect.py), ~360-560ms
  per case, including retraction commands and the negative (emphasis/content
  "no") cases.
- 75.2s synthetic dictation (say-generated, embedded pauses, mid-text
  "3 p.m no no 6 p.m"): stop→transcript **315ms** (tail-only decode),
  stop→final **1.57s**, `reason=streaming`, fully punctuated, self-correction
  resolved to "Let's meet at 6 p.m.". Live partials streamed during recording
  (whisper's first-ever HUD partials). Short regression (jfk.wav 11s):
  classic path, byte-equivalent behavior, stop→final 1.24s.
- Glossary biasing: with `vocabulary=["Velora","Wispr Flow",...]`, the same
  clip transcribes "**Velora**" (was "Valora") and "**Wispr Flow**" (was
  "Whisperflow") — corrected at STT time, visible in the first live partial.
- Miner on a copy of the real 39-row history with real Qwen3.5: promoted
  "super whisper", "LLM" (≥2 dictations); candidates include real people
  names and product terms; checkpoint advanced 8→39; junk stayed below the
  promotion threshold. Known behavior: a CONSISTENTLY misheard name can be
  mined — the edit-learning loop and the Settings delete/ban UI are the
  corrective forces.

## What stays untouched

Hot path budget: no new work between hotkey-release and insert except the
tail chunk (which replaces a *bigger* whole-text cleanup). Mining runs only
when idle and yields to a starting session. All data stays in `~/.velora`
(0600/0700). No network. No new Python deps.

## Delivery

Engine agent (cleanup.py/formatting.py/stt.py/server.py/miner + tests) and
Swift agent (deferred edit capture, auto-vocab settings UI) on disjoint file
sets; orchestrator owns integration; yoyo codex+claude adversarial review
before done; version bump minor → 0.3.0.
