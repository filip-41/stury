package yaml

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"

// Typed reads: a YAML text read into an Odin value directly during the walk with no intermediate `Document`.
// Struct members match tags under `yaml`, or else `stury`.

Plan :: typed.Plan
Unmarshal_Options :: typed.Unmarshal_Options
Raw :: typed.Raw
Typed_Refusal :: typed.Typed_Refusal
plan_destroy :: typed.plan_destroy

@(private)
TAG :: "yaml"

// Builds a reusable plan of `T` for YAML reads/writes (`Unmarshal_Options.plan` / `marshal`).
@(require_results)
plan_make :: proc($T: typeid, opts := typed.Plan_Options{}, allocator := context.allocator) -> (Plan, Error) {
	return typed.plan_make(T, TAG, opts, allocator)
}

// Reads `src`, a single YAML document of `spec`, into `target`.
@(require_results)
unmarshal :: #force_inline proc(src: []u8, target: ^$T, spec := Spec.Yaml_1_2, read := Unmarshal_Options{}, opts := Options{}, allocator := context.allocator) -> Error {
	hook.probe_stack(READ_STACK)
	return unmarshal_type(src, target, T, spec, read, opts, allocator)
}

@(private)
unmarshal_type :: #force_inline proc(src: []u8, target: rawptr, T: typeid, spec: Spec, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> Error {
	switch spec {
	case .Yaml_1_2:
		return unmarshal_spec(src, target, T, .Yaml_1_2, read, opts, allocator)
	case .Yaml_Merge:
		return unmarshal_spec(src, target, T, .Yaml_Merge, read, opts, allocator)
	}
	return Bad_Option{"spec"}
}

@(private)
unmarshal_spec :: #force_inline proc(src: []u8, target: rawptr, T: typeid, $S: Spec, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> Error {
	lax := opts.budget.steps != 0
	if opts.dups == .Refuse {
		return unmarshal_as(src, target, T, S, true, true, read, opts, allocator) if lax else unmarshal_as(src, target, T, S, false, true, read, opts, allocator)
	}
	return unmarshal_as(src, target, T, S, true, false, read, opts, allocator) if lax else unmarshal_as(src, target, T, S, false, false, read, opts, allocator)
}

@(private)
unmarshal_as :: #force_no_inline proc(src: []u8, target: rawptr, T: typeid, $S: Spec, $LAX, $REFUSE: bool, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> Error {
	when REFUSE {
		refusing :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^typed.Refusing_Reader, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
			on :: #force_inline proc "contextless" (h: ^typed.Refusing_Reader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
				return typed.refusing_hook(h, s, t, number_value)
			}
			end, err, tolerated := walk_text(src, S, LAX, opts, h, regs, a, ctx, on)
			return end, typed.refusing_end(h, err, &RULES), tolerated
		}
		return typed.read(src, target, T, &FORMATS[S], TAG, opts, read, allocator, typed.Refusing_Reader, refusing)
	} else {
		walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^typed.Text_Reader, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
			on :: #force_inline proc "contextless" (h: ^typed.Text_Reader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
				return typed.text_hook(h, s, t, number_value)
			}
			return walk_text(src, S, LAX, opts, h, regs, a, ctx, on)
		}
		return typed.read(src, target, T, &FORMATS[S], TAG, opts, read, allocator, typed.Text_Reader, walk)
	}
}
