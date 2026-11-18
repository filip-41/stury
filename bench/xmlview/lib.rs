// The tree stury reads an XML text as, produced from roxmltree's tree or quick-xml's events, and the visitors that fold it.
// An element is a member named for it: a plain value of its text when it has no child element (empty text reads as null),
// otherwise an object holding a `#text` member for each run of text between its children that has a character other than
// white space, and each child. Attributes, comments and processing instructions are no nodes. The visitors take calls in
// the order of stury's document nodes: key, then its value (`object` to `end_object`, or `plain`).
use quick_xml::events::Event;
use timing::{CHECK_OFFSET, fnv_byte, fnv_u64};

pub trait Visitor {
    // Whether `plain` needs the decoded length of a text. A stream decodes its texts only when it does.
    const LENGTHS: bool;
    fn key(&mut self, name: &[u8]);
    fn object(&mut self);
    fn end_object(&mut self);
    fn plain(&mut self, len: usize);
}

fn is_blank(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | b'\r')
}

// The text between two children of an element, built of the text nodes the library gives for it.
#[derive(Default)]
struct Run {
    len: usize,
    text: bool,
}

impl Run {
    fn add(&mut self, len: usize, text: bool) {
        self.len += len;
        self.text |= text;
    }

    // Gives the run to `v` as a `#text` member when it has text, then clears it.
    fn flush<V: Visitor>(&mut self, v: &mut V) {
        if self.text {
            v.key(b"#text");
            v.plain(self.len);
        }
        *self = Run::default();
    }
}

// The build lane's check: the node count, then each node's kind tag and role, role 1 being a key. An empty text is null.
#[derive(Default)]
pub struct BuildCheck {
    seq: Vec<u8>,
}

impl Visitor for BuildCheck {
    const LENGTHS: bool = false;
    fn key(&mut self, _: &[u8]) {
        self.seq.extend_from_slice(b"s\x01");
    }
    fn object(&mut self) {
        self.seq.extend_from_slice(b"o\x00");
    }
    fn end_object(&mut self) {}
    fn plain(&mut self, len: usize) {
        self.seq.extend_from_slice(if len == 0 { b"z\x00" } else { b"s\x00" });
    }
}

impl BuildCheck {
    pub fn hash(&self) -> u64 {
        let h = fnv_u64(CHECK_OFFSET, (self.seq.len() / 2) as u64);
        self.seq.iter().fold(h, |h, &b| fnv_byte(h, b))
    }
}

// The read lane's check: each value's tag, then a string's length. An empty text is null.
pub struct ReadCheck(pub u64);

impl Default for ReadCheck {
    fn default() -> Self {
        ReadCheck(CHECK_OFFSET)
    }
}

impl Visitor for ReadCheck {
    const LENGTHS: bool = true;
    fn key(&mut self, _: &[u8]) {}
    fn object(&mut self) {
        self.0 = fnv_byte(self.0, b'o');
    }
    fn end_object(&mut self) {}
    fn plain(&mut self, len: usize) {
        self.0 = if len == 0 { fnv_byte(self.0, b'z') } else { fnv_u64(fnv_byte(self.0, b's'), len as u64) };
    }
}

// The timed build of a stream: the nodes it gives, counted.
#[derive(Default)]
pub struct Count(pub u64);

impl Visitor for Count {
    const LENGTHS: bool = false;
    fn key(&mut self, _: &[u8]) {
        self.0 += 1;
    }
    fn object(&mut self) {
        self.0 += 1;
    }
    fn end_object(&mut self) {}
    fn plain(&mut self, _: usize) {
        self.0 += 1;
    }
}

// The timed read: every string adds its length to the sum.
#[derive(Default)]
pub struct Sum(pub f64);

impl Visitor for Sum {
    const LENGTHS: bool = true;
    fn key(&mut self, _: &[u8]) {}
    fn object(&mut self) {}
    fn end_object(&mut self) {}
    fn plain(&mut self, len: usize) {
        self.0 += len as f64;
    }
}

// The key lane's lookup: the key is the first key, the root element's name. Every object is counted, and one that has a
// member of that name answers.
#[derive(Default)]
pub struct KeyLookup {
    pub key: Vec<u8>,
    pub answers: u64,
    pub objects: u64,
    found: Vec<bool>,
}

