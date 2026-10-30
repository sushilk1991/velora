# Measurement evidence

Read [the report](../2026-10-29-cleanup-latency-roofline.md) for controls and limits.

| File | Contents |
| --- | --- |
| `replays.csv`, `replay-summary.json` | All replay rows, load1, durations, spans, work counts and hashes; per-round summaries |
| `roofline.json`, `phase-summary.json`, `manifest.json` | Copy/QMM samples, byte counts, package/model revisions and adapter hashes |
| `quality.json` | Current cleanup and decision outcomes, footprints and run load brackets; timing results excluded |
| `trace.json` | Cold/warm replay spans and numeric Metal observations; raw traces remain outside the repo |
| `llama-bench.jsonl`, `log-summary.json` | Synthetic Metal engine benchmarks with per-command load; all historical inference-line aggregates |

A/B means the baseline/candidate in each named dataset, except `baseline-idle2`
(A and B are identical), `instrumentation-parity` (A pre-change, B traced), and
`registry-2b` (A 4B 8-bit, B shipped 2B 4-bit). In `llama-bench.jsonl`, A/B are
prompt shapes, not engines. Rounds are zero-based; blocks always follow ABBA.

`comparison_valid=false` marks an incomplete or failed comparison. A fallback
with zero inference time is a failed request. `all_load_below_20=false` makes
that whole round ineligible for the speed gate. Output changes independently
reject pure-speed candidates. Individual low-load rows can describe observed
hardware behavior; they cannot turn an ineligible round into a passing lever.

Empty CSV cells mean a field was unavailable, not zero. Older exploratory
rows lack pre-guard hashes. Spans are inclusive and can overlap. Parent socket
RTT contains worker execution. Copy-draft accepted tokens differ from model
passes, proposed tokens and replayed input tokens. `ms` retains the established
production inference definition; `wall_ms` and parent RTT include proxy work.

Raw owner input and model output are never stored here. Quality case names
refer to the existing repository benchmark fixtures. Scratch environments,
prototype adapters and trace bundles remain in `/tmp/velora-latency-20261029`;
they are not installed into Velora.
