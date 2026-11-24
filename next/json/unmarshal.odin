package json

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"

// Typed reads: a text read into an Odin value during the walk, with no document between them. A struct's members are
// named by their tags under `json`, or else under `stury`.

Plan :: typed.Plan
Unmarshal_Options :: typed.Unmarshal_Options
Raw :: typed.Raw
Typed_Refusal :: typed.Typed_Refusal
plan_destroy :: typed.plan_destroy

@(private)
TAG :: "json"

// The plan of `T` for JSON reads, as `typed.plan_make` makes it, which `unmarshal` takes in `Unmarshal_Options.plan`.
@(require_results)
plan_make :: proc($T: typeid, opts := typed.Plan_Options{}, allocator := context.allocator) -> (Plan, Error) {
	return typed.plan_make(T, TAG, opts, allocator)
}

// Reads `src`, a text of `spec`, into `target`, as `typed.read` reads. Needs `READ_STACK` bytes of stack and faults on a
// thread with less.
@(require_results)
unmarshal :: #force_inline proc(src: []u8, target: ^$T, spec := Spec.Json, read := Unmarshal_Options{}, opts := Options{}, allocator := context.allocator) -> Error {
	return unmarshal_type(src, target, T, spec, read, opts, allocator)
}

@(private)
unmarshal_type :: #force_inline proc(src: []u8, target: rawptr, T: typeid, spec: Spec, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> Error {
	hook.probe_stack(READ_STACK)
	switch spec {
	case .Json:
		return unmarshal_spec(src, target, T, .Json, read, opts, allocator)
	case .Jsonc:
		return unmarshal_spec(src, target, T, .Jsonc, read, opts, allocator)
	case .Json5:
		return unmarshal_spec(src, target, T, .Json5, read, opts, allocator)
	}
	return Bad_Option{"spec"}
}

// A text in pieces is refused by the read, so only a step budget needs the lax walk.
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
