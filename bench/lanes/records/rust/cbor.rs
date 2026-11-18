// `records-rust validate|value FILE ciborium|minicbor` on a CBOR sequence (RFC 8742): each pass reads the data items one
// after another and `check` is their count. `validate` judges each item and drops it, ciborium by reading an
// IgnoredAny and minicbor by `skip`, which judges the structure and the UTF-8 of every text it passes. `value` builds
// a ciborium::Value per item. minicbor has no document type, so it has no `value` job.
use ciborium::Value;
use serde::de::IgnoredAny;
use std::hint::black_box;

use timing::{report, time_runs};

fn ciborium_items<T: serde::de::DeserializeOwned>(data: &[u8]) -> Result<u64, String> {
    let mut rest = black_box(data);
    let mut n = 0;
    while !rest.is_empty() {
        let item: T = ciborium::from_reader(&mut rest).map_err(|e| e.to_string())?;
        black_box(&item);
        n += 1;
    }
    Ok(n)
}

fn minicbor_skip(data: &[u8]) -> Result<u64, String> {
    let mut d = minicbor::Decoder::new(black_box(data));
    let mut n = 0;
    while d.position() < data.len() {
        d.skip().map_err(|e| e.to_string())?;
        n += 1;
    }
    Ok(n)
}

pub fn run(job: &str, data: &[u8], lib: &str) -> Result<(), String> {
    let (ns, n) = match (lib, job) {
        ("ciborium", "validate") => time_runs(|| ciborium_items::<IgnoredAny>(data))?,
        ("ciborium", "value") => time_runs(|| ciborium_items::<Value>(data))?,
        ("minicbor", "validate") => time_runs(|| minicbor_skip(data))?,
        _ => return Err(format!("no job {lib} {job}")),
    };
    report(data.len(), ns, n, "");
    Ok(())
}
