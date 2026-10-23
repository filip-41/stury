// The timing protocol shared by the Rust arms; each bin includes it with `#[path]`. A job makes WARMUP untimed
// calls and RUNS timed ones and prints the median as key=value tokens. BENCH_RUNS overrides RUNS.
#![allow(dead_code)]

use std::sync::OnceLock;
use std::time::Instant;

pub const WARMUP: usize = 2;
static RUNS: OnceLock<usize> = OnceLock::new();

// Sets RUNS to BENCH_RUNS if set, else 10. Returns an error unless BENCH_RUNS is an integer >= 1. Call once
// before any job.
pub fn init() -> Result<(), String> {
    let n = match std::env::var("BENCH_RUNS") {
        Err(_) => 10,
        Ok(s) => match s.parse::<usize>() {
            Ok(n) if n >= 1 => n,
            _ => return Err(format!("BENCH_RUNS must be an integer >= 1, got {s:?}")),
        },
    };
    RUNS.set(n).expect("set once");
    Ok(())
}

pub fn runs() -> usize {
    *RUNS.get().expect("init validates BENCH_RUNS before any job")
}

// Returns the median ns of RUNS timed calls of `f` after WARMUP untimed ones, and the last call's value. Each
// earlier value is dropped after its clock stops.
pub fn time_runs<T>(mut f: impl FnMut() -> Result<T, String>) -> Result<(u128, T), String> {
    let runs = runs();
    let mut times = Vec::with_capacity(runs);
    let mut kept = None;
    for i in 0..WARMUP + runs {
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
    Ok(((times[(runs - 1) / 2] + times[runs / 2]) / 2, kept.unwrap()))
}

pub fn report(len: usize, ns: u128, extra: &str) {
    println!("gb_per_s={:.4} ns={} {}", len as f64 / ns as f64, ns, extra);
}

pub fn report_ns(len: usize, ns: f64, extra: &str) {
    println!("gb_per_s={:.4} ns={:.1} {}", len as f64 / ns, ns, extra);
}
