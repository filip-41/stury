// The paths lane's HTML arm: scraper's CSS selector over html5ever's tree, taking the first element SELECTOR matches.
// `build_select` parses the text and selects in each call, the job stury's build_query does, and `select` selects on a
// document parsed outside the clock. A sample is `batch` calls and the ns is the median sample over `batch`. The check is
// the FNV-1a of the answer's decoded text then a newline.
use std::hint::black_box;

use scraper::{Html, Selector};
use timing::{CHECK_OFFSET, fnv_byte, fnv_bytes, report, time_batches};

pub fn run(mode: &str, data: &[u8], selector: &str, batch: usize) -> Result<(), String> {
    let selector = Selector::parse(selector).map_err(|e| format!("bad selector: {e}"))?;
    let text = std::str::from_utf8(data).map_err(|e| e.to_string())?;
    let answer = |html: &Html| html.select(&selector).next().map(|e| e.text().collect::<String>());
    let ns = match mode {
        "build_select" => {
            let (ns, _) = time_batches(batch, || {
                let html = Html::parse_document(black_box(std::str::from_utf8(data).map_err(|e| e.to_string())?));
                black_box(html.select(&selector).next().map(|e| e.id()));
                Ok(html)
            })?;
            ns
        }
        "select" => {
            let html = Html::parse_document(text);
            let (ns, _) = time_batches(batch, || {
                Ok(black_box(html.select(&selector).next().map(|e| e.id())))
            })?;
            ns
        }
        _ => return Err(format!("no mode {mode}")),
    };
    let found = answer(&Html::parse_document(text)).unwrap_or_default();
    report(data.len(), ns, fnv_byte(fnv_bytes(CHECK_OFFSET, found.as_bytes()), b'\n'), "");
    Ok(())
}
