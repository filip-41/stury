// `doc-rust build|read|key FILE ciborium|minicbor`: the CBOR text as a ciborium::Value or as a tree of minicbor's decoder,
// then nothing, a visit of every value, or one lookup of the first key in every object. Both readers judge UTF-8 and the
// structure, and the text must end with the item. File I/O and dropping each tree are outside the clock.
use std::borrow::Cow;
use std::hint::black_box;

use minicbor::data::Type;
use timing::{CHECK_OFFSET, fnv_byte, fnv_bytes, fnv_u64, report, time_runs};

const MAX_DEPTH: usize = 512;

// What a tree node is, as the check folds it. A byte string counts as a string of its payload and a tag as its content.
enum Shape<'a, N> {
    Map(&'a [(N, N)]),
    Array(&'a [N]),
    Text(&'a str),
    Bytes(usize),
    Number(f64),
    Bool(bool),
    Null,
}

trait Node: Sized {
    fn shape(&self) -> Shape<'_, Self>;
}

impl Node for ciborium::Value {
    fn shape(&self) -> Shape<'_, Self> {
        use ciborium::Value as V;
        match self {
            V::Map(m) => Shape::Map(m),
            V::Array(a) => Shape::Array(a),
            V::Text(s) => Shape::Text(s),
            V::Bytes(b) => Shape::Bytes(b.len()),
            V::Integer(i) => Shape::Number(i128::from(*i) as f64),
            V::Float(f) => Shape::Number(*f),
            V::Bool(b) => Shape::Bool(*b),
            V::Tag(_, inner) => inner.shape(),
            _ => Shape::Null,
        }
    }
}

enum Item<'b> {
    Map(Vec<(Item<'b>, Item<'b>)>),
    Array(Vec<Item<'b>>),
    Text(Cow<'b, str>),
    Bytes(usize),
    Number(f64),
    Bool(bool),
    Null,
}

impl Node for Item<'_> {
    fn shape(&self) -> Shape<'_, Self> {
        match self {
            Item::Map(m) => Shape::Map(m),
            Item::Array(a) => Shape::Array(a),
            Item::Text(s) => Shape::Text(s),
            Item::Bytes(n) => Shape::Bytes(*n),
            Item::Number(x) => Shape::Number(*x),
            Item::Bool(b) => Shape::Bool(*b),
            Item::Null => Shape::Null,
        }
    }
}

fn decode_item<'b>(d: &mut minicbor::Decoder<'b>, depth: usize) -> Result<Item<'b>, minicbor::decode::Error> {
    if depth > MAX_DEPTH {
        return Err(minicbor::decode::Error::message("nesting too deep"));
    }
    Ok(match d.datatype()? {
        Type::Bool => Item::Bool(d.bool()?),
        Type::Null | Type::Undefined => {
            d.skip()?;
            Item::Null
        }
        Type::U8 | Type::U16 | Type::U32 | Type::U64 => Item::Number(d.u64()? as f64),
        Type::I8 | Type::I16 | Type::I32 | Type::I64 => Item::Number(d.i64()? as f64),
        Type::Int => Item::Number(i128::from(d.int()?) as f64),
        Type::F16 | Type::F32 | Type::F64 => Item::Number(d.f64()?),
        Type::Bytes => Item::Bytes(d.bytes()?.len()),
        Type::BytesIndef => {
            let mut n = 0;
            for chunk in d.bytes_iter()? {
                n += chunk?.len();
            }
            Item::Bytes(n)
        }
        Type::String => Item::Text(Cow::Borrowed(d.str()?)),
        Type::StringIndef => {
            let mut s = String::new();
            for chunk in d.str_iter()? {
                s.push_str(chunk?);
            }
            Item::Text(Cow::Owned(s))
        }
        Type::Array | Type::ArrayIndef => {
            let n = d.array()?;
            let mut v = Vec::with_capacity(n.map_or(0, |n| n.min(1 << 16) as usize));
            match n {
                Some(n) => {
                    for _ in 0..n {
                        v.push(decode_item(d, depth + 1)?);
                    }
                }
                None => {
                    while d.datatype()? != Type::Break {
                        v.push(decode_item(d, depth + 1)?);
                    }
                    d.skip()?;
                }
            }
            Item::Array(v)
        }
        Type::Map | Type::MapIndef => {
            let n = d.map()?;
            let mut v = Vec::with_capacity(n.map_or(0, |n| n.min(1 << 16) as usize));
            match n {
                Some(n) => {
                    for _ in 0..n {
                        let k = decode_item(d, depth + 1)?;
                        v.push((k, decode_item(d, depth + 1)?));
                    }
                }
                None => {
                    while d.datatype()? != Type::Break {
                        let k = decode_item(d, depth + 1)?;
                        v.push((k, decode_item(d, depth + 1)?));
                    }
                    d.skip()?;
                }
            }
            Item::Map(v)
        }
        Type::Tag => {
            d.tag()?;
            decode_item(d, depth)?
        }
        t => return Err(minicbor::decode::Error::message(format!("unsupported item {t}"))),
    })
}

