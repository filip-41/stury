// Warm in-process CSV timing jobs for bench/compare.py, mirroring stury's `csv_` lanes (bench/probe/bench_csv.odin):
// WARMUP + RUNS calls on one input, the median printed as key=value tokens. File I/O is outside the clock, as is
// dropping each built value. A `.tsv` file reads with a tab delimiter (csv crate: quoting off).
//   csv_bench csv  validate-str|validate-bytes|records-str|records-bytes|dom-str|dom-bytes FILE
//   csv_bench csv  typed|marshal table|text FILE      serde derive; typed reads owned Strings
//   csv_bench simd validate-str|validate-split|records-str|records-total|dom-str|dom-total FILE
// The `-str` arms check every field as UTF-8, the `-bytes` and `-total` arms do not. Every arm reads the first
// record as data, so `records` counts the header, as stury's `records` lane does. The records and dom arms print
// `records fields bytes` (the decoded fields' total); a failing read exits nonzero. With STURY_DUMP set, a typed
// arm writes its rows as JSON there and a marshal arm the CSV it wrote.
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use std::hint::black_box;

#[path = "../timing.rs"]
mod timing;
use timing::{report, time_runs};

#[derive(Serialize, Deserialize)]
struct TableRow {
    id: i64,
    ts: i64,
    lat: f64,
    lon: f64,
    qty: i64,
    price: f64,
    score: f64,
    ok: bool,
    code: String,
}

#[derive(Serialize, Deserialize)]
struct TextRow {
    id: i64,
    name: String,
    city: String,
    quote: String,
    note: String,
}

#[derive(Default)]
struct Tally {
    records: u64,
    fields: u64,
    bytes: u64,
}

impl Tally {
    fn add(&mut self, fields: impl Iterator<Item = usize>) {
        self.records += 1;
        for len in fields {
            self.fields += 1;
            self.bytes += len as u64;
        }
    }

    fn tokens(&self) -> String {
        format!("records={} fields={} bytes={}", self.records, self.fields, self.bytes)
    }
}

fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

fn csv_reader(data: &[u8], tsv: bool, headers: bool) -> csv::Reader<&[u8]> {
    let mut b = csv::ReaderBuilder::new();
    b.has_headers(headers);
    if tsv {
        b.delimiter(b'\t').quoting(false);
    }
    b.from_reader(data)
}

// simd-csv cannot switch quoting off: the TSV fixture holds no quote byte, so its answer is the same.
fn simd_reader(data: &[u8], tsv: bool) -> simd_csv::Reader<&[u8]> {
    let mut b = simd_csv::ReaderBuilder::new();
    b.has_headers(false);
    if tsv {
        b.delimiter(b'\t');
    }
    b.from_reader(data)
}

fn csv_str_records(data: &[u8], tsv: bool) -> Result<Vec<csv::StringRecord>, String> {
    csv_reader(data, tsv, false).records().collect::<Result<_, _>>().map_err(err)
}

fn csv_byte_records(data: &[u8], tsv: bool) -> Result<Vec<csv::ByteRecord>, String> {
    csv_reader(data, tsv, false).byte_records().collect::<Result<_, _>>().map_err(err)
}

fn simd_str_records(data: &[u8], tsv: bool) -> Result<Vec<simd_csv::StringRecord>, String> {
    let mut rd = simd_reader(data, tsv);
    let mut out = Vec::new();
    loop {
        let mut rec = simd_csv::StringRecord::new();
        if !rd.read_record(&mut rec).map_err(err)? {
            return Ok(out);
        }
        out.push(rec);
    }
}

fn simd_total_records(data: &[u8], tsv: bool) -> Vec<simd_csv::ByteRecord> {
    let mut rd = simd_csv::TotalReaderBuilder::new().has_headers(false).delimiter(if tsv { b'\t' } else { b',' }).from_bytes(data);
    let mut out = Vec::new();
    let mut rec = simd_csv::ByteRecord::new();
    while rd.read_byte_record(&mut rec) {
        out.push(rec.clone());
    }
    out
}

