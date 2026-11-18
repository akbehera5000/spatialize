//! Places separated stems (vocals, drums, bass, other) around the listener.
//!
//! stdin:  f32le 48 kHz, 2 channels per stem, stems in order (e.g. 8 ch for 4 stereo stems).
//! stdout: 16 ch 3rd-order ambisonics (ACN, SN3D) with `--out hoa`, for the APAC encoder, or
//!         12 ch 7.1.4 (Apple order, LFE silent) with `--out 714`, for the binaural renderer.
//!
//!   --stems "AZ:EL:WIDTH:GAIN:ORBIT;…"  one entry per stem
//!       AZ, EL   direction in degrees (azimuth left-positive, elevation up)
//!       WIDTH    angle between the stem's left and right channels (0 = a point)
//!       GAIN     linear gain (0 mutes)
//!       ORBIT    degrees per second the stem circles you (0 = still, negative = clockwise)
//!   --out hoa|714
//!
//! Levels: see `weight` below. A look-ahead limiter keeps every channel below -0.2 dBFS.
//! Its delay is removed, so the output is exactly as long as the input and starts on time.

use atmos_render::*;
use std::io::{self, BufReader, BufWriter, Write};

struct Stem {
    az: f32,
    el: f32,
    width: f32,
    gain: f32,
    orbit: f32,
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let die = |m: &str| -> ! {
        eprintln!("stem-render: {m}");
        std::process::exit(2)
    };
    let get = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    let spec = get("--stems").unwrap_or_else(|| die("--stems is required"));
    let out714 = get("--out").as_deref() == Some("714");
    let stems: Vec<Stem> = spec
        .split(';')
        .filter(|s| !s.trim().is_empty())
        .map(|s| {
            let v: Vec<f32> = s.split(':').map(|x| x.trim().parse().unwrap_or_else(|_| die("bad --stems value"))).collect();
            if v.len() != 5 {
                die("each stem needs AZ:EL:WIDTH:GAIN:ORBIT");
            }
            Stem { az: v[0], el: v[1], width: v[2], gain: v[3], orbit: v[4] }
        })
        .collect();
    let in_ch = stems.len() * 2;
    let out_ch = if out714 { CH714 } else { HOA };
    let speakers = standard_dirs(45.0);
    let speaker_vecs: Vec<[f32; 3]> = speakers.iter().map(|&(a, e)| unit(a, e)).collect();

    // gains for one source direction into the output channels
    let gains_for = |az: f32, el: f32| -> Vec<f32> {
        if !out714 {
            return sh3(az, el).to_vec();
        }
        // smooth panner over the 11 main speakers: power-normalised cos^6 lobes
        let d = unit(az, el);
        let mut g = vec![0f32; CH714];
        let mut sum = 0f32;
        for (k, s) in speaker_vecs.iter().enumerate() {
            if k == LFE {
                continue;
            }
            let c = (d[0] * s[0] + d[1] * s[1] + d[2] * s[2]).max(0.0);
            g[k] = c.powi(6);
            sum += g[k] * g[k];
        }
        let n = if sum > 0.0 { sum.sqrt() } else { 1.0 };
        g.iter_mut().for_each(|v| *v /= n);
        g
    };

