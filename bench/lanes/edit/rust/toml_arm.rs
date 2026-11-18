// `edit-rust set FILE EDITS`: toml_edit's `DocumentMut` of a `.toml` file with EDITS of its string, integer and float values
// replaced by the integer 0 and the document written back as text, which keeps every byte the edits do not touch. The
// edited values are spread over the file as the stury probe spreads them. Parsing the file and finding each value's path
// are outside the clock, and the clock holds the edits and the write. GB/s is the best of three of those, over the
// source's bytes, and `check` the FNV-1a of the text written.
use std::time::Instant;

use timing::{CHECK_OFFSET, fnv_bytes, report};
use toml_edit::{DocumentMut, Item, Value};

#[derive(Clone)]
enum Step {
    Key(String),
    Index(usize),
}

fn is_scalar(v: &Value) -> bool {
    matches!(v, Value::String(_) | Value::Integer(_) | Value::Float(_))
}

fn paths_in_value(v: &Value, at: &mut Vec<Step>, out: &mut Vec<Vec<Step>>) {
    match v {
        Value::Array(a) => {
            for (i, e) in a.iter().enumerate() {
                at.push(Step::Index(i));
                paths_in_value(e, at, out);
                at.pop();
            }
        }
        Value::InlineTable(t) => {
            for (k, e) in t.iter() {
                at.push(Step::Key(k.to_string()));
                paths_in_value(e, at, out);
                at.pop();
            }
        }
        v if is_scalar(v) => out.push(at.clone()),
        _ => {}
    }
}

// The path of every string, integer and float value in text order.
fn paths_in_item(item: &Item, at: &mut Vec<Step>, out: &mut Vec<Vec<Step>>) {
    match item {
        Item::Value(v) => paths_in_value(v, at, out),
        Item::Table(t) => {
            for (k, e) in t.iter() {
                at.push(Step::Key(k.to_string()));
                paths_in_item(e, at, out);
                at.pop();
            }
        }
        Item::ArrayOfTables(a) => {
            for (i, t) in a.iter().enumerate() {
                at.push(Step::Index(i));
                for (k, e) in t.iter() {
                    at.push(Step::Key(k.to_string()));
                    paths_in_item(e, at, out);
                    at.pop();
                }
                at.pop();
            }
        }
        Item::None => {}
    }
}

fn value_at<'a>(v: &'a mut Value, steps: &[Step]) -> Option<&'a mut Value> {
    match (steps.split_first(), v) {
        (None, v) => Some(v),
        (Some((Step::Index(i), rest)), Value::Array(a)) => value_at(a.get_mut(*i)?, rest),
        (Some((Step::Key(k), rest)), Value::InlineTable(t)) => value_at(t.get_mut(k)?, rest),
        _ => None,
    }
}

fn item_at<'a>(item: &'a mut Item, steps: &[Step]) -> Option<&'a mut Value> {
    match (steps.split_first(), item) {
        (None, Item::Value(v)) => Some(v),
        (Some((Step::Key(k), rest)), Item::Table(t)) => item_at(t.get_mut(k)?, rest),
        (Some((Step::Index(i), rest)), Item::ArrayOfTables(a)) => match rest.split_first() {
            Some((Step::Key(k), rest)) => item_at(a.get_mut(*i)?.get_mut(k)?, rest),
            _ => None,
        },
        (Some(_), Item::Value(v)) => value_at(v, steps),
        _ => None,
    }
}

pub fn run(args: &[String]) -> Result<(), String> {
    let [_, job, file, edits] = &args[..] else {
        return Err("usage: edit-rust set FILE EDITS".into());
    };
    if job != "set" {
        return Err("usage: edit-rust set FILE EDITS".into());
    }
    let src = std::fs::read_to_string(file).map_err(|e| e.to_string())?;
    let want: usize = edits.parse().map_err(|_| format!("bad edit count {edits}"))?;
    let mut targets = Vec::new();
    let first: DocumentMut = src.parse().map_err(|e: toml_edit::TomlError| e.to_string())?;
    paths_in_item(first.as_item(), &mut Vec::new(), &mut targets);
    let n = want.min(targets.len());
    let chosen: Vec<&Vec<Step>> = (0..n).map(|k| &targets[k * targets.len() / n.max(1)]).collect();
    let (mut best, mut text) = (u128::MAX, String::new());
    for _ in 0..3 {
        let mut doc: DocumentMut = src.parse().map_err(|e: toml_edit::TomlError| e.to_string())?;
        let t0 = Instant::now();
        for steps in &chosen {
            let v = item_at(doc.as_item_mut(), steps).ok_or("an edit's path is gone")?;
            let decor = v.decor().clone();
            *v = Value::from(0);
            *v.decor_mut() = decor;
        }
        let out = doc.to_string();
        best = best.min(t0.elapsed().as_nanos());
        text = out;
    }
    report(src.len(), best, fnv_bytes(CHECK_OFFSET, text.as_bytes()), "");
    Ok(())
}
