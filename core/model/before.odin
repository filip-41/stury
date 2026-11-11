package model

import "base:runtime"
import core ".."
import typed "../typed"

@(private)
Before_Of :: struct {
	type:  typeid,
	field: string,
	b:     typed.Before,
}

// Rewrites member `field` of `T` before a load reads it. `rewrite` gets the member's value as the format spells it, as a
// `core.Value`, and answers the value to read in its place, which is read as the member's type and judged by its rules
// and validators as the text would have been. It runs for a member the load read and not in `validate`, which judges values
// already read. One a member has: a later call replaces an earlier. Refuses as `.Invalid_Argument` a member `T` lacks.
register_before :: proc(reg: ^Registry, $T: typeid, field: string, rewrite: proc(value: core.Value, r: ^Report) -> core.Value) -> runtime.Allocator_Error {
	call :: proc(value: core.Value, fn: rawptr, r: ^Report) -> core.Value {
		return (proc(value: core.Value, r: ^Report) -> core.Value)(fn)(value, r)
	}
	if !has_member(T, field, nil) {
		return .Invalid_Argument
	}
	return add_hook(&reg.befores, Before_Of{T, field, {call = call, fn = rawptr(rewrite), value = typed.before_value}}, true)
}

// A copy of the `before` of member `field` of `owner` in a plan that loads, nil for none.
@(private)
before_of :: proc(c: ^Compiling, owner: typeid, field: string) -> ^typed.Before {
	if !c.model.loading {
		return nil
	}
	for x in c.reg.befores {
		if x.type == owner && x.field == field {
			b := new_clone(x.b, context.temp_allocator)
			return b
		}
	}
	return nil
}

// The refusal of a load plan `p` whose format holds no value alone, a table's, and so reads no text whole, for a member
// read by its first matching arm or judged by applicators.
@(private)
judged_refused :: proc(p: ^typed.Plan) -> core.Typed_Refusal {
	if p.value_text != nil {
		return {}
	}
	for &m in p.meta {
		if m.before != nil && (m.before.first_match || m.before.judge != nil) {
			return {kind = .Unsupported, want = {m.type, "first match" if m.before.first_match else "applicator"}}
		}
	}
	return {}
}
