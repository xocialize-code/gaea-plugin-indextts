# gaea-plugin-indextts

[IndexTTS 2.5](https://huggingface.co/IndexTeam/IndexTTS-2.5) (bilibili IndexTeam) as a [Gaea](https://github.com/xocialize-code/gaea)
plugin on MES Audio 0.1: speech in a voice cloned from a clip, in Chinese, English, Japanese, Spanish and Arabic. The
emotion is set apart from the voice, and the length can be fitted to a cue. It runs
[mlx-indextts2-swift](https://github.com/xocialize/mlx-indextts2-swift) through MLXEngine, on GaeaPluginKit.

Install it in Gaea with `gaea plugins add https://github.com/xocialize-code/gaea-plugin-indextts`.

## The offer

One model, `indextts-2.5`, on `audio.speak`:

| | |
|---|---|
| Voice | `voice_ref`, a clip of 1 to 20 s (longer is trimmed). No preset voices and no default voice. `voice_ref_text` isn't used |
| Languages | `zh`, `en`, `ja`, `es`, `ar`. Unnamed text is detected by script; Latin script is read as English, so name `es` for Spanish |
| Emotion | A label: `neutral`, `happy`, `angry`, `sad`, `afraid`, `disgusted`, `melancholic`, `surprised`, `calm`. `intensity` 0–1 (0.6 when absent) |
| `x-indextts.emotion_vector` | Instead of a label: eight weights, 0–1.2, in the order happy, angry, sad, afraid, disgusted, melancholic, surprised, calm |
| Length | `target_duration_s` fits the take to a cue (pauses kept); `speed` 0.5–2 sets the pace. With both, the duration wins (`param_adjusted`) |
| Cues | `[pause Ns]`; Gaea removes any other cue with `cue_unsupported` |
| Output | 16-bit mono WAV at 22.05 kHz; Gaea converts to what the request asks for |
| Lanes | `fp16` (the default, as shipped), `int8` and `int4`: the GPT backbone's quant. About 4.6 / 4.2 / 3.9 GB resident, about 9.3 GB at peak |
| Licence | The weights: the [bilibili Model Use Licence](https://huggingface.co/IndexTeam/IndexTTS-2.5), allowing commercial use below 100 M monthly users. This plugin and the port: Apache-2.0 |

A seeded request is reproducible: the worker seeds MLX's random state and the package before every piece. Numbers aren't
spelled out in Chinese and English, so write them as words.

## Building and checking

```
swift test
scripts/build-plugin.sh                 # the worker, manifest.json (validated), the signed bundle and its zip in dist/
scripts/check-plugin.sh                 # drive the bundle over GPP with every .build hidden, plus the metallib control
scripts/golden.sh <out-dir>             # 8 seeded cases over GPP against indextts-inproc, byte for byte
```

The checks read IndexTTS 2.5's weights from `CHECK_MODELS_ROOT` (default `/Volumes/DEV_VOL1/Models/Models`) and never
download. `scripts/fixtures/ref-en.wav` is the reference clip they clone, made with macOS's `say`.

`indextts-inproc` runs the same package in-process with the worker's requests and seeding, for comparison:
`indextts-inproc --ref <wav> --text "…" [--language en] [--emotion happy --intensity 0.8] [--vector …] [--target-duration 4] [--speed 1.2] [--seed 42] [--lane fp16]`.

`Package.swift` names the fleet's mlx-swift fork (`xocialize/mlx-swift`), as mlx-engine-swift 0.74.1 does. A root line
naming ml-explore's URL would win, and could drop the fix for a leak that kills workers that reload quantized models
(Gaea AB-L-0330).

## Releasing

Push a `v<version>` tag matching the manifest's version. CI (`.github/workflows/release.yml`, the `xcode-27` runner)
builds, signs, notarizes and publishes the zip, its sha256 and `manifest.json`. CI secrets: `DEVELOPER_ID_P12_BASE64`,
`DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID` and `NOTARY_APP_PASSWORD`, organization secrets on xocialize-code.
