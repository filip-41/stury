package xml

import "base:runtime"
import core "../core"

// Reads of a built document that need an element's place in it: the namespace its prefix is bound to, an element's
// string value, and where its end tag stands.

// The length of the attribute name at `lo` of `src`, which the white space or the `=` after it ends: in a tag an `=`
// follows the name, and in an attribute-list declaration its type.
@(private)
name_length :: #force_inline proc "contextless" (src: []u8, lo: u64) -> int #no_bounds_check {
	q := lo
	for !is_ws(src[q]) && src[q] != '=' {
		q += 1
	}
	return int(q - lo)
}

// The longest lead an attribute fact's `spelling` holds.
@(private)
LEAD_MAX :: core.ATTRIBUTE_LEAD_MAX

// The `spelling` of an attribute fact whose value starts `lead` bytes past its name's first byte: the lead through the
// opening quote and the closing quote as the tail.
@(private)
attribute_spelling :: #force_inline proc "contextless" (lead: int) -> u16 {
	return core.attribute_spelling(lead, true)
}

// The name and value of attribute fact `f`, as written between its quotes. The fact's lead runs through the opening
// quote unless it saturated, and then the quote is the nearest byte before the closing one that equals it, since a
// value holds no quote of its own kind.
@(private)
attribute_parts :: proc "contextless" (src: []u8, f: core.Fact) -> (name, value: []u8) #no_bounds_check {
	hi := f.lo + u64(f.n)
	name = src[f.lo:f.lo + u64(name_length(src, f.lo))]
	open := f.lo + core.comment_lead(f.spelling)
	if core.comment_lead(f.spelling) == LEAD_MAX {
		open = hi - 1
		for src[open - 1] != src[hi - 1] {
			open -= 1
		}
	}
	return name, src[open:hi - 1]
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

// Fills `chain` with the containers around node `target`, outermost first, and returns their number. A document nested
// deeper than `chain` holds is cut at its outermost containers.
@(private)
ancestors :: proc "contextless" (doc: ^core.Document, target: core.Node_Index, chain: []core.Node_Index) -> int #no_bounds_check {
	n := 0
	c := core.ROOT
	for n < len(chain) {
		chain[n] = c
		n += 1
		j := c + 1
		end := c + core.Node_Index(doc.nodes[c].n)
		descended := false
		for j < end && j <= target {
			t := doc.nodes[j]
			size := core.Node_Index(t.n) if t.kind == .Object || t.kind == .Array else 1
			if target < j + size {
				if j != target {
					c, descended = j, true
				}
				break
			}
			j += size
		}
		if !descended {
			break
		}
	}
	return n
}

// Returns the URI that `prefix` is bound to for the element whose value is node `v`, the declaration's normalized value,
// and whether any declaration binds it. The default namespace is the empty prefix. A value that is not as written is
// decoded into the temporary allocator.
@(private)
declared :: proc "contextless" (doc: ^core.Document, v: core.Node_Index, prefix: []u8) -> (uri: string, found: bool) {
	if string(prefix) == "xml" {
		return XML_URI, true
	}
	f: core.Fact
	if f, found = declared_at(doc, v, prefix); !found {
		chain: [core.MAX_DEPTH]core.Node_Index = ---
		n := ancestors(doc, v, chain[:])
		for k := n - 1; k >= 0 && !found; k -= 1 {
			f, found = declared_at(doc, chain[k], prefix)
		}
		if !found {
			return "", false
		}
	}
	_, value := attribute_parts(doc.src, f)
	dtd: Dtd_View
	if plain_value(value) && !fact_tokenized(doc, dtd_of(&doc.view, &dtd), f) {
		return string(value), true
	}
	context = runtime.default_context()
	uri, _ = attribute_decode(doc, f, value, make([]u8, value_room(doc, value), context.temp_allocator))
	return uri, true
}

@(private)
declared_at :: proc "contextless" (doc: ^core.Document, node: core.Node_Index, prefix: []u8) -> (decl: core.Fact, found: bool) {
	context = runtime.default_context()
	for f in core.all_facts(doc, node) {
		if f.role != .Attribute {
			continue
		}
		name, _ := attribute_parts(doc.src, f)
		if len(prefix) == 0 && string(name) == "xmlns" || len(prefix) > 0 && len(name) == len(prefix) + 6 && string(name[:6]) == "xmlns:" && string(name[6:]) == string(prefix) {
			return f, true
		}
	}
	return {}, false
}

