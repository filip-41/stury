// `typed-rust-xml logs FILE borrow|copy`: quick-xml's serde reader into the records of logs.xml, a `logs` element of `log`
// elements. `copy` reads every string into a `String`, and `borrow` into a `Text`, borrowed from the input when it has no
// escape. A number is parsed from its text. The check folds the value read as the typed lane's other arms do: an object's
// members sorted by key, then each value's kind and bytes. quick-xml checks the nesting of tags and no more, so this arm
// is not validating.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::hint::black_box;

use timing::{CHECK_OFFSET, fnv_bytes as fold_bytes, fnv_u64 as fold_u64, report, time_runs};
use typed_rust::{LogRecord, Logs, Text};

// The `log` children of the root element, which serde collects into one list.
#[derive(Serialize, Deserialize)]
struct LogsXml<S = String> {
    log: Vec<LogRecord<S>>,
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

fn read<'a, S: Deserialize<'a> + Serialize>(data: &'a [u8]) -> Result<(), String> {
    let (ns, v) = time_runs(|| -> Result<LogsXml<S>, String> {
        let text = std::str::from_utf8(black_box(data)).map_err(|e| e.to_string())?;
        quick_xml::de::from_str(text).map_err(|e| e.to_string())
    })?;
    let logs = Logs { logs: v.log };
    let value = serde_json::to_value(&logs).map_err(|e| e.to_string())?;
    report(data.len(), ns, fold(CHECK_OFFSET, &value), "");
    Ok(())
}

fn run(args: &[String]) -> Result<(), String> {
    let [_, lane, file, mode] = &args[..] else {
        return Err("usage: typed-rust-xml logs FILE borrow|copy".into());
    };
    let data = std::fs::read(file).map_err(|e| e.to_string())?;
    match (lane.as_str(), mode.as_str()) {
        ("logs", "copy") => read::<String>(&data),
        ("logs", "borrow") => read::<Text>(&data),
        _ => Err(format!("no typed lane {lane} {mode}")),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Err(e) = run(&args) {
        eprintln!("typed-rust-xml: {e}");
        std::process::exit(1);
    }
}
