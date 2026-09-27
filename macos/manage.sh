#!/usr/bin/env bash
# Starts/stops/inspects the native macOS deployment set up by setup.sh.
# There is no Docker layer here: Docker Desktop on macOS cannot pass Metal
# through to a container, so MPS/MLX acceleration only works running
# natively. This script plays the role docker-compose plays on Linux --
# one process per engine, each in its own venv, backgrounded with a pidfile
# and a log file.
#
# Usage:
#   macos/manage.sh start  [engine ...]   # default: all three
#   macos/manage.sh stop   [engine ...]
#   macos/manage.sh status [engine ...]
#   macos/manage.sh logs   <engine>       # tail -f
#
# Engines: chatterbox (mps, 24kHz), voxcpm (mps, 48kHz), qwen3tts-mlx (mlx, 24kHz)
#
# Ports and devices are overridable via env vars before calling this script,
# e.g. `CHATTERBOX_PORT=9000 macos/manage.sh start chatterbox`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENVS_DIR="$ROOT/macos/venvs"
LOG_DIR="$ROOT/macos/logs"
RUN_DIR="$ROOT/macos/run"
ALL_ENGINES="chatterbox qwen3tts-mlx voxcpm"

mkdir -p "$LOG_DIR" "$RUN_DIR"

engine_script() {
    case "$1" in
        chatterbox) echo "impl/server_chatterbox.py" ;;
        qwen3tts-mlx) echo "impl/server_qwen3TTS_mlx.py" ;;
        voxcpm) echo "impl/server_voxcpm.py" ;;
        *) echo "unknown engine: $1" >&2; return 1 ;;
    esac
}

# Exports the engine's port/device env vars (with defaults) into the CURRENT
# shell and sets $RESOLVED_PORT. Chatterbox and VoxCPM default host ports
# match the docker deployment's scheme (docker-compose.yml / .env.example);
# qwen3tts-mlx takes the slot the pytorch Qwen3-TTS server would use there,
# since only the MLX variant runs natively on Apple Silicon.
#
# Must be called directly (engine_configure foo), never via a $(...) command
# substitution -- exports made inside a subshell vanish when it exits, which
# previously left every server running on its own internal default (cuda
# device, port 7500) instead of what this script intended.
engine_configure() {
    case "$1" in
        chatterbox)
            export CHATTERBOX_DEVICE="${CHATTERBOX_DEVICE:-mps}"
            export CHATTERBOX_PORT="${CHATTERBOX_PORT:-7500}"
            RESOLVED_PORT="$CHATTERBOX_PORT"
            ;;
        qwen3tts-mlx)
            export QWEN3TTS_MLX_PORT="${QWEN3TTS_MLX_PORT:-7501}"
            RESOLVED_PORT="$QWEN3TTS_MLX_PORT"
            ;;
        voxcpm)
            export VOXCPM_DEVICE="${VOXCPM_DEVICE:-mps}"
            export VOXCPM_PORT="${VOXCPM_PORT:-7502}"
            RESOLVED_PORT="$VOXCPM_PORT"
            ;;
        *) echo "unknown engine: $1" >&2; return 1 ;;
    esac
}

is_running() {
    local pidfile="$RUN_DIR/$1.pid"
    [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null
}

start_one() {
    local engine="$1" venv script port pidfile logfile
    venv="$VENVS_DIR/$engine"
    pidfile="$RUN_DIR/$engine.pid"
    logfile="$LOG_DIR/$engine.log"

    if [ ! -d "$venv" ]; then
        echo "$engine: no venv at $venv -- run macos/setup.sh $engine first" >&2
        return 1
    fi
    if is_running "$engine"; then
        echo "$engine: already running (pid $(cat "$pidfile"))"
        return 0
    fi

    script="$(engine_script "$engine")"
    engine_configure "$engine"
    port="$RESOLVED_PORT"

    (
        cd "$ROOT"
        # shellcheck disable=SC1091
        source "$venv/bin/activate"
        nohup python "$script" >>"$logfile" 2>&1 &
        echo $! >"$pidfile"
    )
    sleep 1
    if is_running "$engine"; then
        echo "$engine: started on port $port (pid $(cat "$pidfile")) -- log: $logfile"
    else
        echo "$engine: failed to start -- check $logfile" >&2
        rm -f "$pidfile"
        return 1
    fi
}

stop_one() {
    local engine="$1" pidfile="$RUN_DIR/$1.pid"
    if ! is_running "$engine"; then
        echo "$engine: not running"
        rm -f "$pidfile"
        return 0
    fi
    local pid
    pid="$(cat "$pidfile")"
    kill "$pid"
    for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "$engine: pid $pid did not exit, sending SIGKILL" >&2
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
    echo "$engine: stopped"
}

status_one() {
    local engine="$1" port
    if is_running "$engine"; then
        if engine_configure "$engine" 2>/dev/null; then
            port="$RESOLVED_PORT"
        else
            port='?'
        fi
        local health="unreachable"
        if command -v curl >/dev/null && curl -fsS -m 2 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
            health="healthy"
        fi
        echo "$engine: running (pid $(cat "$RUN_DIR/$engine.pid"), port $port, $health)"
    else
        echo "$engine: stopped"
    fi
}

logs_one() {
    local logfile="$LOG_DIR/$1.log"
    [ -f "$logfile" ] || { echo "no log yet for $1 at $logfile" >&2; exit 1; }
    tail -f "$logfile"
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
    start)
        for e in ${@:-$ALL_ENGINES}; do start_one "$e"; done
        ;;
    stop)
        for e in ${@:-$ALL_ENGINES}; do stop_one "$e"; done
        ;;
    status)
        for e in ${@:-$ALL_ENGINES}; do status_one "$e"; done
        ;;
    logs)
        [ $# -eq 1 ] || { echo "usage: macos/manage.sh logs <engine>" >&2; exit 1; }
        logs_one "$1"
        ;;
    *)
        echo "usage: macos/manage.sh {start|stop|status|logs} [engine ...]" >&2
        echo "engines: $ALL_ENGINES" >&2
        exit 1
        ;;
esac
