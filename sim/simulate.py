"""
Offline checks for SyncSpeaker's sync algorithms.

Each function mirrors one in the Swift app:
  ClockSync          -> SyncSpeaker/Core/ClockSync.swift
  chirp / detect     -> SyncSpeaker/DSP/DSP.swift  (DSP.chirp, DSP.detect)
  echo_lag           -> SyncSpeaker/DSP/DSP.swift  (DSP.echoLag)
  PIController       -> SyncSpeaker/Audio/DriftController.swift

Run:  python3 sim/simulate.py
Needs numpy. Exits non-zero if any check misses its target.
"""
import sys
import numpy as np

rng = np.random.default_rng(7)
FAILURES = []


def check(name, ok, detail):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}: {detail}")
    if not ok:
        FAILURES.append(name)


# ---------------------------------------------------------------- clock sync

class ClockSync:
    def __init__(self, window=80, margin_ns=2e6, min_span_ns=3e9, max_ppm=200):
        self.window, self.margin, self.min_span, self.max_ppm = window, margin_ns, min_span_ns, max_ppm
        self.samples = []
        self.ref, self.intercept, self.skew = 0, 0.0, 0.0

    def add(self, t1, t2, t3, t4):
        rtt = (t4 - t1) - (t3 - t2)
        if rtt < 0:
            return
        self.samples.append((t1 + (t4 - t1) / 2, ((t2 - t1) + (t3 - t4)) / 2, rtt))
        self.samples = self.samples[-self.window:]
        min_rtt = min(s[2] for s in self.samples)
        good = [s for s in self.samples if s[2] <= min_rtt + self.margin]
        self.ref = good[-1][0]
        xs = np.array([s[0] - self.ref for s in good])
        ys = np.array([s[1] for s in good])
        span = max(s[0] for s in good) - min(s[0] for s in good)
        if len(good) >= 3 and span >= self.min_span:
            mx, my = xs.mean(), ys.mean()
            sxx = ((xs - mx) ** 2).sum()
            b = ((xs - mx) * (ys - my)).sum() / sxx if sxx > 0 else 0
            b = float(np.clip(b, -self.max_ppm * 1e-6, self.max_ppm * 1e-6))
            self.skew, self.intercept = b, my - b * mx
        else:
            self.skew, self.intercept = 0.0, float(np.sort(ys)[len(ys) // 2])

    def leader_time(self, local):
        return local + self.intercept + self.skew * (local - self.ref)


def sim_clock_sync(seconds=60, skew_ppm=35.0, offset_s=12.345):
    """Follower clock = leader clock * (1 + skew) + offset.
    Network: 4 ms base each way, plus heavy-tailed queueing that is
    different in each direction (this is what breaks naive NTP)."""
    cs = ClockSync()
    errs = []
    skew = skew_ppm * 1e-6
    # local(t) = t*(1+skew) - offset ; leader clock is true time t
    to_local = lambda t: t * (1 + skew) - offset_s * 1e9
    t = 0.0
    while t < seconds * 1e9:
        # always some jitter, often a big queueing spike, and the two directions differ
        up = 4e6 + rng.exponential(1.0e6) + rng.exponential(6e6) * (rng.random() < 0.6)
        down = 5e6 + rng.exponential(1.5e6) + rng.exponential(15e6) * (rng.random() < 0.6)
        proc = rng.uniform(0.05e6, 0.3e6)
        if rng.random() < 0.05:   # packet lost
            t += 100e6
            continue
        t1 = to_local(t)
        t2 = t + up
        t3 = t2 + proc
        t4 = to_local(t3 + down)
        cs.add(t1, t2, t3, t4)
        if t > 10e9:   # measure after warm-up
            probe = t + rng.uniform(0, 100e6)
            errs.append(cs.leader_time(to_local(probe)) - probe)
        t += 100e6     # 10 Hz
    errs = np.abs(np.array(errs)) / 1e6
    p95 = np.percentile(errs, 95)
    check("clock sync", p95 < 2.0,
          f"p95 error {p95:.2f} ms, max {errs.max():.2f} ms (skew {skew_ppm} ppm, asymmetric jitter)")


# ---------------------------------------------------------------- calibration chirp

def chirp(sr, duration=0.15, f0=1500, f1=8000, fade=0.005, amp=0.6):
    n = int(duration * sr)
    t = np.arange(n) / sr
    k = (f1 - f0) / duration
    x = np.sin(2 * np.pi * (f0 * t + 0.5 * k * t * t))
    fn = max(1, int(fade * sr))
    env = np.ones(n)
    i = np.arange(fn)
    env[:fn] = 0.5 - 0.5 * np.cos(np.pi * i / fn)
    env[n - fn:] = (0.5 - 0.5 * np.cos(np.pi * i / fn))[::-1]
    return (amp * x * env).astype(np.float32)


def next_pow2(x):
    n = 1
    while n < x:
        n <<= 1
    return n


def parabolic(y, i):
    if i <= 0 or i >= len(y) - 1:
        return 0.0
    a, b, c = y[i - 1], y[i], y[i + 1]
    d = a - 2 * b + c
    return 0.0 if abs(d) < 1e-12 else float(np.clip(0.5 * (a - c) / d, -0.5, 0.5))


def cross_correlate(signal, template):
    n = next_pow2(len(signal) + len(template))
    S = np.fft.fft(signal, n)
    T = np.fft.fft(template, n)
    r = np.real(np.fft.ifft(S * np.conj(T)))
    return r[: len(signal) - len(template) + 1]


def detect(template, signal):
    mags = np.abs(cross_correlate(signal, template))
    i = int(np.argmax(mags))
    return i + parabolic(mags, i), mags[i] / max(np.median(mags), 1e-12)


def room_impulse(sr, rt60=0.4, direct_gain=1.0):
    """Direct path + exponentially decaying diffuse reverb (starting 3 ms later)."""
    n = int(rt60 * sr)
    t = np.arange(n) / sr
    tail = rng.normal(0, 1, n) * np.exp(-6.9 * t / rt60) * 0.08
    tail[: int(0.003 * sr)] = 0
    h = tail
    h[0] += direct_gain
    return h


def bluetooth_lowpass(x, sr):
    """Crude stand-in for a codec + small speaker: band-limit 150 Hz - 10 kHz."""
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / sr)
    X[(f < 150) | (f > 10000)] *= 0.05
    return np.fft.irfft(X, len(x))


def sim_calibration(trials=200):
    sr = 48000
    tpl = chirp(sr)
    errs, confs = [], []
    for _ in range(trials):
        true_delay = rng.uniform(0.05, 0.35)      # unknown BT + air delay, s
        total = int(1.0 * sr)
        x = np.zeros(total)
        start = int(true_delay * sr)
        frac = true_delay * sr - start
        # fractional-sample delay via FFT phase shift
        sig = np.zeros(total)
        sig[start : start + len(tpl)] = tpl
        S = np.fft.rfft(sig)
        f = np.fft.rfftfreq(total)
        sig = np.fft.irfft(S * np.exp(-2j * np.pi * f * frac), total)
        sig = bluetooth_lowpass(sig, sr)
        sig = np.convolve(sig, room_impulse(sr, rt60=rng.uniform(0.2, 0.8)))[:total]
        gain = rng.uniform(0.02, 0.3)              # distance / volume
        noise = rng.normal(0, 0.03, total)         # room noise / chatter
        x = gain * sig + noise
        est, conf = detect(tpl, x.astype(np.float32))
        errs.append(abs(est / sr - true_delay) * 1000)
        confs.append(conf)
    errs = np.array(errs)
    p95 = np.percentile(errs, 95)
    check("chirp detection", p95 < 1.0,
          f"p95 error {p95:.3f} ms, max {errs.max():.3f} ms, min confidence {min(confs):.1f}")


# ---------------------------------------------------------------- echo check (cepstrum)

def synth_music(sr, seconds, bpm=112):
    """Chords that change every beat + drums + noise. Not real music, but it has
    the troublesome parts: strong pitch periodicity and a steady beat."""
    n = int(sr * seconds)
    t = np.arange(n) / sr
    out = np.zeros(n)
    beat = 60 / bpm
    notes = 110 * 2 ** (rng.integers(0, 24, size=(int(seconds / beat) + 1, 3)) / 12)
    for b in range(int(seconds / beat) + 1):
        s, e = int(b * beat * sr), min(n, int((b + 1) * beat * sr))
        if s >= n:
            break
        tt = t[s:e] - t[s]
        env = np.exp(-tt * 3)
        for f in notes[b]:
            for h in range(1, 6):
                out[s:e] += env * np.sin(2 * np.pi * f * h * tt) / h
        kick_n = min(e - s, int(0.08 * sr))
        out[s : s + kick_n] += 2 * np.exp(-np.arange(kick_n) / (0.02 * sr)) * np.sin(
            2 * np.pi * 60 * np.arange(kick_n) / sr)
        hat = rng.normal(0, 0.3, min(e - s, int(0.03 * sr)))
        mid = s + (e - s) // 2
        out[mid : mid + len(hat)] += hat[: max(0, min(len(hat), n - mid))]
    out += rng.normal(0, 0.05, n)
    return out / np.max(np.abs(out))


def echo_lag(signal, sr, min_lag=0.004, max_lag=0.300, frame=32768):
    hop = frame // 2
    max_n, min_n = int(max_lag * sr), max(1, int(min_lag * sr))
    win = np.hanning(frame)
    avg = np.zeros(max_n + 1)
    frames = 0
    for s in range(0, len(signal) - frame + 1, hop):
        X = np.fft.fft(signal[s : s + frame] * win)
        cep = np.real(np.fft.ifft(np.log(np.abs(X) ** 2 + 1e-10)))
        avg += cep[: max_n + 1]
        frames += 1
    rngv = avg[min_n : max_n + 1]
    i = int(np.argmax(rngv))
    strength = (rngv[i] - rngv.mean()) / max(rngv.std(), 1e-12)
    return (min_n + i + parabolic(rngv, i)) / sr, strength


def sim_echo(trials=40):
    sr = 48000
    errs, strengths, misses = [], [], 0
    for _ in range(trials):
        music = synth_music(sr, 5)
        lag = rng.uniform(0.008, 0.25)
        d = int(lag * sr)
        g_a, g_b = rng.uniform(0.4, 1.0), rng.uniform(0.4, 1.0)
        a = bluetooth_lowpass(music, sr)
        b = bluetooth_lowpass(np.concatenate([np.zeros(d), music[:-d]]), sr)
        mix = np.convolve(g_a * a + g_b * b, room_impulse(sr, rt60=0.4))[: len(music)]
        mix += rng.normal(0, 0.01, len(mix))
        est, strength = echo_lag(mix, sr)
        err = abs(est - d / sr) * 1000
        if err > 2:
            misses += 1
        else:
            errs.append(err)
            strengths.append(strength)
    hit_rate = 1 - misses / trials
    detail = f"found the lag in {hit_rate:.0%} of trials"
    if errs:
        detail += f"; when found, max error {max(errs):.2f} ms, min strength {min(strengths):.1f} sd"
    check("echo check (cepstrum)", hit_rate >= 0.9, detail)


# ---------------------------------------------------------------- drift controller

class PIController:
    """Mirror of DriftController.swift. Error in seconds, returns varispeed rate."""
    def __init__(self, kp=0.2, ki=0.02, max_dev=0.002, reseek=0.080):
        self.kp, self.ki, self.max_dev, self.reseek = kp, ki, max_dev, reseek
        self.integral = 0.0

    def update(self, error, dt):
        if abs(error) > self.reseek:
            self.integral = 0.0
            return None    # caller re-seeks
        self.integral = float(np.clip(self.integral + error * dt, -0.2, 0.2))
        u = self.kp * error + self.ki * self.integral
        return 1.0 - float(np.clip(u, -self.max_dev, self.max_dev))


def sim_drift(minutes=6, hw_ppm=60):
    """Audio hardware clock runs `hw_ppm` fast vs the shared timeline, and the
    position readout has 1 ms of noise. Start 15 ms off."""
    ctl = PIController()
    dt = 0.5
    err, rate = 0.015, 1.0
    worst_after = 0.0
    for step in range(int(minutes * 60 / dt)):
        err += ((1 + hw_ppm * 1e-6) * rate - 1) * dt
        measured = err + rng.normal(0, 0.001)
        r = ctl.update(measured, dt)
        rate = 1.0 if r is None else r
        if r is None:
            err = 0.0
        if step * dt > 30:
            worst_after = max(worst_after, abs(err))
    check("drift controller", worst_after < 0.003,
          f"after 30 s settling, worst error {worst_after * 1000:.2f} ms with {hw_ppm} ppm clock drift")


if __name__ == "__main__":
    sim_clock_sync()
    sim_calibration()
    sim_echo()
    sim_drift()
    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed: {', '.join(FAILURES)}")
        sys.exit(1)
    print("\nAll checks passed.")
