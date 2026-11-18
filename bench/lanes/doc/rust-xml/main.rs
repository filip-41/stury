// `doc-rust-xml roxmltree|quickxml build|read|key|validate FILE`: roxmltree's tree of the text, or quick-xml's events of it, and then
// nothing, a visit of every value, or one lookup of the root's name in every object. quick-xml builds no tree, so its build
// is the read of every event. The text is checked as UTF-8 inside the clock. quick-xml checks the nesting of tags and no
// more, so its arm is not validating.
use std::hint::black_box;

use timing::{CHECK_OFFSET, fnv_bytes, fnv_u64, report, time_runs};
use xmlview::*;

// One timed job over `text`: roxmltree parses a tree and walks it with `V`, quick-xml reads the events into `V`.
fn job<V: Visitor + Default>(lib: &str, data: &[u8], walk: bool) -> Result<V, String> {
    let text = std::str::from_utf8(black_box(data)).map_err(|e| e.to_string())?;
    let mut v = V::default();
    match lib {
        "roxmltree" => {
            let doc = parse_roxmltree(text)?;
            if walk {
                walk_document(&doc, &mut v);
            }
            black_box(&doc);
        }
        "quickxml" => stream(text, &mut v)?,
        _ => return Err(format!("no library {lib}")),
    }
    Ok(v)
}

fn run(args: &[String]) -> Result<(), String> {
    let [_, lib, lane, file] = &args[..] else {
        return Err("usage: doc-rust-xml roxmltree|quickxml build|read|key FILE".into());
    };
    let data = std::fs::read(file).map_err(|e| e.to_string())?;
    // A quick-xml build is the stream itself, which every lane reads through the visitor of its own work.
    match lane.as_str() {
        "validate" => {
            let (ns, _) = time_runs(|| job::<Count>(lib, &data, false))?;
            report(data.len(), ns, 1, "");
        }
        "build" => {
            let (ns, _) = time_runs(|| job::<Count>(lib, &data, false))?;
            let v = job::<BuildCheck>(lib, &data, true)?;
            report(data.len(), ns, v.hash(), "");
        }
        "read" => {
            let (ns, sum) = time_runs(|| job::<Sum>(lib, &data, true))?;
            black_box(sum.0);
            let v = job::<ReadCheck>(lib, &data, true)?;
            report(data.len(), ns, v.0, "");
        }
        "key" => {
            let (ns, v) = time_runs(|| job::<KeyLookup>(lib, &data, true))?;
            let check = fnv_u64(fnv_u64(fnv_bytes(CHECK_OFFSET, &v.key), v.answers), v.objects);
            let key = String::from_utf8_lossy(&v.key);
            report(data.len(), ns, check, &format!("answers={} objects={} key={key}", v.answers, v.objects));
        }
        _ => return Err(format!("no sublane {lane}")),
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Err(e) = run(&args) {
        eprintln!("doc-rust-xml: {e}");
        std::process::exit(1);
    }
}
