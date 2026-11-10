package model

import "base:runtime"
import "core:reflect"
import "core:strings"
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
	return add_before(reg, {T, field, {call = call, fn = rawptr(rewrite)}})
}

@(private)
add_before :: proc(reg: ^Registry, x: Before_Of) -> runtime.Allocator_Error {
	x := x
	if len(x.field) == 0 || reflect.struct_field_by_name(x.type, x.field).name != x.field {
		return .Invalid_Argument
	}
	for &y in reg.befores {
		if y.type == x.type && y.field == x.field {
			y.b = x.b
			return nil
		}
	}
	x.field = strings.clone(x.field) or_return
	if _, err := append(&reg.befores, x); err != nil {
		delete(x.field)
		return err
	}
	return nil
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

// The rules a plan that reads a replacement takes: the member's, at its root, and the load's elsewhere.
@(private)
Replacement_Rules :: struct {
	using c: Compiling,
	root:    typed.Member_Rule,
	type:    typeid,
	rooted:  bool,
}

@(private)
replacement_rule :: proc(h: ^typed.Model_Rules, owner: typeid, field: string, type: typeid, tag: string) -> typed.Member_Rule {
	s := (^Replacement_Rules)(h)
	if owner == nil && !s.rooted && type == s.type {
		s.rooted = true
		return s.root
	}
	return member_rule(&s.c.model, owner, field, type, tag)
}

// Gives each `before` member of the load plan `p` the plan that reads its replacement, as the member's type with the
// member's rules at its root.
@(private)
replacement_plans :: proc(c: ^Compiling, reads: ^typed.Format_Reads, p: ^typed.Plan, allocator: runtime.Allocator) -> core.Typed_Error {
	for &m in p.meta {
		if m.before == nil || p.value_text == nil {
			continue
		}
		s := Replacement_Rules{c = c^, root = {rules = m.before.rules}, type = m.type}
		s.model.member, s.model.rule_sets, s.model.leaves = replacement_rule, nil, nil
		sub, refused := reads.plan(m.type, {enums = c.reg.naming.enums, rename = c.reg.naming.fields, union_tag = c.reg.naming.union_tag, model = &s.model}, allocator)
		if refused.kind == .Unsupported {
			// A format that holds a type only inside a record, a table's, reads a replacement as a cell of its own.
			continue
		}
		if refused.kind != .None {
			return refused
		}
		kept, failed := new_clone(sub, allocator)
		if failed != nil {
			typed.plan_destroy(&sub)
			return {kind = .No_Memory}
		}
		m.before.plan = kept
	}
	return {}
}

// Frees the plans that read the replacements of the load plan `p`'s members.
@(private)
replacement_destroy :: proc(p: ^typed.Plan) {
	for &m in p.meta {
		if m.before != nil && m.before.plan != nil {
			typed.plan_destroy(m.before.plan)
			free(m.before.plan, p.allocator)
			m.before.plan = nil
		}
	}
}
