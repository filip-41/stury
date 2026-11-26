package jsonpath

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/query"

// Query planning for compiled RFC 9535 JSONPath programs:
// 1. Exact `query.Demand_Path` extraction into `prog.plan.sources[.Main]`.
// 2. Hint 1 (`Per_Element_Split`) for `$[*].rest`, `$.prefix[*].rest`, and `$.prefix[?pred].rest`.
// 3. Hint 2 (`Projection_Template`) for static single-path and multi-selector projections.
//
// Note on Hint 3 (`Conditional_Whole`): per `lib/query/plan.odin`, `Conditional_Whole` describes a
// root-level `select(P)` whose `pred_demand` is rooted at `.` (e.g. NDJSON record filtering). In
// RFC 9535 JSONPath, `[?pred]` always filters children of a container rather than the root document
// itself, so element-level filters are represented exclusively via `hints.split` (`Per_Element_Split`)
// and `hints.conditional.active` is intentionally left `false`.
//
// Zero native recursion: AST walks use explicit heap worklists. All allocations propagate
// `runtime.Allocator_Error` so `compile` fails cleanly with `.Memory` on OOM.

// Formats `p` as a human-readable `--explain` string in `allocator`.
explain_plan :: proc(p: ^query.Plan, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	query.format_plan(&b, p)
	return strings.to_string(b)
}

@(private = "file")
MAX_PLAN_DEPTH :: 32

@(private = "file")
MAX_PLAN_RAW_PATHS :: query.MAX_DEMAND_PATHS * 4

@(private = "file")
Seg_Work :: struct {
	segs:      []Segment,
	seg_idx:   int,
	prefix:    []tape.Step,
	end_grain: tape.Grain,
	// When true, collect only root `$` demands inside filters (current subtree is already demanded `.Whole`).
	root_only: bool,
}

@(private = "file")
Expr_Work :: struct {
	expr:       ^Expr,
	at_prefix:  []tape.Step,
	need_grain: tape.Grain,
	root_only:  bool,
}

@(private = "file")
Demand_Collector :: struct {
	scratch:      runtime.Allocator,
	paths:        [dynamic]query.Demand_Path,
	whole:        bool,
	whole_reason: query.Whole_Reason,
	err:          runtime.Allocator_Error,
	seg_work:     [dynamic]Seg_Work,
	expr_work:    [dynamic]Expr_Work,
}

@(private)
build_plan :: proc(prog: ^Program) -> runtime.Allocator_Error {
	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, prog.backing, prog.backing, block_size = 4096, out_band_size = 1024)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)

	plan := query.Plan{allocator = prog.backing}
	ok := false
	defer if !ok {
		query.destroy_plan(&plan)
	}

	plan.sources[.Main] = collect_query_demand(prog.root.segments, nil, .Whole, scratch, prog.backing) or_return
	extract_hints(prog, &plan, scratch, prog.backing) or_return
	prog.plan = plan
	ok = true
	return nil
}

@(private = "file")
collector_init :: proc(c: ^Demand_Collector, scratch: runtime.Allocator) -> runtime.Allocator_Error {
	c.scratch = scratch
	c.paths = make([dynamic]query.Demand_Path, 0, 16, scratch) or_return
	c.seg_work = make([dynamic]Seg_Work, 0, 16, scratch) or_return
	c.expr_work = make([dynamic]Expr_Work, 0, 16, scratch) or_return
	return nil
}

// Collects the `query.Source_Demand` for evaluating `segs` starting at `base_prefix` with terminal `end_grain`.
@(private = "file")
collect_query_demand :: proc(
	segs: []Segment,
	base_prefix: []tape.Step,
	end_grain: tape.Grain,
	scratch, out_alloc: runtime.Allocator,
) -> (res: query.Source_Demand, err: runtime.Allocator_Error) {
	c: Demand_Collector
	collector_init(&c, scratch) or_return
	push_seg_work(&c, Seg_Work{segs = segs, seg_idx = 0, prefix = base_prefix, end_grain = end_grain})
	drain_collector(&c)
	return finalize_collector(&c, out_alloc)
}

// Collects `@`-relative demand for `pred` (when non-nil) combined with trailing `rest_segs` on each element.
@(private = "file")
collect_each_demand :: proc(
	pred: ^Expr,
	rest_segs: []Segment,
	scratch, out_alloc: runtime.Allocator,
) -> (res: query.Source_Demand, err: runtime.Allocator_Error) {
	c: Demand_Collector
	collector_init(&c, scratch) or_return
	if pred != nil {
		push_expr_work(&c, Expr_Work{expr = pred, at_prefix = nil, need_grain = .Exists})
	}
	push_seg_work(&c, Seg_Work{segs = rest_segs, seg_idx = 0, prefix = nil, end_grain = .Whole})
	drain_collector(&c)
	return finalize_collector(&c, out_alloc)
}

