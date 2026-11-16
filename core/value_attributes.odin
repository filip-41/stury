package core

import "core:slice"
import "core:strconv"
import "core:strings"

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
			attribute_add(&o, key, text)
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
		attribute_add(&o, key, text)
	}
	return o if o != nil else nil
}

// Sets attribute `key` to `text` in `o`, made on first use.
@(private = "file")
attribute_add :: proc(o: ^^Object, key: string, text: Value) {
	if o^ == nil {
		o^ = new_object()
	}
	object_put(o^, key, text)
}

// The attributes of the element `v` is as `attributes_value` reads them, when they are not its node's as its document
// holds them: those written on it, or past a value that is no node, its origin's. False for a node's own.
rebuilt_attributes :: proc(v: Value) -> (attributes: ^Object, rebuilt: bool) {
	if !role_rebuilt(v, .Attribute) {
		return nil, false
	}
	attributes, _ = attributes_value(v, "", false).(^Object)
	return attributes, true
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
