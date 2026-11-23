#!/bin/sh
# Postura per-user installer. Safe to re-run.
#   curl -fsSL https://raw.githubusercontent.com/samihalawa/postura/main/install.sh | sh
#   sh install.sh uninstall          remove the app and login item (keeps your examples)
#   sh install.sh uninstall --purge  also delete examples, venv and logs
set -eu
REPO=samihalawa/postura; LABEL=io.github.samihalawa.postura
APP="$HOME/Applications/Postura.app"; SUP="$HOME/Library/Application Support/Postura"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"; TRAIN="$HOME/.local/bin/postura-train"
MODELS=https://storage.googleapis.com/mediapipe-models

if [ "${1:-}" = uninstall ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  pkill -f "$APP/Contents/MacOS/Postura" 2>/dev/null || true
  rm -rf "$APP" "$PLIST" "$TRAIN"
  [ "${2:-}" = --purge ] && rm -rf "$SUP" "$HOME/Library/Logs/postura.log" "$HOME/Library/Logs/postura-features.jsonl" "$HOME/Library/Logs/postura.out.log"
  echo "Postura removed"; exit 0
fi

[ "$(uname)" = Darwin ] || { echo "Postura needs macOS"; exit 1; }
command -v swiftc >/dev/null 2>&1 || { echo "Needs the Xcode Command Line Tools: run  xcode-select --install  and try again"; exit 1; }

# Source: this checkout when run from one, otherwise the latest main branch.
SRC=$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)
if [ ! -f "$SRC/mac/Postura.swift" ]; then
  SRC=$(mktemp -d); curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$SRC" --strip-components=1
fi

echo "1/4 building Postura.app"
B=$(mktemp -d)/Postura.app; mkdir -p "$B/Contents/MacOS" "$B/Contents/Resources/models"
swiftc -O -target "$(uname -m)-apple-macos14.0" "$SRC/mac/Postura.swift" -o "$B/Contents/MacOS/Postura" 2>&1 | grep -v -e warning -e '^ *|' -e '^[0-9]* |' -e '^$' -e note: -e DeprecatedDeclaration || true
[ -x "$B/Contents/MacOS/Postura" ] || { echo "build failed"; exit 1; }
cp "$SRC/mac/Info.plist" "$B/Contents/"; /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $LABEL" "$B/Contents/Info.plist"
cp "$SRC/mac/postura-eye.py" "$B/Contents/Resources/"

echo "2/4 downloading MediaPipe models"
for m in pose_landmarker/pose_landmarker_full/float16/latest/pose_landmarker_full.task \
         face_landmarker/face_landmarker/float16/latest/face_landmarker.task \
         image_embedder/mobilenet_v3_small/float32/latest/mobilenet_v3_small.tflite; do
  curl -fsSL "$MODELS/$m" -o "$B/Contents/Resources/models/$(basename "$m")"
done
codesign --force -s - "$B" >/dev/null 2>&1

echo "3/4 setting up the posture judge (Python + MediaPipe, first run takes a minute)"
mkdir -p "$SUP" "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$HOME/.local/bin"
command -v uv >/dev/null 2>&1 || [ -x "$HOME/.local/bin/uv" ] || curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh >/dev/null
UV=$(command -v uv || echo "$HOME/.local/bin/uv")
[ -x "$SUP/venv/bin/python3" ] || "$UV" venv -q --python 3.11 "$SUP/venv"
"$UV" pip install -q --python "$SUP/venv/bin/python3" mediapipe opencv-python-headless numpy

echo "4/4 installing and starting"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -rf "$APP"; mv "$B" "$APP"
install -m 755 "$SRC/mac/postura-train" "$TRAIN"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Postura</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer>
<key>StandardOutPath</key><string>$HOME/Library/Logs/postura.out.log</string>
<key>StandardErrorPath</key><string>$HOME/Library/Logs/postura.out.log</string>
</dict></plist>
PL
if [ "${POSTURA_NO_START:-}" = 1 ]; then echo "Postura installed (not started)."; else
  launchctl bootstrap "gui/$(id -u)" "$PLIST"; echo "Postura is running. Allow camera access when macOS asks."; fi
echo "Teach it: Ctrl-Opt-Cmd-B (this is bad) / Ctrl-Opt-Cmd-G (this is good). Log: ~/Library/Logs/postura.log"
