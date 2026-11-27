package msgpack

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"

// Typed deserialization directly from the MessagePack walk into Odin values.
// Struct fields honor `` `msgpack:"..."` `` tags first, then `` `stury:"..."` ``.

Plan :: typed.Plan
Unmarshal_Options :: typed.Unmarshal_Options
Raw :: typed.Raw
Typed_Refusal :: typed.Typed_Refusal
plan_destroy :: typed.plan_destroy

@(private)
TAG :: "msgpack"

// Precompiles a typed plan for `T` reusing it across `unmarshal` and `marshal` calls.
@(require_results)
plan_make :: proc($T: typeid, opts := typed.Plan_Options{}, allocator := context.allocator) -> (Plan, tape.Error) {
	return typed.plan_make(T, TAG, opts, allocator)
}

// Unmarshals the MessagePack item in `src` into `target`.
@(require_results)
unmarshal :: #force_inline proc(src: []u8, target: ^$T, spec := Spec.Msgpack, read := Unmarshal_Options{}, opts := Options{}, allocator := context.allocator) -> tape.Error {
	return unmarshal_type(src, target, T, spec, read, opts, allocator)
}

@(private)
unmarshal_type :: #force_inline proc(src: []u8, target: rawptr, T: typeid, spec: Spec, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	hook.probe_stack(READ_STACK)
	switch spec {
	case .Msgpack:
		return unmarshal_spec(src, target, T, .Msgpack, read, opts, allocator)
	case .Compact:
		return unmarshal_spec(src, target, T, .Compact, read, opts, allocator)
	}
	return tape.Bad_Option{"spec"}
}

@(private)
unmarshal_spec :: #force_inline proc(src: []u8, target: rawptr, T: typeid, $S: Spec, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	lax := opts.budget.steps != 0
	if !lax && opts.runner != nil && opts.runner.threads > 0 && opts.pieces == nil && len(src) >= typed.PARALLEL_FROM {
		if opts.dups == .Refuse {
			if err, done := unmarshal_parallel(src, target, T, S, true, read, opts, allocator); done {
				return err
			}
		} else {
			if err, done := unmarshal_parallel(src, target, T, S, false, read, opts, allocator); done {
				return err
			}
		}
	}
	if opts.dups == .Refuse {
		return unmarshal_as(src, target, T, S, true, true, read, opts, allocator) if lax else unmarshal_as(src, target, T, S, false, true, read, opts, allocator)
	}
	return unmarshal_as(src, target, T, S, true, false, read, opts, allocator) if lax else unmarshal_as(src, target, T, S, false, false, read, opts, allocator)
}

@(private)
unmarshal_as :: #force_no_inline proc(src: []u8, target: rawptr, T: typeid, $S: Spec, $LAX, $REFUSE: bool, read: Unmarshal_Options, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	when REFUSE {
		refusing :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^typed.Refusing_Reader, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
			on :: #force_inline proc "contextless" (h: ^typed.Refusing_Reader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
				return typed.refusing_hook(h, s, t, number_in_place)
			}
			end, err, tolerated := walk_text(src, S, LAX, opts, h, regs, a, ctx, on)
			return end, typed.refusing_end(h, err, &RULES), tolerated
		}
		return typed.read(src, target, T, &FORMATS[S], TAG, opts, read, allocator, typed.Refusing_Reader, refusing)
	} else {
		walk_fn :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^typed.Text_Reader, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
			on :: #force_inline proc "contextless" (h: ^typed.Text_Reader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
				return typed.text_hook(h, s, t, number_in_place)
			}
			return walk_text(src, S, LAX, opts, h, regs, a, ctx, on)
		}
		return typed.read(src, target, T, &FORMATS[S], TAG, opts, read, allocator, typed.Text_Reader, walk_fn)
	}
}