@(private = "file")
finalize_collector :: proc(c: ^Demand_Collector, out_alloc: runtime.Allocator) -> (query.Source_Demand, runtime.Allocator_Error) {
	if c.err != nil {
		return {}, c.err
	}
	if c.whole {
		return query.whole_demand(false, c.whole_reason if c.whole_reason != .None else .Identity), nil
	}
	return query.finalize_source_demand(c.paths[:], false, out_alloc), nil
}

@(private = "file")
push_seg_work :: #force_inline proc(c: ^Demand_Collector, w: Seg_Work) {
	if c.err != nil || c.whole {
		return
	}
	if _, err := append(&c.seg_work, w); err != nil {
		c.err = err
	}
}

@(private = "file")
push_expr_work :: #force_inline proc(c: ^Demand_Collector, w: Expr_Work) {
	if c.err != nil || c.whole {
		return
	}
	if _, err := append(&c.expr_work, w); err != nil {
		c.err = err
	}
}

@(private = "file")
emit_path :: proc(c: ^Demand_Collector, steps: []tape.Step, grain: tape.Grain) {
	if c.whole || c.err != nil {
		return
	}
	if len(steps) == 0 && grain == .Whole {
		c.whole = true
		c.whole_reason = .Identity
		return
	}
	if len(c.paths) >= MAX_PLAN_RAW_PATHS {
		c.whole = true
		c.whole_reason = .Too_Wide
		return
	}
	if _, err := append(&c.paths, query.Demand_Path{steps = steps, grain = grain}); err != nil {
		c.err = err
	}
}

@(private = "file")
append_step :: proc(c: ^Demand_Collector, prefix: []tape.Step, step: tape.Step) -> ([]tape.Step, bool) {
	if c.err != nil {
		return nil, false
	}
	if len(prefix) + 1 > MAX_PLAN_DEPTH {
		c.whole = true
		c.whole_reason = .Analysis_Cap
		return nil, false
	}
	out, err := make([]tape.Step, len(prefix) + 1, c.scratch)
	if err != nil {
		c.err = err
		return nil, false
	}
	copy(out, prefix)
	out[len(prefix)] = step
	return out, true
}

@(private = "file")
drain_collector :: proc(c: ^Demand_Collector) {
	for !c.whole && c.err == nil && (len(c.seg_work) > 0 || len(c.expr_work) > 0) {
		if len(c.seg_work) > 0 {
			w := pop(&c.seg_work)
			process_seg_work(c, w)
			continue
		}
		ew := pop(&c.expr_work)
		process_expr_work(c, ew)
	}
}

