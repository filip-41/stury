package model

import "base:runtime"
import "core:strings"
import core ".."
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
// `validate`. It runs only for a member the load read, and only if nothing under the member failed. One validator a
// member has: a later call replaces an earlier. Refuses as `.Invalid_Argument` a member `T` lacks or one of another type.
register_after :: proc(reg: ^Registry, $T: typeid, field: string, check: proc(value: $V, r: ^Report)) -> runtime.Allocator_Error {
	if !has_member(T, field, V) {
		return .Invalid_Argument
	}
	call :: proc(value, fn: rawptr, r: ^Report) {
		(proc(value: V, r: ^Report))(fn)((^V)(value)^, r)
	}
	return add_validator(reg, {T, field, {call, rawptr(check)}})
}

// Judges a whole `T` at its close, in a load and in `validate`, when none of its members failed, innermost struct first.
// A struct may have several, which run in the order they were registered.
register_validator :: proc(reg: ^Registry, $T: typeid, check: proc(value: T, r: ^Report)) -> runtime.Allocator_Error {
	call :: proc(value, fn: rawptr, r: ^Report) {
		(proc(value: T, r: ^Report))(fn)((^T)(value)^, r)
	}
	return add_validator(reg, {T, "", {call, rawptr(check)}})
}

@(private)
add_validator :: proc(reg: ^Registry, x: Validator_Of) -> runtime.Allocator_Error {
	x := x
	if x.field != "" {
		for &y in reg.validators {
			if y.type == x.type && y.field == x.field {
				y.v = x.v
				return nil
			}
		}
	}
	x.field = strings.clone(x.field) or_return
	if _, err := append(&reg.validators, x); err != nil {
		delete(x.field)
		return err
	}
	return nil
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

// The closing of a struct in `validate`: runs its validators and reports what they found.
@(private)
close_struct :: proc(v: ^write.Visitor, sm: ^typed.Struct_Model, base: uintptr) -> bool {
	j := (^Judging)(v)
	clear(&j.steps)
	if !write.visit_path(&j.visitor, &j.steps) {
		j.first = {kind = .No_Memory}
		return false
	}
	seen := make([]bool, len(sm.afters), context.temp_allocator)
	for &s in seen {
		s = true
	}
	entries: []core.Error_Entry
	if j.sink != nil {
		entries = j.sink.entries[j.floor:]
	}
	verdicts := make([dynamic]typed.Verdict, context.temp_allocator)
	typed.judge_struct(sm, base, j.steps[:], entries, seen, &verdicts)
	for x in verdicts {
		if !report_custom(j, x) {
			return false
		}
	}
	return true
}

// Records the failure of a validator as `validate` records a refusal.
@(private)
report_custom :: proc(j: ^Judging, x: typed.Verdict) -> bool {
	steps := typed.verdict_path(j.steps[:], x, context.temp_allocator)
	if j.first.kind == .None {
		j.first = typed.refusal_at(.Custom, steps, x.failure.message, 0)
	}
	c := j.sink
	if c == nil || !typed.sink_room(c, context.allocator) {
		return false
	}
	entry := core.Error_Entry{kind = .Custom, record = c.record}
	if x.failure.message != "" {
		entry.operand = strings.clone(x.failure.message, c.entries.allocator)
	}
	if !typed.sink_entry(c, entry, steps, nil, false) {
		j.first = {kind = .No_Memory}
		return false
	}
	return true
}
