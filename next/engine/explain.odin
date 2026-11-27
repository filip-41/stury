package engine

import "base:runtime"
import "core:fmt"
import "core:strings"
import "stury:json"
import "stury:lib/core/tape"
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

@(private = "file", rodata)
DEMAND_KIND_NAMES := [query.Demand_Mode]string {
	.None    = "none",
	.Partial = "partial",
	.Whole   = "whole",
}

// Canonical, deterministic machine-readable plan pin for `--plan-out` and `--plan-file`.
Plan_Pin :: struct {
	route:       string,
	framing:     string,
	parallel:    bool,
	hint:        string,
	demand_kind: string,
	format:      string,
}

// Returns canonical string label for `query.Demand_Mode`.
demand_mode_name :: proc "contextless" (mode: query.Demand_Mode) -> string {
	return DEMAND_KIND_NAMES[mode]
}

// Extracts the canonical `Plan_Pin` from `decision` (zero allocations; borrows static rodata strings).
@(require_results)
plan_pin_of :: proc "contextless" (decision: ^Decision) -> Plan_Pin {
	if decision == nil {
		return {}
	}
	return {
		route       = ROUTE_NAMES[decision.kind],
		framing     = FRAMING_NAMES[decision.framing],
		parallel    = decision.parallel,
		hint        = HINT_NAMES[decision.active_hint],
		demand_kind = DEMAND_KIND_NAMES[decision.demand_mode],
		format      = decision.entry.name,
	}
}

// Releases heap-owned string fields produced by `parse_plan_pin_json`.
destroy_plan_pin :: proc(pin: ^Plan_Pin, allocator := context.allocator) {
	if pin == nil {
		return
	}
	delete(pin.route, allocator)
	delete(pin.framing, allocator)
	delete(pin.hint, allocator)
	delete(pin.demand_kind, allocator)
	delete(pin.format, allocator)
	pin^ = {}
}

// Writes the canonical deterministic JSON representation of `pin` into `b` (WASM-clean, no `core:os`).
explain_pin_json_to :: proc(b: ^strings.Builder, decision: ^Decision) {
	pin := plan_pin_of(decision)
	alloc := b.buf.allocator if b.buf.allocator.procedure != nil else context.allocator
	_ = json.marshal_to(strings.to_writer(b), &pin, allocator = alloc)
	strings.write_byte(b, '\n')
}

// Renders the canonical deterministic JSON plan pin as a newly allocated string owned by the caller.
@(require_results)
explain_pin_json :: proc(decision: ^Decision, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	explain_pin_json_to(&b, decision)
	return strings.to_string(b)
}

// Parses a canonical plan pin JSON document produced by `explain_pin_json` (in any key order/whitespace).
// All 6 canonical fields (`route`, `framing`, `parallel`, `hint`, `demand_kind`, `format`) are required.
// Free the returned `Plan_Pin` with `destroy_plan_pin(pin, allocator)` when `ok` is true.
@(require_results)
parse_plan_pin_json :: proc(src: string, allocator := context.allocator) -> (pin: Plan_Pin, ok: bool) {
	doc, berr := json.build(transmute([]u8)src, .Json, {dups = .Refuse}, allocator)
	if berr != nil {
		return {}, false
	}
	defer tape.destroy(&doc)
	if len(doc.nodes) == 0 || doc.nodes[tape.ROOT].kind != .Object {
		return {}, false
	}

	Field_Bit :: enum u8 {
		Route,
		Framing,
		Parallel,
		Hint,
		Demand_Kind,
		Format,
	}
	res: Plan_Pin
	seen: bit_set[Field_Bit; u8]
	ok_parse := false
	defer if !ok_parse {
		destroy_plan_pin(&res, allocator)
	}

	read_str :: proc(doc: ^tape.Document, v: tape.Node_Index, allocator: runtime.Allocator) -> (string, bool) {
		node := doc.nodes[v]
		if node.kind != .String {
			return "", false
		}
		return tape.node_text_read(doc.format, doc.src, node, allocator)
	}

	end := tape.node_after(&doc, tape.ROOT)
	kbuf: [32]u8
	for k := tape.ROOT + 1; k < end; k = tape.node_after(&doc, k + 1) {
		v := k + 1
		key, kok := tape.node_text(&doc, k, kbuf[:])
		if !kok {
			return {}, false
		}
		switch key {
		case "route":
			if .Route in seen { return {}, false }
			res.route = read_str(&doc, v, allocator) or_return
			seen += {.Route}
		case "framing":
			if .Framing in seen { return {}, false }
			res.framing = read_str(&doc, v, allocator) or_return
			seen += {.Framing}
		case "parallel":
			if .Parallel in seen { return {}, false }
			vk := doc.nodes[v].kind
			if vk != .True && vk != .False { return {}, false }
			res.parallel = vk == .True
			seen += {.Parallel}
		case "hint":
			if .Hint in seen { return {}, false }
			res.hint = read_str(&doc, v, allocator) or_return
			seen += {.Hint}
		case "demand_kind":
			if .Demand_Kind in seen { return {}, false }
			res.demand_kind = read_str(&doc, v, allocator) or_return
			seen += {.Demand_Kind}
		case "format":
			if .Format in seen { return {}, false }
			res.format = read_str(&doc, v, allocator) or_return
			seen += {.Format}
		case:
			return {}, false
		}
	}

	if seen != {.Route, .Framing, .Parallel, .Hint, .Demand_Kind, .Format} {
		return {}, false
	}
	ok_parse = true
	return res, true
}

// Compares `expected` against `actual`. Returns `true` when every pinned field matches; otherwise writes a
// concise human-readable diff (`expected route ..., got ...`) into `diff_out` (when non-nil) and returns `false`.
@(require_results)
compare_plan_pin :: proc(expected, actual: Plan_Pin, diff_out: ^strings.Builder = nil) -> bool {
	matched := true
	check_str :: proc(b: ^strings.Builder, matched: ^bool, field, exp, got: string) {
		if exp == got {
			return
		}
		if b != nil {
			if !matched^ {
				strings.write_string(b, "; ")
			}
			fmt.sbprintf(b, "expected %s %s, got %s", field, exp, got)
		}
		matched^ = false
	}
	check_bool :: proc(b: ^strings.Builder, matched: ^bool, field: string, exp, got: bool) {
		if exp == got {
			return
		}
		if b != nil {
			if !matched^ {
				strings.write_string(b, "; ")
			}
			fmt.sbprintf(b, "expected %s %s, got %s", field, "true" if exp else "false", "true" if got else "false")
		}
		matched^ = false
	}
	check_str(diff_out, &matched, "route", expected.route, actual.route)
	check_str(diff_out, &matched, "framing", expected.framing, actual.framing)
	check_bool(diff_out, &matched, "parallel", expected.parallel, actual.parallel)
	check_str(diff_out, &matched, "hint", expected.hint, actual.hint)
	check_str(diff_out, &matched, "demand_kind", expected.demand_kind, actual.demand_kind)
	check_str(diff_out, &matched, "format", expected.format, actual.format)
	return matched
}
