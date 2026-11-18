// The `toml` crate's arm of the write lane, run on a `.toml` file: `toml::to_string` of the fixture's struct (`typed`, GB/s of
// the output's bytes) or of a `toml::Table` read from it (`doc`, GB/s of the source's). Reading the fixture is outside the
// clock. The check is the read check of the output parsed back as a table, since writers spell the same values their own
// ways. The crate has one compact spelling, so there is no pretty form.
use std::hint::black_box;

use timing::{report, time_runs};
use toml::Table;
use typed_rust::Logs;

#[path = "../../doc/rust/toml_arm.rs"]
#[allow(dead_code)]
mod toml_arm;

fn lane<T: serde::Serialize>(v: &T, basis: usize) -> Result<(), String> {
    let (ns, text) = time_runs(|| toml::to_string(black_box(v)).map_err(|e| e.to_string()))?;
    let back = toml::from_str::<Table>(&text).map_err(|e| e.to_string())?;
    let chk = toml_arm::read_check(&toml::Value::Table(back));
    report(if basis == 0 { text.len() } else { basis }, ns, chk, &format!("out={}", text.len()));
    Ok(())
}

pub fn run(mode: &str, file: &str, data: &[u8]) -> Result<(), String> {
    match mode {
        "doc" => lane(&toml::from_slice::<Table>(data).map_err(|e| e.to_string())?, data.len()),
        "typed" => match std::path::Path::new(file).file_stem().and_then(|s| s.to_str()) {
            Some("logs") => lane(&toml::from_slice::<Logs>(data).map_err(|e| e.to_string())?, 0),
            stem => Err(format!("no typed lane for {stem:?}")),
        },
        _ => Err(format!("unknown mode {mode}")),
    }
}
