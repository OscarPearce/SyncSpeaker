# SyncSpeaker — design

Play the same music on several iPhones, each connected to its own Bluetooth
speaker, and keep the speakers in sync to within ~30 ms at the listener's position.

## Goals and non-goals

**Goals**
- One phone (the *leader*) picks a track and presses play; every other phone
  (the *followers*) starts the same track at the same instant.
- Measure each phone's real speaker delay (phone → Bluetooth → speaker → air)
  instead of trusting what the OS reports, and compensate for it.
- Keep the speakers in sync for the whole song, not just at the start.
- Two playback sources behind one interface:
  - **Local engine** — audio files we decode and play ourselves. Sample-accurate
    scheduling and inaudible drift correction. This is the "reliably under 30 ms" path.
  - **Spotify** — each phone's own Spotify app, controlled through the Spotify
    iOS SDK (App Remote). Best-effort sync; limited by how consistently Spotify
    responds to play/resume/seek.

**Non-goals (for now)**
- Streaming audio from one phone to the others. Spotify audio can't be
  redistributed, and for local files every phone having a copy is simpler and
  keeps the network out of the audio path.
- Android. The sync protocol is platform-neutral, so an Android client can be
  added later.
- Internet play. Phones are expected to be on the same Wi-Fi or near each other.

## Constraints that shape the design

| Constraint | Consequence |
|---|---|
| Spotify audio is DRM'd; we can only send play/pause/seek to the Spotify app | Spotify sync is done by *timing commands*, not by controlling audio samples |
| Spotify Developer Mode: every user needs Premium and must be added by hand to the app's allowlist in the Spotify Developer Dashboard | Spotify mode is for you and a few friends unless the app gets extended quota |
| The Spotify app must be installed, and App Remote connections drop if the Spotify app is killed | The app must reconnect gracefully and show connection state clearly |
| A2DP delay reports from speakers are estimates and are only partly exposed by iOS (`AVAudioSession.outputLatency`) | We measure delay acoustically with a microphone |
| Recording while a Bluetooth speaker is connected can flip the speaker into hands-free (HFP) mode, which kills audio quality | Audio session must use `.allowBluetoothA2DP` and **never** `.allowBluetooth` (that option means HFP) |
| Voice processing (AGC, echo cancellation) shifts and smears timing | Use audio session mode `.measurement` while calibrating |
| Sound travels ~0.34 m (≈1.1 ft) per ms | Sync is only exact at one spot; we calibrate *at the listener's position* |

## Architecture

```
┌──────────────────────── each iPhone ─────────────────────────┐
│                                                              │
│  SwiftUI views ──► SessionCoordinator (leader/follower logic)│
│                       │          │            │              │
│               PeerSession   ClockSync    Calibrator          │
│        (MultipeerConnectivity) (NTP-style)  (chirps + mic)   │
│                       │                       │              │
│                       ▼                       ▼              │
│                 SyncPlayer protocol ◄── DriftController      │
│                 ├─ LocalEnginePlayer (AVAudioEngine)         │
│                 └─ SpotifyPlayer (SPTAppRemote)              │
│                                                              │
└──────────────────────────────────────────────────────────────┘
          ▲  peer-to-peer messages (Wi-Fi / Bluetooth LE)  ▲
          └──────────── other phones in the session ───────┘
```

### Networking: MultipeerConnectivity

No server. Phones discover each other with Bonjour (service type `syncspk`) and
exchange small `Codable` messages encoded as JSON:

- Reliable channel: session control (track load, start, pause, calibration plan,
  results).
- Unreliable channel: clock-sync pings, so a lost packet is just a dropped
  sample rather than a retransmission that inflates round-trip time.

The leader is the clock reference and the source of truth for the timeline.

### Shared clock (`ClockSync`)

Every device reads the same local clock: `mach_absolute_time()` converted to
nanoseconds (`HostClock`). This is also the clock Core Audio uses for
`AVAudioTime(hostTime:)`, so a shared timestamp converts directly into a
playback start time with no extra clock hops.

Followers estimate `leaderTime = localTime + offset` with an NTP-style exchange:

```
follower t1 ──ping──► leader t2
follower t4 ◄──pong── leader t3
offset = ((t2 - t1) + (t3 - t4)) / 2      rtt = (t4 - t1) - (t3 - t2)
```

Wi-Fi delays are lopsided and spiky, so a single exchange can be off by tens
of milliseconds. Two fixes:

1. **Min-RTT filtering.** Send ~10 pings/second, keep a sliding window, and
   trust only samples whose RTT is within a small margin of the window's minimum.
   Low-RTT samples are the ones where neither direction got queued, so their
   offset estimate is accurate.
2. **Skew tracking.** Two crystals drift by up to ~±20 ppm (≈1.2 ms per minute).
   Fit `offset(t) = a + b·t` by least squares over the good samples, so the
   estimate stays correct between updates.

Target accuracy: ≤2 ms. `sim/simulate.py` checks this against a jittery,
asymmetric network model.

### Timeline

The leader defines a timeline: "track position `p0` plays at leader time
`T0`". Every device can then compute the expected position at any moment:

```
expectedPosition(now) = p0 + (leaderTime(now) − T0)
```

Starting, seeking and drift correction are all ways of making the real
position match this formula. The leader schedules `T0` about 1.5 s in the
future so every follower has time to receive it and pre-buffer.

### Playback engines (`SyncPlayer`)

```swift
protocol SyncPlayer {
    func prepare(track:at position:) async throws
    func start(atLocalHostTime:position:)
    func pause()
    func currentPosition() -> (position: TimeInterval, atLocalHostTime: UInt64)?
    func correct(error:)               // engine-specific correction
}
```

