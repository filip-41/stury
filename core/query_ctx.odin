package core

import "base:runtime"

// One scan's walk state, zeroed by `query_ctx_zero` for the kinds in use. Fields are ordered by who reads them:
// the leading ones every walk, the row edges `.Nodes` and `.Dom`, the path runs `.Path`, and the tail
// (from `wild_marks`) is never zeroed, each field set before it is read.
Query_Ctx :: struct {
	// The path runs in use (`path_runs[:n_paths]`).
	n_paths:        int,
	path_sink:      ^Scan_Query_Sink,
	max_depth:      u64,
	root_lo:        u64,
	// `key_esc_live` is set while parsing an object member's key. The string leaf raises `key_saw_escape` on
	// a backslash, so nothing re-scans the key. `object_key` resets it per key.
	key_esc_live: bool,
	key_saw_escape: bool,
	// `.Nodes`: whether the latched member key carried an escape. Latched by `object_key`, cleared with the
	// key spans by the one row that takes the key.
	node_key_escaped: bool,
	// `.Nodes`: the string value's escape facts, waiting for the row `emit_scalar` writes right after the
	// leaf returns. Unlike `key_saw_escape` this outlives the leaf. It is reset at the opening quote.
	// `str_first_esc` saturates at `FIRST_ESC_SATURATED`. The string leaf is its only writer.
	str_escaped:   bool,
	str_first_esc: u16,
	// `.Path`: one past the deepest step index whose level may be armed, at least 1 once the root is armed.
	// The walk's hooks test it before they load a level, so below it the automaton costs one compare.
	path_top: u8,
	// `.Path`: some `.First` or `.Last` run has an `Any` step, so the walk remembers the keys of the objects
	// it reads (`wild_key`) to find a repeated one. Set by `bind_path_run`.
	wild_keys: bool,
	// The member key that introduced the value now being walked, for `.Nodes`. Latched by `object_key`, taken
	// by the member value's row, then reset to `NO_KEY_LATCH` so a later array element or root cannot inherit
	// it.
	node_key_lo: u64,
	node_key_hi: u64,
	// `.Dom` only: the decoded string payload the leaf produced, waiting for the row `emit_scalar` writes
	// next. The window is one value wide.
	dom_pending: Dom_Pending,
	// The demand read's resolved state and scratch (zeroed when none was asked for).
	demand: Demand_Run,
	// Whether a demand was asked for (one per scan).
	demand_asked: bool,
	// An append the caller's allocator refused. The row is lost, but the walk continues to reach the result.
	// the run reports the shortfall and `oom_kind` names the collection.
	oom:      bool,
	oom_kind: Walk_Kind,
	// A negative `Index`'s re-read found its answer malformed (`reread_fault`): the walk's result.
	reread_faulted: bool,

	// Whether this walk validates every token it visits rather than only locating it.
	walk_judged: bool,

	// Whether the walk covered some value without checks because it skipped it. Only whether, not how many
	// bytes: a count costs every skipped member its end.
	skipped: bool,

	// The caller's node rows, borrowed for the call. The walk writes through an `Edge` cursor.
	nodes_edge: Edge(Row),
	// Where decoded escaped strings are written, borrowed from the sink, which must outlive the scan.
	value_bytes: ^[dynamic]u8,
	nodes_sink:  ^[dynamic]Row,

	// Path resolution. `path_runs` is fixed because the walk allocates nothing. Declared last: they are most
	// of the context's bytes, and the fields every walk reads should sit at small offsets.
	//
	// `auto` is the compiled match automaton (`Path_Auto`), one level per step index. It lives here because
	// every hook that touches it is a separate proc, and a pointer to a walk local threaded through all of
	// them would escape.
	path_runs:      [MAX_PATH_QUERIES]Path_Run,
	auto:           Path_Auto,
	// A `.Last` wildcard run's rows written before the first occurrence of the key it matched at step `d`
	// in the container now open there (`auto_key`): where a repeat's supersession cuts. Never zeroed: a slot is read only once
	// `Auto_Level.hit` says it was written.
	wild_marks:     [MAX_PATH_QUERIES][MAX_PATH_STEPS]int,
	// Where the members of the array open at step `d` begin, the latest of each group of a stride's members
	// (`Path_Auto.ring_shift`) by group modulo `MEMBER_RING`, while a negative `Index` there waits for the
	// length (`path_reenter_from_end`). Never zeroed: a slot is read only for one of the container's last
	// `MEMBER_RING` groups, whose latest member is written when it opened.
	member_starts:  [MAX_PATH_STEPS][MEMBER_RING]u64,
	// A gated demand (`Demand_Spec.gate`), read only by a walk carrying `.Gate`. Never zeroed:
	// `demand_gate_prepare` sets it.
	gate:           ^Demand_Gate,
	// The document a `.Path` walk reads, for the kind of each `Found` it writes. Never zeroed: the walk
	// sets it before any hook runs.
	path_src:       []u8,
	// The format's hooks (`Format_Hooks`). Never zeroed: the scan entry sets it before the walk.
	hooks:          ^Format_Hooks,
	// `.Shape` only, set by `scan_shape`. Nothing else sets or reads it. Never zeroed.
	shape:          ^Shape_Run,
	// `.Unique` only, set by the scan entry before the walk. Never zeroed.
	keys:           ^Key_Set,
	// The first fault a negative `Index`'s re-read found in its answer (`path_reenter_from_end`). Never
	// zeroed: read only once `reread_faulted` says it was written.
	reread_fault:   Error,
}

// The zero context for a walk over `$Q`, the one zeroing of every `Query_Ctx`: each one is words declared
// `---` (a padded struct local is zeroed whole). The fields are ordered by who reads them, so each kind set
// zeroes a prefix: every walk reads the fields before `nodes_edge`. The row edges through `nodes_sink`
// are read only under `.Nodes` or `.Dom`, and the path runs and automaton only under `.Path`. Everything from
// `wild_marks` on is never zeroed, each field set before it is read (see its own comment).
query_ctx_zero :: #force_inline proc(ctx: ^Query_Ctx, $Q: bit_set[Walk_Kind]) {
	when .Path in Q {
		runtime.mem_zero(ctx, int(offset_of(Query_Ctx, wild_marks)))
	} else when Q & {.Nodes, .Dom} != {} {
		runtime.mem_zero(ctx, int(offset_of(Query_Ctx, path_runs)))
	} else {
		runtime.mem_zero(ctx, int(offset_of(Query_Ctx, nodes_edge)))
	}
}
// The prefixes nest, and nothing sits between the row edges and the path runs, or after the automaton.
#assert(offset_of(Query_Ctx, nodes_sink) + size_of(^[dynamic]Row) == offset_of(Query_Ctx, path_runs))
#assert(offset_of(Query_Ctx, path_runs) + size_of([MAX_PATH_QUERIES]Path_Run) + size_of(Path_Auto) == offset_of(Query_Ctx, wild_marks))
#assert(align_of(Query_Ctx) == align_of(u64))

// Record a refused append, keeping the first kind that fell short.
note_oom :: #force_inline proc(q: ^Query_Ctx, kind: Walk_Kind) {
	if !q.oom {
		q.oom = true
		q.oom_kind = kind
	}
}

// What the string leaf leaves for the row site. One value wide and read once: `emit_dom_string` fills it,
// `emit_scalar`'s `.String` arm consumes it.
Dom_Pending :: struct {
	str:     Row_Str,
	decoded: bool,
}
