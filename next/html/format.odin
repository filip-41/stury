package html

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// Format services for HTML5: token spelling bit layout, decoded text/key readers, typed `Html_Ext` state,
// attributes, and namespaces.

@(private)
KEY_NS_SHIFT :: 12
@(private)
KEY_IMPLIED_SHIFT :: 12
@(private)
KEY_FROZEN :: u16(1 << 14)
@(private)
KEY_TABLE :: u16(1 << 15)

@(private)
TEXT_MODE_SHIFT :: 11
@(private)
TEXT_PIECES :: u16(1 << 14)
@(private)
TEXT_FROZEN :: u16(1 << 15)

#assert(((3 << KEY_NS_SHIFT) | KEY_FROZEN | KEY_TABLE) == 0xF000)
#assert(((7 << KEY_IMPLIED_SHIFT) | KEY_TABLE) == 0xF000)
#assert((0xF000 | tape.SPELLING_TEXT_KEY) & 0x07FF == 0)
#assert(((7 << TEXT_MODE_SHIFT) | TEXT_PIECES | TEXT_FROZEN) & 0x07FF == 0)

@(private)
DECODED :: Span_Flags{.Ref, .Nul, .Upper, .Cr, .Invalid}

@(private, rodata)
NAMESPACE_URIS := [Namespace]string {
	.Html = "http://www.w3.org/1999/xhtml",
	.Svg  = "http://www.w3.org/2000/svg",
	.Math = "http://www.w3.org/1998/Math/MathML",
}

@(private)
to_html_span :: #force_inline proc "contextless" (s: Span) -> tape.Html_Span {
	return {lo = s.lo, n = s.n, mode = u8(s.mode), flags = transmute(u8)s.flags}
}

@(private)
from_html_span :: #force_inline proc "contextless" (s: tape.Html_Span) -> Span {
	return {lo = s.lo, n = s.n, mode = Mode(s.mode), flags = transmute(Span_Flags)s.flags}
}

@(private)
Open_Entry :: struct { tag: u64, node: tape.Node_Index }

@(private)
Kept :: struct {
	ends:   [dynamic]tape.Html_End,
	texts:  [dynamic]tape.Html_Text,
	pieces: [dynamic]tape.Html_Span,
	open:   [dynamic]Open_Entry,
	infer:  bool,
	oom:    bool,
}

@(private)
kept_destroy :: proc(k: ^Kept) {
	delete(k.ends); delete(k.texts); delete(k.pieces); delete(k.open)
}

@(private = "file")
attach_ext :: proc(doc: ^tape.Document, he: tape.Html_Ext, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	held: []tape.Held_Span
	origin: tape.Origin
	if doc.ext != nil { held, origin = doc.ext.held, doc.ext.origin }
	new_ext := tape.ext_make(held, he, allocator, origin) or_return
	if doc.ext != nil { free(doc.ext, doc.allocator) }
	doc.ext = new_ext
	return nil
}

@(private)
seal_state :: proc(doc: ^tape.Document, k: ^Kept, allocator: runtime.Allocator) -> bool {
	if k.oom { return false }
	if len(k.ends) == 0 && len(k.texts) == 0 && !k.infer { return true }
	slice.sort_by(k.ends[:], proc(a, b: tape.Html_End) -> bool { return a.node < b.node })
	slice.sort_by(k.texts[:], proc(a, b: tape.Html_Text) -> bool { return a.lo < b.lo })
	n := 0
	for e, i in k.texts {
		if i == 0 || e.lo != k.texts[n - 1].lo { k.texts[n] = e; n += 1 }
	}
	resize(&k.texts, n)
	return attach_ext(doc, tape.Html_Ext{ends = k.ends[:], texts = k.texts[:], pieces = k.pieces[:], infer = k.infer}, allocator) == nil
}

@(private)
html_ext :: #force_inline proc "contextless" (ext: ^tape.Format_Ext) -> (^tape.Html_Ext, bool) {
	if ext == nil { return nil, false }
	return &ext.(tape.Html_Ext)
}

@(private)
doc_inferred :: proc "contextless" (doc: ^tape.Document) -> bool {
	if doc == nil { return false }
	if doc.ext != nil {
		if he, ok := html_ext(&doc.ext.format); ok && he.infer { return true }
	}
	for n in doc.nodes {
		if n.role == .Value && (n.kind == .Number || n.kind == .True || n.kind == .False) { return true }
	}
	return false
}

