package jq

// Comments as a filter reads and writes them, over the library's comments on values (`core.Commented`).
//
// In a path a comment role is a step of its own, the object `{"fact": "comment"}` (or `"comment_inline"`,
// `"comment_foot"`), and only the last step: `.a.@comment` is the path `["a", {"fact": "comment"}]`.

import core_pkg "../../../core"

// The name of each comment role as a path step spells it, and as `.@` reads it after its `@`.
COMMENT_ROLE_NAMES :: #partial [core_pkg.Role]string {
	.Comment        = "comment",
	.Comment_Inline = "comment_inline",
	.Comment_Foot   = "comment_foot",
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

// The role path step `key` names, when it is one: an object whose one member `fact` names a role.
fact_step :: proc(key: Value) -> (role: core_pkg.Role, ok: bool) {
	if kind(key) != .Object || length_of(key) != 1 {
		return
	}
	name, _ := object_get(key, "fact")
	s, is_str := string_of(name)
	if !is_str {
		return
	}
	names := COMMENT_ROLE_NAMES
	for r in core_pkg.COMMENT_ROLES {
		if names[r] == s {
			return r, true
		}
	}
	return
}

// The path step of `role`.
fact_key :: proc(role: core_pkg.Role) -> Value {
	o := new_object()
	names := COMMENT_ROLE_NAMES
	object_put(o, "fact", names[role])
	return o
}

fact_step_not_last :: proc(ip: ^Interp) -> Signal {
	return fail(ip, "A comment step must be the last step of a path")
}

// The keys of a deletion that are not role steps, in an order of their own, and the roles the others name.
split_fact_steps :: proc(keys: []Value) -> ([]Value, bit_set[core_pkg.Role]) {
	keys := keys
	roles: bit_set[core_pkg.Role]
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
remove_comments :: proc(ip: ^Interp, v: Value, roles: bit_set[core_pkg.Role]) -> (Value, Signal) {
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
