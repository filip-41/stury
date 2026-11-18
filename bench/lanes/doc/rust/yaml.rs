// `doc-rust build|read|key FILE saphyr`: saphyr's `Yaml::load_from_str` of the text, then nothing, a visit of every value,
// or one `Mapping::get` of the first key in every mapping. saphyr resolves a plain scalar itself, by the YAML 1.2 core
// schema. The first document is the one read.
use std::borrow::Cow;
use std::hint::black_box;

use saphyr::{LoadableYamlNode, Scalar, Yaml};
use timing::{CHECK_OFFSET, fnv_byte, fnv_bytes, fnv_u64, report, time_runs};

fn parse(text: &str) -> Result<Yaml<'_>, String> {
    let text = black_box(text);
    let mut docs = Yaml::load_from_str(text).map_err(|e| e.to_string())?;
    let doc = docs.drain(..).next().ok_or("no document")?;
    black_box(&doc);
    Ok(doc)
}

// The binary64 bits a number folds as: zero as +0, and a decimal past the range of binary64 as 0.
fn number_bits(d: f64) -> u64 {
    if d == 0.0 || d.is_infinite() { 0 } else { d.to_bits() }
}

// What a visit reads of a scalar: its tag, then a string's byte count or a number's bits.
fn scalar_parts(v: &Scalar) -> (u8, u64, f64) {
    match v {
        Scalar::Null => (b'z', 0, 0.0),
        Scalar::Boolean(true) => (b't', 0, 0.0),
        Scalar::Boolean(false) => (b'f', 0, 0.0),
        Scalar::Integer(i) => (b'n', number_bits(*i as f64), *i as f64),
        Scalar::FloatingPoint(f) => (b'n', number_bits(f.0), f.0),
        Scalar::String(s) => (b's', s.len() as u64, s.len() as f64),
    }
}

fn text_of<'a>(v: &'a Yaml) -> Cow<'a, str> {
    match v {
        Yaml::Value(Scalar::String(s)) => Cow::Borrowed(s),
        Yaml::Value(Scalar::Integer(i)) => Cow::Owned(i.to_string()),
        Yaml::Value(Scalar::FloatingPoint(f)) => Cow::Owned(f.0.to_string()),
        Yaml::Value(Scalar::Boolean(b)) => Cow::Owned(b.to_string()),
        Yaml::Representation(s, _, _) => Cow::Borrowed(s),
        _ => Cow::Borrowed(""),
    }
}

// The build lane's check: the node count, then each node's kind tag and role in document order.
fn count(v: &Yaml) -> u64 {
    match v {
        Yaml::Sequence(a) => 1 + a.iter().map(count).sum::<u64>(),
        Yaml::Mapping(m) => 1 + m.iter().map(|(_, val)| 1 + count(val)).sum::<u64>(),
        _ => 1,
    }
}

fn hash(v: &Yaml, h: &mut u64) {
    match v {
        Yaml::Sequence(a) => {
            *h = fnv_byte(fnv_byte(*h, b'a'), 0);
            a.iter().for_each(|e| hash(e, h));
        }
        Yaml::Mapping(m) => {
            *h = fnv_byte(fnv_byte(*h, b'o'), 0);
            for (_, val) in m.iter() {
                *h = fnv_byte(fnv_byte(*h, b's'), 1);
                hash(val, h);
            }
        }
        Yaml::Value(s) => *h = fnv_byte(fnv_byte(*h, scalar_parts(s).0), 0),
        _ => *h = fnv_byte(fnv_byte(*h, b's'), 0),
    }
}

// The read lane: each value's tag, then a string's byte count or a number's bits. `sum` is the timed visit's
// accumulator, which keeps the reads from being optimized away.
fn visit<const HASH: bool>(v: &Yaml, h: &mut u64, sum: &mut f64) {
    match v {
        Yaml::Sequence(a) => {
            if HASH {
                *h = fnv_byte(*h, b'a');
            }
            a.iter().for_each(|e| visit::<HASH>(e, h, sum));
        }
        Yaml::Mapping(m) => {
            if HASH {
                *h = fnv_byte(*h, b'o');
            }
            m.iter().for_each(|(_, val)| visit::<HASH>(val, h, sum));
        }
        Yaml::Value(s) => {
            let (tag, bits, value) = scalar_parts(s);
            if let Scalar::String(t) = s {
                if let Some(b) = t.as_bytes().first() {
                    black_box(*b);
                }
            }
            *sum += value;
            if HASH {
                *h = fnv_byte(*h, tag);
                if tag == b's' || tag == b'n' {
                    *h = fnv_u64(*h, bits);
                }
            }
        }
        _ => {
            if HASH {
                *h = fnv_u64(fnv_byte(*h, b's'), 0);
            }
        }
    }
}

fn first_object<'a, 'i>(v: &'a Yaml<'i>) -> Option<&'a saphyr::Mapping<'i>> {
    match v {
        Yaml::Mapping(m) => Some(m),
        Yaml::Sequence(a) => a.iter().find_map(first_object),
        _ => None,
    }
}

fn key_walk(v: &Yaml, key: &Yaml, answers: &mut usize, objects: &mut usize) {
    match v {
        Yaml::Sequence(a) => a.iter().for_each(|e| key_walk(e, key, answers, objects)),
        Yaml::Mapping(m) => {
            *objects += 1;
            if m.get(key).is_some() {
                *answers += 1;
            }
            m.iter().for_each(|(_, val)| key_walk(val, key, answers, objects));
        }
        _ => {}
    }
}

fn key_job(text: &str) -> Result<(), String> {
    let (ns, (_, answers, objects, key)) = time_runs(|| {
        let v = parse(text)?;
        let (mut answers, mut objects) = (0, 0);
        let first = first_object(&v).and_then(|o| o.iter().next().map(|(k, _)| k.clone()));
        let name = first.as_ref().map(|k| text_of(k).into_owned()).unwrap_or_default();
        if let Some(k) = &first {
            key_walk(&v, k, &mut answers, &mut objects);
        }
        black_box(&answers);
        Ok((v, answers, objects, name))
    })?;
    let chk = fnv_u64(fnv_u64(fnv_bytes(CHECK_OFFSET, key.as_bytes()), answers as u64), objects as u64);
    report(text.len(), ns, chk, &format!("answers={answers} objects={objects} key={key}"));
    Ok(())
}

pub fn run(args: &[String]) -> Result<(), String> {
    let [_, lane, file, _] = args else {
        return Err("usage: doc-rust build|read|key FILE saphyr".into());
    };
    let bytes = std::fs::read(file).map_err(|e| e.to_string())?;
    let text = std::str::from_utf8(&bytes).map_err(|e| e.to_string())?;
    match lane.as_str() {
        "build" => {
            let (ns, _) = time_runs(|| parse(text))?;
            let v = parse(text)?;
            let mut h = fnv_u64(CHECK_OFFSET, count(&v));
            hash(&v, &mut h);
            report(text.len(), ns, h, "");
            Ok(())
        }
        "read" => {
            let (ns, _) = time_runs(|| {
                let v = parse(text)?;
                let (mut h, mut sum) = (0, 0.0);
                visit::<false>(&v, &mut h, &mut sum);
                black_box(&sum);
                Ok(v)
            })?;
            let v = parse(text)?;
            let (mut h, mut sum) = (CHECK_OFFSET, 0.0);
            visit::<true>(&v, &mut h, &mut sum);
            report(text.len(), ns, h, "");
            Ok(())
        }
        "key" => key_job(text),
        _ => Err(format!("no sublane {lane}")),
    }
}
