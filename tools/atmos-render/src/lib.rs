//! Shared DSP for the Spatialize engine: filters, ambisonic encoding, room simulation and
//! dynamics. Everything runs at 48 kHz on interleaved f32 frames.

use std::f32::consts::PI;
use std::io::{self, Read, Write};

pub const SR: f32 = 48000.0;
/// Channels of a 7.1.4 frame, Apple order: L R C LFE Ls Rs Lrs Rrs Ltf Rtf Ltr Rtr.
pub const CH714: usize = 12;
pub const HOA: usize = 16;
pub const LFE: usize = 3;

// ---------- filters ----------

#[derive(Clone)]
pub struct Biquad {
    b: [f32; 3],
    a: [f32; 2],
    z: [f32; 2],
}

impl Biquad {
    /// RBJ cookbook peaking EQ.
    pub fn peaking(freq: f32, q: f32, gain_db: f32) -> Self {
        let a = 10f32.powf(gain_db / 40.0);
        let w = 2.0 * PI * freq / SR;
        let alpha = w.sin() / (2.0 * q);
        let a0 = 1.0 + alpha / a;
        Biquad {
            b: [(1.0 + alpha * a) / a0, -2.0 * w.cos() / a0, (1.0 - alpha * a) / a0],
            a: [-2.0 * w.cos() / a0, (1.0 - alpha / a) / a0],
            z: [0.0; 2],
        }
    }
    /// RBJ cookbook shelf (slope 1): `high` lifts or cuts above `freq`, otherwise below it.
    pub fn shelf(freq: f32, gain_db: f32, high: bool) -> Self {
        let a = 10f32.powf(gain_db / 40.0);
        let w = 2.0 * PI * freq / SR;
        let (c, sn) = (w.cos(), w.sin());
        let alpha = sn / 2.0 * 2f32.sqrt();
        let k = 2.0 * a.sqrt() * alpha;
        let (b, a2) = if high {
            ([a * ((a + 1.0) + (a - 1.0) * c + k), -2.0 * a * ((a - 1.0) + (a + 1.0) * c), a * ((a + 1.0) + (a - 1.0) * c - k)],
             [(a + 1.0) - (a - 1.0) * c + k, 2.0 * ((a - 1.0) - (a + 1.0) * c), (a + 1.0) - (a - 1.0) * c - k])
        } else {
            ([a * ((a + 1.0) - (a - 1.0) * c + k), 2.0 * a * ((a - 1.0) - (a + 1.0) * c), a * ((a + 1.0) - (a - 1.0) * c - k)],
             [(a + 1.0) + (a - 1.0) * c + k, -2.0 * ((a - 1.0) + (a + 1.0) * c), (a + 1.0) + (a - 1.0) * c - k])
        };
        let a0 = a2[0];
        Biquad { b: [b[0] / a0, b[1] / a0, b[2] / a0], a: [a2[1] / a0, a2[2] / a0], z: [0.0; 2] }
    }
    /// The overhead cue used everywhere: a broad lift around 7.5 kHz.
    pub fn height_cue(gain_db: f32) -> Self {
        Self::peaking(7500.0, 1.0, gain_db)
    }
    #[inline]
    pub fn run(&mut self, x: f32) -> f32 {
        let y = self.b[0] * x + self.z[0];
        self.z[0] = self.b[1] * x - self.a[0] * y + self.z[1];
        self.z[1] = self.b[2] * x - self.a[1] * y;
        y
    }
}

/// Ten-band headphone EQ (31 Hz … 16 kHz, octave spacing), the same curve on every channel.
/// The outer bands are shelves, the rest peaking filters.
pub const EQ_BANDS: [f32; 10] = [31.0, 62.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];

pub struct HeadphoneEq {
    stages: Vec<Vec<Biquad>>, // per channel, only the bands that aren't 0 dB
}

