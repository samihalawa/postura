#!/bin/sh
# Postura installer: puts the latest signed and notarized Postura.app in /Applications (or ~/Applications) and opens it.
# The app then keeps itself running (login agent) and sets up its posture model on first launch.
#   curl -fsSL https://raw.githubusercontent.com/samihalawa/postura/main/install.sh | sh
#   sh install.sh uninstall          remove the app and its login agent (keeps your examples)
#   sh install.sh uninstall --purge  also delete examples, model environment and logs
# With Homebrew instead:  brew install --cask samihalawa/tap/postura
set -eu
REPO=samihalawa/postura; LABEL=io.github.samihalawa.postura
SUP="$HOME/Library/Application Support/Postura"; PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DEST=/Applications; [ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

if [ "${1:-}" = uninstall ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  pkill -f "Postura.app/Contents/MacOS/Postura" 2>/dev/null || true
  rm -rf /Applications/Postura.app "$HOME/Applications/Postura.app" "$PLIST" "$HOME/.local/bin/postura-train"
  [ "${2:-}" = --purge ] && rm -rf "$SUP" "$HOME/Library/Logs/postura.log" "$HOME/Library/Logs/postura-features.jsonl" \
    "$HOME/Library/Logs/postura.out.log" "$HOME/Library/Logs/postura-setup.log"
  echo "Postura removed"; exit 0
fi

[ "$(uname)" = Darwin ] || { echo "Postura needs macOS"; exit 1; }
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep -o '"browser_download_url": *"[^"]*Postura-[^"]*\.zip"' | head -1 | cut -d'"' -f4)
[ -n "$URL" ] || { echo "Could not find the latest release"; exit 1; }
echo "Downloading $URL"
T=$(mktemp -d); curl -fsSL "$URL" -o "$T/Postura.zip"; ditto -x -k "$T/Postura.zip" "$T"
pkill -f "Postura.app/Contents/MacOS/Postura" 2>/dev/null || true
rm -rf "$DEST/Postura.app"; mv "$T/Postura.app" "$DEST/"; rm -rf "$T"
open "$DEST/Postura.app"
echo "Installed $DEST/Postura.app. Allow the camera when asked; Postura lives in the menu bar."
