package core

import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import spell "./spell"

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
// name, else after the others, or removed when `text` is nil. An attribute that already holds `text` keeps its body. A
// new body is quoted, with the markup, the quote and the white space a reader would fold to a space written as
// references.
attribute_bodies :: proc(v: Value, name: string, text: Maybe(string)) -> []string {
	have, _ := comments(v, .Attribute)
	if want, is_text := text.?; is_text {
		if current, held := attributes_value(v, name, true).(string); held && current == want {
			return have
		}
	}
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

// `v` with the attributes of each element in it read as members, made in the context allocator: attribute `name` as
// the member `@name` before the element's own, and an element of text or of nothing with attributes as an object of
// them with its text as `MARKUP_TEXT`. A value of no markup document is `v`. `members_as_attributes` reads it back.
attributes_as_members :: proc(v: Value) -> Value {
	#partial switch x in v {
	case ^Array:
		a := new_array(len(x.items))
		for item in x.items {
			array_append(a, attributes_as_members(item))
		}
		return a
	case ^Object:
		o := new_object()
		keys, vals := object_keys(x), object_vals(x)
		for k, i in keys {
			object_append(o, k, attributes_as_members(vals[i]))
		}
		return o
	case Node_Ref:
		if !is_markup(x.doc) {
			return v
		}
		attributes, _ := attributes_value(x, "", false).(^Object)
		element := x.doc.nodes[x.node].kind == .Object
		if attributes == nil && !element {
			return v
		}
		o := new_object()
		if attributes != nil {
			akeys, avals := object_keys(attributes), object_vals(attributes)
			for k, i in akeys {
				object_append(o, strings.concatenate({"@", k}), avals[i])
			}
		}
		if element {
			mkeys, mvals := object_keys(markup_members(x)), object_vals(markup_members(x))
			for k, i in mkeys {
				object_append(o, k, attributes_as_members(mvals[i]))
			}
		} else if value_kind(v) != .Null {
			object_append(o, MARKUP_TEXT, v)
		}
		return o
	}
	return v
}

// `v` with each member `@name` of an object in it whose value is a string, a number or a boolean read as attribute
// `name` of the element the object is, made in the context allocator, and one whose value is null left out. An object
// left with only `MARKUP_TEXT` is the element of that text, and one left with nothing an empty element. A node of a
// document is built first.
members_as_attributes :: proc(v: Value) -> Value {
	#partial switch x in v {
	case ^Array:
		a := new_array(len(x.items))
		for item in x.items {
			array_append(a, members_as_attributes(item))
		}
		return a
	case ^Object:
		bodies := make([dynamic]string)
		o := new_object()
		keys, vals := object_keys(x), object_vals(x)
		for k, i in keys {
			if name, s, is_attribute := member_attribute(k, vals[i]); is_attribute {
				append(&bodies, attribute_body(name, s))
			} else if len(k) < 2 || k[0] != '@' {
				object_append(o, k, members_as_attributes(vals[i]))
			} else if value_kind(vals[i]) != .Null {
				object_append(o, k, vals[i])
			}
		}
		if len(bodies) == 0 {
			return o
		}
		content: Value = o
		okeys, ovals := object_keys(o), object_vals(o)
		if len(okeys) == 0 {
			content = nil
		} else if len(okeys) == 1 && okeys[0] == MARKUP_TEXT {
			content = ovals[0]
		}
		return noted(content, .Attribute, bodies[:])
	case Node_Ref:
		if k := value_kind(v); k == .Object || k == .Array {
			return members_as_attributes(built_value(x))
		}
	}
	return v
}

// The attribute the member `key` holding `v` stands for in the view `attributes_as_members` reads: a member `@name`
// holding a string, a number or a boolean, with its text, a float's in the temp allocator. No markup name starts with
// `@`, so no such member is an element.
member_attribute :: proc(key: string, v: Value) -> (name, text: string, ok: bool) {
	if len(key) < 2 || key[0] != '@' {
		return
	}
	text, ok = attribute_text(v)
	return key[1:], text, ok
}

// The text of the scalar `v` as an attribute's value, its digits for a number, a float's in the temp allocator. False for
// null and a container.
@(private = "file")
attribute_text :: proc(v: Value) -> (string, bool) {
	#partial switch x in plain(v) {
	case string:
		return x, true
	case bool:
		return "true" if x else "false", true
	case Number_View:
		return string(x.text[:x.len]), true
	case f64:
		if math.is_inf(x) || math.is_nan(x) {
			return "", false
		}
		buf := make([]u8, spell.F64_ROOM, context.temp_allocator)
		return string(buf[:spell.f64_text(raw_data(buf), x)]), true
	}
	return "", false
}
