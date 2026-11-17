package jq

// Facts as a filter reads and writes them: the comments, over the library's comments on values (`core.Commented`), and
// the properties, a tag, an anchor, an alias and a style. A property is one value, a string or null, and a tag may be a
// number. A property the filter wrote is held as a comment role's bodies are, one body under its role, and a style,
// which no format spells as an edit, is never held. An attribute the filter wrote is held as its role's bodies are,
// each spelled as markup writes it. The other facts of markup, an element's name, namespace and content and a
// document's instructions and doctype, are read only.
//
// In a path a fact is a step of its own, the object `{"fact": "comment"}` (or any other name in `core.FACTS`), and only
// the last step: `.a.@comment` is the path `["a", {"fact": "comment"}]`. `.@` reads only the names in the catalogue. An
// attribute's step names it too: `.&k` is `{"fact": "attribute", "name": "k"}`.

import core_pkg "../../../core"

// Every fact `.@` names is a `core.Fact_Kind`, by its `core.FACTS` name. `.@attrs` reads `Attribute` as an object of
// every attribute, and the step of `.&name`, `{"fact": "attribute", "name": name}`, one attribute.
Fact :: core_pkg.Fact_Kind

// The other names `.@` reads, each for the fact it names. A path step always spells the fact by its `core.FACTS` name.
FACT_ALIASES :: [?]struct {
	name: string,
	fact: Fact,
}{{"comment_head", .Comment}}

// The fact `.@name` names, `name` without its `@`, and whether the catalogue holds it.
fact_named :: proc(name: string) -> (Fact, bool) {
	for info, f in core_pkg.FACTS {
		if info.name == name {
			return f, true
		}
	}
	for a in FACT_ALIASES {
		if a.name == name {
			return a.fact, true
		}
	}
	return .Comment, false
}

// `v` with `role` written as `bodies`: a string is one body, an array of strings one per element, and null or an
// empty array removes the role.
write_comments :: proc(ip: ^Interp, v: Value, role: core_pkg.Role, bodies: Value) -> (Value, Signal) {
	texts: []string
	switch kind(bodies) {
	case .Null:
	case .String:
		s, _ := string_of(bodies)
		texts = make([]string, 1)
		texts[0] = s
	case .Array:
		texts = make([]string, length_of(bodies))
		it := iterate(bodies)
		i := 0
		for _, m in next_member(&it) {
			s, is_str := string_of(m)
			if !is_str {
				return nil, bad_comment(ip)
			}
			texts[i] = s
			i += 1
		}
	case .False, .True, .Number, .Object:
		return nil, bad_comment(ip)
	}
	return noted(v, role, texts), .Go
}

@(private = "file")
bad_comment :: proc(ip: ^Interp) -> Signal {
	return fail(ip, "a comment is a string, an array of strings, or null")
}

// The fact path step `key` names, when it is one: an object whose one member `fact` names a fact, or the attribute
// step, whose second member `name` is a string.
fact_step :: proc(key: Value) -> (fact: Fact, ok: bool) {
	if kind(key) != .Object || length_of(key) < 1 || length_of(key) > 2 {
		return
	}
	name, _ := object_get(key, "fact")
	s, is_str := string_of(name)
	if !is_str {
		return
	}
	if length_of(key) == 2 {
		n, _ := object_get(key, "name")
		_, named := string_of(n)
		return .Attribute, s == "attribute" && named
	}
	for info, f in core_pkg.FACTS {
		if info.name == s {
			return f, true
		}
	}
	return
}

// Whether fact path step `key` is the step of one attribute, `.&name`.
is_attribute_step :: proc(key: Value) -> bool {
	return length_of(key) == 2
}

// The attribute name of an attribute step, which `fact_step` reports as `Attribute`.
attribute_step_name :: proc(key: Value) -> string {
	name, _ := object_get(key, "name")
	s, _ := string_of(name)
	return s
}

// The path step of `fact`.
fact_key :: proc(fact: Fact) -> Value {
	o := new_object()
	object_put(o, "fact", core_pkg.FACTS[fact].name)
	return o
}