@(private = "file")
process_seg_work :: proc(c: ^Demand_Collector, w: Seg_Work) {
	if w.seg_idx >= len(w.segs) {
		if !w.root_only {
			emit_path(c, w.prefix, w.end_grain)
		}
		return
	}
	seg := w.segs[w.seg_idx]
	if seg.kind == .Descendant {
		// Descendant traversal walks every container under `w.prefix` with `cursor_open`, so `w.prefix`
		// must be kept `.Whole` (skips untouched sibling subtrees when `len(w.prefix) > 0`).
		if !w.root_only {
			if len(w.prefix) == 0 {
				c.whole = true
				c.whole_reason = .Whole_Op
				return
			}
			emit_path(c, w.prefix, .Whole)
		}
		// Still scan filter expressions in this and later segments for root `$` references.
		for k in w.seg_idx ..< len(w.segs) {
			for sel in w.segs[k].selectors {
				if sel.kind == .Filter && sel.filter != nil {
					push_expr_work(c, Expr_Work{expr = sel.filter, at_prefix = nil, need_grain = .Exists, root_only = true})
				}
			}
		}
		return
	}

	// Child segment.
	for sel in seg.selectors {
		if c.whole || c.err != nil {
			return
		}
		switch sel.kind {
		case .Name:
			if w.root_only {
				push_seg_work(c, Seg_Work{segs = w.segs, seg_idx = w.seg_idx + 1, root_only = true})
				continue
			}
			next_p, ok := append_step(c, w.prefix, tape.Name(sel.name))
			if !ok {
				return
			}
			push_seg_work(c, Seg_Work{segs = w.segs, seg_idx = w.seg_idx + 1, prefix = next_p, end_grain = w.end_grain})

		case .Index:
			if w.root_only {
				push_seg_work(c, Seg_Work{segs = w.segs, seg_idx = w.seg_idx + 1, root_only = true})
				continue
			}
			// Negative index needs array length when `want_paths` computes normalized index `len + i`.
			if sel.index < 0 {
				emit_path(c, w.prefix, .Keys)
			}
			step: tape.Step
			if sel.index >= i64(min(i32)) && sel.index <= i64(max(i32)) {
				step = tape.Index(int(sel.index))
			} else {
				step = tape.All{}
			}
			next_p, ok := append_step(c, w.prefix, step)
			if !ok {
				return
			}
			push_seg_work(c, Seg_Work{segs = w.segs, seg_idx = w.seg_idx + 1, prefix = next_p, end_grain = w.end_grain})

		case .Wildcard:
			if w.root_only {
				push_seg_work(c, Seg_Work{segs = w.segs, seg_idx = w.seg_idx + 1, root_only = true})
				continue
			}
			next_p, ok := append_step(c, w.prefix, tape.All{})
			if !ok {
				return
			}
			push_seg_work(c, Seg_Work{segs = w.segs, seg_idx = w.seg_idx + 1, prefix = next_p, end_grain = w.end_grain})

		case .Slice:
			if sel.has_step && sel.step == 0 {
				// Step 0 selects nothing, but reaching this segment reads `w.prefix` (so keep `.Exists`).
				if !w.root_only {
					emit_path(c, w.prefix, .Exists)
				}
				continue
			}
			if w.root_only {
				push_seg_work(c, Seg_Work{segs = w.segs, seg_idx = w.seg_idx + 1, root_only = true})
				continue
			}
			// Slice computes RFC 9535 Bounds from container length -> parent needs `.Keys`.
			emit_path(c, w.prefix, .Keys)
			step: tape.Step = tape.All{}
			step_val := sel.step if sel.has_step else i64(1)
			if step_val > 0 {
				start_fits := !sel.has_start || (sel.start >= i64(min(i32)) && sel.start <= i64(max(i32)))
				end_fits := !sel.has_end || (sel.end >= i64(min(i32)) && sel.end <= i64(max(i32)))
				if start_fits && end_fits {
					lo := i32(sel.start) if sel.has_start else i32(0)
					hi: Maybe(i32) = i32(sel.end) if sel.has_end else nil
					step = tape.Slice{lo = lo, hi = hi}
				}
			}
			next_p, ok := append_step(c, w.prefix, step)
			if !ok {
				return
			}
			push_seg_work(c, Seg_Work{segs = w.segs, seg_idx = w.seg_idx + 1, prefix = next_p, end_grain = w.end_grain})

		case .Filter:
			if w.root_only {
				if sel.filter != nil {
					push_expr_work(c, Expr_Work{expr = sel.filter, at_prefix = nil, need_grain = .Exists, root_only = true})
				}
				push_seg_work(c, Seg_Work{segs = w.segs, seg_idx = w.seg_idx + 1, root_only = true})
				continue
			}
			elem_p, ok := append_step(c, w.prefix, tape.All{})
			if !ok {
				return
			}
			if sel.filter != nil {
				push_expr_work(c, Expr_Work{expr = sel.filter, at_prefix = elem_p, need_grain = .Exists, root_only = false})
			}
			push_seg_work(c, Seg_Work{segs = w.segs, seg_idx = w.seg_idx + 1, prefix = elem_p, end_grain = w.end_grain})
		}
	}
}

