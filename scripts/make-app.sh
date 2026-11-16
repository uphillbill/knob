#!/usr/bin/env bash
# Build Knob.app, sign it, copy it to ~/Applications and launch it.
#
#   ./scripts/make-app.sh                 # ad-hoc signature
#   SIGN_ID="My Signing Identity" ./scripts/make-app.sh
#
# Or put SIGN_ID in a .signing.env file at the repo root (gitignored; copy
# .signing.env.example). An environment variable wins over the file.
#
# With an ad-hoc signature, macOS treats every rebuild as a new app and asks for
# the audio and Accessibility permissions again. Signing with a stable identity
# (an Apple Development certificate, or a self-signed code-signing certificate
# made in Keychain Access) keeps the permissions across rebuilds. List yours with:
#   security find-identity -p codesigning

set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="io.github.uphillbill.knob"

if [[ -z "${SIGN_ID:-}" && -f .signing.env ]]; then
    # shellcheck disable=SC1091
    source .signing.env
fi
SIGN_ID="${SIGN_ID:--}"

swift build -c release

APP="build/Knob.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Knob "$APP/Contents/MacOS/Knob"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign "$SIGN_ID" "$APP"

# Quit a running copy before replacing it.
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
sleep 1

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Knob.app"
ditto "$APP" "$HOME/Applications/Knob.app"
open "$HOME/Applications/Knob.app"
echo "Installed and launched ~/Applications/Knob.app (signed with: $SIGN_ID)"
