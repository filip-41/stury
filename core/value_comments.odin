package core

// Comments on values. A value carries, per comment role, either nothing written on it or the bodies written
// (`Commented`), and a node shows its document's comments for each role not written. Comments are not data: every
// reader of a value's data sees through `Commented` (`plain`).

import "core:strings"

// The roles a comment takes.
COMMENT_ROLES :: bit_set[Role]{.Comment, .Comment_Inline, .Comment_Foot}

// A value with comments written on it. `v` is never itself a `^Commented`, and `kind` is its kind, so `kind` reads it
// without a call. A role in `written` reads `bodies` for that role, an empty list being a role removed, and a role
// not in it reads what `v` carries, a node's comments in its document. A change makes a new one.
Commented :: struct {
	v:       Value,
	kind:    Kind,
	written: bit_set[Role],
	bodies:  [Role][]string,
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

// The comments of `role` on `v`, and where they come from. Written bodies are as they were written. Source bodies are a
// comment's text without its markers and the one space next to each (`// a` and `/* a */` read "a"), sliced from the
// source or, past one, in a slice made in the context allocator. An attribute's body is `name="value"` as `set_fact`
// takes it, its name and its quoted value as written, made in the context allocator.
comments :: proc(v: Value, role: Role) -> (bodies: []string, from: Comment_From) {
	inner := v
	if c, is_commented := v.(^Commented); is_commented {
		if role in c.written {
			return c.bodies[role], .Written
		}
		inner = c.v
	}
	r, is_ref := inner.(Node_Ref)
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
		body := string(fact_body(r.doc, f))
		text := strings.trim_prefix(body, " ")
		// A block comment's body follows its `/*`, a line comment's its `//`.
		if at := uintptr(raw_data(body)) - uintptr(raw_data(r.doc.src)); r.doc.src[at - 1] == '*' {
			text = strings.trim_suffix(text, " ")
		}
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
