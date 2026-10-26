package json

// The walk over a request: its outputs reset, its queries built, the scanner run, its answers settled.

import "base:runtime"
import "scan/walk"
import scan_pkg "scan"

// The most queries one scan hands the walk: every walk kind once but `.Unique`, which answers none, plus
// the repeatable `.Path`.
@(private = "file")
MAX_WALK_QUERIES :: len(scan_pkg.Walk_Kind) - 1 + walk.MAX_PATH_QUERIES

@(private = "file")
duplicates_resolution :: proc(d: Duplicates) -> scan_pkg.Resolution {
	switch d {
	case .Default, .Last: return .Last
	case .First: return .First
	case .All:   return .All
	// Every repeat refuses, so the first occurrence is the answer whenever there is one.
	case .Refuse: return .First
	}
	return .Last
}

// Fill `sink` with `req`'s storage for the arrays of `$K`: array headers copied in, so `sink_store` must
// follow the walk. The rest of the sink is left unset, and the walk never reads it. An out-parameter: a
// sink returned by value is zeroed whole.
@(private = "file")
sink_of :: #force_inline proc(req: ^Request($KINDS), sink: ^walk.Scan_Query_Sink, $K: bit_set[scan_pkg.Walk_Kind]) {
	when .Path in K {
		sink.paths = req.answers
		sink.paths_retracted = 0
		sink.paths_unresolved = 0
	}
	when .Nodes in K { sink.nodes = req.doc.rows }
	when .Dom in K { sink.value_bytes = req.doc.values }
}

@(private = "file")
sink_store :: #force_inline proc(req: ^Request($KINDS), sink: walk.Scan_Query_Sink, $K: bit_set[scan_pkg.Walk_Kind]) {
	when .Path in K { req.answers = sink.paths }
	when .Nodes in K { req.doc.rows = sink.nodes }
	when .Dom in K {
		// `req` still holds the header the scan started from.
		values := sink.value_bytes
		walk.value_bytes_trim(&values, cap(req.doc.values))
		req.doc.values = values
	}
}

// Empty the arrays of `$K` for a rescan, keeping capacity and the allocator each is bound to. The arenas
// restart from their first block.
@(private = "file")
output_reset :: #force_inline proc(req: ^Request($KINDS), $K: bit_set[scan_pkg.Walk_Kind]) {
	when .Path in K { clear(&req.answers) }
	when .Nodes in K {
		doc := &req.doc
		clear(&doc.rows)
		clear(&doc.keys)
		clear(&doc.strings)
		clear(&doc.members)
		clear(&doc.member_at)
		clear(&doc.facts)
		walk.name_arena_reset(&doc.arena)
	}
	when .Dom in K { clear(&req.doc.values) }
}

// The walk of `src` that builds `req.doc.rows`, with the route's plan cleared (the caller restores it if the
// request keeps it): the tape and wildcard routes answer from the rows.
@(private)
scan_rows :: proc(src: []byte, req: ^Request($KINDS), alloc: runtime.Allocator) -> scan_pkg.Walk_Fault {
	req.state.route.matcher, req.state.route.n_auto, req.state.route.gate.gated = .None, 0, 0
	// Sized to the document's usual density, before the scan seeds it larger (`seed_row_cap`).
	walk.adopt_allocator(&req.doc.rows, alloc)
	_ = walk.edge_reserve(&req.doc.rows, len(src) / walk.SEEDED_ROW_BYTES)
	return scan_walk(src, req, {.Nodes}, alloc)
}

// The walk over `req` specialized for `$WALK`. It returns the walk's own fault and leaves the result on
// `req`. The steps below are inlined: one specialization is one body.
@(private)
scan_walk :: proc(src: []byte, req: ^Request($KINDS), $WALK: bit_set[scan_pkg.Walk_Kind], alloc: runtime.Allocator) -> (fault: scan_pkg.Walk_Fault) {
	plan := &req.state.route
	// The router gates only a demand-only walk. A gate is a walk of its own, so no other walk compiles one.
	when .Demand in WALK && .Path not_in WALK && .Gate not_in WALK {
		if plan.gate.gated != 0 {
			return #force_no_inline scan_walk(src, req, WALK + {.Gate}, alloc)
		}
	}
	// The arrays the walk touches: a path or demand writes `answers`.
	K :: WALK | {.Path} when .Demand in WALK else WALK
	output_reset(req, K)
	// The matcher writes its rows, and the slots' answers, into `answers`. `outputs_fault` agreed its
	// allocator.
	if plan.matcher != .None {
		walk.adopt_allocator(&req.answers, alloc)
	}

	sink: walk.Scan_Query_Sink = ---
	sink_of(req, &sink, K)
	queries: [MAX_WALK_QUERIES]scan_pkg.Scan_Query = ---
	nq := walk_queries(req, &sink, &queries, WALK, alloc)
	facts := walk_facts(req, WALK, alloc)
	err: Maybe(Error)
	err, fault = walk_run(src, req, queries[:nq], walk_strictness(req), WALK, facts)
	req.state.verdict = err
	when .Path in K {
		req.state.route.unresolved = sink.paths_unresolved > 0
	}
	sink_store(req, sink, K)
	req.doc.src = src
	req.doc.dialect = req.dialect
	req.doc.deep = req.limits.max_depth > MAX_DEPTH
	walk_attach_facts(req, src, facts, err, &fault)
	walk_answers(req, &sink, WALK, err, &fault)
	return fault
}

