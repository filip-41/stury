package msgpack

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import schema_check "stury:lib/schema/check"

// Streaming schema validation directly over the MessagePack walk (zero intermediate `tape.Document`).
@(require_results)
check :: #force_inline proc(src: []u8, plan: ^schema_check.Plan, spec := Spec.Msgpack, opts := schema_check.Options{}, sink: ^schema_check.Sink = nil, allocator := context.allocator) -> schema_check.Result {
	hook.probe_stack(READ_STACK)
	switch spec {
	case .Msgpack:
		return check_spec(src, plan, .Msgpack, opts, sink, allocator)
	case .Compact:
		return check_spec(src, plan, .Compact, opts, sink, allocator)
	}
	return {valid = false, err = {kind = .Bad_Option, keyword = "spec"}}
}

@(private)
check_spec :: #force_inline proc(src: []u8, plan: ^schema_check.Plan, $S: Spec, opts: schema_check.Options, sink: ^schema_check.Sink, allocator: runtime.Allocator) -> schema_check.Result {
	lax := opts.budget.steps != 0
	if opts.dups == .Refuse {
		return check_as(src, plan, S, true, true, opts, sink, allocator) if lax else check_as(src, plan, S, false, true, opts, sink, allocator)
	}
	return check_as(src, plan, S, true, false, opts, sink, allocator) if lax else check_as(src, plan, S, false, false, opts, sink, allocator)
}

@(private)
check_as :: #force_no_inline proc(src: []u8, plan: ^schema_check.Plan, $S: Spec, $LAX, $REFUSE: bool, opts: schema_check.Options, sink: ^schema_check.Sink, allocator: runtime.Allocator) -> schema_check.Result {
	walk_opts := Options{dups = opts.dups, budget = opts.budget, scratch = opts.scratch}
	when REFUSE {
		walk_fn :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^schema_check.Refusing_Checker, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
			return walk_text(src, S, LAX, opts, h, regs, a, ctx, schema_check.refusing_hook)
		}
		return schema_check.check_stream(src, plan, &FORMATS[S], opts, walk_opts, sink, allocator, schema_check.Refusing_Checker, walk_fn)
	} else {
		walk_fn :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^schema_check.Checker, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
			return walk_text(src, S, LAX, opts, h, regs, a, ctx, schema_check.checker_hook)
		}
		build_last :: proc(src: []u8, opts: Options, a: runtime.Allocator) -> (tape.Document, tape.Error) {
			return build(src, S, opts, a)
		}
		return schema_check.check_stream(src, plan, &FORMATS[S], opts, walk_opts, sink, allocator, schema_check.Checker, walk_fn, build_last)
	}
}