@(private = "file")
process_expr_work :: proc(c: ^Demand_Collector, ew: Expr_Work) {
	e := ew.expr
	if e == nil || c.err != nil {
		return
	}
	switch e.kind {
	case .Literal:
		// Literals demand nothing from the document.
	case .Or, .And:
		push_expr_work(c, Expr_Work{expr = e.a, at_prefix = ew.at_prefix, need_grain = .Exists, root_only = ew.root_only})
		push_expr_work(c, Expr_Work{expr = e.b, at_prefix = ew.at_prefix, need_grain = .Exists, root_only = ew.root_only})
	case .Not, .Paren:
		push_expr_work(c, Expr_Work{expr = e.a, at_prefix = ew.at_prefix, need_grain = .Exists, root_only = ew.root_only})
	case .Compare:
		// Strict `<` / `>` only compare numbers and strings (scalars are whole under `.Exists`).
		// `==` / `!=` / `<=` / `>=` compare containers recursively unless one side is a scalar literal.
		cmp_grain := tape.Grain.Exists
		if e.op != .Lt && e.op != .Gt {
			if e.a.kind != .Literal && e.b.kind != .Literal {
				cmp_grain = .Whole
			}
		}
		push_expr_work(c, Expr_Work{expr = e.a, at_prefix = ew.at_prefix, need_grain = cmp_grain, root_only = ew.root_only})
		push_expr_work(c, Expr_Work{expr = e.b, at_prefix = ew.at_prefix, need_grain = cmp_grain, root_only = ew.root_only})
	case .Query:
		if e.query.kind == .Root {
			push_seg_work(c, Seg_Work{
				segs      = e.query.segments,
				seg_idx   = 0,
				prefix    = nil,
				end_grain = ew.need_grain,
				root_only = false,
			})
		} else {
			if ew.root_only {
				// Current subtree is already `.Whole`, only chase nested `$` inside filters.
				push_seg_work(c, Seg_Work{
					segs      = e.query.segments,
					seg_idx   = 0,
					prefix    = nil,
					end_grain = ew.need_grain,
					root_only = true,
				})
			} else {
				push_seg_work(c, Seg_Work{
					segs      = e.query.segments,
					seg_idx   = 0,
					prefix    = ew.at_prefix,
					end_grain = ew.need_grain,
					root_only = false,
				})
			}
		}
	case .Func:
		switch e.func {
		case .Length:
			// `length` reads string bytes (whole under all grains) or container length (needs `.Keys`).
			push_expr_work(c, Expr_Work{expr = e.args[0], at_prefix = ew.at_prefix, need_grain = .Keys, root_only = ew.root_only})
		case .Count:
			// `count` only counts matching nodes without inspecting their contents.
			push_expr_work(c, Expr_Work{expr = e.args[0], at_prefix = ew.at_prefix, need_grain = .Exists, root_only = ew.root_only})
		case .Match, .Search:
			// `match` / `search` inspect only strings (scalars are whole under `.Exists`).
			push_expr_work(c, Expr_Work{expr = e.args[0], at_prefix = ew.at_prefix, need_grain = .Exists, root_only = ew.root_only})
			push_expr_work(c, Expr_Work{expr = e.args[1], at_prefix = ew.at_prefix, need_grain = .Exists, root_only = ew.root_only})
		case .Value:
			// `value` forwards whatever grain the consumer needs from the single node.
			push_expr_work(c, Expr_Work{expr = e.args[0], at_prefix = ew.at_prefix, need_grain = ew.need_grain, root_only = ew.root_only})
		}
	}
}

// ---- Plan Hints (Hint 1 Split, Hint 2 Projection) ----