@(private)
find_text_entry :: proc "contextless" (ext: ^tape.Format_Ext, lo: u64) -> (he: ^tape.Html_Ext, entry: tape.Html_Text, ok: bool) {
	he = html_ext(ext) or_return
	i, j := 0, len(he.texts)
	for i < j {
		mid := (i + j) / 2
		if he.texts[mid].lo < lo { i = mid + 1 } else { j = mid }
	}
	if i == len(he.texts) { return nil, {}, false }
	entry = he.texts[i]
	if entry.lo != lo { return nil, {}, false }
	return he, entry, true
}

@(private)
subdoc_state :: proc(src_doc, dst_doc: ^tape.Document, v, count: tape.Node_Index, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	if src_doc.ext == nil { return nil }
	he, ok := html_ext(&src_doc.ext.format)
	if !ok { return nil }
	lo_idx, hi_idx := 0, len(he.ends)
	for lo_idx < hi_idx {
		mid := (lo_idx + hi_idx) / 2
		if he.ends[mid].node < v { lo_idx = mid + 1 } else { hi_idx = mid }
	}
	end_idx, limit := lo_idx, v + count
	for end_idx < len(he.ends) && he.ends[end_idx].node < limit { end_idx += 1 }

	mapped: [dynamic]tape.Html_End
	mapped.allocator = allocator
	defer delete(mapped)
	dense := len(dst_doc.nodes) == int(count)
	if lo_idx < end_idx {
		if dense {
			reserve(&mapped, end_idx - lo_idx) or_return
			for k in lo_idx ..< end_idx {
				e := he.ends[k]
				e.node -= v
				append(&mapped, e) or_return
			}
		} else {
			ri, k := v, lo_idx
			for dnode, di in dst_doc.nodes {
				if dnode.kind != .Object { continue }
				for ri < v + count {
					snode := src_doc.nodes[ri]
					if snode.kind == .Object && snode.lo == dnode.lo &&
						(di == 0 && ri == v || di > 0 && ri > 0 && dst_doc.nodes[di - 1].lo == src_doc.nodes[ri - 1].lo) { break }
					ri += 1
				}
				if ri >= v + count { break }
				for k < end_idx && he.ends[k].node < ri { k += 1 }
				if k < end_idx {
					if e := he.ends[k]; e.node == ri {
						append(&mapped, tape.Html_End{node = tape.Node_Index(di), end = e.end}) or_return
						k += 1
					}
				}
				ri += 1
			}
		}
	}
	if len(mapped) == 0 && len(he.texts) == 0 && len(he.pieces) == 0 && !he.infer { return nil }
	return attach_ext(dst_doc, tape.Html_Ext{ends = mapped[:], texts = he.texts, pieces = he.pieces, infer = he.infer}, allocator)
}

@(private)
key_namespace :: #force_inline proc "contextless" (k: tape.Token) -> Namespace {
	return .Html if k.n == 0 else Namespace(min(k.spelling >> KEY_NS_SHIFT & 3, u16(max(Namespace))))
}

@(private)
key_is_frozen :: #force_inline proc "contextless" (k: tape.Token) -> bool {
	return !tape.is_text_key(k) && (k.n == 0 || k.spelling & KEY_FROZEN != 0)
}

@(private)
table_key_text :: proc "contextless" (src: []u8, t: tape.Token) -> string {
	if tape.is_text_key(t) { return tape.TEXT_KEY }
	if t.n == 0 { return IMPLIED_TAG_NAMES[Implied_Tag((t.spelling >> KEY_IMPLIED_SHIFT) & 7)] }
	if t.spelling & KEY_TABLE != 0 {
		if ns := key_namespace(t); ns == .Svg || ns == .Math {
			if i := foreign_of(raw_data(src)[t.lo:], t.n); i > 0 { return FOREIGN_NAMES[i].name }
		}
		if t.n == 5 && fold_name_equal(src[t.lo:][:5], "image") { return "img" }
	}
	return ""
}

@(private)
bounds :: proc "contextless" (src: []u8, t: tape.Token) -> (u8, u8) { return 0, 0 }

@(private)
number_value :: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number {
	num, _ := spell.number_strict(src, t.lo, t.lo + u64(t.n))
	return num
}

