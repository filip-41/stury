// The `toml` crate's arm of the doc lane, run on a `.toml` file: `toml::Table` of the text (`from_slice`, which judges the
// UTF-8), then nothing, a visit of every value, or one `get` of the first key in every table. The crate's `fast_hash` feature
// keeps a table's members in text order. A date or time counts as a string of length 0.
use std::hint::black_box;

use timing::{CHECK_OFFSET, fnv_byte, fnv_bytes, fnv_u64, report, time_runs};
use toml::{Table, Value};

fn parse(data: &[u8]) -> Result<Value, String> {
    toml::from_slice::<Table>(black_box(data)).map(Value::Table).map_err(|e| e.to_string())
}

fn count(v: &Value) -> u64 {
    match v {
        Value::Table(t) => 1 + t.values().map(|x| 1 + count(x)).sum::<u64>(),
        Value::Array(a) => 1 + a.iter().map(count).sum::<u64>(),
        _ => 1,
    }
}

fn hash_kinds(v: &Value, h: &mut u64) {
    match v {
        Value::Table(t) => {
            *h = fnv_byte(fnv_byte(*h, b'o'), 0);
            for x in t.values() {
                *h = fnv_byte(fnv_byte(*h, b's'), 1);
                hash_kinds(x, h);
            }
        }
        Value::Array(a) => {
            *h = fnv_byte(fnv_byte(*h, b'a'), 0);
            a.iter().for_each(|x| hash_kinds(x, h));
        }
        Value::Boolean(b) => *h = fnv_byte(fnv_byte(*h, if *b { b't' } else { b'f' }), 0),
        Value::Integer(_) | Value::Float(_) => *h = fnv_byte(fnv_byte(*h, b'n'), 0),
        _ => *h = fnv_byte(fnv_byte(*h, b's'), 0),
    }
}

fn bits_of(x: f64) -> u64 {
    if x == 0.0 { 0 } else { x.to_bits() }
}

// The read check, and with `HASH` false the timed visit, which keeps each string's length and each number in `sum`.
fn visit<const HASH: bool>(v: &Value, sum: &mut f64, h: &mut u64) {
    match v {
        Value::Table(t) => {
            if HASH {
                *h = fnv_byte(*h, b'o');
            }
            t.values().for_each(|x| visit::<HASH>(x, sum, h));
        }
        Value::Array(a) => {
            if HASH {
                *h = fnv_byte(*h, b'a');
            }
            a.iter().for_each(|x| visit::<HASH>(x, sum, h));
        }
        Value::String(s) => {
            if HASH {
                *h = fnv_u64(fnv_byte(*h, b's'), s.len() as u64);
            }
            *sum += s.len() as f64;
            if let Some(b) = s.as_bytes().first() {
                black_box(*b);
            }
        }
        Value::Integer(i) => {
            if HASH {
                *h = fnv_u64(fnv_byte(*h, b'n'), bits_of(*i as f64));
            }
            *sum += *i as f64;
        }
        Value::Float(f) => {
            if HASH {
                *h = fnv_u64(fnv_byte(*h, b'n'), bits_of(*f));
            }
            *sum += *f;
        }
        Value::Boolean(b) => {
            if HASH {
                *h = fnv_byte(*h, if *b { b't' } else { b'f' });
            }
        }
        Value::Datetime(_) => {
            if HASH {
                *h = fnv_u64(fnv_byte(*h, b's'), 0);
            }
        }
    }
}

// The read check of a parsed text, which the write lane also takes of what a writer made.
pub fn read_check(v: &Value) -> u64 {
    let (mut sum, mut h) = (0.0, CHECK_OFFSET);
    visit::<true>(v, &mut sum, &mut h);
    h
}

fn key_walk(v: &Value, key: &str, answers: &mut u64, objects: &mut u64) {
    match v {
        Value::Table(t) => {
            *objects += 1;
            if t.contains_key(key) {
                *answers += 1;
            }
            t.values().for_each(|x| key_walk(x, key, answers, objects));
        }
        Value::Array(a) => a.iter().for_each(|x| key_walk(x, key, answers, objects)),
        _ => {}
    }
}

pub fn run(lane: &str, data: &[u8]) -> Result<(), String> {
    let fresh = parse(data)?;
    match lane {
        "build" => {
            let (ns, _) = time_runs(|| parse(data))?;
            let mut h = fnv_u64(CHECK_OFFSET, count(&fresh));
            hash_kinds(&fresh, &mut h);
            report(data.len(), ns, h, "");
        }
        "read" => {
            let (ns, _) = time_runs(|| {
                let v = parse(data)?;
                let (mut sum, mut h) = (0.0, 0);
                visit::<false>(&v, &mut sum, &mut h);
                black_box(sum);
                Ok(v)
            })?;
            report(data.len(), ns, read_check(&fresh), "");
        }
        "key" => {
            let key = fresh.as_table().and_then(|t| t.keys().next().cloned()).unwrap_or_default();
            let (ns, (answers, objects, _)) = time_runs(|| {
                let v = parse(data)?;
                let (mut a, mut o) = (0, 0);
                key_walk(&v, &key, &mut a, &mut o);
                black_box((a, o));
                Ok((a, o, v))
            })?;
            let chk = fnv_u64(fnv_u64(fnv_bytes(CHECK_OFFSET, key.as_bytes()), answers), objects);
            report(data.len(), ns, chk, &format!("answers={answers} objects={objects} key={key}"));
        }
        _ => return Err(format!("no sublane {lane}")),
    }
    Ok(())
}
