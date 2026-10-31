// Timing jobs for doc.py. Each job makes WARMUP + RUNS parses of one input and prints the median as key=value
// tokens. File I/O and dropping each decoded value are outside the clock.
//   read sonic dom FILE             sonic_rs::Value
//   read sonic sonic_dom_read FILE  sonic_rs::Value, then a visit of every value
//   read sonic sonic_key FILE       one .get of the first key in every object
use std::hint::black_box;

#[path = "../timing.rs"]
mod timing;
use timing::{report, time_runs};

// The checksum every arm of a lane prints, so the runner can refuse a fixture whose arms disagree.
const CHECK_OFFSET: u64 = 14695981039346656037;
const CHECK_PRIME: u64 = 1099511628211;

fn fnv_byte(h: u64, b: u8) -> u64 {
    (h ^ u64::from(b)).wrapping_mul(CHECK_PRIME)
}

fn fnv_bytes(h: u64, p: &[u8]) -> u64 {
    p.iter().fold(h, |h, &b| fnv_byte(h, b))
}

fn fnv_u64(h: u64, v: u64) -> u64 {
    (0..8).fold(h, |h, i| fnv_byte(h, (v >> (8 * i)) as u8))
}

// Parses one sonic_rs::Value. The input is black-boxed inside the clock, as the other arms do.
fn parse(data: &[u8]) -> Result<sonic_rs::Value, String> {
    let data = black_box(data);
    let v = sonic_rs::from_slice::<sonic_rs::Value>(data).map_err(|e| e.to_string())?;
    black_box(&v);
    Ok(v)
}

// The build lane's check: the node count, then each node's kind tag and role in document order. A key is a node of
// role `.Key`, as next's document has it.
fn summary_count(v: &sonic_rs::Value) -> u64 {
    use sonic_rs::{JsonContainerTrait, JsonValueTrait};
    match v.get_type() {
        sonic_rs::JsonType::Array => {
            1 + v.as_array().map(|a| a.iter().map(summary_count).sum::<u64>()).unwrap_or(0)
        }
        sonic_rs::JsonType::Object => {
            1 + v.as_object()
                .map(|o| o.iter().map(|(_, val)| 1 + summary_count(val)).sum::<u64>())
                .unwrap_or(0)
        }
        _ => 1,
    }
}

fn summary_hash(v: &sonic_rs::Value, h: &mut u64) {
    use sonic_rs::{JsonContainerTrait, JsonValueTrait};
    match v.get_type() {
        sonic_rs::JsonType::Array => {
            *h = fnv_byte(*h, b'a');
            *h = fnv_byte(*h, 0);
            if let Some(a) = v.as_array() {
                for e in a {
                    summary_hash(e, h);
                }
            }
        }
        sonic_rs::JsonType::Object => {
            *h = fnv_byte(*h, b'o');
            *h = fnv_byte(*h, 0);
            if let Some(o) = v.as_object() {
                for (_k, val) in o {
                    *h = fnv_byte(*h, b's');
                    *h = fnv_byte(*h, 1);
                    summary_hash(val, h);
                }
            }
        }
        sonic_rs::JsonType::String => {
            *h = fnv_byte(*h, b's');
            *h = fnv_byte(*h, 0);
        }
        sonic_rs::JsonType::Number => {
            *h = fnv_byte(*h, b'n');
            *h = fnv_byte(*h, 0);
        }
        sonic_rs::JsonType::Boolean => {
            *h = fnv_byte(*h, if v.as_bool().unwrap_or(false) { b't' } else { b'f' });
            *h = fnv_byte(*h, 0);
        }
        sonic_rs::JsonType::Null => {
            *h = fnv_byte(*h, b'z');
            *h = fnv_byte(*h, 0);
        }
    }
}

fn summary(v: &sonic_rs::Value) -> u64 {
    let mut h = fnv_u64(CHECK_OFFSET, summary_count(v));
    summary_hash(v, &mut h);
    h
}

fn dom(data: &[u8]) -> Result<(), String> {
    let (ns, _) = time_runs(|| parse(data))?;
    // The check is work outside the clock, on a fresh parse.
    let v = parse(data)?;
    report(data.len(), ns, &format!("check={}", summary(&v)));
    Ok(())
}

// What one DOM read's visit saw. `sum` keeps every string's length and every number's value in one accumulator
// so the visit cannot be optimized away, and `check` is the checksum the runner compares.
#[derive(Clone, Copy, Default)]
struct VisitCounts {
    sum: f64,
    check: u64,
}

// Touches the first byte of a string.
fn touch_first(s: &str) {
    if let Some(b) = s.as_bytes().first() {
        black_box(*b);
    }
}

