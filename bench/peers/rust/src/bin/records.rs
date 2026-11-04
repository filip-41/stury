// Timing jobs for records.py. Each job makes WARMUP + TIMED passes over one file of records and prints the median as
// key=value tokens. The file is read outside the clock, and `check` is the record count.
//   records serde value FILE     serde_json's StreamDeserializer over an NDJSON text, each record to a Value
//   records serde validate FILE  the same, each record to IgnoredAny
//   records sonic value FILE     sonic-rs's StreamDeserializer, each record to a Value
//   records sonic validate FILE  the same, each record to IgnoredAny
//   records csv frame FILE       simd-csv's Splitter over a CSV text, each record's bytes and no cells
// A stream stops at its first error, so a text with a refused record fails the job.
use serde::de::{Deserialize, IgnoredAny};
use std::hint::black_box;

#[path = "../timing.rs"]
mod timing;
use timing::{report, time_runs};

// Counts the records of a stream, dropping each one as the next is read.
fn drain<T, E: ToString>(stream: impl Iterator<Item = Result<T, E>>) -> Result<u64, String> {
    let mut n = 0;
    for record in stream {
        black_box(&record.map_err(|e| e.to_string())?);
        n += 1;
    }
    Ok(n)
}

fn serde_stream<T: for<'de> Deserialize<'de>>(data: &[u8]) -> Result<u64, String> {
    drain(serde_json::Deserializer::from_slice(black_box(data)).into_iter::<T>())
}

// sonic-rs's stream has no clean end: after the last record it yields an end-of-input error, which ends the count here.
// A text cut inside a record also ends in one, and the runner compares the counts across arms.
fn sonic_stream<T: for<'de> Deserialize<'de>>(data: &[u8]) -> Result<u64, String> {
    let stream = sonic_rs::Deserializer::from_slice(black_box(data)).into_stream::<T>();
    drain(stream.take_while(|r| !matches!(r, Err(e) if e.is_eof())))
}

// The records after the first, which the Splitter's default takes as a header, as the record reader does.
fn csv_frame(data: &[u8]) -> Result<u64, String> {
    let mut splitter = simd_csv::Splitter::from_reader(black_box(data));
    let mut n = 0;
    while let Some(record) = splitter.split_record().map_err(|e| e.to_string())? {
        black_box(record);
        n += 1;
    }
    Ok(n)
}

fn run(args: &[String]) -> Result<(), String> {
    let [_, lib, job, file] = &args[..] else {
        return Err("usage: records serde|sonic value|validate FILE | records csv frame FILE".into());
    };
    let data = std::fs::read(file).map_err(|e| e.to_string())?;
    let (ns, n) = match (lib.as_str(), job.as_str()) {
        ("serde", "value") => time_runs(|| serde_stream::<serde_json::Value>(&data))?,
        ("serde", "validate") => time_runs(|| serde_stream::<IgnoredAny>(&data))?,
        ("sonic", "value") => time_runs(|| sonic_stream::<sonic_rs::Value>(&data))?,
        ("sonic", "validate") => time_runs(|| sonic_stream::<IgnoredAny>(&data))?,
        ("csv", "frame") => time_runs(|| csv_frame(&data))?,
        _ => return Err(format!("no job {lib} {job}")),
    };
    report(data.len(), ns, &format!("check={n}"));
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Err(e) = run(&args) {
        eprintln!("records: {e}");
        std::process::exit(1);
    }
}
