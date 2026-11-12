package xml

import "base:intrinsics"
import "base:runtime"
import spell "../core/spell"
import core "../core"

// References to the entities of the DTD while a walk reads: what each may stand for where it stands, the sizes the
// expansion budget adds, the descent into a replacement text that holds markup, which the walk reads over the
// entity's literal in the internal subset, and the attribute defaults a tag receives.

// The flags of an entity that its references take on.
@(private)
REFERENCE_FLAGS :: Entity_Flags{.Markup, .Element, .Respelled, .Cdata_End, .External_Ref, .Unparsed_Ref, .Undeclared_Ref}

// The character a predefined entity stands for, by name.
@(private)
predefined :: #force_inline proc "contextless" (name: []u8) -> (r: rune, ok: bool) {
	switch string(name) {
	case "lt":
		return '<', true
	case "gt":
		return '>', true
	case "amp":
		return '&', true
	case "apos":
		return '\'', true
	case "quot":
		return '"', true
	}
	return 0, false
}

// Judges the reference at `p`, a well-formed `&name;` to no predefined entity, in content or in an attribute value.
// Returns its length and its fault, or one past the index of the entity to descend into, whose replacement text holds
// markup. A reference at the document's level adds its entity's size to the expansion total.
@(private, cold)
entity_reference :: #force_no_inline proc "contextless" (d: ^Dtd, p, end: [^]u8, attr: bool) -> (n: int, kind: core.Fault_Kind, detail: Detail, entity: u32) #no_bounds_check {
	t, _ := name_end(p[1:], end)
	n = intrinsics.ptr_sub(t, p) + 1
	name := p[1:][:n - 2]
	if _, ok := predefined(name); ok {
		return n, .None, .None, 0
	}
	i := dtd_find(&d.view, .General, name)
	if i == NO_DECL {
		if .Html in d.head.flags {
			if _, ok := spell.entity_named(name); ok {
				return n, .None, .None, 0
			}
		}
		kind, detail = unread(d, true)
		return
	}
	flags := d.entities[i].flags
	if .Unparsed in flags {
		return n, .Bad_Char, .Unparsed_Entity, 0
	}
	if .External in flags {
		if attr {
			return n, .Bad_Char, .External_Entity, 0
		}
		kind, detail = unread(d, false)
		return
	}
	size, refs, mk, md := measure(d, i, 0)
	if mk != .None {
		return n, mk, md, 0
	}
	switch {
	case .Unparsed_Ref in refs:
		return n, .Bad_Char, .Unparsed_Entity, 0
	case .External_Ref in refs && attr:
		return n, .Bad_Char, .External_Entity, 0
	case .External_Ref in refs:
		if kind, detail = unread(d, false); kind != .None {
			return
		}
	case .Undeclared_Ref in refs:
		if kind, detail = unread(d, true); kind != .None {
			return
		}
	}
	if .Markup in refs {
		if attr {
			return n, .Bad_Char, .Attribute_Lt, 0
		}
		if .Respelled in refs {
			return n, .Bad_Char, .Entity_Respelled, 0
		}
	} else if .Cdata_End in refs && !attr {
		return n, .Bad_Char, .Cdata_End, 0
	}
	if d.block != nil && d.depth == 0 {
		if !budget(d, size) {
			return n, .Too_Wide, .Expansion, 0
		}
	}
	if .Markup in refs && !attr {
		return n, .Bad_Char, .None, i + 1
	}
	return n, .None, .None, 0
}

// Adds `size` to the expansion total. Returns false past the limit.
@(private)
budget :: #force_inline proc "contextless" (d: ^Dtd, size: u64) -> bool {
	d.total = saturating_add(d.total, size)
	return d.total <= d.limit
}

// The fault of a reference to an entity whose text is not read, an undeclared one when `undeclared`: a document whose
// DTD was read whole, or that says it is standalone, declares every entity it refers to.
@(private)
unread :: proc "contextless" (d: ^Dtd, undeclared: bool) -> (core.Fault_Kind, Detail) {
	if undeclared && d.head.flags & {.Complete, .Standalone} != {} {
		return .Bad_Char, .Undeclared_Entity
	}
	if d.tolerate {
		return .None, .None
	}
	return .Bad_Char, .Unread_Entity
}

