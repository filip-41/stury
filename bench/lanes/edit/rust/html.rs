// `edit-rust set FILE EDITS SELECTOR`: lol_html's streaming rewrite of an HTML text that sets the content of EDITS of the
// elements SELECTOR matches to `0`, spread over them as stury's edit probe spreads its sets (element k*N/EDITS of the N
// that match, in document order). The count N comes from a rewrite outside the clock. Each timed call is one rewrite of
// the whole text into a buffer reused across calls, and the check is the FNV-1a of what it wrote.
use std::hint::black_box;

use lol_html::html_content::ContentType;
use lol_html::{HtmlRewriter, Settings, element};
use timing::{CHECK_OFFSET, fnv_bytes, report, time_runs};

// One rewrite of `data` into `out`, setting the content of the elements at `targets` (ascending indexes among the matches)
// and returning how many elements matched.
fn rewrite(data: &[u8], selector: &str, targets: &[usize], out: &mut Vec<u8>) -> Result<usize, String> {
    out.clear();
    let mut seen = 0;
    let mut next = 0;
    {
        let handler = element!(selector, |el| {
            if targets.get(next) == Some(&seen) {
                el.set_inner_content("0", ContentType::Text);
                next += 1;
            }
            seen += 1;
            Ok(())
        });
        let mut rewriter = HtmlRewriter::new(
            Settings::new().append_element_content_handler(handler),
            |chunk: &[u8]| out.extend_from_slice(chunk),
        );
        rewriter.write(data).map_err(|e| e.to_string())?;
        rewriter.end().map_err(|e| e.to_string())?;
    }
    Ok(seen)
}

pub fn run(args: &[String]) -> Result<(), String> {
    let [_, mode, file, edits, selector] = &args[..] else {
        return Err("usage: edit-rust set FILE EDITS SELECTOR".into());
    };
    if mode != "set" {
        return Err("usage: edit-rust set FILE EDITS SELECTOR".into());
    }
    let data = std::fs::read(file).map_err(|e| e.to_string())?;
    let want: usize = edits.parse().map_err(|_| "EDITS is a number".to_string())?;
    let mut out = Vec::with_capacity(data.len() + data.len() / 8);
    let matched = rewrite(&data, selector, &[], &mut out)?;
    let n = want.min(matched);
    let targets: Vec<usize> = (0..n).map(|k| k * matched / n.max(1)).collect();
    let (ns, ()) = time_runs(|| {
        rewrite(black_box(&data), selector, &targets, &mut out)?;
        black_box(&out);
        Ok(())
    })?;
    report(data.len(), ns, fnv_bytes(CHECK_OFFSET, &out), &format!("matched={matched}"));
    Ok(())
}
