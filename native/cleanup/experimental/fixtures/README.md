# Student-header cache stress fixture

`header-stress.jsonl` contains 12 public synthetic inputs. Long repeated instructions exercise header capture and reuse; changing mode, language, vocabulary and transcript exercises cache identity. The last two cases contain a synthetic previous-piece canary and must fall back from the student-header strategy. `header-stress-prompts.json` records the corresponding prompt token IDs, not generated output. The file hashes and the specific model and template identities for those IDs are in `header-stress.manifest.json`.

Run only in a reserved inference window. From the repository root, set `BINARY`, `MODEL`, `MODEL_SHA256`, and `OUT_DIR` to caller-owned paths. Use the model SHA in the manifest with this prompt reference; regenerate the reference for a different tokenizer or template. The output directory must already exist and both output filenames must be new.

```sh
PYTHONPATH=training/cleanup engine/.venv/bin/python native/cleanup/benchmark.py \
  --binary "$BINARY" --model "$MODEL" --sha256 "$MODEL_SHA256" \
  --data native/cleanup/experimental/fixtures/header-stress.jsonl \
  --reference-tokens native/cleanup/experimental/fixtures/header-stress-prompts.json \
  --out "$OUT_DIR/header-off.jsonl" --limit 12 --copy-draft --prefix-cache \
  --draft-max 8 --prefill-batch 128 --max-tokens 512 --deadline-ms 30000

PYTHONPATH=training/cleanup engine/.venv/bin/python native/cleanup/benchmark.py \
  --binary "$BINARY" --model "$MODEL" --sha256 "$MODEL_SHA256" \
  --data native/cleanup/experimental/fixtures/header-stress.jsonl \
  --reference-tokens native/cleanup/experimental/fixtures/header-stress-prompts.json \
  --reference-output "$OUT_DIR/header-off.jsonl" \
  --out "$OUT_DIR/header-on.jsonl" --limit 12 --copy-draft --prefix-cache \
  --draft-max 8 --prefill-batch 128 --max-tokens 512 --deadline-ms 30000 \
  --student-prefix-cache
```

The opt-in run requires observed bounded header capture and restored hit, strict recovery, and exact complete prompt/output token, status and text parity against the matching control. Check `student_header_evidence` and `output_reference_parity` in its metadata. Reuse both control output and its `.meta.json` together. These synthetic tests do not establish semantic quality or performance.

The separate short 96-case public fixture did not exercise a header capture or hit in the observed run. An opt-in qualification on that short fixture is expected to fail the exercise gate even when its outputs match; it is not a substitute for this positive stress fixture.
