// Timing jobs for typed.py. Each job makes WARMUP + TIMED reads of one file into the fixture's struct type, chosen by
// the lane's name, and prints the median as key=value tokens. GB/s counts the source's bytes.
//   typed LIB LANE borrow|copy FILE
// LIB is `serde` (serde_json) or `sonic` (sonic-rs), and LANE `logs`, `twitter` or `citm`. `copy` reads every string into
// a `String`, and `borrow` into a `Text`, borrowed from the input when it has no escape. `check` folds the value read, as
// the probe's does: an object's members sorted by key, then each value's kind and bytes.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::hint::black_box;

#[path = "../timing.rs"]
mod timing;
use timing::{report, time_runs};
#[path = "../types.rs"]
mod types;
use types::*;

const CHECK_OFFSET: u64 = 14695981039346656037;
const CHECK_PRIME: u64 = 1099511628211;

fn fold_bytes(h: u64, p: &[u8]) -> u64 {
    p.iter().fold(h, |h, &b| (h ^ u64::from(b)).wrapping_mul(CHECK_PRIME))
}

fn fold_u64(h: u64, n: u64) -> u64 {
    fold_bytes(h, &n.to_le_bytes())
}

fn fold_text(h: u64, s: &str) -> u64 {
    fold_bytes(fold_u64(fold_bytes(h, b"s"), s.len() as u64), s.as_bytes())
}

fn fold(h: u64, v: &Value) -> u64 {
    match v {
        Value::Null => fold_bytes(h, b"n"),
        Value::Bool(b) => fold_bytes(h, if *b { b"t" } else { b"f" }),
        Value::Number(n) => match n.as_i64() {
            Some(i) => fold_u64(fold_bytes(h, b"i"), i as u64),
            None => fold_u64(fold_bytes(h, b"d"), n.as_f64().unwrap_or(f64::NAN).to_bits()),
        },
        Value::String(s) => fold_text(h, s),
        Value::Array(a) => a.iter().fold(fold_u64(fold_bytes(h, b"a"), a.len() as u64), fold),
        Value::Object(o) => {
            let mut members: Vec<_> = o.iter().collect();
            members.sort_unstable_by(|a, b| a.0.cmp(b.0));
            members.iter().fold(fold_u64(fold_bytes(h, b"o"), o.len() as u64), |h, (k, v)| fold(fold_text(h, k), v))
        }
    }
}

fn read<'a, T: Deserialize<'a> + Serialize>(lib: &str, data: &'a [u8]) -> Result<(), String> {
    let (ns, v) = time_runs(|| -> Result<T, String> {
        match lib {
            "serde" => serde_json::from_slice(black_box(data)).map_err(|e| e.to_string()),
            "sonic" => sonic_rs::from_slice(black_box(data)).map_err(|e| e.to_string()),
            _ => Err(format!("unknown LIB {lib}")),
        }
    })?;
    let value = serde_json::to_value(&v).map_err(|e| e.to_string())?;
    report(data.len(), ns, &format!("check={}", fold(CHECK_OFFSET, &value)));
    Ok(())
}

fn run(args: &[String]) -> Result<(), String> {
    let [_, lib, lane, mode, file] = &args[..] else {
        return Err("usage: typed serde|sonic logs|twitter|citm borrow|copy FILE".into());
    };
    let data = std::fs::read(file).map_err(|e| e.to_string())?;
    match (lane.as_str(), mode.as_str()) {
        ("logs", "copy") => read::<Logs>(lib, &data),
        ("logs", "borrow") => read::<Logs<Text>>(lib, &data),
        ("twitter", "copy") => read::<Twitter>(lib, &data),
        ("twitter", "borrow") => read::<Twitter<Text>>(lib, &data),
        ("citm", "copy") => read::<Citm>(lib, &data),
        ("citm", "borrow") => read::<Citm<Text>>(lib, &data),
        _ => Err(format!("no typed lane {lane} {mode}")),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Err(e) = run(&args) {
        eprintln!("typed: {e}");
        std::process::exit(1);
    }
}
