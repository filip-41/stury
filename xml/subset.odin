package xml

import "base:intrinsics"
import "base:runtime"
import spell "../core/spell"
import core "../core"

// The internal subset: every `markupdecl` production is judged, and the entity and attribute-list declarations go
// into the DTD. A parameter entity referenced between declarations is read as declarations. After a reference to one
// that was not read, later entity and attribute-list declarations are judged but not processed, as section 5.1 of the
// XML specification says.

// The deepest nesting of parameter entities, of entity references in a replacement text, and of content-model groups.
@(private)
MAX_NEST :: 64

// Reads declarations and parameter-entity references from `p`: to the subset's `]` when `top`, which it returns, else
// to `end`, the end of a parameter entity's replacement text, copied out of the DTD's bytes when `stored`. `rw` reads
// the runs of comments, instructions and attribute values.
@(private)
declarations :: proc "contextless" (d: ^Dtd, rw: ^Walk(core.No_Hooks), p, end: [^]u8, top, stored: bool, nest: int) -> ([^]u8, Dtd_Fault) #no_bounds_check {
	q := p
	for {
		q = skip_ws(q, end)
		if q >= end {
			if top {
				return q, {end, .Truncated, .None}
			}
			return q, {}
		}
		switch q[0] {
		case ']':
			if top {
				return q, {}
			}
			return q, {q, .Bad_Char, .Subset}
		case '%':
			next, f := parameter_reference(d, rw, q, end, stored, nest)
			if f.kind != .None {
				return q, f
			}
			q = next
			continue
		case '<':
		case:
			return q, {q, .Bad_Char, .Subset}
		}
		room := intrinsics.ptr_sub(end, q)
		if room < 2 {
			return q, {end, .Truncated, .None}
		}
		if q[1] == '?' {
			next, r := instruction(rw, q, end)
			if r.kind != .None {
				return q, {r.q, r.kind, r.detail}
			}
			q = next
			continue
		}
		if q[1] != '!' {
			return q, {q, .Bad_Char, .Subset}
		}
		if room < 4 && prefix_of(q, room, "<!--") {
			return q, {end, .Truncated, .None}
		}
		if q[2] == '-' && q[3] == '-' {
			r := run(rw, q[4:], end, .Comment, 0)
			if r.kind != .None {
				return q, {r.q, r.kind, r.detail}
			}
			q = r.q[3:]
			continue
		}
		next: [^]u8
		f: Dtd_Fault
		switch {
		case keyword(q[2:], end, "ELEMENT"):
			next, f = element_declaration(q[9:], end)
		case keyword(q[2:], end, "ATTLIST"):
			next, f = attlist_declaration(d, rw, q[9:], end, stored)
		case keyword(q[2:], end, "ENTITY"):
			next, f = entity_declaration(d, q[8:], end, stored)
		case keyword(q[2:], end, "NOTATION"):
			next, f = notation_declaration(q[10:], end)
		case:
			for word in ([]string{"<!ELEMENT", "<!ATTLIST", "<!ENTITY", "<!NOTATION"}) {
				if room < len(word) && prefix_of(q, room, word) {
					return q, {end, .Truncated, .None}
				}
			}
			return q, {q, .Bad_Char, .Markup}
		}
		if f.kind != .None {
			return q, f
		}
		q = next
	}
}

// Whether the bytes at `q` are `word` and then a byte that ends it, which the declaration's reader judges.
@(private)
keyword :: #force_inline proc "contextless" (q, end: [^]u8, word: string) -> bool #no_bounds_check {
	return intrinsics.ptr_sub(end, q) >= len(word) && string(q[:len(word)]) == word
}

// The rule a declaration breaks at `q`, which a parameter-entity reference names when one stands there.
@(private)
decl_rule :: #force_inline proc "contextless" (q, end: [^]u8, detail: Detail) -> Detail {
	return .Parameter_Reference if q < end && q[0] == '%' else detail
}

// Passes the whitespace at `q`, of which there must be some.
@(private)
gap :: proc "contextless" (q, end: [^]u8, detail: Detail) -> ([^]u8, Dtd_Fault) {
	s := skip_ws(q, end)
	if s >= end {
		return s, {end, .Truncated, .None}
	}
	if s == q {
		return s, {q, .Bad_Char, decl_rule(q, end, detail)}
	}
	return s, {}
}

