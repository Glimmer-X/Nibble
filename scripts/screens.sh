#!/bin/zsh
# Takes the README's screenshots in one language with made-up conversations (scripts/demo-data.py)
# and the scripted backend, then lays them out on one picture (scripts/layout.py):
# docs/media/screens-LANG.png.
#
#   scripts/screens.sh [zh|en]          (zh if left out)
#
# Shots, in build/screens/LANG/: the chat with an answer, the strip while a reply searches, the
# menu bar panel, the main window's home and history. Each opens the Debug app for a few seconds.
set -euo pipefail
source "${0:A:h}/env.sh"

LANG_CODE="${1:-zh}"
case "$LANG_CODE" in
    zh) LANGUAGE=chinese; APPLE="(zh-Hans)"; DATA_LANG=""; QUESTION="搜一下 Swift 6.2 有哪些新特性" ;;
    en) LANGUAGE=english; APPLE="(en)"; DATA_LANG=en; QUESTION="What's new in Swift 6.2?" ;;
    *) echo "usage: scripts/screens.sh [zh|en]" >&2; exit 2 ;;
esac

APP="$(scripts/build.sh debug | tail -1)"
SHOTS="$BUILD_DIR/screens/$LANG_CODE"
DATA="$BUILD_DIR/screens/data"
rm -rf "$SHOTS" "$DATA"
mkdir -p "$SHOTS" "$DATA"
cat > "$DATA/settings.json" <<JSON
{
  "appearance": "dark",
  "background": "lava",
  "colorTheme": "violet",
  "language": "$LANGUAGE",
  "textSize": "small",
  "panelWidth": 480,
  "panelHeight": 560,
  "backend": { "kind": "hermes", "hermes": { "address": "http://127.0.0.1:8642", "profile": "general" } }
}
JSON

# shoot NAME SECONDS [app arguments…]: opens the Debug app, waits until its window has settled and
# SECONDS more, and captures that window alone.
shoot() {
    local name="$1" wait="$2"
    shift 2
    python3 -I -B scripts/demo-data.py "$DATA" $DATA_LANG
    local info="$TMPDIR/window.txt"
    rm -f "$info"
    pkill -x "Nibble Dev" 2>/dev/null && sleep 0.5 || true
    NIBBLE_DATA_DIR="$DATA" "$APP/Contents/MacOS/Nibble Dev" -NibbleScript sample -AppleLanguages "$APPLE" \
        -NibbleWindowFile "$info" "$@" >/dev/null 2>&1 &
    local pid=$!
    for _ in {1..30}; do [[ -s "$info" ]] && break; sleep 0.5; done
    [[ -s "$info" ]] || { kill $pid 2>/dev/null; echo "no window for $name" >&2; exit 1; }
    sleep "$wait"
    local number x y w h
    read -r number x y w h < "$info"
    screencapture -x -o -l "$number" "$SHOTS/$name.png" 2>/dev/null || screencapture -x -R "$x,$y,$w,$h" "$SHOTS/$name.png"
    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
}

shoot chat 0.5 -NibbleShowPanelAtLaunch YES
shoot strip 0.1 -NibbleAsk "$QUESTION" -NibblePage strip
shoot menu 0.5 -NibblePage menu
shoot home 0.5 -NibblePage home
shoot history 0.5 -NibblePage history

# The pictures, on the backdrop the violet clip of the moving picture has, 80 px (40 pt) around.
BACK=0x171622
mkdir -p docs/media
# The panel: the chat on the left; on the right the strip at the chat's top, the menu bar panel
# at its foot. The shots are 2x: chat 960 x 1120, strip 620 x 80, menu 680 x 920.
ffmpeg -v error -y -f lavfi -i "color=c=${BACK}:s=1864x1280" \
    -i "$SHOTS/chat.png" -i "$SHOTS/strip.png" -i "$SHOTS/menu.png" -filter_complex \
    "[0][1]overlay=80:80[a];[a][2]overlay=1104:80[b];[b][3]overlay=1104:280,format=rgb24" \
    -frames:v 1 "docs/media/panel-$LANG_CODE.png"
# The main window: home and history side by side (each 1840 x 1240), at half size.
ffmpeg -v error -y -f lavfi -i "color=c=${BACK}:s=3904x1400" \
    -i "$SHOTS/home.png" -i "$SHOTS/history.png" -filter_complex \
    "[0][1]overlay=80:80[a];[a][2]overlay=1984:80,scale=1952:700:flags=lanczos,format=rgb24" \
    -frames:v 1 "docs/media/main-$LANG_CODE.png"
echo "docs/media/panel-$LANG_CODE.png docs/media/main-$LANG_CODE.png"
