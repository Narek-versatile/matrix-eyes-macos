#!/bin/bash
# Matrix Eyes installer: downloads the latest release, checks it, installs it and opens it.
#
#   curl -fsSL https://raw.githubusercontent.com/Narek-versatile/matrix-eyes-macos/main/install.sh | bash
#
# Optional: MATRIX_EYES_DEST=<folder> to install somewhere else, MATRIX_EYES_NO_OPEN=1 to skip launching.
set -euo pipefail

REPO="Narek-versatile/matrix-eyes-macos"
APP="Matrix Eyes.app"
BASE="https://github.com/$REPO/releases/latest/download"

fail() { echo "✗ $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Matrix Eyes is a macOS app."
[ "$(uname -m)" = "arm64" ] || fail "Matrix Eyes needs an Apple silicon Mac (M1 or newer)."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "Matrix Eyes needs macOS 14 Sonoma or newer (this Mac has $(sw_vers -productVersion))."

if [ -n "${MATRIX_EYES_DEST:-}" ]; then
    dest="$MATRIX_EYES_DEST"
elif [ -w /Applications ]; then
    dest="/Applications"
else
    dest="$HOME/Applications"
fi
mkdir -p "$dest"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "→ Downloading Matrix Eyes…"
curl -fL --progress-bar -o "$tmp/Matrix-Eyes.zip" "$BASE/Matrix-Eyes.zip" || fail "Download failed."
curl -fsSL -o "$tmp/Matrix-Eyes.zip.sha256" "$BASE/Matrix-Eyes.zip.sha256" || fail "Couldn't fetch the checksum."

echo "→ Verifying…"
expected=$(awk '{print $1}' "$tmp/Matrix-Eyes.zip.sha256")
actual=$(shasum -a 256 "$tmp/Matrix-Eyes.zip" | awk '{print $1}')
[ "$expected" = "$actual" ] || fail "Checksum mismatch; the download may be damaged. Try again."

echo "→ Installing to $dest…"
ditto -x -k "$tmp/Matrix-Eyes.zip" "$tmp/unpacked"
[ -d "$tmp/unpacked/$APP" ] || fail "The download didn't contain $APP."
pkill -f "$APP/Contents/MacOS/MatrixEyes" 2>/dev/null && sleep 1 || true
rm -rf "$dest/$APP"
mv "$tmp/unpacked/$APP" "$dest/"
xattr -dr com.apple.quarantine "$dest/$APP" 2>/dev/null || true

echo "✓ Installed $dest/$APP"
if [ -z "${MATRIX_EYES_NO_OPEN:-}" ]; then
    echo "→ Opening. Allow camera access when macOS asks; press Esc for settings."
    open "$dest/$APP"
fi