impl Visitor for KeyLookup {
    const LENGTHS: bool = false;
    fn key(&mut self, name: &[u8]) {
        if self.key.is_empty() {
            self.key = name.to_vec();
        }
        if let Some(f) = self.found.last_mut() {
            *f |= name == self.key;
        }
    }
    fn object(&mut self) {
        self.found.push(false);
    }
    fn end_object(&mut self) {
        self.objects += 1;
        if self.found.pop() == Some(true) {
            self.answers += 1;
        }
    }
    fn plain(&mut self, _: usize) {}
}

fn walk_element<V: Visitor>(e: roxmltree::Node, v: &mut V) {
    v.key(e.tag_name().name().as_bytes());
    if !e.children().any(|c| c.is_element()) {
        v.plain(e.children().filter(|c| c.is_text()).map(|c| c.text().map_or(0, str::len)).sum());
        return;
    }
    v.object();
    let mut run = Run::default();
    for c in e.children() {
        if c.is_element() {
            run.flush(v);
            walk_element(c, v);
        } else if let Some(t) = c.text().filter(|_| c.is_text()) {
            run.add(t.len(), t.bytes().any(|b| !is_blank(b)));
        }
    }
    run.flush(v);
    v.end_object();
}

pub fn walk_document<V: Visitor>(doc: &roxmltree::Document, v: &mut V) {
    v.object();
    walk_element(doc.root_element(), v);
    v.end_object();
}

// A DOCTYPE is read, since the fixtures hold one, and no entity is expanded past roxmltree's own limits.
pub fn parse_roxmltree(text: &str) -> Result<roxmltree::Document<'_>, String> {
    let options = roxmltree::ParsingOptions { allow_dtd: true, ..Default::default() };
    roxmltree::Document::parse_with_options(text, options).map_err(|e| e.to_string())
}

struct Frame {
    object: bool,
    run: Run,
}

// Opens an element named `name`, which makes its parent an object when it is the parent's first child.
fn open<V: Visitor>(stack: &mut Vec<Frame>, name: &[u8], v: &mut V) {
    if let Some(parent) = stack.last_mut() {
        if !parent.object {
            parent.object = true;
            v.object();
        }
        parent.run.flush(v);
    }
    v.key(name);
    stack.push(Frame { object: false, run: Run::default() });
}

fn close<V: Visitor>(stack: &mut Vec<Frame>, v: &mut V) {
    if let Some(mut f) = stack.pop() {
        if f.object {
            f.run.flush(v);
            v.end_object();
        } else {
            v.plain(f.run.len);
        }
    }
}

// Reads the events of quick-xml over `text`. Entity references other than the predefined five count as no text, since
// quick-xml reads no declaration. Only the nesting of tags is checked.
pub fn stream<V: Visitor>(text: &str, v: &mut V) -> Result<(), String> {
    let mut reader = quick_xml::Reader::from_str(text);
    let mut stack: Vec<Frame> = Vec::new();
    v.object();
    loop {
        match reader.read_event().map_err(|e| e.to_string())? {
            Event::Start(e) => open(&mut stack, e.name().as_ref().as_bytes(), v),
            Event::Empty(e) => {
                open(&mut stack, e.name().as_ref().as_bytes(), v);
                close(&mut stack, v);
            }
            Event::End(_) => close(&mut stack, v),
            Event::Text(t) => {
                if let Some(f) = stack.last_mut() {
                    let raw = t.as_ref().as_bytes();
                    let text = raw.iter().any(|&b| !is_blank(b));
                    f.run.add(if V::LENGTHS { t.xml10_content().len() } else { raw.len() }, text);
                }
            }
            Event::CData(c) => {
                if let Some(f) = stack.last_mut() {
                    let raw = c.as_ref().as_bytes();
                    let text = raw.iter().any(|&b| !is_blank(b));
                    f.run.add(if V::LENGTHS { c.xml10_content().len() } else { raw.len() }, text);
                }
            }
            Event::GeneralRef(r) => {
                if let Some(f) = stack.last_mut() {
                    let n = match r.resolve_char_ref().map_err(|e| e.to_string())? {
                        Some(c) => c.len_utf8(),
                        None => usize::from(matches!(r.as_ref().as_bytes(), b"lt" | b"gt" | b"amp" | b"quot" | b"apos")),
                    };
                    f.run.add(n, n > 0);
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }
    v.end_object();
    Ok(())
}