// Fill `queries` with what `$WALK` asks of the scanner, and return how many: each automaton path under its
// own index in `req.paths`, then the rows, the decoded values, and the demand matcher.
@(private = "file")
walk_queries :: #force_inline proc(req: ^Request($KINDS), sink: ^walk.Scan_Query_Sink, queries: ^[MAX_WALK_QUERIES]scan_pkg.Scan_Query, $WALK: bit_set[scan_pkg.Walk_Kind], alloc: runtime.Allocator) -> (nq: int) {
	plan := &req.state.route
	for pi in plan.auto[:plan.n_auto] {
		queries[nq] = scan_pkg.Scan_Query{kind = .Path, allocator = alloc, sink = sink, path = req.paths[pi], tag = pi}
		nq += 1
	}
	when .Nodes in WALK {
		queries[nq] = scan_pkg.Scan_Query{kind = .Nodes, allocator = alloc, sink = sink}
		nq += 1
		when .Dom in WALK {
			queries[nq] = scan_pkg.Scan_Query{kind = .Dom, allocator = alloc, sink = sink}
			nq += 1
		}
	}
	when .Demand in WALK {
		store := route_store(plan, plan.n_keys)
		spec := walk.Demand_Spec{keys = store.keys, depth = plan.depth}
		when .Gate in WALK {
			spec.gate = &plan.gate
		}
		if plan.matcher == .Slots {
			spec.out = store.fields
		} else {
			spec.rows = &sink.paths
			spec.row_keys = store.row_keys
		}
		queries[nq] = scan_pkg.Scan_Query{kind = .Demand, allocator = alloc, sink = sink, demand = spec}
		nq += 1
	}
	return
}

// Where a dialect document's comments go: `req.doc.facts`, nil for a JSON walk.
@(private = "file")
walk_facts :: #force_inline proc(req: ^Request($KINDS), $WALK: bit_set[scan_pkg.Walk_Kind], alloc: runtime.Allocator) -> ^[dynamic]Fact {
	when .Nodes in WALK {
		if !scan_pkg.plain_json(req.dialect) {
			walk.adopt_allocator(&req.doc.facts, alloc)
			return &req.doc.facts
		}
	}
	return nil
}

// An empty path's answer is the whole root, which settles only with the walk: `.Lazy` would only skip
// bytes of an answer it hands out, so it reads as `.Strict`.
@(private = "file")
walk_strictness :: #force_inline proc(req: ^Request($KINDS)) -> Strictness {
	when .Path in KINDS {
		if req.strictness == .Lazy {
			for p in req.paths {
				if len(p.steps) == 0 {
					return .Strict
				}
			}
		}
	}
	return req.strictness
}

// The scanner entry the limits and dialect pick.
@(private = "file")
walk_run :: #force_inline proc(src: []byte, req: ^Request($KINDS), queries: []scan_pkg.Scan_Query, strictness: Strictness, $WALK: bit_set[scan_pkg.Walk_Kind], facts: ^[dynamic]Fact) -> (err: Maybe(Error), fault: scan_pkg.Walk_Fault) {
	if req.limits.max_depth > MAX_DEPTH {
		return scan_pkg.scan_queries_deep(
			src, queries, strictness, req.limits, WALK, &req.coverage, duplicates_resolution(req.duplicates), req.dialect, facts,
		)
	}
	// A dialect walk has no demand matcher (`automaton_forced`), so a demand walk compiles no dialect.
	when .Demand not_in WALK {
		switch req.dialect {
		case .Json:
		case .Jsonc:
			return scan_pkg.scan_queries_dialect(src, queries, req.limits, WALK, &req.coverage, duplicates_resolution(req.duplicates), facts, .Jsonc)
		case .Json5:
			return scan_pkg.scan_queries_dialect(src, queries, req.limits, WALK, &req.coverage, duplicates_resolution(req.duplicates), facts, .Json5)
		}
	}
	return scan_pkg.scan_queries(
		src, queries, strictness, req.limits, WALK,
		&req.stop, &req.coverage, duplicates_resolution(req.duplicates), req.state.route.kept,
	)
}

// Attach a dialect walk's comments to its rows.
@(private = "file")
walk_attach_facts :: #force_inline proc(req: ^Request($KINDS), src: []byte, facts: ^[dynamic]Fact, err: Maybe(Error), fault: ^scan_pkg.Walk_Fault) {
	if facts == nil {
		return
	}
	attached := err == nil && scan_pkg.jsonc_attach(req.doc.rows[:], src, facts[:])
	if err == nil && !attached {
		fault.oom = true
	}
	if !attached {
		// Unattached, they would read as nothing's.
		clear(facts)
	}
}

// The answers the matcher and the sweep owe after the walk: the slots' and names' misses, then the pass that
// drops retracted rows, cuts limits and fills nodes.
@(private = "file")
walk_answers :: #force_inline proc(req: ^Request($KINDS), sink: ^walk.Scan_Query_Sink, $WALK: bit_set[scan_pkg.Walk_Kind], err: Maybe(Error), fault: ^scan_pkg.Walk_Fault) {
	plan := &req.state.route
	if plan.matcher == .Slots {
		// The automaton owes a miss only to a walk that reached the end.
		reached_end := req.stop == nil
		if e, faulted := err.?; faulted && e.kind != .Trailing {
			reached_end = false
		}
		fault.oom ||= !route_slots(&req.answers, plan, reached_end)
	} else if plan.matcher == .Names {
		fault.oom ||= !route_missing(&req.answers, plan, req.stop, err)
	}
	// `.Last` repeats retract rows the sweep drops: a gate's, or a wildcard path's.
	retracted := false
	when .Gate in WALK {
		retracted = plan.gate.retracted
	}
	when .Path in WALK {
		retracted = sink.paths_retracted > 0
	}
	if plan.any_limit || .Nodes in WALK || retracted {
		finish_answers(&req.answers, req.doc.rows[:], plan, req.paths, .Nodes in WALK)
	}
}