// The path step of attribute `name`.
attribute_key :: proc(name: string) -> Value {
	o := new_object()
	object_put(o, "fact", "attribute")
	object_put(o, "name", name)
	return o
}

// `.@fact` of `v`: a comment role's bodies as an array of strings, or a property's value, null when it has none.
fact_value :: proc(v: Value, fact: Fact) -> Value {
	info := core_pkg.FACTS[fact]
	switch info.class {
	case .Comment:
		bodies, _ := comments(v, info.role)
		if len(bodies) == 0 {
			return nil
		}
		a := new_array(len(bodies))
		for b in bodies {
			append(&a.items, b)
		}
		return a
	case .Property:
		return property_value(v, fact)
	case .Markup:
	}
	#partial switch fact {
	case .Instruction:
		return markup_facts(v, .Instruction, true)
	case .Doctype:
		return markup_facts(v, .Doctype, false)
	case .Directive:
		return markup_facts(v, .Directive, true)
	}
	return attributes_value(v, "", false)
}

// The bodies of the facts of `role` on `v`, an array of strings, or the first one as a string when `many` is false.
// Null when `v` has none.
@(private = "file")
markup_facts :: proc(v: Value, role: core_pkg.Role, many: bool) -> Value {
	r, is_ref := core_pkg.facts_node(v)
	if !is_ref || len(r.doc.facts) == 0 {
		return nil
	}
	it := core_pkg.facts_of(r.doc, r.node, role)
	a := new_array(1)
	for body in core_pkg.fact_next(&it) {
		append(&a.items, body)
	}
	if len(a.items) == 0 {
		return nil
	}
	return Value(a) if many else a.items[0]
}

// `v`'s property `name`: the filter's write, else the value of its node's fact, a number when the fact spells one.
property_value :: proc(v: Value, name: Fact) -> Value {
	if c, is_commented := v.(^Commented); is_commented {
		if role := core_pkg.FACTS[name].role; role != .Value && role in c.written {
			return c.bodies[role][0] if len(c.bodies[role]) > 0 else nil
		}
	}
	r, is_ref := core_pkg.facts_node(v)
	if !is_ref {
		return nil
	}
	fv, held := core_pkg.fact_value(r.doc, r.node, name)
	if !held {
		return nil
	}
	if fv.numeric {
		if n, is_number := read_number(fv.text); is_number {
			return n
		}
	}
	return fv.text
}

// `v` with the fact of path step `step` written as `nv`: the comment bodies of `write_comments`, for a property a string
// or null, and a number for a tag, which is held as its digits, and for an attribute a string or null. A style is
// written only as the one `v` has.
write_fact :: proc(ip: ^Interp, v: Value, step: Value, nv: Value) -> (Value, Signal) {
	name, _ := fact_step(step)
	if is_attribute_step(step) {
		return write_attribute(ip, v, attribute_step_name(step), nv)
	}
	info := core_pkg.FACTS[name]
	if info.class == .Comment {
		return write_comments(ip, v, info.role, nv)
	}
	if info.read_only || info.class != .Property {
		return nil, fail(ip, "A markup name, namespace, content, instruction, doctype or document marker cannot be written")
	}
	text: string
	switch kind(nv) {
	case .Null:
	case .String:
		text, _ = string_of(nv)
	case .Number:
		if name != .Tag {
			return nil, bad_property(ip)
		}
		text = to_json(nv, {}, context.allocator)
	case .False, .True, .Array, .Object:
		return nil, bad_property(ip)
	}
	role := info.role
	if role == .Value {
		if compare(property_value(v, name), plain(nv)) == 0 {
			return v, .Go
		}
		return nil, fail(ip, "cannot write a style: the format has no spelling for it")
	}
	if kind(nv) == .Null {
		return noted(v, role, nil), .Go
	}
	bodies := make([]string, 1)
	bodies[0] = text
	return noted(v, role, bodies), .Go
}