// Reads every record as the csv crate's `StringRecord` or `ByteRecord`, touching only the field counts.
fn validate(tool: &str, how: &str, data: &[u8], tsv: bool) -> Result<(), String> {
    let (ns, _) = time_runs(|| {
        let mut n = 0u64;
        match (tool, how) {
            ("csv", "validate-str") => {
                let mut rd = csv_reader(data, tsv, false);
                let mut rec = csv::StringRecord::new();
                while rd.read_record(&mut rec).map_err(err)? {
                    n += rec.len() as u64;
                }
            }
            ("csv", "validate-bytes") => {
                let mut rd = csv_reader(data, tsv, false);
                let mut rec = csv::ByteRecord::new();
                while rd.read_byte_record(&mut rec).map_err(err)? {
                    n += rec.len() as u64;
                }
            }
            ("simd", "validate-str") => {
                let mut rd = simd_reader(data, tsv);
                let mut rec = simd_csv::StringRecord::new();
                while rd.read_record(&mut rec).map_err(err)? {
                    n += rec.len() as u64;
                }
            }
            ("simd", "validate-split") => {
                let mut sp = simd_csv::SplitterBuilder::new().has_headers(false).delimiter(if tsv { b'\t' } else { b',' }).from_reader(data);
                n = sp.count_records().map_err(err)?;
            }
            _ => return Err(format!("unknown arm {tool} {how}")),
        }
        Ok(black_box(n))
    })?;
    report(data.len(), ns, "");
    Ok(())
}

// A pass over every record's every field.
fn records(tool: &str, how: &str, data: &[u8], tsv: bool) -> Result<(), String> {
    let (ns, t) = time_runs(|| {
        let mut t = Tally::default();
        match (tool, how) {
            ("csv", "records-str") => {
                let mut rd = csv_reader(data, tsv, false);
                let mut rec = csv::StringRecord::new();
                while rd.read_record(&mut rec).map_err(err)? {
                    t.add(rec.iter().map(str::len));
                }
            }
            ("csv", "records-bytes") => {
                let mut rd = csv_reader(data, tsv, false);
                let mut rec = csv::ByteRecord::new();
                while rd.read_byte_record(&mut rec).map_err(err)? {
                    t.add(rec.iter().map(<[u8]>::len));
                }
            }
            ("simd", "records-str") => {
                let mut rd = simd_reader(data, tsv);
                let mut rec = simd_csv::StringRecord::new();
                while rd.read_record(&mut rec).map_err(err)? {
                    t.add(rec.iter().map(str::len));
                }
            }
            ("simd", "records-total") => {
                let mut rd = simd_csv::TotalReaderBuilder::new().has_headers(false).delimiter(if tsv { b'\t' } else { b',' }).from_bytes(data);
                let mut rec = simd_csv::ByteRecord::new();
                while rd.read_byte_record(&mut rec) {
                    t.add(rec.iter().map(<[u8]>::len));
                }
            }
            _ => return Err(format!("unknown arm {tool} {how}")),
        }
        Ok(black_box(t))
    })?;
    report(data.len(), ns, &t.tokens());
    Ok(())
}

// Every record kept in memory, then every field read once, inside the clock: stury's head arm reads every cell of
// its Document, which decodes a quoted cell only when it is read.
fn dom(tool: &str, how: &str, data: &[u8], tsv: bool) -> Result<(), String> {
    let (ns, t) = match (tool, how) {
        ("csv", "dom-str") => time_runs(|| csv_str_records(data, tsv).map(|v| tally(&v, |t, r| t.add(r.iter().map(str::len)))))?,
        ("csv", "dom-bytes") => time_runs(|| csv_byte_records(data, tsv).map(|v| tally(&v, |t, r| t.add(r.iter().map(<[u8]>::len)))))?,
        ("simd", "dom-str") => time_runs(|| simd_str_records(data, tsv).map(|v| tally(&v, |t, r| t.add(r.iter().map(str::len)))))?,
        ("simd", "dom-total") => time_runs(|| Ok(tally(&simd_total_records(data, tsv), |t, r| t.add(r.iter().map(<[u8]>::len)))))?,
        _ => return Err(format!("unknown arm {tool} {how}")),
    };
    report(data.len(), ns, &t.tokens());
    Ok(())
}

