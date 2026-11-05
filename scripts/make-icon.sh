#!/bin/zsh
# Draws Cursor Pilot's app icon into mac/Resources/AppIcon.icns. The rainbow
# frame is the app's own glow shader (Glow.swift), so the icon lights up the
# same way the screen edges do.
#
#   scripts/make-icon.sh                 # write AppIcon.icns
#   CP_ICON_PREVIEW=/tmp/icon.png scripts/make-icon.sh   # also a 1024px PNG
set -euo pipefail
APP_DIR="${0:A:h:h}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -O -module-name MakeIcon "$APP_DIR/scripts/icon/main.swift" \
  "$APP_DIR/mac/Sources/CursorPilot/Glow.swift" -o "$TMP/make-icon" -suppress-warnings
"$TMP/make-icon" "$APP_DIR/mac/Resources/AppIcon.icns"
