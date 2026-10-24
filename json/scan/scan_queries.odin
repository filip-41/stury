package scan

import "walk"
import index "index"
import lex "lex"

// A tape is built by a checking walk only (`Nodes_Need_Strict`), so a set with paths beside one has no
// locating walk. A tape alone keeps its dead twin, which the values walk's code layout depends on.
@(private = "file")
TAPE_BESIDE_PATHS :: bit_set[Walk_Kind]{.Nodes, .Path}

// The four walk specializations. `$check` and `$may_stop` stay literals, so
// each arm is its own walk and no runtime flag reaches the value loop.
@(private = "file")
dispatch_walk :: #force_inline proc(
	s: ^Scanner,
	ctx: ^Query_Ctx,
	axes: Strictness_Axes,
	$Q: bit_set[Walk_Kind],
	stopped: ^bool,
	$pretty: bool,
) -> Maybe(Error) {
	// Only path and demand queries can tell which values nothing reads, so only they let a locating or
	// may-stop reading leave values unvisited. With no query the walk is a validation and never skips.
	SKIP :: Q != {} && Q <= bit_set[Walk_Kind]{.Path, .Demand, .Gate}
	switch axes_check_level(axes) {
	case .Values:
		return dispatch_walk_cursor(s, ctx, axes, .Values, Q, stopped, SKIP, pretty)
	case .Locate:
		when !(TAPE_BESIDE_PATHS <= Q) {
			return dispatch_walk_cursor(s, ctx, axes, .Locate, Q, stopped, SKIP, pretty)
		}
	}
	return nil
}

@(private = "file")
dispatch_walk_cursor :: #force_inline proc(
	s: ^Scanner,
	ctx: ^Query_Ctx,
	axes: Strictness_Axes,
	$check: Check_Level,
	$Q: bit_set[Walk_Kind],
	stopped: ^bool,
	$skip: bool,
	// The document starts like pretty-printed output (`pretty_head`). A walk that reads every token then uses the
	// pretty cursor.
	$pretty: bool,
) -> Maybe(Error) {
	// One index per arm keeps a single buffer in the frame.
	when SCAN_FORCE_SLOW {
		cur: Byte_Cursor
	} else when check == .Locate && skip {
		// Every unread scalar is skipped and the others are passed by their leaf, so no per-block shape fact
		// is collected. A skip needs only `.Wire_On_Skip`, to check the blocks it crosses.
		ix: index.Index(index.Facts{.Wire_On_Skip}) = ---
		cur := index_cursor(&ix, s, axes.termination == .Complete)
	} else when check == .Locate {
		ix: index.Index(LOCATE_FACTS) = ---
		cur := index_cursor(&ix, s, axes.termination == .Complete)
	} else when skip {
		ix: index.Index(VALUES_FACTS) = ---
		cur: Byte_Cursor
	} else when pretty {
		cur: Pretty_Cursor
	} else {
		cur: Byte_Cursor
	}
	termination := axes.termination
	// Only a path or a demand can settle early, so for any other set a may-stop reading is the complete
	// walk and compiles as one.
	when .Path not_in Q && .Demand not_in Q {
		termination = .Complete
	}
	// Without skipping, a may-stop reading that cannot stop early is the complete walk, so it shares it.
	when !skip {
		if termination == .First_Wins_May_Stop && !stop_capable(ctx, Q) {
			termination = .Complete
		}
	} else when Q == MEMBER_RUN_KINDS && check == .Values {
		// A skipping demand walk that cannot stop early is also the complete walk where skipping would not pay:
		// its index and per-value test would be work on top of the complete walk's (`demand_skip_walk_pays`).
		if termination == .First_Wins_May_Stop && !stop_capable(ctx, Q) && !demand_skip_walk_pays(ctx, s.src, int(s.pos), s.limits.max_depth) {
			termination = .Complete
		}
	} else when Q == {.Path} && check == .Values && !SCAN_FORCE_SLOW {
		// A skipping path walk where every value it would skip is a scalar (`path_skip_walk_pays`) also falls
		// back, but to the byte walk, which still stops. One that cannot stop keeps the skipping walk, because a
		// complete fallback here changes the codegen.
		if termination == .First_Wins_May_Stop && stop_capable(ctx, Q) && !path_skip_walk_pays(s.src, int(s.pos)) {
			return walk_bytes_may_stop(s, ctx, check, Q, stopped)
		}
	}
	switch termination {
	case .Complete:
		return walk_value_q(s, ctx, s.limits.max_depth, check, Q, &cur, skip && check == .Locate, false)
	case .First_Wins_May_Stop:
		// `axes_for` stops only a `.Full` reading, which walks at `.Values`: a locating walk never gets
		// here, and compiling it would be a dead twin of the walk.
		when check == .Values {
			// A Values walk takes the index only when it skips. Otherwise every token's leaf runs and the
			// index would be work on top of them.
			when skip && !SCAN_FORCE_SLOW {
				skip_cur := index_cursor(&ix, s, false)
				return walk_may_stop(s, ctx, check, Q, &skip_cur, skip, stopped)
			} else when skip {
				return walk_may_stop(s, ctx, check, Q, &cur, skip, stopped)
			} else {
				return walk_value_q(s, ctx, s.limits.max_depth, check, Q, &cur, skip, true, stopped)
			}
		}
	}
	return nil
}