// Reads the name at `q` of a declaration. `colons` is the namespace rule it follows: a qualified name, or no colon at
// all for an entity or a notation.
@(private)
decl_name :: proc "contextless" (q, end: [^]u8, detail: Detail, no_colon := false) -> ([^]u8, Dtd_Fault) {
	n, nf := name_end(q, end)
	switch nf {
	case .Truncated:
		return n, {end, .Truncated, .None}
	case .Not_Name:
		return n, {q, .Bad_Char, decl_rule(q, end, detail)}
	case .Bad_Utf8:
		return n, {n, .Bad_Char, .Invalid_Utf8}
	case .None:
	}
	if n >= end {
		return n, {end, .Truncated, .None}
	}
	count := intrinsics.ptr_sub(n, q)
	if no_colon && has_colon(q, count) {
		return n, {q, .Bad_Char, .Qualified_Name}
	}
	if _, ok := qname(q, count); !ok {
		return n, {q, .Bad_Char, .Qualified_Name}
	}
	if count > int(max(u16)) {
		return n, {q, .Too_Wide, .None}
	}
	return n, {}
}

// Passes the whitespace at `q` and the `>` that ends a declaration.
@(private)
decl_close :: proc "contextless" (q, end: [^]u8, detail: Detail) -> ([^]u8, Dtd_Fault) {
	s := skip_ws(q, end)
	if s >= end {
		return s, {end, .Truncated, .None}
	}
	if s[0] != '>' {
		return s, {s, .Bad_Char, decl_rule(s, end, detail)}
	}
	return s[1:], {}
}

// `<!ELEMENT S Name S contentspec S? >`, from past the keyword.
@(private)
element_declaration :: proc "contextless" (p, end: [^]u8) -> ([^]u8, Dtd_Fault) #no_bounds_check {
	q, f := gap(p, end, .Element_Declaration)
	if f.kind != .None {
		return q, f
	}
	q, f = decl_name(q, end, .Element_Declaration)
	if f.kind != .None {
		return q, f
	}
	q, f = gap(q, end, .Element_Declaration)
	if f.kind != .None {
		return q, f
	}
	switch {
	case keyword(q, end, "EMPTY"):
		q = q[5:]
	case keyword(q, end, "ANY"):
		q = q[3:]
	case q[0] == '(':
		s := skip_ws(q[1:], end)
		if keyword(s, end, "#PCDATA") {
			q, f = mixed(s[7:], end)
		} else {
			q, f = content_group(q, end, 0)
		}
		if f.kind != .None {
			return q, f
		}
	case:
		return q, {q, .Bad_Char, decl_rule(q, end, .Element_Declaration)}
	}
	return decl_close(q, end, .Element_Declaration)
}

// `Mixed`, from past `#PCDATA`: `)`, `)*`, or names between `|` and then `)*`.
@(private)
mixed :: proc "contextless" (p, end: [^]u8) -> ([^]u8, Dtd_Fault) #no_bounds_check {
	q := p
	names := false
	for {
		q = skip_ws(q, end)
		if q >= end {
			return q, {end, .Truncated, .None}
		}
		switch q[0] {
		case ')':
			if intrinsics.ptr_sub(end, q) >= 2 && q[1] == '*' {
				return q[2:], {}
			}
			if names {
				return q, {q, .Bad_Char, .Element_Declaration}
			}
			return q[1:], {}
		case '|':
			s := skip_ws(q[1:], end)
			n, f := decl_name(s, end, .Element_Declaration)
			if f.kind != .None {
				return n, f
			}
			q, names = n, true
		case:
			return q, {q, .Bad_Char, decl_rule(q, end, .Element_Declaration)}
		}
	}
}