// The size the replacement text of entity `i` expands to with the references it holds, and the flags it takes on from
// them, or the fault of a reference in it. A sealed DTD keeps both on the entity, so each is measured once.
@(private)
measure :: proc "contextless" (d: ^Dtd, i: u32, nest: int) -> (size: u64, flags: Entity_Flags, kind: core.Fault_Kind, detail: Detail) #no_bounds_check {
	e := &d.entities[i]
	if .Measured in e.flags {
		return e.size, e.flags & REFERENCE_FLAGS, .None, .None
	}
	if .Measuring in e.flags {
		return 0, {}, .Bad_Char, .Recursion
	}
	if nest >= MAX_NEST {
		return 0, {}, .Too_Deep, .None
	}
	e.flags += {.Measuring}
	defer d.entities[i].flags -= {.Measuring}
	text := entity_text(&d.view, d.src, e)
	q := raw_data(text)
	end := q[len(text):]
	for q < end {
		c := q[0]
		switch c {
		case '<':
			flags += {.Markup}
			s := markup_end(q, end)
			if s == q {
				if intrinsics.ptr_sub(end, q) >= 2 && NAME_BYTE[q[1]] != .No && NAME_BYTE[q[1]] != .Rest {
					flags += {.Element}
				}
				s = q[1:]
			}
			size += u64(intrinsics.ptr_sub(s, q))
			q = s
			continue
		case '&':
			if intrinsics.ptr_sub(end, q) >= 2 && q[1] == '#' {
				n, k, dt := reference_slow(q, end)
				if k != .None {
					return 0, {}, .Bad_Char if k == .Truncated else k, .Reference if k == .Truncated else dt
				}
				size += u64(n)
				q = q[n:]
				continue
			}
			t, nf := name_end(q[1:], end)
			if nf != .None || t >= end || t[0] != ';' {
				return 0, {}, .Bad_Char, .Reference
			}
			n := intrinsics.ptr_sub(t, q) + 1
			name := q[1:][:n - 2]
			q = q[n:]
			if _, ok := predefined(name); ok {
				size += u64(n)
				continue
			}
			j := dtd_find(&d.view, .General, name)
			if j == NO_DECL {
				if .Html in d.head.flags {
					if value, ok := spell.entity_named(name); ok {
						size += u64(max(len(value), n))
						continue
					}
				}
				flags += {.Undeclared_Ref}
				size += u64(n)
				continue
			}
			ef := d.entities[j].flags
			if .Unparsed in ef {
				flags += {.Unparsed_Ref}
			} else if .External in ef {
				flags += {.External_Ref}
				size += u64(n)
			} else {
				s, f, k, dt := measure(d, j, nest + 1)
				if k != .None {
					return 0, {}, k, dt
				}
				size = saturating_add(size, s)
				flags += f
			}
			e = &d.entities[i]
			continue
		case ']':
			if intrinsics.ptr_sub(end, q) >= 3 && q[1] == ']' && q[2] == '>' {
				flags += {.Cdata_End}
			}
		}
		size += 1
		q = q[1:]
	}
	if .Markup in flags && (.Lit_Stored in e.flags || .Stored in e.flags && respelled(raw_data(d.src)[e.lit_lo:][:e.lit_n])) {
		flags += {.Respelled}
	}
	if d.block != nil {
		e.size = size
		e.flags += flags + {.Measured}
	}
	return
}

// One past the comment, processing instruction or CDATA section at `q`, a `<`, or `q` for any other markup. The text
// was judged, or is judged where its markup is walked, so an unclosed one ends at `end`.
@(private)
markup_end :: proc "contextless" (q, end: [^]u8) -> [^]u8 #no_bounds_check {
	room := intrinsics.ptr_sub(end, q)
	close: string
	switch {
	case room >= 4 && string(q[:4]) == "<!--":
		close = "-->"
	case room >= 9 && string(q[:9]) == "<![CDATA[":
		close = "]]>"
	case room >= 2 && q[1] == '?':
		close = "?>"
	case:
		return q
	}
	for s := q[2:]; s < end; s = s[1:] {
		if intrinsics.ptr_sub(end, s) >= len(close) && string(s[:len(close)]) == close {
			return s[len(close):]
		}
	}
	return end
}

