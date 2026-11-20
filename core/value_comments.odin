package core

// Comments on values. A value carries, per comment role, either nothing written on it or the bodies written
// (`Commented`), and a node shows its document's comments for each role not written. Comments are not data: every
// reader of a value's data sees through `Commented` (`plain`).

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
			append(&texts, attribute_source_body(r.doc, f))
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

// The body of attribute fact `f` as its source spells it: its name, then `=` and its value with the quotes around it, or
// the name alone for an attribute with no value. Made in the context allocator.
attribute_source_body :: proc(doc: ^Document, f: Fact) -> string {
	name, value := doc.readers.attribute(doc, f)
	src := doc.src
	quote := src[value.lo - 1] if value.lo > 0 else 0
	end := value.lo + u64(value.n)
	switch {
	case (quote == '"' || quote == '\'') && end < u64(len(src)) && src[end] == quote:
		return strings.concatenate({string(src[name.lo:][:name.n]), "=", string(src[value.lo - 1:end + 1])})
	case value.n == 0:
		return strings.clone(string(src[name.lo:][:name.n]))
	}
	return strings.concatenate({string(src[name.lo:][:name.n]), "=", string(src[value.lo:end])})
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

// Whether the `role` of `v` is not its node's as its document holds it: written on it, or past a value that is no node.
@(private)
role_rebuilt :: proc(v: Value, role: Role) -> bool {
	c, is_commented := v.(^Commented)
	if !is_commented {
		return false
	}
	_, is_ref := c.v.(Node_Ref)
	return !is_ref || role in c.written
}

// The comments of `role` on `v` when they are not its node's as its document holds them: those written on it, or past a
// value that is no node, its origin's. False for a node's own.
rebuilt_comments :: proc(v: Value, role: Role) -> (bodies: []string, rebuilt: bool) {
	if !role_rebuilt(v, role) {
		return nil, false
	}
	bodies, _ = comments(v, role)
	return bodies, true
}
