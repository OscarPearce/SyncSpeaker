# Notes for Claude Code

iPhone app that starts music on several phones at the same instant and keeps
their Bluetooth speakers in sync. Read DESIGN.md before changing sync logic.

## Current state

- Scaffold written without a Mac: **never compiled**. First job is
  `xcodegen generate`, build, and fix compile errors without changing behavior.
- Working toward milestone M1 (two phones, local file, built-in speakers). See DESIGN.md → Milestones.

## Commands

- Generate project: `xcodegen generate` (never hand-edit the .xcodeproj; edit project.yml)
- Build: `xcodebuild -scheme SyncSpeaker -destination 'generic/platform=iOS' build`
- Unit tests: `xcodebuild test -scheme SyncSpeaker -destination 'platform=iOS Simulator,name=iPhone 16'`
- Algorithm sims: `python3 sim/simulate.py` (needs numpy)

## Conventions

- All times are `Int64` nanoseconds on `HostClock` (mach_absolute_time) unless
  the name says otherwise (`...Millis`, `...Seconds`, positions in seconds as `Double`).
  Local vs leader clock is always explicit in names (`localNanos`, `leaderTime`).
- Error sign: positive error = this speaker is **ahead** of the timeline.
- Calibration residual: positive = speaker was late, so it gets started earlier.
- Swift 5 language mode, minimal concurrency checking. UI-facing classes are `@MainActor`.
- Keep DSP / ClockSync / DriftController / Calibrator free of UIKit and AVFoundation
  so they stay unit-testable, and keep `sim/simulate.py` in step with them when
  changing an algorithm.

## Things that are easy to break

- Audio session must use `.allowBluetoothA2DP`, never `.allowBluetooth` (HFP
  ruins speaker audio when the mic is on). Mode `.measurement` keeps voice
  processing from shifting recorded timing.
- Clock-sync pings are answered inside `PeerSession` on the delivery queue,
  not on the main thread, so main-thread work doesn't add jitter to t2/t3.
- The chirp node holds one scheduled start at a time; chirps are handed over
  ~250 ms before they're due (`playChirpWhenDue`).
- Spotify: SDK v5.0.1 (SPM package `SpotifyiOS`) is optional and gated by
  `#if canImport(SpotifyiOS)`; a stub keeps the app building without it.
- Spotify-style sync lives in `RemoteSyncPlayer` over a `RemoteBackend`.
  `SimulatedSpotifyBackend` must stay limited to what Spotify allows
  (resume/pause/seek, random delays, coarse position reports), or testing
  with it stops meaning anything.
- Echo-monitor shifts are always immediate jumps; a gradual trim would still be
  under way at the next check and get corrected twice.