    // Ambisonics: 0.5 per channel keeps the W channel (the sum of everything) within the song's
    // own peaks, so nothing is limited; it plays at about -17 LUFS, the level Apple Music's Dolby
    // Atmos songs are mastered to. 7.1.4 (for the binaural copy): 0.75 matches the stereo song
    // within 1 LU (measured). The limiter is only a safety net.
    let weight = if out714 { 0.75 } else { 0.5 };
    let block = 64usize;
    let look = 96usize;
    let ceiling = 0.977f32;
    let attack = (-5.0f32 / look as f32).exp();
    let release = (-1.0f32 / (0.12 * SR)).exp();
    let mut delay: std::collections::VecDeque<Vec<f32>> = std::collections::VecDeque::with_capacity(look + 1);
    let mut need: std::collections::VecDeque<f32> = std::collections::VecDeque::with_capacity(look + 1);
    let mut lim_gain = 1f32;
    let mut skip = look;
    let mut limited = Vec::with_capacity(block * out_ch);
    let mut input = BufReader::with_capacity(1 << 20, io::stdin().lock());
    let mut output = BufWriter::with_capacity(1 << 20, io::stdout().lock());
    let (mut raw, mut frames, mut scratch) = (Vec::new(), Vec::new(), Vec::new());
    let mut out = Vec::with_capacity(block * out_ch);
    let mut t = 0usize; // frames rendered so far
    // previous block's gains per source, for a ramp (no zipper noise while a stem moves)
    let mut prev: Vec<Vec<f32>> = vec![Vec::new(); in_ch];

    loop {
        let n = read_frames(&mut input, &mut raw, &mut frames, in_ch, block);
        if n == 0 {
            break;
        }
        let secs = (t + n) as f32 / SR;
        out.clear();
        out.resize(n * out_ch, 0.0);
        for (s, st) in stems.iter().enumerate() {
            let az = st.az + st.orbit * secs;
            for side in 0..2 {
                let src = 2 * s + side;
                // left channel to the left of the stem's direction
                let a = az + if side == 0 { st.width / 2.0 } else { -st.width / 2.0 };
                let target: Vec<f32> = gains_for(a, st.el).into_iter().map(|g| g * weight * st.gain).collect();
                let from = if prev[src].is_empty() { target.clone() } else { prev[src].clone() };
                for f in 0..n {
                    let x = frames[f * in_ch + src];
                    if x == 0.0 {
                        continue;
                    }
                    let w = (f + 1) as f32 / n as f32;
                    let o = &mut out[f * out_ch..(f + 1) * out_ch];
                    for k in 0..out_ch {
                        let g = from[k] + (target[k] - from[k]) * w;
                        o[k] += x * g;
                    }
                }
                prev[src] = target;
            }
        }
        t += n;
        limit(&out, n, out_ch, look, ceiling, attack, release, &mut delay, &mut need, &mut lim_gain, &mut skip, &mut limited);
        if write_f32(&mut output, &limited, &mut scratch).is_err() {
            return;
        }
    }
    // push the look-ahead out so the end isn't cut
    let silence = vec![0f32; look * out_ch];
    limit(&silence, look, out_ch, look, ceiling, attack, release, &mut delay, &mut need, &mut lim_gain, &mut skip, &mut limited);
    let _ = write_f32(&mut output, &limited, &mut scratch);
    let _ = output.flush();
}

/// Look-ahead peak limiter over whole frames: each frame waits `look` frames, while the gain
/// already falls towards what any frame in that window needs.
#[allow(clippy::too_many_arguments)]
fn limit(input: &[f32], n: usize, ch: usize, look: usize, ceiling: f32, attack: f32, release: f32,
         delay: &mut std::collections::VecDeque<Vec<f32>>, need: &mut std::collections::VecDeque<f32>,
         gain: &mut f32, skip: &mut usize, out: &mut Vec<f32>) {
    out.clear();
    for f in 0..n {
        let frame = input[f * ch..(f + 1) * ch].to_vec();
        let peak = frame.iter().fold(0f32, |m, v| m.max(v.abs()));
        delay.push_back(frame);
        need.push_back(if peak > ceiling { ceiling / peak } else { 1.0 });
        if delay.len() <= look {
            continue;
        }
        let target = need.iter().cloned().fold(1f32, f32::min);
        let coef = if target < *gain { attack } else { release };
        *gain = target + (*gain - target) * coef;
        let old = delay.pop_front().unwrap();
        let req = need.pop_front().unwrap();
        let g = gain.min(req);
        if *skip > 0 {
            *skip -= 1;
            continue;
        }
        out.extend(old.iter().map(|v| v * g));
    }
}