// `v` with its attribute `name` written as `nv`, or removed by null: in place of one of that name, else after the others.
@(private = "file")
write_attribute :: proc(ip: ^Interp, v: Value, name: string, nv: Value) -> (Value, Signal) {
	text, is_text := string_of(nv)
	if !is_text && kind(nv) != .Null {
		return nil, fail(ip, "an attribute is a string or null")
	}
	return noted(v, .Attribute, core_pkg.attribute_bodies(v, name, text if is_text else nil)), .Go
}

@(private = "file")
bad_property :: proc(ip: ^Interp) -> Signal {
	return fail(ip, "a tag, an anchor, an alias or a style is a string or null, and a tag may be a number")
}

fact_step_not_last :: proc(ip: ^Interp) -> Signal {
	return fail(ip, "A comment step must be the last step of a path")
}

// The keys of a deletion that are not fact steps, then the fact steps, each part in an order of its own.
split_fact_steps :: proc(keys: []Value) -> (rest, facts: []Value) {
	n := len(keys)
	for i := 0; i < n; {
		if _, is_fact := fact_step(keys[i]); is_fact {
			n -= 1
			keys[i], keys[n] = keys[n], keys[i]
		} else {
			i += 1
		}
	}
	return keys[:n], keys[n:]
}

// `v` without the facts of path steps `facts`.
remove_facts :: proc(ip: ^Interp, v: Value, facts: []Value) -> (Value, Signal) {
	v := v
	for step in facts {
		sig: Signal
		if v, sig = write_fact(ip, v, step, nil); sig != .Go {
			return nil, sig
		}
	}
	return v, .Go
}

// `nv` put where `old` was: it keeps `old`'s facts that `nv` does not bring, the comments of each role
// (`core.keep_comments`) and each property, written or from the source, a tag only where `nv` still fits it
// (`core.kept_tag`).
keep_facts :: #force_inline proc(old, nv: Value) -> Value {
	#partial switch x in old {
	case ^Commented:
		return merge_facts(old, nv)
	case Ref:
		if len(x.doc.facts) > 0 || x.doc.readers != nil && x.doc.readers.fact != nil {
			return merge_facts(old, nv)
		}
	}
	return nv
}

@(private = "file")
merge_facts :: #force_no_inline proc(old, nv: Value) -> Value {
	if r, is_ref := old.(Ref); is_ref {
		if s, same := nv.(Ref); same && s == r {
			return nv
		}
	}
	kept := core_pkg.keep_comments(old, nv)
	for info, name in core_pkg.FACTS {
		role := info.role
		if info.class != .Property || role == .Value {
			continue
		}
		if property_value(nv, name) != nil {
			continue
		}
		if c, is_commented := nv.(^Commented); is_commented && role in c.written {
			continue
		}
		have := property_value(old, name)
		if have == nil {
			continue
		}
		text, is_text := string_of(have)
		if !is_text {
			text = to_json(have, {}, context.allocator)
		}
		if r, is_ref := plain(old).(Ref); is_ref && name == .Tag {
			text = core_pkg.kept_tag(r.doc, text, nv) or_continue
		}
		bodies := make([]string, 1)
		bodies[0] = text
		kept = noted(kept, role, bodies)
	}
	if r, is_node := core_pkg.facts_node(old); is_node && core_pkg.is_markup(r.doc) {
		n, brings := nv.(^Commented)
		_, is_ref := plain(nv).(Ref)
		if c, is_commented := old.(^Commented); is_commented && .Attribute in c.written && !is_ref && !(brings && .Attribute in n.written) {
			kept = noted(kept, .Attribute, c.bodies[.Attribute])
		}
		kept = core_pkg.in_place_of(kept, r)
	}
	return kept
}

// Whether path `p` ends in a fact step. Only the step `.@fact` makes, an object of the program, is looked at, so the
// test costs a path step a type check.
ends_in_fact :: #force_inline proc(p: ^Path_Step) -> bool {
	if p == nil {
		return false
	}
	if _, is_object := p.key.(^Object); !is_object {
		return false
	}
	_, is_fact := fact_step(p.key)
	return is_fact
}