@(private = "file")
walk_may_stop :: #force_inline proc(
	s: ^Scanner,
	ctx: ^Query_Ctx,
	$check: Check_Level,
	$Q: bit_set[Walk_Kind],
	cur: ^$C,
	$may_skip: bool,
	stopped: ^bool,
) -> Maybe(Error) {
	if stop_capable(ctx, Q) {
		return walk_value_q(s, ctx, s.limits.max_depth, check, Q, cur, may_skip, true, stopped)
	}
	return walk_value_q(s, ctx, s.limits.max_depth, check, Q, cur, may_skip, false)
}

// The byte walk of a may-stop reading. Out of line, so the other walks' codegen stays apart from it.
@(private = "file")
walk_bytes_may_stop :: #force_no_inline proc(
	s: ^Scanner,
	ctx: ^Query_Ctx,
	$check: Check_Level,
	$Q: bit_set[Walk_Kind],
	stopped: ^bool,
) -> Maybe(Error) {
	cur: Byte_Cursor
	return walk_value_q(s, ctx, s.limits.max_depth, check, Q, &cur, false, true, stopped)
}

@(private = "file")
take_edge :: #force_no_inline proc(q: ^Query_Ctx, arr: ^[dynamic]$T, kind: Walk_Kind) -> Edge(T) {
	if e, ok := edge_begin(q, arr); ok {
		e.len = len(arr^)
		return e
	}
	note_oom(q, kind)
	return {}
}

@(private = "file")
publish_nodes :: #force_no_inline proc(ctx: ^Query_Ctx) {
	edge_publish(ctx.nodes_sink, ctx.nodes_edge.len)
}

