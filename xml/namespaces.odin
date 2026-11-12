package xml

import "base:intrinsics"
import "base:runtime"
import spell "../core/spell"
import core "../core"

// Namespaces in XML 1.0: the declarations in scope while a walk reads, and the judgement of the names of a tag against
// them. An element's prefix may be declared by an attribute that follows the name, so a tag is judged at its end.

@(private)
XML_URI :: "http://www.w3.org/XML/1998/namespace"
@(private)
XMLNS_URI :: "http://www.w3.org/2000/xmlns/"

// A declaration in scope: `prefix` is empty for the default namespace. `depth` is the open count of the element that
// declared it, which pops it when it closes. The `uri` is the attribute's normalized value: its source bytes, or a
// decode on the default heap when `owned`, which the pop frees.
@(private)
Ns_Entry :: struct {
	prefix: Name_Ref,
	uri:    Name_Ref,
	depth:  u64,
	owned:  bool,
}

// Whether an attribute value written as `value` is its own normalized value: it holds no reference and no tab or line
// end, which normalization replaces.
@(private)
plain_value :: proc "contextless" (value: []u8) -> bool {
	for b in value {
		if b == '&' || b == '\t' || b == '\n' || b == '\r' {
			return false
		}
	}
	return true
}

// The normalized value of an `xmlns` attribute written as `value`, of a `tokenized` type when it is, for a value that
// is not its own. The decode is on the default heap, and `ok` is false when memory runs out.
@(private, cold)
bound_uri :: proc "contextless" (w: ^Walk($H), value: []u8, tokenized: bool) -> (uri: []u8, ok: bool) {
	view: ^Dtd_View
	src: []u8
	size := len(value)
	if w.dtd != nil {
		view, src = &w.dtd.view, w.dtd.src
		size = max(size, int(min(expansion_room(view, src, value, 0), u64(max(int)))))
	}
	buf := ([^]u8)(runtime.heap_alloc(max(size, 1), false))
	if buf == nil {
		return nil, false
	}
	s, _ := attribute_text(value, buf[:size], view, src, tokenized)
	// A collapsed value may start past the buffer's first byte, which the pop frees.
	copy(buf[:len(s)], s)
	return buf[:len(s)], true
}

// Whether the `n` bytes at `p` hold a colon.
@(private)
has_colon :: #force_inline proc "contextless" (p: [^]u8, n: int) -> bool #no_bounds_check {
	for i in 0 ..< n {
		if p[i] == ':' {
			return true
		}
	}
	return false
}

// Whether the attribute name at `p` declares_ns a namespace: `xmlns`, or `xmlns:` and a prefix.
@(private)
declares_ns :: #force_inline proc "contextless" (p: [^]u8, n: int) -> bool #no_bounds_check {
	return n >= 5 && p[0] == 'x' && p[1] == 'm' && p[2] == 'l' && p[3] == 'n' && p[4] == 's' && (n == 5 || p[5] == ':')
}

// Splits the name of `n` bytes at `p` into a prefix and a local name. Returns the index of the colon, -1 for a name with
// none, and false for a name that is neither an NCName nor a prefix, a colon and an NCName.
@(private)
qname :: proc "contextless" (p: [^]u8, n: int) -> (colon: int, ok: bool) #no_bounds_check {
	colon = -1
	for i in 0 ..< n {
		if p[i] == ':' {
			colon = i
			break
		}
	}
	if colon < 0 {
		return -1, true
	}
	if colon == 0 || colon == n - 1 || has_colon(p[colon + 1:], n - colon - 1) {
		return colon, false
	}
	return colon, ncname_start(p[colon + 1:], p[n:])
}

// Whether the character at `p` can start an NCName.
@(private)
ncname_start :: proc "contextless" (p, end: [^]u8) -> bool #no_bounds_check {
	switch NAME_BYTE[p[0]] {
	case .Start:
		return true
	case .High:
		r, kind := spell.utf8_char(p, end)
		return kind == .None && name_start_rune(rune_at(p, r))
	case .No, .Rest, .Colon:
	}
	return false
}