// Whether a character reference in the literal `lit` stands where its character would read as something else than
// the reference does: as markup or a reference in character data, as a quote, a markup character or a line end in an
// attribute value, and anywhere inside a tag, a comment, an instruction or a CDATA section. A replacement text that
// holds markup and such a character is not the literal's markup, so it cannot be walked over the literal.
@(private)
respelled :: proc "contextless" (lit: []u8) -> bool #no_bounds_check {
	Place :: enum u8 {
		Data,
		Tag,
		Value,
		Close, // a comment, an instruction or a CDATA section, to `close`
	}
	place := Place.Data
	quote: u8
	close: string
	for i := 0; i < len(lit); i += 1 {
		c := lit[i]
		if c == '&' && i + 1 < len(lit) && lit[i + 1] == '#' {
			if place == .Tag || place == .Close {
				return true
			}
			_, r, _ := decode_reference(lit[i:])
			switch place {
			case .Data:
				if r == '<' || r == '&' || r == '>' || r == ']' {
					return true
				}
			case .Value:
				if r == '<' || r == '&' || r == '"' || r == '\'' || r == '\t' || r == '\n' || r == '\r' {
					return true
				}
			case .Tag, .Close:
			}
			continue
		}
		switch place {
		case .Data:
			if c == '<' {
				rest := string(lit[i:])
				switch {
				case len(rest) >= 4 && rest[:4] == "<!--":
					place, close = .Close, "-->"
				case len(rest) >= 9 && rest[:9] == "<![CDATA[":
					place, close = .Close, "]]>"
				case len(rest) >= 2 && rest[1] == '?':
					place, close = .Close, "?>"
				case:
					place = .Tag
				}
			}
		case .Tag:
			if c == '"' || c == '\'' {
				place, quote = .Value, c
			} else if c == '>' {
				place = .Data
			}
		case .Value:
			if c == quote {
				place = .Tag
			}
		case .Close:
			if len(lit) - i >= len(close) && string(lit[i:][:len(close)]) == close {
				place = .Data
				i += len(close) - 1
			}
		}
	}
	return false
}

// The bytes that hold the decode of `span`, a run of `src` or of a replacement text that may refer to the entities of
// `v`: its length, with each reference to an entity whose text is read counted at its replacement text's size.
@(private)
expansion_room :: proc "contextless" (v: ^Dtd_View, src, span: []u8, nest := 0) -> u64 #no_bounds_check {
	room := u64(len(span))
	if nest >= MAX_NEST {
		return room
	}
	for i := 0; i < len(span); i += 1 {
		if span[i] != '&' || i + 1 >= len(span) || span[i + 1] == '#' {
			continue
		}
		k := i + 1
		for k < len(span) && span[k] != ';' {
			k += 1
		}
		if k >= len(span) {
			break
		}
		name := span[i + 1:k]
		i = k
		if _, ok := predefined(name); ok {
			continue
		}
		j := dtd_find(v, .General, name)
		if j == NO_DECL {
			if .Html in v.head.flags {
				if value, ok := spell.entity_named(name); ok {
					room += u64(len(value))
				}
			}
			continue
		}
		e := &v.entities[j]
		if e.flags & {.External, .Unparsed} != {} {
			continue
		}
		size := e.size if .Measured in e.flags else expansion_room(v, src, entity_text(v, src, e), nest + 1)
		room = saturating_add(room, size)
	}
	return room
}

// `p` is at the reference that ends a text run in the content of the element with `d` open elements, or at the end
// of a replacement text's literal. Descends into the literal of an entity whose replacement holds markup, returns
// from a literal to the text after its reference, or gives the run's fault.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_halt :: #force_no_inline proc "contextless" (p, end: [^]u8, d: u64, w: ^Walk($H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	r := w.halt
	t := w.dtd
	if t == nil {
		return run_fault(w, hs, r)
	}
	f := &w.frames[d - 1]
	if r.entity != 0 {
		amp := r.q
		if amp > p {
			f.flags += {.Seen}
		}
		if r.decode {
			f.flags += {.Decode}
		}
		i := r.entity - 1
		e := t.entities[i]
		name_after, _ := name_end(amp[1:], end)
		if t.depth == t.stack_cap {
			cap := max(8, 2 * t.stack_cap)
			grown := runtime.heap_resize(t.stack, int(cap) * size_of(Entity_Frame))
			if grown == nil {
				return fault(w, hs, amp, .No_Memory)
			}
			t.stack, t.stack_cap = ([^]Entity_Frame)(grown), cap
		}
		t.stack[t.depth] = {name_after[1:], end, amp, d, f.tag_lo, i}
		t.depth += 1
		t.head.flags += {.In_Place}
		lit := w.base[e.lit_lo:]
		if .Element in e.flags {
			if res, done := open_content(w, on, &hs, f, d, amp); done {
				return res
			}
			f.text_lo = e.lit_lo
		} else {
			f.flags += {.Decode}
		}
		return #must_tail st_content(lit, lit[e.lit_n:], d, w, hs.a, hs.b, hs.c, on)
	}
	if r.kind == .Truncated && r.q == end && t.depth > 0 {
		fr := t.stack[t.depth - 1]
		if d != fr.depth || f.tag_lo != fr.tag_lo {
			return fault(w, hs, fr.at, .Bad_Char, .Entity_Boundary)
		}
		t.depth -= 1
		if end > p {
			f.flags += {.Seen}
		}
		if r.decode {
			f.flags += {.Decode}
		}
		if .Element in t.entities[fr.entity].flags {
			if res, done := text_member(w, on, &hs, f, end); done {
				return res
			}
			f.text_lo = at(w, fr.resume)
		}
		return #must_tail st_content(fr.resume, fr.end, d, w, hs.a, hs.b, hs.c, on)
	}
	return run_fault(w, hs, r)
}

