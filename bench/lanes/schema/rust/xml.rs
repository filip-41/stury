// `schema-rust-xml verdict|errors FILE SCHEMA jsonschema`: each job makes WARMUP + TIMED passes, each parsing the XML text of FILE
// with roxmltree into the value a reader of XML gives and judging it with jsonschema, then dropping it. In that value an
// element with no child element is its text as a string (null when empty), an element with child elements an object of
// its children, a name that repeats among them an array, and a text between children with a character other than white
// space a `#text` member. Attributes are not read. `check` is the number of instances accepted and `errors` the errors listed.
// BENCH_PASSES=N makes N untimed passes and prints `check` alone. BENCH_VERDICTS=PATH writes one 0 or 1 per instance.
use std::hint::black_box;

use serde_json::{Map, Value};
use timing::{report, time_runs};

fn text_of(e: roxmltree::Node) -> String {
    e.children().filter(|c| c.is_text()).filter_map(|c| c.text()).collect()
}

// Adds `v` under `name`, making the member an array at its second value.
fn add(members: &mut Map<String, Value>, name: &str, v: Value) {
    match members.get_mut(name) {
        None => {
            members.insert(name.to_string(), v);
        }
        Some(Value::Array(items)) => items.push(v),
        Some(first) => {
            let first = first.take();
            members.insert(name.to_string(), Value::Array(vec![first, v]));
        }
    }
}

// The value of an element. No value is an array, so an array under a name is a repeat of it.
fn value_of(e: roxmltree::Node) -> Value {
    if !e.children().any(|c| c.is_element()) {
        let t = text_of(e);
        return if t.is_empty() { Value::Null } else { Value::String(t) };
    }
    let mut members = Map::new();
    let mut run = String::new();
    let flush = |run: &mut String, members: &mut Map<String, Value>| {
        if run.bytes().any(|b| !matches!(b, b' ' | b'\t' | b'\n' | b'\r')) {
            add(members, "#text", Value::String(std::mem::take(run)));
        }
        run.clear();
    };
    for c in e.children() {
        if c.is_element() {
            flush(&mut run, &mut members);
            add(&mut members, c.tag_name().name(), value_of(c));
        } else if let Some(t) = c.text().filter(|_| c.is_text()) {
            run.push_str(t);
        }
    }
    flush(&mut run, &mut members);
    Value::Object(members)
}

fn instance_of(text: &str) -> Result<Value, String> {
    let options = roxmltree::ParsingOptions { allow_dtd: true, ..Default::default() };
    let doc = roxmltree::Document::parse_with_options(black_box(text), options).map_err(|e| e.to_string())?;
    let root = doc.root_element();
    let mut members = Map::new();
    members.insert(root.tag_name().name().to_string(), value_of(root));
    Ok(Value::Object(members))
}

fn run(args: &[String]) -> Result<(), String> {
    let [_, job, file, schema_path, lib] = &args[..] else {
        return Err("usage: schema-rust-xml verdict|errors FILE SCHEMA jsonschema".into());
    };
    if lib != "jsonschema" {
        return Err(format!("no library {lib}"));
    }
    let schema: Value = serde_json::from_str(&std::fs::read_to_string(schema_path).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    let judge = jsonschema::validator_for(&schema).map_err(|e| e.to_string())?;
    let text = std::fs::read_to_string(file).map_err(|e| e.to_string())?;
    let all_errors = match job.as_str() {
        "verdict" => false,
        "errors" => true,
        _ => return Err(format!("no job {job}")),
    };
    let pass = || -> Result<(u64, usize), String> {
        let instance = instance_of(&text)?;
        if all_errors {
            let n = judge.iter_errors(&instance).count();
            Ok(((n == 0) as u64, n))
        } else {
            Ok((judge.is_valid(&instance) as u64, 0))
        }
    };
    if let Some(path) = std::env::var_os("BENCH_VERDICTS") {
        std::fs::write(path, if judge.is_valid(&instance_of(&text)?) { "1" } else { "0" }).map_err(|e| e.to_string())?;
    }
    if let Some(passes) = std::env::var("BENCH_PASSES").ok().and_then(|p| p.parse::<usize>().ok()) {
        let mut valid = 0;
        for _ in 0..passes {
            valid = pass()?.0;
        }
        println!("check={valid}");
        return Ok(());
    }
    let (ns, (valid, errors)) = time_runs(pass)?;
    report(text.len(), ns, valid, &format!("errors={errors}"));
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Err(e) = run(&args) {
        eprintln!("schema-rust-xml: {e}");
        std::process::exit(1);
    }
}
