package jq

// Comments on values. A value carries, per role, either nothing the filter said or the bodies the filter wrote
// (`Commented`), and a value of an input document (`Ref`) shows its node's comments for each role the filter has not
// written. Comments are not data: every reader of a value's data sees through `Commented` (`plain`).
//
// In a path a comment role is a step of its own, the object `{"fact": "comment"}` (or `"comment_inline"`,
// `"comment_foot"`), and only the last step: `.a.@comment` is the path `["a", {"fact": "comment"}]`.

import "core:strings"
import core_pkg "../../../core"

Comment_Role :: enum u8 {
	Comment,
	Inline,
	Foot,
}

// The name of each role as a path step spells it, and as `.@` reads it after its `@`.
COMMENT_ROLE_NAMES :: [Comment_Role]string {
	.Comment = "comment",
	.Inline  = "comment_inline",
	.Foot    = "comment_foot",
}

@(private = "file")
CORE_ROLES :: [Comment_Role]core_pkg.Role {
	.Comment = .Comment,
	.Inline  = .Comment_Inline,
	.Foot    = .Comment_Foot,
}

// A value with comments the filter wrote. `v` is never itself a `^Commented`, and `kind` is its kind, so `kind` reads
// it without a call. A role in `written` reads `bodies` for that role, an empty list being a role removed, and a role
// not in it reads what `v` carries, a `Ref`'s source comments. Shared like any value: a change makes a new one.
Commented :: struct {
	v:       Value,
	kind:    Kind,
	written: bit_set[Comment_Role],
	bodies:  [Comment_Role][]string,
}

// Where the comments `comments` returns for a role come from.
Comment_From :: enum u8 {
	None, // the filter wrote no comment of this role and the value has no source comment of it
	Written, // the filter wrote this role: the bodies it wrote, none when it removed the role
	Source, // the filter did not write this role and the value is a node of an input document that has comments of it
}

// `v` without the comments the filter wrote on it: the value printers and the edit command compare and write.
plain :: #force_inline proc(v: Value) -> Value {
	if c, is_commented := v.(^Commented); is_commented {
		return c.v
	}
	return v
}

// The comments of `role` on `v`, and where they come from. Written bodies are as the filter wrote them. Source bodies
// are a comment's text without its markers and the one space next to each (`// a` and `/* a */` read "a"), sliced
// from the source or, past one, in a slice made in the context allocator.
comments :: proc(v: Value, role: Comment_Role) -> (bodies: []string, from: Comment_From) {
	inner := v
	if c, is_commented := v.(^Commented); is_commented {
		if role in c.written {
			return c.bodies[role], .Written
		}
		inner = c.v
	}
	r, is_ref := inner.(Ref)
	if !is_ref || len(r.doc.facts) == 0 {
		return nil, .None
	}
	texts: [dynamic]string
	core_roles := CORE_ROLES
	it := core_pkg.facts_of(r.doc, r.node, core_roles[role])
	for body in core_pkg.fact_next(&it) {
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

// `.@role` of `v`: its comments of `role` as an array of strings, or null when it has none.
comments_value :: proc(v: Value, role: Comment_Role) -> Value {
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
write_comments :: proc(ip: ^Interp, v: Value, role: Comment_Role, bodies: Value) -> (Value, Signal) {
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

// `v` with its comments of `role` written as `bodies`, as `.@role = bodies` writes them.
noted :: proc(v: Value, role: Comment_Role, bodies: []string) -> Value {
	c := commented(v)
	c.written += {role}
	c.bodies[role] = bodies
	return c
}

@(private = "file")
bad_comment :: proc(ip: ^Interp) -> Signal {
	return fail(ip, "a comment is a string, an array of strings, or null")
}

// The role path step `key` names, when it is one: an object whose one member `fact` names a role.
fact_step :: proc(key: Value) -> (role: Comment_Role, ok: bool) {
	if kind(key) != .Object || length_of(key) != 1 {
		return
	}
	name, _ := object_get(key, "fact")
	s, is_str := string_of(name)
	if !is_str {
		return
	}
	names := COMMENT_ROLE_NAMES
	for n, r in names {
		if n == s {
			return r, true
		}
	}
	return
}

// The path step of `role`.
fact_key :: proc(role: Comment_Role) -> Value {
	o := new_object()
	names := COMMENT_ROLE_NAMES
	object_put(o, "fact", names[role])
	return o
}

fact_step_not_last :: proc(ip: ^Interp) -> Signal {
	return fail(ip, "A comment step must be the last step of a path")
}

// The keys of a deletion that are not role steps, in an order of their own, and the roles the others name.
split_fact_steps :: proc(keys: []Value) -> ([]Value, bit_set[Comment_Role]) {
	keys := keys
	roles: bit_set[Comment_Role]
	for i := 0; i < len(keys); {
		if role, is_fact := fact_step(keys[i]); is_fact {
			roles += {role}
			keys[i] = keys[len(keys) - 1]
			keys = keys[:len(keys) - 1]
		} else {
			i += 1
		}
	}
	return keys, roles
}

// `v` without its comments of `roles`.
remove_comments :: proc(ip: ^Interp, v: Value, roles: bit_set[Comment_Role]) -> (Value, Signal) {
	v := v
	for role in roles {
		sig: Signal
		if v, sig = write_comments(ip, v, role, nil); sig != .Go {
			return nil, sig
		}
	}
	return v, .Go
}

// Whether path `p` ends in a role step. Only the step `.@role` makes, an object of the program, is looked at, so the
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

// `nv` put where `old` was: it keeps `old`'s comments of each role `nv` does not bring, written or from the source.
keep_comments :: #force_inline proc(old, nv: Value) -> Value {
	#partial switch x in old {
	case ^Commented:
		return merge_comments(old, nv)
	case Ref:
		if len(x.doc.facts) > 0 {
			return merge_comments(old, nv)
		}
	}
	return nv
}

@(private = "file")
merge_comments :: #force_no_inline proc(old, nv: Value) -> Value {
	if r, is_ref := old.(Ref); is_ref {
		if s, same := nv.(Ref); same && s == r {
			return nv
		}
	}
	c: ^Commented
	for role in Comment_Role {
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
	w.kind = kind(w.v)
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
		c.kind = kind(v)
	}
	return c
}
