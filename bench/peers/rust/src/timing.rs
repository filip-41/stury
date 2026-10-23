// The timing protocol the Rust arms share (`#[path]`-included by each bin): WARMUP untimed calls and RUNS
// timed ones, the median printed as key=value tokens. BENCH_RUNS overrides the timed iteration count.
#![allow(dead_code)]

use std::sync::OnceLock;
use std::time::Instant;

pub const WARMUP: usize = 2;
static RUNS: OnceLock<usize> = OnceLock::new();

// BENCH_RUNS if set, else 10; an integer >= 1 or an error. Call once before any job.
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

// Median of RUNS timed calls of `f` after WARMUP untimed ones; the last value is kept, and each earlier one is
// dropped after its clock stops.
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
