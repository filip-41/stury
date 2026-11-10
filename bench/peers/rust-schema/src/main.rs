// Timing jobs for bench/schema.py. Each job makes WARMUP + TIMED passes and prints the median as key=value tokens. Each
// parses every instance of FILE (a JSONL text, else one document) with serde_json and judges it, dropping it before the
// next. `check` is the number of instances the schema accepts and `errors` the errors listed.
//   schema jsonschema|boon verdict SCHEMA FILE   the bool form: jsonschema's is_valid, boon's validate().is_ok()
//   schema jsonschema|boon errors SCHEMA FILE    every error: jsonschema's iter_errors, boon's basic output
// BENCH_PASSES=N makes N untimed passes and prints `check` alone, for the runner's instruction counts. BENCH_VERDICTS=PATH
// writes one 0 or 1 per instance, in order, to PATH.
use std::hint::black_box;

#[path = "../../rust/src/timing.rs"]
mod timing;
use timing::{report, time_runs};

use serde_json::Value;

// The instance texts of FILE: one per line of a JSONL text, else the whole text.
fn pieces<'a>(path: &str, text: &'a str) -> Vec<&'a str> {
    if path.ends_with(".jsonl") || path.ends_with(".ndjson") {
        text.lines().filter(|l| !l.is_empty()).collect()
    } else {
        vec![text]
    }
}

// What a library does with a compiled schema.
trait Judge {
    fn accepts(&self, instance: &Value) -> bool;
    // The number of errors the library lists for the instance.
    fn errors(&self, instance: &Value) -> usize;
}

struct Jsonschema(jsonschema::Validator);

impl Judge for Jsonschema {
    fn accepts(&self, instance: &Value) -> bool {
        self.0.is_valid(instance)
    }
    fn errors(&self, instance: &Value) -> usize {
        self.0.iter_errors(instance).count()
    }
}

struct Boon {
    schemas: boon::Schemas,
    index: boon::SchemaIndex,
}

// The leaf errors under a unit of boon's basic output.
fn leaves(unit: &boon::OutputUnit) -> usize {
    match &unit.error {
        boon::OutputError::Leaf(_) => 1,
        boon::OutputError::Branch(units) => units.iter().map(leaves).sum(),
    }
}

impl Judge for Boon {
    fn accepts(&self, instance: &Value) -> bool {
        self.schemas.validate(instance, self.index).is_ok()
    }
    fn errors(&self, instance: &Value) -> usize {
        match self.schemas.validate(instance, self.index) {
            Ok(()) => 0,
            Err(e) => leaves(&e.basic_output()),
        }
    }
}

fn compile(lib: &str, text: &str) -> Result<Box<dyn Judge>, String> {
    let schema: Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
    match lib {
        "jsonschema" => Ok(Box::new(Jsonschema(jsonschema::validator_for(&schema).map_err(|e| e.to_string())?))),
        "boon" => {
            let mut schemas = boon::Schemas::new();
            let mut compiler = boon::Compiler::new();
            compiler.add_resource("file:///schema.json", schema).map_err(|e| e.to_string())?;
            let index = compiler.compile("file:///schema.json", &mut schemas).map_err(|e| e.to_string())?;
            Ok(Box::new(Boon { schemas, index }))
        }
        _ => Err(format!("no library {lib}")),
    }
}

fn run(args: &[String]) -> Result<(), String> {
    let [_, lib, job, schema_path, file] = &args[..] else {
        return Err("usage: schema jsonschema|boon verdict|errors SCHEMA FILE".into());
    };
    let judge = compile(lib, &std::fs::read_to_string(schema_path).map_err(|e| e.to_string())?)?;
    let text = std::fs::read_to_string(file).map_err(|e| e.to_string())?;
    let texts = pieces(file, &text);
    let all_errors = match job.as_str() {
        "verdict" => false,
        "errors" => true,
        _ => return Err(format!("no job {job}")),
    };
    let pass = || -> Result<(u64, usize), String> {
        let (mut valid, mut errors) = (0u64, 0usize);
        for t in &texts {
            let instance: Value = serde_json::from_str(black_box(t)).map_err(|e| e.to_string())?;
            if all_errors {
                let n = judge.errors(&instance);
                valid += (n == 0) as u64;
                errors += n;
            } else {
                valid += judge.accepts(&instance) as u64;
            }
        }
        Ok((valid, errors))
    };
    if let Some(path) = std::env::var_os("BENCH_VERDICTS") {
        let mut marks = String::with_capacity(texts.len());
        for t in &texts {
            let instance: Value = serde_json::from_str(t).map_err(|e| e.to_string())?;
            marks.push(if judge.accepts(&instance) { '1' } else { '0' });
        }
        std::fs::write(path, marks).map_err(|e| e.to_string())?;
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
    report(text.len(), ns, &format!("check={valid} errors={errors}"));
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Err(e) = run(&args) {
        eprintln!("schema: {e}");
        std::process::exit(1);
    }
}