// Finds the declaration of `prefix` in scope. The default namespace is the empty prefix.
@(private)
bound :: proc "contextless" (w: ^Walk($H), prefix: string) -> (uri: Name_Ref, found: bool) #no_bounds_check {
	for i := int(w.ns_len) - 1; i >= 0; i -= 1 {
		e := &w.ns[i]
		if int(e.prefix.n) == len(prefix) && string(e.prefix.p[:e.prefix.n]) == prefix {
			return e.uri, true
		}
	}
	return {}, false
}

// What the namespace rules make of the attribute at `name` of `n` bytes, whose value runs from `value` to `value_end`, in
// the tag with `e` open elements and `colon` when the name holds one: a declaration is recorded, and either marks the tag
// for the check of its names at its end. Returns the rule it breaks, or `.No_Memory`.
@(private)
attribute_scope :: #force_no_inline proc "contextless" (w: ^Walk($H), name: [^]u8, n: int, value, value_end: [^]u8, e: u64, colon: bool) -> (kind: core.Fault_Kind, detail: Detail) {
	if declares_ns(name, n) {
		rule, no_memory := declare(w, name, n, value[:intrinsics.ptr_sub(value_end, value)], e)
		if no_memory {
			return .No_Memory, .None
		}
		if rule != .None {
			return .Bad_Char, rule
		}
		w.tag_ns = true
	} else if colon {
		w.tag_ns = true
	}
	return .None, .None
}

// Records the declaration the attribute `name` of `n` bytes makes, valued `value`, in the tag with `e` open elements.
// Returns the rule it breaks, and whether memory ran out.
@(private)
declare :: proc "contextless" (w: ^Walk($H), name: [^]u8, n: int, value: []u8, e: u64) -> (rule: Detail, no_memory: bool) {
	value := value
	tokenized := false
	if w.dtd != nil {
		f := w.frames[e - 1]
		if a := attr_decl(&w.dtd.view, w.base[f.tag_lo + 1:][:f.name_n], name[:n]); a != nil {
			tokenized = a.tokenized
		}
	}
	owned := tokenized || !plain_value(value)
	if owned {
		decoded, ok := bound_uri(w, value, tokenized)
		if !ok {
			return .None, true
		}
		value = decoded
	}
	entry := Ns_Entry {
		uri   = {raw_data(value), u64(len(value))},
		depth = e,
		owned = owned,
	}
	defer if owned && rule != .None {
		runtime.heap_free(raw_data(value))
	}
	if n == 5 {
		if string(value) == XML_URI || string(value) == XMLNS_URI {
			return .Reserved_Namespace, false
		}
	} else {
		prefix := name[6:n]
		if n == 6 || has_colon(raw_data(prefix), len(prefix)) || !ncname_start(raw_data(prefix), name[n:]) {
			return .Qualified_Name, false
		}
		switch string(prefix) {
		case "xmlns":
			return .Reserved_Prefix, false
		case "xml":
			return .None if string(value) == XML_URI else .Reserved_Prefix, false
		}
		if string(value) == XML_URI || string(value) == XMLNS_URI {
			return .Reserved_Namespace, false
		}
		if len(value) == 0 {
			return .Empty_Binding, false
		}
		entry.prefix = {raw_data(prefix), u64(len(prefix))}
	}
	if w.ns_len == w.ns_cap {
		cap := max(8, 2 * w.ns_cap)
		grown := runtime.heap_resize(w.ns, int(cap) * size_of(Ns_Entry))
		if grown == nil {
			if owned {
				runtime.heap_free(raw_data(value))
			}
			return .None, true
		}
		w.ns, w.ns_cap = ([^]Ns_Entry)(grown), cap
	}
	w.ns[w.ns_len] = entry
	w.ns_len += 1
	return .None, false
}

@(private)
Expanded :: struct {
	uri:   Name_Ref,
	local: Name_Ref,
}

