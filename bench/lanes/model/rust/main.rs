// `model-rust logs|twitter FILE load|dump`: FILE holds one JSON record per line, each decoded by serde_json into a struct
// whose members garde then judges, and written back by serde_json for `dump`. Every member is an `Option` whose
// `required` rule garde judges, since serde_json would end a decode at the first member a record leaves out. A refusal of
// the record lists every rule it breaks, as the other arms' `load` does. `check` is the Odin probe's: the number of
// accepted records, the sum of one number member over them, and how many records refused each member path, in path order.
// GB/s of `dump` counts the bytes written. A float written without a fraction ends `.0` here, and the check hashes it
// without, as the other arms' texts are hashed.
use garde::Validate;
use serde::{Deserialize, Serialize};
use std::hint::black_box;

use timing::{CHECK_OFFSET, fnv_bytes, fnv_u64, report, time_runs};

fn local() -> String {
    "local".into()
}

#[derive(Deserialize, Serialize, Validate)]
struct LogRecord {
    #[garde(required, pattern(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$"))]
    ts: Option<String>,
    #[garde(required, pattern(r"^(trace|debug|info|warn|error)$"))]
    level: Option<String>,
    #[garde(required, length(chars, min = 1, max = 16))]
    service: Option<String>,
    #[garde(required, length(chars, min = 1, max = 200))]
    msg: Option<String>,
    #[garde(required, range(min = 100, max = 599))]
    status: Option<i64>,
    #[garde(required, range(min = 0))]
    bytes: Option<i64>,
    #[garde(required, range(min = 0.0, max = 60000.0))]
    duration_ms: Option<f64>,
    #[garde(required, pattern(r"^req-[0-9a-f]{8}$"))]
    id: Option<String>,
    #[serde(default = "local")]
    #[garde(length(chars, max = 16))]
    region: String,
}

#[derive(Deserialize, Serialize, Validate)]
struct Metadata {
    #[garde(required, pattern(r"^(recent|popular|mixed)$"))]
    result_type: Option<String>,
    #[garde(required, pattern(r"^[a-z]{2,3}$"))]
    iso_language_code: Option<String>,
}

#[derive(Deserialize, Serialize, Validate)]
struct User {
    #[garde(required, range(min = 1))]
    id: Option<i64>,
    #[garde(required, pattern(r"^[0-9]{1,19}$"))]
    id_str: Option<String>,
    #[garde(required, length(chars, min = 1, max = 50))]
    name: Option<String>,
    #[garde(required, pattern(r"^[A-Za-z0-9_]{1,15}$"))]
    screen_name: Option<String>,
    #[garde(required, length(chars, max = 100))]
    location: Option<String>,
    #[garde(required, length(chars, max = 200))]
    description: Option<String>,
    #[garde(required, pattern(r"^[A-Z][a-z]{2} [A-Z][a-z]{2} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \+0000 [0-9]{4}$"))]
    created_at: Option<String>,
    #[garde(required, range(min = 0))]
    followers_count: Option<i64>,
    #[garde(required, range(min = 0))]
    friends_count: Option<i64>,
    #[garde(required, range(min = 0))]
    listed_count: Option<i64>,
    #[garde(required, range(min = 0))]
    favourites_count: Option<i64>,
    #[garde(required, range(min = 0))]
    statuses_count: Option<i64>,
    #[garde(required, pattern(r"^[a-z]{2}(-[a-z]{2})?$"))]
    lang: Option<String>,
    #[garde(required)]
    verified: Option<bool>,
    #[garde(required)]
    protected: Option<bool>,
}

#[derive(Deserialize, Serialize, Validate)]
struct Tweet {
    #[garde(required, dive)]
    metadata: Option<Metadata>,
    #[garde(required, pattern(r"^[A-Z][a-z]{2} [A-Z][a-z]{2} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \+0000 [0-9]{4}$"))]
    created_at: Option<String>,
    #[garde(required, range(min = 1))]
    id: Option<i64>,
    #[garde(required, pattern(r"^[0-9]{1,19}$"))]
    id_str: Option<String>,
    #[garde(required, length(chars, min = 1, max = 140))]
    text: Option<String>,
    #[garde(required, length(chars, min = 1, max = 200))]
    source: Option<String>,
    #[garde(required)]
    truncated: Option<bool>,
    #[garde(required, range(min = 0))]
    retweet_count: Option<i64>,
    #[garde(required, range(min = 0))]
    favorite_count: Option<i64>,
    #[garde(required, pattern(r"^[a-z]{2,3}$"))]
    lang: Option<String>,
    #[garde(required, dive)]
    user: Option<User>,
    #[serde(default)]
    #[garde(skip)]
    reviewed: bool,
}

