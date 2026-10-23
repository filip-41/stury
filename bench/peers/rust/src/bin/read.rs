// Timing jobs for bench/compare.py that match stury's bench lanes. Each job makes WARMUP + RUNS calls on one
// input and prints the median as key=value tokens. File I/O and dropping each decoded value are outside the
// clock.
//   read TOOL typed SHAPE FILE     TOOL serde|sonic; SHAPE logs|logs_subset|nested|config
//   read TOOL dom FILE             serde_json::Value or sonic_rs::Value
//   read sonic get FILE KEY        sonic_rs::get on one root member, taking its raw text. One sample is
//                                  GET_BATCH calls; the printed time is per call.
// typed decodes into the shapes of stury's bench_unmarshal.odin, borrowing strings that have no escapes
// (Cow + #[serde(borrow)]). With STURY_DUMP set, the last typed read is written there as JSON.
// BENCH_RUNS overrides the timed iteration count.
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use std::borrow::Cow;
use std::hint::black_box;

#[path = "../timing.rs"]
mod timing;
use timing::{report, report_ns, time_runs};

// Calls per GetOne sample, since one early-key call takes only a few timer ticks. The other GetOne arms use
// the same count.
const GET_BATCH: usize = 256;

#[derive(Serialize, Deserialize)]
struct LogRecord<'a> {
    #[serde(borrow)]
    ts: Cow<'a, str>,
    #[serde(borrow)]
    level: Cow<'a, str>,
    #[serde(borrow)]
    service: Cow<'a, str>,
    #[serde(borrow)]
    msg: Cow<'a, str>,
    status: i64,
    bytes: i64,
    duration_ms: f64,
    #[serde(borrow)]
    id: Cow<'a, str>,
}

#[derive(Serialize, Deserialize)]
struct LogsDoc<'a> {
    #[serde(borrow)]
    logs: Vec<LogRecord<'a>>,
}

#[derive(Serialize, Deserialize)]
struct LogSubset<'a> {
    status: i64,
    #[serde(borrow)]
    id: Cow<'a, str>,
}

#[derive(Serialize, Deserialize)]
struct LogsSubsetDoc<'a> {
    #[serde(borrow)]
    logs: Vec<LogSubset<'a>>,
}

#[derive(Serialize, Deserialize)]
struct NestedB {
    c: i64,
}

#[derive(Serialize, Deserialize)]
struct NestedInner {
    a: Vec<f64>,
    b: NestedB,
}

#[derive(Serialize, Deserialize)]
struct NestedRec<'a> {
    id: i64,
    #[serde(borrow)]
    name: Cow<'a, str>,
    tags: Vec<i64>,
    nested: NestedInner,
    ok: bool,
}

#[derive(Serialize, Deserialize)]
struct ConfigHead<'a> {
    #[serde(borrow)]
    name: Cow<'a, str>,
    port: i64,
}

#[derive(Clone, Copy)]
enum Tool {
    Serde,
    Sonic,
}

fn decode<'a, T: Deserialize<'a>>(tool: Tool, data: &'a [u8]) -> Result<T, String> {
    let data = black_box(data);
    let v = match tool {
        // from_utf8 inside the clock checks that the whole input is valid UTF-8, as the other arms do;
        // from_utf8 + from_str is serde_json's fastest way to do that.
        Tool::Serde => std::str::from_utf8(data)
            .map_err(|e| e.to_string())
            .and_then(|text| serde_json::from_str(text).map_err(|e| e.to_string())),
        Tool::Sonic => sonic_rs::from_slice(data).map_err(|e| e.to_string()),
    };
    black_box(&v);
    v
}

fn typed<'a, T: Deserialize<'a> + Serialize>(
    tool: Tool,
    data: &'a [u8],
    records: impl Fn(&T) -> usize,
) -> Result<(), String> {
    let (ns, v) = time_runs(|| decode::<T>(tool, data))?;
    if let Ok(path) = std::env::var("STURY_DUMP") {
        std::fs::write(path, serde_json::to_vec(&v).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    }
    report(data.len(), ns, &format!("records={}", records(&v)));
    Ok(())
}

fn dom<T: DeserializeOwned>(tool: Tool, data: &[u8]) -> Result<(), String> {
    let (ns, _) = time_runs(|| decode::<T>(tool, data))?;
    report(data.len(), ns, "");
    Ok(())
}

fn get(data: &[u8], key: &str) -> Result<(), String> {
    let (ns, raw_len) = time_runs(|| {
        let mut len = 0;
        for _ in 0..GET_BATCH {
            let found = sonic_rs::get(black_box(data), &[key]);
            black_box(&found);
            len = match found {
                Ok(v) => v.as_raw_str().len(),
                Err(e) if e.is_not_found() => 0,
                Err(e) => return Err(e.to_string()),
            };
        }
        Ok(len)
    })?;
    report_ns(data.len(), ns as f64 / GET_BATCH as f64, &format!("answer_bytes={}", raw_len));
    Ok(())
}

fn run(args: &[String]) -> Result<(), String> {
    let tool = match args.get(1).map(String::as_str) {
        Some("serde") => Tool::Serde,
        Some("sonic") => Tool::Sonic,
        _ => return Err("TOOL is serde or sonic".into()),
    };
    let job = args.get(2).map(String::as_str).unwrap_or("");
    let file = match job {
        "typed" => args.get(4),
        _ => args.get(3),
    }
    .ok_or("missing FILE")?;
    let data = std::fs::read(file).map_err(|e| e.to_string())?;
    match (job, tool) {
        ("typed", _) => match args[3].as_str() {
            "logs" => typed(tool, &data, |v: &LogsDoc| v.logs.len()),
            "logs_subset" => typed(tool, &data, |v: &LogsSubsetDoc| v.logs.len()),
            "nested" => typed(tool, &data, |v: &Vec<NestedRec>| v.len()),
            "config" => typed(tool, &data, |_: &ConfigHead| 1),
            s => Err(format!("unknown shape {s}")),
        },
        ("dom", Tool::Serde) => dom::<serde_json::Value>(tool, &data),
        ("dom", Tool::Sonic) => dom::<sonic_rs::Value>(tool, &data),
        ("get", Tool::Sonic) => get(&data, args.get(4).ok_or("missing KEY")?),
        _ => Err(format!("unknown job {job}")),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Err(e) = timing::init() {
        eprintln!("read: {e}");
        std::process::exit(2);
    }
    if let Err(e) = run(&args) {
        eprintln!("read: {e}");
        std::process::exit(1);
    }
}
