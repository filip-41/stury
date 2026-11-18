// The doc lane's HTML arm: html5ever's parse of the text into its `RcDom`, then nothing, a visit of every value, or the
// root key looked up in every object. The shape each lane reads is html-shape's.
use std::hint::black_box;

use html_shape::{Count, Hash, Key, Read, document, name, parse, root};
use timing::{CHECK_OFFSET, fnv_bytes, fnv_u64, report, time_runs};

pub fn run(lane: &str, data: &[u8]) -> Result<(), String> {
    match lane {
        "build" => {
            let (ns, dom) = time_runs(|| parse(data))?;
            let mut count = Count(0);
            let root = root(&dom)?;
            document(&root, &mut count);
            let mut hash = Hash(fnv_u64(CHECK_OFFSET, count.0));
            document(&root, &mut hash);
            report(data.len(), ns, hash.0, "");
        }
        "read" => {
            let (ns, dom) = time_runs(|| {
                let dom = parse(data)?;
                let mut read = Read::<false> { check: CHECK_OFFSET, sum: 0.0 };
                document(&root(&dom)?, &mut read);
                black_box(&read.sum);
                Ok(dom)
            })?;
            let mut read = Read::<true> { check: CHECK_OFFSET, sum: 0.0 };
            document(&root(&dom)?, &mut read);
            report(data.len(), ns, read.check, "");
        }
        "key" => {
            let (ns, (_, answers, objects, key)) = time_runs(|| {
                let dom = parse(data)?;
                let top = root(&dom)?;
                let key = name(&top);
                let mut k = Key { key: &key, objects: 0, answers: 0, counted: Vec::new() };
                document(&top, &mut k);
                let (answers, objects) = (k.answers, k.objects);
                black_box(&answers);
                Ok((dom, answers, objects, key))
            })?;
            let chk = fnv_u64(fnv_u64(fnv_bytes(CHECK_OFFSET, key.as_bytes()), answers), objects);
            report(data.len(), ns, chk, &format!("answers={answers} objects={objects} key={key}"));
        }
        _ => return Err(format!("no sublane {lane}")),
    }
    Ok(())
}