// A `choice` or `seq` group at its `(`, with its quantifier, `nest` groups deep.
@(private)
content_group :: proc "contextless" (p, end: [^]u8, nest: int) -> ([^]u8, Dtd_Fault) #no_bounds_check {
	if nest >= MAX_NEST {
		return p, {p, .Too_Deep, .None}
	}
	q, f := content_particle(skip_ws(p[1:], end), end, nest)
	if f.kind != .None {
		return q, f
	}
	sep: u8
	for {
		q = skip_ws(q, end)
		if q >= end {
			return q, {end, .Truncated, .None}
		}
		c := q[0]
		if c == ')' {
			return quantifier(q[1:], end), {}
		}
		if c != '|' && c != ',' || sep != 0 && c != sep {
			return q, {q, .Bad_Char, decl_rule(q, end, .Element_Declaration)}
		}
		sep = c
		q, f = content_particle(skip_ws(q[1:], end), end, nest)
		if f.kind != .None {
			return q, f
		}
	}
}

// A `cp`: a name or a group, with its quantifier.
@(private)
content_particle :: proc "contextless" (q, end: [^]u8, nest: int) -> ([^]u8, Dtd_Fault) {
	if q >= end {
		return q, {end, .Truncated, .None}
	}
	if q[0] == '(' {
		return content_group(q, end, nest + 1)
	}
	n, f := decl_name(q, end, .Element_Declaration)
	if f.kind != .None {
		return n, f
	}
	return quantifier(n, end), {}
}

@(private)
quantifier :: #force_inline proc "contextless" (q, end: [^]u8) -> [^]u8 {
	if q < end && (q[0] == '?' || q[0] == '*' || q[0] == '+') {
		return q[1:]
	}
	return q
}

// The attribute types of `AttType` that are a keyword, which `NOTATION` follows with names.
@(private, rodata)
ATT_TYPES := [?]string{"CDATA", "ID", "IDREF", "IDREFS", "ENTITY", "ENTITIES", "NMTOKEN", "NMTOKENS", "NOTATION"}

// `<!ATTLIST S Name AttDef* S? >`, from past the keyword. Each attribute the element does not have yet is recorded.
// A default read from a parameter entity's stored replacement text has no bytes of the text to span and is refused.
@(private)
attlist_declaration :: proc "contextless" (d: ^Dtd, rw: ^Walk(core.No_Hooks), p, end: [^]u8, stored: bool) -> ([^]u8, Dtd_Fault) #no_bounds_check {
	q, f := gap(p, end, .Attribute_Declaration)
	if f.kind != .None {
		return q, f
	}
	element := q
	q, f = decl_name(q, end, .Attribute_Declaration)
	if f.kind != .None {
		return q, f
	}
	element_name := element[:intrinsics.ptr_sub(q, element)]
	for {
		s := skip_ws(q, end)
		if s >= end {
			return s, {end, .Truncated, .None}
		}
		if s[0] == '>' {
			return s[1:], {}
		}
		if s == q {
			return s, {s, .Bad_Char, decl_rule(s, end, .Attribute_Declaration)}
		}
		name_at := s
		q, f = decl_name(s, end, .Attribute_Declaration)
		if f.kind != .None {
			return q, f
		}
		name := name_at[:intrinsics.ptr_sub(q, name_at)]
		q, f = gap(q, end, .Attribute_Declaration)
		if f.kind != .None {
			return q, f
		}
		tokenized := true
		if q[0] == '(' {
			q, f = enumeration(q, end, false)
		} else {
			t, nf := name_end(q, end)
			if nf == .Truncated || t >= end {
				return t, {end, .Truncated, .None}
			}
			word := string(q[:intrinsics.ptr_sub(t, q)])
			known := false
			for type in ATT_TYPES {
				known ||= word == type
			}
			if !known {
				return q, {q, .Bad_Char, decl_rule(q, end, .Attribute_Declaration)}
			}
			tokenized = word != "CDATA"
			q = t
			if word == "NOTATION" {
				q, f = gap(q, end, .Attribute_Declaration)
				if f.kind == .None {
					if q[0] != '(' {
						return q, {q, .Bad_Char, decl_rule(q, end, .Attribute_Declaration)}
					}
					q, f = enumeration(q, end, true)
				}
			}
		}
		if f.kind != .None {
			return q, f
		}
		q, f = gap(q, end, .Attribute_Declaration)
		if f.kind != .None {
			return q, f
		}
		a := Attr_Decl {
			tokenized = tokenized,
			qualified = has_colon(raw_data(name), len(name)),
			next      = NO_DECL,
		}
		switch {
		case keyword(q, end, "#REQUIRED"):
			q = q[9:]
		case keyword(q, end, "#IMPLIED"):
			q = q[8:]
		case:
			if keyword(q, end, "#FIXED") {
				q, f = gap(q[6:], end, .Attribute_Declaration)
				if f.kind != .None {
					return q, f
				}
			}
			r: Run
			switch q[0] {
			case '"':
				r = run(rw, q[1:], end, .Attr, '"')
			case '\'':
				r = run(rw, q[1:], end, .Attr, '\'')
			case:
				return q, {q, .Bad_Char, decl_rule(q, end, .Attribute_Declaration)}
			}
			if r.kind != .None {
				return r.q, {r.q, r.kind, r.detail}
			}
			value_end := r.q[1:]
			a.defaulted = true
			a.fact_lo = u64(intrinsics.ptr_sub(name_at, raw_data(d.src)))
			a.fact_n = u32(intrinsics.ptr_sub(value_end, name_at))
			a.lead = u8(min(intrinsics.ptr_sub(q[1:], name_at), LEAD_MAX))
			a.size = expansion_room(&d.view, d.src, name_at[:a.fact_n])
			if stored && .Stopped not_in d.built.flags {
				return name_at, {name_at, .Bad_Char, .Entity_Respelled}
			}
			q = value_end
		}
		if .Stopped not_in d.built.flags {
			if fault := declare_attribute(d, element_name, name, a); fault.kind != .None {
				return name_at, {name_at, fault.kind, fault.detail}
			}
		}
	}
}

