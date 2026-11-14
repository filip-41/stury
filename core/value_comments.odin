package core

// Comments on values. A value carries, per comment role, either nothing written on it or the bodies written
// (`Commented`), and a node shows its document's comments for each role not written. Comments are not data: every
// reader of a value's data sees through `Commented` (`plain`).

import "core:slice"
import "core:strconv"
import "core:strings"

// The roles a comment takes.
COMMENT_ROLES :: bit_set[Role]{.Comment, .Comment_Inline, .Comment_Foot}

// A value with comments written on it. `v` is never itself a `^Commented`, and `kind` is its kind, so `kind` reads it
// without a call. A role in `written` reads `bodies` for that role, an empty list being a role removed, and a role
// not in it reads what `v` carries, a node's comments in its document, or past a `v` that is no node, the facts of
// `origin`, the markup node an update put `v` in place of, when it has one. A change makes a new one.
Commented :: struct {
	v:       Value,
	kind:    Kind,
	written: bit_set[Role],
	bodies:  [Role][]string,
	origin:  Node_Ref,
}

// Where the comments `comments` returns for a role come from.
Comment_From :: enum u8 {
	None, // nothing of this role is written on the value and its node has no comment of it
	Written, // this role is written: the bodies written, none when the role was removed
	Source, // this role is not written and the value is a node whose document has comments of it
}

// `v` without the comments written on it.
plain :: #force_inline proc(v: Value) -> Value {
	if c, is_commented := v.(^Commented); is_commented {
		return c.v
	}
	return v
}

// The node whose facts `v` reads where it writes none: the node `v` is, else the one an update put it in place of.
facts_node :: proc(v: Value) -> (Node_Ref, bool) {
	if c, is_commented := v.(^Commented); is_commented {
		if r, is_ref := c.v.(Node_Ref); is_ref {
			return r, true
		}
		return c.origin, c.origin.doc != nil
	}
	r, is_ref := v.(Node_Ref)
	return r, is_ref
}

// `v` put in place of markup node `origin`, whose name, attributes and other facts it reads where it writes none.
in_place_of :: proc(v: Value, origin: Node_Ref) -> Value {
	if _, is_ref := plain(v).(Node_Ref); is_ref {
		return v
	}
	c := commented(v)
	c.origin = origin
	return c
}

// The comments of `role` on `v`, and where they come from. Written bodies are as they were written. Source bodies are a
// comment's text without its markers and the one space next to each (`// a` and `/* a */` read "a"), sliced from the
// source or, past one, in a slice made in the context allocator. An attribute's body is `name="value"` as `set_fact`
// takes it, its name and its quoted value as written, made in the context allocator.
comments :: proc(v: Value, role: Role) -> (bodies: []string, from: Comment_From) {
	if c, is_commented := v.(^Commented); is_commented && role in c.written {
		return c.bodies[role], .Written
	}
	r, is_ref := facts_node(v)
	if !is_ref || len(r.doc.facts) == 0 {
		return nil, .None
	}
	texts: [dynamic]string
	for f in all_facts(r.doc, r.node) {
		if f.role != role {
			continue
		}
		if role == .Attribute {
			name, value := r.doc.readers.attribute(r.doc, f)
			quoted := r.doc.src[value.lo - 1:][:value.n + 2]
			append(&texts, strings.concatenate({string(r.doc.src[name.lo:][:name.n]), "=", string(quoted)}))
			continue
		}
		text, _ := comment_text(r.doc, f)
		append(&texts, text)
	}
	if len(texts) == 0 {
		return nil, .None
	}
	return texts[:], .Source
}

// `v` with its comments of `role` written as `bodies`, an empty list removing the role.
noted :: proc(v: Value, role: Role, bodies: []string) -> Value {
	c := commented(v)
	c.written += {role}
	c.bodies[role] = bodies
	return c
}

// `nv` put where `old` was: it keeps `old`'s comments of each role `nv` does not bring, written or from the source.
keep_comments :: #force_inline proc(old, nv: Value) -> Value {
	#partial switch x in old {
	case ^Commented:
		return merge_comments(old, nv)
	case Node_Ref:
		if len(x.doc.facts) > 0 {
			return merge_comments(old, nv)
		}
	}
	return nv
}

@(private = "file")
merge_comments :: #force_no_inline proc(old, nv: Value) -> Value {
	if r, is_ref := old.(Node_Ref); is_ref {
		if s, same := nv.(Node_Ref); same && s == r {
			return nv
		}
	}
	c: ^Commented
	for role in COMMENT_ROLES {
		if _, brought := comments(nv, role); brought != .None {
			continue
		}
		bodies, from := comments(old, role)
		if from == .None {
			continue
		}
		if c == nil {
			c = commented(nv)
		}
		c.written += {role}
		c.bodies[role] = bodies
	}
	if c == nil {
		return nv
	}
	return c
}

