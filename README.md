# SyncSpeaker

An iPhone app that plays the same music on several phones, each connected to
its own Bluetooth speaker, and keeps them in sync. It measures each speaker's
real delay with the microphone and corrects for it.

See **DESIGN.md** for how it works and why.

> **Status:** first scaffold. The sync algorithms are checked by
> `sim/simulate.py`, but the Swift code was written without a Mac and **has
> not been compiled yet**. Expect to fix a handful of build errors on the first build.

## Requirements

- A Mac with Xcode 16 or newer
- Two or more iPhones on iOS 17+ (the simulator can't do Bluetooth audio or real mic timing)
- A free or paid Apple developer account, to install on your own phones
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and run

```bash
cd SyncSpeaker
xcodegen generate          # creates SyncSpeaker.xcodeproj from project.yml
open SyncSpeaker.xcodeproj
```

In Xcode: select the **SyncSpeaker** target → *Signing & Capabilities* → pick
your team, and change the bundle ID to something unique
(e.g. `com.yourname.syncspeaker`). Run on each phone.

## Building without a Mac (Windows)

GitHub Actions builds the app on a cloud Mac every time you push
(`.github/workflows/build.yml`). It runs the unit tests in the iOS Simulator,
runs `sim/simulate.py`, and produces an **unsigned** `SyncSpeaker.ipa`.

1. Push to GitHub. Open the repo's **Actions** tab, then the latest **Build** run.
2. Under **Artifacts**, download `SyncSpeaker-ipa` and unzip it to get `SyncSpeaker.ipa`.
3. On Windows, install [Sideloadly](https://sideloadly.io) plus iTunes and iCloud
   from Apple's website (the Microsoft Store versions don't work with Sideloadly).
4. Plug in the iPhone, open Sideloadly, drop in the `.ipa`, enter your Apple ID,
   and click **Start**.
5. On the iPhone: *Settings → General → VPN & Device Management*, trust your
   Apple ID. On iOS 16+ also turn on *Settings → Privacy & Security → Developer Mode*.

With a free Apple ID the app stops opening after **7 days**; re-run Sideloadly
to refresh it. A free ID can have at most 3 sideloaded apps per phone.

## First test (milestone M1)

1. Put both phones on the same Wi-Fi, side by side, using their built-in speakers.
2. Phone A: **Start a session**. Phone B: **Join a session** and tap phone A.
3. On phone B, wait until *Clock accuracy* shows a value under about ±2 ms.
4. On phone A, tap **Click track (120 bpm)**.
5. Listen: in sync, the clicks sound like one click. Out of sync by more than
   ~10 ms, they sound like a double hit ("flam").

Then connect each phone to a Bluetooth speaker and run **Calibrate speakers**,
with the listening phone held where people will be standing.

## Adding music

Every phone needs the same file with the same name. In the Files app, go to
*On My iPhone → SyncSpeaker* and drop files in (mp3, m4a, wav, aiff, flac).
From a Mac, drag them into the app in Finder's iPhone file-sharing view.

## Spotify setup (optional)

1. Create an app at <https://developer.spotify.com/dashboard>.
   - Redirect URI: `syncspeaker://spotify-callback`
   - iOS bundle ID: the one you set in Xcode
   - APIs: iOS SDK
2. Under *User Management*, add the Spotify account of everyone who'll use it.
   Everyone needs Spotify Premium.
3. Put your client ID in `SyncSpeaker/Audio/SpotifyPlayer.swift` (`clientID`).
4. In `project.yml`, uncomment the `packages:` block and the `dependencies:`
   lines for `SpotifyiOS`, then run `xcodegen generate` again.
5. In the app, tap **Connect Spotify** on each phone. Paste a track link or
   `spotify:track:…` URI on the host phone and tap **Play**.

The app builds without the SDK; Spotify buttons just report that it's missing.

## Algorithm checks

```bash
pip install numpy
python3 sim/simulate.py
```

Simulates clock sync over a jittery network, chirp detection in a reverberant
room, the echo check on synthetic music, and the drift controller. Last run:

| Check | Result |
|---|---|
| Clock sync (35 ppm skew, asymmetric jitter) | p95 error 1.05 ms |
| Chirp detection (reverb, codec band-limit, noise) | p95 error < 0.01 ms |
| Echo check (cepstrum) | lag found in 100% of trials |
| Drift controller (60 ppm drift) | worst error 0.76 ms after settling |

These are simulations; real phones and rooms will be worse. Measure on devices.

## Layout

```
SyncSpeaker/
  App/        app entry point
  Core/       HostClock, ClockSync, Messages, PeerSession, Calibrator, SessionCoordinator
  Audio/      AudioRoute, SyncPlayer + DriftController, LocalEnginePlayer,
              SpotifyPlayer, MicRecorder, LocalLibrary
  DSP/        chirp, matched filter, cepstral echo check (Accelerate)
  UI/         SwiftUI views
SyncSpeakerTests/  unit tests for the pure logic
sim/          numpy simulations of the algorithms
```