// Records attribute `name` of `element` unless an earlier declaration names it, the first being binding.
@(private)
declare_attribute :: proc "contextless" (d: ^Dtd, element, name: []u8, a: Attr_Decl) -> Dtd_Fault #no_bounds_check {
	a := a
	head := dtd_find(&d.view, .Element, element)
	last := NO_DECL
	for i := head; i != NO_DECL; i = d.attrs[i].next {
		b := &d.attrs[i]
		if string(d.bytes[b.name_lo:][:b.name_n]) == string(name) {
			return {}
		}
		last = i
	}
	if head != NO_DECL {
		a.element_lo, a.element_n = d.attrs[head].element_lo, d.attrs[head].element_n
	} else {
		lo, ok := dtd_bytes(d, element)
		if !ok {
			return {kind = .No_Memory}
		}
		a.element_lo, a.element_n = u32(lo), u16(len(element))
	}
	lo, ok := dtd_bytes(d, name)
	if !ok {
		return {kind = .No_Memory}
	}
	a.name_lo, a.name_n = u32(lo), u16(len(name))
	i := dtd_attr(d, a)
	if i == NO_DECL {
		return {kind = .No_Memory}
	}
	if last != NO_DECL {
		d.attrs[last].next = i
	} else if !dtd_put(d, .Element, i) {
		return {kind = .No_Memory}
	}
	if a.defaulted {
		d.built.flags += {.Defaults}
	}
	return {}
}

// `( S? Nmtoken (S? | S? Nmtoken)* S? )`, or names for a `NOTATION` type, at its `(`.
@(private)
enumeration :: proc "contextless" (p, end: [^]u8, names: bool) -> ([^]u8, Dtd_Fault) #no_bounds_check {
	q := p
	for {
		q = skip_ws(q[1:], end)
		t: [^]u8
		f: Dtd_Fault
		if names {
			t, f = decl_name(q, end, .Attribute_Declaration, true)
		} else {
			t, f = nmtoken(q, end)
		}
		if f.kind != .None {
			return t, f
		}
		q = skip_ws(t, end)
		if q >= end {
			return q, {end, .Truncated, .None}
		}
		if q[0] == ')' {
			return q[1:], {}
		}
		if q[0] != '|' {
			return q, {q, .Bad_Char, decl_rule(q, end, .Attribute_Declaration)}
		}
	}
}

