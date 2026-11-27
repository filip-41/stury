// Streaming TOML 1.0 / 1.1 schema validation directly over the format walk (zero intermediate Document).
package toml

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import schema_check "stury:lib/schema/check"

// The stack room a TOML check probes up front (matching `json`/`xml`/`cbor`).
READ_STACK :: 48 * 1024

// Validates `src`, a TOML text of `spec`, against compiled schema `plan` by streaming tokens
// directly into `schema_check.Checker` with zero intermediate `tape.Document` allocation.
// Preserves per-spec dead-stripping. Duplicate keys are natively refused by the TOML walk.
@(require_results)
check :: #force_inline proc(src: []u8, plan: ^schema_check.Plan, spec := Spec.Toml_1_0, opts := schema_check.Options{}, sink: ^schema_check.Sink = nil, allocator := context.allocator) -> schema_check.Result {
	hook.probe_stack(READ_STACK)
	lax := opts.budget.steps != 0
	switch spec {
	case .Toml_1_0:
		return check_as(src, plan, .Toml_1_0, true, opts, sink, allocator) if lax else check_as(src, plan, .Toml_1_0, false, opts, sink, allocator)
	case .Toml_1_1:
		return check_as(src, plan, .Toml_1_1, true, opts, sink, allocator) if lax else check_as(src, plan, .Toml_1_1, false, opts, sink, allocator)
	}
	return {valid = false, err = {kind = .Bad_Option, keyword = "spec"}}
}

@(private)
check_as :: #force_no_inline proc(src: []u8, plan: ^schema_check.Plan, $S: Spec, $LAX: bool, opts: schema_check.Options, sink: ^schema_check.Sink, allocator: runtime.Allocator) -> schema_check.Result {
	if opts.dups == .All {
		refused := tape.Error(tape.Bad_Option{"dups"})
		return {valid = false, err = {kind = .Bad_Option, keyword = "dups", walk_err = refused}, walk_err = refused}
	}
	walk_opts := Options{dups = opts.dups, budget = opts.budget, scratch = opts.scratch}
	walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^schema_check.Checker, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return walk_text(src, S, LAX, opts, h, regs, a, ctx, schema_check.checker_hook)
	}
	build_last :: proc(src: []u8, opts: Options, a: runtime.Allocator) -> (tape.Document, tape.Error) {
		return build(src, S, opts, a)
	}
	return schema_check.check_stream(src, plan, &FORMATS[S], opts, walk_opts, sink, allocator, schema_check.Checker, walk, build_last)
}
