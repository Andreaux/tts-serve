# tts-serve on Apple Silicon (native, no Docker)

This is the Mac counterpart to [`docker/`](../docker/README.md), but it does
**not** use Docker. Docker Desktop on macOS cannot pass Metal/MPS through to a
container -- there is no `--gpus` equivalent for Apple's GPU -- so a
containerized deployment here would run every engine on CPU only, which
defeats the point. Instead, each engine runs natively in its own venv and
talks to the GPU through PyTorch's MPS backend, or, for Qwen3-TTS, through
Apple's own MLX framework.

## Engines covered here

| Engine | Script | Backend | Rate | Reference transcript |
|---|---|---|---|---|
| Chatterbox | `impl/server_chatterbox.py` | MPS (torch) | 24 kHz | not used |
| VoxCPM | `impl/server_voxcpm.py` | MPS (torch) | 48 kHz | optional |
| Qwen3-TTS (MLX) | `impl/server_qwen3TTS_mlx.py` | MLX (Metal, native) | 24 kHz | required |

Two engines in this repo are **not** viable on this machine at all:
`dots.tts` auto-selects CUDA/CPU with no MPS path, and `faster-qwen3-tts` is
a CUDA-only fork (`FASTER_QWEN3TTS_DEVICE` must start with `cuda`). The other
engines (OmniVoice, Qwen3-TTS, IndexTTS-2.5, LuxTTS) do support
`*_DEVICE=mps` and can be added the same way if you need them -- see
"Adding another engine" below.

Why isolated venvs rather than one shared environment: the engines' own
dependency trees conflict (different torch pins, etc.), same reason the
Docker deployment gives each engine its own image/container. Mixing them in
one env is not supported -- see the root [README.md](../README.md).

## Setup

From the repo root:

```bash
bash macos/setup.sh                       # all three engines
# or just what you need:
bash macos/setup.sh chatterbox voxcpm
```

This creates `macos/venvs/<engine>/`, installs the engine's own package (plus
PyTorch, which on macOS's PyPI wheels already includes MPS support -- no
special index needed, unlike the CUDA/ROCm Docker builds), and installs
`tts-engine-common` (from this checkout) + `fastapi uvicorn loguru
soundfile`, matching the manual steps in each engine's own doc
(`impl/server_chatterbox.md`, `impl/server_voxcpm.md`,
`impl/server_qwen3TTS_mlx.md`).

First run of each server downloads model weights from HuggingFace into
`~/.cache/huggingface/hub/` -- expect a multi-GB download per engine on first
start.

> Both scripts are invoked as `bash macos/<script>.sh`, not `./macos/<script>.sh`.
> If this checkout lives on a network share (SMB/AFP/NFS), the executable bit
> often doesn't persist across mounts even after `chmod +x`, so `./setup.sh`
> can fail with "permission denied" -- running it through `bash` sidesteps
> that entirely.

## Running

```bash
bash macos/manage.sh start                # all three, backgrounded
bash macos/manage.sh start chatterbox      # just one
bash macos/manage.sh status                # pid + port + /health check
bash macos/manage.sh logs voxcpm           # tail -f the log
bash macos/manage.sh stop                  # all three
```

`start` backgrounds each server with `nohup`, writes its pid to
`macos/run/<engine>.pid`, and appends output to `macos/logs/<engine>.log`.
There's no `launchd` unit here, so servers do not survive a reboot or login
on their own -- rerun `bash macos/manage.sh start` after one, or set up a
`launchd` plist yourself if you want that.

Default ports (no collisions running all three at once):

| Engine | Port | Override |
|---|---|---|
| Chatterbox | 7500 | `CHATTERBOX_PORT` |
| Qwen3-TTS (MLX) | 7501 | `QWEN3TTS_MLX_PORT` |
| VoxCPM | 7502 | `VOXCPM_PORT` |

These mirror the host-port scheme in the Docker deployment's
[`.env.example`](../.env.example); Qwen3-TTS (MLX) takes the slot the
PyTorch Qwen3-TTS server would use there, since only the MLX variant runs
natively here.

Devices default to `mps` for Chatterbox and VoxCPM (override with
`CHATTERBOX_DEVICE` / `VOXCPM_DEVICE`, e.g. to force `cpu`). Qwen3-TTS (MLX)
has no device env var -- MLX always reports `mlx`.

Check any server directly:

```bash
curl http://localhost:7500/health
curl http://localhost:7500/capabilities
```

And exercise one with the test tool:

```bash
python tools/speak.py --server http://localhost:7502 \
  --ref-audio /path/to/reference.wav \
  --ref-audio-transcript /path/to/transcript.txt
```

## Notes specific to this hardware

- **VoxCPM on MPS** forces `float32` by default (bfloat16/float16 cause
  numerical drift that breaks its diffusion loop) -- see
  `impl/server_voxcpm.md` if you want to experiment with
  `VOXCPM_MPS_DTYPE`. Leave it unset in normal use.
- **Chatterbox** installs from a pinned upstream git commit, not the PyPI
  release -- `bash macos/setup.sh` already does this correctly; if you ever
  reinstall by hand, see the note in `impl/server_chatterbox.md` about why
  the PyPI package silently fails.
- **Chatterbox on MPS also needs a newer torch than upstream pins.**
  `chatterbox-tts`'s own metadata requires `torch==2.6.0`, but that exact
  build has a reproducible MPS bug on Apple Silicon: generations past ~200
  sampling steps (roughly 150+ characters of input) degrade mid-run and the
  server process dies silently, no traceback, regardless of free memory or
  `PYTORCH_MPS_HIGH_WATERMARK_RATIO`. Confirmed by bisecting on this
  machine -- identical failure on torch 2.6.0 and 2.9.1, clean success (and
  roughly 2x faster) on 2.14.0. `setup.sh` installs `torch==2.14.0` +
  `torchaudio==2.11.0` with `--no-deps` after the chatterbox install for
  exactly this reason -- don't "fix" it back down to 2.6.0 to match
  upstream's declared pin.
- **Qwen3-TTS (MLX)** requires `reference_text` on every request (ICL
  cloning only, no speaker-embedding fallback) and needs Apple Silicon --
  `mlx-audio` will not install/run on Intel Macs.
- Both MPS engines run eager (no `torch.compile`); this is normal for MPS
  and not something to "fix".

## Adding another engine

To bring OmniVoice, Qwen3-TTS (PyTorch), IndexTTS-2.5, or LuxTTS into this
same setup, add a `setup_<engine>()` function to `setup.sh` following the
pattern of the existing three (copy the "Installation" section from that
engine's `impl/server_<name>.md`), and a matching case in
`engine_script()` / `engine_configure()` in `manage.sh`. All four support
`*_DEVICE=mps`.
