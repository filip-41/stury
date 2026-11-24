package xml

import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/markup"
import "stury:lib/core/tape"

// Reads of a built document that need an element's place in it: an attribute's name and value, the namespace an
// element's prefix is bound to, and where an end tag stands.

// In an attribute fact's spelling, past its lead and tail, the value refers to an entity the DTD declares, so its
// decode reads the DTD.
@(private)
ATTRIBUTE_DTD :: u16(1 << 9)

// In an attribute fact's spelling, past its lead and tail, the DTD declares the attribute of a type other than `CDATA`,
// so its value collapses its spaces.
@(private)
ATTRIBUTE_TOKENIZED :: u16(1 << 11)

// In an attribute fact's spelling, past its lead and tail, the attribute declares a namespace, so a build lists its
// element in the document's scopes with no read of its name.
@(private)
ATTRIBUTE_NS :: u16(1 << 10)

// The length of the attribute name at `lo` of `src`, which the white space or the `=` after it ends: in a tag an `=`
// follows the name, and in an attribute-list declaration its type.
@(private)
name_length :: #force_inline proc "contextless" (src: []u8, lo: u64) -> int #no_bounds_check {
	q := lo
	for !kernel.is_ws(src[q]) && src[q] != '=' {
		q += 1
	}
	return int(q - lo)
}

// The name and value of attribute fact `f`, as written between its quotes. The fact's lead runs through the opening
// quote unless it saturated, and then the quote is the nearest byte before the closing one that equals it, since a
// value holds no quote of its own kind.
@(private)
attribute_parts :: proc "contextless" (src: []u8, f: tape.Fact) -> (name, value: []u8) #no_bounds_check {
	hi := f.lo + u64(f.n)
	name = src[f.lo:f.lo + u64(name_length(src, f.lo))]
	open := f.lo + markup.fact_lead(f.spelling)
	if markup.fact_lead(f.spelling) == markup.ATTRIBUTE_LEAD_MAX {
		open = hi - 1
		for src[open - 1] != src[hi - 1] {
			open -= 1
		}
	}
	return name, src[open:hi - 1]
}

// The name of attribute fact `f` of `doc` as a key token and its value as a string token, which `tape.node_text`
// reads with the document's format and allocator: decoded as an attribute value is, and for a type the DTD declares
// that is not `CDATA`, with its spaces collapsed.
attribute :: proc "contextless" (doc: ^tape.Document, f: tape.Fact) -> (name, value: tape.Token) {
	n, v := attribute_parts(doc.src, f)
	name = {lo = f.lo, n = u32(len(n)), kind = .String, role = .Key}
	value = {lo = f.lo + u64(f.n) - 1 - u64(len(v)), n = u32(len(v)), kind = .String}
	tokenized := f.spelling & ATTRIBUTE_TOKENIZED != 0
	if !plain_value(v) || tokenized && !collapsed(v) {
		value.spelling = tape.SPELLING_DECODE | SPELLING_ATTRIBUTE | (SPELLING_TOKENIZED if tokenized else 0)
		if f.spelling & ATTRIBUTE_DTD != 0 {
			value.spelling |= SPELLING_DTD
		}
	}
	return
}

// Whether `value` is what `collapse` leaves of it: no space leads or ends it, and none follows another.
@(private)
collapsed :: proc "contextless" (value: []u8) -> bool {
	for b, i in value {
		if b == ' ' && (i == 0 || i == len(value) - 1 || value[i - 1] == ' ') {
			return false
		}
	}
	return true
}

