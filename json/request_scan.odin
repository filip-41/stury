package json

// `scan` and `prepare`: the request checked, routed, and handed to the walk (request_walk.odin).

import "base:runtime"
import core_pkg "../core"
import scan_pkg "scan"

// Scan `src` for what the request asks and fill its outputs. The request is a `^Request` or a `^Prepared`
// from `prepare` (the same scan, without repeating the setup that does not depend on the source).
//
//	- Returns nil when the text is valid over what the scan visited (`Request.coverage`).
//	- An `Error` is the text's fault, or `.Out_Of_Memory` when an output could not grow.
//	- A `Request_Error` means the request was refused before any byte was read, and the outputs are untouched.
scan :: proc {
	scan_plain,
	scan_prepared,
}

@(private, require_results)
scan_plain :: #force_inline proc(src: []byte, req: ^Request($KINDS)) -> Scan_Error {
	return scan_request(src, req, planned = false)
}

// `planned`: the request holds its plan for `src` already (`scan_prepared`), so the checks and the routing are
// skipped. One body for both, so a program's scans share one copy of the walks.
@(private = "file")
scan_request :: #force_no_inline proc(src: []byte, req: ^Request($KINDS), planned: bool) -> Scan_Error {
	alloc := request_allocator(req)
	// `KINDS` as walk kinds, the same names. `.Dom` decodes the `.Nodes` rows. Written out kind by kind: a
	// conversion between two enums' bit_sets is no constant.
	W :: bit_set[scan_pkg.Walk_Kind]
	NONE :: W{}
	WALK ::
		(W{.Path} when .Path in KINDS else NONE) |
		(W{.Nodes} when .Nodes in KINDS || .Dom in KINDS else NONE) |
		(W{.Dom} when .Dom in KINDS else NONE)
	if !planned {
		if err, refused := request_fault(src, req, alloc).?; refused {
			return err
		}
		// `.Refuse` and JSONC walks serve every path through the automaton (`automaton_only`), so no matcher
		// is planned.
		if tape_routable(req) && scan_tape(src, req, alloc) {
			return nil
		}
		if err, refused := route_paths(&req.route, src, req.paths, req.duplicates, alloc, automaton_only(req)).?; refused {
			return err
		}
	}
	req.src, req.verdict, req.coverage, req.stop = src, nil, .Partial, nil
	req.groups.grouped = false
	req.route.unresolved = false
	err := scan_error(req.verdict, scan_routed(src, req, WALK, alloc))
	if req.route.unresolved && !req.route.every_member && (req.duplicates == .First || req.duplicates == .Last) {
		// A text another follows was read whole and answered (`.Trailing`), so its answers are settled too.
		if e, faulted := err.(Error); err == nil || faulted && e.kind == .Trailing {
			if settled := settle_wild(src, req, alloc); settled != nil {
				return settled
			}
		}
	}
	return err
}

// A request planned once for the scans of many sources, such as the records of a stream. `prepare` makes
// one.
//
//	- `scan(src, &p)` answers as `scan(src, p.req)` does, result, refusal and outputs alike, without
//	  repeating the setup that does not depend on the source.
//	- It borrows the request, whose outputs each scan fills, so one is used on one thread at a time. Each
//	  worker of a pool prepares a request of its own.
//	- The request's inputs must not change while it is in use (prepare again after), and `destroy(&req)`
//	  frees what both hold.
Prepared :: struct($KINDS: bit_set[Query]) {
	req:     ^Request(KINDS),
	// Whether the plan on the request is the prepared one. A request `prepare` refuses, or one it cannot
	// plan for every source, scans as `scan(src, req)` does every time.
	planned: bool,
	// The walk's resolution of the plan's queries, kept by the first planned scan for the rest.
	kept:    core_pkg.Resolved_Queries,
}

