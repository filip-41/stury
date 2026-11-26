// Custom per-field (`after`), per-struct (`validator`), and declarative named validators (`x-stury-validators`).
package model

import "base:runtime"
import "core:mem"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"

// JSON Schema extension keyword for declarative named validators.
X_STURY_VALIDATORS_KEY :: "x-stury-validators"

@(private)
Report_Failure :: struct { field, message: string }
Report :: struct { failures: [dynamic]Report_Failure, allocator: runtime.Allocator, failed, oom: bool }

fail :: proc(r: ^Report, message: string) { fail_at(r, "", message) }
fail_at :: proc(r: ^Report, field, message: string) {
	if r == nil { return }
	r.failed = true; if _, err := append(&r.failures, Report_Failure{field, message}); err != nil { r.oom = true }
}

@(private)
report_init :: proc(r: ^Report, scratch: runtime.Allocator) { r^ = {allocator = scratch}; r.failures.allocator = scratch }
@(private)
report_reset :: proc(r: ^Report) { r.failed, r.oom = false, false; clear(&r.failures) }
@(private)
report_destroy :: proc(r: ^Report) { delete(r.failures); r^ = {} }

@(private)
Validator_Call :: proc(value, fn: rawptr, r: ^Report)
@(private)
Validator :: struct { call: Validator_Call, fn: rawptr }
@(private)
Validator_Of :: struct { type: typeid, field: string, v: Validator }

register_after :: proc(reg: ^Registry, $T: typeid, field: string, check_fn: proc(value: $V, r: ^Report)) -> runtime.Allocator_Error {
	if has_member(T, field, nil) && !has_member(T, field, V) { return .Invalid_Argument }
	call :: proc(value, fn: rawptr, r: ^Report) { (proc(value: V, r: ^Report))(fn)((^V)(value)^, r) }
	return add_hook(reg, &reg.validators, Validator_Of{T, field, {call, rawptr(check_fn)}}, false)
}

register_validator :: proc(reg: ^Registry, $T: typeid, check_fn: proc(value: T, r: ^Report)) -> runtime.Allocator_Error {
	call :: proc(value, fn: rawptr, r: ^Report) { (proc(value: T, r: ^Report))(fn)((^T)(value)^, r) }
	return add_hook(reg, &reg.validators, Validator_Of{T, "", {call, rawptr(check_fn)}}, false)
}

// ============================================================================
// Declarative Named Validators (`Validator_Registry`, `x-stury-validators`)
// ============================================================================

// Callback for a named validator operating on a decoded Odin value (`any`), reporting failures into `r`.
Named_Validator_Fn :: proc(value: any, r: ^Report, data: rawptr)

// Callback for a named validator operating directly on a `rules.Value` (e.g. schema-driven document validation).
Value_Validator_Fn :: proc(value: rules.Value, r: ^Report, data: rawptr)

Named_Validator :: struct {
	name: string,
	fn:   Named_Validator_Fn,
	vfn:  Value_Validator_Fn,
	data: rawptr,
}

@(private)
Named_Validator_Ref :: struct {
	name:  string,
	v:     Named_Validator,
	has_v: bool,
}

// Caller-owned registry of declarative named validators (zero global mutable state).
Validator_Registry :: struct {
	entries:     map[string]Named_Validator,
	arena:       mem.Dynamic_Arena,
	arena_ready: bool,
	allocator:   runtime.Allocator,
}

validator_registry_init :: proc(vr: ^Validator_Registry, allocator := context.allocator) {
	if vr == nil { return }
	vr^ = {allocator = allocator}
	mem.dynamic_arena_init(&vr.arena, allocator, allocator)
	vr.arena_ready = true
	vr.entries.allocator = allocator
}

validator_registry_destroy :: proc(vr: ^Validator_Registry) {
	if vr == nil { return }
	delete(vr.entries)
	if vr.arena_ready { mem.dynamic_arena_destroy(&vr.arena) }
	vr^ = {}
}

@(private)
vr_ensure :: proc(vr: ^Validator_Registry) -> runtime.Allocator {
	if !vr.arena_ready {
		alloc := vr.allocator if vr.allocator.procedure != nil else context.allocator
		vr.allocator = alloc
		mem.dynamic_arena_init(&vr.arena, alloc, alloc)
		vr.arena_ready = true
		vr.entries.allocator = alloc
	}
	return mem.dynamic_arena_allocator(&vr.arena)
}

