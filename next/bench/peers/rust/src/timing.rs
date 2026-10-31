// The timing protocol of the Rust arms; the bin includes it with `#[path]`. A job makes WARMUP untimed calls
// and TIMED timed ones and prints the median as key=value tokens.
use std::time::Instant;

pub const WARMUP: usize = 2;
pub const TIMED: usize = 10;

// Returns the median ns of TIMED timed calls of `f` after WARMUP untimed ones, and the last call's value. Each
// earlier value is dropped after its clock stops.
pub fn time_runs<T>(mut f: impl FnMut() -> Result<T, String>) -> Result<(u128, T), String> {
    let mut times = Vec::with_capacity(TIMED);
    let mut kept = None;
    for i in 0..WARMUP + TIMED {
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

pub fn report(len: usize, ns: u128, extra: &str) {
    println!("gb_per_s={:.4} ns={} {}", len as f64 / ns as f64, ns, extra);
}
