#!/bin/zsh
# Records the panel for marketing: English questions typed, sent and answered in the Debug app
# (scripted backends, made-up history, English interface, dark), filmed showing only Nibble's
# windows on a plain background in the theme's hue. Writes marketing/nibble-demo-en-THEME.mp4 and
# beside it .marks (each moment and when it happens, for scripts/hero.sh); neither is kept in git:
# run this again to remake them.
#
#   scripts/demo.sh [violet|teal|blue|rose|orange|amber]     (violet if left out)
#
# Three questions show every light: thinking into the tunnel, searching, reading, writing, done;
# asking to run a command and running it; failing to connect and working on retry. The panel opens
# in the middle of the main screen and takes the keyboard for about 70 seconds; don't type while
# it runs. Recording needs Screen Recording permission for the app the script runs in.
set -euo pipefail
source "${0:A:h}/env.sh"

THEME="${1:-violet}"
case "$THEME" in
    violet|teal|blue|rose|orange|amber) ;;
    *) echo "unknown theme: $THEME (violet, teal, blue, rose, orange, amber)" >&2; exit 2 ;;
esac
NAME="nibble-demo-en-$THEME.mp4"

APP="$(scripts/build.sh debug | tail -1)"
TOOL="$BUILD_DIR/tools/record"
if [[ ! -x "$TOOL" || scripts/record.swift -nt "$TOOL" ]]; then
    mkdir -p "$BUILD_DIR/tools"
    swiftc -O -module-cache-path "$BUILD_DIR/ModuleCache" scripts/record.swift -o "$TOOL"
fi

DEMO="$BUILD_DIR/demo"
rm -rf "$DEMO"
mkdir -p "$DEMO/data" "$DEMO/signals" marketing
python3 -I -B scripts/demo-data.py "$DEMO/data" en
cat > "$DEMO/data/settings.json" <<JSON
{
  "appearance": "dark",
  "background": "lava",
  "colorTheme": "$THEME",
  "language": "english",
  "textSize": "small",
  "panelWidth": 480,
  "panelHeight": 560,
  "backend": { "kind": "hermes", "hermes": { "address": "http://127.0.0.1:8642", "profile": "general" } }
}
JSON

pkill -x "Nibble Dev" 2>/dev/null && sleep 0.5 || true
NIBBLE_DATA_DIR="$DEMO/data" "$APP/Contents/MacOS/Nibble Dev" -NibbleScript demo -NibbleDemo "$DEMO/signals" \
    -AppleLanguages "(en)" >/dev/null 2>&1 &
PID=$!
"$TOOL" com.glimmer.Nibble.dev "$DEMO/signals" "$DEMO/$NAME" >/dev/null || { kill $PID 2>/dev/null; exit 1; }
wait $PID 2>/dev/null || true

OUT="$NIBBLE_ROOT/marketing/$NAME"
mv -f "$DEMO/$NAME" "$OUT"
cp "$DEMO/signals/marks" "${OUT%.mp4}.marks"
rm -rf "$DEMO"
echo "$OUT"
