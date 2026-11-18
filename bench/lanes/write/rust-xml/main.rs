// `write-rust-xml doc|typed FILE`: quick-xml's writes of the logs of logs.xml into a buffer reused across calls. `doc` writes
// the elements and texts of a roxmltree tree, parsed outside the clock, as events of `Writer`, and its GB/s counts the
// source's bytes. `typed` serializes the records, read outside the clock, through quick-xml's serde, and its GB/s counts the
// output's bytes. The check is the read check of the text written, taken outside the clock by reading it back with
// roxmltree, so a writer that keeps every value prints the check of its source.
use std::hint::black_box;

use quick_xml::{
    Writer,
    events::{BytesEnd, BytesStart, BytesText, Event},
};
use serde::{Deserialize, Serialize};
use timing::{report, time_runs};
use xmlview::{ReadCheck, parse_roxmltree, walk_document};

// The records of logs.xml. A float is written with its fraction (`396.0`), as the fixture spells it, since a text's length is
// what the read check folds and quick-xml's own spelling of a whole float (`396`) has none.
#[derive(Serialize, Deserialize)]
struct Log {
    ts: String,
    level: String,
    service: String,
    msg: String,
    status: i64,
    bytes: i64,
    #[serde(serialize_with = "with_fraction")]
    duration_ms: f64,
    id: String,
}

fn with_fraction<S: serde::Serializer>(v: &f64, s: S) -> Result<S::Ok, S::Error> {
    s.serialize_str(&format!("{v:?}"))
}

#[derive(Serialize, Deserialize)]
struct LogsXml {
    log: Vec<Log>,
}

// Writes `n` and what it holds. A text of white space alone between elements is no value of the tree stury reads, so it is
// not written. Attributes are not written: the fixture has none.
fn put_node(w: &mut Writer<&mut Vec<u8>>, n: roxmltree::Node) -> std::io::Result<()> {
    if n.is_element() {
        let name = n.tag_name().name();
        w.write_event(Event::Start(BytesStart::new(name)))?;
        for c in n.children() {
            put_node(w, c)?;
        }
        w.write_event(Event::End(BytesEnd::new(name)))
    } else if let Some(t) = n.text().filter(|_| n.is_text()) {
        let between = n.parent().is_some_and(|p| p.children().any(|c| c.is_element()));
        if between && t.bytes().all(|b| matches!(b, b' ' | b'\t' | b'\n' | b'\r')) {
            return Ok(());
        }
        w.write_event(Event::Text(BytesText::new(t)))
    } else {
        Ok(())
    }
}

fn check_of(out: &[u8]) -> Result<u64, String> {
    let text = std::str::from_utf8(out).map_err(|e| e.to_string())?;
    let doc = parse_roxmltree(text)?;
    let mut check = ReadCheck::default();
    walk_document(&doc, &mut check);
    Ok(check.0)
}

fn run(args: &[String]) -> Result<(), String> {
    let [_, mode, file] = &args[..] else {
        return Err("usage: write-rust-xml doc|typed FILE".into());
    };
    let data = std::fs::read(file).map_err(|e| e.to_string())?;
    let text = std::str::from_utf8(&data).map_err(|e| e.to_string())?;
    let mut out: Vec<u8> = Vec::with_capacity(data.len() * 2);
    let ns = match mode.as_str() {
        "doc" => {
            let doc = parse_roxmltree(text)?;
            time_runs(|| {
                out.clear();
                let mut w = Writer::new(&mut out);
                put_node(&mut w, doc.root_element()).map_err(|e| e.to_string())?;
                black_box(&w);
                Ok(())
            })?
            .0
        }
        "typed" => {
            let v: LogsXml = quick_xml::de::from_str(text).map_err(|e| e.to_string())?;
            let mut s = String::with_capacity(data.len() * 2);
            let ns = time_runs(|| {
                s.clear();
                let ser = quick_xml::se::Serializer::with_root(&mut s, Some("logs")).map_err(|e| e.to_string())?;
                v.serialize(ser).map_err(|e| e.to_string())?;
                black_box(&s);
                Ok(())
            })?
            .0;
            out = s.into_bytes();
            ns
        }
        _ => return Err(format!("no mode {mode}")),
    };
    let basis = if mode == "doc" { data.len() } else { out.len() };
    report(basis, ns, check_of(&out)?, &format!("out={}", out.len()));
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Err(e) = run(&args) {
        eprintln!("write-rust-xml: {e}");
        std::process::exit(1);
    }
}
