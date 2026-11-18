// `paths-rust path FILE PATH [BATCH]`: minicbor's decoder walks the CBOR text to the value a path names (`.name` and
// `[index]` steps), decoding the keys on the way and skipping every other value, which `skip` judges as it passes.
// The text after the answer is not read. The answer is hashed as the stury probe hashes it: the value's text, then a
// newline.
use std::hint::black_box;

use minicbor::{Decoder, data::Type};
use timing::{CHECK_OFFSET, fnv_byte, fnv_bytes, report, time_batches};

enum Step<'a> {
    Key(&'a str),
    Index(u64),
}

fn steps(path: &str) -> Result<Vec<Step<'_>>, String> {
    let mut out = Vec::new();
    let mut rest = path;
    while !rest.is_empty() {
        if let Some(r) = rest.strip_prefix('.') {
            let end = r.find(['.', '[']).unwrap_or(r.len());
            out.push(Step::Key(&r[..end]));
            rest = &r[end..];
        } else if let Some(r) = rest.strip_prefix('[') {
            let end = r.find(']').ok_or("unclosed [")?;
            out.push(Step::Index(r[..end].parse().map_err(|_| "bad index")?));
            rest = &r[end + 1..];
        } else {
            return Err(format!("bad path {path}"));
        }
    }
    Ok(out)
}

type Failure = minicbor::decode::Error;

// Moves `d` to the value `step` names inside the container it is at, skipping what comes before it.
fn enter(d: &mut Decoder<'_>, step: &Step) -> Result<bool, Failure> {
    match (step, d.datatype()?) {
        (Step::Key(name), Type::Map) => {
            for _ in 0..d.map()?.unwrap_or(0) {
                if d.str()? == *name {
                    return Ok(true);
                }
                d.skip()?;
            }
            Ok(false)
        }
        (Step::Index(index), Type::Array) => {
            let len = d.array()?.unwrap_or(0);
            if *index >= len {
                return Ok(false);
            }
            for _ in 0..*index {
                d.skip()?;
            }
            Ok(true)
        }
        _ => Ok(false),
    }
}

// The text of the value the decoder is at: a string as it is, a number in decimal, true, false or null.
fn answer_text(d: &mut Decoder<'_>) -> Result<String, Failure> {
    Ok(match d.datatype()? {
        Type::String => d.str()?.to_owned(),
        Type::Bool => d.bool()?.to_string(),
        Type::Null => {
            d.null()?;
            "null".into()
        }
        Type::U8 | Type::U16 | Type::U32 | Type::U64 => d.u64()?.to_string(),
        Type::I8 | Type::I16 | Type::I32 | Type::I64 => d.i64()?.to_string(),
        t => return Err(Failure::message(format!("answer of type {t}"))),
    })
}

fn find(data: &[u8], path: &[Step]) -> Result<Option<String>, String> {
    let mut d = Decoder::new(black_box(data));
    for step in path {
        if !enter(&mut d, step).map_err(|e| e.to_string())? {
            return Ok(None);
        }
    }
    answer_text(&mut d).map(Some).map_err(|e| e.to_string())
}

pub fn run(file: &str, path: &str, batch: usize) -> Result<(), String> {
    let data = std::fs::read(file).map_err(|e| e.to_string())?;
    let path = steps(path)?;
    let (ns, answer) = time_batches(batch, || {
        let a = find(&data, &path)?;
        black_box(&a);
        Ok(a)
    })?;
    let chk = answer.map_or(CHECK_OFFSET, |a| fnv_byte(fnv_bytes(CHECK_OFFSET, a.as_bytes()), b'\n'));
    report(data.len(), ns, chk, "");
    Ok(())
}