impl HeadphoneEq {
    /// `gains`: "g1,g2,…,g10" in dB.
    pub fn parse(spec: &str, channels: usize) -> Option<Self> {
        let g: Vec<f32> = spec.split(',').map(|v| v.trim().parse().ok()).collect::<Option<_>>()?;
        if g.len() != EQ_BANDS.len() {
            return None;
        }
        let chain: Vec<Biquad> = g.iter().enumerate().filter(|(_, d)| d.abs() > 0.01).map(|(i, &d)| match i {
            0 => Biquad::shelf(44.0, d, false),
            9 => Biquad::shelf(11300.0, d, true),
            _ => Biquad::peaking(EQ_BANDS[i], 1.41, d),
        }).collect();
        Some(HeadphoneEq { stages: vec![chain; channels] })
    }
    pub fn is_flat(&self) -> bool {
        self.stages.first().map_or(true, |c| c.is_empty())
    }
    #[inline]
    pub fn run(&mut self, ch: usize, x: f32) -> f32 {
        let mut y = x;
        for b in self.stages[ch].iter_mut() {
            y = b.run(y);
        }
        y
    }
}

/// One-pole low-pass, used to darken reflections.
#[derive(Clone, Copy, Default)]
struct OnePole {
    a: f32,
    z: f32,
}
impl OnePole {
    fn new(cutoff: f32) -> Self {
        OnePole { a: (-2.0 * PI * cutoff / SR).exp(), z: 0.0 }
    }
    #[inline]
    fn run(&mut self, x: f32) -> f32 {
        self.z = x + self.a * (self.z - x);
        self.z
    }
}

// ---------- ambisonics ----------

/// Real spherical harmonics up to 3rd order, ACN channel order, SN3D normalisation.
/// Azimuth is counter-clockwise from the front (left = +90°), elevation up from the horizon.
pub fn sh3(az_deg: f32, el_deg: f32) -> [f32; HOA] {
    let (t, p) = (az_deg.to_radians(), el_deg.to_radians());
    let (st, ct, sp, cp) = (t.sin(), t.cos(), p.sin(), p.cos());
    let (s3, s15, s38, s58) = (3f32.sqrt(), 15f32.sqrt(), (3.0f32 / 8.0).sqrt(), (5.0f32 / 8.0).sqrt());
    [
        1.0,
        st * cp,
        sp,
        ct * cp,
        s3 / 2.0 * (2.0 * t).sin() * cp * cp,
        s3 / 2.0 * st * (2.0 * p).sin(),
        0.5 * (3.0 * sp * sp - 1.0),
        s3 / 2.0 * ct * (2.0 * p).sin(),
        s3 / 2.0 * (2.0 * t).cos() * cp * cp,
        s58 * (3.0 * t).sin() * cp * cp * cp,
        s15 / 2.0 * (2.0 * t).sin() * sp * cp * cp,
        s38 * st * cp * (5.0 * sp * sp - 1.0),
        0.5 * sp * (5.0 * sp * sp - 3.0),
        s38 * ct * cp * (5.0 * sp * sp - 1.0),
        s15 / 2.0 * (2.0 * t).cos() * sp * cp * cp,
        s58 * (3.0 * t).cos() * cp * cp * cp,
    ]
}

/// Speaker directions (azimuth, elevation) in Apple 7.1.4 order with the top row at `top_el`.
pub fn standard_dirs(top_el: f32) -> [(f32, f32); CH714] {
    [
        (30.0, 0.0), (-30.0, 0.0), (0.0, 0.0), (0.0, 0.0), (90.0, 0.0), (-90.0, 0.0),
        (150.0, 0.0), (-150.0, 0.0), (45.0, top_el), (-45.0, top_el), (135.0, top_el), (-135.0, top_el),
    ]
}

/// Parses 12 "azimuth:elevation" pairs (Apple 7.1.4 order, comma separated).
pub fn parse_layout(s: &str) -> Option<[(f32, f32); CH714]> {
    let v: Vec<(f32, f32)> = s
        .split(',')
        .filter_map(|p| {
            let (a, e) = p.split_once(':')?;
            Some((a.trim().parse().ok()?, e.trim().parse().ok()?))
        })
        .collect();
    v.try_into().ok()
}

