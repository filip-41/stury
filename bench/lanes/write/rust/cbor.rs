// `write-rust doc|typed FILE ciborium|minicbor` on a CBOR fixture: each job makes WARMUP + TIMED writes of one value into a
// buffer sized once and reused. Reading the fixture into the value is outside the clock. `typed` is the logs struct
// (serde through ciborium, hand-written `Encode` through minicbor, whose derive maps fields by integer index and cannot
// write text keys), and `doc` a parsed document: ciborium's Value, or minicbor's token tape, the flat list of the
// decoder's tokens, which minicbor writes back item by item. A typed value's GB/s counts the output's bytes and a
// document's the source's. `check` is the read check of the text written, read back with ciborium outside the clock:
// in document order each value's kind tag, then a string's byte count or a number's binary64 bits, zero as +0.
use ciborium::Value;
use minicbor::{Encode, Encoder, data::Token, encode::Write};
use std::hint::black_box;

use timing::{CHECK_OFFSET, fnv_byte, fnv_u64, report, time_runs};
use typed_rust::{LogRecord, Logs};

fn read_check(v: &Value, h: &mut u64) {
    match v {
        Value::Map(m) => {
            *h = fnv_byte(*h, b'o');
            m.iter().for_each(|(_, val)| read_check(val, h));
        }
        Value::Array(a) => {
            *h = fnv_byte(*h, b'a');
            a.iter().for_each(|e| read_check(e, h));
        }
        Value::Text(s) => *h = fnv_u64(fnv_byte(*h, b's'), s.len() as u64),
        Value::Bytes(b) => *h = fnv_u64(fnv_byte(*h, b's'), b.len() as u64),
        Value::Integer(i) => number(h, i128::from(*i) as f64),
        Value::Float(x) => number(h, *x),
        Value::Bool(b) => *h = fnv_byte(*h, if *b { b't' } else { b'f' }),
        Value::Tag(_, inner) => read_check(inner, h),
        _ => *h = fnv_byte(*h, b'z'),
    }
}

fn number(h: &mut u64, x: f64) {
    *h = fnv_u64(fnv_byte(*h, b'n'), if x == 0.0 { 0 } else { x.to_bits() });
}

fn checked(out: &[u8]) -> Result<u64, String> {
    let mut rest = out;
    let v: Value = ciborium::from_reader(&mut rest).map_err(|e| e.to_string())?;
    if !rest.is_empty() {
        return Err("data after the item".into());
    }
    let mut h = CHECK_OFFSET;
    read_check(&v, &mut h);
    Ok(h)
}

struct Written<'a>(&'a Logs);

impl<C> Encode<C> for Written<'_> {
    fn encode<W: Write>(&self, e: &mut Encoder<W>, _: &mut C) -> Result<(), minicbor::encode::Error<W::Error>> {
        e.map(1)?.str("logs")?.array(self.0.logs.len() as u64)?;
        for r in &self.0.logs {
            record(e, r)?;
        }
        Ok(())
    }
}

fn record<W: Write>(e: &mut Encoder<W>, r: &LogRecord) -> Result<(), minicbor::encode::Error<W::Error>> {
    e.map(8)?
        .str("ts")?.str(&r.ts)?
        .str("level")?.str(&r.level)?
        .str("service")?.str(&r.service)?
        .str("msg")?.str(&r.msg)?
        .str("status")?.i64(r.status)?
        .str("bytes")?.i64(r.bytes)?
        .str("duration_ms")?.f64(r.duration_ms)?
        .str("id")?.str(&r.id)?;
    Ok(())
}

// Times `put`, which writes the value into the buffer, and reports the check of what it wrote.
fn lane(source: usize, basis: usize, mut put: impl FnMut(&mut Vec<u8>) -> Result<(), String>) -> Result<(), String> {
    let mut buf = Vec::with_capacity(source * 3);
    let (ns, ()) = time_runs(|| {
        buf.clear();
        put(&mut buf)?;
        black_box(&buf);
        Ok(())
    })?;
    let basis = if basis == 0 { buf.len() } else { basis };
    report(basis, ns, checked(&buf)?, &format!("out={}", buf.len()));
    Ok(())
}

pub fn run(mode: &str, data: &[u8], lib: &str) -> Result<(), String> {
    match (mode, lib) {
        ("typed", "ciborium") => {
            let v: Logs = ciborium::from_reader(data).map_err(|e| e.to_string())?;
            lane(data.len(), 0, |buf| ciborium::into_writer(&v, buf).map_err(|e| e.to_string()))
        }
        ("typed", "minicbor") => {
            let v: Logs = ciborium::from_reader(data).map_err(|e| e.to_string())?;
            lane(data.len(), 0, |buf| minicbor::encode(Written(&v), buf).map_err(|e| e.to_string()))
        }
        ("doc", "ciborium") => {
            let v: Value = ciborium::from_reader(data).map_err(|e| e.to_string())?;
            lane(data.len(), data.len(), |buf| ciborium::into_writer(&v, buf).map_err(|e| e.to_string()))
        }
        ("doc", "minicbor") => {
            let tape = minicbor::Decoder::new(data).tokens().collect::<Result<Vec<Token>, _>>().map_err(|e| e.to_string())?;
            lane(data.len(), data.len(), |buf| {
                let mut e = Encoder::new(buf);
                for t in &tape {
                    e.encode(t).map_err(|e| e.to_string())?;
                }
                Ok(())
            })
        }
        _ => Err(format!("no write job {mode} {lib}")),
    }
}
