//! Mix stage between the renderer and the APAC encoder.
//!
//! stdin:  raw f32le, 12 ch 7.1.4 in Apple order (L R C LFE Ls Rs Lrs Rrs Ltf Rtf Ltr Rtr),
//!         or with --direct-in 28 ch: that 7.1.4 feed followed by 16 ch of ambisonics that
//!         atmos-render already encoded straight from the objects.
//! stdout: 12 ch 7.1.4, or 16 ch 3rd-order ambisonics (ACN, SN3D) with --hoa/--layout/--direct-in.
//!
//! Order: dialogue/LFE level → room → headphone EQ → gain, night mode and limiter → (--compat-out copy)
//!        → overhead cue → ambisonic encoding.
//!
//!   --dialogue DB       centre channel level (dialogue lives there in nearly every mix)
//!   --lfe DB            LFE level
//!   --room SPEC         small|living|cinema[:amount] early reflections + diffuse tail
//!   --eq G1,…,G10       headphone EQ in dB at 31 62 125 250 500 1k 2k 4k 8k 16k Hz
//!   --gain DB           static gain (loudness normalisation)
//!   --night             compress loud passages, lift quiet ones
//!   --limit             look-ahead peak limiter at -1 dBFS (latency is trimmed, sync unchanged)
//!   --compat-out PATH   also write the processed 7.1.4 (before the height cue) to PATH
//!   --height-eq DB      peaking lift around 7.5 kHz on the four top channels
//!   --hoa DEGREES       encode as ambisonics with the top speakers at DEGREES elevation
//!   --layout PAIRS      encode as ambisonics with 12 custom az:el speaker directions
//!   --direct-in         28-ch input (see above); the 16 ambisonic channels pass through the
//!                       same gain and get the room encoded on top

