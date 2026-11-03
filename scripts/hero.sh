#!/bin/zsh
# Cuts a moving picture from the demo recordings (scripts/demo.sh): four colours, each playing a
# different moment of the same length, looping.
#
#   scripts/hero.sh                 the README's: four in a row, lossless WebP, docs/media/hero.webp
#   scripts/hero.sh grid mp4        two by two as a video, for upright formats elsewhere:
#                                   marketing/nibble-hero-grid.mp4 (not kept in git)
#   scripts/hero.sh row|grid webp|mp4
#
# violet: summoned, a question typed and sent, the chat unfolding, thinking begins
# teal:   thinking, the stars turning into the tunnel
# rose:   asking to run a command, allowed, the command running
# orange: a request that cannot get through, red and still, retried, answered
#
# The recordings are 2x; the clips are taken at exactly half size, so each lit cell is 10 pixels
# and the grid stays even. The WebP is lossless: lossy WebP halves the colour resolution and
# carries errors from frame to frame, which smears the dim cells. (Animated AVIF would be smaller,
# but Safari shows only its first frame.)
set -euo pipefail
source "${0:A:h}/env.sh"

LAYOUT="${1:-row}"
FORMAT="${2:-webp}"
LENGTH=7          # seconds each clip plays
FADE=0.3          # seconds of fade from and to the backdrop at either end, so the loop joins softly
FPS=30
GAP=12            # pixels between the clips
SEAM=0x0b0b10     # the colour between them
# The panel (480 x 560 pt) with 24 pt around it, from 64 pt around it, at half the 2x size.
CLIP="crop=1056:1216:80:80,scale=528:608:flags=lanczos"

# moment THEME NAME: when NAME happened in THEME's recording.
moment() {
    awk -v name="$2" '$1 == name { print $2 }' "marketing/nibble-demo-en-$1.marks"
}
# The colour behind the panel, read from a corner of the recording.
backdrop() {
    ffmpeg -v error -ss 1 -i "marketing/nibble-demo-en-$1.mp4" -frames:v 1 \
        -vf "crop=2:2:4:4,scale=1:1" -f rawvideo -pix_fmt rgb24 - | xxd -p
}

typeset -A START
START[violet]=$(( $(moment violet summon) - 0.3 ))
START[teal]=$(( $(moment teal think) + 1.0 ))
START[rose]=$(( $(moment rose approval) - 1.0 ))
START[orange]=$(( $(moment orange ask-fail-sent) - 0.3 ))

INPUTS=()
FILTERS=""
i=0
for theme in violet teal rose orange; do
    file="marketing/nibble-demo-en-$theme.mp4"
    [[ -f "$file" ]] || { echo "missing $file (run scripts/demo.sh $theme)" >&2; exit 1; }
    colour="0x$(backdrop $theme)"
    INPUTS+=(-ss "${START[$theme]}" -t "$LENGTH" -i "$file")
    FILTERS+="[${i}:v]fps=${FPS},setpts=PTS-STARTPTS,${CLIP},"
    FILTERS+="fade=t=in:st=0:d=${FADE}:color=${colour},fade=t=out:st=$(( LENGTH - FADE )):d=${FADE}:color=${colour}[c${i}];"
    i=$(( i + 1 ))
done

W=528
H=608
case "$LAYOUT" in
    row) PLACES="0_0|$(( W + GAP ))_0|$(( 2 * (W + GAP) ))_0|$(( 3 * (W + GAP) ))_0" ;;
    grid) PLACES="0_0|$(( W + GAP ))_0|0_$(( H + GAP ))|$(( W + GAP ))_$(( H + GAP ))" ;;
    *) echo "layout: row or grid" >&2; exit 2 ;;
esac
FILTERS+="[c0][c1][c2][c3]xstack=inputs=4:layout=${PLACES}:fill=${SEAM}[v]"

if [[ "$LAYOUT" == row && "$FORMAT" == webp ]]; then
    OUT="docs/media/hero.webp"
else
    OUT="marketing/nibble-hero-$LAYOUT.$FORMAT"
fi
mkdir -p "${OUT:h}"
case "$FORMAT" in
    webp)
        # Homebrew's ffmpeg has no WebP encoder: frames as PNG, then img2webp (libwebp's tool).
        FRAMES="$TMPDIR/frames"
        mkdir -p "$FRAMES"
        ffmpeg -v error -y "${INPUTS[@]}" -filter_complex "$FILTERS" -map "[v]" "$FRAMES/%04d.png"
        img2webp -loop 0 -lossless -q 100 -m 6 -d $(( 1000 / FPS )) "$FRAMES"/*.png -o "$OUT" >/dev/null 2>&1
        ;;
    mp4)
        ffmpeg -v error -y "${INPUTS[@]}" -filter_complex "$FILTERS" -map "[v]" \
            -c:v libx264 -crf 14 -preset slow -profile:v high -pix_fmt yuv420p -movflags +faststart -an "$OUT"
        ;;
    *) echo "format: webp or mp4" >&2; exit 2 ;;
esac
echo "$OUT"