// Scan `src` and write the answers to the requested queries into the sink they name.
//
// `$Q` is the set of kinds this call site is specialized for, which keeps unrequested work out of the
// walk. `queries` must name exactly those kinds, each kind but `.Path` once.
// `fault.capacity` is a refusal, in which case the source was not scanned and nothing was written.
// `fault.oom` is an append the allocator refused mid-run. It is independent of the result in `err`. Rows already
// appended are not rolled back: ignore the sink on error.
// The caller owns the pre-flight of everything else about `queries` (`request_fault`): the slice must be
// servable, a `.Nodes`/`.Dom` source must fit `TAPE_MAX_SOURCE`, and only the wanted names and the path runs'
// caps are checked here.
// `strictness` and `resolution` decide the walk's reading (`axes_for`): `.Lazy` may stop only under
// `.First`. Under `.Last` the forward walk reads the whole item.
// `resolution` is also the duplicate rule paths and a demand resolve under.
// `stop_byte` is non-nil only when a `.First_Wins_May_Stop` reading stopped there because every query had
// settled (`stop_capable`). Bytes past it were never checked, so neither it nor `err` is a document result.
// `validity` is written on every exit: `.Full` exactly when the walk consumed the whole item and skipped
// nothing, else `.Partial`.
// `dialect == .Jsonc` reads comments and trailing commas on `jsonc_walk`, whatever the strictness: a complete
// `.Values` walk, so its coverage is `.Full`. `facts` then receives each comment, attached to nothing, and nil records none.
// Only a locating or may-stop reading whose queries are all path or demand ones skips a value, and its
// `validity` is then `.Partial`. Pass that to `validate_remaining`. A cap past MAX_DEPTH is held to it:
// `scan_queries_deep` reads deeper.
// `kept`, when not nil, keeps a demand walk's resolution of `queries` for the next call over the same query
// set, which resolves nothing (`resolve_queries`): a set whose inputs do not change between calls.
scan_queries :: proc(
	src: []byte,
	queries: []Scan_Query,
	strictness := Strictness.Strict,
	limits := Limits{},
	$Q: bit_set[Walk_Kind],
	stop_byte: ^Maybe(u64) = nil,
	validity: ^Validity = nil,
	resolution := Resolution.All,
	kept: ^Resolved_Queries = nil,
) -> (err: Maybe(Error), fault: Walk_Fault) {
	when .Nodes in Q {
		qerr: Maybe(walk.Request_Error)
		err, qerr = scan_queries_tape(src, queries, strictness, limits, Q, stop_byte, validity, resolution)
		if q, refused := qerr.?; refused {
			fault = Walk_Fault{capacity = q.capacity, oom = q.kind == .Out_Of_Memory}
		}
		return
	} else {
		return scan_queries_in(src, queries, strictness, limits, Q, stop_byte, validity, resolution, .Json, nil, Walk_Fault, false, kept, false)
	}
}

// The node-tape walks behind `scan_queries`, returning a `Maybe(Request_Error)` resolved through
// `resolve_refusal`: the walk's register allocation follows its exits' shape, and under `Walk_Fault` the
// tape walks spill more while the path walks spill less, hence the split.
@(private = "file")
scan_queries_tape :: #force_no_inline proc(
	src: []byte,
	queries: []Scan_Query,
	strictness: Strictness,
	limits: Limits,
	$Q: bit_set[Walk_Kind],
	stop_byte: ^Maybe(u64),
	validity: ^Validity,
	resolution: Resolution,
) -> (err: Maybe(Error), qerr: Maybe(walk.Request_Error)) {
	// The cursor is chosen before the walk's scanner exists, as in `scan_plain`, so the compact walk compiles as
	// it would without the pretty one.
	s := enter_document(src, limits, MAX_DEPTH)
	lex.skip_ws(&s)
	if pretty_head(src, int(s.pos)) {
		return scan_queries_tape_pretty(src, queries, strictness, limits, Q, stop_byte, validity, resolution)
	}
	return scan_queries_in(
		src, queries, strictness, limits, Q, stop_byte, validity, resolution, .Json, nil, Maybe(walk.Request_Error), false, nil, false,
	)
}

// Runs `scan_queries_tape` on the pretty cursor, for a document that starts like pretty-printed output.
@(private = "file")
scan_queries_tape_pretty :: #force_no_inline proc(
	src: []byte,
	queries: []Scan_Query,
	strictness: Strictness,
	limits: Limits,
	$Q: bit_set[Walk_Kind],
	stop_byte: ^Maybe(u64),
	validity: ^Validity,
	resolution: Resolution,
) -> (err: Maybe(Error), qerr: Maybe(walk.Request_Error)) {
	return scan_queries_in(
		src, queries, strictness, limits, Q, stop_byte, validity, resolution, .Json, nil, Maybe(walk.Request_Error), false, nil, true,
	)
}

// `scan_queries` and `scan_queries_jsonc` under a cap past MAX_DEPTH, on `walk_deep`: a complete walk that
// neither stops nor skips, at `.Structural`'s level for that strictness and checking every value for the
// rest. So `.Lazy` has no early stop past MAX_DEPTH. The caller picks it before the walk, so the default walks
// compile as if it did not exist.
scan_queries_deep :: #force_no_inline proc(
	src: []byte,
	queries: []Scan_Query,
	strictness: Strictness,
	limits: Limits,
	$Q: bit_set[Walk_Kind],
	validity: ^Validity,
	resolution: Resolution,
	dialect: Dialect,
	facts: ^[dynamic]Fact,
) -> (err: Maybe(Error), fault: Walk_Fault) {
	if dialect == .Jsonc {
		return scan_queries_in(src, queries, .Strict, limits, Q, nil, validity, resolution, .Jsonc, facts, Walk_Fault, true, nil, false)
	}
	// `.Lazy` is read as `.Strict`: its stop is not taken here, and `axes_for` would arm one.
	level := Strictness.Structural if strictness == .Structural else Strictness.Strict
	return scan_queries_in(src, queries, level, limits, Q, nil, validity, resolution, .Json, nil, Walk_Fault, true, nil, false)
}

