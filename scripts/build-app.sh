#!/bin/zsh
# Builds Cursor Pilot.app: the Rust core as a static library, then the Swift
# app linked against it, then the bundle, signed.
#
#   scripts/build-app.sh            # release build into build/
#   BUILD_ROOT=/Volumes/Big/cp scripts/build-app.sh   # put build output elsewhere
#   CODESIGN_IDENTITY="Apple Development: …" scripts/build-app.sh
#
# Without CODESIGN_IDENTITY the first "Apple Development" or "Developer ID
# Application" identity in the keychain is used, then the local "Cursor Pilot
# Development" one (scripts/dev-signing-identity.sh makes it), falling back to
# ad-hoc signing. A stable identity keeps macOS privacy permissions and the
# keychain entry valid across rebuilds; ad-hoc signing asks for them again.
#
# The finished app is copied to ~/Applications (no admin password needed) so
# Spotlight and Launchpad find it; INSTALL_DIR=/some/dir changes that and
# INSTALL_DIR= skips it.
set -euo pipefail

APP_DIR="${0:A:h:h}"
BUILD_ROOT="${BUILD_ROOT:-$APP_DIR/build}"
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$BUILD_ROOT/core-target}"
SWIFT_SCRATCH="$BUILD_ROOT/swift"
BUNDLE="$BUILD_ROOT/Cursor Pilot.app"
export CARGO_TARGET_DIR
# Match LSMinimumSystemVersion so C code in Rust dependencies links cleanly.
export MACOSX_DEPLOYMENT_TARGET=14.0

echo "==> Rust core"
cargo build --release --manifest-path "$APP_DIR/core/Cargo.toml"

echo "==> Swift app"
# SwiftPM does not notice a changed Rust archive, so force the final link.
rm -f "$SWIFT_SCRATCH"/*/release/CursorPilot(N)
CP_CORE_LIB_DIR="$CARGO_TARGET_DIR/release" swift build -c release \
  --package-path "$APP_DIR/mac" --scratch-path "$SWIFT_SCRATCH"
BIN="$(CP_CORE_LIB_DIR="$CARGO_TARGET_DIR/release" swift build -c release \
  --package-path "$APP_DIR/mac" --scratch-path "$SWIFT_SCRATCH" --show-bin-path)/CursorPilot"

echo "==> Bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/CursorPilot"
cp "$APP_DIR/mac/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
[[ -f "$APP_DIR/mac/Resources/AppIcon.icns" ]] && cp "$APP_DIR/mac/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/"

echo "==> Sign"
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Developer ID Application|Apple Development):' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
fi
if [[ -z "$IDENTITY" ]]; then
  # Self-signed, so not "valid" (-v); codesign accepts it all the same.
  IDENTITY="$(security find-identity -p codesigning 2>/dev/null \
    | awk '/"Cursor Pilot Development"/ { print $2; exit }' || true)"
fi
if [[ -n "$IDENTITY" ]]; then
  codesign --force --options runtime --entitlements "$APP_DIR/mac/Resources/CursorPilot.entitlements" \
    --sign "$IDENTITY" "$BUNDLE"
  echo "Signed with: $IDENTITY"
else
  codesign --force --entitlements "$APP_DIR/mac/Resources/CursorPilot.entitlements" --sign - "$BUNDLE"
  echo "Signed ad-hoc (macOS will ask for permissions again after each rebuild;"
  echo "run scripts/dev-signing-identity.sh once to stop that)"
fi

echo "Built: $BUNDLE"

# Installs into /Applications when Cursor Pilot is already there and you own
# it (copy it in once, see the README), otherwise into ~/Applications.
if [[ -z "${INSTALL_DIR+x}" ]]; then
  if [[ -w "/Applications/Cursor Pilot.app/Contents" ]]; then INSTALL_DIR=/Applications; else INSTALL_DIR="$HOME/Applications"; fi
fi
if [[ -n "$INSTALL_DIR" ]]; then
  DEST="$INSTALL_DIR/Cursor Pilot.app"
  mkdir -p "$INSTALL_DIR"
  if [[ -d "$DEST" && ! -w "$INSTALL_DIR" ]]; then
    # The folder isn't ours (/Applications), but the app is: update it in place.
    rsync -a --delete "$BUNDLE/" "$DEST/"
  else
    rm -rf "$DEST"
    ditto "$BUNDLE" "$DEST"
  fi
  echo "Installed: $DEST"
fi