// The facts of node `at` of `doc`, in source order.
@(private)
facts_at :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> []tape.Fact #no_bounds_check {
	lo, hi := 0, len(doc.facts)
	for lo < hi {
		mid := (lo + hi) / 2
		if doc.facts[mid].node < at {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	hi = lo
	for hi < len(doc.facts) && doc.facts[hi].node == at {
		hi += 1
	}
	return doc.facts[lo:hi]
}

// The index of the first colon of `name`, -1 for none.
@(private)
colon_of :: proc "contextless" (name: []u8) -> int {
	for b, i in name {
		if b == ':' {
			return i
		}
	}
	return -1
}

// Lists the elements of `doc` that declare a namespace in its format data, which `namespace` reads. A document with
// none has no list. False when memory is refused, which leaves `doc` as it was.
@(private)
keep_scopes :: proc(doc: ^tape.Document) -> bool {
	n := 0
	last := tape.NO_NODE
	for f in doc.facts {
		if f.kind == .Attribute && f.node != last && f.spelling & ATTRIBUTE_NS != 0 {
			n, last = n + 1, f.node
		}
	}
	if n == 0 {
		return true
	}
	context.allocator = doc.allocator
	size := size_of(tape.Doc_Ext) + n * size_of(tape.Markup_Scope)
	raw, err := runtime.mem_alloc(size, align_of(tape.Doc_Ext))
	if err != nil || raw == nil {
		return false
	}
	ext := (^tape.Doc_Ext)(raw_data(raw))
	scopes := ([^]tape.Markup_Scope)(raw_data(raw[size_of(tape.Doc_Ext):]))[:n]
	k := 0
	last = tape.NO_NODE
	for f in doc.facts {
		if f.kind != .Attribute || f.node == last || f.spelling & ATTRIBUTE_NS == 0 {
			continue
		}
		last = f.node
		end := f.node + (tape.Node_Index(doc.nodes[f.node].n) if doc.nodes[f.node].kind == .Object else 1)
		// The scopes before this one that hold it are its ancestors, the nearest last.
		parent := u32(k) - 1 if k > 0 else tape.NO_SCOPE
		for parent != tape.NO_SCOPE && scopes[parent].end <= f.node {
			parent = scopes[parent].parent
		}
		scopes[k] = {node = f.node, end = end, parent = parent}
		k += 1
	}
	ext.format = tape.Markup_Ext{scopes = scopes}
	doc.ext = ext
	return true
}

// The namespace URI of the element whose value is node `at` of `doc`, a document `build` made, bound to its prefix or
// the default one, decoded into `buf` when it is not as written, and empty for none. False when `buf` is shorter than
// the URI's decode needs, as `text_room` gives for an attribute's value, or the document's allocator refuses the DTD
// the decode reads.
namespace :: proc(doc: ^tape.Document, at: tape.Node_Index, buf: []u8) -> (uri: string, ok: bool) {
	if at == tape.ROOT || at == tape.NO_NODE || doc.nodes[at - 1].role != .Key || markup.is_text_key(doc.nodes[at - 1]) {
		return "", true
	}
	key := doc.nodes[at - 1]
	written := doc.src[key.lo:][:key.n]
	prefix := written[:max(colon_of(written), 0)]
	if string(prefix) == "xml" {
		return XML_URI, true
	}
	if doc.ext == nil {
		return "", true
	}
	ext, scoped := doc.ext.format.(tape.Markup_Ext)
	if !scoped {
		return "", true
	}
	// The last scope that starts at or before `at`, and then the scopes around it, nearest first.
	lo, hi := 0, len(ext.scopes)
	for lo < hi {
		mid := (lo + hi) / 2
		if ext.scopes[mid].node <= at {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	scope := u32(lo) - 1 if lo > 0 else tape.NO_SCOPE
	for ; scope != tape.NO_SCOPE; scope = ext.scopes[scope].parent {
		s := ext.scopes[scope]
		if s.end <= at {
			continue
		}
		for f in facts_at(doc, s.node) {
			if f.kind != .Attribute {
				continue
			}
			name, _ := attribute_parts(doc.src, f)
			if len(prefix) == 0 && string(name) == "xmlns" || len(prefix) > 0 && len(name) == len(prefix) + 6 && string(name[:6]) == "xmlns:" && string(name[6:]) == string(prefix) {
				_, value := attribute(doc, f)
				return tape.node_text(doc.format, doc.src, value, buf, doc.allocator)
			}
		}
	}
	return "", true
}

// The byte just past the end of the element at container node `at`, or of the text for the document's node. The close
// of an element is found from its last descendant: a leaf element ends with its own end tag, and each container around
// it with the end tag after its comments and instructions.
@(private)
close_end :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (u64, bool) {
	if at == tape.ROOT {
		return doc.root_close, true
	}
	src := doc.src
	if in_subset(doc) {
		return balanced_end(src, doc.nodes[at].lo), true
	}
	last := at + tape.Node_Index(doc.nodes[at].n) - 1
	t := doc.nodes[last]
	p := t.lo + u64(t.n)
	if k := doc.nodes[last - 1]; k.role == .Key && !markup.is_text_key(k) {
		if t.n == 0 && src[t.lo] == '/' {
			p = t.lo + 2
		} else {
			p = end_tag_end(src, p)
		}
	}
	// The containers from `at` down to the one that holds `last`.
	count := 0
	c := at
	for {
		count += 1
		next := c
		for j := c + 1; j < c + tape.Node_Index(doc.nodes[c].n); {
			child := doc.nodes[j]
			size := tape.Node_Index(child.n) if child.kind == .Object else 1
			if last < j + size {
				if j != last {
					next = j
				}
				break
			}
			j += size
		}
		if next == c {
			break
		}
		c = next
	}
	for _ in 0 ..< count {
		p = end_tag_end(src, skip_misc(src, p))
	}
	return p, true
}

// Whether a node of `doc` may lie in its internal subset, an entity's text walked at its reference, which a text with
// a DTD that declares an entity holding markup has.
@(private)
in_subset :: proc "contextless" (doc: ^tape.Document) -> bool {
	return declares_entities(doc.src)
}

// `close_end` for a document some of whose nodes may lie in the internal subset, so a last descendant may lie outside
// the element's bytes: the element's tags are matched from its start tag at `lo` on. The text between them is balanced,
// since a reference stands for content that closes what it opens.
@(private)
balanced_end :: proc "contextless" (src: []u8, lo: u64) -> u64 {
	p := lo
	open := 0
	for {
		for src[p] != '<' {
			p += 1
		}
		switch src[p + 1] {
		case '/':
			p = end_tag_end(src, p)
			open -= 1
			if open == 0 {
				return p
			}
			continue
		case '!', '?':
			p = u64(uintptr(markup_end(raw_data(src)[p:], raw_data(src)[len(src):])) - uintptr(raw_data(src)))
			continue
		}
		quote: u8
		for p += 1; quote != 0 || src[p] != '>'; p += 1 {
			if quote == 0 && (src[p] == '"' || src[p] == '\'') {
				quote = src[p]
			} else if src[p] == quote {
				quote = 0
			}
		}
		p += 1
		if src[p - 2] != '/' {
			open += 1
		} else if open == 0 {
			return p
		}
	}
}

// Returns the first byte at or past `p` that is no whitespace, comment or processing instruction.
@(private)
skip_misc :: proc "contextless" (src: []u8, p: u64) -> u64 {
	p := p
	for {
		for p < u64(len(src)) && kernel.is_ws(src[p]) {
			p += 1
		}
		if p + 1 >= u64(len(src)) || src[p] != '<' {
			return p
		}
		switch {
		case src[p + 1] == '?':
			p += 2
			for !(src[p] == '?' && src[p + 1] == '>') {
				p += 1
			}
			p += 2
		case src[p + 1] == '!' && p + 3 < u64(len(src)) && src[p + 2] == '-':
			p += 4
			for !(src[p] == '-' && src[p + 1] == '-') {
				p += 1
			}
			p += 3
		case:
			return p
		}
	}
}

// Returns one past the `>` of the end tag at `p`.
@(private)
end_tag_end :: proc "contextless" (src: []u8, p: u64) -> u64 {
	p := p
	for src[p] != '>' {
		p += 1
	}
	return p + 1
}