register_named_validator :: proc {
	register_named_validator_any,
	register_named_validator_typed,
	register_named_validator_value,
	register_reg_named_validator_any,
	register_reg_named_validator_typed,
	register_reg_named_validator_value,
}

register_named_validator_any :: proc(vr: ^Validator_Registry, name: string, fn: Named_Validator_Fn, data: rawptr = nil, vfn: Value_Validator_Fn = nil) -> runtime.Allocator_Error {
	if vr == nil || !valid_validator_name(name) || (fn == nil && vfn == nil) { return .Invalid_Argument }
	arena := vr_ensure(vr)
	key := strings.clone(name, arena) or_return
	_, err := map_insert(&vr.entries, key, Named_Validator{name = key, fn = fn, vfn = vfn, data = data})
	return err
}

register_named_validator_value :: proc(vr: ^Validator_Registry, name: string, vfn: Value_Validator_Fn, data: rawptr = nil) -> runtime.Allocator_Error {
	return register_named_validator_any(vr, name, nil, data, vfn)
}

register_named_validator_typed :: proc(vr: ^Validator_Registry, name: string, $V: typeid, check_fn: proc(value: V, r: ^Report)) -> runtime.Allocator_Error {
	if vr == nil || !valid_validator_name(name) || check_fn == nil { return .Invalid_Argument }
	call :: proc(value: any, r: ^Report, data: rawptr) {
		fn := (proc(value: V, r: ^Report))(data)
		if value.data == nil || value.id == nil { return }
		if value.id == V { fn((^V)(value.data)^, r); return }
		// Unwrap `Maybe(T)` and `^T` transparently when validating optional/nullable fields.
		cur_data := value.data
		cur_ti := type_info_of(value.id)
		for cur_ti != nil {
			base := runtime.type_info_base(cur_ti)
			if p, is_ptr := base.variant.(^runtime.Type_Info_Pointer); is_ptr && p.elem != nil {
				inner := (^rawptr)(cur_data)^
				if inner == nil { return }
				cur_data, cur_ti = inner, p.elem
			} else if u, is_u := base.variant.(^runtime.Type_Info_Union); is_u && len(u.variants) == 1 && !u.no_nil {
				if u.tag_type == nil {
					if (^rawptr)(cur_data)^ == nil { return }
				} else {
					tag := u64(0)
					mem.copy(&tag, rawptr(uintptr(cur_data) + u.tag_offset), u.tag_type.size)
					if tag == 0 { return }
				}
				cur_ti = u.variants[0]
			} else {
				break
			}
			if cur_ti.id == V { fn((^V)(cur_data)^, r); return }
		}
		when V == string {
			if cur_ti != nil {
				if str_ti, is_str := runtime.type_info_base(cur_ti).variant.(^runtime.Type_Info_String); is_str && !str_ti.is_cstring {
					fn((^string)(cur_data)^, r); return
				}
			}
		}
		fail(r, "validator type mismatch")
	}
	vcall: Value_Validator_Fn = nil
	when V == string {
		vcall = proc(val: rules.Value, r: ^Report, data: rawptr) {
			if rules.value_kind(val) != .String { return }
			buf: [256]u8 = ---
			s, owned, ok := rules.value_string(val, buf[:], r.allocator)
			if !ok { r.oom = true; return }
			defer if owned { delete(s, r.allocator) }
			(proc(value: string, r: ^Report))(data)(s, r)
		}
	} else when V == i64 || V == int {
		vcall = proc(val: rules.Value, r: ^Report, data: rawptr) {
			if rules.value_kind(val) != .Number { return }
			buf: [64]u8 = ---
			s, owned, ok := rules.value_number_text(val, buf[:], r.allocator)
			if !ok {
				if ref, is_ref := val.(rules.Node_Ref); is_ref && ref.doc != nil && tape.text_room(ref.doc, ref.node) > len(buf) { r.oom = true }
				return
			}
			defer if owned { delete(s, r.allocator) }
			d := rules.decimal_of(s)
			if iv, fits := rules.decimal_i64(d); fits && rules.integral(d) {
				(proc(value: V, r: ^Report))(data)(V(iv), r)
			}
		}
	} else when V == f64 {
		vcall = proc(val: rules.Value, r: ^Report, data: rawptr) {
			if rules.value_kind(val) != .Number { return }
			if fv, is_f := val.(f64); is_f { (proc(value: f64, r: ^Report))(data)(fv, r); return }
			buf: [64]u8 = ---
			s, owned, ok := rules.value_number_text(val, buf[:], r.allocator)
			if !ok {
				if ref, is_ref := val.(rules.Node_Ref); is_ref && ref.doc != nil && tape.text_room(ref.doc, ref.node) > len(buf) { r.oom = true }
				return
			}
			defer if owned { delete(s, r.allocator) }
			(proc(value: f64, r: ^Report))(data)(parse_f64_approx(s), r)
		}
	} else when V == bool {
		vcall = proc(val: rules.Value, r: ^Report, data: rawptr) {
			vk := rules.value_kind(val)
			if vk != .True && vk != .False { return }
			(proc(value: bool, r: ^Report))(data)(vk == .True, r)
		}
	}
	return register_named_validator_any(vr, name, call, rawptr(check_fn), vcall)
}

