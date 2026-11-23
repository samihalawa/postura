#!/bin/bash
# Strict mode: install a built Postura.app (build/Postura.app) system-wide with root daemons that relaunch it and restore it
# if it is removed or disabled. For the normal per-user install use ./install.sh. Run from the repo: sudo ./mac/install.sh [user]
set -e; [ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
R=$(cd "$(dirname "$0")/.." && pwd); L=/usr/local/libexec/postura; B=/var/db/postura
mkdir -p "$L" "$B"; echo "${1:-${SUDO_USER:-$(stat -f%Su /dev/console)}}" > "$B/user"
[ -x "$L/venv/bin/python3" ] || { /opt/homebrew/opt/python@3.11/bin/python3.11 -m venv "$L/venv"; "$L/venv/bin/pip" -q install mediapipe opencv-python-headless; }
rm -rf "$B/Postura.app"; cp -Rp "$R/build/Postura.app" "$B/"; chown -R root:wheel "$B/Postura.app"
for f in postura-guard postura-keeper postura-train com.sami.postura.plist com.sami.postura-keeper.plist; do install -m 755 -o root -g wheel "$R/mac/$f" "$B/$f"; done
chmod 644 "$B"/*.plist
rm -rf "$L/Postura.app"; cp -Rp "$B/Postura.app" "$L/"
for f in postura-guard postura-keeper postura-train; do install -m 755 -o root -g wheel "$B/$f" "$L/$f"; done
ln -sf "$L/postura-train" /usr/local/bin/postura-train; rm -f /usr/local/bin/postura-recalibrate
for s in com.sami.postura com.sami.postura-keeper; do
  install -m 644 -o root -g wheel "$B/$s.plist" /Library/LaunchDaemons/
  launchctl bootout "system/$s" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do launchctl print "system/$s" >/dev/null 2>&1 || break; sleep 0.5; done  # bootout is asynchronous
  launchctl bootstrap system "/Library/LaunchDaemons/$s.plist"
done
pkill -x Postura || true
echo installed
