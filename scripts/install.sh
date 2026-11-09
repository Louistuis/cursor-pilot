#!/bin/bash
# Installs the latest Cursor Pilot into Applications and opens it.
#
#   curl -fsSL https://cursorpilot.lou15.com/install.sh | bash
#
# What it does: downloads the latest release from GitHub, checks it against
# the release's SHA-256 and its code signature, replaces any copy already in
# Applications, and opens the app.
#
# What it doesn't do: it asks for no password, and it grants no permissions.
# macOS keeps the microphone, screen and accessibility switches for you; the
# app's set-up walks you through them.
#
# Options (environment variables):
#   CURSOR_PILOT_DIR=/some/folder   install there instead of Applications
#   CURSOR_PILOT_OPEN=0             don't open the app afterwards
set -euo pipefail

BASE="https://github.com/Louistuis/cursor-pilot/releases/latest/download"
APP="Cursor Pilot.app"

step() { printf '\033[1;36m›\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Cursor Pilot is a Mac app."
[ "$(uname -m)" = "arm64" ] || fail "Cursor Pilot needs an Apple Silicon Mac."
macos=$(sw_vers -productVersion)
[ "${macos%%.*}" -ge 15 ] || fail "Cursor Pilot needs macOS 15 or later (this Mac has $macos)."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

step "Finding the latest version"
want=$(curl -fsSL --retry 3 "$BASE/Cursor-Pilot.zip.sha256" | awk '{print $1}') ||
  fail "Couldn't reach GitHub. Check your connection and run this again."
[ "${#want}" -eq 64 ] || fail "Couldn't read the latest version's checksum. Run this again in a moment."

step "Downloading Cursor Pilot"
curl -fL --retry 3 --progress-bar "$BASE/Cursor-Pilot.zip" -o "$tmp/Cursor-Pilot.zip" ||
  fail "The download didn't finish. Nothing was installed; run this again."

step "Checking it"
got=$(shasum -a 256 "$tmp/Cursor-Pilot.zip" | awk '{print $1}')
[ "$got" = "$want" ] || fail "The download doesn't match its checksum. Nothing was installed; run this again."
ditto -x -k "$tmp/Cursor-Pilot.zip" "$tmp/unzipped"
[ -d "$tmp/unzipped/$APP" ] || fail "The download didn't contain the app. Nothing was installed."
codesign --verify --deep --strict "$tmp/unzipped/$APP" 2>/dev/null ||
  fail "The app's signature didn't check out. Nothing was installed."
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$tmp/unzipped/$APP/Contents/Info.plist" 2>/dev/null || echo "")

dest="${CURSOR_PILOT_DIR:-/Applications}"
if [ -z "${CURSOR_PILOT_DIR:-}" ] && [ ! -w "$dest" ]; then
  dest="$HOME/Applications"
fi
mkdir -p "$dest" 2>/dev/null || fail "Can't write to $dest."
[ -w "$dest" ] || fail "Can't write to $dest."

# A copy that's running from there is closed first, then replaced. The old
# one is only removed once the new one is in place.
if pgrep -f "$dest/$APP/Contents/MacOS/" >/dev/null 2>&1; then
  step "Closing the Cursor Pilot that's running"
  pkill -f "$dest/$APP/Contents/MacOS/" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$dest/$APP/Contents/MacOS/" >/dev/null 2>&1 || break
    sleep 0.3
  done
fi

step "Installing into $dest"
if [ -e "$dest/$APP" ]; then mv "$dest/$APP" "$tmp/previous.app"; fi
if ! ditto "$tmp/unzipped/$APP" "$dest/$APP"; then
  rm -rf "$dest/$APP"
  if [ -e "$tmp/previous.app" ]; then mv "$tmp/previous.app" "$dest/$APP"; fi
  fail "Couldn't copy the app into $dest. Your previous copy, if any, is back in place."
fi

printf '\033[1;32m✓\033[0m Cursor Pilot %s is installed.\n' "$version"
if [ "${CURSOR_PILOT_OPEN:-1}" != "0" ]; then
  open "$dest/$APP"
  echo "  It's opening now: paste your API key, then click Allow Everything."
  echo "  After that, hold Control + Option anywhere and ask."
fi