// `resolve_queries` behind an out-of-line `Maybe(Request_Error)` return, for `scan_queries_tape`.
@(private = "file")
resolve_refusal :: #force_no_inline proc(
	queries: []Scan_Query,
	mode: Resolution,
	axes: Strictness_Axes,
	ctx: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
) -> Maybe(walk.Request_Error) {
	if e := resolve_queries(queries, mode, axes, ctx, Q); e != .None {
		return walk.Request_Error{kind = .Over_Capacity, query_kind = .Path, capacity = e}
	}
	return nil
}

// A refusal before the walk, in the walk's return shape `F`: `Walk_Fault`, or `scan_queries_tape`'s.
@(private = "file")
capacity_fault :: #force_inline proc($F: typeid, e: walk.Capacity) -> F {
	when F == Walk_Fault {
		return Walk_Fault{capacity = e}
	} else {
		return walk.Request_Error{kind = .Over_Capacity, query_kind = .Path, capacity = e}
	}
}

// The sink-side result after a run, in the walk's return shape `F`: a failed append left a collection short.
@(private = "file")
sink_fault :: #force_inline proc($F: typeid, ctx: ^Query_Ctx) -> F {
	when F == Walk_Fault {
		return Walk_Fault{oom = ctx.oom}
	} else {
		if ctx.oom {
			return walk.Request_Error{kind = .Out_Of_Memory, query_kind = walk.query_of(ctx.oom_kind)}
		}
		return nil
	}
}

// `scan_queries` over JSONC: a complete `.Strict` walk that appends each comment to `facts` when it is not
// nil. A procedure of its own so the JSON instantiation compiles as it would without it.
scan_queries_jsonc :: #force_no_inline proc(
	src: []byte,
	queries: []Scan_Query,
	limits: Limits,
	$Q: bit_set[Walk_Kind],
	validity: ^Validity = nil,
	resolution := Resolution.All,
	facts: ^[dynamic]Fact = nil,
) -> (err: Maybe(Error), fault: Walk_Fault) {
	return scan_queries_in(src, queries, .Strict, limits, Q, nil, validity, resolution, .Jsonc, facts, Walk_Fault, false, nil, false)
}

