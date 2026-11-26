#!/bin/sh
# Postura installer: puts the latest signed and notarized Postura.app in ~/Applications and opens it.
# The app opens from the Dock and sets up its posture model on first launch.
#   curl -fsSL https://raw.githubusercontent.com/samihalawa/postura/main/install.sh | sh
#   sh install.sh uninstall          remove the app and its login agent (keeps your examples)
#   sh install.sh uninstall --purge  also delete examples, model environment and logs
# With Homebrew instead:  brew install --cask samihalawa/tap/postura
set -eu
REPO=samihalawa/postura; LABEL=io.github.samihalawa.postura
SUP="$HOME/Library/Application Support/Postura"; PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DEST="$HOME/Applications"
APP="$DEST/Postura.app"
LEGACY=/Applications/Postura.app

agent_program() {
  plutil -extract ProgramArguments.0 raw -o - "$PLIST" 2>/dev/null || true
}

homebrew_owns_app() {
  for brew_bin in "$(command -v brew || true)" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$brew_bin" ] || continue
    # Check the installed cask's directory without loading an untrusted tap.
    caskroom=$("$brew_bin" --caskroom 2>/dev/null) || return 0
    [ -n "$caskroom" ] || return 0
    [ ! -d "$caskroom/postura" ] || return 0
  done
  return 1
}

[ "$(uname)" = Darwin ] || { echo "Postura needs macOS" >&2; exit 1; }

stop_copy() {
  exe="$1/Contents/MacOS/Postura"
  if [ "$(agent_program)" = "$exe" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
  fi
  for pid in $(pgrep -x Postura || true); do
    [ "$(ps -p "$pid" -o comm= || true)" != "$exe" ] || kill "$pid" 2>/dev/null || true
  done
}

remove_legacy_copy() {
  if [ "$(agent_program)" = "$LEGACY/Contents/MacOS/Postura" ] && ! homebrew_owns_app; then
    stop_copy "$LEGACY"
    rm -rf "$LEGACY"
    echo "Removed old shell install at $LEGACY"
  fi
}

if [ "${1:-}" = uninstall ]; then
  remove_legacy_copy
  stop_copy "$APP"
  rm -rf "$APP"
  [ "${2:-}" != --purge ] || rm -rf "$SUP" "$HOME/Library/Logs/postura.log" "$HOME/Library/Logs/postura-features.jsonl" \
    "$HOME/Library/Logs/postura.out.log" "$HOME/Library/Logs/postura-setup.log"
  echo "Removed $APP"
  exit 0
fi

URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep -o '"browser_download_url": *"[^"]*Postura-[^"]*\.zip"' | head -1 | cut -d'"' -f4)
[ -n "$URL" ] || { echo "Could not find the latest release"; exit 1; }
echo "Downloading $URL"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
asset=${URL##*/}
curl -fsSL "$URL" -o "$T/$asset"
curl -fsSL "${URL%/*}/SHA256SUMS.txt" -o "$T/SHA256SUMS.txt"
expected=$(awk -v asset="$asset" '$2==asset { print $1 }' "$T/SHA256SUMS.txt")
actual=$(shasum -a 256 "$T/$asset" | cut -d' ' -f1)
[ "$actual" = "$expected" ] || { echo "Postura download checksum mismatch" >&2; exit 1; }
ditto -x -k "$T/$asset" "$T"
codesign --verify --strict "$T/Postura.app"
mkdir -p "$DEST"
remove_legacy_copy
stop_copy "$APP"
rm -rf "$APP"
mv "$T/Postura.app" "$APP"
open "$APP"
echo "Installed $APP. Open Postura from the Dock and allow camera access if prompted."
