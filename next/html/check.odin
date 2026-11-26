// Streaming HTML5 schema validation directly over the format walk (zero intermediate Document).
package html

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import schema_check "stury:lib/schema/check"

// Validates `src`, an HTML5 text of `spec`, against compiled schema `plan` by streaming tokens
// directly into `schema_check.Checker` with zero intermediate `tape.Document` allocation.
@(require_results)
check :: #force_inline proc(src: []u8, plan: ^schema_check.Plan, spec := Spec.Html, opts := schema_check.Options{}, sink: ^schema_check.Sink = nil, allocator := context.allocator) -> schema_check.Result {
	hook.probe_stack(READ_STACK)
	switch spec {
	case .Html:
		return check_dispatch(src, plan, .Html, {}, opts, sink, allocator)
	case .Fragment:
		return check_dispatch(src, plan, .Fragment, {}, opts, sink, allocator)
	}
	return {valid = false, err = {kind = .Bad_Option, keyword = "spec"}}
}

// Streaming schema validation of an HTML5 fragment with explicit `fopts`.
@(require_results)
check_fragment :: proc(src: []u8, plan: ^schema_check.Plan, fopts := Fragment_Options{}, opts := schema_check.Options{}, sink: ^schema_check.Sink = nil, allocator := context.allocator) -> schema_check.Result {
	hook.probe_stack(READ_STACK)
	return check_dispatch(src, plan, .Fragment, fopts, opts, sink, allocator)
}

@(private)
check_dispatch :: #force_inline proc(src: []u8, plan: ^schema_check.Plan, $S: Spec, fopts: Fragment_Options, opts: schema_check.Options, sink: ^schema_check.Sink, allocator: runtime.Allocator) -> schema_check.Result {
	lax := opts.budget.steps != 0
	if opts.dups == .Refuse {
		return check_as(src, plan, S, fopts, true, true, opts, sink, allocator) if lax else check_as(src, plan, S, fopts, false, true, opts, sink, allocator)
	}
	return check_as(src, plan, S, fopts, true, false, opts, sink, allocator) if lax else check_as(src, plan, S, fopts, false, false, opts, sink, allocator)
}

@(private)
check_as :: #force_no_inline proc(src: []u8, plan: ^schema_check.Plan, $S: Spec, fopts: Fragment_Options, $LAX, $REFUSE: bool, opts: schema_check.Options, sink: ^schema_check.Sink, allocator: runtime.Allocator) -> schema_check.Result {
	walk_opts := Options{dups = opts.dups, budget = opts.budget, scratch = opts.scratch}
	TREE_SPEC :: Tree_Spec.Fragment when S == .Fragment else Tree_Spec.Document
	when S == .Fragment {
		if fopts.context_name != "" || fopts.context_namespace != .Html || fopts.scripting {
			if plan == nil || len(plan.records) == 0 {
				return {valid = false, err = {kind = .Bad_Option, keyword = "plan"}}
			}
			doc, berr := build_fragment(src, fopts, walk_opts, opts.scratch if opts.scratch.procedure != nil else allocator)
			if berr != nil {
				kind := schema_check.Error_Kind.Walk
				at := u64(0)
				kw := ""
				switch e in berr {
				case runtime.Allocator_Error:
					kind = .No_Memory
				case tape.Bad_Option:
					kind = .Bad_Option
					kw = e.option
				case tape.Exceeded:
					kind = .Exceeded
					at = e.at
				case tape.Fault:
					at = e.at
				case tape.Piece_Gap:
					kind = .Walk
				}
				return {valid = false, err = {kind = kind, at = at, keyword = kw, walk_err = berr}, allocator = allocator}
			}
			defer tape.destroy(&doc)
			return schema_check.check_document(&doc, plan, opts, sink, allocator)
		}
	}
	when REFUSE {
		walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^schema_check.Refusing_Checker, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
			return walk_tree_text(src, TREE_SPEC, opts, {}, 0, LAX, h, regs, a, ctx, schema_check.refusing_hook)
		}
		return schema_check.check_stream(src, plan, &FORMATS[S], opts, walk_opts, sink, allocator, schema_check.Refusing_Checker, walk)
	} else {
		walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^schema_check.Checker, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
			return walk_tree_text(src, TREE_SPEC, opts, {}, 0, LAX, h, regs, a, ctx, schema_check.checker_hook)
		}
		build_last :: proc(src: []u8, opts: Options, a: runtime.Allocator) -> (tape.Document, tape.Error) {
			return build(src, S, opts, a)
		}
		return schema_check.check_stream(src, plan, &FORMATS[S], opts, walk_opts, sink, allocator, schema_check.Checker, walk, build_last)
	}
}
