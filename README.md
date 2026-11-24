# gaea-plugin-longcat-avatar

Meituan's **LongCat-Video-Avatar 1.6** ([model card](https://huggingface.co/meituan-longcat/LongCat-Video-Avatar-1.6),
MIT) as a [Gaea](https://github.com/xocialize-code/gaea) plugin: an audio-driven talking avatar. A first frame (the
person), a soundtrack (the speech) and a prompt make a clip in which the person speaks it, lip-synced, at 25 fps, with
the soundtrack as its audio.

It is built on [GaeaPluginKit](https://github.com/xocialize-code/gaea-plugin-kit) over
[longcat-avatar-mlx-swift](https://github.com/xocialize/longcat-avatar-mlx-swift), runs in its own process, and speaks
the Gaea Plugin Protocol v1. Add it to Gaea by its repo URL:

```bash
gaea plugins add https://github.com/xocialize-code/gaea-plugin-longcat-avatar
```

## What it offers

| Model | MES operation | Lanes | Notes |
|---|---|---|---|
| `longcat-avatar-1.6` | `video.generate` | `bf16` (default), `int8`, `int4` | A first frame and a soundtrack, both required; 25 fps; 1 s to 60 s. |

- **Inputs.** `first_frame` is the person and `soundtrack` is the speech. Both are required: a request without either
  is refused. `prompt` describes the scene. Give clean speech: upstream's vocal separator is not ported, so music or
  noise under the voice drives the mouth too.
- **Length.** The soundtrack's, unless `duration_s` says otherwise. Any whole number of frames from one second up:
  there is no frame grid. When the clip and the soundtrack differ in length the soundtrack is cut, or padded with
  silence, with `soundtrack_fitted`. Past 60 s is `out_of_limits`; a soundtrack longer than that is cut to it.
- **Time.** The model works in segments: 93 frames (3.72 s) from the first frame, then 80 more (3.2 s) per
  continuation, each conditioned on the end of the one before. A full segment takes about ten minutes on an M5 Max, so
  a 30 s clip is roughly an hour and a half.
- **Size.** The model makes a fixed table of sizes, about 400,000 pixels each (upstream's 480p buckets): 832×480 for
  16:9, 480×832 for 9:16, 640×608 near square, and 23 more between 1280×320 and 320×1216. Without `size` or `aspect`
  the clip takes the one closest to the first frame's shape; the frame is scaled to cover it and centre-cropped. A
  `size` that isn't in the table gets the closest shape, with `size_snapped`. An `aspect` names a shape, so it is
  never snapped.
- **Rate.** The model's motion and lip-sync are 25 fps. Another `fps` is made at 25, with `fps_adjusted`.
- **Sound.** The clip's audio is the soundtrack as 48 kHz mono AAC. `audio: false` gives the picture only.
- **No guidance.** Sampling is distilled to 8 steps without classifier-free guidance: a `negative_prompt` is reported
  `negative_prompt_ignored`.
- **Not taken.** A last frame, keyframes, references, control clips and adapters are refused.
- **Seeds.** A request without a seed gets one, reported in `effective.seed`.
- Gaea marks every clip it makes as AI-generated (Video §1.9).

## How 1.6 runs

A 13.6 B-parameter video DiT with an audio cross-attention path, the Wan 2.1 VAE, umT5-XXL for the prompt and a
Whisper-large-v3 encoder for the speech. 1.6 ships two distillation LoRAs over one base DiT and switches between them
part-way through the denoise: steps 1–4 run the DMD LoRA, steps 5–8 the OPSD LoRA (upstream's `--mix_steps=4
--mix_alpha=1.0`). They run as side-paths beside the base weights rather than merged into them, which is also why the
same LoRAs work over the 8-bit and 4-bit DiTs.

## Weights

One repo per lane, fetched by the engine into the models root Gaea sends. Each holds the DiT at the lane's precision,
both LoRAs, umT5-XXL and its tokenizer, the Whisper encoder and the VAE (all bf16 but the DiT).

| Lane | Repo | Size |
|---|---|---|
| `bf16` | `mlx-community/LongCat-Video-Avatar-1.6-bf16` | 46 GB |
| `int8` | `mlx-community/LongCat-Video-Avatar-1.6-q8` | 33 GB |
| `int4` | `mlx-community/LongCat-Video-Avatar-1.6-q4` | 26 GB |

They are converted from `meituan-longcat/LongCat-Video-Avatar-1.6` by
[longcat-avatar-mlx](https://github.com/xocialize/longcat-avatar-mlx)'s recipe.

## Memory and speed

Measured 2026-11-24 on an M5 Max (128 GB, macOS 27.3) through the signed bundle with `gaea-plugin-check`, which
launches the worker the way Gaea does. Each run is a fresh worker process; weights on an external USB volume. Logs are
in `receipts/`.

One full segment (93 frames, 3.72 s) at 768×512:

| Lane | After prepare | Worker lifetime peak (`phys_footprint`) | After the job | Run | Declared lane need |
|---|---|---|---|---|---|
| `bf16` | 37.8 GB | **57.7 GB** | 41.1 GB | 565 s | 62.0 GB (resident 38.0 + peak activation 24.0) |
| `int8` | 23.8 GB | **43.9 GB** | 27.1 GB | 627 s | 48.5 GB (24.0 + 24.5) |
| `int4` | 16.3 GB | **36.3 GB** | 19.2 GB | 622 s | 40.5 GB (16.5 + 24.0) |

- **Length doesn't raise the peak.** A longer clip is more segments of the same size: about nine minutes per 3.2 s.
- **Shorter is faster.** 1 s (25 frames) ran in 111 s and 2 s (50 frames) in 272 s on `bf16`.
- **The quantized lanes are for memory, not speed.** They take a little longer than `bf16` here.
- **Prepare** is 4–5 s on a warm file cache and 65–82 s cold from the USB volume (the engine pages the weights first).
- The peak is the request's own working set: umT5-XXL (11 GB) is paged in for the prompt and evicted before
  denoising, and the VAE decodes one latent frame at a time.

`receipts/sheet_bf16_over_int4_93f.png` shows frames 0, 30, 60 and 92 of the same request on `bf16` (top) and `int4`
(bottom): the same composition and identity, slightly softer detail at 4-bit.

`scripts/check-plugin.sh` passed on the `bf16` lane (`receipts/check.log`): signature and launch requirement, hello
against the manifest, prepare, a 2 s clip, the memory report, the transcript through `tools/validate.py`, and the
metallib control.

## Build, check, release

See the [plugin authoring guide](https://github.com/xocialize-code/gaea-plugin-demo/blob/main/AUTHORING.md).

```bash
scripts/build-plugin.sh
```

```bash
CHECK_MODELS_ROOT=<a models root with the lane's repo> scripts/check-plugin.sh
```

- `build-plugin.sh` builds the worker, writes and validates `manifest.json`, assembles and signs the bundle, and zips
  it into `dist/`.
- `check-plugin.sh` drives the signed bundle over GPP the way Gaea does, with every build folder hidden: a 2 s clip
  from the fixture first frame and soundtrack (50 frames at 768×512, seed 7; about five minutes), then the transcript
  through `tools/validate.py`, then a control that proves the metallib comes from the bundle. `CHECK_LANE` picks the
  lane (default `bf16`).
- `longcat-avatar-inproc` runs the same request in-process through MLXServeEngine, with the lane configuration and
  the plan the worker uses: the reference for a run through Gaea.
- `release.sh` (or the `release` workflow on a `v*` tag) builds, checks, notarizes and publishes the release assets.

`LONGCAT_AVATAR_SWIFT_PATH` and `GAEA_PLUGIN_KIT_PATH` build against local checkouts.

The fixtures in `Tests/Fixtures`: `presenter.png` is upstream's demo portrait
(`assets/avatar/single/man.png` in [meituan-longcat/LongCat-Video](https://github.com/meituan-longcat/LongCat-Video),
MIT), scaled down; `speech.wav` is synthetic speech from macOS `say`.

## Versions

- longcat-avatar-mlx-swift 0.2.0, mlx-engine-swift 0.82.1 (contract 1.66.0), GaeaPluginKit 0.16.0.
- mlx-swift: the fleet fork at 0.33.1 (upstream 0.33.0 with the split-head attention routes off, AB-D-0264).

## Licence

The plugin's code is Apache-2.0 (`LICENSE`). It links longcat-avatar-mlx-swift (MIT), a port of Meituan's
LongCat-Video code (MIT). The weights are MIT. This plugin is not affiliated with or endorsed by Meituan.