// Visits every value of a sonic_rs::Value. A string adds its length to the sum and touches its first byte, a
// number is read as its own type and added, bools and nulls are noted, and containers are walked in document
// order. Keys are not values, so the visit skips them and the key lane looks them up. `HASH` true is the untimed
// check, which also folds each value's tag, then its text length or its number bits.
fn visit_sonic<const HASH: bool>(v: &sonic_rs::Value, c: &mut VisitCounts) {
    use sonic_rs::{JsonContainerTrait, JsonValueTrait};
    match v.get_type() {
        sonic_rs::JsonType::String => {
            let s = v.as_str().unwrap_or("");
            if HASH {
                c.check = fnv_byte(c.check, b's');
                c.check = fnv_u64(c.check, s.len() as u64);
            }
            c.sum += s.len() as f64;
            touch_first(s);
        }
        sonic_rs::JsonType::Number => {
            if HASH {
                c.check = fnv_byte(c.check, b'n');
            }
            // The raw text parses to the binary64 the other arms hold, sign of zero included.
            let x = v
                .as_raw_number()
                .and_then(|raw| raw.as_str().parse::<f64>().ok())
                .or_else(|| v.as_f64())
                .unwrap_or(0.0);
            c.sum += x;
            if HASH {
                // Zero folds as +0, since this reader keeps no sign on it.
                c.check = fnv_u64(c.check, if x == 0.0 { 0 } else { x.to_bits() });
            }
        }
        sonic_rs::JsonType::Array => {
            if HASH {
                c.check = fnv_byte(c.check, b'a');
            }
            if let Some(a) = v.as_array() {
                for e in a {
                    visit_sonic::<HASH>(e, c);
                }
            }
        }
        sonic_rs::JsonType::Object => {
            if HASH {
                c.check = fnv_byte(c.check, b'o');
            }
            if let Some(o) = v.as_object() {
                for (_k, val) in o {
                    visit_sonic::<HASH>(val, c);
                }
            }
        }
        sonic_rs::JsonType::Boolean => {
            if HASH {
                c.check = fnv_byte(c.check, if v.as_bool().unwrap_or(false) { b't' } else { b'f' });
            }
        }
        sonic_rs::JsonType::Null => {
            if HASH {
                c.check = fnv_byte(c.check, b'z');
            }
        }
    }
}

// Times a parse plus a visit of every value, per run.
fn dom_read(data: &[u8]) -> Result<(), String> {
    let (ns, _) = time_runs(|| {
        let v = parse(data)?;
        let mut c = VisitCounts::default();
        visit_sonic::<false>(&v, &mut c);
        black_box(&c);
        Ok(())
    })?;
    // The check is work outside the clock, on a fresh parse.
    let v = parse(data)?;
    let mut c = VisitCounts::default();
    c.check = CHECK_OFFSET;
    visit_sonic::<true>(&v, &mut c);
    report(data.len(), ns, &format!("check={}", c.check));
    Ok(())
}

// The first object in document order, as docprobe's `key` lane finds the document's first Map node.
fn first_object(v: &sonic_rs::Value) -> Option<&sonic_rs::Object> {
    use sonic_rs::{JsonContainerTrait, JsonValueTrait};
    match v.get_type() {
        sonic_rs::JsonType::Object => v.as_object(),
        sonic_rs::JsonType::Array => {
            if let Some(a) = v.as_array() {
                for e in a {
                    if let Some(o) = first_object(e) {
                        return Some(o);
                    }
                }
            }
            None
        }
        _ => None,
    }
}

// The `key` lane's work: one `.get` of `key` in every object, then every member's value. `Object` keeps
// duplicate keys, and `get` answers the first of them, as the other peers' lookups do.
fn key_walk(v: &sonic_rs::Value, key: &str, answers: &mut usize, objects: &mut usize) {
    use sonic_rs::{JsonContainerTrait, JsonValueTrait};
    match v.get_type() {
        sonic_rs::JsonType::Array => {
            if let Some(a) = v.as_array() {
                for e in a {
                    key_walk(e, key, answers, objects);
                }
            }
        }
        sonic_rs::JsonType::Object => {
            if let Some(o) = v.as_object() {
                *objects += 1;
                if o.get(&key).is_some() {
                    *answers += 1;
                }
                for (_k, val) in o {
                    key_walk(val, key, answers, objects);
                }
            }
        }
        _ => {}
    }
}

// Times a sonic-rs Value parse plus the key lane: the first object's first key, then one `.get` of it per
// object. The key is taken from the Value the lane itself parsed.
fn key_job(data: &[u8]) -> Result<(), String> {
    let (ns, (answers, objects, key)) = time_runs(|| {
        let v = parse(data)?;
        let mut answers = 0;
        let mut objects = 0;
        // No object, or an object with no members: the lane has no key to look up.
        let key = first_object(&v)
            .and_then(|obj| obj.iter().next().map(|(k, _)| k.to_string()))
            .unwrap_or_default();
        if !key.is_empty() {
            key_walk(&v, &key, &mut answers, &mut objects);
        }
        black_box(&answers);
        Ok((answers, objects, key))
    })?;
    let chk = fnv_u64(fnv_u64(fnv_bytes(CHECK_OFFSET, key.as_bytes()), answers as u64), objects as u64);
    report(
        data.len(),
        ns,
        &format!("check={} answers={} objects={} key={}", chk, answers, objects, key),
    );
    Ok(())
}

fn run(args: &[String]) -> Result<(), String> {
    if args.get(1).map(String::as_str) != Some("sonic") {
        return Err("TOOL is sonic".into());
    }
    let job = args.get(2).map(String::as_str).unwrap_or("");
    let file = args.get(3).ok_or("missing FILE")?;
    let data = std::fs::read(file).map_err(|e| e.to_string())?;
    match job {
        "dom" => dom(&data),
        "sonic_dom_read" => dom_read(&data),
        "sonic_key" => key_job(&data),
        _ => Err(format!("unknown job {job}")),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Err(e) = run(&args) {
        eprintln!("read: {e}");
        std::process::exit(1);
    }
}
