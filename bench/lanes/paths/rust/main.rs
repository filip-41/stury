// `paths-rust get FILE KEY [BATCH]`: sonic_rs::get of one root key, which scans to the key and leaves the rest of the text
// unread, BATCH calls to a sample.
use std::hint::black_box;

mod cbor;
mod html;

use timing::{CHECK_OFFSET, fnv_bytes, report, time_batches};

// One `sonic_rs::get` of `key`, which scans to the key and leaves the rest of the text unread.
fn get_job(data: &[u8], key: &str, batch: usize) -> Result<(), String> {
    let path = [key];
    let (ns, raw) = time_batches(batch, || {
        let found = sonic_rs::get_from_slice(data, path).ok().map(|v| v.as_raw_str().to_owned());
        black_box(&found);
        Ok(found)
    })?;
    let chk = fnv_bytes(CHECK_OFFSET, raw.unwrap_or_default().as_bytes());
    report(data.len(), ns, chk, "");
    Ok(())
}

fn run(args: &[String]) -> Result<(), String> {
    if let [_, lane, file, path, rest @ ..] = &args[..] {
        if lane == "path" && rest.len() <= 1 {
            let batch = rest.first().map_or(Ok(1), |b| b.parse::<usize>()).map_err(|e| e.to_string())?;
            return cbor::run(file, path, batch);
        }
    }
    let [_, lane, file, key, rest @ ..] = &args[..] else {
        return Err("usage: paths-rust get FILE KEY [BATCH]".into());
    };
    if matches!(lane.as_str(), "select" | "build_select") {
        let data = std::fs::read(file).map_err(|e| e.to_string())?;
        let batch = rest.first().map_or(Ok(1), |b| b.parse::<usize>()).map_err(|e| e.to_string())?;
        return html::run(lane, &data, key, batch);
    }
    if lane != "get" || rest.len() > 1 {
        return Err("usage: paths-rust get FILE KEY [BATCH]".into());
    }
    let data = std::fs::read(file).map_err(|e| e.to_string())?;
    let batch = rest.first().map_or(Ok(1), |b| b.parse::<usize>()).map_err(|e| e.to_string())?;
    get_job(&data, key, batch)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Err(e) = run(&args) {
        eprintln!("paths-rust: {e}");
        std::process::exit(1);
    }
}