// The bytes that hold the decode of the attribute value `raw`, a span of `doc`'s source.
@(private)
value_room :: proc "contextless" (doc: ^core.Document, raw: []u8) -> int {
	dtd: Dtd_View
	if dtd_of(&doc.view, &dtd) == nil {
		return len(raw)
	}
	return int(min(expansion_room(&dtd, doc.src, raw), u64(max(int))))
}

// Decodes the value `raw` of attribute fact `f` of `doc` into `buf`, with the normalization its declared type asks.
@(private)
attribute_decode :: proc "contextless" (doc: ^core.Document, f: core.Fact, raw: []u8, buf: []u8) -> (string, bool) {
	dtd: Dtd_View
	v := dtd_of(&doc.view, &dtd)
	return attribute_text(raw, buf, v, doc.src, fact_tokenized(doc, v, f))
}

// Whether the DTD `v` of `doc` declares attribute fact `f` of a tokenized type.
@(private)
fact_tokenized :: proc "contextless" (doc: ^core.Document, v: ^Dtd_View, f: core.Fact) -> bool {
	if v == nil || f.node == 0 || int(f.node) > len(doc.nodes) {
		return false
	}
	key := doc.nodes[f.node - 1]
	a := attr_decl(v, doc.src[key.lo:key.lo + u64(key.n)], doc.src[f.lo:f.lo + u64(name_length(doc.src, f.lo))])
	return a != nil && a.tokenized
}

// Splits an expanded name `{uri}local`. A name that is not one returns false.
@(private)
expanded :: proc "contextless" (name: string) -> (uri, local: string, ok: bool) {
	if len(name) == 0 || name[0] != '{' {
		return
	}
	for i in 1 ..< len(name) {
		if name[i] == '}' {
			return name[1:i], name[i + 1:], true
		}
	}
	return
}

// Whether the name `written`, a qualified name of an element when `element` or of an attribute, is the expanded name
// `want` under the declarations in scope at node `v`.
@(private)
name_is :: proc "contextless" (doc: ^core.Document, v: core.Node_Index, written: []u8, want_uri, want_local: string, element: bool) -> bool {
	k := colon_of(written)
	if string(written[k + 1:]) != want_local {
		return false
	}
	if k < 0 && !element {
		return want_uri == ""
	}
	uri, found := declared(doc, v, written[:max(k, 0)])
	if !found {
		return want_uri == ""
	}
	return uri == want_uri
}

// The key at node `i` against `name`. A name in `{uri}local` form matches the element whose qualified name has that
// namespace and local part, and any other name its qualified name as written.
@(private)
key_is :: proc "contextless" (doc: ^core.Document, i: core.Node_Index, name: string) -> bool {
	t := doc.nodes[i]
	if t.spelling & core.SPELLING_SYNTHETIC == core.SPELLING_SYNTHETIC {
		return name == TEXT_KEY
	}
	written := doc.src[t.lo:t.lo + u64(t.n)]
	uri, local, ok := expanded(name)
	if !ok {
		return string(written) == name
	}
	return int(i) + 1 < len(doc.nodes) && name_is(doc, i + 1, written, uri, local, true)
}