fn parse_minicbor(data: &[u8]) -> Result<Item<'_>, String> {
    let mut d = minicbor::Decoder::new(black_box(data));
    let v = decode_item(&mut d, 0).map_err(|e| e.to_string())?;
    if d.position() != data.len() {
        return Err("data after the item".into());
    }
    black_box(&v);
    Ok(v)
}

fn parse_ciborium(data: &[u8]) -> Result<ciborium::Value, String> {
    let mut rest = black_box(data);
    let v: ciborium::Value = ciborium::from_reader(&mut rest).map_err(|e| e.to_string())?;
    if !rest.is_empty() {
        return Err("data after the item".into());
    }
    black_box(&v);
    Ok(v)
}

// The build lane's check: the node count, then each node's kind tag and role in document order.
fn summary_count<N: Node>(v: &N) -> u64 {
    match v.shape() {
        Shape::Array(a) => 1 + a.iter().map(summary_count).sum::<u64>(),
        Shape::Map(m) => 1 + m.iter().map(|(k, val)| summary_count(k) + summary_count(val)).sum::<u64>(),
        _ => 1,
    }
}

fn tag(h: &mut u64, t: u8, role: u8) {
    *h = fnv_byte(*h, t);
    *h = fnv_byte(*h, role);
}

fn summary_hash<N: Node>(v: &N, role: u8, h: &mut u64) {
    match v.shape() {
        Shape::Array(a) => {
            tag(h, b'a', role);
            a.iter().for_each(|e| summary_hash(e, 0, h));
        }
        Shape::Map(m) => {
            tag(h, b'o', role);
            for (k, val) in m {
                summary_hash(k, 1, h);
                summary_hash(val, 0, h);
            }
        }
        Shape::Text(_) | Shape::Bytes(_) => tag(h, b's', role),
        Shape::Number(_) => tag(h, b'n', role),
        Shape::Bool(b) => tag(h, if b { b't' } else { b'f' }, role),
        Shape::Null => tag(h, b'z', role),
    }
}

fn summary<N: Node>(v: &N) -> u64 {
    let mut h = fnv_u64(CHECK_OFFSET, summary_count(v));
    summary_hash(v, 0, &mut h);
    h
}