/// Per-speaker HOA encoding gains; LFE has no direction and feeds W only.
pub fn speaker_encoders(dirs: &[(f32, f32); CH714]) -> [[f32; HOA]; CH714] {
    std::array::from_fn(|c| {
        if c == LFE {
            let mut w = [0.0; HOA];
            w[0] = 1.0;
            w
        } else {
            sh3(dirs[c].0, dirs[c].1)
        }
    })
}

pub fn unit(az: f32, el: f32) -> [f32; 3] {
    let (a, e) = (az.to_radians(), el.to_radians());
    [e.cos() * a.cos(), e.cos() * a.sin(), e.sin()]
}

// ---------- room ----------

/// Small room simulation that makes headphone sound feel outside the head: early reflections
/// arriving from the other speaker directions plus a decorrelated diffuse tail, both darker
/// than the direct sound. Input and output are 7.1.4 frames; the output is wet only.
pub struct Room {
    wet: f32,
    // early reflections: per output (speaker), taps of (input channel, delay, gain)
    taps: Vec<Vec<(usize, usize, f32)>>,
    er_lp: [OnePole; CH714],
    hist: Vec<[f32; CH714]>,
    hist_pos: usize,
    // late tail: 8-line feedback delay network
    lines: Vec<Vec<f32>>,
    line_pos: Vec<usize>,
    line_gain: Vec<f32>,
    line_lp: Vec<OnePole>,
    pre: Vec<f32>,
    pre_pos: usize,
    out_mix: [[f32; 8]; CH714],
    in_lp: OnePole,
}

impl Room {
    /// `size` 0..1 (small room .. cinema), `rt60` seconds, `wet_db` level of the room.
    pub fn new(size: f32, rt60: f32, wet_db: f32) -> Self {
        let size = size.clamp(0.1, 1.0);
        // deterministic pseudo-random numbers so every run sounds the same
        let mut seed: u32 = 0x2545_f491;
        let mut rnd = move || {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            (seed as f32 / u32::MAX as f32).clamp(0.0, 1.0)
        };
        let ear: [usize; 11] = [0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11];
        let mut taps = vec![Vec::new(); CH714];
        let max_er_ms = 6.0 + 30.0 * size;
        for &o in &ear {
            for k in 0..6 {
                let src = ear[(rnd() * 11.0) as usize % 11];
                let ms = 3.0 + (max_er_ms - 3.0) * (k as f32 + rnd()) / 6.0;
                let gain = 0.55 * (1.0 - ms / (max_er_ms * 1.6)) * if rnd() > 0.5 { 1.0 } else { -1.0 };
                taps[o].push((src, (ms * SR / 1000.0) as usize, gain / 6f32.sqrt()));
            }
        }
        let hist_len = (max_er_ms * SR / 1000.0) as usize + 2;

        let base_ms = [29.7, 37.1, 41.1, 43.7, 53.3, 59.9, 67.3, 73.1];
        let mut lines = Vec::new();
        let mut line_gain = Vec::new();
        for ms in base_ms {
            let len = ((ms * (0.45 + 0.8 * size)) * SR / 1000.0) as usize;
            lines.push(vec![0.0; len]);
            // per-pass gain for the requested decay: -60 dB after rt60 seconds
            line_gain.push(10f32.powf(-3.0 * len as f32 / (rt60.max(0.1) * SR)));
        }
        let mut out_mix = [[0.0f32; 8]; CH714];
        for &o in &ear {
            for j in 0..8 {
                out_mix[o][j] = if rnd() > 0.5 { 1.0 } else { -1.0 } / 8f32.sqrt();
            }
        }
        Room {
            wet: 10f32.powf(wet_db / 20.0),
            taps,
            er_lp: [OnePole::new(6000.0); CH714],
            hist: vec![[0.0; CH714]; hist_len],
            hist_pos: 0,
            line_pos: vec![0; 8],
            line_lp: (0..8).map(|_| OnePole::new(5000.0 - 2500.0 * size)).collect(),
            lines,
            line_gain,
            pre: vec![0.0; ((8.0 + 20.0 * size) * SR / 1000.0) as usize],
            pre_pos: 0,
            out_mix,
            in_lp: OnePole::new(8000.0),
        }
    }