// The result of a walk over a text with a DTD, `r`: a text that ends inside a replacement text is the fault of the
// reference to it. Frees the DTD, or hands its sealed block to `kept`.
@(private)
dtd_end :: proc "contextless" (w: ^Walk($H), r: u64, kept: ^[]u8) -> u64 {
	t := w.dtd
	r := r
	if t.depth > 0 && core.Fault_Kind(r & 0xff) == .Truncated {
		r = core.fault_at(at(w, t.stack[t.depth - 1].at), .Bad_Char, u8(Detail.Entity_Boundary))
	}
	if kept != nil && t.block != nil {
		kept^ = t.block[:t.block_n]
		t.block = nil
	}
	dtd_free(t)
	w.dtd = nil
	return r
}

// `p` is at the `>` or the `/` that ends the start tag of the element with `e` open elements, whose element type has
// attribute-list declarations or may have. Gives each default of an attribute the tag does not have as a fact, which
// spans its declaration, then judges the tag's names and goes on as `st_open_done` or `st_empty_done`.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_defaults :: #force_no_inline proc "contextless" (p, end: [^]u8, e: u64, w: ^Walk($H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	t := w.dtd
	f := &w.frames[e - 1]
	tag := w.base[f.tag_lo:]
	qualified := false
	for i := dtd_find(&t.view, .Element, tag[1:][:f.name_n]); i != NO_DECL; i = t.attrs[i].next {
		a := t.attrs[i]
		name := w.base[a.fact_lo:]
		if !a.defaulted || tag_has(w, name, u64(a.name_n)) {
			continue
		}
		if !budget(t, a.size) {
			return fault(w, hs, tag, .Too_Wide, .Expansion)
		}
		if declares_ns(name, int(a.name_n)) {
			_, value := attribute_parts(t.src, {lo = a.fact_lo, n = a.fact_n, spelling = attribute_spelling(int(a.lead))})
			rule, no_memory := declare(w, name, int(a.name_n), value, e)
			if no_memory {
				return fault(w, hs, tag, .No_Memory)
			}
			if rule != .None {
				return fault(w, hs, tag, .Bad_Char, rule)
			}
		}
		qualified ||= a.qualified
		if x := emit(w, on, &hs, .Plain, .Attribute, a.fact_lo, int(a.fact_n), attribute_spelling(int(a.lead))); x != .Next {
			return refused(w, hs, x, p)
		}
	}
	// A default with no prefix has no namespace, so neither its prefix nor its expanded name needs judging.
	if w.tag_ns || qualified {
		if kind, rule := tag_names(w, tag, p, t if qualified else nil); kind != .None {
			return fault(w, hs, tag, kind, rule)
		}
	}
	if w.nattr > ATTR_SLOTS {
		runtime.heap_free(w.table)
		w.table = nil
	}
	if p[0] == '>' {
		return #must_tail st_content(p[1:], end, e, w, hs.a, hs.b, hs.c, on)
	}
	if x := emit(w, on, &hs, .Plain, .Value, at(w, p), 0); x != .Next {
		return refused(w, hs, x, p[2:])
	}
	return #must_tail st_closed(p[2:], end, e, w, hs.a, hs.b, hs.c, on)
}

// Whether the tag being read has the attribute named by the `n` bytes at `name`.
@(private)
tag_has :: proc "contextless" (w: ^Walk($H), name: [^]u8, n: u64) -> bool #no_bounds_check {
	if w.nattr <= ATTR_SLOTS {
		for j in 0 ..< w.nattr {
			if w.names[j].n == n && string(w.names[j].p[:n]) == string(name[:n]) {
				return true
			}
		}
		return false
	}
	if w.table == nil {
		return false
	}
	cap := table_cap(w.nattr)
	h := u64(14695981039346656037)
	for b in name[:n] {
		h = (h ~ u64(b)) * 1099511628211
	}
	for i := h & (cap - 1); ; i = (i + 1) & (cap - 1) {
		if w.table[i].p == nil {
			return false
		}
		if w.table[i].n == n && string(w.table[i].p[:n]) == string(name[:n]) {
			return true
		}
	}
}