@(private = "file")
extract_hints :: proc(prog: ^Program, plan: ^query.Plan, scratch, out_alloc: runtime.Allocator) -> runtime.Allocator_Error {
	segs := prog.root.segments
	if len(segs) == 0 {
		return nil
	}

	// Collect leading static single-step prefix (Child segments of single Name or safe-i32 Index).
	prefix := make([dynamic]tape.Step, 0, len(segs), scratch) or_return
	split_idx := -1
	for seg, i in segs {
		if seg.kind != .Child || len(seg.selectors) != 1 {
			split_idx = i
			break
		}
		sel := seg.selectors[0]
		if sel.kind == .Name {
			append(&prefix, tape.Name(sel.name)) or_return
			continue
		}
		if sel.kind == .Index && sel.index >= i64(min(i32)) && sel.index <= i64(max(i32)) {
			append(&prefix, tape.Index(int(sel.index))) or_return
			continue
		}
		split_idx = i
		break
	}

	// Hint 2: Projection_Template — static single path (`$.a.b[0].c`) or multi-selector (`$.a['x', 'y']`).
	if split_idx < 0 {
		fields := make([]query.Projection_Field, 1, out_alloc) or_return
		cloned_prefix, cerr := slice.clone(prefix[:], out_alloc)
		if cerr != nil {
			delete(fields, out_alloc)
			return cerr
		}
		fields[0] = {path = cloned_prefix}
		plan.hints.projection = {shape = .Single, fields = fields}
		return nil
	}
	if split_idx == len(segs) - 1 && segs[split_idx].kind == .Child && len(segs[split_idx].selectors) > 1 {
		all_static := true
		for sel in segs[split_idx].selectors {
			if sel.kind != .Name && !(sel.kind == .Index && sel.index >= i64(min(i32)) && sel.index <= i64(max(i32))) {
				all_static = false
				break
			}
		}
		if all_static {
			sels := segs[split_idx].selectors
			fields := make([]query.Projection_Field, len(sels), out_alloc) or_return
			for sel, k in sels {
				p, perr := make([]tape.Step, len(prefix) + 1, out_alloc)
				if perr != nil {
					for j in 0 ..< k {
						delete(fields[j].path, out_alloc)
					}
					delete(fields, out_alloc)
					return perr
				}
				copy(p, prefix[:])
				p[len(prefix)] = tape.Name(sel.name) if sel.kind == .Name else tape.Index(int(sel.index))
				fields[k] = {path = p}
			}
			plan.hints.projection = {shape = .Stream, fields = fields}
			return nil
		}
	}

	// Check if `segs[split_idx]` is a single Wildcard (`*`) or Filter (`?pred`).
	if segs[split_idx].kind != .Child || len(segs[split_idx].selectors) != 1 {
		return nil
	}
	split_sel := segs[split_idx].selectors[0]
	rest := segs[split_idx + 1:]

	if split_sel.kind == .Wildcard {
		// Hint 1: `$[*].rest` or `$.prefix[*].rest` without root `$` references in `rest`.
		uses_root := segments_use_root(rest, scratch) or_return
		if !uses_root {
			each_d: query.Source_Demand
			if len(rest) == 0 {
				each_d = query.whole_demand(false, .Identity)
			} else {
				each_d = collect_each_demand(nil, rest, scratch, out_alloc) or_return
			}
			cloned_prefix, cerr := slice.clone(prefix[:], out_alloc)
			if cerr != nil {
				query.destroy_source_demand(&each_d)
				return cerr
			}
			plan.hints.split = {
				kind        = .Stream,
				prefix      = cloned_prefix,
				each_demand = each_d,
				has_each    = len(rest) > 0,
			}
		}
		return nil
	}

	if split_sel.kind == .Filter && split_sel.filter != nil {
		pred_root := expr_uses_root(split_sel.filter, scratch) or_return
		rest_root := segments_use_root(rest, scratch) or_return
		if pred_root || rest_root {
			return nil
		}
		// Hint 1: `$.prefix[?pred].rest` (and `$[?pred]` / `$.prefix[?pred]`) is a per-element stream split.
		// `hints.conditional` is intentionally NOT set because RFC 9535 `[?pred]` filters container elements
		// rather than the root document itself (`lib/query/plan.odin` `Conditional_Whole` is root-level).
		each_d: query.Source_Demand
		if len(rest) == 0 {
			each_d = query.whole_demand(false, .Identity)
		} else {
			each_d = collect_each_demand(split_sel.filter, rest, scratch, out_alloc) or_return
		}
		cloned_prefix, cerr := slice.clone(prefix[:], out_alloc)
		if cerr != nil {
			query.destroy_source_demand(&each_d)
			return cerr
		}
		plan.hints.split = {
			kind        = .Stream,
			prefix      = cloned_prefix,
			each_demand = each_d,
			has_each    = true,
		}
	}
	return nil
}

// Iterative check whether any filter inside `segs` references root `$`.
@(private = "file")
segments_use_root :: proc(segs: []Segment, scratch: runtime.Allocator) -> (uses: bool, err: runtime.Allocator_Error) {
	sstack := make([dynamic][]Segment, 0, 8, scratch) or_return
	estack := make([dynamic]^Expr, 0, 8, scratch) or_return
	append(&sstack, segs) or_return
	return walk_for_root(&sstack, &estack)
}

@(private = "file")
expr_uses_root :: proc(expr: ^Expr, scratch: runtime.Allocator) -> (uses: bool, err: runtime.Allocator_Error) {
	sstack := make([dynamic][]Segment, 0, 8, scratch) or_return
	estack := make([dynamic]^Expr, 0, 8, scratch) or_return
	append(&estack, expr) or_return
	return walk_for_root(&sstack, &estack)
}

@(private = "file")
walk_for_root :: proc(sstack: ^[dynamic][]Segment, estack: ^[dynamic]^Expr) -> (uses: bool, err: runtime.Allocator_Error) {
	for len(sstack) > 0 || len(estack) > 0 {
		if len(sstack) > 0 {
			segs := pop(sstack)
			for seg in segs {
				for sel in seg.selectors {
					if sel.kind == .Filter && sel.filter != nil {
						append(estack, sel.filter) or_return
					}
				}
			}
			continue
		}
		e := pop(estack)
		if e == nil {
			continue
		}
		switch e.kind {
		case .Literal:
		case .Query:
			if e.query.kind == .Root {
				return true, nil
			}
			append(sstack, e.query.segments) or_return
		case .Or, .And, .Compare:
			append(estack, e.a) or_return
			append(estack, e.b) or_return
		case .Not, .Paren:
			append(estack, e.a) or_return
		case .Func:
			for arg in e.args {
				append(estack, arg) or_return
			}
		}
	}
	return false, nil
}