fn tally<R>(records: &[R], add: impl Fn(&mut Tally, &R)) -> Tally {
    let mut t = Tally::default();
    for r in records {
        add(&mut t, r);
    }
    t
}

fn dump(path: Result<String, std::env::VarError>, bytes: impl FnOnce() -> Result<Vec<u8>, String>) -> Result<(), String> {
    match path {
        Ok(p) => std::fs::write(p, bytes()?).map_err(err),
        Err(_) => Ok(()),
    }
}

// The csv crate's serde reader into owned rows, as `Vec<T>` (stury's unmarshal also builds the whole list).
fn typed<T: DeserializeOwned + Serialize>(data: &[u8], tsv: bool) -> Result<(), String> {
    let (ns, rows) = time_runs(|| csv_reader(data, tsv, true).deserialize::<T>().collect::<Result<Vec<T>, _>>().map_err(err))?;
    dump(std::env::var("STURY_DUMP"), || serde_json::to_vec(&rows).map_err(err))?;
    report(data.len(), ns, &format!("records={}", rows.len()));
    Ok(())
}

// The csv crate's serde writer over the rows it reads from `data`, into a `Vec<u8>`.
fn marshal<T: DeserializeOwned + Serialize>(data: &[u8], tsv: bool) -> Result<(), String> {
    let rows = csv_reader(data, tsv, true).deserialize::<T>().collect::<Result<Vec<T>, _>>().map_err(err)?;
    let (ns, out) = time_runs(|| {
        let mut w = csv::WriterBuilder::new();
        if tsv {
            w.delimiter(b'\t');
        }
        let mut w = w.from_writer(Vec::new());
        for r in &rows {
            w.serialize(r).map_err(err)?;
        }
        w.into_inner().map_err(err)
    })?;
    dump(std::env::var("STURY_DUMP"), || Ok(out.clone()))?;
    report(data.len(), ns, &format!("records={} out_bytes={}", rows.len(), out.len()));
    Ok(())
}

fn run(args: &[String]) -> Result<(), String> {
    let [_, tool, job, rest @ ..] = args else {
        return Err("usage: csv_bench csv|simd JOB [SHAPE] FILE".into());
    };
    let (shape, file) = match rest {
        [file] => ("", file),
        [shape, file] => (shape.as_str(), file),
        _ => return Err("usage: csv_bench csv|simd JOB [SHAPE] FILE".into()),
    };
    let data = std::fs::read(file).map_err(err)?;
    let tsv = file.ends_with(".tsv");
    match (tool.as_str(), job.as_str(), shape) {
        (_, j, _) if j.starts_with("validate") => validate(tool, j, &data, tsv),
        (_, j, _) if j.starts_with("records") => records(tool, j, &data, tsv),
        (_, j, _) if j.starts_with("dom") => dom(tool, j, &data, tsv),
        ("csv", "typed", "table") => typed::<TableRow>(&data, tsv),
        ("csv", "typed", "text") => typed::<TextRow>(&data, tsv),
        ("csv", "marshal", "table") => marshal::<TableRow>(&data, tsv),
        ("csv", "marshal", "text") => marshal::<TextRow>(&data, tsv),
        _ => Err(format!("unknown arm {tool} {job} {shape}")),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Err(e) = timing::init() {
        eprintln!("csv_bench: {e}");
        std::process::exit(2);
    }
    if let Err(e) = run(&args) {
        eprintln!("csv_bench: {e}");
        std::process::exit(1);
    }
}
