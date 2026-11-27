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
	plan.sources[.Main] = collect_demand(nil, prog.root.segments, .Whole, scratch, prog.backing) or_return
	extract_hints(prog, &plan, scratch, prog.backing) or_return
	prog.plan = plan
	ok = true
	return nil
}

// Collects `query.Source_Demand` for optional `@`-relative `pred` combined with `segs`.
@(private = "file")
collect_demand :: proc(pred: ^Expr, segs: []Segment, end_grain: tape.Grain, scratch, out_alloc: runtime.Allocator) -> (res: query.Source_Demand, err: runtime.Allocator_Error) {
	c := Demand_Collector {
		scratch   = scratch,
		paths     = make([dynamic]query.Demand_Path, 0, 16, scratch) or_return,
		seg_work  = make([dynamic]Seg_Work, 0, 16, scratch) or_return,
		expr_work = make([dynamic]Expr_Work, 0, 16, scratch) or_return,
	}
	if pred != nil {
		push_expr_work(&c, {expr = pred, need_grain = .Exists})
	}
	push_seg_work(&c, {segs = segs, end_grain = end_grain})
	for !c.whole && c.err == nil && (len(c.seg_work) > 0 || len(c.expr_work) > 0) {
		if len(c.seg_work) > 0 {
			process_seg_work(&c, pop(&c.seg_work))
		} else {
			process_expr_work(&c, pop(&c.expr_work))
		}
	}
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
	if c.err == nil && !c.whole {
		if _, err := append(&c.seg_work, w); err != nil {
			c.err = err
		}
	}
}

@(private = "file")
push_expr_work :: #force_inline proc(c: ^Demand_Collector, w: Expr_Work) {
	if c.err == nil && !c.whole {
		if _, err := append(&c.expr_work, w); err != nil {
			c.err = err
		}
	}
}

@(private = "file")
emit_path :: proc(c: ^Demand_Collector, steps: []tape.Step, grain: tape.Grain) {
	if c.whole || c.err != nil {
		return
	}
	if len(steps) == 0 && grain == .Whole {
		c.whole, c.whole_reason = true, .Identity
		return
	}
	if len(c.paths) >= MAX_PLAN_RAW_PATHS {
		c.whole, c.whole_reason = true, .Too_Wide
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
		c.whole, c.whole_reason = true, .Analysis_Cap
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
fits_i32 :: #force_inline proc "contextless" (v: i64) -> bool {
	return v >= i64(min(i32)) && v <= i64(max(i32))
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
		if !w.root_only {
			if len(w.prefix) == 0 {
				c.whole, c.whole_reason = true, .Whole_Op
				return
			}
			emit_path(c, w.prefix, .Whole)
		}
		for s in w.segs[w.seg_idx:] {
			for sel in s.selectors {
				if sel.kind == .Filter && sel.filter != nil {
					push_expr_work(c, {expr = sel.filter, need_grain = .Exists, root_only = true})
				}
			}
		}
		return
	}

	for sel in seg.selectors {
		if c.whole || c.err != nil {
			return
		}
		if sel.kind == .Slice && sel.has_step && sel.step == 0 {
			if !w.root_only {
				emit_path(c, w.prefix, .Exists)
			}
			continue
		}
		if w.root_only {
			if sel.kind == .Filter && sel.filter != nil {
				push_expr_work(c, {expr = sel.filter, need_grain = .Exists, root_only = true})
			}
			push_seg_work(c, {segs = w.segs, seg_idx = w.seg_idx + 1, root_only = true})
			continue
		}
		step: tape.Step = tape.All{}
		switch sel.kind {
		case .Name:
			step = tape.Name(sel.name)
		case .Index:
			if sel.index < 0 {
				emit_path(c, w.prefix, .Keys)
			}
			if fits_i32(sel.index) {
				step = tape.Index(int(sel.index))
			}
		case .Wildcard, .Filter:
		case .Slice:
			emit_path(c, w.prefix, .Keys)
			step_val := sel.step if sel.has_step else i64(1)
			if step_val > 0 && (!sel.has_start || fits_i32(sel.start)) && (!sel.has_end || fits_i32(sel.end)) {
				step = tape.Slice{lo = i32(sel.start) if sel.has_start else 0, hi = i32(sel.end) if sel.has_end else nil}
			}
		}
		next_p, ok := append_step(c, w.prefix, step)
		if !ok {
			return
		}
		if sel.kind == .Filter && sel.filter != nil {
			push_expr_work(c, {expr = sel.filter, at_prefix = next_p, need_grain = .Exists})
		}
		push_seg_work(c, {segs = w.segs, seg_idx = w.seg_idx + 1, prefix = next_p, end_grain = w.end_grain})
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
	case .Or, .And:
		push_expr_work(c, {expr = e.a, at_prefix = ew.at_prefix, need_grain = .Exists, root_only = ew.root_only})
		push_expr_work(c, {expr = e.b, at_prefix = ew.at_prefix, need_grain = .Exists, root_only = ew.root_only})
	case .Not, .Paren:
		push_expr_work(c, {expr = e.a, at_prefix = ew.at_prefix, need_grain = .Exists, root_only = ew.root_only})
	case .Compare:
		g := tape.Grain.Whole if (e.op != .Lt && e.op != .Gt && e.a.kind != .Literal && e.b.kind != .Literal) else .Exists
		push_expr_work(c, {expr = e.a, at_prefix = ew.at_prefix, need_grain = g, root_only = ew.root_only})
		push_expr_work(c, {expr = e.b, at_prefix = ew.at_prefix, need_grain = g, root_only = ew.root_only})
	case .Query:
		is_root := e.query.kind == .Root
		push_seg_work(c, {
			segs      = e.query.segments,
			prefix    = nil if (is_root || ew.root_only) else ew.at_prefix,
			end_grain = ew.need_grain,
			root_only = !is_root && ew.root_only,
		})
	case .Func:
		switch e.func {
		case .Length:
			push_expr_work(c, {expr = e.args[0], at_prefix = ew.at_prefix, need_grain = .Keys, root_only = ew.root_only})
		case .Count:
			push_expr_work(c, {expr = e.args[0], at_prefix = ew.at_prefix, need_grain = .Exists, root_only = ew.root_only})
		case .Match, .Search:
			push_expr_work(c, {expr = e.args[0], at_prefix = ew.at_prefix, need_grain = .Exists, root_only = ew.root_only})
			push_expr_work(c, {expr = e.args[1], at_prefix = ew.at_prefix, need_grain = .Exists, root_only = ew.root_only})
		case .Value:
			push_expr_work(c, {expr = e.args[0], at_prefix = ew.at_prefix, need_grain = ew.need_grain, root_only = ew.root_only})
		}
	}
}

