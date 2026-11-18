// `paths-rust-xml FILE PATH first|last`: quick-xml's events up to the first element PATH names, or to the end of the text for
// the last one, and the decoded text of that element. PATH names elements from the root, as `.logs.log.id`. The check is
// the FNV-1a of the answer's text then a newline. quick-xml checks the nesting of tags and no more, so this arm is not
// validating.
use std::hint::black_box;

use quick_xml::{Reader, events::Event};
use timing::{CHECK_OFFSET, fnv_byte, fnv_bytes, report, time_runs};

// Appends the text an event gives to `out`, decoded.
fn push_text(out: &mut String, ev: &Event) -> Result<(), String> {
    match ev {
        Event::Text(t) => out.push_str(&t.xml10_content()),
        Event::CData(c) => out.push_str(&c.xml10_content()),
        Event::GeneralRef(r) => match r.resolve_char_ref().map_err(|e| e.to_string())? {
            Some(c) => out.push(c),
            None => match r.as_ref() {
                "lt" => out.push('<'),
                "gt" => out.push('>'),
                "amp" => out.push('&'),
                "quot" => out.push('"'),
                "apos" => out.push('\''),
                _ => {}
            },
        },
        _ => {}
    }
    Ok(())
}

// Reads to the first element at `path`, or to the end of the text and keeps the last, and returns its text.
fn pull(data: &[u8], path: &[&str], last: bool) -> Result<Option<String>, String> {
    let text = std::str::from_utf8(black_box(data)).map_err(|e| e.to_string())?;
    let mut reader = Reader::from_str(text);
    let mut depth = 0;
    // The depth of the first open element that is not the path's, or none.
    let mut off_path: Option<usize> = None;
    // The depth of the element being read, whose text is in `current`.
    let mut reading: Option<usize> = None;
    let mut current = String::new();
    let mut answer: Option<String> = None;
    loop {
        let ev = reader.read_event().map_err(|e| e.to_string())?;
        match &ev {
            Event::Start(e) | Event::Empty(e) => {
                depth += 1;
                if off_path.is_none() && (depth > path.len() || e.name().as_ref() != path[depth - 1]) {
                    off_path = Some(depth);
                }
                if off_path.is_none() && depth == path.len() {
                    reading = Some(depth);
                    current.clear();
                }
            }
            Event::End(_) => {
                if reading == Some(depth) {
                    reading = None;
                    std::mem::swap(answer.get_or_insert_with(String::new), &mut current);
                    if !last {
                        return Ok(answer);
                    }
                }
                if off_path == Some(depth) {
                    off_path = None;
                }
                depth -= 1;
            }
            Event::Eof => return Ok(answer),
            _ if reading == Some(depth) => push_text(&mut current, &ev)?,
            _ => {}
        }
        if matches!(ev, Event::Empty(_)) {
            // An empty element opens and closes at once.
            if reading == Some(depth) {
                reading = None;
                std::mem::swap(answer.get_or_insert_with(String::new), &mut current);
                if !last {
                    return Ok(answer);
                }
            }
            if off_path == Some(depth) {
                off_path = None;
            }
            depth -= 1;
        }
    }
}

fn run(args: &[String]) -> Result<(), String> {
    let [_, file, path, dups] = &args[..] else {
        return Err("usage: paths-rust-xml FILE PATH first|last".into());
    };
    let data = std::fs::read(file).map_err(|e| e.to_string())?;
    let names: Vec<&str> = path.split('.').filter(|s| !s.is_empty()).collect();
    let (ns, answer) = time_runs(|| pull(&data, &names, dups == "last"))?;
    let text = answer.ok_or("no answer")?;
    report(data.len(), ns, fnv_byte(fnv_bytes(CHECK_OFFSET, text.as_bytes()), b'\n'), "");
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Err(e) = run(&args) {
        eprintln!("paths-rust-xml: {e}");
        std::process::exit(1);
    }
}
