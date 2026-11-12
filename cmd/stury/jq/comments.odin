package jq

// Facts as a filter reads and writes them: the comments, over the library's comments on values (`core.Commented`), and
// the properties, a tag, an anchor, an alias and a style. A property is one value, a string or null. A property the
// filter wrote is held as a comment role's bodies are, one body under its role, and a style, which no format spells as
// an edit, is never held.
//
// In a path a fact is a step of its own, the object `{"fact": "comment"}` (or any other name in `FACT_NAMES`), and only
// the last step: `.a.@comment` is the path `["a", {"fact": "comment"}]`. `.@` reads only the names in the catalogue.

import core_pkg "../../../core"

// Every fact `.@` names: the three comment roles, then the properties of `core.Fact_Name`.
Fact :: enum u8 {
	Comment,
	Comment_Inline,
	Comment_Foot,
	Tag,
	Anchor,
	Alias,
	Style,
}

// The name of each fact as a path step spells it, and as `.@` reads it after its `@`.
FACT_NAMES :: [Fact]string {
	.Comment        = "comment",
	.Comment_Inline = "comment_inline",
	.Comment_Foot   = "comment_foot",
	.Tag            = "tag",
	.Anchor         = "anchor",
	.Alias          = "alias",
	.Style          = "style",
}

// The other names `.@` reads, each for the fact it names. A path step always spells the fact by its `FACT_NAMES` name.
FACT_ALIASES :: [?]struct {
	name: string,
	fact: Fact,
}{{"comment_head", .Comment}}

// The fact `.@name` names, `name` without its `@`, and whether the catalogue holds it.
fact_named :: proc(name: string) -> (Fact, bool) {
	names := FACT_NAMES
	for n, f in names {
		if n == name {
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

// The comment role of fact `f`, when it is one.
comment_role :: proc(f: Fact) -> (core_pkg.Role, bool) {
	#partial switch f {
	case .Comment:
		return .Comment, true
	case .Comment_Inline:
		return .Comment_Inline, true
	case .Comment_Foot:
		return .Comment_Foot, true
	}
	return .Value, false
}

// The property fact `f` names, when it is one.
property_name :: proc(f: Fact) -> (core_pkg.Fact_Name, bool) {
	#partial switch f {
	case .Tag:
		return .Tag, true
	case .Anchor:
		return .Anchor, true
	case .Alias:
		return .Alias, true
	case .Style:
		return .Style, true
	}
	return .Tag, false
}

// The role property `name` is written under, which a style, held in a node's spelling alone, has none of.
property_role :: proc(name: core_pkg.Fact_Name) -> (core_pkg.Role, bool) {
	switch name {
	case .Tag:
		return .Tag, true
	case .Anchor:
		return .Anchor, true
	case .Alias:
		return .Alias, true
	case .Style:
	}
	return .Value, false
}

// `.@role` of `v`: its comments of `role` as an array of strings, or null when it has none.
comments_value :: proc(v: Value, role: core_pkg.Role) -> Value {
	bodies, _ := comments(v, role)
	if len(bodies) == 0 {
		return nil
	}
	a := new_array(len(bodies))
	for b in bodies {
		append(&a.items, b)
	}
	return a
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

// The fact path step `key` names, when it is one: an object whose one member `fact` names a fact.
fact_step :: proc(key: Value) -> (fact: Fact, ok: bool) {
	if kind(key) != .Object || length_of(key) != 1 {
		return
	}
	name, _ := object_get(key, "fact")
	s, is_str := string_of(name)
	if !is_str {
		return
	}
	names := FACT_NAMES
	for n, f in names {
		if n == s {
			return f, true
		}
	}
	return
}

// The path step of `fact`.
fact_key :: proc(fact: Fact) -> Value {
	o := new_object()
	names := FACT_NAMES
	object_put(o, "fact", names[fact])
	return o
}

// `.@fact` of `v`: a comment role's bodies as an array of strings, or a property's value, null when it has none.
fact_value :: proc(v: Value, fact: Fact) -> Value {
	if role, is_comment := comment_role(fact); is_comment {
		return comments_value(v, role)
	}
	name, _ := property_name(fact)
	return property_value(v, name)
}

// `v`'s property `name`: the filter's write, else the value of its node's fact.
property_value :: proc(v: Value, name: core_pkg.Fact_Name) -> Value {
	inner := v
	if c, is_commented := v.(^Commented); is_commented {
		if role, spanned := property_role(name); spanned && role in c.written {
			return c.bodies[role][0] if len(c.bodies[role]) > 0 else nil
		}
		inner = c.v
	}
	r, is_ref := inner.(Ref)
	if !is_ref {
		return nil
	}
	fv, held := core_pkg.fact_value(r.doc, r.node, name)
	if !held {
		return nil
	}
	return fv.text
}

// `v` with fact `fact` written as `nv`: the comment bodies of `write_comments`, or for a property a string or null. A
// style is written only as the one `v` has.
write_fact :: proc(ip: ^Interp, v: Value, fact: Fact, nv: Value) -> (Value, Signal) {
	if role, is_comment := comment_role(fact); is_comment {
		return write_comments(ip, v, role, nv)
	}
	name, _ := property_name(fact)
	text: string
	switch kind(nv) {
	case .Null:
	case .String:
		text, _ = string_of(nv)
	case .False, .True, .Number, .Array, .Object:
		return nil, bad_property(ip)
	}
	role, spanned := property_role(name)
	if !spanned {
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

@(private = "file")
bad_property :: proc(ip: ^Interp) -> Signal {
	return fail(ip, "a tag, an anchor, an alias or a style is a string or null")
}

fact_step_not_last :: proc(ip: ^Interp) -> Signal {
	return fail(ip, "A comment step must be the last step of a path")
}

// The keys of a deletion that are not fact steps, in an order of their own, and the facts the others name.
split_fact_steps :: proc(keys: []Value) -> ([]Value, bit_set[Fact]) {
	keys := keys
	facts: bit_set[Fact]
	for i := 0; i < len(keys); {
		if fact, is_fact := fact_step(keys[i]); is_fact {
			facts += {fact}
			keys[i] = keys[len(keys) - 1]
			keys = keys[:len(keys) - 1]
		} else {
			i += 1
		}
	}
	return keys, facts
}

// `v` without its facts `facts`.
remove_facts :: proc(ip: ^Interp, v: Value, facts: bit_set[Fact]) -> (Value, Signal) {
	v := v
	for fact in facts {
		sig: Signal
		if v, sig = write_fact(ip, v, fact, nil); sig != .Go {
			return nil, sig
		}
	}
	return v, .Go
}

// `nv` put where `old` was: it keeps `old`'s facts that `nv` does not bring, the comments of each role
// (`core.keep_comments`) and each property, written or from the source.
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
	for name in core_pkg.Fact_Name {
		role := property_role(name) or_continue
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
		bodies := make([]string, 1)
		bodies[0] = text
		kept = noted(kept, role, bodies)
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
