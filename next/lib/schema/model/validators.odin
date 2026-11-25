// Custom per-field (`after`) and per-struct (`validator`) hooks and `Report`.
package model

import "base:runtime"
import "stury:lib/core/tape"

@(private)
Report_Failure :: struct { field, message: string }

Report :: struct {
	failures:  [dynamic]Report_Failure,
	allocator: runtime.Allocator,
	failed:    bool,
	oom:       bool,
}

fail :: proc(r: ^Report, message: string) {
	if r == nil { return }
	r.failed = true
	if _, err := append(&r.failures, Report_Failure{message = message}); err != nil { r.oom = true }
}

fail_at :: proc(r: ^Report, field, message: string) {
	if r == nil { return }
	r.failed = true
	if _, err := append(&r.failures, Report_Failure{field, message}); err != nil { r.oom = true }
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

@(private)
emit_report :: proc(r: ^Report, base_steps: []tape.Step, at: u64, si: ^Struct_Info, sink: ^Sink, first: ^Model_Error, oom: ^bool, allocator, scratch: runtime.Allocator, silent := false) -> bool {
	if r.oom { if oom != nil { oom^ = true }; return false }
	if !r.failed { return true }
	steps, serr := make([dynamic]tape.Step, 0, len(base_steps) + 1, scratch)
	if serr != nil { if oom != nil { oom^ = true }; return false }
	defer delete(steps)
	for f in r.failures {
		clear(&steps)
		if _, aerr := append(&steps, ..base_steps); aerr != nil { if oom != nil { oom^ = true }; return false }
		if f.field != "" {
			wire := f.field
			if si != nil {
				for fld in si.fields { if fld.odin_name == f.field { wire = fld.name; break } }
			}
			if _, aerr := append(&steps, tape.Name(wire)); aerr != nil { if oom != nil { oom^ = true }; return false }
		}
		if !record_failure(sink, first, oom, allocator, .Custom, at, steps[:], "", {text = f.message}, silent) { return false }
	}
	return true
}