    /// Presets: "small", "living", "cinema", optionally ":AMOUNT" (0..2, default 1).
    pub fn preset(spec: &str) -> Option<Self> {
        let (name, amount) = match spec.split_once(':') {
            Some((n, a)) => (n, a.parse().unwrap_or(1.0f32)),
            None => (spec, 1.0),
        };
        let trim = 20.0 * amount.clamp(0.05, 2.0).log10();
        match name {
            "off" | "none" | "" => None,
            "small" => Some(Room::new(0.3, 0.30, -17.0 + trim)),
            "living" => Some(Room::new(0.55, 0.45, -14.0 + trim)),
            "cinema" => Some(Room::new(1.0, 0.85, -12.0 + trim)),
            _ => None,
        }
    }

    /// Returns the room's contribution (wet only) for one 7.1.4 frame.
    pub fn process(&mut self, x: &[f32; CH714]) -> [f32; CH714] {
        let n = self.hist.len();
        self.hist[self.hist_pos] = *x;
        let mut wet = [0.0f32; CH714];
        for o in 0..CH714 {
            let mut acc = 0.0;
            for &(src, d, g) in &self.taps[o] {
                acc += g * self.hist[(self.hist_pos + n - d) % n][src];
            }
            wet[o] = self.er_lp[o].run(acc);
        }
        self.hist_pos = (self.hist_pos + 1) % n;

        // late tail from the mono sum (no LFE), after a short pre-delay
        let mut mono = 0.0;
        for (c, &v) in x.iter().enumerate() {
            if c != LFE {
                mono += v;
            }
        }
        let pl = self.pre.len();
        let input = self.in_lp.run(self.pre[self.pre_pos]) * 0.3;
        self.pre[self.pre_pos] = mono;
        self.pre_pos = (self.pre_pos + 1) % pl;

        let mut outs = [0.0f32; 8];
        for j in 0..8 {
            outs[j] = self.lines[j][self.line_pos[j]];
        }
        // Householder feedback: y = x - 2/N * sum(x)
        let s: f32 = outs.iter().sum::<f32>() * (2.0 / 8.0);
        for j in 0..8 {
            let fb = self.line_lp[j].run((outs[j] - s) * self.line_gain[j]);
            let len = self.lines[j].len();
            self.lines[j][self.line_pos[j]] = input + fb;
            self.line_pos[j] = (self.line_pos[j] + 1) % len;
        }
        for o in 0..CH714 {
            let mut acc = 0.0;
            for j in 0..8 {
                acc += self.out_mix[o][j] * outs[j];
            }
            wet[o] += acc;
        }
        for o in 0..CH714 {
            wet[o] *= self.wet;
        }
        wet
    }
}

// ---------- dynamics ----------

/// Static gain, optional night-mode compression and a look-ahead peak limiter, with one gain
/// shared by every channel so the image never shifts. The detector listens to the 7.1.4 feed;
/// the same gain is applied to any parallel stream (e.g. the ambisonic version of it).
/// The look-ahead delays the audio by `latency()` frames; callers trim that much from the start.
pub struct Dynamics {
    gain: f32,
    night: bool,
    limit: bool,
    env: f32,
    comp_gain: f32,
    look: usize,
    peaks: Vec<f32>,
    pos: usize,
    lim_gain: f32,
}

impl Dynamics {
    pub fn new(gain_db: f32, night: bool, limit: bool) -> Self {
        let look = if limit { 96 } else { 0 }; // 2 ms
        Dynamics {
            gain: 10f32.powf(gain_db / 20.0),
            night,
            limit,
            env: 0.0,
            comp_gain: 1.0,
            look,
            peaks: vec![0.0; look + 1],
            pos: 0,
            lim_gain: 1.0,
        }
    }
    pub fn active(&self) -> bool {
        self.gain != 1.0 || self.night || self.limit
    }
    pub fn latency(&self) -> usize {
        self.look
    }