@(private)
decode_room_node :: proc "contextless" (src: []u8, t: tape.Node, ext: ^tape.Format_Ext) -> int {
	if t.role == .Key {
		if fx := table_key_text(src, t); len(fx) > 0 { return len(fx) }
		return 3 * int(t.n) if t.spelling & tape.SPELLING_LAX != 0 else int(t.n)
	}
	if t.spelling & TEXT_PIECES != 0 {
		if he, entry, ok := find_text_entry(ext, t.lo); ok {
			sum := u64(0)
			for i in 0 ..< entry.count { sum += u64(he.pieces[entry.first + i].n) }
			return 3 * int(max(u64(t.n), sum)) + 16
		}
	}
	return 3 * int(t.n) + 16
}

@(private)
text_decoded :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8, ext: ^tape.Format_Ext) -> (s: string, ok: bool) {
	if t.role == .Key {
		if fixed := table_key_text(src, t); len(fixed) > 0 {
			if len(buf) < len(fixed) { return "", false }
			return string(buf[:copy(buf, fixed)]), true
		}
		if t.spelling & tape.SPELLING_DECODE == 0 {
			if len(buf) < int(t.n) { return "", false }
			return string(buf[:copy(buf, src[t.lo:][:t.n])]), true
		}
		if t.spelling & tape.SPELLING_LAX != 0 {
			return decode(src, Span{lo = t.lo, n = t.n, mode = .Name, flags = DECODED}, buf)
		}
		if len(buf) < int(t.n) { return "", false }
		for c, i in src[t.lo:][:t.n] { buf[i] = c | 0x20 if c - 'A' < 26 else c }
		return string(buf[:t.n]), true
	}
	mode := Mode((t.spelling >> TEXT_MODE_SHIFT) & 7)
	if t.spelling & TEXT_PIECES == 0 { return decode(src, Span{lo = t.lo, n = t.n, mode = mode, flags = DECODED}, buf) }
	he, entry := find_text_entry(ext, t.lo) or_return
	w := 0
	for i in 0 ..< entry.count {
		p := from_html_span(he.pieces[entry.first + i])
		p.flags = DECODED
		part := decode(src, p, buf[w:]) or_return
		w += copy(buf[w:], part)
	}
	return string(buf[:w]), true
}

@(private = "file")
Name_Cursor :: struct {
	p, end:   [^]u8,
	lax, fold: bool,
	fixed:    string,
	fi:       int,
	pend:     [3]u8,
	pi, pn:   int,
}

@(private = "file")
name_cursor_init :: #force_inline proc "contextless" (s: []u8, t: tape.Token) -> Name_Cursor {
	if fx := table_key_text(s, t); len(fx) > 0 { return {fixed = fx} }
	sp := s[t.lo:][:t.n]
	p := raw_data(sp)
	return {p = p, end = intrinsics.ptr_offset(p, len(sp)), lax = t.spelling & tape.SPELLING_LAX != 0, fold = t.spelling & tape.SPELLING_DECODE != 0}
}

@(private = "file")
name_cursor_next :: #force_inline proc "contextless" (c: ^Name_Cursor) -> (u8, bool) {
	if len(c.fixed) > 0 {
		if c.fi >= len(c.fixed) { return 0, false }
		b := c.fixed[c.fi]; c.fi += 1
		return b, true
	}
	if c.pi < c.pn { b := c.pend[c.pi]; c.pi += 1; return b, true }
	if c.p >= c.end { return 0, false }
	ch := c.p[0]
	if !c.lax {
		c.p = c.p[1:]
		return (ch | 0x20 if c.fold && ch - 'A' < 26 else ch), true
	}
	if ch == 0 {
		c.p = c.p[1:]
		c.pend, c.pi, c.pn = {0xEF, 0xBF, 0xBD}, 1, 3
		return 0xEF, true
	}
	if ch >= 0x80 {
		if _, kind := spell.utf8_char(c.p, c.end); kind != .None {
			c.p = spell.utf8_subpart(c.p, c.end)
			c.pend, c.pi, c.pn = {0xEF, 0xBF, 0xBD}, 1, 3
			return 0xEF, true
		}
		c.p = c.p[1:]
		return ch, true
	}
	c.p = c.p[1:]
	return (ch | 0x20 if ch - 'A' < 26 else ch), true
}

