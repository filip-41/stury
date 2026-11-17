// What every Rust probe shares: the sampling rule and the check hash. A job makes WARMUP untimed calls and TIMED timed
// ones and prints the median as key=value tokens. The Odin, C and C++ probes follow the same rule and hash (timing.odin,
// timing.h).
use std::time::Instant;

pub const CHECK_OFFSET: u64 = 14695981039346656037;
const CHECK_PRIME: u64 = 1099511628211;

pub fn fnv_byte(h: u64, b: u8) -> u64 {
    (h ^ u64::from(b)).wrapping_mul(CHECK_PRIME)
}

pub fn fnv_bytes(h: u64, p: &[u8]) -> u64 {
    p.iter().fold(h, |h, &b| fnv_byte(h, b))
}

pub fn fnv_u64(h: u64, v: u64) -> u64 {
    (0..8).fold(h, |h, i| fnv_byte(h, (v >> (8 * i)) as u8))
}

pub const WARMUP: usize = 2;
pub const TIMED: usize = 10;

// Returns the median ns of TIMED timed calls of `f` after WARMUP untimed ones, and the last call's value. An
// earlier value is dropped before the next call starts, so only one call's value is live at a time.
pub fn time_runs<T>(mut f: impl FnMut() -> Result<T, String>) -> Result<(u128, T), String> {
    let mut times = Vec::with_capacity(TIMED);
    let mut kept = None;
    for i in 0..WARMUP + TIMED {
        drop(kept.take());
        let t0 = Instant::now();
        let v = f()?;
        let ns = t0.elapsed().as_nanos();
        kept = Some(v);
        if i >= WARMUP {
            times.push(ns);
        }
    }
    times.sort();
    // The mean of the two middle samples.
    Ok(((times[(TIMED - 1) / 2] + times[TIMED / 2]) / 2, kept.unwrap()))
}

// Like `time_runs`, with `batch` calls to a sample, each value dropped inside the clock before the next call. Returns the
// median sample over `batch`, in ns.
pub fn time_batches<T>(batch: usize, mut f: impl FnMut() -> Result<T, String>) -> Result<(u128, T), String> {
    let mut times = Vec::with_capacity(TIMED);
    let mut kept = None;
    for i in 0..WARMUP + TIMED {
        let t0 = Instant::now();
        for _ in 0..batch {
            drop(kept.take());
            kept = Some(f()?);
        }
        let ns = t0.elapsed().as_nanos();
        if i >= WARMUP {
            times.push(ns);
        }
    }
    times.sort();
    Ok((((times[(TIMED - 1) / 2] + times[TIMED / 2]) / 2) / batch as u128, kept.unwrap()))
}

pub fn report(len: usize, ns: u128, check: u64, extra: &str) {
    println!("gb_per_s={:.4} ns={} check={} {}", len as f64 / ns as f64, ns, check, extra);
}
