# tts-serve in Docker — CUDA and ROCm

Six engines, one container each, driven by docker compose, with a switchable
accelerator backend: NVIDIA (CUDA), AMD on native Linux (ROCm), or AMD on a
Windows PC via WSL2 — for that last one, see
[`windows/README.md`](../windows/README.md). On a Mac, run the engines
natively instead: [`macos/README.md`](../macos/README.md).

```bash
cd /opt/tts-serve
cp .env.example .env          # pick your backend in here (see below)
docker compose --profile chatterbox up -d --build
curl http://localhost:7500/health
```

Swap `chatterbox` for `qwen3tts`, `voxcpm`, `indextts`, `omnivoice`, or `luxtts`; `--profile all` runs
every engine. Nothing starts without a profile, so a bare `docker compose up` is
a no-op by design.

| Engine | Host port | Rate | Reference transcript |
|---|---|---|---|
| Chatterbox | 7500 | 24 kHz | not used |
| Qwen3-TTS | 7501 | 24 kHz | optional |
| VoxCPM | 7502 | 48 kHz | optional (enables "ultimate cloning") |
| IndexTTS-2.5 | 7503 | 22.05 kHz | not used |
| OmniVoice | 7504 | 24 kHz | optional (omitted: Whisper auto-transcribes, slow) |
| LuxTTS | 7505 | 48 kHz | not used (the engine always transcribes the clip with Whisper) |

Each exposes the standard tts-serve surface: `GET /health`, `GET /capabilities`,
`GET /docs`, `POST /synthesize`.

## Switching backend: CUDA vs ROCm

`docker-compose.yml` is backend-agnostic — on its own it carries no GPU wiring
and no torch versions, and will not start anything. It is always combined with
exactly one overlay:

| File | Backend |
|---|---|
| `docker-compose.cuda.yml` | NVIDIA, cu126 wheels, `driver: nvidia` device reservation |
| `docker-compose.rocm.yml` | AMD, ROCm wheels, `/dev/kfd` + `/dev/dri` passthrough |
| `docker-compose.rocm-wsl.yml` | AMD under WSL2, `/dev/dxg` + host WSL HSA runtime shadowed into torch |

Select it once in `.env` and every later command just works:

```bash
COMPOSE_FILE=docker-compose.yml:docker-compose.cuda.yml
#COMPOSE_FILE=docker-compose.yml:docker-compose.rocm.yml
#COMPOSE_FILE=docker-compose.yml:docker-compose.rocm-wsl.yml
```

The separator is `:` on Linux and `;` on Windows; `COMPOSE_PATH_SEPARATOR`
overrides it. Or pass the files explicitly:

```bash
docker compose -f docker-compose.yml -f docker-compose.rocm.yml \
  --profile voxcpm up -d --build
```

Images are tagged per backend (`tts-serve/chatterbox:cu126` against
`tts-serve/chatterbox:rocm6.2.4`), so both can coexist without clobbering
each other.

**The engine code needs no changes to move between backends.** PyTorch's ROCm
build exposes AMD GPUs through the same `torch.cuda` API and the same `"cuda"`
device string that every tts-serve server already checks for, so `*_DEVICE=cuda`
is correct on both. The whole difference is the wheel index and the device
wiring.

> **Status:**
> - **CUDA:** verified end to end on a Tesla P40 for the original four engines.
>   OmniVoice and LuxTTS follow the same pattern but haven't been run on NVIDIA.
> - **ROCm on WSL2** (`docker-compose.rocm-wsl.yml`): **verified** for OmniVoice
>   and LuxTTS on an RX 7800 XT. Chatterbox does not work there (see
>   [`windows/README.md`](../windows/README.md)).
> - **ROCm on native Linux** (`docker-compose.rocm.yml`): **untested** — built
>   from verified wheel availability and AMD's documented device wiring.

## Why torch is pinned per engine

This is the part that makes or breaks the build.

The engines disagree about torch, two of them by exact pin, so no single
version satisfies all of them:

