package xml

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:lib/core/hook"
import "stury:lib/ops/build"

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
entity_reference :: #force_no_inline proc "contextless" (d: ^Dtd, p, end: [^]u8, attr: bool) -> (n: int, kind: tape.Fault_Kind, detail: Detail, entity: u32) #no_bounds_check {
	t, _ := name_end(p[1:], end)
	n = intrinsics.ptr_sub(t, p) + 1
	name := p[1:][:n - 2]
	if _, ok := predefined(name); ok {
		return n, .None, .None, 0
	}
	i := dtd_find(&d.view, .General, name)
	if i == NO_DECL {
		if .Html in d.flags {
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
	if d.sealed && d.depth == 0 && !budget(d, size) {
		return n, EXPANSION, .None, 0
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
unread :: proc "contextless" (d: ^Dtd, undeclared: bool) -> (tape.Fault_Kind, Detail) {
	if undeclared && d.flags & {.Complete, .Standalone} != {} {
		return .Bad_Char, .Undeclared_Entity
	}
	if d.tolerate {
		d.took = true
		return .None, .None
	}
	return .Bad_Char, .Unread_Entity
}

// The size the replacement text of entity `i` expands to with the references it holds, and the flags it takes on from
// them, or the fault of a reference in it. A sealed DTD keeps both on the entity, so each is measured once.
@(private)
measure :: proc "contextless" (d: ^Dtd, i: u32, nest: int) -> (size: u64, flags: Entity_Flags, kind: tape.Fault_Kind, detail: Detail) #no_bounds_check {
	e := &d.entities[i]
	if .Measured in e.flags {
		return e.size, e.flags & REFERENCE_FLAGS, .None, .None
	}
	if .Measuring in e.flags {
		return 0, {}, .Bad_Char, .Recursion
	}
	if nest >= MAX_NEST {
		return 0, {}, TOO_DEEP, .None
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
			s, _ := markup_end(q, end)
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
				if .Html in d.flags {
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
	if d.sealed {
		e.size = size
		e.flags += flags + {.Measured}
	}
	return
}

// The text that ends the comment, processing instruction or CDATA section `s` opens, empty when it opens none.
@(private)
markup_close :: proc "contextless" (s: string) -> string {
	switch {
	case len(s) >= 4 && s[:4] == "<!--":
		return "-->"
	case len(s) >= 9 && s[:9] == "<![CDATA[":
		return "]]>"
	case len(s) >= 2 && s[1] == '?':
		return "?>"
	}
	return ""
}

// One past the comment, processing instruction or CDATA section at `q`, a `<`, and true, or `end` and false for one
// that `end` comes before the close of, and `q` and false for any other markup. A close starts past the opening.
@(private)
markup_end :: proc "contextless" (q, end: [^]u8) -> (past: [^]u8, closed: bool) #no_bounds_check {
	n := intrinsics.ptr_sub(end, q)
	close := markup_close(string(q[:n]))
	if close == "" {
		return q, false
	}
	open := 2 if close == "?>" else 4 if close == "-->" else 9
	for j := open + len(close) - 1; j < n; j += 1 {
		k := kernel.index_byte(q[j:n], '>')
		if k < 0 {
			break
		}
		j += k
		if string(q[j + 1 - len(close):][:len(close)]) == close {
			return q[j + 1:], true
		}
	}
	return end, false
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
				place, close = .Close, markup_close(string(lit[i:]))
				if close == "" {
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
			if .Html in v.flags {
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
st_halt :: #force_no_inline proc "contextless" (p, end: [^]u8, d: u64, w: ^Walk($H, $LAX), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> u64 {
	hs := hook.Regs{s0, s1, s2}
	r := w.halt
	t := w.dtd
	if t == nil {
		return run_fault(w, hs, r)
	}
	f := &w.stack[d - 1]
	if r.entity != 0 {
		amp := r.q
		if amp > p {
			f.flags += {.Seen, .Chars}
		}
		if r.decode {
			f.flags += {.Decode}
		}
		if r.dtd {
			f.flags += {.Dtd}
		}
		i := r.entity - 1
		e := t.entities[i]
		name_after, _ := name_end(amp[1:], end)
		if t.depth == t.stack_cap {
			cap := max(8, 2 * t.stack_cap)
			grown := regrab(t.grab, t.stack, int(t.stack_cap) * size_of(Entity_Frame), int(cap) * size_of(Entity_Frame))
			if grown == nil {
				return fault(w, hs, amp, NO_MEMORY)
			}
			t.stack, t.stack_cap = ([^]Entity_Frame)(grown), cap
		}
		t.stack[t.depth] = {name_after[1:], end, amp, d, f.tag, i}
		t.depth += 1
		t.flags += {.In_Place}
		lit := w.subset[e.lit_lo - t.subset_lo:] if w.subset != nil else w.base[e.lit_lo:]
		if .Element in e.flags {
			// The element's `Object` opens before its first child, whose start would deepen the walk, does.
			if d >= w.depth {
				if kind := deepen(w, &hs, amp); kind != .None {
					return fault(w, hs, amp, kind)
				}
			}
			if res, done := open_content(w, on, &hs, f, d, amp); done {
				return res
			}
			f.text_lo = e.lit_lo
		} else {
			f.flags += {.Decode, .Dtd}
		}
		when LAX {
			if w.subset != nil {
				w.in_subset = true
				dtd_bind_hook_src(w, t, true)
			}
		}
		return #must_tail st_content(lit, lit[e.lit_n:], d, w, hs.a, hs.b, hs.c, on)
	}
	if r.kind == .Truncated && r.q == end && t.depth > 0 {
		fr := t.stack[t.depth - 1]
		if d != fr.depth || f.tag != fr.tag {
			when LAX {
				if w.subset != nil {
					w.in_subset = t.depth > 1
					if !w.in_subset {
						dtd_bind_hook_src(w, t, false)
					}
				}
			}
			return fault(w, hs, fr.at, .Bad_Char, .Entity_Boundary)
		}
		t.depth -= 1
		if end > p {
			f.flags += {.Seen, .Chars}
		}
		if r.decode {
			f.flags += {.Decode}
		}
		if r.dtd {
			f.flags += {.Dtd}
		}
		if .Element in t.entities[fr.entity].flags {
			if res, done := text_member(w, on, &hs, f, end); done {
				return res
			}
			when LAX {
				if t.depth == 0 {
					w.in_subset = false
					if w.subset != nil {
						dtd_bind_hook_src(w, t, false)
					}
				}
			}
			f.text_lo = at(w, fr.resume)
		} else {
			when LAX {
				if t.depth == 0 {
					w.in_subset = false
					if w.subset != nil {
						dtd_bind_hook_src(w, t, false)
					}
				}
			}
		}
		return #must_tail st_content(fr.resume, fr.end, d, w, hs.a, hs.b, hs.c, on)
	}
	return run_fault(w, hs, r)
}

// Points `Finder` / `Scanner` key/source slices at the copied DTD subset while walking a markup entity literal inside
// `w.subset`, and restores them to `t.src` on exit.
@(private)
dtd_bind_hook_src :: #force_inline proc "contextless" (w: ^Walk($H, $LAX), t: ^Dtd, in_subset: bool) {
	when H == build.Finder || H == build.Scanner {
		src := tape.piece_src(w.subset[:t.subset_hi - t.subset_lo], t.subset_lo) if in_subset else t.src
		when H == build.Finder {
			w.hooks.src = src
			w.hooks.key_text = src
		} else {
			w.hooks.key_text = src
		}
	}
}

// The result of a walk over a text with a DTD, `r`: a text that ends inside a replacement text is the fault of the
// reference to it. Gives the document a build or a scan made the DTD's tables, and frees the DTD.
@(private)
dtd_end :: proc "contextless" (w: ^Walk($H, $LAX), r: u64) -> u64 {
	t := w.dtd
	r := r
	if t.depth > 0 && tape.Fault_Kind(r & 0xff) == .Truncated {
		when LAX {
			if w.subset != nil {
				w.in_subset = t.depth > 1
			}
		}
		r = fault_at(at(w, t.stack[t.depth - 1].at), .Bad_Char, u8(Detail.Entity_Boundary))
	}
	when LAX {
		if w.in_subset {
			w.in_subset = false
			dtd_bind_hook_src(w, t, false)
		}
	}
	if (u8(r) == 0 || u8(r) == hook.WALK_STOPPED) && !dtd_give(t, w.base, w.hooks, w.ctx) {
		r = fault_at(0, NO_MEMORY)
	}
	dtd_free(t)
	w.dtd = nil
	return r
}

// Whether a text may need the tables of `d` to decode: they declare an entity, name the HTML standard's references, or
// the walk tolerated a reference whose text it did not read. A default's value refers to the DTD only then.
@(private)
dtd_decodes :: #force_inline proc "contextless" (d: ^Dtd) -> bool {
	return len(d.entities) > 0 || .Html in d.flags || d.took
}

// Gives the document hook `h` makes, a build's or a scan's, a copy of the tables of `d`, the DTD of the text at `base`,
// when its texts may decode by them. False when memory runs out.
@(private)
dtd_give :: proc "contextless" (d: ^Dtd, base: [^]u8, h: ^$H, ctx: ^runtime.Context) -> bool {
	when H == build.Builder || H == build.Scanner {
		when H == build.Builder {
			doc := &h.doc
		} else {
			doc := &h.b.doc
		}
		if dtd_decodes(d) && doc.ext == nil {
			doc.ext = dtd_keep(d, base, doc.allocator, ctx)
			return doc.ext != nil
		}
	}
	return true
}

// `p` is at the `>` or the `/` that ends the start tag of the element with `e` open elements, whose element type has
// attribute-list declarations or may have. Gives each default of an attribute the tag does not have as a fact, which
// spans its declaration, then judges the tag's names and goes on as `st_open_done` or `st_empty_done`.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_defaults :: #force_no_inline proc "contextless" (p, end: [^]u8, e: u64, w: ^Walk($H, $LAX), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> u64 {
	hs := hook.Regs{s0, s1, s2}
	t := w.dtd
	f := &w.stack[e - 1]
	tag := f.tag
	qualified := false
	for i := dtd_find(&t.view, .Element, tag[1:][:f.name_n]); i != NO_DECL; i = t.attrs[i].next {
		a := t.attrs[i]
		name := raw_data(t.bytes[a.name_lo:])
		if !a.defaulted || tag_has(w, name, u64(a.name_n)) {
			continue
		}
		if !budget(t, a.size) {
			return fault(w, hs, tag, EXPANSION)
		}
		spelling := tape.attribute_spelling(int(a.lead), true) | (ATTRIBUTE_DTD if dtd_decodes(t) else 0) | (ATTRIBUTE_TOKENIZED if a.tokenized else 0)
		if declares_ns(name, int(a.name_n)) {
			spelling |= ATTRIBUTE_NS
			fact_bytes := w.subset[a.fact_lo - t.subset_lo:][:a.fact_n] if w.subset != nil else t.src[a.fact_lo:][:a.fact_n]
			_, value := attribute_parts(fact_bytes, spelling)
			rule, no_memory := declare(w, name, int(a.name_n), value, e)
			if no_memory {
				return fault(w, hs, tag, NO_MEMORY)
			}
			if rule != .None {
				return fault(w, hs, tag, .Bad_Char, rule)
			}
		}
		qualified ||= a.qualified
		if x := emit(w, on, &hs, .String, .Attribute, a.fact_lo, int(a.fact_n), spelling); x != .Next {
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
		table_free(w)
	}
	if p[0] == '>' {
		return #must_tail st_content(p[1:], end, e, w, hs.a, hs.b, hs.c, on)
	}
	if x := emit(w, on, &hs, .Null, .Value, at(w, p), 0); x != .Next {
		return refused(w, hs, x, p[2:])
	}
	return #must_tail st_closed(p[2:], end, e, w, hs.a, hs.b, hs.c, on)
}

// Whether the tag being read has the attribute named by the `n` bytes at `name`.
@(private)
tag_has :: proc "contextless" (w: ^Walk($H, $LAX), name: [^]u8, n: u64) -> bool #no_bounds_check {
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
