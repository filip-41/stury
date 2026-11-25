// Before-load value coercions operating natively on `rules.Value` (zero serialize-reparse).
package model

import "base:runtime"
import "stury:lib/schema/rules"

// Rewrites a member's incoming `rules.Value` before the model decodes and validates it.
Before_Fn :: proc(value: rules.Value, r: ^Report) -> rules.Value

@(private)
Before_Call :: proc(value: rules.Value, fn: rawptr, r: ^Report) -> rules.Value

@(private)
Before :: struct {
	call: Before_Call,
	fn:   rawptr,
}

@(private)
Before_Of :: struct {
	type:  typeid,
	field: string,
	b:     Before,
}

// Rewrites member `field` of struct `T` before a load decodes it.
// Replaces any earlier before-coercion on the same `(T, field)`.
// A member `T` lacks is refused by `compile`.
register_before :: proc(reg: ^Registry, $T: typeid, field: string, rewrite: Before_Fn) -> runtime.Allocator_Error {
	call :: proc(value: rules.Value, fn: rawptr, r: ^Report) -> rules.Value {
		return (Before_Fn)(fn)(value, r)
	}
	return add_hook(reg, &reg.befores, Before_Of{T, field, {call = call, fn = rawptr(rewrite)}}, true)
}

@(private)
before_of :: proc(reg: ^Registry, owner: typeid, field: string) -> (b: Before, ok: bool) {
	if reg == nil {
		return
	}
	for x in reg.befores {
		if x.type == owner && x.field == field {
			return x.b, true
		}
	}
	return
}