| Engine | Requires | CUDA build | ROCm build | Python |
|---|---|---|---|---|
| Chatterbox | `torch==2.6.0` | 2.6.0+cu126 | 2.6.0+rocm6.2.4 | 3.12 |
| Qwen3-TTS | unpinned | 2.8.0+cu126 | 2.8.0+rocm6.4 | 3.12 |
| VoxCPM | `torch>=2.5.0` | 2.8.0+cu126 | 2.8.0+rocm6.4 | 3.12 |
| IndexTTS-2.5 | `torch==2.8.*` | 2.8.0+cu126 | 2.8.0+rocm6.4 | **3.11** |
| OmniVoice | `torch>=2.4` | 2.8.0+cu126 | 2.8.0+rocm6.4 | 3.12 |
| LuxTTS | unpinned | 2.8.0+cu126 | 2.8.0+rocm6.4 | 3.12 |

Chatterbox is why the ROCm side needs two different indexes: `rocm6.2.4` is the
one carrying torch 2.6.0, since 6.3 and 6.4 start at 2.8.0.

Each image takes `TORCH_INDEX`, `TORCH`, `TORCHAUDIO`, `TORCHVISION` and
`TORCH_BUILD_TAG` as build args — supplied by the overlay — and writes those
exact versions into a constraints file applied to every later install, via
`PIP_CONSTRAINT` and `UV_CONSTRAINT`. An engine that drags in a different torch
fails at **build** time instead of producing a broken image.

Because a version constraint alone cannot tell `2.8.0+cu126` from
`2.8.0+cu128` or `2.8.0+rocm6.4`, every image ends with an assertion that the
installed torch carries the expected backend tag. If a build dies with
`ResolutionImpossible` or that `FATAL:` message, the guard is working — find
what the engine actually requires and set the build arg, rather than relaxing
the constraint.

IndexTTS is on Python 3.11 because upstream declares
`requires-python = ">=3.10,<3.12"`.

## NVIDIA notes — Pascal (Tesla P40)

The P40 is compute capability **6.1**. PyTorch's cu128 and cu129 wheels dropped
Pascal, so the cu126 index is mandatory: anything newer installs cleanly and
then dies at the first kernel launch. On an Ampere-or-newer card, point
`TORCH_INDEX` at a cu128 index and change nothing else.

Verified on the hardware rather than assumed:

```
torch 2.11.0+cu126   arch list: sm_50 sm_60 sm_70 sm_75 sm_80 sm_86 sm_90
device: Tesla P40, capability (6, 1)  ->  matmul and conv kernels execute
```

`sm_61` is absent from that list. It works anyway because CUDA cubins run
forward across minor revisions, so an `sm_60` binary executes on a 6.1 device.

**`torch.compile` is unavailable on Pascal.** Triton refuses CUDA capability
below 7.0 (`GPUTooOldForTriton`), so the CUDA overlay sets
`TORCHDYNAMO_DISABLE=1` and the engines run eager. This matters most for
**VoxCPM**, which compiles part of its generation path. On a newer NVIDIA card,
set `TORCHDYNAMO_DISABLE=0`.

**Flash-attention is unavailable** (needs sm_80+); PyTorch's own SDPA works.

**fp16 and bf16 do not crash**, contrary to Pascal folklore — cuBLAS
up-converts, so they run at roughly fp32 speed rather than falling off a cliff.
Measured: fp32 ~4.9 TFLOPS, fp16 ~8.3, bf16 ~5.1. A bf16 model loads and runs;
you get the memory saving without a speed-up.

**Expect slow synthesis.** Measured RTF on the P40 is **7.75** — 23 seconds to
generate 3 seconds of speech. Fine for batch and async work, not interactive.

## AMD notes — ROCm

`torch.compile` is left **enabled** on ROCm (`TORCHDYNAMO_DISABLE` defaults to
`0`), because Triton supports ROCm and VoxCPM needs no workaround there.
IndexTTS's `--all-extras` also becomes plausible, since flash-attn and deepspeed
both have ROCm builds — set the `INDEXTTS_EXTRAS=--all-extras` build arg. Both
are left conservative by default because neither has been exercised.