// An `Nmtoken`: one or more name characters.
@(private)
nmtoken :: proc "contextless" (q, end: [^]u8) -> ([^]u8, Dtd_Fault) #no_bounds_check {
	t := q
	for t < end && u8(NAME_BYTE[t[0]]) & NAME_ASCII != 0 {
		t = t[1:]
	}
	if t < end && NAME_BYTE[t[0]] == .High {
		nf: Name_Fault
		t, nf = name_end_high(nil, t, end)
		if nf == .Truncated {
			return t, {end, .Truncated, .None}
		}
		if nf == .Bad_Utf8 {
			return t, {t, .Bad_Char, .Invalid_Utf8}
		}
	}
	if t >= end {
		return t, {end, .Truncated, .None}
	}
	if t == q {
		return t, {q, .Bad_Char, decl_rule(q, end, .Attribute_Declaration)}
	}
	return t, {}
}

// `ExternalID`, `SYSTEM S SystemLiteral` or `PUBLIC S PubidLiteral S SystemLiteral`, at its keyword. A notation's
// public identifier may stand alone. Returns one past it and its public literal, nil for none.
@(private)
external_id :: proc "contextless" (p, end: [^]u8, detail: Detail, notation := false) -> (next: [^]u8, public: []u8, f: Dtd_Fault) {
	public_id := keyword(p, end, "PUBLIC")
	if !public_id && !keyword(p, end, "SYSTEM") {
		return p, nil, {p, .Bad_Char, decl_rule(p, end, detail)}
	}
	q := p[6:]
	for pass in 0 ..< (2 if public_id else 1) {
		l: [^]u8
		l, f = gap(q, end, detail)
		if f.kind != .None {
			if notation && pass == 1 {
				return q, public, {}
			}
			return l, public, f
		}
		if notation && pass == 1 && l[0] != '"' && l[0] != '\'' {
			return q, public, {}
		}
		e, kind, at_ := literal(l, end, public_id && pass == 0)
		if kind != .None {
			return at_, public, {at_, kind, detail if kind == .Bad_Char else .None}
		}
		if public_id && pass == 0 {
			public = l[1:][:intrinsics.ptr_sub(e, l) - 2]
		}
		q = e
	}
	return q, public, {}
}

// `<!NOTATION S Name S (ExternalID | PublicID) S? >`, from past the keyword.
@(private)
notation_declaration :: proc "contextless" (p, end: [^]u8) -> ([^]u8, Dtd_Fault) {
	q, f := gap(p, end, .Notation_Declaration)
	if f.kind != .None {
		return q, f
	}
	q, f = decl_name(q, end, .Notation_Declaration, true)
	if f.kind != .None {
		return q, f
	}
	q, f = gap(q, end, .Notation_Declaration)
	if f.kind != .None {
		return q, f
	}
	q, _, f = external_id(q, end, .Notation_Declaration, true)
	if f.kind != .None {
		return q, f
	}
	return decl_close(q, end, .Notation_Declaration)
}

