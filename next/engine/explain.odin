package engine

import "core:fmt"
import "core:strings"
import "stury:lib/query"

// Human-readable `--explain` formatting for `Decision` and its `query.Plan`.

@(private = "file", rodata)
FRAMING_NAMES := [Framing]string {
	.Single       = "single",
	.Lines        = "lines",
	.Seq          = "seq",
	.Elements     = "elements",
	.Members      = "members",
	.Concatenated = "concatenated",
}

@(private = "file", rodata)
ROUTE_NAMES := [Route_Kind]string {
	.Whole             = "whole",
	.Scan              = "scan",
	.Records_Serial    = "records_serial",
	.Records_Parallel  = "records_parallel",
	.Spine_Parallel    = "spine_parallel",
	.Projection_Direct = "projection_direct",
	.Conditional_Whole = "conditional_whole",
	.Files_Parallel    = "files_parallel",
}

@(private = "file", rodata)
HINT_NAMES := [Active_Hint]string {
	.None              = "none",
	.Spine_Split       = "spine_split",
	.Projection_Direct = "projection_direct",
	.Conditional_Whole = "conditional_whole",
}

@(private = "file", rodata)
WHY_TEXT := [Route_Why]string {
	.Edit_Needs_Layout     = "edit/fmt/in-place requires full document layout",
	.Format_No_Scan        = "input format does not support partial scan (built whole)",
	.All_Unbounded         = "all demand steps are unbounded wildcards (cheaper whole)",
	.Serial_Program        = "serial program property prevents parallel execution",
	.Eval_Ctx_Serial       = "unsynchronized evaluation context requires serial execution",
	.Dups_Need_Build       = "duplicate-key policy requires full container build",
	.Force_Whole           = "caller forced whole document build",
	.Facts_Need_Scan       = "output comments/facts keep facts along scanned paths",
	.Facts_Need_Whole      = "comments/facts requested on non-scannable format",
	.Slurp_Whole           = "slurp collects all inputs into a single array",
	.Raw_Lines             = "raw input reads each line as a string",
	.Demand_Whole          = "program demand requires the whole value",
	.Demand_None           = "program reads no fields from main input",
	.Where_Needs_Evaluator = "source provenance (--where) requires evaluator",
	.No_Runner             = "no multi-thread worker pool supplied",
	.Input_Too_Small       = "input below parallel size threshold",
	.Partial_Demand        = "partial demand scans only needed paths",
	.Projection_Direct_Hit = "Hint 2: direct projection emits leaf values without evaluator",
	.Conditional_Whole_Hit = "Hint 3: conditional whole scans predicate before building whole",
	.Spine_Split_Hit       = "Hint 1: per-element array split fans elements across worker pool",
	.Records_Framing       = "framed input iterates record by record",
	.Parallel_Worker_Pool  = "executes in parallel across worker pool",
	.Many_Files            = "multiple files dispatched across worker pool",
}

// Returns canonical string label for `Route_Kind`.
route_kind_name :: proc "contextless" (kind: Route_Kind) -> string {
	return ROUTE_NAMES[kind]
}

// Returns human-readable reason string for `Route_Why`.
route_why_text :: proc "contextless" (why: Route_Why) -> string {
	return WHY_TEXT[why]
}

// Formats a complete `--explain` report into `b` covering format, framing,
// contract demand/serial/hints (`query.format_plan`), chosen route, and reasons.
explain_to :: proc(b: ^strings.Builder, plan: ^query.Plan, decision: ^Decision) {
	if decision == nil {
		return
	}
	fmt.sbprintf(b, "format: %s (%s), framing: %s\n", decision.entry.title, decision.entry.name, FRAMING_NAMES[decision.framing])
	if plan != nil {
		query.format_plan(b, plan)
	}
	fmt.sbprintf(
		b,
		"route: %s (hint=%s, parallel=%s, facts=%s, origins=%s)\n",
		ROUTE_NAMES[decision.kind],
		HINT_NAMES[decision.active_hint],
		"yes" if decision.parallel else "no",
		"yes" if decision.keep_facts else "no",
		"yes" if decision.keep_origins else "no",
	)
	fmt.sbprintf(b, "why: %s\n", WHY_TEXT[decision.primary_why])
	for w in Route_Why {
		if w == decision.primary_why || w not_in decision.whys {
			continue
		}
		fmt.sbprintf(b, "because: %s\n", WHY_TEXT[w])
	}
}

// Renders `--explain` output as a newly allocated string owned by the caller.
@(require_results)
explain :: proc(plan: ^query.Plan, decision: ^Decision, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	explain_to(&b, plan, decision)
	return strings.to_string(b)
}
