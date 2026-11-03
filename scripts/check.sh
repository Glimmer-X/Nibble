#!/bin/zsh
# Builds the Debug app and runs its on-screen self-test, printing the report as JSON: what code
# alone cannot see (window heights and places, what a press lands on, the light through a reply).
# Logic belongs in the unit tests (scripts/test.sh), which run without any window.
#
#   scripts/check.sh [panel] [edges] [strip] [main] [menu]     all parts when none is named
#
# Uses a throwaway data folder and the scripted backend, so it touches no real conversations or
# backends. Its windows appear on screen and take the keyboard while it runs: run only the part a
# change needs.
set -euo pipefail
source "${0:A:h}/env.sh"

APP="$(scripts/build.sh debug | tail -1)"
DATA="${TMPDIR}selftest-data"
REPORT="${TMPDIR}selftest.json"
pkill -x "Nibble Dev" 2>/dev/null && sleep 0.5 || true
# zsh keeps an unquoted expansion as one word, so the parts go in as an array of their own.
PARTS=()
(( $# )) && PARTS=(-NibbleSelfTestParts "${(j:,:)@}")
NIBBLE_DATA_DIR="$DATA" "$APP/Contents/MacOS/Nibble Dev" -NibbleScript sample -NibbleSelfTest "$REPORT" \
    "${PARTS[@]}" >/dev/null 2>&1 &
PID=$!
for _ in {1..120}; do
    [[ -s "$REPORT" ]] && break
    sleep 1
done
kill $PID 2>/dev/null || true
[[ -s "$REPORT" ]] || { echo "self-test did not finish" >&2; exit 1; }
cat "$REPORT"
grep -q '"passed" : true' "$REPORT"