// ---- Plan Hints (Hint 1 Split, Hint 2 Projection) ----

@(private = "file")
static_selector_step :: proc "contextless" (sel: Selector) -> (tape.Step, bool) {
	if sel.kind == .Name {
		return tape.Name(sel.name), true
	}
	if sel.kind == .Index && fits_i32(sel.index) {
		return tape.Index(int(sel.index)), true
	}
	return {}, false
}

@(private = "file")
extract_hints :: proc(prog: ^Program, plan: ^query.Plan, scratch, out_alloc: runtime.Allocator) -> runtime.Allocator_Error {
	segs := prog.root.segments
	if len(segs) == 0 {
		return nil
	}
	prefix := make([dynamic]tape.Step, 0, len(segs), scratch) or_return
	split_idx := -1
	for seg, i in segs {
		if seg.kind == .Child && len(seg.selectors) == 1 {
			if st, ok := static_selector_step(seg.selectors[0]); ok {
				append(&prefix, st) or_return
				continue
			}
		}
		split_idx = i
		break
	}

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
		sels := segs[split_idx].selectors
		all_static := true
		for sel in sels {
			if _, ok := static_selector_step(sel); !ok {
				all_static = false
				break
			}
		}
		if all_static {
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
				p[len(prefix)], _ = static_selector_step(sel)
				fields[k] = {path = p}
			}
			plan.hints.projection = {shape = .Stream, fields = fields}
			return nil
		}
	}

	if segs[split_idx].kind != .Child || len(segs[split_idx].selectors) != 1 {
		return nil
	}
	split_sel := segs[split_idx].selectors[0]
	is_filter := split_sel.kind == .Filter && split_sel.filter != nil
	if split_sel.kind != .Wildcard && !is_filter {
		return nil
	}
	rest := segs[split_idx + 1:]
	pred := split_sel.filter if is_filter else nil
	if uses_root_ref(rest, pred, scratch) or_return {
		return nil
	}
	each_d := query.whole_demand(false, .Identity) if len(rest) == 0 else (collect_demand(pred, rest, .Whole, scratch, out_alloc) or_return)
	cloned_prefix, cerr := slice.clone(prefix[:], out_alloc)
	if cerr != nil {
		query.destroy_source_demand(&each_d)
		return cerr
	}
	plan.hints.split = {kind = .Stream, prefix = cloned_prefix, each_demand = each_d, has_each = is_filter || len(rest) > 0}
	return nil
}

@(private = "file")
uses_root_ref :: proc(segs: []Segment, expr: ^Expr, scratch: runtime.Allocator) -> (res: bool, err: runtime.Allocator_Error) {
	sstack := make([dynamic][]Segment, 0, 8, scratch) or_return
	estack := make([dynamic]^Expr, 0, 8, scratch) or_return
	if len(segs) > 0 {
		append(&sstack, segs) or_return
	}
	if expr != nil {
		append(&estack, expr) or_return
	}
	for len(sstack) > 0 || len(estack) > 0 {
		if len(sstack) > 0 {
			for seg in pop(&sstack) {
				for sel in seg.selectors {
					if sel.kind == .Filter && sel.filter != nil {
						append(&estack, sel.filter) or_return
					}
				}
			}
			continue
		}
		e := pop(&estack)
		if e == nil {
			continue
		}
		switch e.kind {
		case .Literal:
		case .Query:
			if e.query.kind == .Root {
				return true, nil
			}
			append(&sstack, e.query.segments) or_return
		case .Or, .And, .Compare:
			append(&estack, e.a) or_return
			append(&estack, e.b) or_return
		case .Not, .Paren:
			append(&estack, e.a) or_return
		case .Func:
			for arg in e.args {
				append(&estack, arg) or_return
			}
		}
	}
	return false, nil
}
