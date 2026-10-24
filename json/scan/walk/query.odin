package walk

import "base:runtime"

// What a request may ask of a scan. `.Nodes` and `.Dom` carry the answers as node rows. Several `.Path`s
// may ride one scan.
Query :: enum {
	Path, // where a `Path` lands. Answers go to `Request.answers` (path_answer.odin)
	Nodes, // one row per value, written at its open and patched at its close. Answers go to
	       // `Request.doc.rows`.
	Dom, // `.Nodes` with escaped strings unescaped at build. A number is decoded each time it is read, the
	     // walk only checks it. The walk always carries `.Nodes` beside it.
}

// What one walk is wired for: every `Query` under the same name and value, then the walk selectors the
// json layer picks and a request never names. The comptime set of kinds in use at a call site is the
// monomorphization key, so each distinct set gets its own walk.
Walk_Kind :: enum {
	Path,
	Nodes,
	Dom,
	Demand, // the demand matcher (demand.odin): locate named members at one depth in this same walk.
	        // The router picks it for a `Path`.
	Gate, // beside `.Demand`: the matcher reads only under named members (`Demand_Spec.gate`), a
	      // column such as `.logs[].id`.
	Shape, // the unmarshal walk (`scan_shape`): reads a document into a typed target along a read shape
	       // (`Shape_Run`).
	Unique, // `Duplicates.Refuse`: every open object's keys are remembered (`Key_Set`), and a key repeating
	        // one of its own object's refuses the document (`.Duplicate_Key`). Beside any other kinds.
	Pass_Unread, // beside `.Shape`, for `.Lazy` above its gate in the complete walk: a fused struct passes a
	             // string nothing reads to its closing quote, unvalidated.
}

#assert(int(Walk_Kind.Dom) == int(Query.Dom) && len(Query) == int(Walk_Kind.Demand))

// The kind a request named for walk kind `k`: a selector the router picked for a `Path` is that `Path`,
// and `.Shape`, `.Unique` and `.Pass_Unread` belong to no request's answers. The node-tape walk's
// exit names its culprit with it (`scan_queries_tape`).
query_of :: proc "contextless" (k: Walk_Kind) -> Maybe(Query) {
	switch k {
	case .Demand, .Gate:
		return .Path
	case .Shape, .Unique, .Pass_Unread:
		return nil
	case .Path, .Nodes, .Dom:
	}
	return Query(k)
}

// One query the walk is wired for: what it asks, whose allocator owns its storage, and the
// collection the walk appends into.
//
// A sink array with no allocator of its own adopts `allocator`, and one that already has one must agree,
// because one dynamic array has one allocator.
Scan_Query :: struct {
	kind:      Walk_Kind,
	allocator: runtime.Allocator,
	sink:      ^Scan_Query_Sink,
	// .Path only: the path it resolves.
	path:      Path,
	// .Demand only: the names to locate and the buffer they answer into.
	demand:    Demand_Spec,
	// .Path only: the `query` its answers carry, so a caller that handed the walk only some of its
	// paths still hears them under its own numbering.
	tag:       u32,
}

// Wire `want` into an array that has no allocator of its own (a never-`make`d `[dynamic]` has the zero
// Allocator). Otherwise agree only if the array already carries that one. Writes to a caller-owned array, so
// only the wiring pass calls it, after the pre-flight has agreed every output's allocator.
adopt_allocator :: #force_inline proc(arr: ^[dynamic]$T, want: runtime.Allocator) -> bool {
	if arr.allocator.procedure == nil {
		arr.allocator = want
		return true
	}
	return arr.allocator == want
}

// Whether an output made with `have` can grow under `want`: one dynamic array has one allocator, so the
// scan cannot move it to another. An output with no allocator yet is compatible with anything. A
// mismatch comes from changing `Request.allocator` after a scan, or from filling its outputs by hand.
allocator_ok :: #force_inline proc(have, want: runtime.Allocator) -> bool {
	return have.procedure == nil || have == want
}

// What a walk could not do, as the walk returns it: a refusal of its own before anything was read
// (`capacity`, restating the caller's pre-flight), or an output that could not grow (`oom`, and the walk ran
// on to its result). A plain value, which the automaton's walk returns cheaper than a
// `Maybe(Request_Error)`. The node-tape walks keep that return (`scan_queries_tape`).
Walk_Fault :: struct {
	capacity: Capacity,
	oom:      bool,
}

// What a node-tape walk could not do, as it returns it (`scan_queries_tape`); `json` reports either as an `Error`.
// The values are fixed: renumbering them changes the tape walks' code generation for the worse.
Request_Error_Kind :: enum {
	// A fixed engine limit (`capacity`), restating the caller's pre-flight.
	Over_Capacity = 4,
	// An output could not grow. `query_kind` names it.
	Out_Of_Memory = 6,
}

// Which limit an `Over_Capacity` refusal hit.
Capacity :: enum u8 {
	None,
	Path_Runs, // more paths on the path automaton than MAX_PATH_QUERIES
	Path_Steps, // a path the path automaton serves with more steps than MAX_PATH_STEPS
	Repeated_Names, // more byte-identical wanted names than LATCH_MAX, which one member's key could all match
	Node_Source_Bytes, // a `.Nodes`/`.Dom` source longer than `Row`'s `u32` offsets address
}

// The node-tape walks' refusal. Its layout is the walk's return shape, which register allocation follows; `path`
// and `offset` are not set.
Request_Error :: struct {
	kind:       Request_Error_Kind,
	query_kind: Maybe(Query),
	capacity:   Capacity,
	path:       int,
	offset:     u64,
}
