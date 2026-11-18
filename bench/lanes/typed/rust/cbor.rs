// `typed-rust logs FILE borrow|copy ciborium|minicbor`: the logs records of a CBOR text read into the fixture's struct.
// ciborium reads through serde from a reader and hands every string over owned, so both modes copy. minicbor's decoder
// borrows a string from the input in `borrow` and copies it in `copy`. The derive of minicbor maps fields by integer
// index and the fixture's keys are text, so its `Decode` is written by hand, a loop over the members that matches each
// key and skips the ones the struct does not keep.
use minicbor::{Decode, Decoder, decode::Error};
use serde::Serialize;
use std::hint::black_box;

use timing::{CHECK_OFFSET, report, time_runs};
use typed_rust::Logs;

use crate::fold;

#[derive(Serialize)]
struct Record<S> {
    ts: S,
    level: S,
    service: S,
    msg: S,
    status: i64,
    bytes: i64,
    duration_ms: f64,
    id: S,
}

#[derive(Serialize)]
struct Document<S> {
    logs: Vec<Record<S>>,
}

// Calls `member` with the decoder at the value of each member of the map the decoder is at.
fn members<'b>(d: &mut Decoder<'b>, mut member: impl FnMut(&mut Decoder<'b>, &'b str) -> Result<(), Error>) -> Result<(), Error> {
    match d.map()? {
        Some(n) => {
            for _ in 0..n {
                let key = d.str()?;
                member(d, key)?;
            }
        }
        None => {
            while d.datatype()? != minicbor::data::Type::Break {
                let key = d.str()?;
                member(d, key)?;
            }
            d.skip()?;
        }
    }
    Ok(())
}

fn missing(name: &'static str) -> Error {
    Error::message(format!("missing {name}"))
}

impl<'b, S: Decode<'b, ()>> Decode<'b, ()> for Record<S> {
    fn decode(d: &mut Decoder<'b>, _: &mut ()) -> Result<Self, Error> {
        let (mut ts, mut level, mut service, mut msg, mut id) = (None, None, None, None, None);
        let (mut status, mut bytes, mut duration_ms) = (None, None, None);
        members(d, |d, key| {
            match key {
                "ts" => ts = Some(d.decode()?),
                "level" => level = Some(d.decode()?),
                "service" => service = Some(d.decode()?),
                "msg" => msg = Some(d.decode()?),
                "status" => status = Some(d.i64()?),
                "bytes" => bytes = Some(d.i64()?),
                "duration_ms" => duration_ms = Some(d.f64()?),
                "id" => id = Some(d.decode()?),
                _ => d.skip()?,
            }
            Ok(())
        })?;
        Ok(Record {
            ts: ts.ok_or_else(|| missing("ts"))?,
            level: level.ok_or_else(|| missing("level"))?,
            service: service.ok_or_else(|| missing("service"))?,
            msg: msg.ok_or_else(|| missing("msg"))?,
            status: status.ok_or_else(|| missing("status"))?,
            bytes: bytes.ok_or_else(|| missing("bytes"))?,
            duration_ms: duration_ms.ok_or_else(|| missing("duration_ms"))?,
            id: id.ok_or_else(|| missing("id"))?,
        })
    }
}

impl<'b, S: Decode<'b, ()>> Decode<'b, ()> for Document<S> {
    fn decode(d: &mut Decoder<'b>, _: &mut ()) -> Result<Self, Error> {
        let mut logs = None;
        members(d, |d, key| {
            match key {
                "logs" => logs = Some(d.decode()?),
                _ => d.skip()?,
            }
            Ok(())
        })?;
        Ok(Document { logs: logs.ok_or_else(|| missing("logs"))? })
    }
}

fn decode_minicbor<'b, S: Decode<'b, ()>>(data: &'b [u8]) -> Result<Document<S>, String> {
    let mut d = Decoder::new(black_box(data));
    let v = d.decode::<Document<S>>().map_err(|e| e.to_string())?;
    if d.position() != data.len() {
        return Err("data after the item".into());
    }
    Ok(v)
}

fn timed<T: Serialize>(data: &[u8], read: impl FnMut() -> Result<T, String>) -> Result<(), String> {
    let (ns, v) = time_runs(read)?;
    let value = serde_json::to_value(&v).map_err(|e| e.to_string())?;
    report(data.len(), ns, fold(CHECK_OFFSET, &value), "");
    Ok(())
}

pub fn run(lane: &str, data: &[u8], mode: &str, lib: &str) -> Result<(), String> {
    if lane != "logs" {
        return Err(format!("no typed lane {lane} for CBOR"));
    }
    match (lib, mode) {
        ("ciborium", _) => timed(data, || {
            let mut rest = black_box(data);
            let v: Logs = ciborium::from_reader(&mut rest).map_err(|e| e.to_string())?;
            if !rest.is_empty() {
                return Err("data after the item".into());
            }
            Ok(v)
        }),
        ("minicbor", "borrow") => timed(data, || decode_minicbor::<&str>(data)),
        ("minicbor", "copy") => timed(data, || decode_minicbor::<String>(data)),
        _ => Err(format!("no typed job {lib} {mode}")),
    }
}