use atmos_render::*;
use std::fs::File;
use std::io::{self, BufReader, BufWriter, Write};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut dialogue = 0.0f32;
    let mut lfe = 0.0f32;
    let mut room: Option<Room> = None;
    let mut gain = 0.0f32;
    let mut night = false;
    let mut limit = false;
    let mut compat: Option<String> = None;
    let mut height_eq = 0.0f32;
    let mut hoa_el: Option<f32> = None;
    let mut layout: Option<[(f32, f32); CH714]> = None;
    let mut direct = false;
    let mut eq_spec: Option<String> = None;

    let mut i = 0;
    let die = |m: String| -> ! {
        eprintln!("spatial-post: {m}");
        std::process::exit(2)
    };
    while i < args.len() {
        let next = |i: usize| args.get(i + 1).cloned().unwrap_or_else(|| die(format!("{} needs a value", args[i])));
        let num = |i: usize| next(i).parse::<f32>().unwrap_or_else(|_| die(format!("{} needs a number", args[i])));
        let mut step = 2;
        match args[i].as_str() {
            "--dialogue" => dialogue = num(i),
            "--lfe" => lfe = num(i),
            "--room" => room = Room::preset(&next(i)),
            "--gain" => gain = num(i),
            "--eq" => eq_spec = Some(next(i)),
            "--night" => { night = true; step = 1 }
            "--limit" => { limit = true; step = 1 }
            "--compat-out" => compat = Some(next(i)),
            "--height-eq" => height_eq = num(i),
            "--hoa" => hoa_el = Some(num(i)),
            "--layout" => {
                layout = Some(parse_layout(&next(i)).unwrap_or_else(|| die("--layout needs 12 azimuth:elevation pairs".into())));
            }
            "--direct-in" => { direct = true; step = 1 }
            o => die(format!("unknown option {o}")),
        }
        i += step;
    }

    let hoa_out = direct || hoa_el.is_some() || layout.is_some();
    let dirs = layout.unwrap_or_else(|| standard_dirs(hoa_el.unwrap_or(45.0)));
    let enc = speaker_encoders(&dirs);
    let (dlg, lfe_g) = (10f32.powf(dialogue / 20.0), 10f32.powf(lfe / 20.0));
    let mut dynamics = Dynamics::new(gain, night, limit);
    let dyn_on = dynamics.active();
    let latency = dynamics.latency();
    let mut delay714: FrameDelay<CH714> = FrameDelay::new(latency);
    let mut delay_hoa: FrameDelay<HOA> = FrameDelay::new(latency);
    let mut eq: Vec<Biquad> = (0..4).map(|_| Biquad::height_cue(height_eq)).collect();
    let mut compat_w = compat.map(|p| BufWriter::with_capacity(1 << 20, File::create(&p).unwrap_or_else(|e| die(format!("{p}: {e}")))));

    let in_ch = if direct { CH714 + HOA } else { CH714 };
    let mut heq = eq_spec.map(|s| HeadphoneEq::parse(&s, CH714 + HOA).unwrap_or_else(|| die("--eq needs 10 comma-separated dB values".into())))
        .filter(|e| !e.is_flat());
    let out_ch = if hoa_out { HOA } else { CH714 };
    let mut input = BufReader::with_capacity(1 << 20, io::stdin().lock());
    let mut output = BufWriter::with_capacity(1 << 20, io::stdout().lock());
    let (mut raw, mut frames_in, mut scratch) = (Vec::new(), Vec::new(), Vec::new());
    let mut out = Vec::with_capacity(1024 * HOA);
    let mut compat_buf = Vec::with_capacity(1024 * CH714);
    let mut to_skip = latency; // the limiter's look-ahead: drop that many frames at the start
    let mut flushing = 0usize;

    loop {
        let mut n = read_frames(&mut input, &mut raw, &mut frames_in, in_ch, 1024);
        if n == 0 {
            // push the look-ahead through with silence so the end isn't cut
            if flushing >= latency {
                break;
            }
            n = (latency - flushing).min(1024);
            flushing += n;
            frames_in.clear();
            frames_in.resize(n * in_ch, 0.0);
        }
        out.clear();
        compat_buf.clear();
        for f in 0..n {
            let fr = &frames_in[f * in_ch..(f + 1) * in_ch];
            let mut x: [f32; CH714] = fr[..CH714].try_into().unwrap();
            let mut h: [f32; HOA] = if direct { fr[CH714..].try_into().unwrap() } else { [0.0; HOA] };
            if !direct {
                x[2] *= dlg;
                x[LFE] *= lfe_g;
            }
            if let Some(r) = room.as_mut() {
                let wet = r.process(&x);
                for c in 0..CH714 {
                    x[c] += wet[c];
                    if direct && wet[c] != 0.0 {
                        for k in 0..HOA {
                            h[k] += wet[c] * enc[c][k];
                        }
                    }
                }
            }
            if let Some(e) = heq.as_mut() {
                for c in 0..CH714 {
                    x[c] = e.run(c, x[c]);
                }
                if direct {
                    for k in 0..HOA {
                        h[k] = e.run(CH714 + k, h[k]);
                    }
                }
            }
            if dyn_on {
                let g = dynamics.gain_for(&x);
                x = delay714.push(x);
                h = delay_hoa.push(h);
                for v in x.iter_mut() {
                    *v *= g;
                }
                for v in h.iter_mut() {
                    *v *= g;
                }
            }
            if to_skip > 0 {
                to_skip -= 1;
                continue;
            }
            if compat_w.is_some() {
                compat_buf.extend_from_slice(&x);
            }
            if direct {
                out.extend_from_slice(&h);
                continue;
            }
            if height_eq != 0.0 {
                for k in 0..4 {
                    x[8 + k] = eq[k].run(x[8 + k]);
                }
            }
            if hoa_out {
                let mut y = [0.0f32; HOA];
                for c in 0..CH714 {
                    if x[c] != 0.0 {
                        for k in 0..HOA {
                            y[k] += x[c] * enc[c][k];
                        }
                    }
                }
                out.extend_from_slice(&y);
            } else {
                out.extend_from_slice(&x);
            }
        }
        if let Some(w) = compat_w.as_mut() {
            if write_f32(w, &compat_buf, &mut scratch).is_err() {
                // the compatible encoder went away; carry on without it
                compat_w = None;
            }
        }
        if write_f32(&mut output, &out, &mut scratch).is_err() {
            return;
        }
    }
    let _ = output.flush();
    if let Some(mut w) = compat_w {
        let _ = w.flush();
    }
    let _ = out_ch;
}
