package xml

import "base:intrinsics"
import "stury:lib/base/kernel"
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

// The name and value of XML attribute fact `span` with `spelling`, the value as written within its quotes. A name ends
// at white space or `=`. A lead that saturated is a quoted value's, which starts past the nearest byte before its
// closing quote that equals it, since a value holds no quote of its own kind.
// Invariant: `span` is a validated quoted XML attribute fact (`len(span) >= 4`, closing quote at `hi`, matching
// opening quote before `hi`).
@(private, require_results)
attribute_parts :: proc "contextless" (span: []u8, spelling: u16) -> (name, value: []u8) #no_bounds_check {
	q := 0
	for q < len(span) && !kernel.is_ws(span[q]) && span[q] != '=' {
		q += 1
	}
	// The tail is the closing quote, a bit below the format's own.
	hi := len(span) - int(spelling >> 8 & 1)
	lead := int(tape.fact_lead(spelling))
	if lead == tape.ATTRIBUTE_LEAD_MAX {
		for lead = hi; span[lead - 1] != span[hi]; lead -= 1 {
		}
	}
	return span[:q], span[min(lead, hi):hi]
}

// The name of attribute fact `f` of `doc` as a key token and its value as a string token, which `tape.node_text`
// reads with the document: decoded as an attribute value is, and for a type the DTD declares
// that is not `CDATA`, with its spaces collapsed.
attribute :: proc "contextless" (doc: ^tape.Document, f: tape.Fact) -> (name, value: tape.Token) {
	span := tape.span_bytes(doc, f.lo, f.n)
	n, v := attribute_parts(span, f.spelling)
	name = {lo = f.lo, n = u32(len(n)), kind = .String, role = .Key}
	value = {lo = f.lo + u64(intrinsics.ptr_sub(raw_data(v), raw_data(span))), n = u32(len(v)), kind = .String}
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

// Lists the elements of `doc` that declare a namespace in its format data, which `namespace` reads, beside the DTD and
// the held spans it holds, with `whole` when the facts of `doc` hold every declaration around its nodes. A document of
// every value with none has no list. A refusal of memory destroys `doc`.
@(private)
keep_scopes :: proc(doc: ^tape.Document, whole: bool) -> (err: tape.Error) {
	if .Attribute not_in doc.present && (doc.partial == nil || !whole) {
		return nil
	}
	// Most documents declare no namespace, so the first declaration is sought alone.
	first := len(doc.facts)
	for f, i in doc.facts {
		if f.kind == .Attribute && f.spelling & ATTRIBUTE_NS != 0 {
			first = i
			break
		}
	}
	n, m := 0, 0
	last := tape.NO_NODE
	for f in doc.facts[first:] {
		if f.kind == .Attribute && f.spelling & ATTRIBUTE_NS != 0 {
			if f.node != last {
				n, last = n + 1, f.node
			}
			m += 1
		}
	}
	if n == 0 && (doc.partial == nil || !whole) {
		return nil
	}
	defer if err != nil {
		tape.destroy(doc)
	}
	scopes := make([]tape.Markup_Scope, n, doc.allocator) or_return
	defer delete(scopes, doc.allocator)
	uris := make([]tape.Markup_Uri, m, doc.allocator) or_return
	defer delete(uris, doc.allocator)
	text := make([dynamic]u8, doc.allocator)
	defer delete(text)
	k, d := 0, 0
	last = tape.NO_NODE
	for f, j in doc.facts[first:] {
		if f.kind != .Attribute || f.spelling & ATTRIBUTE_NS == 0 {
			continue
		}
		if _, value := attribute(doc, f); value.spelling & tape.SPELLING_DECODE != 0 {
			w := len(text)
			resize(&text, w + tape.text_room(doc, value)) or_return
			uri, decodes := tape.node_text(doc, value, text[w:])
			at := intrinsics.ptr_sub(raw_data(uri), raw_data(text)) if decodes && len(uri) > 0 else 0
			uris[d] = {fact = u32(first + j), n = u32(len(uri)) if decodes else 0, lo = u64(at)}
			d += 1
		}
		if f.node == last {
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
	kept := tape.Markup_Ext{scopes = scopes, uris = uris[:d], uri_text = text[:], whole = whole}
	held: []tape.Held_Span
	origin: tape.Origin
	if doc.ext != nil {
		held, origin = doc.ext.held, doc.ext.origin
		if m, ok := doc.ext.format.(tape.Markup_Ext); ok {
			kept.dtd = m.dtd
		}
	}
	ext := tape.ext_make(held, kept, doc.allocator, origin) or_return
	free(doc.ext, doc.allocator)
	doc.ext = ext
	return nil
}

// Resolves the element key node for element value `at`, handling both direct `[Key, Value]` members and normalized
// `[Key, Array, elem_0, ...]` elements iteratively without recursion.
@(private)
element_key_of :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (key_idx: tape.Node_Index, ok: bool) #no_bounds_check {
	if at == tape.ROOT || at == tape.NO_NODE || int(at) >= len(doc.nodes) {
		return tape.NO_NODE, false
	}
	if doc.nodes[at].kind == .Array {
		return tape.NO_NODE, false
	}
	if prev := doc.nodes[at - 1]; prev.role == .Key {
		if tape.is_text_key(prev) {
			return tape.NO_NODE, false
		}
		return at - 1, true
	}
	// Walk backwards to find `at`'s immediate enclosing container: the first earlier container whose subtree covers `at`.
	for i := int(at) - 1; i >= 0; i -= 1 {
		cand := doc.nodes[i]
		if cand.kind > .Plain && i + int(cand.n) > int(at) {
			if cand.kind == .Array && i > 0 {
				k := doc.nodes[i - 1]
				if k.role == .Key && !tape.is_text_key(k) {
					return tape.Node_Index(i - 1), true
				}
			}
			return tape.NO_NODE, false
		}
	}
	return tape.NO_NODE, false
}

// The namespace URI of the element whose value is node `at` of `doc`, bound to its prefix or the default one.
// `.Missing` for an element in no namespace, and `.Not_Loaded` when `doc` is partial and its facts do not hold the
// declarations around the element: a scan's document kept no facts, or a record's under `.Members` holds those of its
// member and not the root's, and its root is the member, whose name is the record's key.
namespace :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (uri: string, p: tape.Presence) {
	ext: tape.Markup_Ext
	if doc.ext != nil {
		ext, _ = doc.ext.format.(tape.Markup_Ext)
	}
	unbound := tape.Presence.Missing if doc.partial == nil || ext.whole else .Not_Loaded
	if at == tape.ROOT {
		return "", unbound
	}
	key_idx, has_key := element_key_of(doc, at)
	if !has_key {
		return "", .Missing
	}
	return namespace_for_key(doc, &ext, key_idx, at, unbound)
}

@(private)
namespace_for_key :: proc "contextless" (doc: ^tape.Document, ext: ^tape.Markup_Ext, key_idx, at: tape.Node_Index, unbound: tape.Presence) -> (uri: string, p: tape.Presence) {
	key := doc.nodes[key_idx]
	written := tape.span_bytes(doc, key.lo, key.n)
	prefix := written[:max(colon_of(written), 0)]
	if string(prefix) == "xml" {
		return XML_URI, .Found
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
		facts := tape.facts_of(doc, s.node)
		for f, i in facts {
			if f.kind != .Attribute {
				continue
			}
			name, _ := attribute_parts(tape.span_bytes(doc, f.lo, f.n), f.spelling)
			if len(prefix) == 0 && string(name) == "xmlns" || len(prefix) > 0 && len(name) == len(prefix) + 6 && string(name[:6]) == "xmlns:" && string(name[6:]) == string(prefix) {
				uri = declared_uri(doc, ext, f, u32(intrinsics.ptr_sub(raw_data(facts), raw_data(doc.facts)) + i))
				// An empty default declaration undeclares the default namespace.
				return uri, .Found if len(uri) > 0 else .Missing
			}
		}
	}
	return "", unbound
}

// The URI namespace declaration `f`, fact `i` of `doc`, binds: its value as written, or the decode `ext` holds.
@(private)
declared_uri :: proc "contextless" (doc: ^tape.Document, ext: ^tape.Markup_Ext, f: tape.Fact, i: u32) -> string {
	_, value := attribute(doc, f)
	if value.spelling & tape.SPELLING_DECODE == 0 {
		uri, _ := tape.node_text(doc, value, nil)
		return uri
	}
	lo, hi := 0, len(ext.uris)
	for lo < hi {
		mid := (lo + hi) / 2
		if ext.uris[mid].fact < i {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	u := ext.uris[lo]
	return string(ext.uri_text[u.lo:][:u.n])
}

// Whether a step of `path` is a name in `{uri}local` form.
@(private)
expanded_step :: proc "contextless" (path: []tape.Step) -> bool {
	for step in path {
		if name, ok := step.(tape.Name); ok && len(name) > 0 && name[0] == '{' {
			return true
		}
	}
	return false
}

// Whether a step of a path of `d` is a name in `{uri}local` form.
@(private)
expanded_demand :: proc "contextless" (d: ^tape.Demand) -> bool {
	for e in d.edges {
		if name, ok := e.step.(tape.Name); ok && len(name) > 0 && name[0] == '{' {
			return true
		}
	}
	return false
}

// XML's `Format.expanded`: whether key node `key` of `doc` is the expanded name `name`, `{uri}local`, an element whose
// name has the local part `local` in the namespace `uri`, or in none for an empty one. A name with no closing brace is
// no element's.
@(private)
expanded_names :: proc "contextless" (doc: ^tape.Document, key: tape.Node_Index, name: string) -> tape.Presence {
	t := doc.nodes[key]
	close := 1
	for close < len(name) && name[close] != '}' {
		close += 1
	}
	if close == len(name) || tape.is_text_key(t) {
		return .Missing
	}
	written := tape.span_bytes(doc, t.lo, t.n)
	if string(written[colon_of(written) + 1:]) != name[close + 1:] {
		return .Missing
	}
	want_uri := name[1:close]
	val_idx := key + 1
	if val_idx < tape.Node_Index(len(doc.nodes)) && doc.nodes[val_idx].kind == .Array {
		ext: tape.Markup_Ext
		if doc.ext != nil {
			ext, _ = doc.ext.format.(tape.Markup_Ext)
		}
		unbound := tape.Presence.Missing if doc.partial == nil || ext.whole else .Not_Loaded
		arr_end := val_idx + tape.Node_Index(doc.nodes[val_idx].n)
		unknown := false
		for elem := val_idx + 1; elem < arr_end; {
			uri, p := namespace_for_key(doc, &ext, key, elem, unbound)
			if p == .Not_Loaded {
				unknown = true
			} else if uri == want_uri {
				return .Found
			}
			ch := doc.nodes[elem]
			elem += tape.Node_Index(ch.n) if ch.kind > .Plain else 1
		}
		return .Not_Loaded if unknown else .Missing
	}
	uri, p := namespace(doc, val_idx)
	if p == .Not_Loaded {
		return .Not_Loaded
	}
	return .Found if uri == want_uri else .Missing
}

// The byte just past the end of the element at container node `at`, or of the text for the document's node. The close
// of an element is found from its last descendant: a leaf element ends with its own end tag, and each container around
// it with the end tag after its comments and instructions. For normalized `.Array` wrappers or containers holding
// `.Array` children (whose siblings may be reordered by non-adjacent grouping), resolves the true byte-last end.
@(private)
close_end :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (u64, bool) {
	if at == tape.ROOT {
		return doc.root_close, true
	}
	if .Held in doc.flags {
		return 0, false
	}
	src := doc.src
	if doc.nodes[at].kind == .Array {
		is_text_arr := at > tape.ROOT && tape.is_text_key(doc.nodes[at - 1])
		end_idx := at + tape.Node_Index(doc.nodes[at].n)
		max_end := u64(0)
		for j := at + 1; j < end_idx; {
			ch := doc.nodes[j]
			elem_end: u64
			if ch.kind == .Object {
				elem_end = balanced_end(src, ch.lo)
			} else if ch.kind <= .Plain {
				if is_text_arr {
					elem_end = ch.lo + u64(ch.n)
				} else if ch.n == 0 && ch.lo < u64(len(src)) && src[ch.lo] == '/' {
					elem_end = ch.lo + 2
				} else {
					elem_end = end_tag_end(src, ch.lo + u64(ch.n))
				}
			}
			if elem_end > max_end {
				max_end = elem_end
			}
			j += tape.Node_Index(ch.n) if ch.kind > .Plain else 1
		}
		return max_end, true
	}
	// A reference walked over its literal puts nodes in the internal subset, past the bytes of the element they are in.
	if dtd, ok := dtd_of(&doc.ext.format if doc.ext != nil else nil); ok && .In_Place in dtd.flags {
		return balanced_end(src, doc.nodes[at].lo), true
	}
	last := at + tape.Node_Index(doc.nodes[at].n) - 1
	// Walk from `at` down to the container holding `last`; if any container along the path holds a normalized `.Array`
	// child, sibling byte offsets may be non-monotonic, so match the true closing tag iteratively via `balanced_end`.
	count := 0
	c := at
	for {
		count += 1
		next := c
		c_end := c + tape.Node_Index(doc.nodes[c].n)
		for j := c + 1; j < c_end; {
			child := doc.nodes[j]
			if child.kind == .Array {
				return balanced_end(src, doc.nodes[at].lo), true
			}
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
	t := doc.nodes[last]
	p := t.lo + u64(t.n)
	if k := doc.nodes[last - 1]; k.role == .Key && !tape.is_text_key(k) {
		if t.n == 0 && src[t.lo] == '/' {
			p = t.lo + 2
		} else {
			p = end_tag_end(src, p)
		}
	}
	for _ in 0 ..< count {
		p = end_tag_end(src, skip_misc(src, p))
	}
	return p, true
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
			past, _ := markup_end(raw_data(src)[p:], raw_data(src)[len(src):])
			p = u64(intrinsics.ptr_sub(past, raw_data(src)))
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
		// A CDATA section is content, which ends the run.
		if p + 2 >= u64(len(src)) || src[p] != '<' || src[p + 1] != '?' && !(src[p + 1] == '!' && src[p + 2] == '-') {
			return p
		}
		past, closed := markup_end(raw_data(src)[p:], raw_data(src)[len(src):])
		if !closed {
			return p
		}
		p = u64(intrinsics.ptr_sub(past, raw_data(src)))
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
