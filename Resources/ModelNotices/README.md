# Speech model notices

Velora can use the Underdog Bark 3.0 English speech models by Conway Research,
licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
The files here are byte-exact copies from the pinned Hugging Face revisions.

| File | Source |
|---|---|
| `Underdog-Bark-3.0.NOTICE` | `ConwayResearch/Underdog-Bark-3.0` @ `85db2ad18ab41e534a222ee253c29191d77ed919`, `NOTICE` |
| `Underdog-Bark-3.0-Clean.NOTICE` | `ConwayResearch/Underdog-Bark-3.0-Clean` @ `6d34ed8639b2b9a33e764acf06748519bbb950cf`, `NOTICE` |
| `CC-BY-4.0.LICENSE` | `ConwayResearch/Underdog-Bark-3.0` @ `85db2ad18ab41e534a222ee253c29191d77ed919`, `coreml/LICENSE` |

The Clean repository publishes no license file. Its model card declares
`cc-by-4.0`, and `CC-BY-4.0.LICENSE` is that license's legal code.

Velora redistributes the model files unmodified. On your Mac, Velora may unpack
`model.bark` into a local cache. That cache holds fp16 weights, or 8- or 4-bit
affine quantization (group size 64) on smaller Macs. Velora may also compile the
Core ML encoder for your device. These derived files stay on your Mac.