// Prepare `req` for many scans.
//
//	- A refusal is one `scan` gives every source, found before any is read. A refusal of the paths' routing
//	  comes from each scan, as from `scan`. Either way the `Prepared` is usable: its scans refuse as `scan`
//	  does.
//	- Allocates only what `scan` would, the storage for more than `MAX_PATH_QUERIES` names, with the
//	  request's allocator.
@(require_results)
prepare :: proc(req: ^Request($KINDS)) -> (p: Prepared(KINDS), err: Maybe(Request_Error)) {
	p.req = req
	if err = request_fault(nil, req, request_allocator(req)); err == nil {
		p.planned = prepared_plan(req)
	}
	return
}

// Plan `req` over every source whose root is an object (`PLAN_SRC`), the plan any other one's `scan`
// re-plans. False for a request with no such plan: one the tape route may answer, or one routing refuses
// (each scan then routes as `scan` does, and gives the refusal).
@(private = "file")
prepared_plan :: proc(req: ^Request($KINDS)) -> bool {
	plan_src := transmute([]byte)string(PLAN_SRC)
	// Inlined here, so `scan_request` stays their one call and inlines them too.
	return !#force_inline tape_routable(req) &&
		#force_inline route_paths(&req.route, plan_src, req.paths, req.duplicates, request_allocator(req), automaton_only(req)) == nil
}

@(private, require_results)
scan_prepared :: proc(src: []byte, p: ^Prepared($KINDS)) -> Scan_Error {
	req := p.req
	// `request_fault`'s one check of the source.
	fits := true
	when .Nodes in KINDS || .Dom in KINDS {
		fits = u64(len(src)) <= MAX_ROW_SOURCE
	}
	if p.planned && fits && route_rebase(&req.route, src) {
		req.route.kept = &p.kept
		defer req.route.kept = nil
		return scan_request(src, req, planned = true)
	}
	err := scan_request(src, req, planned = false)
	if p.planned {
		// A plan made again holds its keys anew.
		p.planned, p.kept.ok = prepared_plan(req), false
	}
	return err
}

// The automaton is the one engine a JSONC walk and a `.Refuse` walk carry.
@(private = "file")
automaton_only :: #force_inline proc(req: ^Request($KINDS)) -> bool {
	return req.dialect == .Jsonc || req.duplicates == .Refuse
}

// The public result of a walk that returned `fault` beside `verdict`.
@(private)
scan_error :: proc(verdict: Maybe(Error), fault: scan_pkg.Walk_Fault) -> Scan_Error {
	if fault.capacity != .None {
		return Request_Error{kind = .Over_Capacity, query_kind = .Path, capacity = fault.capacity}
	}
	if e, bad := verdict.?; bad {
		return e
	}
	if fault.oom {
		return Error{kind = .Out_Of_Memory}
	}
	return nil
}

// The walk the router's plan and `duplicates` pick for `$WALK`.
@(private = "file")
scan_routed :: #force_inline proc(src: []byte, req: ^Request($KINDS), $WALK: bit_set[scan_pkg.Walk_Kind], alloc: runtime.Allocator) -> scan_pkg.Walk_Fault {
	when .Path in WALK {
		// Which engines run is the plan's, decided per call. Each combination is its own walk.
		if req.route.matcher != .None {
			if req.route.n_auto > 0 {
				return scan_walk(src, req, WALK + {.Demand}, alloc)
			}
			return scan_walk(src, req, (WALK - {.Path}) + {.Demand}, alloc)
		}
	}
	// Built without its walks, `.Refuse` was refused before the scan (`request_fault`).
	when REFUSE_DUPLICATES {
		if req.duplicates == .Refuse {
			return scan_refuse(src, req, WALK, alloc)
		}
	}
	return scan_walk(src, req, WALK, alloc)
}

// Whether `Duplicates.Refuse` is compiled in. A build define (`-define:REFUSE_DUPLICATES=false`), not a name of
// the contract: its walks are a copy of each scan walk with the key check, dead weight in a program that
// never refuses (the CLI, as jq keeps the last of a repeated key). Built without, `scan` refuses a `.Refuse` request
// as `.Refuse_Compiled_Out` and `build` as `.Bad_Option`, before any byte is read. `unmarshal` keeps it.
@(private)
REFUSE_DUPLICATES :: #config(REFUSE_DUPLICATES, true)

