// The write lane's HTML arm: html5ever's serialization of the document parsed from the text, into a buffer reused across
// calls. The parse is outside the clock and the GB/s counts the source's bytes. The check is the read check of the output
// parsed again by html5ever (html-shape's), taken outside the clock.
use std::hint::black_box;

use html5ever::serialize::{SerializeOpts, serialize};
use html_shape::{Read, document, parse, root};
use markup5ever_rcdom::SerializableHandle;
use timing::{CHECK_OFFSET, report, time_runs};

pub fn run(data: &[u8]) -> Result<(), String> {
    let dom = parse(data)?;
    let top: SerializableHandle = dom.document.clone().into();
    let mut buf = Vec::with_capacity(data.len() * 3);
    let (ns, ()) = time_runs(|| {
        buf.clear();
        serialize(&mut buf, &top, SerializeOpts::default()).map_err(|e| e.to_string())?;
        black_box(&buf);
        Ok(())
    })?;
    let written = parse(&buf)?;
    let mut read = Read::<true> { check: CHECK_OFFSET, sum: 0.0 };
    document(&root(&written)?, &mut read);
    report(data.len(), ns, read.check, &format!("out={}", buf.len()));
    Ok(())
}
