// Typed Odin data models: reflection, validation rules, defaults, carriers, coercions, and schema generation.
package model

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:strings"

// Tracks which members of a struct were explicitly present in a load or patch (inline 128-bit + wide fallback).
Fields_Set :: struct {
	bits: [2]u64,
	wide: []u64,
}

fields_set_has :: proc "contextless" (s: Fields_Set, idx: int) -> bool {
	if idx < 0 { return false }
	if idx < 128 { return (s.bits[idx / 64] >> uint(idx % 64)) & 1 != 0 }
	w := (idx - 128) / 64
	return w < len(s.wide) && (s.wide[w] >> uint((idx - 128) % 64)) & 1 != 0
}

fields_set_set :: proc(s: ^Fields_Set, idx, total_fields: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	if idx < 0 { return nil }
	if idx < 128 { s.bits[idx / 64] |= u64(1) << uint(idx % 64); return nil }
	w := (idx - 128) / 64
	if w >= len(s.wide) {
		fresh := make([]u64, max(w + 1, (total_fields - 128 + 63) / 64), allocator) or_return
		if len(s.wide) > 0 { copy(fresh, s.wide); delete(s.wide, allocator) }
		s.wide = fresh
	}
	s.wide[w] |= u64(1) << uint((idx - 128) % 64)
	return nil
}

fields_set_merge :: proc(dst: ^Fields_Set, src: Fields_Set, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	dst.bits[0] |= src.bits[0]; dst.bits[1] |= src.bits[1]
	if len(src.wide) == 0 { return nil }
	if len(dst.wide) < len(src.wide) {
		fresh := make([]u64, len(src.wide), allocator) or_return
		if len(dst.wide) > 0 { copy(fresh, dst.wide); delete(dst.wide, allocator) }
		dst.wide = fresh
	}
	for word, i in src.wide { dst.wide[i] |= word }
	return nil
}

fields_set_destroy :: proc(s: ^Fields_Set, allocator := context.allocator) {
	if s == nil { return }
	if len(s.wide) > 0 { delete(s.wide, allocator) }
	s^ = {}
}

Access :: enum u8 { Read_Write, Read_Only, Write_Only }

Naming :: struct {
	fields:       Rename,
	enums:        Enum_Spelling,
	enum_members: Rename,
	union_tag:    string,
}

Type_Rule :: struct { type: typeid, tag: string }
Field_Rule_Of :: struct { type: typeid, field, tag: string }
Extra :: enum u8 { Ignore, Forbid }

@(private)
Loads :: struct {
	defaults:    [dynamic]Default_Of,
	forbids:     [dynamic]typeid,
	memory:      mem.Dynamic_Arena,
	arena_ready: bool,
	allocator:   runtime.Allocator,
}

Registry :: struct {
	naming:     Naming,
	types:      [dynamic]Type_Rule,
	fields:     [dynamic]Field_Rule_Of,
	loads:      Loads,
	validators: [dynamic]Validator_Of,
	befores:    [dynamic]Before_Of,
	customs:    [dynamic]Custom_Of,
	enums:      [dynamic]Enum_Rule,
	unions:     [dynamic]Union_Rule,
	schemas:    [dynamic]Schema_Of,
}

@(private)
reg_arena :: proc(reg: ^Registry) -> runtime.Allocator {
	if !reg.loads.arena_ready {
		alloc := reg.loads.allocator if reg.loads.allocator.procedure != nil else context.allocator
		reg.loads.allocator = alloc
		mem.dynamic_arena_init(&reg.loads.memory, alloc, alloc)
		reg.loads.arena_ready = true
	}
	return mem.dynamic_arena_allocator(&reg.loads.memory)
}

@(private)
kept :: proc(reg: ^Registry, text: string) -> (string, runtime.Allocator_Error) {
	if len(text) == 0 { return "", nil }
	return strings.clone(text, reg_arena(reg))
}

register :: proc {
	register_naming, register_type, register_field, register_default, register_factory,
	register_extra, register_after, register_validator, register_before, register_custom,
	register_enum, register_union, register_schema,
}

register_naming :: proc(reg: ^Registry, naming: Naming) -> runtime.Allocator_Error {
	ut := kept(reg, naming.union_tag) or_return
	reg.naming = naming; reg.naming.union_tag = ut
	return nil
}

register_type :: proc(reg: ^Registry, rule: Type_Rule) -> runtime.Allocator_Error {
	_, err := append(&reg.types, Type_Rule{rule.type, kept(reg, rule.tag) or_return})
	return err
}

register_field :: proc(reg: ^Registry, rule: Field_Rule_Of) -> runtime.Allocator_Error {
	_, err := append(&reg.fields, Field_Rule_Of{rule.type, kept(reg, rule.field) or_return, kept(reg, rule.tag) or_return})
	return err
}

register_default :: proc(reg: ^Registry, $T: typeid, field: string, value: $V) -> Error where !intrinsics.type_is_proc(V) {
	held: rawptr
	if has_member(T, field, nil) {
		val := value
		c := default_constant(reg, reflect.struct_field_by_name(T, field).type, field, any{&val, typeid_of(V)}) or_return
		held = c
	}
	if aerr := add_default(reg, {T, field, copied_constant, held}); aerr != nil { return aerr }
	return nil
}

