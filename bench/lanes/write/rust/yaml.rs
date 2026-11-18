// `write-rust doc|typed FILE yaml`: serde_yaml_ng's `to_writer` into one buffer that keeps its capacity across calls. `doc`
// writes a `serde_yaml_ng::Value` the fixture parses to and its GB/s counts the source's bytes. `typed` writes the logs
// struct and its GB/s counts the output's. Reading the fixture is outside the clock. The check is the read check of the
// text written, read back by serde_yaml_ng outside the clock, since a writer spells a value its own way.
use std::hint::black_box;

use serde::Serialize;
use serde_yaml_ng::Value;
use timing::{CHECK_OFFSET, fnv_byte, fnv_u64, report, time_runs};
use typed_rust::Logs;

// Each value's kind tag in document order, then a string's byte count or a number's binary64 bits, zero as +0.
fn fold(v: &Value, h: &mut u64) {
    match v {
        Value::Null => *h = fnv_byte(*h, b'z'),
        Value::Bool(b) => *h = fnv_byte(*h, if *b { b't' } else { b'f' }),
        Value::Number(n) => {
            let d = n.as_f64().unwrap_or(0.0);
            *h = fnv_u64(fnv_byte(*h, b'n'), if d == 0.0 || d.is_infinite() { 0 } else { d.to_bits() });
        }
        Value::String(s) => *h = fnv_u64(fnv_byte(*h, b's'), s.len() as u64),
        Value::Sequence(a) => {
            *h = fnv_byte(*h, b'a');
            a.iter().for_each(|e| fold(e, h));
        }
        Value::Mapping(m) => {
            *h = fnv_byte(*h, b'o');
            m.iter().for_each(|(_, e)| fold(e, h));
        }
        Value::Tagged(t) => fold(&t.value, h),
    }
}

fn read_check(text: &[u8]) -> Result<u64, String> {
    let v: Value = serde_yaml_ng::from_slice(text).map_err(|e| e.to_string())?;
    let mut h = CHECK_OFFSET;
    fold(&v, &mut h);
    Ok(h)
}

fn lane<T: Serialize>(v: &T, basis: usize, cap: usize) -> Result<(), String> {
    let mut buf: Vec<u8> = Vec::with_capacity(cap);
    let (ns, ()) = time_runs(|| {
        buf.clear();
        serde_yaml_ng::to_writer(&mut buf, black_box(v)).map_err(|e| e.to_string())?;
        black_box(&buf);
        Ok(())
    })?;
    let basis = if basis == 0 { buf.len() } else { basis };
    report(basis, ns, read_check(&buf)?, &format!("out={}", buf.len()));
    Ok(())
}

pub fn run(args: &[String]) -> Result<(), String> {
    let [_, mode, file, _] = args else {
        return Err("usage: write-rust doc|typed FILE yaml".into());
    };
    let data = std::fs::read(file).map_err(|e| e.to_string())?;
    match mode.as_str() {
        "typed" => {
            let v: Logs = serde_yaml_ng::from_slice(&data).map_err(|e| e.to_string())?;
            lane(&v, 0, data.len() * 3)
        }
        "doc" => {
            let v: Value = serde_yaml_ng::from_slice(&data).map_err(|e| e.to_string())?;
            lane(&v, data.len(), data.len() * 3)
        }
        _ => Err(format!("unknown mode {mode}")),
    }
}