**LocalEnginePlayer** (`AVAudioEngine`):
- `AVAudioPlayerNode → AVAudioUnitVarispeed → mainMixer`.
- Start: `scheduleSegment` from the start frame, then
  `play(at: AVAudioTime(hostTime: …))`. The host time is the leader start
  time converted to local time, minus `outputLatency + ioBufferDuration`, minus
  this route's calibrated residual delay.
- Position: `playerTime(forNodeTime: lastRenderTime)` gives the frame being
  rendered at a known host time, so the error can be measured on-device
  without any network traffic.
- Drift correction: a PI controller nudges varispeed `rate` within ±0.2%
  (≈3.5 cents of pitch, inaudible). Errors above 80 ms trigger a hard re-seek.

**SpotifyPlayer** (`SPTAppRemote`):
- Prepare: `play(uri)`, then `seek(position)`, then `pause()` a few seconds
  before the start time, so the audio is already buffered.
- Start: call `resume()` at `T0 − measuredResumeLatency − routeDelay`.
  `measuredResumeLatency` is a running average of how long Spotify takes to make
  sound after `resume`. It's learned during calibration and refined over time.
- Position: `playerState.playbackPosition` (integer ms, only reported on state
  changes, so it's coarse). Drift is checked every ~10 s using the acoustic
  echo check below. If the error exceeds 40 ms, the player seeks.

### Calibration (`Calibrator`)

The goal is relative sync at one spot, so one phone acts as the **listener**:
it's held where people will actually be, and its mic hears every speaker.

1. The leader builds a plan: device *i* plays a 150 ms linear chirp
   (1.5–8 kHz) at shared time `T_i = now + 1.5 s + i × 0.6 s`.
2. Each device schedules its chirp through `LocalEnginePlayer`, using exactly
   the same latency compensation it will use for music.
3. The listener records the whole sequence with mode `.measurement`. It stamps
   every mic buffer with its host time, then converts that to shared time.
4. For each slot, a matched filter (FFT cross-correlation with the chirp, plus
   parabolic peak interpolation) finds the arrival time `A_i`. A confidence
   check (peak / median ratio) rejects slots where the chirp wasn't heard.
5. `late_i = A_i − T_i`. Errors that affect all slots equally, like the
   listener's own input latency or acoustic distance to the room centre,
   cancel out, so each device's correction is `late_i − mean(late)`.
6. Each device adds its correction to the residual stored for its current
   audio route (keyed by route port UID, so switching speakers doesn't reuse a
   stale value).

Repeat 3 times and take the median per device. Expected accuracy is ±1–3 ms
per device in a normal room.

**Spotify extra step.** Chirps measure the route but not Spotify's own
pipeline. To calibrate Spotify, use the **echo check**: two speakers play the
same song, and the listener records 4 s. A real cepstrum (`IFFT(log|FFT|²)`)
shows a peak at the lag between them. That lag doesn't say which speaker is
ahead, so nudge one by +10 ms and see whether the lag grows or shrinks. With
more than two devices, do it pairwise against a reference phone while the
others are paused.

### Drift control loop

- **Local engine:** every 0.5 s, `error = actualPosition − expectedPosition`.
  If |error| > 80 ms, re-seek. Otherwise
  `rate = 1 − clamp(Kp·error + Ki·∫error, ±0.002)`.
- **Spotify:** every ~10 s, estimate the error using `playbackPosition` and,
  if available, the echo check. Seek if |error| > 40 ms. Seeks are audible, so
  rate-limit them to one per 20 s.

## Message protocol

```
hello(name, role, engines)            ← announce on connect
ping(id, t1) / pong(id, t1, t2, t3)   ← clock sync (unreliable)
load(track)                           ← leader → all; followers prepare
startAt(leaderTime, position)         ← the timeline
pause(atLeaderTime)
calibrationPlan(listener, slots)      ← leader → all
calibrationResult(corrections)        ← listener → all
status(position, error, rate, ready)  ← follower → leader, ~1 Hz
```

## Expected accuracy budget

| Source | Local engine | Spotify |
|---|---|---|
| Clock sync | 1–2 ms | 1–2 ms |
| Start scheduling | <1 ms (sample-accurate) | 10–60 ms jitter (resume latency) |
| Bluetooth latency after calibration | 2–10 ms (depends on speaker) | 2–10 ms |
| Drift | corrected continuously | grows between seeks |
| **Typical total** | **~5–15 ms** | **~20–80 ms** — measure it |

## Milestones

1. **M1 — Two phones, local file, no Bluetooth.** Peer discovery, clock sync
   with on-screen offset/RTT readout, synchronized start of a bundled file on
   both built-in speakers. *Success: echo-free by ear when phones are side by side.*
2. **M2 — Calibration.** Chirp plan, listener recording, matched filter, residuals
   per route. *Success: the reported correction is stable across repeated runs
   to within ±3 ms.*
3. **M3 — Bluetooth speakers + drift loop.** Varispeed PI controller, route-change
   handling. *Success: still in sync after a full 5-minute song on two different
   speaker brands.*
4. **M4 — Spotify engine.** App Remote auth, pause-then-resume start, resume-latency
   learning, seek-based correction. *Success: measure the real error with the echo check and decide if it's good enough.*
5. **M5 — Echo check for live monitoring**, polish, onboarding.

## Open questions to answer with M1–M4 measurements

- How consistent is Spotify's `resume()`-to-sound delay on one phone? If the
  standard deviation is under ~15 ms, Spotify mode can hit 30 ms.
- Do common Bluetooth speakers keep constant latency, or do they re-buffer
  mid-song? (The echo check during playback will show this.)
- Does MultipeerConnectivity over Wi-Fi give low enough RTT jitter, or should
  clock pings move to raw UDP via Network.framework?