// The walk of a `Duplicates.Refuse` scan. Out of line so `scan`'s other walks keep inlining. `.Refuse`
// requests are the rare case.
@(private = "file")
scan_refuse :: #force_no_inline proc(src: []byte, req: ^Request($KINDS), $WALK: bit_set[scan_pkg.Walk_Kind], alloc: runtime.Allocator) -> scan_pkg.Walk_Fault {
	// The walk keeps its spilled keys in `context.allocator`, given back on return.
	prev := context.allocator
	context.allocator = alloc
	defer context.allocator = prev
	return scan_walk(src, req, WALK + {.Unique}, alloc)
}

// Everything the walk cannot serve about `req` over `src`, found before anything is touched: the
// pre-flight. Each limit of `Capacity` is checked here, or in `route_paths` where the router's shapes
// decide it, so no refusal follows a write. The walk's own checks (`resolve_queries`) only restate these.
@(private = "file")
request_fault :: proc(src: []byte, req: ^Request($KINDS), alloc: runtime.Allocator) -> Maybe(Request_Error) {
	when !REFUSE_DUPLICATES {
		if req.duplicates == .Refuse {
			return Request_Error{kind = .Refuse_Compiled_Out}
		}
	}
	if req.strictness == .Lazy && req.duplicates != .First && req.duplicates != .Refuse {
		return Request_Error{kind = .Lazy_Needs_First}
	}
	when .Nodes in KINDS || .Dom in KINDS {
		if req.strictness == .Structural {
			return Request_Error{kind = .Nodes_Need_Strict, query_kind = .Dom if .Dom in KINDS else .Nodes}
		}
	}
	// `paths` and `.Path` in `$KINDS` come together.
	when .Path in KINDS {
		if len(req.paths) == 0 {
			return Request_Error{kind = .Query_Not_In_Set, query_kind = .Path}
		}
	} else {
		if len(req.paths) > 0 {
			return Request_Error{kind = .Query_Not_In_Set, query_kind = .Path}
		}
	}
	// A row's `u32` spans cannot address more: refused, not truncated.
	when .Nodes in KINDS || .Dom in KINDS {
		if u64(len(src)) > MAX_ROW_SOURCE {
			return Request_Error{kind = .Over_Capacity, query_kind = .Dom if .Dom in KINDS else .Nodes, capacity = .Node_Source_Bytes}
		}
	}
	return outputs_fault(req, len(req.paths) > 0, alloc)
}

// The first output the request owns that was made with another allocator than the request's, or none.
// `paths_used` says the walk will write `answers`. A fresh output has no allocator and agrees with any.
@(private = "file")
outputs_fault :: #force_inline proc(req: ^Request($KINDS), paths_used: bool, alloc: runtime.Allocator) -> Maybe(Request_Error) {
	mismatch :: proc(k: Query) -> Request_Error {
		return Request_Error{kind = .Allocator_Mismatch, query_kind = k}
	}
	if paths_used && !core_pkg.allocator_ok(req.answers.allocator, alloc) {
		return mismatch(.Path)
	}
	// The plan's spill arrays are bound together, so one speaks for all.
	if !core_pkg.allocator_ok(req.route.spill.keys.allocator, alloc) {
		return mismatch(.Path)
	}
	when .Nodes in KINDS || .Dom in KINDS {
		if !core_pkg.allocator_ok(req.doc.rows.allocator, alloc) {
			return mismatch(.Dom if .Dom in KINDS else .Nodes)
		}
	}
	// Decoded strings live in the document's arena.
	when .Dom in KINDS {
		if !core_pkg.allocator_ok(req.doc.values.allocator, alloc) || !core_pkg.allocator_ok(req.doc.arena.blocks.allocator, alloc) {
			return mismatch(.Dom)
		}
	}
	return nil
}