@(private)
same_text :: proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool {
	ta, tb := table_key_text(src, t), table_key_text(other, o)
	if len(ta) > 0 && len(tb) > 0 { return ta == tb }
	a_buf, b_buf: [256]u8 = ---, ---
	if key_decode_fits(src, t) && key_decode_fits(other, o) {
		sa, ok_a := key_text_fast(src, t, a_buf[:])
		sb, ok_b := key_text_fast(other, o, b_buf[:])
		if ok_a && ok_b { return sa == sb }
	}
	ca, cb := name_cursor_init(src, t), name_cursor_init(other, o)
	for {
		ba, oka := name_cursor_next(&ca)
		bb, okb := name_cursor_next(&cb)
		if oka != okb || ba != bb { return false }
		if !oka { return true }
	}
}

@(private)
key_hash :: proc "contextless" (src: []u8, t: tape.Token) -> u32 {
	if fixed := table_key_text(src, t); len(fixed) > 0 { return tape.text_hash(transmute([]u8)fixed) }
	if t.spelling & tape.SPELLING_DECODE == 0 { return tape.text_hash(src[t.lo:][:t.n]) }
	h := tape.text_hasher()
	cur := name_cursor_init(src, t)
	for b in name_cursor_next(&cur) { tape.text_hash_byte(&h, b) }
	return tape.text_hasher_end(&h)
}

@(private)
key_decode_fits :: #force_inline proc "contextless" (src: []u8, t: tape.Token) -> bool {
	if t.spelling & tape.SPELLING_DECODE == 0 || len(table_key_text(src, t)) > 0 { return true }
	return (3 * int(t.n) if t.spelling & tape.SPELLING_LAX != 0 else int(t.n)) <= 256
}

@(private)
key_text_fast :: #force_inline proc "contextless" (src: []u8, t: tape.Token, buf: []u8) -> (string, bool) {
	if fixed := table_key_text(src, t); len(fixed) > 0 { return fixed, true }
	if t.spelling & tape.SPELLING_DECODE == 0 { return string(src[t.lo:][:t.n]), true }
	return text_decoded(src, t, buf, nil)
}

@(private)
html_text_ext :: proc(src: []u8, allocator: runtime.Allocator) -> (^tape.Doc_Ext, bool) { return build_text_ext(src, .Document, allocator) }
@(private)
fragment_text_ext :: proc(src: []u8, allocator: runtime.Allocator) -> (^tape.Doc_Ext, bool) { return build_text_ext(src, .Fragment, allocator) }

@(private, cold)
build_text_ext :: proc(src: []u8, spec: Tree_Spec, allocator: runtime.Allocator) -> (^tape.Doc_Ext, bool) {
	t, err := build_tree(src, spec, {}, {}, 0, allocator)
	if err != nil { return nil, false }
	defer tree_destroy(&t)
	k: Kept
	k.texts.allocator, k.pieces.allocator = allocator, allocator
	defer { delete(k.texts); delete(k.pieces) }
	for cur := DOCUMENT; cur != 0; {
		if first := tree_node(&t, cur).first; first != 0 {
			collect_run(&t, first, &k)
			cur = first
			continue
		}
		for cur != 0 {
			if nxt := tree_node(&t, cur).next; nxt != 0 {
				if tree_node(&t, cur).kind == .Element { collect_run(&t, nxt, &k) }
				cur = nxt
				break
			}
			cur = tree_node(&t, cur).parent
		}
	}
	if len(k.texts) == 0 { return nil, true }
	doc := tape.Document{allocator = allocator}
	if !seal_state(&doc, &k, allocator) { return nil, false }
	return doc.ext, true
}

@(private, cold)
collect_run :: proc(t: ^Html_Tree, from: u32, k: ^Kept) {
	run := make([dynamic]tape.Html_Span, 0, 4, t.ctx.allocator)
	defer delete(run)
	lo := u64(0)
	for node := from; node != 0 && tree_node(t, node).kind != .Element; node = tree_node(t, node).next {
		tn := tree_node(t, node)
		if tn.kind != .Text { continue }
		for p := tn.a;; p = t.pieces[p].next {
			s := t.pieces[p].span
			lo = s.lo if len(run) == 0 else min(lo, s.lo)
			if _, aerr := append(&run, to_html_span(s)); aerr != nil { k.oom = true; return }
			if p == tn.b { break }
		}
	}
	if len(run) > 1 {
		_, e1 := append(&k.texts, tape.Html_Text{lo = lo, first = u32(len(k.pieces)), count = u32(len(run))})
		_, e2 := append(&k.pieces, ..run[:])
		if e1 != nil || e2 != nil { k.oom = true }
	}
}

