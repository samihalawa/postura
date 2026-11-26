<p align="center"><img src=".github/assets/hero.svg" alt="Postura" width="100%"></p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/on--device-MediaPipe-8D9FFF" alt="MediaPipe">
</p>

**Postura** is a posture coach for macOS. It waits for a clearly bad posture to persist, then gradually covers
the display until you correct your posture. The screen clears on the first empty camera detection. Open Postura from the Dock to see
your current status, pause coaching, or correct a reading.

Everything runs on the Mac. No camera frames are stored or sent. Postura keeps numerical posture examples and, if you enroll for the camera preview, a local numerical face reference.

## Install

```sh
brew install --cask samihalawa/tap/postura
```

Or without Homebrew: `curl -fsSL https://raw.githubusercontent.com/samihalawa/postura/main/install.sh | sh`

Open **Postura** and allow camera access. The Dock icon opens the coaching window, and the menu bar icon offers the same
basic controls. The first launch sets up a local MediaPipe environment using [uv](https://github.com/astral-sh/uv).
Postura runs on macOS 14 or later on Apple silicon and Intel. Enable **Keep Postura running** in Advanced settings if
you want it to start at login.

- **Menu bar**: live status, visibility feedback, and Settings.
- **Window** (Dock → Postura): live status, **Pause coaching**, and **Good posture** / **Bad posture** feedback. Camera selection and other options are in **Advanced settings**.
- **Log**: `~/Library/Logs/postura.log`, one line per decision.

Uninstall: `brew uninstall --cask postura` (`--zap` also deletes your examples and logs), or
`curl -fsSL https://raw.githubusercontent.com/samihalawa/postura/main/install.sh | sh -s uninstall`.

## Optional proximity detection

| Camera observation | Screen |
|---|---|
| Nobody detected | Visible on the first empty detection. |
| People in the distant background only | Visible. |
| A close person, including someone with their face cropped out | Covered. |
| A nearby person who keeps facing the display or stays stationary | Covered once the behavior persists. |
| A video call | A thin edge glow. |

Privacy mode waits 5 seconds for a qualifying situation, then closes the cover gradually over 5 seconds.
A brief change while someone is still detected leaves the cover steady. A clear verdict held for 2 seconds starts
a smooth reveal. If nobody is detected, the screen clears immediately.

Turn on **Cover when someone is nearby** in Advanced settings to use proximity detection. In that mode, use **Should Hide** (Ctrl-Opt-Cmd-B) for an incorrect reveal and **Should Reveal**
(Ctrl-Opt-Cmd-G or the button on the cover) for an incorrect hide. Feedback is saved immediately when the recent
frames contain one measurable nearby person. Postura reuses similar observations while keeping the empty and
distant rules in effect. It stores numerical features in `privacy-examples.jsonl` under
`~/Library/Application Support/Postura`.

Import existing examples with the app's Python environment. Set `RESOURCES` to the app's
`Contents/Resources` directory and use the Python executable that the app uses.

```sh
python3 "$RESOURCES/postura-eye.py" --import-privacy hide example.jpg
python3 "$RESOURCES/postura-eye.py" --import-privacy reveal false-trigger.jpg
python3 "$RESOURCES/postura-eye.py" --import-privacy background distant-person.jpg
```

Use `nearby` and `close` to add other distance calibration images. The strict install also exposes
`postura-train LABEL IMAGE...` and `postura-train hide|reveal` for live feedback.

### OBS replay

Add the recording as a **Media Source** in OBS, disable looping, and enable **Show nothing when playback ends**.
Start **Virtual Camera**, select **OBS Virtual Camera** in Postura's Camera picker, then restart playback.
The Postura status file in its Application Support folder records the selected camera, visibility decisions,
and whether the cover is actually blocking. For direct replay of the classifier, use
`python3 "$RESOURCES/postura-eye.py" --video clip.mov` with the same environment. Each output row includes time
in seconds and the `privacy.hide` decision.

## Posture coach

| You | Postura |
|---|---|
| Sit well or turn to a second screen | No new cover appears. A turned head or uncertain reading can’t start a cover. |
| Slouch, tilt your head or shoulders clearly | After 5 seconds of clearly bad posture, a thin glow starts closing in. |
| Keep slouching | The glow closes in over about 5 seconds, frosting the screen behind it, then covers it and blocks mouse, keyboard, Cmd-Tab and Force Quit. |
| Sit up | After 2 seconds of corrected posture, the glow opens back out over about 2.5 seconds. |
| Leave the frame while it is warning | The cover clears when nobody is detected. |
| Wear sunglasses with **Require glasses** enabled | They don't count as glasses: dark lenses are detected from the eye-to-cheek brightness. |
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
to 1 (bad) with a reason. In privacy mode, it combines landmarks, a fallback person detector, and labeled visibility examples to decide when to cover. The app drives the glow: a rotating conic gradient shown through
blurred strokes on the display edge, plus a colour wash and a frosted blur behind a slowly waving front. Every boundary is
feathered with a GPU shadow mask, so there is no hard line anywhere. While the cover is up it
can show a small circular, background-free camera preview at the top-right edge of the main display. In Settings, choose **Enroll my face for the camera preview** and select one or more photos of yourself. Each displayed camera frame must match the enrolled face. The circle fades when the match ends, when nobody is visible, or when multiple people are detected. The time and the message sit in the corners and change slowly, only when a new reason has held for 4 s.

Telemetry for tuning lives in `~/Library/Logs/postura-features.jsonl` (one row of numbers per second).

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

- Tested on Apple silicon with macOS 27. Local contributor builds use ad-hoc signing by default.
- Privacy mode checks each detected person. The posture coach scores the nearest face.
- Blocking uses kiosk presentation options; the login item restarts it if it quits.

## Credits

- Glow technique: [AppleIntelligenceGlowEffect](https://github.com/jacobamobin/AppleIntelligenceGlowEffect) by Jacob Mobin and
  [IntelligenceGlow](https://github.com/Livsy90/IntelligenceGlow) by Livsy90 (MIT), rebuilt here in Core Animation with an organic, moving shape.
- Pose and face models: [Google MediaPipe](https://github.com/google-ai-edge/mediapipe) (Apache-2.0), downloaded at install.

## License

MIT