register_factory :: proc(reg: ^Registry, $T: typeid, field: string, make_fn: proc(allocator: runtime.Allocator) -> $V) -> runtime.Allocator_Error {
	if has_member(T, field, nil) && !has_member(T, field, V) { return .Invalid_Argument }
	made :: proc(dest, data: rawptr, allocator: runtime.Allocator) -> runtime.Allocator_Error {
		(^V)(dest)^ = (proc(allocator: runtime.Allocator) -> V)(data)(allocator)
		return nil
	}
	return add_default(reg, {T, field, made, rawptr(make_fn)})
}

register_extra :: proc(reg: ^Registry, $T: typeid, extra: Extra) -> runtime.Allocator_Error {
	for x, i in reg.loads.forbids { if x == T { unordered_remove(&reg.loads.forbids, i); break } }
	if extra == .Forbid { _, err := append(&reg.loads.forbids, T); return err }
	return nil
}

@(private)
has_member :: proc(T: typeid, field: string, V: typeid) -> bool {
	if T == nil || len(field) == 0 { return false }
	m := reflect.struct_field_by_name(T, field)
	return m.name == field && m.type != nil && (V == nil || m.type.id == V)
}

@(private)
add_default :: proc(reg: ^Registry, d: Default_Of) -> runtime.Allocator_Error {
	entry := d; entry.field = kept(reg, d.field) or_return
	_, err := append(&reg.loads.defaults, entry)
	return err
}

@(private)
add_hook :: proc(reg: ^Registry, list: ^[dynamic]$X, x: X, replace: bool) -> runtime.Allocator_Error {
	if replace {
		for &y in list {
			if y.type == x.type && y.field == x.field { f := y.field; y = x; y.field = f; return nil }
		}
	}
	entry := x; entry.field = kept(reg, x.field) or_return
	_, err := append(list, entry)
	return err
}

Model :: struct($T: typeid) {
	plan:        Type_Plan,
	tag:         string,
	judging:     ^Applied,
	constants:   mem.Dynamic_Arena,
	const_ready: bool,
	allocator:   runtime.Allocator,
}

@(require_results)
compile :: proc(reg: ^Registry, $T: typeid, tag := "json", allocator := context.allocator) -> (m: Model(T), err: Error) {
	m.allocator, m.tag, m.const_ready = allocator, tag if tag != "" else "stury", true
	mem.dynamic_arena_init(&m.constants, allocator, allocator)
	defer if err != nil { model_destroy(&m) }

	if reg != nil {
		if uerr := unknown_member(reg); uerr != nil { return m, uerr }
		if eerr := enum_rules_refused(reg); eerr.kind != .None { return m, eerr }
	}
	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)

	defaults := copied_defaults(reg, mem.dynamic_arena_allocator(&m.constants), scratch) or_return
	m.plan = build_type_plan(reg, T, m.tag, defaults, allocator, scratch) or_return
	m.judging = judging_of(reg, &m.plan, allocator, scratch) or_return
	if m.judging != nil {
		m.plan.can_stream = false
	}
	return m, nil
}

@(private)
unknown_member :: proc(reg: ^Registry) -> Error {
	refused :: proc(type: typeid, field, item: string) -> Error { return Model_Error{kind = .Bad_Tag, pointer = field, want = {type, item}} }
	for x in reg.fields { if !has_member(x.type, x.field, nil) { return refused(x.type, x.field, x.tag) } }
	for x in reg.loads.defaults { if !has_member(x.type, x.field, nil) { return refused(x.type, x.field, "default") } }
	for x in reg.befores { if !has_member(x.type, x.field, nil) { return refused(x.type, x.field, "before") } }
	for x in reg.validators { if len(x.field) > 0 && !has_member(x.type, x.field, nil) { return refused(x.type, x.field, "after") } }
	return nil
}

destroy :: proc { registry_destroy, model_destroy, problem_destroy, sink_destroy, fields_set_destroy, error_destroy }

registry_destroy :: proc(reg: ^Registry) {
	if reg == nil { return }
	delete(reg.validators); delete(reg.befores); delete(reg.types); delete(reg.fields)
	delete(reg.loads.defaults); delete(reg.loads.forbids); delete(reg.customs)
	delete(reg.enums); delete(reg.unions); delete(reg.schemas)
	if reg.loads.arena_ready { mem.dynamic_arena_destroy(&reg.loads.memory) }
	reg^ = {}
}

model_destroy :: proc(m: ^Model($T)) {
	if m == nil { return }
	judging_destroy(m.judging); type_plan_destroy(&m.plan)
	if m.const_ready { mem.dynamic_arena_destroy(&m.constants) }
	m^ = {}
}

@(private)
held_type :: proc(ti: ^runtime.Type_Info) -> ^runtime.Type_Info {
	if ti == nil { return nil }
	#partial switch v in runtime.type_info_base(ti).variant {
	case ^runtime.Type_Info_Pointer: return v.elem
	case ^runtime.Type_Info_Union:   if len(v.variants) == 1 && !v.no_nil { return v.variants[0] }
	}
	return nil
}

@(private)
forbids_extra :: proc(reg: ^Registry, owner: typeid) -> bool {
	if reg == nil { return false }
	for x in reg.loads.forbids { if x == owner { return true } }
	return false
}