// The tag a value `nv` put in place of a node of `doc` tagged `tag` keeps, and false for none: the one the format judges
// `nv` to fit where its tags state a type, else `tag`.
kept_tag :: proc(doc: ^Document, tag: string, nv: Value) -> (string, bool) {
	if doc.readers == nil || doc.readers.tag_fits == nil {
		return tag, true
	}
	return doc.readers.tag_fits(tag, nv)
}

// `inner`, the value `c` wraps after a change to its data, with `c`'s comments.
rewrap :: proc(c: ^Commented, inner: Value) -> Value {
	w := new(Commented)
	w^ = c^
	w.v = plain(inner)
	w.kind = value_kind(w.v)
	return w
}

// A new `^Commented` with the data and comments of `v`.
@(private = "file")
commented :: proc(v: Value) -> ^Commented {
	c := new(Commented)
	if x, is_commented := v.(^Commented); is_commented {
		c^ = x^
	} else {
		c.v = v
		c.kind = value_kind(v)
	}
	return c
}

// The attributes of the element `v` is, by name as read: with `one` the value of the attribute `name`, else an object
// of every one's value, made in the context allocator. Null for a value that is no element or has none, or none of
// that name. A body written on `v` that its node has is read as the source reads it, and any other as
// `attribute_bodies` spells it.
attributes_value :: proc(v: Value, name: string, one: bool) -> Value {
	if c, is_commented := v.(^Commented); is_commented && .Attribute in c.written {
		node, is_node := facts_node(c)
		source: []string
		if is_node {
			source, _ = comments(node, .Attribute)
		}
		o: ^Object
		for body in c.bodies[.Attribute] {
			key := attribute_read_name(c, body)
			if one && key != name {
				continue
			}
			text := attributes_value(node, key, true) if slice.contains(source, body) else Value(attribute_body_text(body))
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
	r, is_ref := facts_node(v)
	if !is_ref || len(r.doc.facts) == 0 {
		return nil
	}
	o: ^Object
	it := attributes_of(r.doc, r.node)
	for k, value in attribute_next(&it) {
		key, _ := token_text(r.doc.readers, &r.doc.view, k, context.allocator)
		if one && key != name {
			continue
		}
		text, _ := token_text(r.doc.readers, &r.doc.view, value, context.allocator)
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

// The attributes of the element `v` is as `attributes_value` reads them, when they are not its node's as its document
// holds them: those written on it, or past a value that is no node, its origin's. False for a node's own.
rebuilt_attributes :: proc(v: Value) -> (attributes: ^Object, rebuilt: bool) {
	c, is_commented := v.(^Commented)
	if _, is_ref := plain(v).(Node_Ref); !is_commented || is_ref && .Attribute not_in c.written {
		return nil, false
	}
	attributes, _ = attributes_value(v, "", false).(^Object)
	return attributes, true
}

// The comments of `role` on `v` when they are not its node's as its document holds them: those written on it, or past a
// value that is no node, its origin's. False for a node's own.
rebuilt_comments :: proc(v: Value, role: Role) -> (bodies: []string, rebuilt: bool) {
	c, is_commented := v.(^Commented)
	if !is_commented {
		return nil, false
	}
	if _, is_ref := c.v.(Node_Ref); is_ref && role not_in c.written {
		return nil, false
	}
	bodies, _ = comments(v, role)
	return bodies, true
}

// The attribute bodies of the element `v` with its attribute `name` given the value `text`, in place of one of that
// name, else after the others, or removed when `text` is nil. A new body is quoted, with the markup, the quote and the
// white space a reader would fold to a space written as references.
attribute_bodies :: proc(v: Value, name: string, text: Maybe(string)) -> []string {
	have, _ := comments(v, .Attribute)
	bodies := make([dynamic]string, 0, len(have) + 1)
	text, is_text := text.?
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
	return bodies[:]
}

// The name of attribute body `body`, what stands before its `=`.
@(private = "file")
attribute_body_name :: proc(body: string) -> string {
	eq := strings.index_byte(body, '=')
	return strings.trim_right_space(body[:eq if eq >= 0 else len(body)])
}

// The name the format reads from attribute `body`: what its reader makes of the name the element's source spells that
// way, as HTML folds capitals, else the name as written.
@(private = "file")
attribute_read_name :: proc(v: Value, body: string) -> string {
	written := attribute_body_name(body)
	if r, is_ref := facts_node(v); is_ref && len(r.doc.facts) > 0 {
		it := attributes_of(r.doc, r.node)
		for k, _ in attribute_next(&it) {
			if string(r.doc.src[k.lo:][:k.n]) == written {
				read, _ := token_text(r.doc.readers, &r.doc.view, k, context.allocator)
				return read
			}
		}
	}
	return written
}

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