// `<!ENTITY S Name S EntityDef S? >` or `<!ENTITY S % S Name S PEDef S? >`, from past the keyword. The entity is
// recorded unless one of its kind and name is, the first being binding.
@(private)
entity_declaration :: proc "contextless" (d: ^Dtd, p, end: [^]u8, stored: bool) -> ([^]u8, Dtd_Fault) #no_bounds_check {
	q, f := gap(p, end, .Entity_Declaration)
	if f.kind != .None {
		return q, f
	}
	kind := Slot_Kind.General
	e: Entity
	if q[0] == '%' {
		kind = .Parameter
		e.flags += {.Parameter}
		q, f = gap(q[1:], end, .Entity_Declaration)
		if f.kind != .None {
			return q, f
		}
	}
	name_at := q
	q, f = decl_name(q, end, .Entity_Declaration, true)
	if f.kind != .None {
		return q, f
	}
	name := name_at[:intrinsics.ptr_sub(q, name_at)]
	q, f = gap(q, end, .Entity_Declaration)
	if f.kind != .None {
		return q, f
	}
	value: []u8
	refs: bool
	if q[0] == '"' || q[0] == '\'' {
		next: [^]u8
		next, value, refs, f = entity_value(q, end)
		if f.kind != .None {
			return next, f
		}
		q = next
	} else {
		q, _, f = external_id(q, end, .Entity_Declaration)
		if f.kind != .None {
			return q, f
		}
		e.flags += {.External}
		if kind == .General {
			s := skip_ws(q, end)
			if s > q && keyword(s, end, "NDATA") {
				s, f = gap(s[5:], end, .Entity_Declaration)
				if f.kind == .None {
					s, f = decl_name(s, end, .Entity_Declaration, true)
				}
				if f.kind != .None {
					return s, f
				}
				e.flags += {.Unparsed}
				q = s
			}
		}
	}
	q, f = decl_close(q, end, .Entity_Declaration)
	if f.kind != .None || .Stopped in d.built.flags || dtd_find(&d.view, kind, name) != NO_DECL {
		return q, f
	}
	lo, ok := dtd_bytes(d, name)
	if !ok {
		return q, {kind = .No_Memory}
	}
	e.name_lo, e.name_n = u32(lo), u16(len(name))
	if .External not_in e.flags {
		if len(value) > int(max(u32)) {
			return q, {name_at, .Too_Wide, .None}
		}
		e.lit_n = u32(len(value))
		if stored {
			// The literal lies in a copy of a replacement text, which is freed once read.
			e.lit_lo, ok = dtd_bytes(d, value)
			if !ok {
				return q, {kind = .No_Memory}
			}
			e.flags += {.Lit_Stored, .Stored}
			e.text_lo, e.text_n = e.lit_lo, e.lit_n
		} else {
			e.lit_lo = u64(intrinsics.ptr_sub(raw_data(value), raw_data(d.src)))
			e.text_lo, e.text_n = e.lit_lo, e.lit_n
		}
		if refs {
			e.text_lo, e.text_n, ok = replacement_text(d, value)
			if !ok {
				return q, {kind = .No_Memory}
			}
			e.flags += {.Stored}
		}
	}
	i := dtd_entity(d, e)
	if i == NO_DECL || !dtd_put(d, kind, i) {
		return q, {kind = .No_Memory}
	}
	return q, {}
}

// Judges the `EntityValue` at `p`, its quote. Returns one past it, the literal between its quotes, and whether it holds
// a character reference or a CR, which the replacement text spells otherwise. A parameter-entity reference in the
// internal subset's literal is refused, as a well-formedness constraint says.
@(private)
entity_value :: proc "contextless" (p, end: [^]u8) -> (next: [^]u8, value: []u8, respelled: bool, f: Dtd_Fault) #no_bounds_check {
	quote := p[0]
	q := p[1:]
	for {
		if q >= end {
			return q, nil, false, {end, .Truncated, .None}
		}
		c := q[0]
		switch c {
		case quote:
			return q[1:], p[1:][:intrinsics.ptr_sub(q, p[1:])], respelled, {}
		case '%':
			return q, nil, false, {q, .Bad_Char, .Parameter_Reference}
		case '&':
			n, kind, detail := reference(q, end)
			if kind == .Bad_Char && detail == .Undeclared_Entity {
				kind = .None
				t, _ := name_end(q[1:], end)
				n = intrinsics.ptr_sub(t, q) + 1
			}
			if kind != .None {
				return q, nil, false, {q if kind != .Truncated else end, kind, detail}
			}
			respelled ||= q[1] == '#'
			q = q[n:]
			continue
		case '\r':
			respelled = true
		case '\t', '\n':
		case:
			if c < 0x20 {
				return q, nil, false, {q, .Bad_Char, .Control_Char}
			}
			if c >= 0x80 {
				r, kind := spell.utf8_char(q, end)
				if kind == .Truncated {
					return q, nil, false, {end, .Truncated, .None}
				}
				if kind != .None {
					return q, nil, false, {q, .Bad_Char, .Invalid_Utf8}
				}
				if c == 0xef && non_char(q, end) {
					return q, nil, false, {q, .Bad_Char, .Non_Char}
				}
				q = r
				continue
			}
		}
		q = q[1:]
	}
}