@(private)
close_end :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (end: u64, ok: bool) {
	if at == tape.ROOT { return doc.root_close, true }
	if .Held in doc.flags || doc.ext == nil { return 0, false }
	he := html_ext(&doc.ext.format) or_return
	lo, hi := 0, len(he.ends)
	for lo < hi {
		mid := (lo + hi) / 2
		if he.ends[mid].node < at { lo = mid + 1 } else { hi = mid }
	}
	if lo < len(he.ends) {
		if e := he.ends[lo]; e.node == at { return e.end, true }
	}
	return 0, false
}

// HTML's `Format.attribute`: attribute name as folded/foreign `.Key`, and value as decoded `.Plain` (or empty `.String`).
attribute :: proc "contextless" (doc: ^tape.Document, f: tape.Fact) -> (name, value: tape.Token) {
	src := tape.span_bytes(doc, f.lo, f.n)
	hi, q := u64(len(src)), u64(1)
	for q < hi && !is_space(src[q]) && src[q] != '/' && src[q] != '>' && src[q] != '=' { q += 1 }
	name = {lo = f.lo, n = u32(q), kind = .String, role = .Key}
	ns := key_namespace(doc.nodes[f.node - 1]) if f.node > 0 && int(f.node) <= len(doc.nodes) && doc.nodes[f.node - 1].role == .Key else .Html
	written := src[:q]
	if ns != .Html {
		kinds := FOREIGN_NAMES[foreign_of(raw_data(written), u32(len(written)))].kinds
		if (.Svg_Attribute in kinds && ns == .Svg) || (.Math_Attribute in kinds && ns == .Math) {
			name.spelling = tape.SPELLING_DECODE | u16(ns) << KEY_NS_SHIFT | KEY_TABLE
		}
	}
	if name.spelling == 0 { name.spelling = name_spelling(byte_flags(written)) }
	lead, tail := tape.fact_lead(f.spelling), tape.fact_tail(f.spelling)
	start := lead
	if lead == tape.ATTRIBUTE_LEAD_MAX {
		start = q
		for start < hi && is_space(src[start]) { start += 1 }
		if start < hi && src[start] == '=' {
			start += 1
			for start < hi && is_space(src[start]) { start += 1 }
			start += tail
		} else {
			start = hi
		}
	}
	if tail == 0 && start >= hi { return name, {lo = f.lo + hi, kind = .String} }
	value = {lo = f.lo + start, n = u32(hi - tail - start), kind = .Plain}
	if byte_flags(src[start : hi - tail]) & {.Ref, .Nul, .Cr, .Invalid} != {} {
		value.spelling = tape.SPELLING_DECODE | tape.SPELLING_LAX | u16(Mode.Value) << TEXT_MODE_SHIFT
	}
	return
}

// HTML's `Format.namespace`: namespace URI of element value `at`.
namespace :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (string, tape.Presence) {
	if at == tape.ROOT || at == 0 || int(at) >= len(doc.nodes) || doc.nodes[at - 1].role != .Key { return "", .Missing }
	k := doc.nodes[at - 1]
	if tape.is_text_key(k) { return "", .Missing }
	return NAMESPACE_URIS[key_namespace(k)], .Found
}

@(private)
name_spelling :: #force_inline proc "contextless" (flags: Span_Flags) -> u16 {
	if flags & {.Upper, .Nul, .Invalid} == {} { return 0 }
	return tape.SPELLING_DECODE | (tape.SPELLING_LAX if flags & {.Nul, .Invalid} != {} else 0)
}

@(private)
byte_flags :: proc "contextless" (b: []u8) -> (flags: Span_Flags) {
	for c in b {
		switch {
		case c == '&':      flags += {.Ref}
		case c == 0:        flags += {.Nul}
		case c - 'A' < 26:  flags += {.Upper}
		case c == '\r':     flags += {.Cr}
		case c >= 0x80:     flags += {.Invalid}
		}
	}
	return
}

@(private)
fold_name_equal :: proc "contextless" (written: []u8, name: string) -> bool {
	if len(written) != len(name) { return false }
	for c, i in written { if (c | 0x20 if c - 'A' < 26 else c) != name[i] { return false } }
	return true
}
