#!/bin/sh
# Builds build/Postura.app (universal). With "dist": also dist/Postura-<version>.zip and SHA256SUMS.txt.
# Ad-hoc signed by default. For a Developer ID build set SIGN_IDENTITY (and SIGN_KEYCHAIN if it is not in the default
# search list); to notarize and staple set NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER (an App Store Connect API key).
# BUNDLE_ID overrides the bundle identifier (strict mode uses its own).
set -eu
cd "$(dirname "$0")"
VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' mac/Info.plist)
APP=build/Postura.app; MODELS=https://storage.googleapis.com/mediapipe-models; CACHE=build/.models
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/models" "$CACHE"
for a in arm64 x86_64; do
  swiftc -O -target $a-apple-macos14.0 mac/Postura.swift -o build/Postura-$a 2>&1 | grep -E 'error' && exit 1 || true
done
lipo -create build/Postura-arm64 build/Postura-x86_64 -output "$APP/Contents/MacOS/Postura"; rm -f build/Postura-arm64 build/Postura-x86_64
cp mac/Info.plist "$APP/Contents/"; [ -n "${BUNDLE_ID:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns mac/postura-eye.py "$APP/Contents/Resources/"
for m in pose_landmarker/pose_landmarker_full/float16/latest/pose_landmarker_full.task \
         face_landmarker/face_landmarker/float16/latest/face_landmarker.task; do
  f="$CACHE/$(basename "$m")"; [ -s "$f" ] || curl -fsSL "$MODELS/$m" -o "$f"; cp "$f" "$APP/Contents/Resources/models/"
done
SFACE=face_recognition_sface_2021dec_int8.onnx
SFACE_SHA=2b0e941e6f16cc048c20aee0c8e31f569118f65d702914540f7bfdc14048d78a
owner_model_valid() { [ -f "$1" ] && [ "$(shasum -a 256 "$1" | cut -d ' ' -f1)" = "$SFACE_SHA" ]; }
if ! owner_model_valid "$CACHE/$SFACE"; then
  curl -fLsS --retry 2 "https://media.githubusercontent.com/media/opencv/opencv_zoo/main/models/face_recognition_sface/$SFACE" -o "$CACHE/$SFACE.download"
  owner_model_valid "$CACHE/$SFACE.download" || { echo "SFace model checksum mismatch" >&2; exit 1; }
  mv "$CACHE/$SFACE.download" "$CACHE/$SFACE"
fi
cp "$CACHE/$SFACE" "$APP/Contents/Resources/models/"
SIGN=${SIGN_IDENTITY:--}
if [ "$SIGN" = - ]; then codesign --force --sign - --entitlements mac/Postura.entitlements "$APP"
else codesign --force --options runtime --timestamp --entitlements mac/Postura.entitlements --sign "$SIGN" ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} "$APP"; fi
echo "built $APP ($VER)"
[ "${1:-}" = dist ] || exit 0
rm -rf dist && mkdir dist; Z="dist/Postura-$VER.zip"
ditto -c -k --keepParent "$APP" "$Z"
if [ -n "${NOTARY_KEY:-}" ]; then
  xcrun notarytool submit "$Z" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  xcrun stapler staple "$APP"; rm "$Z"; ditto -c -k --keepParent "$APP" "$Z"
fi
( cd dist && shasum -a 256 ./*.zip | sed 's# \./# #' > SHA256SUMS.txt && cat SHA256SUMS.txt )
