// The HTML lanes' shape over html5ever's `RcDom`, the one lanes/doc/html_shape.hpp defines: an element with no
// child element is a value of its text (null when empty), an element with child elements is an object whose members are
// each child element under its name and a `#text` member for each run of text between the children that holds a
// character other than HTML white space. Attributes, comments, the document type and processing instructions are no nodes.
use std::hint::black_box;

use html5ever::tendril::TendrilSink;
use html5ever::tree_builder::TreeBuilderOpts;
use html5ever::{ParseOpts, parse_document};
use markup5ever_rcdom::NodeData;
pub use markup5ever_rcdom::{Handle, RcDom};
use timing::{fnv_byte, fnv_u64};

fn blank(s: &str) -> bool {
    s.bytes().all(|c| matches!(c, b' ' | b'\t' | b'\n' | 0x0c | b'\r'))
}

// The node whose children an element has: a template's contents stand for its children.
fn source(el: &Handle) -> Handle {
    match &el.data {
        NodeData::Element { template_contents, .. } => template_contents.borrow().clone().unwrap_or_else(|| el.clone()),
        _ => el.clone(),
    }
}

pub fn name(el: &Handle) -> String {
    match &el.data {
        NodeData::Element { name, .. } => name.local.to_string(),
        _ => String::new(),
    }
}

fn is_element(n: &Handle) -> bool {
    matches!(n.data, NodeData::Element { .. })
}

pub trait Sink {
    fn object(&mut self);
    fn close(&mut self);
    fn member(&mut self, name: &str);
    fn run(&mut self, bytes: usize);
    fn leaf(&mut self, bytes: usize);
}

pub fn element(el: &Handle, sink: &mut impl Sink) {
    let source = source(el);
    let kids = source.children.borrow();
    let mut has_child = false;
    let mut leaf_bytes = 0;
    for c in kids.iter() {
        match &c.data {
            NodeData::Element { .. } => has_child = true,
            NodeData::Text { contents } => leaf_bytes += contents.borrow().len(),
            _ => {}
        }
    }
    if !has_child {
        sink.leaf(leaf_bytes);
        return;
    }
    sink.object();
    let (mut bytes, mut text) = (0, false);
    for c in kids.iter() {
        match &c.data {
            NodeData::Text { contents } => {
                let t = contents.borrow();
                bytes += t.len();
                text = text || !blank(&t);
            }
            NodeData::Element { name, .. } => {
                if text {
                    sink.run(bytes);
                }
                (bytes, text) = (0, false);
                sink.member(&name.local);
                element(c, sink);
            }
            _ => {}
        }
    }
    if text {
        sink.run(bytes);
    }
    sink.close();
}

pub fn document(root: &Handle, sink: &mut impl Sink) {
    sink.object();
    sink.member(&name(root));
    element(root, sink);
    sink.close();
}

pub struct Count(pub u64);

impl Sink for Count {
    fn object(&mut self) { self.0 += 1; }
    fn close(&mut self) {}
    fn member(&mut self, _: &str) { self.0 += 1; }
    fn run(&mut self, _: usize) { self.0 += 2; }
    fn leaf(&mut self, _: usize) { self.0 += 1; }
}

pub struct Hash(pub u64);

impl Hash {
    fn put(&mut self, tag: u8, role: u8) {
        self.0 = fnv_byte(fnv_byte(self.0, tag), role);
    }
}

impl Sink for Hash {
    fn object(&mut self) { self.put(b'o', 0); }
    fn close(&mut self) {}
    fn member(&mut self, _: &str) { self.put(b's', 1); }
    fn run(&mut self, _: usize) { self.put(b's', 1); self.put(b's', 0); }
    fn leaf(&mut self, bytes: usize) { self.put(if bytes > 0 { b's' } else { b'z' }, 0); }
}

// The read lane: each value's tag, then its decoded byte count. Only the sum when `HASH` is false.
pub struct Read<const HASH: bool> {
    pub check: u64,
    pub sum: f64,
}

impl<const HASH: bool> Read<HASH> {
    fn text(&mut self, bytes: usize) {
        if HASH {
            self.check = fnv_u64(fnv_byte(self.check, b's'), bytes as u64);
        }
        self.sum += bytes as f64;
    }
}

impl<const HASH: bool> Sink for Read<HASH> {
    fn object(&mut self) {
        if HASH {
            self.check = fnv_byte(self.check, b'o');
        }
    }
    fn close(&mut self) {}
    fn member(&mut self, _: &str) {}
    fn run(&mut self, bytes: usize) { self.text(bytes); }
    fn leaf(&mut self, bytes: usize) {
        if bytes > 0 {
            self.text(bytes);
        } else if HASH {
            self.check = fnv_byte(self.check, b'z');
        }
    }
}

// The key lane: objects, and how many hold a member named `key`.
pub struct Key<'a> {
    pub key: &'a str,
    pub objects: u64,
    pub answers: u64,
    pub counted: Vec<bool>,
}

impl Sink for Key<'_> {
    fn object(&mut self) {
        self.objects += 1;
        self.counted.push(false);
    }
    fn close(&mut self) { self.counted.pop(); }
    fn member(&mut self, name: &str) {
        let counted = self.counted.last_mut().unwrap();
        if name == self.key && !*counted {
            *counted = true;
            self.answers += 1;
        }
    }
    fn run(&mut self, _: usize) {}
    fn leaf(&mut self, _: usize) {}
}

// Scripting is off, as stury's and lexbor's trees are, so a `noscript` holds elements and not text.
fn opts() -> ParseOpts {
    ParseOpts { tree_builder: TreeBuilderOpts { scripting_enabled: false, ..Default::default() }, ..Default::default() }
}

pub fn parse(data: &[u8]) -> Result<RcDom, String> {
    let dom = parse_document(RcDom::default(), opts())
        .from_utf8()
        .read_from(&mut &data[..])
        .map_err(|e| e.to_string())?;
    Ok(black_box(dom))
}

// The document element of a parsed document.
pub fn root(dom: &RcDom) -> Result<Handle, String> {
    dom.document.children.borrow().iter().find(|c| is_element(c)).cloned().ok_or_else(|| "no document element".to_string())
}
