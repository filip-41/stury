package jq

// Facts as a filter reads and writes them: the comments, over the library's comments on values (`core.Commented`), and
// the properties, a tag, an anchor, an alias and a style. A property is one value, a string or null, and a tag may be a
// number. A property the filter wrote is held as a comment role's bodies are, one body under its role, and a style,
// which no format spells as an edit, is never held. An attribute the filter wrote is held as its role's bodies are,
// each spelled as markup writes it. The other facts of markup, an element's name, namespace and content and a
// document's instructions and doctype, are read only.
//
// In a path a fact is a step of its own, the object `{"fact": "comment"}` (or any other name in `FACT_NAMES`), and only
// the last step: `.a.@comment` is the path `["a", {"fact": "comment"}]`. `.@` reads only the names in the catalogue. An
// attribute's step names it too: `.&k` is `{"fact": "attribute", "name": "k"}`.

import "core:slice"
import "core:strconv"
import "core:strings"

import core_pkg "../../../core"

// Every fact `.@` names: the three comment roles, the properties of `core.Fact_Name`, then the markup facts that are
// no property. `Attribute` is the step of `.&name`, which `.@` does not name.
Fact :: enum u8 {
	Comment,
	Comment_Inline,
	Comment_Foot,
	Tag,
	Anchor,
	Alias,
	Style,
	Name,
	Namespace,
	Content,
	Pi,
	Doctype,
	Attrs,
	Attribute,
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
	.Name           = "name",
	.Namespace      = "namespace",
	.Content        = "content",
	.Pi             = "pi",
	.Doctype        = "doctype",
	.Attrs          = "attrs",
	.Attribute      = "attribute",
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
		if n == name && f != .Attribute {
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
	case .Name:
		return .Name, true
	case .Namespace:
		return .Namespace, true
	case .Content:
		return .Content, true
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
	case .Style, .Name, .Namespace, .Content:
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
	names := FACT_NAMES
	for n, f in names {
		if n == s && (f == .Attribute) == (length_of(key) == 2) {
			if f == .Attribute {
				n, _ := object_get(key, "name")
				_, named := string_of(n)
				return f, named
			}
			return f, true
		}
	}
	return
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
	names := FACT_NAMES
	object_put(o, "fact", names[fact])
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
	if role, is_comment := comment_role(fact); is_comment {
		return comments_value(v, role)
	}
	#partial switch fact {
	case .Pi:
		return markup_facts(v, .Instruction, true)
	case .Doctype:
		return markup_facts(v, .Doctype, false)
	case .Attrs:
		return attributes_value(v, "", false)
	}
	name, _ := property_name(fact)
	return property_value(v, name)
}