    /// Feeds one detector frame (the 7.1.4 feed, pre-gain) and returns the gain to apply to the
    /// frame that left the look-ahead delay (i.e. `latency()` frames ago).
    pub fn gain_for(&mut self, x: &[f32; CH714]) -> f32 {
        let mut g = self.gain;
        if self.night {
            // RMS of the summed power of the speaker feeds, 10 ms attack / 300 ms release
            let mut p = 0.0;
            for (c, &v) in x.iter().enumerate() {
                if c != LFE {
                    p += v * v;
                }
            }
            let (att, rel) = ((-1.0 / (0.010 * SR)).exp(), (-1.0 / (0.300 * SR)).exp());
            let k = if p > self.env { att } else { rel };
            self.env = p + k * (self.env - p);
            let lvl = 10.0 * self.env.max(1e-12).log10();
            // 3:1 above -30 dB, 6 dB make-up so quiet dialogue comes up
            let thr = -30.0;
            let over = (lvl - thr).max(0.0);
            let target = 10f32.powf((-over * (1.0 - 1.0 / 3.0) + 6.0) / 20.0);
            self.comp_gain = target + (if target < self.comp_gain { att } else { rel }) * (self.comp_gain - target);
            g *= self.comp_gain;
        }
        if self.limit {
            // peak of the incoming frame after the gain so far
            let mut pk = 0.0f32;
            for &v in x.iter() {
                pk = pk.max((v * g).abs());
            }
            self.peaks[self.pos] = pk;
            self.pos = (self.pos + 1) % self.peaks.len();
            let window = self.peaks.iter().fold(0.0f32, |a, &b| a.max(b));
            let ceiling = 0.891; // -1 dBFS
            let need = if window > ceiling { ceiling / window } else { 1.0 };
            // instant attack inside the look-ahead window, 150 ms release
            let rel = (-1.0 / (0.150 * SR)).exp();
            self.lim_gain = if need < self.lim_gain { need } else { need + rel * (self.lim_gain - need) };
            g *= self.lim_gain;
        }
        g
    }
}

/// Fixed delay line for whole frames, used to line audio up with the limiter's look-ahead.
pub struct FrameDelay<const N: usize> {
    buf: Vec<[f32; N]>,
    pos: usize,
}
impl<const N: usize> FrameDelay<N> {
    pub fn new(len: usize) -> Self {
        FrameDelay { buf: vec![[0.0; N]; len], pos: 0 }
    }
    #[inline]
    pub fn push(&mut self, x: [f32; N]) -> [f32; N] {
        if self.buf.is_empty() {
            return x;
        }
        let out = self.buf[self.pos];
        self.buf[self.pos] = x;
        self.pos = (self.pos + 1) % self.buf.len();
        out
    }
}

// ---------- I/O ----------

/// Reads whole frames of `ch` f32le channels; returns the number of frames (0 at the end).
pub fn read_frames(r: &mut impl Read, buf: &mut Vec<u8>, out: &mut Vec<f32>, ch: usize, frames: usize) -> usize {
    buf.resize(frames * ch * 4, 0);
    let mut got = 0;
    while got < buf.len() {
        match r.read(&mut buf[got..]) {
            Ok(0) => break,
            Ok(n) => got += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => panic!("read failed: {e}"),
        }
    }
    let n = got / (ch * 4);
    out.clear();
    out.extend(buf[..n * ch * 4].chunks_exact(4).map(|b| f32::from_le_bytes(b.try_into().unwrap())));
    n
}

pub fn write_f32(w: &mut impl Write, v: &[f32], scratch: &mut Vec<u8>) -> io::Result<()> {
    scratch.clear();
    for x in v {
        scratch.extend_from_slice(&x.to_le_bytes());
    }
    w.write_all(scratch)
}
