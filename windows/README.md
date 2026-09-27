# tts-serve on Windows — AMD GPU via WSL2

Runs the Docker images from [`docker/`](../docker/README.md) on a Windows PC with
an AMD Radeon GPU, using ROCm inside WSL2. Other machines on the LAN (e.g. a
TalkWithMe server) can then use the Windows box as their TTS backend.

**Verified on:** Radeon RX 7800 XT (gfx1101, 16 GB), Windows 11, Adrenalin
26.8.1, WSL 2.6, Ubuntu 24.04, host ROCm 6.4.4, torch 2.8.0+rocm6.4.
OmniVoice and LuxTTS run on the GPU. Warm OmniVoice synthesis of ~8 s of
speech takes ~2.3 s at `num_steps=16`; LuxTTS takes ~0.7-1.1 s.

## Why WSL2 needs its own overlay

Native Linux ROCm reaches the GPU through `/dev/kfd` + `/dev/dri`. Under WSL2
neither exists: the GPU is `/dev/dxg`, and the HSA runtime has to be the
WSL-specific build that talks to it. PyTorch's ROCm wheels **bundle** the native
HSA runtime, so inside a container `torch.cuda.is_available()` is `False` even
though `rocminfo` sees the card. `docker-compose.rocm-wsl.yml` fixes that by
bind-mounting the host's WSL runtime over torch's bundled copy, alongside
`/dev/dxg` and the WSL driver shims in `/usr/lib/wsl`.

## One-time setup

1. **AMD driver:** Adrenalin 26.1.1 or newer (AMD's minimum for ROCm on WSL2).
2. **WSL distro:** Ubuntu 24.04 (`wsl --install -d Ubuntu-24.04`), with systemd
   enabled (the default on current WSL).
3. **ROCm 6.4.x inside the distro**, per
   [AMD's ROCm 6.4.4 WSL guide](https://rocm.docs.amd.com/projects/radeon-ryzen/en/docs-6.4.4/docs/install/installrad/wsl/howto_wsl.html):
   `sudo amdgpu-install --usecase=wsl,rocm --no-dkms`. Check with
   `/opt/rocm/bin/rocminfo | grep gfx` — your card's gfx target must appear.

   > **ROCm 7.2+ is untested here.** From ROCm 7.2.1 (with Adrenalin 26.2.2)
   > AMD replaced the WSL HSA runtime this overlay bind-mounts
   > (`hsa-runtime-rocr4wsl`, installed as `/opt/rocm/lib/libhsa-runtime64.so.1`)
   > with a new user-mode library, ROCDXG. The overlay may need changes there
   > (and torch wheels on the matching ROCm line), so stay on 6.4.x unless you
   > want to adapt it.
4. **Docker Engine inside the distro** (`apt install docker.io` or Docker's own
   packages). **Docker Desktop does not work here:** it does not pass `/dev/dxg`
   into containers.
5. **`%UserProfile%\.wslconfig`** — add these, then run `wsl --shutdown`:

   ```ini
   [wsl2]
   # Share the Windows LAN IP, so other machines reach the containers directly.
   networkingMode=mirrored
   # Never idle-stop the VM.
   vmIdleTimeout=-1

   [general]
   # Never idle-stop the distro. The default (15 s after the last terminal
   # closes) takes Docker and every tts-serve container down with it.
   instanceIdleTimeout=-1
   ```

6. **LAN access** (elevated PowerShell): `.\open-tts-ports.ps1` opens TCP
   7500-7510 to the local subnet in both the Windows firewall and the Hyper-V
   firewall that filters mirrored-mode WSL traffic.
7. **Start at logon** (normal PowerShell): `.\register-wsl-autostart.ps1`.
   WSL does not start by itself at logon; this task boots the distro, systemd
   starts Docker, and Docker restarts the containers. Note that WSL stops when
   you log off, so the TTS server runs while you are logged in.

## Running an engine

Build from the distro's own Linux filesystem (e.g. `/opt/tts-serve`), not from
`/mnt/c` or a network share: builds are much faster, and files checked out on
Windows have CRLF line endings. If you edit on Windows, copy the files in and
strip the carriage returns (`sed -i 's/\r$//' <files>`).

```bash
cd /opt/tts-serve
cp .env.example .env
# in .env:  COMPOSE_FILE=docker-compose.yml:docker-compose.rocm-wsl.yml
docker compose --profile omnivoice up -d --build
curl http://localhost:7504/health
```

Confirm the container really uses the GPU:

```bash
docker exec tts-omnivoice python -c \
  'import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))'
```

From another machine, use the Windows PC's LAN IP, e.g.
`http://192.168.1.20:7504`.

## Pitfalls we hit (and the fixes that are already in place)

- **torch's ROCm line must match the host's.** The shadowed HSA runtime comes
  from the host (6.4.x here), and torch's bundled HIP libraries must be the same
  line. `rocm6.4` wheels work. **Chatterbox does not run here**: it pins
  torch 2.6.0, which only exists on the `rocm6.2.4` index, and that fails with
  `hipErrorNoDevice` (error 100). Every other engine uses `rocm6.4`.
- **An empty `HSA_OVERRIDE_GFX_VERSION` breaks GPU detection** ("is invalid" in
  the log, then "No HIP GPUs are available"). The overlays therefore don't set
  it at all. Only cards outside ROCm's supported gfx list need it.
- **First request per new text length is slow** (10-30 s) while MIOpen compiles
  GPU kernels. The `tts-miopen` volume keeps them across container recreates,
  so this fades as the server stays up.
- **LuxTTS silently falls back to CPU** if it cannot reach the GPU, and
  `/health` still reports `cuda`. Check the startup log for "Device set to use
  cuda" and no "switching to CPU" line. The `k2` warning in its log is expected
  (optional NVIDIA-oriented speed-up).
- **`expandable_segments not supported`** and **`libhsa-amd-aqlprofile64.so`**
  warnings in the logs are harmless under WSL2.
