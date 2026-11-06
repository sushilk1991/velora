# Fixed-prompt prefill sweep

Run only in the root-reserved inference window. Import and CPU tests do not load a model. Supply an external UTF-8 payload file and external system-prompt file; the driver preserves their exact decoded contents, including line endings, and never modifies them. Control delimiters are rejected before model load; explicitly prepare neutralized input files if needed.

```sh
engine/.venv/bin/python native/cleanup/experimental/prefill_sweep.py \
  --payload-file "$EXTERNAL_PAYLOAD" --system-prompt-file "$EXTERNAL_SYSTEM" \
  --output "$NEW_EXTERNAL_REPORT_DIRECTORY" \
  --binary /tmp/velora-native-research/build/velora-cleanup-native \
  --model "$GGUF" --sha256 "$GGUF_SHA" \
  --context 8192 --research-long-context
```

Default: two counterbalanced rounds, six batches (16,32,64,128,256,512), one fresh supervised worker per arm, one warmup plus three measured requests. A seeded shuffle determines the first round; the next reverses it. Default scalar decoding and prefix-cache off isolate fixed-prompt prefill. Trace is on to record **first_decision_ms**, which includes tokenization, prefix processing and the first completed sample; it is not streamed TTFT or isolated GPU prefill time.

Default `--max-tokens 1` is diagnostic. A one-token `length` response is expected and never called a completed summary. For an EOS-oriented arm use `--max-tokens 1024 --max-output-tokens 2048 --research-long-context`; EOS completion still does not establish semantic note quality. Every response, including warmups, failures and partial results, is retained outside the repository with prompt/output IDs, status, ready metadata, RSS and timing. Missing arms invalidate comparison. Any prompt/token/status/text difference is reported and invalidates the fixed-prompt comparison gate.

Use a separate fresh output directory for `--bounded-swa` on/off comparisons. `--copy-draft --draft-max 8` and `--prefix-cache` are opt-in independent controls. `--no-trace-runtime` can confirm a measured winner without trace overhead. Run full native recovery and quality qualification separately; this sweep does not claim it.

Reports are stored with directory0700/file0600 permissions. The manifest records input/binary/model hashes, source hashes, upstream pin, actual arm order, seed and every setting. Input/binary/source mutation during execution invalidates the summary. Transport failures retire the worker and leave partial arm files plus explicit missing-count evidence. Existing output directories are never reused. Standard output contains only report location and aggregate gates, no prompt or generated content.