`HSA_OVERRIDE_GFX_VERSION` is only needed for cards outside ROCm's supported
gfx list, for example `11.0.0` to present gfx1101/gfx1102 as gfx1100. The
overlays deliberately **don't set it at all**: passing it as an empty string is
not the same as unset — the HSA runtime rejects it and torch then sees no GPU.
If your card needs it, add it to that service's `environment`. An RX 7800 XT
(gfx1101) is officially supported and needs none.

**The first request per new input length is slow** (10-30 s measured under
WSL2) while MIOpen compiles GPU kernels. OmniVoice and LuxTTS keep them in the
`tts-miopen` volume, so they survive container recreates.

### WSL2 is different

The ROCm overlay targets **native Linux**, where the GPU appears as `/dev/kfd`
plus `/dev/dri`. Under WSL2 the GPU is `/dev/dxg` and torch needs the host's WSL
HSA runtime, so use `docker-compose.rocm-wsl.yml` instead. The full Windows
setup (driver, ROCm in the distro, Docker Engine instead of Docker Desktop,
`.wslconfig`, LAN access, start at logon) is in
[`windows/README.md`](../windows/README.md).

## VRAM budget

Chatterbox loads in **3.2 GB**, so it fits almost anywhere. The larger engines
do not: Qwen3-TTS is roughly 7 GB in fp32. LuxTTS is the lightest (under 1 GB,
per its README).

If the GPU is shared with other workloads, the budget moves. On the P40 used
for testing, ollama could hold ~17 GB of the 24 GB while a model was loaded,
releasing it after its `keep_alive` window. Check before starting several
engines:

```bash
nvidia-smi --query-gpu=memory.used,memory.free --format=csv
```

`--profile all` will likely exhaust VRAM next to such a workload. Bring engines
up one at a time unless the GPU is otherwise free. (On AMD, `nvidia-smi` isn't
available; use `rocm-smi` on native Linux.) If IndexTTS is tight, set
`INDEXTTS_USE_BF16=1`.

## Models and first start

Weights download from HuggingFace on first run into the shared `tts-models`
volume (`/models`, with `HF_HOME=/models/hf`). First start is therefore slow and
the container sits `health: starting` meanwhile — the healthchecks allow a 15 to
20 minute start period for exactly this. Chatterbox took **105 s** from cold.

Watch it with `docker compose --profile <engine> logs -f`. The volume is shared
across engines so overlapping files are fetched once. Reclaim the space with
`docker volume rm tts-serve_tts-models`.

## Testing a real synthesis

`tools/speak.py` is baked into each image, and `testdata/` is bind-mounted at
`/testdata`, so a clip dropped there is reachable inside the container and
generated audio lands back on the host:

```bash
docker compose --profile chatterbox exec chatterbox \
  python tools/speak.py "Hello from the P40." \
    --server http://localhost:7500 \
    --ref-audio /testdata/ref.wav \
    --output-file /testdata/out.wav
```

Inspect an engine's parameters without synthesizing anything:

```bash
docker compose --profile chatterbox exec chatterbox \
  python tools/speak.py --server http://localhost:7500 --list-server-params
```

Most engines require `audio_base64`, a reference voice clip. VoxCPM is the
exception: in voice-design mode it synthesizes from text alone, with a
`(control instruction)` prefix steering the voice.

When checking output, verify it is not *silent* rather than merely non-empty.
A well-formed WAV full of zeros is the failure mode that otherwise slips past.

## Adding another engine

tts-serve ships nine engines; six are packaged here. Copy the closest
Dockerfile, swap the `pip install` and the `CMD`, set that engine's
`*_HOST` / `*_PORT` / `*_DEVICE` variables, and add a service to
`docker-compose.yml` plus an entry in **every** overlay (CUDA, ROCm, ROCm-WSL).

Then check the engine's own `pyproject.toml` for a torch pin and a
`requires-python` before building, and set the build args and the `FROM python:`
tag to match. That one check is what turns a 20-minute failed build into a
working one.

Two engines are not candidates here: **Qwen3-TTS (MLX)** is Apple-Silicon-only,
and **faster-qwen3-tts** relies on a CUDA-graph backend that is a poor bet on
Pascal.
