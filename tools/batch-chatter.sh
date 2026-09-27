#!/usr/bin/env bash
# Splits a text document into paragraphs and synthesizes each one against a
# Chatterbox server, then concatenates the results into a single WAV -- so a
# whole document can be turned into speech with one invocation instead of one
# tools/speak.py call per paragraph. Wraps speak.py for the actual HTTP work;
# adds nothing engine-specific beyond "no reference_text" (Chatterbox has no
# such field, per impl/server_chatterbox.md).
#
# Usage:
#   tools/batch-chatter.sh <text-file> --ref-audio voice.wav [options]
#
# Options:
#   --server URL         Chatterbox server (default: http://localhost:7500)
#   --ref-audio PATH      Reference voice clip (required)
#   --output-dir DIR       Where per-paragraph WAVs go
#                           (default: <text-file-dir>/<text-file-stem>_chatterbox)
#   --output-file PATH      Final concatenated WAV (default: <output-dir>/combined.wav)
#   --pause SECONDS          Silence inserted between paragraphs in the final
#                             file (default: 0.5; 0 disables it)
#   --no-concat                Skip concatenation; keep only the per-paragraph files
#   --timeout SECONDS           Per-paragraph request timeout (default: 180)
#
# A paragraph is any run of text separated by one or more blank lines;
# internal newlines within a paragraph are collapsed to spaces before it's
# sent as one synthesis request. A paragraph that fails synthesis is skipped
# (logged, not fatal) -- the rest of the document still gets processed, and
# the final concatenation uses whatever succeeded. Exit status is non-zero if
# any paragraph failed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEAK="$ROOT/tools/speak.py"

SERVER="${TTS_SPEAK_SERVER:-http://localhost:7500}"
REF_AUDIO=""
OUTPUT_DIR=""
OUTPUT_FILE=""
PAUSE="0.5"
DO_CONCAT=1
TIMEOUT="180"
INPUT=""

usage() {
    sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --server) SERVER="$2"; shift 2 ;;
        --ref-audio) REF_AUDIO="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --output-file) OUTPUT_FILE="$2"; shift 2 ;;
        --pause) PAUSE="$2"; shift 2 ;;
        --no-concat) DO_CONCAT=0; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*)
            echo "unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [ -n "$INPUT" ]; then
                echo "unexpected extra argument: $1" >&2
                exit 1
            fi
            INPUT="$1"
            shift
            ;;
    esac
done

if [ -z "$INPUT" ]; then
    echo "usage: tools/batch-chatter.sh <text-file> --ref-audio voice.wav [options]" >&2
    exit 1
fi
if [ ! -f "$INPUT" ]; then
    echo "no such file: $INPUT" >&2
    exit 1
fi
if [ -z "$REF_AUDIO" ]; then
    echo "--ref-audio is required (Chatterbox conditions on reference audio only, no transcript)" >&2
    exit 1
fi
if [ ! -f "$REF_AUDIO" ]; then
    echo "no such reference audio file: $REF_AUDIO" >&2
    exit 1
fi

INPUT_DIR="$(cd "$(dirname "$INPUT")" && pwd)"
INPUT_STEM="$(basename "$INPUT")"
INPUT_STEM="${INPUT_STEM%.*}"
: "${OUTPUT_DIR:=$INPUT_DIR/${INPUT_STEM}_chatterbox}"
: "${OUTPUT_FILE:=$OUTPUT_DIR/combined.wav}"

mkdir -p "$OUTPUT_DIR"
# Clear any numbered WAVs from a previous run so this run's file count is
# never contaminated by stale leftovers, and so speak.py never hits its
# interactive overwrite prompt (which would hang a batch loop).
rm -f "$OUTPUT_DIR"/[0-9][0-9][0-9].wav

echo "Splitting paragraphs from $INPUT ..."
PARAGRAPHS=()
while IFS= read -r -d '' para; do
    PARAGRAPHS+=("$para")
done < <(python3 - "$INPUT" <<'PYEOF'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
paragraphs = re.split(r"\n\s*\n+", text)
out = []
for p in paragraphs:
    p = re.sub(r"\s+", " ", p).strip()
    if p:
        out.append(p)
for p in out:
    sys.stdout.write(p + "\0")
PYEOF
)

TOTAL=${#PARAGRAPHS[@]}
if [ "$TOTAL" -eq 0 ]; then
    echo "no paragraphs found in $INPUT" >&2
    exit 1
fi
echo "Found $TOTAL paragraph(s). Output dir: $OUTPUT_DIR"

RESULT_FILES=()
FAILED=()
i=0
for para in "${PARAGRAPHS[@]}"; do
    i=$((i + 1))
    outfile="$OUTPUT_DIR/$(printf '%03d' "$i").wav"
    preview="${para:0:60}"
    echo "[$i/$TOTAL] ${preview}$([ ${#para} -gt 60 ] && echo '...')"
    if python3 "$SPEAK" "$para" \
        --server "$SERVER" \
        --ref-audio "$REF_AUDIO" \
        --output-file "$outfile" \
        --timeout "$TIMEOUT"; then
        RESULT_FILES+=("$outfile")
    else
        echo "  [$i/$TOTAL] FAILED -- skipping" >&2
        FAILED+=("$i")
    fi
done

echo
echo "Done: ${#RESULT_FILES[@]}/$TOTAL paragraph(s) succeeded."
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "Failed paragraph(s): ${FAILED[*]}" >&2
fi

if [ "$DO_CONCAT" -eq 1 ] && [ ${#RESULT_FILES[@]} -gt 0 ]; then
    echo "Concatenating into $OUTPUT_FILE (pause: ${PAUSE}s) ..."
    python3 - "$OUTPUT_FILE" "$PAUSE" "${RESULT_FILES[@]}" <<'PYEOF'
import sys
import wave

outfile = sys.argv[1]
pause = float(sys.argv[2])
files = sys.argv[3:]

with wave.open(files[0], "rb") as w0:
    nchannels, sampwidth, framerate = w0.getnchannels(), w0.getsampwidth(), w0.getframerate()

silence = b"\x00" * int(pause * framerate) * sampwidth * nchannels

with wave.open(outfile, "wb") as out:
    out.setnchannels(nchannels)
    out.setsampwidth(sampwidth)
    out.setframerate(framerate)
    for i, path in enumerate(files):
        with wave.open(path, "rb") as w:
            if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (nchannels, sampwidth, framerate):
                sys.exit(f"format mismatch in {path}: cannot concatenate")
            out.writeframes(w.readframes(w.getnframes()))
        if silence and i != len(files) - 1:
            out.writeframes(silence)

print(f"Wrote {outfile}")
PYEOF
fi

[ ${#FAILED[@]} -eq 0 ]
