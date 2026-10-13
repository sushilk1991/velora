Build a speech classifier over Velora's available actions, then test dynamic action descriptions.

# Local speech-to-action research

Checked against primary sources on 2026-10-13. The reference is [Mira's Thud demo](https://x.com/caineardayfio/status/2110035727753126298). Velora's intended action scope still needs definition. This note distinguishes action classification from functions with generated arguments. Tool benchmarks do not establish general GUI autonomy.

## What Thud demonstrates

Mira describes Thud as a native audio classifier that selects among prompt-defined categories, returns confidence probabilities, and runs locally/on a phone. Its launch page reports 114.8 ms classification; the chart reports 107.6 ms median versus 383.8 ms for Qwen ASR + Jev and 985.1 ms for Gemini Live. Estimated cost per 1,000 requests is $0.098, $0.190, and $1.92–2.39 respectively. These are publisher claims. The page omits architecture, model size, weights, training recipe, evaluation data, hardware, audio duration, and measurement boundaries. It does not establish open-ended argument extraction or arbitrary desktop control. [Thud launch, 2026-10-13](https://trymira.com/blog/meet-thud).

For matching menu navigation, first test a pretrained speech encoder with an action-classification head. Add a no-action category. Then train a scorer conditioned on candidate action descriptions so categories can change with the app state. A fixed classifier alone does not reproduce Thud's prompt-defined categories. This is our proposed implementation; Thud's internal design is undisclosed. Use an audio-language model when the action needs free-form arguments, such as search text or message content.

The demo overlays show candidate scores, menu navigation, and reported timings. One frame labels Spotify search at 1.9 seconds; another labels opening Alex's conversation at 313 ms. These examples do not support a universal 200 ms full-workflow guarantee. The sound-detection scores can sum above one, consistent with independent category scores; the scoring implementation remains unknown. [Launch video](https://x.com/caineardayfio/status/2110035727753126298).

## Proposed classifier pilot

```text
microphone -> speech encoder -> candidate scorer -> calibrated decision
                                    ^                     |
                                    |                     v
                         current app actions       existing validator
                                                          |
                                                          v
                                                     Mac executor
```

1. Define 10–20 executable actions and a no-action outcome. Bind each candidate to the app's current state and a stable action ID. Reuse Velora's executor and verification contract. [Current Action Mode](../ARCHITECTURE.md#action-mode).
2. Prove audio-to-action classification with a pretrained speech encoder and a small learned head. WavLM Base Plus documents downstream audio-classification fine-tuning and is an English candidate; it provides speech features without generating a transcript. Multilingual commands need a separately evaluated encoder. [Microsoft model card](https://huggingface.co/microsoft/wavlm-base-plus).
3. Collect audio, available-action descriptions, and correct action IDs. Include negation, ordinary conversation, background speech, noise, similar names, and unsupported commands. A first collection budget of 2,000–5,000 real clips is a planning estimate; learning curves determine whether it is enough.
4. Train a candidate-conditioned scorer using positive and hard-negative audio/action pairs. Score candidates independently to avoid positional bias, then calibrate selection and abstention on separate data. A small text encoder with an audio/text scoring head is one experiment. Test unseen descriptions and changed candidate sets before claiming dynamic categories.
5. Measure speech-end to validated-action latency, exact action correctness, wrong-target rate, and abstention on an Apple Silicon Mac. Test quantized inference against the original model. Keep decisions behind the existing validator and re-read the target before execution. Streaming inference is a separate experiment; act only after command completion, since a later word can reverse intent.

Our engineering estimate is 2–4 weeks for one ML engineer to build a narrow classifier pilot if recordings and executors are available. Dynamic-category generalization and reliable argument extraction need separate work and evaluation. A training GPU and an Apple Silicon test Mac are sufficient infrastructure to begin; memory requirements depend on the encoder, clip length, batch size, and frozen layers.

## Which model fits?

| Candidate | Verified capability | Fit for Velora |
| --- | --- | --- |
| FunctionGemma 270M | Text-only Gemma 3 model trained for function calling; Google expects task-specific fine-tuning. | Small action parser after existing STT. Direct audio needs a new encoder, connector, training, and runtime integration. |
| LFM2.5-Audio-1.5B | Native audio/text model; 1.2B language backbone plus a 115M FastConformer encoder and audio-output components. English checkpoint; separate Japanese variant exists. | Argument-generation experiment after the classifier pilot. Use audio input and text action output; spoken responses are optional. |

FunctionGemma's official Mobile Actions recipe fine-tunes text requests into OS functions using Hugging Face TRL and exports to LiteRT-LM. Google's reported task accuracy rises from 58% to 85%; Velora needs its own product evaluation. [FunctionGemma overview](https://ai.google.dev/gemma/docs/functiongemma), [model card](https://ai.google.dev/gemma/docs/functiongemma/model_card), [Mobile Actions recipe](https://ai.google.dev/gemma/docs/mobile-actions).

LFM2-Audio-1.5B has a newer official successor, LFM2.5-Audio-1.5B, announced on 2026-01-05. Its card reports ASR, speech chat, and voice instruction benchmarks. It does not report audio-to-function-call accuracy. Liquid's current library explicitly supports function-calling fine-tuning, added in v1.2.0; the checked package revision is v1.3.0. That makes adaptation supported, while the resulting action accuracy still needs measurement. [Release](https://www.liquid.ai/blog/introducing-lfm2-5-the-next-generation-of-on-device-ai), [audio model card](https://huggingface.co/LiquidAI/LFM2.5-Audio-1.5B), [fine-tuning support](https://github.com/Liquid4All/liquid-audio/tree/19e65845923a7f136442c95137884ec61eb386aa).

Liquid's official voice-controlled car demo runs audio STT/TTS and a separate text tool model. It does not demonstrate a single audio-to-action model. [Car cockpit demo](https://docs.liquid.ai/examples/laptop-examples/audio-car-cockpit).

## Extending to generated arguments

1. Retain Velora's current STT-to-actions path as the baseline. FunctionGemma is an optional smaller text-parser experiment, trained on actual action schemas, arguments, context, clarification requests, and no-action cases. Google provides supervised fine-tuning and synthetic teacher-data examples. [Fine-tuning guide](https://ai.google.dev/gemma/docs/functiongemma/finetuning-with-functiongemma).
2. Fine-tune LFM2.5-Audio on audio input, tool/context text, and the expected serialized action. Its official preprocessing API accepts audio and text chat segments. The example trainer uses BF16, Accelerate, and AdamW over model parameters; it does not provide a turnkey LoRA or MLX training recipe. Prototype training on a suitable GPU; local inference and local training are separate requirements. [Trainer](https://github.com/Liquid4All/liquid-audio/blob/19e65845923a7f136442c95137884ec61eb386aa/src/liquid_audio/trainer.py), [training example](https://github.com/Liquid4All/liquid-audio/blob/19e65845923a7f136442c95137884ec61eb386aa/examples/train.py).
3. If measured memory or latency requires a smaller model, connect a pretrained speech encoder to FunctionGemma through a small learned projector. First freeze encoder/backbone and align the projector using audio/transcripts; then train projector plus backbone adapters on audio/action pairs. Liquid's published architecture uses this frozen alignment stage before broader training. Applying it to FunctionGemma is our proposed experiment and requires validation. A 115M encoder plus a 270M backbone is about 385M parameters before the connector. [LFM2 technical report, §§6.1–6.3](https://arxiv.org/html/2511.23404v1#S6).

Use our own consented recordings or speech data licensed for product training. SLURP audio is CC BY-NC 4.0; Fluent Speech Commands restricts commercial training/testing. Neither is a default commercial training source. [SLURP license](https://github.com/pswietojanski/slurp#license), [Fluent dataset terms](https://www.fluent.ai/fr/fluent-speech-commands-a-dataset-for-spoken-language-understanding-research/).

Keep speakers and phrase families out of the training split. Evaluate exact action/argument correctness, abstention, noise, accent, correction, ambiguity, and end-to-end execution. Synthetic/TTS examples can expand coverage; holdouts need real speech. Any sample counts, GPU budget, or schedule we propose are planning estimates.

## Apple Silicon deployment

| Runtime | FunctionGemma | LFM2.5-Audio |
| --- | --- | --- |
| MLX | MLX-LM supports its Gemma 3 text architecture; community quantized checkpoints exist. | MLX-Audio provides a port with audio input, text output, and speech generation. Liquid's own format table still marks audio MLX unsupported; treat the port as community support. |
| llama.cpp | GGML organization publishes a FunctionGemma GGUF. | Official GGUF uses custom `llama-liquid-audio` runners from PR #18641. The PR remains open/unmerged, titled `[Do Not Merge]`; generic installed llama.cpp audio support is unproven here. |
| Core ML | A community CoreML-LLM port and conversion scripts exist. | No complete LFM2.5-Audio Core ML path was verified in this review. Encoder/backbone conversion would need its own parity and device checks. |

Sources: [MLX-LM architecture](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/models/gemma3_text.py), [FunctionGemma MLX formats](https://huggingface.co/collections/mlx-community/functiongemma), [MLX-Audio implementation](https://github.com/Blaizzy/mlx-audio/blob/e66ad2ff4eb96ce1149000187b30370cbcd707aa/mlx_audio/sts/models/lfm_audio/README.md), [Liquid format table](https://docs.liquid.ai/lfm/models/complete-library), [FunctionGemma GGUF](https://huggingface.co/ggml-org/functiongemma-270m-it-GGUF), [audio GGUF runner instructions](https://huggingface.co/LiquidAI/LFM2.5-Audio-1.5B-GGUF), [live PR](https://github.com/ggml-org/llama.cpp/pull/18641), [CoreML-LLM port](https://github.com/john-rocky/CoreML-LLM).

No weights were downloaded and no inference or training was run. Mac latency, peak memory, quantization accuracy, and action reliability remain unmeasured. Google's phone latency and Liquid's faster audio detokenizer do not predict Velora's speech-to-action latency.

## Licenses and pinned sources

Gemma allows commercial use under its custom terms and redistribution obligations. LFM Open License v1.0 restricts commercial use above its $10M annual-revenue threshold; retain its license and attribution notices. Canary and Mimi weights add CC BY 4.0 attribution requirements. [Gemma terms](https://ai.google.dev/gemma/terms), [LFM license](https://huggingface.co/LiquidAI/LFM2.5-Audio-1.5B/blob/c362a0625dfe45aa588dce5f0ada28a7e5707628/LICENSE), [component licenses](https://huggingface.co/LiquidAI/LFM2.5-Audio-1.5B#license).

Checked model revisions: FunctionGemma `39eccb091651513a5dfb56892d3714c1b5b8276c`; LFM2.5-Audio `c362a0625dfe45aa588dce5f0ada28a7e5707628`; audio GGUF `7d525f883a077e20afb782f2ff618edcae0e39e4`. Library revisions: liquid-audio `19e65845923a7f136442c95137884ec61eb386aa`; MLX-Audio `e66ad2ff4eb96ce1149000187b30370cbcd707aa`; llama.cpp audio PR head `ec9d1fdd9cc18643c5e161b65b8053f6f6f34a4b`.

Next: name the first actions and required languages before selecting a training target.