trait Record: Validate<Context = ()> + for<'a> Deserialize<'a> + Serialize {
    // The number each accepted record adds to the check.
    fn tally(&self) -> u64;
}

impl Record for LogRecord {
    fn tally(&self) -> u64 {
        self.bytes.unwrap_or(0) as u64
    }
}

impl Record for Tweet {
    fn tally(&self) -> u64 {
        self.retweet_count.unwrap_or(0) as u64
    }
}

type Loaded<T> = (Vec<T>, Vec<Vec<String>>);

// Every record decoded and judged: the accepted ones, and for each refused one every member path it broke.
fn load<T: Record>(lines: &[&[u8]]) -> Result<Loaded<T>, String> {
    let mut models = Vec::new();
    let mut failed = Vec::new();
    for line in lines {
        let record: T = serde_json::from_slice(black_box(line)).map_err(|e| e.to_string())?;
        match record.validate() {
            Ok(()) => models.push(record),
            Err(report) => failed.push(report.iter().map(|(path, _)| path.to_string()).collect()),
        }
    }
    Ok((models, failed))
}

fn fold<T: Record>((models, failed): &Loaded<T>) -> u64 {
    let mut refused = std::collections::BTreeMap::new();
    for paths in failed {
        let mut once = paths.clone();
        once.sort();
        once.dedup();
        for path in once {
            *refused.entry(path).or_insert(0u64) += 1;
        }
    }
    let mut h = fnv_u64(CHECK_OFFSET, models.len() as u64);
    h = fnv_u64(h, models.iter().map(T::tally).fold(0u64, u64::wrapping_add));
    for (path, count) in refused {
        h = fnv_u64(fnv_bytes(h, path.as_bytes()), count);
    }
    h
}

// `text` without the `.0` that ends the integral number of a `"duration_ms":` member.
fn spelled(text: &[u8]) -> Vec<u8> {
    const KEY: &[u8] = b"\"duration_ms\":";
    let Some(at) = text.windows(KEY.len()).position(|w| w == KEY) else {
        return text.to_vec();
    };
    let digits = text[at + KEY.len()..].iter().take_while(|b| b.is_ascii_digit()).count();
    let end = at + KEY.len() + digits;
    let tail = &text[end..];
    if tail.starts_with(b".0") && !tail.get(2).is_some_and(u8::is_ascii_digit) {
        [&text[..end], &tail[2..]].concat()
    } else {
        text.to_vec()
    }
}

fn run<T: Record>(src: &[u8], mode: &str) -> Result<(), String> {
    let lines: Vec<&[u8]> = src.split(|&b| b == b'\n').filter(|l| !l.is_empty()).collect();
    match mode {
        "load" => {
            let (ns, loaded) = time_runs(|| load::<T>(&lines))?;
            report(src.len(), ns, fold(&loaded), "");
        }
        "dump" => {
            let (models, failed) = load::<T>(&lines)?;
            if !failed.is_empty() {
                return Err("dump needs a file every record of which loads".into());
            }
            let (ns, texts) = time_runs(|| {
                models.iter().map(|m| serde_json::to_vec(black_box(m)).map_err(|e| e.to_string())).collect::<Result<Vec<_>, _>>()
            })?;
            let written = texts.iter().map(Vec::len).sum();
            let check = texts.iter().fold(CHECK_OFFSET, |h, t| fnv_bytes(h, &spelled(t)));
            report(written, ns, check, "");
        }
        _ => return Err(format!("no mode {mode}")),
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let result = match &args[..] {
        [_, shape, file, mode] => std::fs::read(file).map_err(|e| e.to_string()).and_then(|src| match shape.as_str() {
            "logs" => run::<LogRecord>(&src, mode),
            "twitter" => run::<Tweet>(&src, mode),
            _ => Err(format!("no shape {shape}")),
        }),
        _ => Err("usage: model-rust logs|twitter FILE load|dump".into()),
    };
    if let Err(e) = result {
        eprintln!("model-rust: {e}");
        std::process::exit(1);
    }
}
