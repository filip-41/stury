package walk

import "base:runtime"

// Resolve a request's query slice against the comptime key `$Q` into the walk's plumbing.
//
// `Request` shares one sink among every kind but `.Path`, which the wiring relies on. The slice is already
// known to be servable (the caller's pre-flight refuses the rest). The asserts restate that, and the run and
// step caps the path runs' storage depends on are refused here (the `Capacity` returned) before anything is
// wired. Two passes: check and bind, then wire. Adopting an allocator (see `Scan_Query.allocator`) writes to
// the output arrays, so it waits for a complete slice.
//
// `ctx` is an out-parameter: `Query_Ctx` is several kilobytes, and returning it by value would copy it
// at every `return` arm.
//
// `kept`, when not nil, is the resolution of the same slice by an earlier call (`Resolved_Queries`), restored
// once it holds one and kept by the call that resolves it. Only a demand walk keeps one: a path walk's
// resolution is a few words, but its context's bytes many, slower to restore than to resolve.
//
// Out of line: it runs once per scan, and inlined into the walk's specialization its body shares the
// walk's register allocation.
resolve_queries :: #force_no_inline proc(
	queries: []Scan_Query,
	mode: Resolution,
	axes: Strictness_Axes,
	ctx: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	kept: ^Resolved_Queries = nil,
) -> Capacity {
	// `.Dom` decodes the `.Nodes` rows and writes none of its own.
	#assert(.Dom not_in Q || .Nodes in Q)
	KEEPS :: .Demand in Q && Q & {.Path, .Nodes, .Dom} == {}
	when KEEPS {
		if kept != nil && kept.ok && kept.kinds == Q {
			resolved_restore(kept, ctx, queries[0].sink, Q)
			return .None
		}
	}
	query_ctx_zero(ctx, Q)
	// A `.Locate` scan validates nothing it locates. Resolved once for every `.Dom` emit site.
	ctx^.walk_judged = axes.scan == .Full
	resolved: bit_set[Walk_Kind]

	for q in queries {
		// `.Path` repeats, all on one sink.
		if q.kind == .Path {
			if e := bind_path_run(ctx, q, mode); e != .None {
				return e
			}
			resolved += {.Path}
			continue
		}

		// `.Demand` is one per scan, and its answer buffer is the spec's.
		if q.kind == .Demand {
			assert(!ctx^.demand_asked, "a request names one demand")
			demand_prepare(ctx, q.demand, mode, q.allocator)
			if ctx.path_sink == nil {
				ctx.path_sink = q.sink
			}
			ctx^.demand_asked = true
			resolved += {.Demand}
			// The gate is read by a walk carrying `.Gate` alone: any other would read every member it shuts out.
			when .Gate in Q {
				demand_gate_prepare(ctx, q.demand)
				resolved += {.Gate}
			} else {
				assert(q.demand.gate == nil, "a gated demand needs `.Gate` in $Q")
			}
			continue
		}

		// A request names each other kind once, since a repeat would be wired twice.
		assert(q.kind not_in resolved, "a request names each kind once")
		resolved += {q.kind}
	}

	// `$Q` must name nothing that was not asked for: its compiled-in code would run on unwired state.
	when ODIN_DEBUG {
		assert(Q - {.Unique} - resolved == {}, "a kind in $Q that no query asks for")
	}

	// Wire it. This is the only pass that touches a caller's sink.
	//
	// The `.Nodes` key latch must start at `NO_KEY_LATCH`: zero would mean "the
	// key is the empty span at offset 0" for a root or array element.
	when .Nodes in Q {
		ctx^.node_key_lo = NO_KEY_LATCH
		ctx^.node_key_hi = NO_KEY_LATCH
	}
	for q in queries {
		switch q.kind {
		case .Nodes:
			adopt_allocator(&q.sink.nodes, q.allocator)
			ctx^.nodes_sink = &q.sink.nodes

		case .Dom:
			// Decoded string bytes live on the sink: row payloads are offsets into
			// bytes that must outlive the scan.
			adopt_allocator(&q.sink.value_bytes, q.allocator)
			ctx^.value_bytes = &q.sink.value_bytes

		case .Path:
			adopt_allocator(&q.sink.paths, q.allocator)
		case .Demand, .Gate, .Shape, .Unique, .Pass_Unread:
			// Wired in the `.Demand` arm of the first pass, and `.Unique` by the scan entry.
		}
	}
	when KEEPS {
		if kept != nil {
			resolved_keep(kept, ctx, Q)
		}
	}
	return .None
}

// Bind one path run for `.Path` query `q`. Every run shares one `paths` array. The run count and step
// count are the pre-flight's to bound (`Capacity`), and refused here for a caller that skipped it: a
// truncated path would answer another question.
@(private = "file")
bind_path_run :: proc(ctx: ^Query_Ctx, q: Scan_Query, mode: Resolution) -> Capacity {
	if ctx.n_paths >= MAX_PATH_QUERIES {
		return .Path_Runs
	}
	if len(q.path.steps) > MAX_PATH_STEPS {
		return .Path_Steps
	}
	if ctx.n_paths == 0 {
		ctx.path_sink = q.sink
	}
	wild := steps_have_any(q.path.steps)
	if mode != .All && wild {
		ctx.wild_keys = true
	}
	ctx.path_runs[ctx.n_paths] = Path_Run{
		sink  = &q.sink.paths,
		query = q.tag,
		steps = q.path.steps,
		mode  = mode,
		limit = q.path.limit,
		each  = wild && q.path.per_element,
	}
	ctx.n_paths += 1
	return .None
}

// A resolution kept for the walks of one query set over many sources (`resolve_queries`' `kept`): the
// context it left for `kinds`, once `ok`, but for the fields a demand walk does not read. What it points at
// but the sink must stay where it is.
Resolved_Queries :: struct {
	ctx:   [KEPT_CTX_BYTES / 8]u64,
	gate:  ^Demand_Gate,
	kinds: bit_set[Walk_Kind],
	ok:    bool,
}
@(private = "file")
KEPT_CTX_BYTES :: int(offset_of(Query_Ctx, nodes_edge))

// Keep `ctx`, just resolved for `$Q`, in `kept`.
@(private = "file")
resolved_keep :: proc(kept: ^Resolved_Queries, ctx: ^Query_Ctx, $Q: bit_set[Walk_Kind]) {
	#assert(.Demand in Q && Q & {.Path, .Nodes, .Dom} == {}, "a kept resolution is a demand walk's, which reads no path or row fields")
	runtime.mem_copy_non_overlapping(&kept.ctx, ctx, KEPT_CTX_BYTES)
	kept.gate = ctx.gate
	kept.kinds = Q
	kept.ok = true
}

// The context `resolve_queries` would leave for the query set `kept` holds, writing to `sink`: the kept one,
// rebound to `sink`, with the demand's answers and its gate emptied as `demand_prepare` empties them.
@(private = "file")
resolved_restore :: proc(kept: ^Resolved_Queries, ctx: ^Query_Ctx, sink: ^Scan_Query_Sink, $Q: bit_set[Walk_Kind]) {
	runtime.mem_copy_non_overlapping(ctx, &kept.ctx, KEPT_CTX_BYTES)
	when .Demand in Q {
		// The one sink every query of a set writes to (`resolve_queries`).
		if ctx.demand.rows != nil {
			ctx.demand.rows = &sink.paths
		}
		demand_reset(&ctx.demand)
		// Where `demand_wild_open` counts (the kept one is an earlier call's).
		ctx.path_sink = sink
	}
	when .Gate in Q {
		ctx.gate = kept.gate
		demand_gate_reset(ctx.gate)
	}
}