// `HASH` true is the untimed check, which folds each value's tag, then its text length or its number bits. Keys are no
// values. Zero folds as +0.
fn visit<N: Node, const HASH: bool>(v: &N, sum: &mut f64, check: &mut u64) {
    match v.shape() {
        Shape::Text(s) => {
            if HASH {
                *check = fnv_u64(fnv_byte(*check, b's'), s.len() as u64);
            }
            *sum += s.len() as f64;
            if let Some(b) = s.as_bytes().first() {
                black_box(*b);
            }
        }
        Shape::Bytes(n) => {
            if HASH {
                *check = fnv_u64(fnv_byte(*check, b's'), n as u64);
            }
            *sum += n as f64;
        }
        Shape::Number(x) => {
            if HASH {
                *check = fnv_u64(fnv_byte(*check, b'n'), if x == 0.0 { 0 } else { x.to_bits() });
            }
            *sum += x;
        }
        Shape::Array(a) => {
            if HASH {
                *check = fnv_byte(*check, b'a');
            }
            a.iter().for_each(|e| visit::<N, HASH>(e, sum, check));
        }
        Shape::Map(m) => {
            if HASH {
                *check = fnv_byte(*check, b'o');
            }
            m.iter().for_each(|(_, val)| visit::<N, HASH>(val, sum, check));
        }
        Shape::Bool(b) => {
            if HASH {
                *check = fnv_byte(*check, if b { b't' } else { b'f' });
            }
        }
        Shape::Null => {
            if HASH {
                *check = fnv_byte(*check, b'z');
            }
        }
    }
}

fn first_object<N: Node>(v: &N) -> Option<&[(N, N)]> {
    match v.shape() {
        Shape::Map(m) => Some(m),
        Shape::Array(a) => a.iter().find_map(first_object),
        _ => None,
    }
}

fn text_of<N: Node>(v: &N) -> Option<&str> {
    match v.shape() {
        Shape::Text(s) => Some(s),
        _ => None,
    }
}

// One lookup of `key` in every object, answering the first member of that name, then every member's value.
fn key_walk<N: Node>(v: &N, key: &str, answers: &mut usize, objects: &mut usize) {
    match v.shape() {
        Shape::Array(a) => a.iter().for_each(|e| key_walk(e, key, answers, objects)),
        Shape::Map(m) => {
            *objects += 1;
            if m.iter().any(|(k, _)| text_of(k) == Some(key)) {
                *answers += 1;
            }
            m.iter().for_each(|(_, val)| key_walk(val, key, answers, objects));
        }
        _ => {}
    }
}

fn job<'d, N: Node>(lane: &str, data: &'d [u8], parse: impl Fn(&'d [u8]) -> Result<N, String>) -> Result<(), String> {
    match lane {
        "build" => {
            let (ns, _) = time_runs(|| parse(data))?;
            report(data.len(), ns, summary(&parse(data)?), "");
        }
        "read" => {
            let (ns, _) = time_runs(|| {
                let v = parse(data)?;
                let (mut sum, mut check) = (0.0, 0);
                visit::<N, false>(&v, &mut sum, &mut check);
                black_box(&sum);
                Ok(v)
            })?;
            let v = parse(data)?;
            let (mut sum, mut check) = (0.0, CHECK_OFFSET);
            visit::<N, true>(&v, &mut sum, &mut check);
            report(data.len(), ns, check, "");
        }
        "key" => {
            let (ns, (answers, objects, key)) = time_runs(|| {
                let v = parse(data)?;
                let (mut answers, mut objects) = (0, 0);
                let key = first_object(&v)
                    .and_then(|m| m.first())
                    .and_then(|(k, _)| text_of(k))
                    .unwrap_or_default()
                    .to_owned();
                if !key.is_empty() {
                    key_walk(&v, &key, &mut answers, &mut objects);
                }
                black_box(&answers);
                Ok((answers, objects, key))
            })?;
            let chk = fnv_u64(fnv_u64(fnv_bytes(CHECK_OFFSET, key.as_bytes()), answers as u64), objects as u64);
            report(data.len(), ns, chk, &format!("answers={answers} objects={objects} key={key}"));
        }
        _ => return Err(format!("no sublane {lane}")),
    }
    Ok(())
}

pub fn run(lane: &str, data: &[u8], lib: &str) -> Result<(), String> {
    match lib {
        "ciborium" => job(lane, data, parse_ciborium),
        "minicbor" => job(lane, data, parse_minicbor),
        _ => Err(format!("no library {lib}")),
    }
}