// Writes the replacement text of the judged literal `value` to the DTD's bytes: its character references replaced by
// their characters and its line ends read as LF. Returns where it is.
@(private)
replacement_text :: proc "contextless" (d: ^Dtd, value: []u8) -> (lo: u64, n: u32, ok: bool) #no_bounds_check {
	lo, ok = dtd_bytes(d, value)
	if !ok {
		return
	}
	out := d.arena[lo:]
	w, i := 0, 0
	for i < len(value) {
		c := value[i]
		switch {
		case c == '&' && value[i + 1] == '#':
			k, r, _ := decode_reference(value[i:])
			w += spell.put_rune(out[w:][:4], r)
			i += k
		case c == '\r':
			out[w] = '\n'
			w += 1
			i += 2 if i + 1 < len(value) && value[i + 1] == '\n' else 1
		case:
			out[w] = c
			w += 1
			i += 1
		}
	}
	d.arena_n = lo + u64(w)
	dtd_refresh(d)
	return lo, u32(w), true
}

// A parameter-entity reference at `q` between declarations: its replacement text is read as declarations, or, for an
// entity that is not read, the DTD stops being processed.
@(private)
parameter_reference :: proc "contextless" (d: ^Dtd, rw: ^Walk(core.No_Hooks), q, end: [^]u8, stored: bool, nest: int) -> ([^]u8, Dtd_Fault) #no_bounds_check {
	n, nf := name_end(q[1:], end)
	switch nf {
	case .Truncated:
		return n, {end, .Truncated, .None}
	case .Not_Name, .Bad_Utf8:
		return n, {q, .Bad_Char, .Reference}
	case .None:
	}
	if n >= end {
		return n, {end, .Truncated, .None}
	}
	if n[0] != ';' {
		return n, {n, .Bad_Char, .Reference}
	}
	after := n[1:]
	// Entity Declared binds a subset with a parameter-entity reference only when the document is standalone.
	d.built.flags -= {.Complete}
	i := dtd_find(&d.view, .Parameter, q[1:][:intrinsics.ptr_sub(n, q[1:])])
	if i == NO_DECL || .External in d.entities[i].flags {
		if i == NO_DECL && .Standalone in d.built.flags {
			return q, {q, .Bad_Char, .Undeclared_Entity}
		}
		d.built.flags += {.Stopped}
		return after, {}
	}
	if .Measuring in d.entities[i].flags {
		return q, {q, .Bad_Char, .Recursion}
	}
	if nest >= MAX_NEST {
		return q, {q, .Too_Deep, .None}
	}
	d.ents[i].flags += {.Measuring}
	e := d.entities[i]
	text := entity_text(&d.view, d.src, &e)
	f: Dtd_Fault
	if .Stored in e.flags {
		// The DTD's bytes grow while the text is read, so it is read from a copy.
		copy_of := ([^]u8)(runtime.heap_alloc(max(len(text), 1), false))
		if copy_of == nil {
			return q, {kind = .No_Memory}
		}
		intrinsics.mem_copy_non_overlapping(copy_of, raw_data(text), len(text))
		_, f = declarations(d, rw, copy_of, copy_of[len(text):], false, true, nest + 1)
		runtime.heap_free(copy_of)
		if f.kind != .None && f.kind != .No_Memory && f.detail != .Entity_Respelled {
			f = {q, f.kind, f.detail}
		}
	} else {
		_, f = declarations(d, rw, raw_data(text), raw_data(text)[len(text):], false, stored, nest + 1)
	}
	d.ents[i].flags -= {.Measuring}
	if f.kind == .Truncated {
		return q, {q, .Bad_Char, .Entity_Boundary}
	}
	if f.detail == .Entity_Respelled && .Stored in e.flags {
		f.at = q
	}
	return after, f
}

// The public identifiers the HTML standard lists for which an XML reader reads its named character references.
@(private, rodata)
HTML_PUBLIC_IDS := [?]string {
	"-//W3C//DTD XHTML 1.0 Transitional//EN",
	"-//W3C//DTD XHTML 1.1//EN",
	"-//W3C//DTD XHTML 1.0 Strict//EN",
	"-//W3C//DTD XHTML 1.0 Frameset//EN",
	"-//W3C//DTD XHTML Basic 1.0//EN",
	"-//W3C//DTD XHTML 1.1 plus MathML 2.0//EN",
	"-//W3C//DTD XHTML 1.1 plus MathML 2.0 plus SVG 1.1//EN",
	"-//W3C//DTD MathML 2.0//EN",
	"-//WAPFORUM//DTD XHTML Mobile 1.0//EN",
}
