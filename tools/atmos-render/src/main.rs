//! Renders a Dolby Atmos master file set (DAMF: .atmos / .atmos.audio / .atmos.metadata, as
//! written by `truehdd decode --bed-conform`) to 7.1.4 speaker channels.
//!
//! Output: raw interleaved f32 little-endian on stdout, 12 channels, in Apple's
//! kAudioChannelLayoutTag_Atmos_7_1_4 order:
//!   L R C LFE Ls Rs Lrs Rrs Ltf Rtf Ltr Rtr   (Ls/Rs = side surrounds, Lrs/Rrs = rear)
//!
//! With --direct LAYOUT the output is 28 channels: that 7.1.4 feed, then 16 channels of 3rd-order
//! ambisonics (ACN, SN3D) where every object is encoded as a point source at its own direction
//! instead of as a mix of speakers. LAYOUT is 12 az:el pairs (Apple order) that define where the
//! 7.1.4 speakers are, so custom layouts still steer the objects. With --height-eq DB the overhead
//! cue is applied in proportion to each object's elevation.
//!
//! usage: atmos-render INPUT.atmos [--direct LAYOUT [--height-eq DB]] [--dialogue DB] [--lfe DB]

use std::collections::HashMap;
use atmos_render::{Biquad, CH714, HOA, LFE, parse_layout, sh3, speaker_encoders, unit};
use std::f32::consts::FRAC_PI_2;
use std::fs::File;
use std::io::{self, BufRead, BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

const OUT_CH: usize = 12;
/// Coefficients per source: 12 speaker gains, 16 dry ambisonic, 16 ambisonic for the height cue.
const K: usize = CH714 + 2 * HOA;

/// Turns 7.1.4 speaker gains into the full coefficient set.
struct Encoder {
    direct: bool,
    units: [[f32; 3]; CH714],
    enc: [[f32; HOA]; CH714],
}

impl Encoder {
    fn coeffs(&self, g: &[f32; OUT_CH]) -> [f32; K] {
        let mut k = [0.0f32; K];
        k[..OUT_CH].copy_from_slice(g);
        if !self.direct {
            return k;
        }
        // energy-weighted direction of the speakers the panner used
        let (mut v, mut e) = ([0.0f32; 3], 0.0f32);
        for c in 0..CH714 {
            if c == LFE || g[c] == 0.0 {
                continue;
            }
            let w = g[c] * g[c];
            e += w;
            for i in 0..3 {
                v[i] += w * self.units[c][i];
            }
        }
        let mut hoa = [0.0f32; HOA];
        let mut el = 0.0f32;
        if e > 1e-12 {
            let len = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
            // focus: 1 when the gains point one way, 0 when they cancel (a source "in the middle")
            let d = (len / e).clamp(0.0, 1.0);
            let amp = e.sqrt();
            if len > 1e-9 {
                let az = v[1].atan2(v[0]).to_degrees();
                el = (v[2] / len).clamp(-1.0, 1.0).asin().to_degrees();
                let y = sh3(az, el);
                for h in 0..HOA {
                    hoa[h] += d * amp * y[h];
                }
            }
            if d < 1.0 {
                for c in 0..CH714 {
                    if c != LFE && g[c] != 0.0 {
                        for h in 0..HOA {
                            hoa[h] += (1.0 - d) * g[c] * self.enc[c][h];
                        }
                    }
                }
            }
        }
        let w = (el / 45.0).clamp(0.0, 1.0);
        for h in 0..HOA {
            k[OUT_CH + h] = (1.0 - w) * hoa[h];
            k[OUT_CH + HOA + h] = w * hoa[h];
        }
        k[OUT_CH] += g[LFE]; // LFE: omni only
        k
    }
}
const BLOCK: usize = 1024;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

// ---------- DAMF header ----------

fn read_header(path: &Path) -> Result<(PathBuf, PathBuf)> {
    let dir = path.parent().unwrap_or(Path::new("."));
    let text = std::fs::read_to_string(path)?;
    let mut audio = None;
    let mut meta = None;
    for line in text.lines() {
        let t = line.trim();
        if let Some(v) = t.strip_prefix("audio:") {
            audio.get_or_insert(unquote(v.trim()));
        } else if let Some(v) = t.strip_prefix("metadata:") {
            meta.get_or_insert(unquote(v.trim()));
        }
    }
    Ok((
        dir.join(audio.ok_or("no audio: entry in .atmos header")?),
        dir.join(meta.ok_or("no metadata: entry in .atmos header")?),
    ))
}

fn unquote(s: &str) -> String {
    let s = s.trim();
    if s.len() >= 2 && ((s.starts_with('\'') && s.ends_with('\'')) || (s.starts_with('"') && s.ends_with('"'))) {
        s[1..s.len() - 1].replace("''", "'")
    } else {
        s.to_string()
    }
}

// ---------- DAMF metadata events ----------

#[derive(Default, Clone, Debug)]
struct Event {
    id: Option<u32>,
    sample_pos: Option<u64>,
    active: Option<bool>,
    pos: Option<[f32; 3]>,
    gain_db: Option<f32>,
    ramp: Option<u32>,
}

/// Line-oriented reader for the DAMF event list. The file is a YAML list of flat maps, so a
/// full YAML parser is unnecessary and would need the whole (often large) file in memory.
fn read_events(path: &Path) -> Result<Vec<Event>> {
    let reader = BufReader::new(File::open(path)?);
    let mut events = Vec::new();
    let mut cur: Option<Event> = None;
    for line in reader.lines() {
        let line = line?;
        let mut t = line.trim();
        if let Some(rest) = t.strip_prefix("- ") {
            if let Some(e) = cur.take() {
                events.push(e);
            }
            cur = Some(Event::default());
            t = rest.trim();
        }
        let Some(e) = cur.as_mut() else { continue };
        let Some((k, v)) = t.split_once(':') else { continue };
        let v = v.trim();
        match k.trim() {
            "ID" => e.id = v.parse().ok(),
            "samplePos" => e.sample_pos = v.parse().ok().or_else(|| v.parse::<f64>().ok().map(|f| f as u64)),
            "active" => e.active = v.parse().ok(),
            "rampLength" => e.ramp = v.parse().ok(),
            "gain" => {
                e.gain_db = Some(if v.contains("inf") { f32::NEG_INFINITY } else { v.parse().unwrap_or(0.0) })
            }
            "pos" => {
                let nums: Vec<f32> = v
                    .trim_matches(|c| c == '[' || c == ']')
                    .split(',')
                    .filter_map(|n| n.trim().parse().ok())
                    .collect();
                if nums.len() == 3 {
                    e.pos = Some([nums[0], nums[1], nums[2]]);
                }
            }
            _ => {}
        }
    }
    if let Some(e) = cur.take() {
        events.push(e);
    }
    // Events whose ID was elided carry nothing usable.
    events.retain(|e| e.id.is_some() && e.sample_pos.is_some());
    events.sort_by_key(|e| e.sample_pos.unwrap());
    Ok(events)
}

// ---------- CAF reader ----------

struct Caf {
    file: BufReader<File>,
    channels: usize,
    bytes_per_sample: usize,
    float: bool,
    little: bool,
    sample_rate: f64,
    data_end: Option<u64>,
}

impl Caf {
    fn open(path: &Path) -> Result<Self> {
        let mut f = File::open(path)?;
        let mut hdr = [0u8; 8];
        f.read_exact(&mut hdr)?;
        if &hdr[0..4] != b"caff" {
            return Err("audio file is not CAF".into());
        }
        let mut desc = None;
        loop {
            let mut ch = [0u8; 12];
            f.read_exact(&mut ch)?;
            let kind = [ch[0], ch[1], ch[2], ch[3]];
            let size = i64::from_be_bytes(ch[4..12].try_into().unwrap());
            match &kind {
                b"desc" => {
                    let mut d = vec![0u8; size as usize];
                    f.read_exact(&mut d)?;
                    let be32 = |o: usize| u32::from_be_bytes(d[o..o + 4].try_into().unwrap());
                    let sr = f64::from_be_bytes(d[0..8].try_into().unwrap());
                    if &d[8..12] != b"lpcm" {
                        return Err("CAF audio is not linear PCM".into());
                    }
                    let flags = be32(12);
                    let channels = be32(24) as usize;
                    let bits = be32(28) as usize;
                    desc = Some((sr, flags, channels, bits));
                }
                b"data" => {
                    let (sr, flags, channels, bits) = desc.ok_or("CAF data before desc")?;
                    f.seek(SeekFrom::Current(4))?; // edit count
                    let start = f.stream_position()?;
                    let data_end = if size < 0 { None } else { Some(start + size as u64 - 4) };
                    return Ok(Caf {
                        file: BufReader::with_capacity(1 << 20, f),
                        channels,
                        bytes_per_sample: bits / 8,
                        float: flags & 1 != 0,
                        little: flags & 2 != 0,
                        sample_rate: sr,
                        data_end,
                    });
                }
                _ => {
                    f.seek(SeekFrom::Current(size))?;
                }
            }
        }
    }

    /// Reads up to `frames` frames as f32 into `out` (interleaved). Returns frames read.
    fn read(&mut self, out: &mut Vec<f32>, frames: usize, raw: &mut Vec<u8>) -> Result<usize> {
        let frame_bytes = self.channels * self.bytes_per_sample;
        let mut want = frames * frame_bytes;
        if let Some(end) = self.data_end {
            let pos = self.file.stream_position()?;
            want = want.min(end.saturating_sub(pos) as usize);
        }
        raw.resize(want, 0);
        let mut got = 0;
        while got < want {
            let n = self.file.read(&mut raw[got..])?;
            if n == 0 {
                break;
            }
            got += n;
        }
        let nframes = got / frame_bytes;
        out.clear();
        let bps = self.bytes_per_sample;
        for s in raw[..nframes * frame_bytes].chunks_exact(bps) {
            let v = match (self.float, bps, self.little) {
                (true, 4, true) => f32::from_le_bytes(s.try_into().unwrap()),
                (true, 4, false) => f32::from_be_bytes(s.try_into().unwrap()),
                (false, 2, true) => i16::from_le_bytes(s.try_into().unwrap()) as f32 / 32768.0,
                (false, 2, false) => i16::from_be_bytes(s.try_into().unwrap()) as f32 / 32768.0,
                (false, 3, true) => (i32::from_le_bytes([0, s[0], s[1], s[2]]) >> 8) as f32 / 8388608.0,
                (false, 3, false) => (i32::from_be_bytes([s[0], s[1], s[2], 0]) >> 8) as f32 / 8388608.0,
                (false, 4, true) => i32::from_le_bytes(s.try_into().unwrap()) as f32 / 2147483648.0,
                (false, 4, false) => i32::from_be_bytes(s.try_into().unwrap()) as f32 / 2147483648.0,
                _ => return Err(format!("unsupported CAF sample format ({bps} bytes, float={})", self.float).into()),
            };
            out.push(v);
        }
        Ok(nframes)
    }
}

// ---------- panner ----------

/// Balance-style panner for a cube room, matching the DAMF coordinate system:
/// x -1 (left) .. 1 (right), y -1 (back) .. 1 (front), z 0 (ear level) .. 1 (ceiling).
/// Every stage is equal-power, so an object's loudness doesn't change as it moves.
fn pan(pos: [f32; 3]) -> [f32; OUT_CH] {
    let x = pos[0].clamp(-1.0, 1.0);
    let y = pos[1].clamp(-1.0, 1.0);
    let z = pos[2].clamp(0.0, 1.0);
    let mut g = [0.0f32; OUT_CH];

    let ear = (z * FRAC_PI_2).cos();
    let top = (z * FRAC_PI_2).sin();

    // pair pan across x for a two-speaker row
    let pair = |x: f32| {
        let u = (x + 1.0) * 0.5 * FRAC_PI_2;
        (u.cos(), u.sin())
    };

    if ear > 1e-6 {
        if y >= 0.0 {
            // between the side row (y=0) and the front row (y=1)
            let t = y * FRAC_PI_2;
            let (front, side) = (t.sin() * ear, t.cos() * ear);
            // front row has a centre speaker: L(-1) C(0) R(1)
            if x <= 0.0 {
                let u = (x + 1.0) * FRAC_PI_2;
                g[0] += front * u.cos();
                g[2] += front * u.sin();
            } else {
                let u = x * FRAC_PI_2;
                g[2] += front * u.cos();
                g[1] += front * u.sin();
            }
            let (l, r) = pair(x);
            g[4] += side * l;
            g[5] += side * r;
        } else {
            // between the side row (y=0) and the rear row (y=-1)
            let t = -y * FRAC_PI_2;
            let (rear, side) = (t.sin() * ear, t.cos() * ear);
            let (l, r) = pair(x);
            g[4] += side * l;
            g[5] += side * r;
            g[6] += rear * l;
            g[7] += rear * r;
        }
    }
    if top > 1e-6 {
        let t = (y + 1.0) * 0.5 * FRAC_PI_2;
        let (front, rear) = (t.sin() * top, t.cos() * top);
        let (l, r) = pair(x);
        g[8] += front * l;
        g[9] += front * r;
        g[10] += rear * l;
        g[11] += rear * r;
    }
    g
}

/// Gains for a bed channel (bed-conformed 7.1.2 IDs 0..9).
fn bed_gains(id: u32) -> [f32; OUT_CH] {
    let mut g = [0.0f32; OUT_CH];
    match id {
        0..=7 => g[id as usize] = 1.0, // L R C LFE Lss Rss Lrs Rrs line up with the output
        8 => {
            g[8] = std::f32::consts::FRAC_1_SQRT_2; // Lts → Ltf + Ltr
            g[10] = std::f32::consts::FRAC_1_SQRT_2;
        }
        9 => {
            g[9] = std::f32::consts::FRAC_1_SQRT_2; // Rts → Rtf + Rtr
            g[11] = std::f32::consts::FRAC_1_SQRT_2;
        }
        _ => {}
    }
    g
}

// ---------- per-source state ----------

/// How often (in samples) speaker gains are re-panned while an object moves; gains are
/// interpolated linearly in between so there is no zipper noise.
const PAN_STEP: u64 = 32;

struct Source {
    id: u32,
    is_bed: bool,
    // state at the start and end of the current ramp
    pos0: [f32; 3],
    pos1: [f32; 3],
    gain0: f32,
    gain1: f32,
    active: bool,
    ramp_len: u64,
    ramp_done: u64,
    // per-sample gains and their per-sample increment within the current PAN_STEP segment
    cur: [f32; K],
    step: [f32; K],
    seg_left: u64,
    level: f32,
}

impl Source {
    fn new(id: u32, level: f32, enc: &Encoder) -> Self {
        let is_bed = id < 10;
        let pos = [0.0, 1.0, 0.0];
        let mut s = Source {
            id, is_bed, pos0: pos, pos1: pos, gain0: 1.0, gain1: 1.0, active: is_bed,
            ramp_len: 0, ramp_done: 0, cur: [0.0; K], step: [0.0; K], seg_left: 0, level,
        };
        s.cur = s.gains_at(1.0, enc);
        s
    }

    /// Speaker gains at progress `k` (0..1) through the current ramp. Position and gain are
    /// interpolated first and then panned, so a moving object travels through the room
    /// instead of crossfading between its end points.
    fn gains_at(&self, k: f32, enc: &Encoder) -> [f32; K] {
        if !self.active {
            return [0.0; K];
        }
        let gain = (self.gain0 + (self.gain1 - self.gain0) * k) * self.level;
        let mut g = if self.is_bed {
            bed_gains(self.id)
        } else {
            let p = std::array::from_fn(|i| self.pos0[i] + (self.pos1[i] - self.pos0[i]) * k);
            pan(p)
        };
        for v in g.iter_mut() {
            *v *= gain;
        }
        enc.coeffs(&g)
    }

    fn progress(&self) -> f32 {
        if self.ramp_len == 0 { 1.0 } else { self.ramp_done as f32 / self.ramp_len as f32 }
    }

    fn apply(&mut self, e: &Event, enc: &Encoder) {
        // start the new ramp from wherever the old one had got to
        let k = self.progress();
        self.pos0 = std::array::from_fn(|i| self.pos0[i] + (self.pos1[i] - self.pos0[i]) * k);
        self.gain0 += (self.gain1 - self.gain0) * k;
        self.pos1 = e.pos.unwrap_or(self.pos0);
        if let Some(db) = e.gain_db {
            self.gain1 = if db.is_finite() { 10f32.powf(db / 20.0) } else { 0.0 };
        } else {
            self.gain1 = self.gain0;
        }
        if let Some(a) = e.active {
            self.active = a;
        }
        self.ramp_len = e.ramp.unwrap_or(0) as u64;
        self.ramp_done = 0;
        self.seg_left = 0;
        if self.ramp_len == 0 {
            self.pos0 = self.pos1;
            self.gain0 = self.gain1;
            self.cur = self.gains_at(1.0, enc);
            self.step = [0.0; K];
        }
    }

    /// Advances one sample and returns the gains to use for it.
    #[inline]
    fn tick(&mut self, enc: &Encoder, kn: usize) -> &[f32; K] {
        if self.ramp_done < self.ramp_len {
            if self.seg_left == 0 {
                let seg = PAN_STEP.min(self.ramp_len - self.ramp_done);
                let target = self.gains_at((self.ramp_done + seg) as f32 / self.ramp_len as f32, enc);
                for o in 0..kn {
                    self.step[o] = (target[o] - self.cur[o]) / seg as f32;
                }
                self.seg_left = seg;
            }
            for o in 0..kn {
                self.cur[o] += self.step[o];
            }
            self.seg_left -= 1;
            self.ramp_done += 1;
            if self.ramp_done == self.ramp_len {
                self.pos0 = self.pos1;
                self.gain0 = self.gain1;
                self.cur = self.gains_at(1.0, enc);
            }
        }
        &self.cur
    }

    fn silent(&self) -> bool {
        self.ramp_done >= self.ramp_len && self.cur.iter().all(|&g| g == 0.0)
    }
}

fn main() {
    if let Err(e) = run() {
        eprintln!("atmos-render: {e}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let usage = "usage: atmos-render INPUT.atmos [--direct LAYOUT [--height-eq DB]] [--dialogue DB] [--lfe DB]";
    let mut input = None;
    let (mut direct, mut height_eq, mut dialogue, mut lfe) = (None, 0.0f32, 0.0f32, 0.0f32);
    let mut i = 0;
    while i < args.len() {
        let val = || args.get(i + 1).cloned().ok_or(usage);
        match args[i].as_str() {
            "--direct" => direct = Some(parse_layout(&val()?).ok_or("--direct needs 12 az:el pairs")?),
            "--height-eq" => height_eq = val()?.parse()?,
            "--dialogue" => dialogue = val()?.parse()?,
            "--lfe" => lfe = val()?.parse()?,
            a if a.starts_with("--") => return Err(format!("unknown option {a}").into()),
            a => {
                input = Some(a.to_string());
                i += 1;
                continue;
            }
        }
        i += 2;
    }
    let arg = input.ok_or(usage)?;
    let enc = match direct {
        Some(dirs) => Encoder { direct: true, units: std::array::from_fn(|c| unit(dirs[c].0, dirs[c].1)), enc: speaker_encoders(&dirs) },
        None => Encoder { direct: false, units: [[0.0; 3]; CH714], enc: [[0.0; HOA]; CH714] },
    };
    let kn = if enc.direct { K } else { OUT_CH };
    let out_ch = if enc.direct { OUT_CH + HOA } else { OUT_CH };
    let mut eq: Vec<Biquad> = (0..HOA).map(|_| Biquad::height_cue(height_eq)).collect();
    let level = |id: u32| match id {
        2 => 10f32.powf(dialogue / 20.0),
        3 => 10f32.powf(lfe / 20.0),
        _ => 1.0,
    };

    let (audio_path, meta_path) = read_header(Path::new(&arg))?;
    let events = read_events(&meta_path)?;
    let mut caf = Caf::open(&audio_path)?;
    let nch = caf.channels;
    eprintln!(
        "atmos-render: {} input channels @ {} Hz, {} metadata events{}",
        nch, caf.sample_rate, events.len(), if enc.direct { ", direct ambisonic objects" } else { "" }
    );

    let mut sources: HashMap<u32, Source> = HashMap::new();
    for id in 0..nch as u32 {
        sources.insert(id, Source::new(id, level(id), &enc));
    }
    let mut ids: Vec<u32> = sources.keys().copied().collect();
    ids.sort();

    let stdout = io::stdout();
    let mut out = BufWriter::with_capacity(1 << 20, stdout.lock());
    let mut inbuf = Vec::new();
    let mut raw = Vec::new();
    let mut mix = vec![0.0f32; BLOCK * K];
    let mut frame_out = vec![0.0f32; BLOCK * out_ch];
    let mut bytes = Vec::with_capacity(BLOCK * out_ch * 4);
    let mut ev_idx = 0;
    let mut pos: u64 = 0;
    let mut peak = 0.0f32;

    loop {
        while ev_idx < events.len() && events[ev_idx].sample_pos.unwrap() <= pos {
            let e = &events[ev_idx];
            if let Some(s) = sources.get_mut(&e.id.unwrap()) {
                s.apply(e, &enc);
            }
            ev_idx += 1;
        }
        let mut n = BLOCK as u64;
        if ev_idx < events.len() {
            n = n.min(events[ev_idx].sample_pos.unwrap() - pos).max(1);
        }
        let frames = caf.read(&mut inbuf, n as usize, &mut raw)?;
        if frames == 0 {
            break;
        }
        let mix = &mut mix[..frames * K];
        mix.fill(0.0);

        for &id in &ids {
            let s = sources.get_mut(&id).unwrap();
            let ch = id as usize;
            if s.silent() {
                continue;
            }
            for f in 0..frames {
                let x = inbuf[f * nch + ch];
                let g = s.tick(&enc, kn);
                if x == 0.0 {
                    continue;
                }
                let row = &mut mix[f * K..f * K + kn];
                for o in 0..kn {
                    row[o] += x * g[o];
                }
            }
        }

        let fo = &mut frame_out[..frames * out_ch];
        for f in 0..frames {
            let row = &mix[f * K..(f + 1) * K];
            let dst = &mut fo[f * out_ch..(f + 1) * out_ch];
            dst[..OUT_CH].copy_from_slice(&row[..OUT_CH]);
            if enc.direct {
                for h in 0..HOA {
                    let wet = if height_eq != 0.0 { eq[h].run(row[OUT_CH + HOA + h]) } else { row[OUT_CH + HOA + h] };
                    dst[OUT_CH + h] = row[OUT_CH + h] + wet;
                }
            }
        }
        bytes.clear();
        for f in 0..frames {
            for (c, &v) in fo[f * out_ch..(f + 1) * out_ch].iter().enumerate() {
                if c < OUT_CH {
                    peak = peak.max(v.abs());
                }
                bytes.extend_from_slice(&v.to_le_bytes());
            }
        }
        if let Err(e) = out.write_all(&bytes) {
            if e.kind() == io::ErrorKind::BrokenPipe {
                return Ok(());
            }
            return Err(e.into());
        }
        pos += frames as u64;
    }
    out.flush()?;
    eprintln!(
        "atmos-render: rendered {:.1} s, peak {:.1} dBFS",
        pos as f64 / caf.sample_rate,
        20.0 * peak.max(1e-9).log10()
    );
    Ok(())
}