// XML's `Readers.attribute`: the name of attribute fact `f` as a `Key` and its value as a `Plain`, the bytes between
// its quotes, which have no kind as an element's text has none. A value with a reference, a tab or a line end, and one
// of a declared type that is not `CDATA`, is decoded by `token_decode`.
@(private)
spelling_attribute :: proc "contextless" (doc: ^core.Document, f: core.Fact) -> (name, value: core.Token) {
	n, v := attribute_parts(doc.src, f)
	name = {lo = f.lo, n = u32(len(n)), kind = .String, role = .Key}
	value = {lo = f.lo + u64(f.n) - 1 - u64(len(v)), n = u32(len(v)), kind = .Plain}
	dtd: Dtd_View
	tokenized := fact_tokenized(doc, dtd_of(&doc.view, &dtd), f)
	if !plain_value(v) || tokenized && !collapsed(v) {
		value.spelling = core.SPELLING_DECODE | SPELLING_ATTRIBUTE | (SPELLING_TOKENIZED if tokenized else 0)
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

// Returns the decoded value of the attribute `name` of the element whose value is node `i`, in `buf` or a span of the
// source, and false for no such attribute or a `buf` too short, which the length of `attribute_room` never is. A name
// is the attribute's qualified name as written, or an expanded name `{uri}local`, which an attribute with no prefix
// never has a namespace for.
attribute_value :: proc(doc: ^core.Document, i: core.Node_Index, name: string, buf: []u8) -> (value: string, ok: bool) {
	if doc.readers == nil || doc.readers.format != rules_of || int(i) >= len(doc.nodes) {
		return "", false
	}
	uri, local, clark := expanded(name)
	for f in core.all_facts(doc, i) {
		if f.role != .Attribute {
			continue
		}
		written, raw := attribute_parts(doc.src, f)
		if clark && string(written) != "xmlns" && !(len(written) > 6 && string(written[:6]) == "xmlns:") {
			if !name_is(doc, i, written, uri, local, false) {
				continue
			}
		} else if string(written) != name {
			continue
		}
		return attribute_decode(doc, f, raw, buf)
	}
	return "", false
}

// Returns a length of `buf` that holds the decoded value of every attribute of the element whose value is node `i`.
attribute_room :: proc(doc: ^core.Document, i: core.Node_Index) -> int {
	room := 0
	if doc.readers == nil || doc.readers.format != rules_of || int(i) >= len(doc.nodes) {
		return 0
	}
	for f in core.all_facts(doc, i) {
		if f.role == .Attribute {
			_, raw := attribute_parts(doc.src, f)
			room = max(room, value_room(doc, raw))
		}
	}
	return room
}

// The facts XML names for node `i`, the value of an element or the document. The name is the key before the value.
@(private)
spelling_fact :: proc(doc: ^core.Document, i: core.Node_Index, name: core.Fact_Name) -> (core.Fact_Value, bool) {
	switch name {
	case .Tag, .Anchor, .Alias, .Style:
		return {}, false
	case .Name, .Content:
		return core.markup_fact(doc, i, name)
	case .Namespace:
		if i == core.ROOT || doc.nodes[i - 1].role != .Key || doc.nodes[i - 1].spelling & core.SPELLING_SYNTHETIC == core.SPELLING_SYNTHETIC {
			return {}, false
		}
		t := doc.nodes[i - 1]
		written := doc.src[t.lo:t.lo + u64(t.n)]
		k := colon_of(written)
		uri, found := declared(doc, i, written[:max(k, 0)])
		if !found || len(uri) == 0 {
			return {}, false
		}
		return {text = uri}, true
	}
	return {}, false
}


// The byte just past the end of the element at container node `i`, or of the root element for the document's node.
// The close of an element is found from its last descendant: a leaf element ends with its own end tag, and each
// container around it with the end tag after its comments and instructions.
@(private)
close_end :: proc(doc: ^core.Document, i: core.Node_Index) -> u64 {
	dtd: Dtd_View
	if v := dtd_of(&doc.view, &dtd); v != nil && .In_Place in v.head.flags {
		return balanced_end(doc, i)
	}
	last := i + core.Node_Index(doc.nodes[i].n) - 1
	t := doc.nodes[last]
	src := doc.src
	p := t.lo + u64(t.n)
	if doc.nodes[last - 1].role == .Key && doc.nodes[last - 1].spelling & core.SPELLING_SYNTHETIC != core.SPELLING_SYNTHETIC {
		if t.n == 0 && src[t.lo] == '/' {
			p = t.lo + 2
		} else {
			p = end_tag_end(src, p)
		}
	}
	// The containers from `i` down to the one that holds `last`.
	count := 0
	c := i
	for {
		count += 1
		next := c
		for j := c + 1; j < c + core.Node_Index(doc.nodes[c].n); {
			child := doc.nodes[j]
			size := core.Node_Index(child.n) if child.kind == .Object || child.kind == .Array else 1
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
	if i == core.ROOT {
		count -= 1
	}
	for _ in 0 ..< count {
		p = end_tag_end(src, skip_misc(src, p))
	}
	return p
}

// `close_end` for a document some of whose nodes were walked over an entity's literal, so a last descendant may lie
// outside the element's bytes: the element's tags are matched from its start tag on. The text between them is
// balanced, since a reference stands for content that closes what it opens.
@(private)
balanced_end :: proc(doc: ^core.Document, i: core.Node_Index) -> u64 {
	src := doc.src
	p := doc.nodes[i].lo
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
		for p < u64(len(src)) && is_ws(src[p]) {
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
