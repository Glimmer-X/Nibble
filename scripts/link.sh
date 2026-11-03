#!/bin/zsh
# Builds the Release app and puts a link to it in /Applications, so Nibble opens from the
# Applications folder (or the Dock) and always runs the latest build.
#   scripts/link.sh            build Release and (re)create /Applications/Nibble.app
#   scripts/link.sh --remove   remove the link
#
# The link is a symbolic link into build/DerivedData.noindex: Spotlight neither follows it nor
# indexes build folders, so no second Nibble shows up anywhere. An installed Nibble (a real app,
# not a link) is never touched. A running Nibble keeps running the build it started from; quit
# and reopen it to get the new one.
set -euo pipefail
source "${0:A:h}/env.sh"

LINK=/Applications/Nibble.app
if [[ -e "$LINK" && ! -L "$LINK" ]]; then
    echo "$LINK is an installed app, not a link; leaving it alone." >&2
    exit 1
fi
if [[ "${1:-}" == "--remove" ]]; then
    rm -f "$LINK"
    echo "Removed $LINK"
    exit 0
fi

APP="$(scripts/build.sh release | tail -1)"
ln -sfn "$APP" "$LINK"
echo "$LINK -> $APP"
