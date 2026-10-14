Evaluate Haku's reader against Velora's speech corpus once its source and weights ship.

# EmbeddingGemma 2 speech-to-text

Primary sources checked on 2026-10-14. The reference is [Shahir's experiment](https://x.com/tslshahir/status/2109660368381395414). No weights were downloaded, models run, or production configuration changed.

## What Google released

EmbeddingGemma 2 is a multimodal embedding model released on 2026-10-06 under Apache 2.0. It produces 768-dimensional representations for search, classification, and similarity. Google's release evaluates embeddings, not transcription WER. The full model is about 740M parameters: 270M text model, 170M vision encoder, and 300M audio encoder. Text plus audio is about 570M. [Official model card](https://huggingface.co/google/embeddinggemma-2), [Google launch](https://blog.google/innovation-and-ai/technology/developers-tools/embeddinggemma-2/).

The audio tower uses Gemma 4's audio architecture. The released config specifies 12 layers, hidden dimension 1,024, and output projection dimension 1,536. Google's embedding pipeline projects the tower's frame features into the text model, then mean-pools its output. A CTC reader needs sequence features; the final pooled vector has no frame-by-frame output. This requirement follows from the published model structure. [Pinned configuration](https://huggingface.co/google/embeddinggemma-2/blob/914f7f89142e33e77833254d9c9b90c3cef7303b/config.json), [Transformers implementation](https://github.com/huggingface/transformers/blob/main/src/transformers/models/embedding_gemma2/modeling_embedding_gemma2.py).

Google requires mono 16 kHz audio; the complete embedding path uses about 25 audio tokens per second and an 8,192-token context. The card claims 100+ languages, with uneven performance, and multilingual speech in training. That does not establish multilingual transcription accuracy for a new reader. [Model card, input and language limits](https://huggingface.co/google/embeddinggemma-2#best-practices).

## What Haku added

Shahir says the audio encoder stays frozen. A trained CTC reader maps frame sequences to EmbeddingGemma's text embeddings for roughly 229,000 English words; a separate small model restores punctuation and capitalization. Reported reader training took under two hours on eight H100 GPUs using openly licensed English speech. [Haku description](https://eg2.haku.sh/), [author's technical clarification](https://news.ycombinator.com/item?id=50071579).

```text
audio -> frozen audio encoder -> trained CTC reader
      -> word-vector lookup -> punctuation -> transcript
```

Haku's site reports one hour of audio in 12.6 seconds on an 8 GB M3 MacBook Air using the Neural Engine, with about 5% WER. Its 288 times real-time figure measures audio duration divided by processing duration. These are author measurements; evaluation corpus, normalization, and the full timing boundaries are not published there. File throughput does not establish latency after a short dictation ends. [Haku benchmark](https://eg2.haku.sh/#how-fast).

As checked today, a free Mac app is downloadable, but I found no public reader source or standalone reader-weight release linked from its site or the author's public repositories. The author says open sourcing will take a few days and confirms English-only support, with a multilingual reader planned. Google's Apache license does not establish the unreleased reader's license. [Author's release statement](https://news.ycombinator.com/item?id=50071209), [public repositories](https://github.com/shershah1024?tab=repositories), [author's language statement](https://news.ycombinator.com/item?id=50069971).

## Apple Silicon and Velora

Google documents Sentence Transformers and Transformers inference and lists MLX among available runtimes. Its original checkpoint's activations require BF16 or FP32; FP16 is unsupported. Google's generic runtime listing does not prove a CTC reader runs on the Neural Engine or that a particular runtime exposes the required audio frames. Haku's Core ML export, quantization, reader, and decoding need their own reproducible release and checks. [Google developer guide](https://developers.googleblog.com/en/embeddinggemma-2-the-developer-guide/), [precision instructions](https://ai.google.dev/gemma/docs/embeddinggemma/multimodal-embeddinggemma-with-sentence-transformers).

Velora already separates recognition behind [`STTBackend`](../../engine/src/velora_engine/stt.py). A released reader could become another backend, with explicit selection in `create_backend`. The engine measures recognition after stop as `stt_ms` and subsequent formatting as `cleanup_wall_ms` in [`server.py`](../../engine/src/velora_engine/server.py). Measure both stages and insertion: a faster recognizer only reduces part of the user's wait.

Compare short-utterance completion time, WER, proper names, numbers, mixed languages, noise, punctuation, and peak memory on the same Mac and recordings as the production engine. An English-only reader cannot establish parity with multilingual dictation. Preserve Velora's current model pair until those checks support a change.

Checked Google model revision: `914f7f89142e33e77833254d9c9b90c3cef7303b`, last modified 2026-10-06. Haku app advertised as v1.6; no public reader revision was verified.

Next: obtain the reader's public source, weights, and license, then run an isolated comparison.