// The bodies of the facts of `role` on `v`, an array of strings, or the first one as a string when `many` is false.
// Null when `v` has none.
@(private = "file")
markup_facts :: proc(v: Value, role: core_pkg.Role, many: bool) -> Value {
	r, is_ref := plain(v).(Ref)
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

// The attributes of the element `v` is, by name as written: with `one` the value of the attribute `name`, else an
// object of every one's value. Null for a value that is no element or has none, or none of that name.
attributes_value :: proc(v: Value, name: string, one: bool) -> Value {
	if c, is_commented := v.(^Commented); is_commented && .Attribute in c.written {
		return written_attributes(c, name, one)
	}
	r, is_ref := plain(v).(Ref)
	if !is_ref || len(r.doc.facts) == 0 {
		return nil
	}
	o: ^Object
	it := core_pkg.attributes_of(r.doc, r.node)
	for k, value in core_pkg.attribute_next(&it) {
		key, _ := core_pkg.token_text(r.doc.readers, &r.doc.view, k, context.allocator)
		if one && key != name {
			continue
		}
		text, _ := core_pkg.token_text(r.doc.readers, &r.doc.view, value, context.allocator)
		if one {
			return text
		}
		if o == nil {
			o = new_object()
		}
		object_put(o, key, text)
	}
	return o if o != nil else nil
}

// `attributes_value` of an element whose attributes the filter wrote: a body its node has is read as the source reads
// it, and one the filter spelled by undoing `attribute_body`.
@(private = "file")
written_attributes :: proc(c: ^Commented, name: string, one: bool) -> Value {
	source, _ := comments(c.v, .Attribute)
	o: ^Object
	for body in c.bodies[.Attribute] {
		key := attribute_read_name(c.v, body)
		if one && key != name {
			continue
		}
		text := attributes_value(c.v, key, true) if slice.contains(source, body) else Value(attribute_body_text(body))
		if one {
			return text
		}
		if o == nil {
			o = new_object()
		}
		object_put(o, key, text)
	}
	return o if o != nil else nil
}

// The name of attribute body `body`, what stands before its `=`.
@(private = "file")
attribute_body_name :: proc(body: string) -> string {
	eq := strings.index_byte(body, '=')
	return strings.trim_right_space(body[:eq if eq >= 0 else len(body)])
}

// The name the format reads from attribute `body`: what its reader makes of the name the element's source spells that way,
// as HTML folds capitals, else the name as written.
@(private = "file")
attribute_read_name :: proc(v: Value, body: string) -> string {
	written := attribute_body_name(body)
	if r, is_ref := plain(v).(Ref); is_ref && len(r.doc.facts) > 0 {
		it := core_pkg.attributes_of(r.doc, r.node)
		for k, _ in core_pkg.attribute_next(&it) {
			if string(r.doc.src[k.lo:][:k.n]) == written {
				read, _ := core_pkg.token_text(r.doc.readers, &r.doc.view, k, context.allocator)
				return read
			}
		}
	}
	return written
}

// The attribute `name` with the value `text`, as markup writes it: quoted, with the markup, the quote and the white
// space a reader would fold to a space written as references.
@(private = "file")
attribute_body :: proc(name, text: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, name)
	strings.write_string(&b, `="`)
	for c in transmute([]u8)text {
		switch c {
		case '&', '<', '"', '\t', '\n', '\r':
			strings.write_string(&b, "&#")
			strings.write_int(&b, int(c))
			strings.write_byte(&b, ';')
		case:
			strings.write_byte(&b, c)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// The value of a body `attribute_body` wrote.
@(private = "file")
attribute_body_text :: proc(body: string) -> string {
	quoted := body[strings.index_byte(body, '"') + 1:len(body) - 1]
	b := strings.builder_make()
	for i := 0; i < len(quoted); i += 1 {
		if quoted[i] == '&' {
			end := strings.index_byte(quoted[i:], ';')
			n, _ := strconv.parse_int(quoted[i + 2:i + end])
			strings.write_byte(&b, u8(n))
			i += end
		} else {
			strings.write_byte(&b, quoted[i])
		}
	}
	return strings.to_string(b)
}

// `v`'s property `name`: the filter's write, else the value of its node's fact, a number when the fact spells one.
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
	fact, _ := fact_step(step)
	if fact == .Attribute {
		return write_attribute(ip, v, attribute_step_name(step), nv)
	}
	if role, is_comment := comment_role(fact); is_comment {
		return write_comments(ip, v, role, nv)
	}
	name, writable := property_name(fact)
	if !writable || name == .Name || name == .Namespace || name == .Content {
		return nil, fail(ip, "A markup name, namespace, content, instruction or doctype cannot be written")
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

// `v` with its attribute `name` written as `nv`, or removed by null: in place of one of that name, else after the others.
@(private = "file")
write_attribute :: proc(ip: ^Interp, v: Value, name: string, nv: Value) -> (Value, Signal) {
	text, is_text := string_of(nv)
	if !is_text && kind(nv) != .Null {
		return nil, fail(ip, "an attribute is a string or null")
	}
	have, _ := comments(v, .Attribute)
	bodies := make([dynamic]string, 0, len(have) + 1)
	found := false
	for body in have {
		if attribute_read_name(v, body) != name {
			append(&bodies, body)
		} else if !found && is_text {
			append(&bodies, attribute_body(attribute_body_name(body), text))
		}
		found ||= attribute_read_name(v, body) == name
	}
	if !found && is_text {
		append(&bodies, attribute_body(name, text))
	}
	return noted(v, .Attribute, bodies[:]), .Go
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
		if r, is_ref := plain(old).(Ref); is_ref && name == .Tag {
			text = core_pkg.kept_tag(r.doc, text, nv) or_continue
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