// Judges the names of the start tag from `tag` (its `<`) to `tag_end` (its `>` or `/`), whose declarations are all in
// scope: the element's prefix, each attribute's prefix, and that no two attributes share a namespace and a local
// name. The defaults `dtd` gives the tag count as its attributes.
@(private, cold)
tag_names :: #force_no_inline proc "contextless" (w: ^Walk($H), tag, tag_end: [^]u8, dtd: ^Dtd = nil) -> (kind: core.Fault_Kind, rule: Detail) {
	q, _ := name_end(tag[1:], tag_end)
	n := intrinsics.ptr_sub(q, tag[1:])
	if k, ok := qname(tag[1:], n); !ok {
		return .Bad_Char, .Qualified_Name
	} else if k >= 0 {
		prefix := string(tag[1:][:k])
		if prefix == "xmlns" {
			return .Bad_Char, .Reserved_Prefix
		}
		if _, found := bound(w, prefix); prefix != "xml" && !found {
			return .Bad_Char, .Unbound_Prefix
		}
	}
	seen := Expanded_Set{}
	seen.list = seen.stack[:]
	defer if seen.heap != nil {
		runtime.heap_free(seen.heap)
	}
	p := q
	for {
		p = skip_ws(p, tag_end)
		if p >= tag_end || p[0] == '>' || p[0] == '/' {
			break
		}
		name_at := p
		p, _ = name_end(p, tag_end)
		an := intrinsics.ptr_sub(p, name_at)
		p = skip_ws(p, tag_end)[1:]
		p = skip_ws(p, tag_end)
		quote := p[0]
		p = p[1:]
		for p[0] != quote {
			p = p[1:]
		}
		p = p[1:]
		if kind, rule = expanded_add(w, &seen, name_at, an); kind != .None {
			return
		}
	}
	if dtd != nil {
		for i := dtd_find(&dtd.view, .Element, tag[1:][:n]); i != NO_DECL; i = dtd.attrs[i].next {
			a := dtd.attrs[i]
			name_at := w.base[a.fact_lo:]
			if !a.defaulted || tag_has(w, name_at, u64(a.name_n)) {
				continue
			}
			if kind, rule = expanded_add(w, &seen, name_at, int(a.name_n)); kind != .None {
				return
			}
		}
	}
	return .None, .None
}

// The expanded names of a tag's attributes, in `stack` up to eight and then on the default heap.
@(private)
Expanded_Set :: struct {
	stack: [8]Expanded,
	list:  []Expanded,
	heap:  [^]Expanded,
	count: int,
}

// Judges the attribute name of `an` bytes at `name_at`, which no declaration names: its prefix is bound, and its
// expanded name is not in `seen`, which it joins.
@(private)
expanded_add :: proc "contextless" (w: ^Walk($H), seen: ^Expanded_Set, name_at: [^]u8, an: int) -> (kind: core.Fault_Kind, rule: Detail) {
	if declares_ns(name_at, an) {
		return .None, .None
	}
	k, ok := qname(name_at, an)
	if !ok {
		return .Bad_Char, .Qualified_Name
	}
	if k < 0 {
		return .None, .None
	}
	prefix := string(name_at[:k])
	uri: Name_Ref
	if prefix == "xml" {
		uri = {raw_data(transmute([]u8)string(XML_URI)), len(XML_URI)}
	} else {
		found: bool
		if uri, found = bound(w, prefix); !found {
			return .Bad_Char, .Unbound_Prefix
		}
	}
	if seen.count == len(seen.list) {
		grown := ([^]Expanded)(runtime.heap_alloc(2 * len(seen.list) * size_of(Expanded), false))
		if grown == nil {
			return .No_Memory, .None
		}
		intrinsics.mem_copy_non_overlapping(grown, raw_data(seen.list), len(seen.list) * size_of(Expanded))
		if seen.heap != nil {
			runtime.heap_free(seen.heap)
		}
		seen.heap, seen.list = grown, grown[:2 * len(seen.list)]
	}
	local := Name_Ref{name_at[k + 1:], u64(an - k - 1)}
	for j in 0 ..< seen.count {
		x := seen.list[j]
		if x.local.n == local.n && x.uri.n == uri.n && string(x.local.p[:local.n]) == string(local.p[:local.n]) && string(x.uri.p[:uri.n]) == string(uri.p[:uri.n]) {
			return .Bad_Char, .Duplicate_Expanded
		}
	}
	seen.list[seen.count] = {uri, local}
	seen.count += 1
	return .None, .None
}
