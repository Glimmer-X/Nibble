#!/bin/zsh
# Screenshots a page of the Debug app with made-up conversations (scripts/demo-data.py) and the
# scripted backend, so no real data or backend is touched. Prints the PNG path.
#
#   scripts/shot.sh PAGE NAME [APP ARGUMENTS…]
#       PAGE home|history|settings|about|sheet|menu|source|strip; NAME names the file in build/shots/;
#       further arguments go to the app, e.g. -AppleLanguages "(en)".
#
# The data folder build/shots/data keeps settings between shots; delete it to start over.
set -euo pipefail
source "${0:A:h}/env.sh"

PAGE="${1:?page}"
NAME="${2:?name}"
shift 2
APP="$(scripts/build.sh debug | tail -1)"
SHOTS="$BUILD_DIR/shots"
DATA="$SHOTS/data"
mkdir -p "$DATA"
python3 -I -B scripts/demo-data.py "$DATA"
INFO="${TMPDIR}window.txt"
pkill -x "Nibble Dev" 2>/dev/null && sleep 0.5 || true
NIBBLE_DATA_DIR="$DATA" "$APP/Contents/MacOS/Nibble Dev" -NibbleScript sample -NibblePage "$PAGE" \
    -NibbleWindowFile "$INFO" "$@" >/dev/null 2>&1 &
PID=$!
for _ in {1..30}; do
    [[ -s "$INFO" ]] && break
    sleep 0.5
done
[[ -s "$INFO" ]] || { kill $PID 2>/dev/null; echo "no window" >&2; exit 1; }
read -r NUMBER X Y W H < "$INFO"
OUT="$SHOTS/$NAME.png"
# Windows above the floating level (the menu bar panel) cannot be captured by number.
screencapture -x -o -l "$NUMBER" "$OUT" 2>/dev/null || screencapture -x -R "$X,$Y,$W,$H" "$OUT"
kill $PID 2>/dev/null || true
echo "$OUT"
