// Streaming YAML schema validation directly over the walk (zero intermediate Document).
package yaml

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import schema_check "stury:lib/schema/check"

// Validates `src`, a YAML text of `spec`, against compiled schema `plan` by streaming tokens directly into
// `schema_check.Checker` with zero intermediate `tape.Document` allocation.
@(require_results)
check :: #force_inline proc(src: []u8, plan: ^schema_check.Plan, spec := Spec.Yaml_1_2, opts := schema_check.Options{}, sink: ^schema_check.Sink = nil, allocator := context.allocator, yaml_opts := tape.Yaml_Options{}) -> schema_check.Result {
	hook.probe_stack(READ_STACK)
	switch spec {
	case .Yaml_1_2:
		return check_spec(src, plan, .Yaml_1_2, opts, sink, allocator, yaml_opts)
	case .Yaml_Merge:
		return check_spec(src, plan, .Yaml_Merge, opts, sink, allocator, yaml_opts)
	}
	return {valid = false, err = {kind = .Bad_Option, keyword = "spec"}}
}

@(private)
check_spec :: #force_inline proc(src: []u8, plan: ^schema_check.Plan, $S: Spec, opts: schema_check.Options, sink: ^schema_check.Sink, allocator: runtime.Allocator, yaml_opts: tape.Yaml_Options) -> schema_check.Result {
	walk_opts := Options{dups = opts.dups, budget = opts.budget, format = yaml_opts, scratch = opts.scratch}
	if e := tape.options_refused(&FORMATS[S], walk_opts); e != nil {
		return {valid = false, err = {kind = .Bad_Option, keyword = "format", walk_err = e}, walk_err = e}
	}
	lax := opts.budget.steps != 0
	if opts.dups == .Refuse {
		return check_as(src, plan, S, true, true, opts, walk_opts, sink, allocator) if lax else check_as(src, plan, S, false, true, opts, walk_opts, sink, allocator)
	}
	return check_as(src, plan, S, true, false, opts, walk_opts, sink, allocator) if lax else check_as(src, plan, S, false, false, opts, walk_opts, sink, allocator)
}

@(private)
check_as :: #force_no_inline proc(src: []u8, plan: ^schema_check.Plan, $S: Spec, $LAX, $REFUSE: bool, opts: schema_check.Options, walk_opts: Options, sink: ^schema_check.Sink, allocator: runtime.Allocator) -> schema_check.Result {
	when REFUSE {
		walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^schema_check.Refusing_Checker, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
			return walk_text(src, S, LAX, opts, h, regs, a, ctx, schema_check.refusing_hook)
		}
		return schema_check.check_stream(src, plan, &FORMATS[S], opts, walk_opts, sink, allocator, schema_check.Refusing_Checker, walk)
	} else {
		walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^schema_check.Checker, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
			return walk_text(src, S, LAX, opts, h, regs, a, ctx, schema_check.checker_hook)
		}
		build_last :: proc(src: []u8, opts: Options, a: runtime.Allocator) -> (tape.Document, tape.Error) {
			return build(src, S, opts, a)
		}
		return schema_check.check_stream(src, plan, &FORMATS[S], opts, walk_opts, sink, allocator, schema_check.Checker, walk, build_last)
	}
}
