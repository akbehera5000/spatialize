//! Speaker-walk test signal: pink noise visits each of the 11 speakers in turn (1.5 s on, 0.5 s
//! gap). stdout: raw f32le, 12 ch, Apple Atmos 7.1.4 order. stderr: "START_SECONDS LABEL" lines.
//! usage: walkgen > walk.f32 2> schedule.txt

use std::io::{self, BufWriter, Write};

const SR: usize = 48000;
const WALK: [(usize, &str); 11] = [
    (0, "Front Left"), (2, "Center"), (1, "Front Right"), (5, "Side Right"), (7, "Rear Right"),
    (6, "Rear Left"), (4, "Side Left"), (8, "Top Front Left"), (9, "Top Front Right"),
    (11, "Top Rear Right"), (10, "Top Rear Left"),
];

fn main() {
    let mut out = BufWriter::new(io::stdout().lock());
    let mut seed: u32 = 1;
    let mut b = [0.0f32; 7]; // Paul Kellet pink-noise filter
    for (k, &(ch, label)) in WALK.iter().enumerate() {
        eprintln!("{} {}", k * 2, label);
        for n in 0..2 * SR {
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            let w = (seed >> 8) as f32 / (1u32 << 24) as f32 * 2.0 - 1.0;
            b[0] = 0.99886 * b[0] + w * 0.0555179;
            b[1] = 0.99332 * b[1] + w * 0.0750759;
            b[2] = 0.96900 * b[2] + w * 0.1538520;
            b[3] = 0.86650 * b[3] + w * 0.3104856;
            b[4] = 0.55000 * b[4] + w * 0.5329522;
            b[5] = -0.7616 * b[5] - w * 0.0168980;
            let pink = (b[..6].iter().sum::<f32>() + b[6] + w * 0.5362) * 0.05;
            b[6] = w * 0.115926;
            let t = n as f32 / SR as f32;
            let fade = if t < 1.5 { (t / 0.02).min(1.0).min((1.5 - t) / 0.02) } else { 0.0 };
            let mut frame = [0.0f32; 12];
            frame[ch] = pink * fade;
            for v in frame {
                out.write_all(&v.to_le_bytes()).unwrap();
            }
        }
    }
}