@(private = "file")
scan_queries_in :: #force_inline proc(
	src: []byte,
	queries: []Scan_Query,
	strictness: Strictness,
	limits: Limits,
	$Q: bit_set[Walk_Kind],
	stop_byte: ^Maybe(u64),
	validity: ^Validity,
	resolution: Resolution,
	$dialect: Dialect,
	facts: ^[dynamic]Fact,
	$F: typeid,
	$deep: bool,
	kept: ^Resolved_Queries = nil,
	$pretty: bool,
) -> (err: Maybe(Error), fault: F) {
	axes := axes_for(strictness, resolution)
	when TAPE_BESIDE_PATHS <= Q {
		assert(axes.scan != .Locate, "a node tape needs a judging walk")
	}
	when .Demand in Q {
		// Before anything is resolved or written.
		for q in queries {
			if q.kind == .Demand && walk.names_over_capacity(q.demand.keys) {
				return nil, capacity_fault(F, .Repeated_Names)
			}
		}
	}
	// A row's `u32` spans cannot address a source past `TAPE_MAX_SOURCE` (one below the u32 all-ones, so
	// `NO_KEY` cannot collide with a real span).
	when .Nodes in Q {
		assert(u64(len(src)) <= TAPE_MAX_SOURCE, "a node tape over a source its offsets cannot address")
	}
	// Words rather than a `Query_Ctx` local: `resolve_queries` zeroes only the fields this query set reads
	// (`query_ctx_zero`).
	ctx_words: [size_of(Query_Ctx) / 8]u64 = ---
	unlent: walk.Scan_Query_Sink = --- // counted into, never read: for a demand walk that lends no sink
	_ = unlent
	ctx := (^Query_Ctx)(&ctx_words)
	when F == Walk_Fault {
		if e := resolve_queries(queries, resolution, axes, ctx, Q, kept); e != .None {
			return nil, capacity_fault(F, e)
		}
	} else {
		if e := resolve_refusal(queries, resolution, axes, ctx, Q); e != nil {
			return nil, e
		}
	}
	ctx.hooks = &FORMAT_HOOKS
	// The demand's key-time match compares against the document, stored here because `resolve_queries`
	// has no `src`.
	when .Demand in Q {
		ctx.demand.src = src
		// The walk counts into a sink on every object (`demand_wild_open`), a caller's or, for one that lends none, this.
		if ctx.path_sink == nil {
			ctx.path_sink = &unlent
		}
	}

	when deep {
		s := enter_document(src, limits, DEPTH_CEILING)
	} else {
		s := enter_document(src, limits, MAX_DEPTH)
	}
	ctx.max_depth = s.limits.max_depth
	when dialect == .Jsonc {
		jc := Jsonc_Cursor{facts = facts}
		ctx.hooks = &FORMAT_HOOKS_JSONC
		jsonc_skip(&s, &jc)
	} else {
		lex.skip_ws(&s)
	}
	when .Path in Q {
		ctx.root_lo = s.pos
		ctx.path_src = src
	}
	stopped := false
	// Set only at the exit that ran to the end. A stop, a fault or a region the walk skipped
	// (`ctx.skipped`) leaves it false.
	covered := false
	defer {
		if validity != nil {
			validity^ = covered ? .Full : .Partial
		}
	}
	// The keys of the open objects past the first KEY_SCRATCH are scan-owned scratch, in `context.allocator`,
	// freed on every exit. A wildcard run under `.First` or `.Last` remembers the keys of the objects it
	// reads, in the same scratch.
	when .Unique in Q || .Path in Q {
		key_scratch: Key_Scratch = ---
		keys: Key_Set
		when .Unique in Q {
			keyed :: true
		} else {
			keyed := ctx.wild_keys
		}
		if keyed {
			key_set_init(&keys, &key_scratch, context.allocator)
		}
		defer if keyed {
			key_set_destroy(&keys)
		}
		ctx.keys = &keys
	}
	// The edge lives on the context and is read by the emit procs directly: threading it through the
	// walk as a parameter would cost it registers across every inlined proc.
	when .Nodes in Q {
		// Reserve once before the edge is borrowed, rather than grow a cold sink rung by rung. A refused
		// reserve is ignored.
		seed_row_cap(ctx.nodes_sink, len(src))
		ctx.nodes_edge = take_edge(ctx, ctx.nodes_sink, .Nodes)
	}

	// Published on every exit: rows the walk did write are real answers about the bytes it reached.
	// Refused growths are already on `ctx`. `sink_fault` folds them in.
	when .Nodes in Q {
		defer publish_nodes(ctx)
	}
	when dialect == .Jsonc {
		when deep {
			werr := jsonc_walk_deep(&s, ctx, Q, &jc)
		} else {
			werr := jsonc_walk(&s, ctx, Q, &jc)
		}
		if jc.oom {
			note_oom(ctx, .Nodes)
		}
	} else when deep {
		werr: Maybe(Error)
		switch axes_check_level(axes) {
		case .Values:
			werr = walk_deep(&s, ctx, s.limits.max_depth, .Values, Q, &Jsonc_Cursor{json = true}, false, nil)
		case .Locate:
			when !(TAPE_BESIDE_PATHS <= Q) {
				werr = walk_deep(&s, ctx, s.limits.max_depth, .Locate, Q, &Jsonc_Cursor{json = true}, false, nil)
			}
		}
	} else {
		werr := dispatch_walk(&s, ctx, axes, Q, &stopped, pretty)
	}
	if werr != nil {
		// A `.Last` candidate parked before the fault is an answer about bytes the walk did check,
		// as on the routes that emit it at once. The fault, not a dropped answer, says the rest is unread.
		walk.auto_flush_last(ctx, Q)
		return werr, sink_fault(F, ctx)
	}
	// A negative `Index`'s re-read that found its answer malformed (`path_reenter_from_end`) stops a walk
	// that can stop. One that cannot runs on to its end, and a later fault it meets is its result instead.
	// Tested on these two exits only: a test on the walk's result, or on its fault exit, costs the walk
	// inlined above its register allocation.
	if stopped {
		if e, bad := walk.reread_verdict(ctx, Q, nil).?; bad {
			return e, sink_fault(F, ctx)
		}
		if stop_byte != nil {
			stop_byte^ = s.pos
		}
		return nil, sink_fault(F, ctx)
	}
	when .Path in Q {
		if e, bad := walk.reread_verdict(ctx, Q, nil).?; bad {
			return e, sink_fault(F, ctx)
		}
		// An empty path is the node itself, and its extent is the root value's.
		// Every other query settled during the walk. A `.All` query that answered
		// nothing is a settled miss here, once the answer set is known.
		root_hi := s.pos
		for i in 0 ..< ctx.n_paths {
			run := &ctx.path_runs[i]
			if len(run.steps) == 0 {
				if emit_path(run, walk.path_answer_of(run, .Found, ctx.root_lo, root_hi, walk.NO_OWNER, walk.kind_at(src, ctx.root_lo))) {
					note_oom(ctx, .Path)
				}
				run.settled = true
			}
		}
		if walk.finish_paths(&ctx.path_runs, ctx.n_paths, Q) {
			note_oom(ctx, .Path)
		}
	}
	// The one exit that consumed the item. `finish` may still report `Trailing`, a whole-document result,
	// so coverage is `.Full` then too, unless the walk skipped a region.
	covered = !ctx.skipped
	when dialect == .Jsonc {
		ferr := jsonc_finish(&s, &jc)
		if jc.oom {
			note_oom(ctx, .Nodes)
		}
		return ferr, sink_fault(F, ctx)
	} else {
		return finish(&s), sink_fault(F, ctx)
	}
}


