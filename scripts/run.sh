#!/bin/zsh
# Builds the Debug app and (re)launches it. Extra arguments are passed to the app, e.g.
#   scripts/run.sh -NibbleShowPanelAtLaunch YES
set -euo pipefail
source "${0:A:h}/env.sh"

APP="$(scripts/build.sh debug | tail -1)"
pkill -x "Nibble Dev" 2>/dev/null && sleep 0.5 || true
open -n "$APP" --args "$@"
echo "Launched $APP"
