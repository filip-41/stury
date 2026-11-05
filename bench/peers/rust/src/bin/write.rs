// Timing jobs for write.py. Each job makes WARMUP + TIMED writes of one value into a buffer sized once and
// reused, and prints the median as key=value tokens. Reading the fixture into the value is outside the clock.
//   write LIB doc FILE [pretty]    a parsed document (LIB's Value) to text
//   write LIB typed FILE [pretty]  the fixture's struct type to text, chosen by the file's name
// LIB is `serde` (serde_json) or `sonic` (sonic-rs). A document's GB/s counts the source file's bytes and a typed
// value's counts the output's.
use serde::de::{MapAccess, Visitor};
use serde::ser::SerializeMap;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::HashMap;
use std::fmt;
use std::hint::black_box;
use std::marker::PhantomData;

#[path = "../timing.rs"]
mod timing;
use timing::{report, time_runs};

const CHECK_OFFSET: u64 = 14695981039346656037;
const CHECK_PRIME: u64 = 1099511628211;

fn fnv_bytes(p: &[u8]) -> u64 {
    p.iter().fold(CHECK_OFFSET, |h, &b| (h ^ u64::from(b)).wrapping_mul(CHECK_PRIME))
}

// A JSON object kept as a list of pairs, in source order, whatever the value type.
struct Pairs<T>(Vec<(String, T)>);

impl<T: Serialize> Serialize for Pairs<T> {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut m = s.serialize_map(Some(self.0.len()))?;
        for (k, v) in &self.0 {
            m.serialize_entry(k, v)?;
        }
        m.end()
    }
}

impl<'de, T: Deserialize<'de>> Deserialize<'de> for Pairs<T> {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V<T>(PhantomData<T>);
        impl<'de, T: Deserialize<'de>> Visitor<'de> for V<T> {
            type Value = Pairs<T>;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("an object")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut m: A) -> Result<Pairs<T>, A::Error> {
                let mut v = Vec::new();
                while let Some(e) = m.next_entry()? {
                    v.push(e);
                }
                Ok(Pairs(v))
            }
        }
        d.deserialize_map(V(PhantomData))
    }
}

// A JSON object as a hash map, whose `Serialize` sorts the keys in the timed write, as a map write in
// stury does. `Pairs` keeps an object's source order for the lanes that need it.
struct SortedMap<T>(HashMap<String, T>);

impl<T: Serialize> Serialize for SortedMap<T> {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut keys: Vec<&String> = self.0.keys().collect();
        keys.sort_unstable();
        let mut m = s.serialize_map(Some(keys.len()))?;
        for k in keys {
            m.serialize_entry(k, &self.0[k])?;
        }
        m.end()
    }
}

impl<'de, T: Deserialize<'de>> Deserialize<'de> for SortedMap<T> {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V<T>(PhantomData<T>);
        impl<'de, T: Deserialize<'de>> Visitor<'de> for V<T> {
            type Value = SortedMap<T>;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("an object")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut m: A) -> Result<SortedMap<T>, A::Error> {
                let mut map = HashMap::with_capacity(m.size_hint().unwrap_or(0));
                while let Some((k, v)) = m.next_entry()? {
                    map.insert(k, v);
                }
                Ok(SortedMap(map))
            }
        }
        d.deserialize_map(V(PhantomData))
    }
}

// The fixtures' types, with the fields the typed read keeps.
#[derive(Serialize, Deserialize)]
struct LogRecord {
    ts: String,
    level: String,
    service: String,
    msg: String,
    status: i64,
    bytes: i64,
    duration_ms: f64,
    id: String,
}

#[derive(Serialize, Deserialize)]
struct Logs {
    logs: Vec<LogRecord>,
}

#[derive(Serialize, Deserialize)]
struct TweetMetadata {
    result_type: String,
    iso_language_code: String,
}

#[derive(Serialize, Deserialize)]
struct TwitterUser {
    id: i64,
    id_str: String,
    name: String,
    screen_name: String,
    location: String,
    description: String,
    created_at: String,
    followers_count: i64,
    friends_count: i64,
    listed_count: i64,
    favourites_count: i64,
    statuses_count: i64,
    lang: String,
    verified: bool,
    protected: bool,
}

#[derive(Serialize, Deserialize)]
struct Tweet {
    metadata: TweetMetadata,
    created_at: String,
    id: i64,
    id_str: String,
    text: String,
    source: String,
    truncated: bool,
    retweet_count: i64,
    favorite_count: i64,
    lang: String,
    user: TwitterUser,
}

#[derive(Serialize, Deserialize)]
struct Twitter {
    statuses: Vec<Tweet>,
}

#[derive(Serialize, Deserialize)]
#[allow(non_snake_case)]
struct CitmEvent {
    id: i64,
    name: String,
    subTopicIds: Vec<i64>,
    topicIds: Vec<i64>,
}

#[derive(Serialize, Deserialize)]
#[allow(non_snake_case)]
struct CitmPrice {
    amount: i64,
    audienceSubCategoryId: i64,
    seatCategoryId: i64,
}

#[derive(Serialize, Deserialize)]
#[allow(non_snake_case)]
struct CitmPerf {
    eventId: i64,
    id: i64,
    start: i64,
    venueCode: String,
    prices: Vec<CitmPrice>,
}

#[derive(Serialize, Deserialize)]
#[allow(non_snake_case)]
struct Citm {
    areaNames: Pairs<String>,
    blockNames: Pairs<String>,
    events: Pairs<CitmEvent>,
    performances: Vec<CitmPerf>,
    topicSubTopics: Pairs<Vec<i64>>,
    venueNames: Pairs<String>,
}

#[derive(Serialize, Deserialize)]
struct CanadaGeo {
    r#type: String,
    coordinates: Vec<Vec<[f64; 2]>>,
}

#[derive(Serialize, Deserialize)]
struct CanadaFeat {
    r#type: String,
    geometry: CanadaGeo,
}

#[derive(Serialize, Deserialize)]
struct Canada {
    r#type: String,
    features: Vec<CanadaFeat>,
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
struct NestedRecord {
    id: i64,
    name: String,
    tags: Vec<i64>,
    nested: NestedInner,
    ok: bool,
}

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
    report(basis, ns, &format!("out={} check={}", buf.len(), fnv_bytes(&buf)));
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
    let [_, lib, mode, file] = &args[..4.min(args.len())] else {
        return Err("usage: write LIB doc|typed FILE [pretty]".into());
    };
    let pretty = args.get(4).map(String::as_str) == Some("pretty");
    let data = std::fs::read(file).map_err(|e| e.to_string())?;
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
                "wide" => typed::<SortedMap<i64>>(lib, pretty, &data),
                _ => Err(format!("no typed lane for {stem}")),
            }
        }
        _ => Err(format!("unknown mode {mode}")),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Err(e) = run(&args) {
        eprintln!("write: {e}");
        std::process::exit(1);
    }
}