// The commit call: the only way a `.Partial` result becomes a whole-document one. `err == nil` from here
// means every byte of `src` was checked at `.Full` grammar.
//
// A no-op only when every channel says nothing is unchecked: `verdict == nil`, `coverage == .Full`,
// `stop == nil`. A skipped region makes `coverage` `.Partial`. Otherwise it re-walks the whole item at `.Strict`, since a stop lands
// mid-container. The no-op is a precondition, not a check: the result must come from a walk over these
// same bytes with the same `limits`. `Validity`'s zero value is `.Partial`, so a caller that never
// established coverage gets the re-walk. The returned `validity` is `.Full` on both arms and does not
// upgrade a `.Structural` reading's level. That is `validate(src, .Json, .Strict)`. `unique` re-walks with the key
// check (`.Duplicate_Key`), as a scan under `Duplicates.Refuse` checked. Its refused spill is `.Out_Of_Memory`.
validate_remaining :: proc(
	src: []byte,
	verdict: Maybe(Error),
	coverage: Validity,
	stop: Maybe(u64),
	limits := Limits{},
	unique := false,
) -> (err: Maybe(Error), validity: Validity) {
	if verdict == nil && coverage == .Full && stop == nil {
		return nil, .Full
	}
	deep := limits.max_depth > MAX_DEPTH
	if unique {
		werr: Maybe(Error)
		fault: Walk_Fault
		if deep {
			werr, fault = scan_queries_deep(src, nil, .Strict, limits, {.Unique}, nil, .All, .Json, nil)
		} else {
			werr, fault = scan_queries(src, nil, .Strict, limits, {.Unique})
		}
		if werr == nil && fault.oom {
			return Error{kind = .Out_Of_Memory}, .Full
		}
		return werr, .Full
	}
	return scan_plain_deep(src, .Strict, limits) if deep else scan_plain(src, .Strict, limits), .Full
}

// Bytes past the document are `Trailing` at the first of them, at every level.
finish :: #force_inline proc(s: ^Scanner) -> Maybe(Error) {
	lex.skip_ws(s)
	if s.pos != u64(len(s.src)) {
		return Error{offset = s.pos, kind = .Trailing}
	}
	return nil
}
