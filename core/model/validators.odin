package model

import "base:runtime"
import typed "../typed"
import write "../write"

// What a validator reports its failures to: `fail` fails the value the validator judges and `fail_at` a member of it.
Report :: typed.Report

fail :: typed.fail

fail_at :: typed.fail_at

@(private)
Validator_Of :: struct {
	type:  typeid,
	field: string, // "" for a validator of the whole struct
	v:     typed.Validator,
}

// Judges member `field` of `T`, of type `V`, once it is read and has passed its type and rules, in a load and in
// `validate`. It runs only for a member the load read, and only if nothing under the member failed. A member may have
// several, which run in the order they were registered. Refuses as `.Invalid_Argument` a member of another type, and a
// member `T` lacks is refused by `compile`.
register_after :: proc(reg: ^Registry, $T: typeid, field: string, check: proc(value: $V, r: ^Report)) -> runtime.Allocator_Error {
	if has_member(T, field, nil) && !has_member(T, field, V) {
		return .Invalid_Argument
	}
	call :: proc(value, fn: rawptr, r: ^Report) {
		(proc(value: V, r: ^Report))(fn)((^V)(value)^, r)
	}
	reg.close = typed.validate_closed
	return add_hook(reg, &reg.validators, Validator_Of{T, field, {call, rawptr(check)}}, false)
}

// Judges a whole `T` at its close, in a load and in `validate`, when none of its members failed, innermost struct first.
// A struct may have several, which run in the order they were registered.
register_validator :: proc(reg: ^Registry, $T: typeid, check: proc(value: T, r: ^Report)) -> runtime.Allocator_Error {
	call :: proc(value, fn: rawptr, r: ^Report) {
		(proc(value: T, r: ^Report))(fn)((^T)(value)^, r)
	}
	reg.close = typed.validate_closed
	return add_hook(reg, &reg.validators, Validator_Of{T, "", {call, rawptr(check)}}, false)
}

// The validators of struct `owner`, which a plan keeps.
@(private)
validators_of :: proc(h: ^typed.Model_Rules, owner: typeid) -> []typed.Validator {
	out := make([dynamic]typed.Validator, context.temp_allocator)
	for x in (^Compiling)(h).reg.validators {
		if x.type == owner && x.field == "" {
			append(&out, x.v)
		}
	}
	return out[:]
}

// The closing of a struct in `validate` at its record `end`, as a load closes it.
@(private)
close_struct :: proc(v: ^write.Visitor, end: ^typed.Field, base: uintptr) -> bool {
	j := (^Judging)(v)
	clear(&j.steps)
	if !write.visit_path(&j.visitor, &j.steps) {
		j.first = {kind = .No_Memory}
		return false
	}
	return typed.visit_closed(j.plan, end, base, j.steps[:], &j.first, j.sink, j.floor)
}