register_reg_named_validator_any :: proc(reg: ^Registry, name: string, fn: Named_Validator_Fn, data: rawptr = nil, vfn: Value_Validator_Fn = nil) -> runtime.Allocator_Error {
	if reg == nil { return .Invalid_Argument }
	return register_named_validator_any(&reg.named_validators, name, fn, data, vfn)
}

register_reg_named_validator_value :: proc(reg: ^Registry, name: string, vfn: Value_Validator_Fn, data: rawptr = nil) -> runtime.Allocator_Error {
	if reg == nil { return .Invalid_Argument }
	return register_named_validator_value(&reg.named_validators, name, vfn, data)
}

register_reg_named_validator_typed :: proc(reg: ^Registry, name: string, $V: typeid, check_fn: proc(value: V, r: ^Report)) -> runtime.Allocator_Error {
	if reg == nil { return .Invalid_Argument }
	return register_named_validator_typed(&reg.named_validators, name, V, check_fn)
}

lookup_named_validator :: proc(vr: ^Validator_Registry, name: string) -> (v: Named_Validator, ok: bool) {
	if vr == nil || len(vr.entries) == 0 { return {}, false }
	return vr.entries[name]
}

@(private)
resolve_named_validator :: proc(primary, secondary: ^Validator_Registry, name: string) -> (v: Named_Validator, ok: bool) {
	if v, ok = lookup_named_validator(primary, name); ok { return }
	return lookup_named_validator(secondary, name)
}

// Invokes all named validators in `refs` on `(val_ptr, ti)`.
// Returns the first missing validator name if any ref was deferred and not found in `runtime_vr`.
@(private)
run_named_validators :: proc(refs: []Named_Validator_Ref, val_ptr: rawptr, ti: ^runtime.Type_Info, runtime_vr: ^Validator_Registry, rep: ^Report) -> (missing: string) {
	if len(refs) == 0 || ti == nil { return "" }
	val := any{val_ptr, ti.id}
	for ref in refs {
		nv: Named_Validator
		found := false
		// Runtime registry overrides compile-time binding when provided.
		if runtime_vr != nil {
			nv, found = lookup_named_validator(runtime_vr, ref.name)
		}
		if !found && ref.has_v {
			nv, found = ref.v, true
		}
		if !found {
			return ref.name
		}
		if nv.fn != nil {
			nv.fn(val, rep, nv.data)
		}
	}
	return ""
}

@(private)
emit_report :: proc(r: ^Report, base_steps: []tape.Step, at: u64, si: ^Struct_Info, sink: ^Sink, first: ^Model_Error, oom: ^bool, allocator, scratch: runtime.Allocator, silent := false, secret := false) -> bool {
	if r.oom { if oom != nil { oom^ = true }; return false }
	if !r.failed { return true }
	steps, serr := make([dynamic]tape.Step, 0, len(base_steps) + 1, scratch)
	if serr != nil { if oom != nil { oom^ = true }; return false }
	defer delete(steps)
	for f in r.failures {
		clear(&steps); if _, aerr := append(&steps, ..base_steps); aerr != nil { if oom != nil { oom^ = true }; return false }
		field_secret := secret
		if f.field != "" {
			wire := f.field
			if si != nil {
				for fld in si.fields {
					if fld.odin_name == f.field || fld.name == f.field {
						wire = fld.name
						field_secret ||= .Secret in fld.flags
						break
					}
				}
			}
			if _, aerr := append(&steps, tape.Name(wire)); aerr != nil { if oom != nil { oom^ = true }; return false }
		}
		if !record_failure(sink, first, oom, allocator, .Custom, at, steps[:], "", {text = f.message}, silent, field_secret) { return false }
	}
	return true
}
