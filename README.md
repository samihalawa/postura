<p align="center"><img src=".github/assets/hero.svg" alt="Postura" width="100%"></p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/on--device-MediaPipe-8D9FFF" alt="MediaPipe">
</p>

**Postura** is a posture guard for macOS. It watches you through the camera and, when you sit clearly badly, an
Apple-Intelligence-style glow closes in from the edges of every display. Fix your posture and it opens back out. Keep
slouching and it covers the screen until you sit up. It learns what *your* good and bad posture look like from two hotkeys.

Everything runs on the Mac. No images are stored or sent anywhere; only numbers (angles and distances) are kept.

## Install

```sh
brew install --cask samihalawa/tap/postura
```

Or without Homebrew: `curl -fsSL https://raw.githubusercontent.com/samihalawa/postura/main/install.sh | sh`

Then open **Postura** once and allow the camera. It is a menu bar app (a standing figure in the menu bar), signed with a
Developer ID and notarized by Apple, for macOS 14 or later on Apple silicon and Intel. On first launch it sets up its
posture model, a private Python environment with Google's MediaPipe made by [uv](https://github.com/astral-sh/uv),
in about a minute. It then keeps itself running: it starts at login and comes back if it is closed or crashes.

- **Menu bar**: current state at a glance, "This is good / bad posture", Settings.
- **Window** (menu bar → Open Postura): live status and score, today's blocked time and corrections, teach buttons,
  and options: require glasses, status pill, keep running, language.
- **Log**: `~/Library/Logs/postura.log`, one line per decision.

Uninstall: `brew uninstall --cask postura` (`--zap` also deletes your examples and logs), or
`curl -fsSL https://raw.githubusercontent.com/samihalawa/postura/main/install.sh | sh -s uninstall`.

## How it behaves

| You | Postura |
|---|---|
| Sit well, or step away, or turn to a second screen | Nothing. Out of frame, further than 85 cm or turned more than 40° is never judged. |
| Slouch, tilt your head or shoulders clearly | After about a second a thin glow appears at the screen edges and starts closing in. |
| Keep slouching | The glow closes in over about 3.5 s, frosting the screen behind it, then covers it and blocks mouse, keyboard, Cmd-Tab and Force Quit. |
| Sit up | The glow opens back out and disappears in about a second. |
| Lean out of view, hide your face or turn away while it is warning | It keeps counting as bad; it only clears when you are back and sitting well (or truly gone for 90 s). |
| Wear sunglasses | They don't count as glasses: dark lenses are detected from the eye-to-cheek brightness. |
| Are on a video call (FaceTime, Teams, WebRTC in the browser) | Only a faint edge glow, it never blocks. |
| Disagree with it | Press **Ctrl-Opt-Cmd-G** (or the button on the cover, or the menu): it lifts and learns that posture as good. 5 corrections a day. |

## Teach it your posture

- **Ctrl-Opt-Cmd-B**: "this posture is bad". **Ctrl-Opt-Cmd-G**: "this posture is good".
- The last 4 seconds and the next 6 seconds of measurements become examples in
  `~/Library/Application Support/Postura/examples.jsonl`. Near an example, your labels win over the built-in rules,
  newest first.
- Same from the menu bar or the window. With **Require glasses** on, the window's glasses buttons teach it what you
  look like with and without them, and it covers the screen when you forget them (sunglasses never count).

The built-in rules only flag clearly bad posture: head sunk towards the shoulders and pushed forward, head rolled more
than 22°, shoulders tilted more than 16°. The UI is in English, or Spanish when that is the Mac's first language
(or pick one in the window).

## How it works

`Postura.app` (Swift, AppKit, Core Animation) owns the camera, the timing and the screens. Two to six frames a second (more while it suspects bad posture)
go to `postura-eye.py`, which runs MediaPipe Pose Landmarker and Face Landmarker and returns a score from 0 (good)
to 1 (bad) with a reason. The app smooths the score, then drives the glow: a rotating conic gradient shown through
blurred strokes on the display edge, plus a colour wash and a frosted blur behind a slowly waving front. Every boundary is
feathered with a GPU shadow mask, so there is no hard line anywhere. While the cover is up it
shows no camera picture: your portrait condenses out of
drifting light (your face and body spun from soft strands), stays a while and drifts apart, then pauses. The time and the message sit in the corners and change slowly, only when a new reason has held for 4 s.

Telemetry for tuning lives in `~/Library/Logs/postura-features.jsonl` (one row of numbers per second). Offline replay of
a recording: `~/Library/Application\ Support/Postura/venv/bin/python3 postura-eye.py --video clip.mov`.

**Build from source**: `./build.sh` makes a universal `build/Postura.app` (ad-hoc signed; `SIGN_IDENTITY` and
`NOTARY_*` variables give a Developer ID, notarized build; see the top of the script).

**Strict mode** (optional, for people who want it hard to switch off): `BUNDLE_ID=com.sami.postura ./build.sh` then
`sudo ./mac/install.sh`. Root daemons relaunch the app and restore it if it is deleted or disabled. With strict mode
installed, opening the Homebrew copy simply brings up the strict copy's window.

## Compared with

| | Postura | [Dorso](https://github.com/tldev/dorso) |
|---|---|---|
| Detection | MediaPipe pose + face landmarks: 3D neck, head and shoulder geometry | Apple Vision head position against a calibrated baseline, or AirPods motion |
| Personal | Learns from your own labelled examples (two hotkeys) | One calibration of your upright posture |
| On bad posture | Glow that closes in and finally blocks input | Progressive screen blur |
| Video calls | Detected; never blocks | — |

Dorso is the more polished app, with a settings window, AirPods mode and a signed, notarized download. Postura is for people
who want detection that learns their own posture and an enforcement that cannot just be waved away.

## Limits

- Tested on macOS 27 (Apple silicon). It is built locally and ad-hoc signed, not notarized.
- One camera, one person: with several faces in frame it judges the nearest one.
- Blocking uses kiosk presentation options; the login item restarts it if it quits.

## Credits

- Glow technique: [AppleIntelligenceGlowEffect](https://github.com/jacobamobin/AppleIntelligenceGlowEffect) by Jacob Mobin and
  [IntelligenceGlow](https://github.com/Livsy90/IntelligenceGlow) by Livsy90 (MIT), rebuilt here in Core Animation with an organic, moving shape.
- Pose and face models: [Google MediaPipe](https://github.com/google-ai-edge/mediapipe) (Apache-2.0), downloaded at install.

## License

MIT
