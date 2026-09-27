#!/usr/bin/env bash
# Sets up one isolated venv per engine under macos/venvs/<engine>, mirroring
# the docker deployment's "one container per engine" isolation (the engines'
# dependency trees conflict -- see docker/README.md and the root README).
#
# Usage:
#   macos/setup.sh                       # all three engines
#   macos/setup.sh chatterbox voxcpm      # just these
#
# Each venv gets: the engine's own package, plus tts-engine-common (this
# repo's shared layer, installed from the local checkout) and the FastAPI
# server deps -- the same set every engine-specific install doc under impl/
# lists by hand.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENVS_DIR="$ROOT/macos/venvs"
ALL_ENGINES="chatterbox qwen3tts-mlx voxcpm"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "warning: this script targets macOS; uname reports $(uname -s)" >&2
fi
ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
    echo "warning: Apple Silicon (arm64) expected for MPS/MLX acceleration; uname -m reports $ARCH" >&2
fi

# macOS ships python3 = 3.9, which chatterbox-tts (and most of the other
# engines) reject outright ("requires a different Python: 3.9.6 not in
# '>=3.10'"). Prefer a newer interpreter if one is on PATH -- e.g. from
# `brew install python@3.12` -- but let PYTHON_BIN override the pick.
find_python() {
    if [ -n "${PYTHON_BIN:-}" ]; then
        command -v "$PYTHON_BIN"
        return
    fi
    local candidate
    for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return
        fi
    done
    return 1
}

PYTHON_BIN="$(find_python)" || {
    echo "no python3 interpreter found on PATH" >&2
    exit 1
}

PYTHON_OK=$("$PYTHON_BIN" -c 'import sys; print(1 if sys.version_info >= (3, 10) else 0)')
if [ "$PYTHON_OK" != "1" ]; then
    echo "error: $PYTHON_BIN is $("$PYTHON_BIN" -V 2>&1), but these engines need >= 3.10." >&2
    echo "  brew install python@3.12" >&2
    echo "  PYTHON_BIN=python3.12 bash macos/setup.sh" >&2
    exit 1
fi
echo "using $PYTHON_BIN ($("$PYTHON_BIN" -V 2>&1))"

setup_chatterbox() {
    local venv="$VENVS_DIR/chatterbox"
    echo "== chatterbox: creating venv at $venv =="
    "$PYTHON_BIN" -m venv --clear "$venv"
    # shellcheck disable=SC1091
    source "$venv/bin/activate"
    pip install -U pip
    # PyPI's chatterbox-tts 0.1.7 predates the v3 multilingual API this server
    # requires and reports the same version number either way -- install from
    # the pinned commit, per impl/server_chatterbox.md.
    pip install "git+https://github.com/resemble-ai/chatterbox.git@5de7a54aa4e5e2baadb0182dde554908b48b85c2"
    # chatterbox-tts pins torch==2.6.0 in its own metadata (for python < 3.14),
    # but on Apple Silicon that exact build has a reproducible MPS bug: longer
    # generations (~200+ sampling steps) degrade mid-run and the process dies
    # with no traceback. Confirmed via bisection on this machine -- same input
    # fails identically on torch 2.6.0 and 2.9.1, succeeds cleanly (and ~2x
    # faster) on 2.14.0. torchaudio's own releases stopped tracking torch's
    # version number 1:1, so 2.11.0 (its latest) is paired with torch 2.14.0
    # here; --no-deps keeps pip from fighting chatterbox-tts's declared pin.
    pip install --no-deps torch==2.14.0 torchaudio==2.11.0
    pip install "$ROOT/tts-engine-common" fastapi uvicorn loguru soundfile
    deactivate
    echo "== chatterbox: done =="
}

setup_qwen3tts_mlx() {
    local venv="$VENVS_DIR/qwen3tts-mlx"
    echo "== qwen3tts-mlx: creating venv at $venv =="
    "$PYTHON_BIN" -m venv --clear "$venv"
    # shellcheck disable=SC1091
    source "$venv/bin/activate"
    pip install -U pip
    pip install -U mlx-audio
    pip install "$ROOT/tts-engine-common" fastapi uvicorn loguru soundfile
    deactivate
    echo "== qwen3tts-mlx: done =="
}

setup_voxcpm() {
    local venv="$VENVS_DIR/voxcpm"
    echo "== voxcpm: creating venv at $venv =="
    "$PYTHON_BIN" -m venv --clear "$venv"
    # shellcheck disable=SC1091
    source "$venv/bin/activate"
    pip install -U pip
    pip install voxcpm
    pip install "$ROOT/tts-engine-common" fastapi uvicorn loguru soundfile
    deactivate
    echo "== voxcpm: done =="
}

ENGINES="${*:-$ALL_ENGINES}"
mkdir -p "$VENVS_DIR"

for engine in $ENGINES; do
    case "$engine" in
        chatterbox) setup_chatterbox ;;
        qwen3tts-mlx) setup_qwen3tts_mlx ;;
        voxcpm) setup_voxcpm ;;
        *)
            echo "unknown engine: $engine (expected one of: $ALL_ENGINES)" >&2
            exit 1
            ;;
    esac
done

echo
echo "Done. Start servers with: macos/manage.sh start $ENGINES"
