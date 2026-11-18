// `write-rust doc|typed FILE [pretty] LIB`: each job makes WARMUP + TIMED writes of one value into a buffer sized once and
// reused. Reading the fixture into the value is outside the clock. `doc` is a parsed document (LIB's Value) to text and
// `typed` the fixture's struct type to text, chosen by the file's name. LIB is `serde` (serde_json) or `sonic` (sonic-rs).
// A document's GB/s counts the source file's bytes and a typed value's counts the output's.
mod toml_write;

use serde::{Deserialize, Serialize};
use std::hint::black_box;

mod yaml;
mod html;

use timing::{CHECK_OFFSET, fnv_bytes, report, time_runs};
use typed_rust::*;

mod cbor;

// One write of `v` into `buf` by `lib`. The buffer keeps its capacity across calls.
fn put<T: Serialize>(lib: &str, pretty: bool, v: &T, buf: &mut Vec<u8>) -> Result<(), String> {
    buf.clear();
    let r = match (lib, pretty) {
        ("serde", false) => serde_json::to_writer(&mut *buf, v).map_err(|e| e.to_string()),
        ("serde", true) => serde_json::to_writer_pretty(&mut *buf, v).map_err(|e| e.to_string()),
        ("sonic", false) => sonic_rs::to_writer(&mut *buf, v).map_err(|e| e.to_string()),
        ("sonic", true) => sonic_rs::to_writer_pretty(&mut *buf, v).map_err(|e| e.to_string()),
        _ => Err(format!("unknown LIB {lib}")),
    };
    black_box(&*buf);
    r
}

// Times the writes of `v`. `basis` is the byte count the GB/s divides: the source's for a document, or 0 for the
// output's.
fn lane<T: Serialize>(lib: &str, pretty: bool, v: &T, basis: usize, cap: usize) -> Result<(), String> {
    let mut buf = Vec::with_capacity(cap);
    let (ns, ()) = time_runs(|| put(lib, pretty, v, &mut buf))?;
    let basis = if basis == 0 { buf.len() } else { basis };
    report(basis, ns, fnv_bytes(CHECK_OFFSET, &buf), &format!("out={}", buf.len()));
    Ok(())
}

fn typed<T: Serialize + for<'de> Deserialize<'de>>(lib: &str, pretty: bool, data: &[u8]) -> Result<(), String> {
    let v: T = serde_json::from_slice(data).map_err(|e| e.to_string())?;
    lane(lib, pretty, &v, 0, data.len() * 3)
}

fn document(lib: &str, pretty: bool, data: &[u8]) -> Result<(), String> {
    let cap = data.len() * 3;
    match lib {
        "serde" => {
            let v: serde_json::Value = serde_json::from_slice(data).map_err(|e| e.to_string())?;
            lane(lib, pretty, &v, data.len(), cap)
        }
        "sonic" => {
            let v: sonic_rs::Value = sonic_rs::from_slice(data).map_err(|e| e.to_string())?;
            lane(lib, pretty, &v, data.len(), cap)
        }
        _ => Err(format!("unknown LIB {lib}")),
    }
}

fn run(args: &[String]) -> Result<(), String> {
    let [_, mode, file, rest @ ..] = &args[..] else {
        return Err("usage: write-rust doc|typed FILE [pretty] serde|sonic".into());
    };
    let (Some(lib), pretty) = (rest.last(), rest.first().map(String::as_str) == Some("pretty")) else {
        return Err("usage: write-rust doc|typed FILE [pretty] serde|sonic".into());
    };
    let data = std::fs::read(file).map_err(|e| e.to_string())?;
    if matches!(lib.as_str(), "ciborium" | "minicbor") {
        return cbor::run(mode, &data, lib);
    }
    if lib.as_str() == "html5ever" {
        return html::run(&data);
    }
    if file.ends_with(".toml") {
        return toml_write::run(mode, file, &data);
    }
    match mode.as_str() {
        "doc" => document(lib, pretty, &data),
        "typed" => {
            let stem = std::path::Path::new(file).file_stem().and_then(|s| s.to_str()).unwrap_or("");
            match stem {
                "logs" => typed::<Logs>(lib, pretty, &data),
                "twitter" => typed::<Twitter>(lib, pretty, &data),
                "citm_catalog" => typed::<Citm>(lib, pretty, &data),
                "canada" => typed::<Canada>(lib, pretty, &data),
                "nested" => typed::<Vec<NestedRecord>>(lib, pretty, &data),
                "wide" => typed::<SortedMap<String, i64>>(lib, pretty, &data),
                _ => Err(format!("no typed lane for {stem}")),
            }
        }
        _ => Err(format!("unknown mode {mode}")),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let result = if args.len() == 4 && args[3] == "yaml" { yaml::run(&args) } else { run(&args) };
    if let Err(e) = result {
        eprintln!("write-rust: {e}");
        std::process::exit(1);
    }
}
