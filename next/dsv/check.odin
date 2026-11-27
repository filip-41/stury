// Streaming DSV (CSV/TSV/Plain) schema validation directly over the format walk (zero intermediate Document).
package dsv

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import schema_check "stury:lib/schema/check"

// Validates `src`, a delimited text of `spec`, against compiled schema `plan` by streaming tokens
// directly into `schema_check.Checker` with zero intermediate `tape.Document` allocation.
// Preserves per-spec dead-stripping and optional `tape.Dsv_Options`.
@(require_results)
check :: #force_inline proc(src: []u8, plan: ^schema_check.Plan, spec := Spec.Csv, opts := schema_check.Options{}, sink: ^schema_check.Sink = nil, allocator := context.allocator, dsv_opts := tape.Dsv_Options{}) -> schema_check.Result {
	switch spec {
	case .Csv:   return check_spec(src, plan, .Csv, opts, sink, allocator, dsv_opts)
	case .Tsv:   return check_spec(src, plan, .Tsv, opts, sink, allocator, dsv_opts)
	case .Plain: return check_spec(src, plan, .Plain, opts, sink, allocator, dsv_opts)
	}
	return {valid = false, err = {kind = .Bad_Option, keyword = "spec"}}
}

@(private)
check_spec :: #force_inline proc(src: []u8, plan: ^schema_check.Plan, $S: Spec, opts: schema_check.Options, sink: ^schema_check.Sink, allocator: runtime.Allocator, dsv_opts: tape.Dsv_Options) -> schema_check.Result {
	walk_opts := Options{dups = opts.dups, budget = opts.budget, scratch = opts.scratch, format = dsv_opts}
	if _, refused := pass_options(S, walk_opts); refused != nil {
		return {valid = false, err = {kind = .Bad_Option, walk_err = refused}, walk_err = refused}
	}
	rb: hook.Read_Budget
	out_alloc := hook.read_budget(&rb, walk_opts, allocator)
	local_mb: hook.Memory_Budget
	scratch := hook.scratch(walk_opts, out_alloc, &local_mb)
	if e := refuse_repeat(src, S, walk_opts, scratch); e != nil {
		if walk_opts.budget.memory > 0 {
			e = hook.memory_budget_error(&rb.main, e)
		}
		kind := schema_check.Error_Kind.Duplicate_Key
		#partial switch _ in e {
		case tape.Exceeded:           kind = .Exceeded
		case runtime.Allocator_Error: kind = .No_Memory
		}
		return {valid = false, err = {kind = kind, walk_err = e}, walk_err = e}
	}
	return check_as(src, plan, S, true, opts, walk_opts, sink, allocator) if opts.budget.steps != 0 else check_as(src, plan, S, false, opts, walk_opts, sink, allocator)
}

@(private)
check_as :: #force_no_inline proc(src: []u8, plan: ^schema_check.Plan, $S: Spec, $LAX: bool, opts: schema_check.Options, walk_opts: Options, sink: ^schema_check.Sink, allocator: runtime.Allocator) -> schema_check.Result {
	walk :: #force_inline proc "contextless" (src: []u8, o: Options, h: ^schema_check.Checker, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, options_resolved(S, o), h, regs, a, ctx, schema_check.checker_hook, nil, o.budget.steps)
	}
	build_last :: proc(src: []u8, o: Options, a: runtime.Allocator) -> (tape.Document, tape.Error) {
		return build(src, S, o, a)
	}
	return schema_check.check_stream(src, plan, &FORMATS[S], opts, walk_opts, sink, allocator, schema_check.Checker, walk, build_last)
}
