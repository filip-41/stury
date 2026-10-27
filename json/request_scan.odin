package json

// `scan` and `prepare`: the request checked, routed, and handed to the walk (request_walk.odin).

import "base:runtime"
import core_pkg "../core"
import "scan/walk"
import scan_pkg "scan"

// Scan `src` for what the request asks and fill its outputs. A request `prepare` planned skips the setup that
// does not depend on the source, with the same result, refusal and outputs.
//
//	- Returns nil when the text is valid over what the scan visited (`Request.coverage`).
//	- An `Error` is the text's fault, or `.Out_Of_Memory` when an output could not grow (a text fault comes
//	  first).
//	- A refusal before any byte is read leaves the outputs untouched: `.Bad_Option` for options the request
//	  cannot take together (`Request`), an output made with another allocator than the request's, or
//	  `Duplicates.Refuse` in a build with `-define:REFUSE_DUPLICATES=false`; `.Over_Capacity` past a fixed
//	  limit; `.Source_Too_Wide` for a `.Nodes`/`.Dom` source past `MAX_ROW_SOURCE`; `.Out_Of_Memory` for the
//	  request's own storage.
//
// Out of line, so a call site holds one call whichever way the request scans.
@(require_results)
scan :: #force_no_inline proc(src: []byte, req: ^Request($KINDS)) -> Maybe(Error) {
	if req.state.planned {
		return scan_prepared(src, req)
	}
	return scan_request(src, req, planned = false)
}

// `planned`: the request holds its plan for `src` already (`prepare`), so the checks and the routing are
// skipped. One body for both, so a program's scans share one copy of the walks.
@(private = "file")
scan_request :: #force_no_inline proc(src: []byte, req: ^Request($KINDS), planned: bool) -> Maybe(Error) {
	alloc := core_pkg.request_allocator(req)
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
		// `.Refuse` and dialect walks serve every path through the automaton (`automaton_forced`), so no matcher
		// is planned.
		forced := automaton_forced(req.dialect, req.duplicates) || req.state.route.walk_repeats
		if !forced && tape_routable(req) && scan_tape(src, req, alloc) {
			return nil
		}
		if err, refused := route_paths(&req.state.route, src, req.paths, req.duplicates, alloc, forced).?; refused {
			return err
		}
	}
	req.state.src, req.state.verdict, req.coverage, req.stop = src, nil, .Partial, nil
	req.groups.grouped = false
	req.state.route.unresolved, req.state.route.repeat_at = false, 0
	err := scan_error(req.state.verdict, scan_routed(src, req, WALK, alloc))
	if req.state.route.unresolved && !req.state.route.every_member && (req.duplicates == .First || req.duplicates == .Last) {
		// A text another follows was read whole and answered (`.Trailing`), so its answers are settled too.
		if e, faulted := err.?; !faulted || e.kind == .Trailing {
			if settled := settle_wild(src, req, alloc); settled != nil {
				return settled
			}
		}
	}
	return err
}

// Plan `req` once for the scans of many sources, such as the records of a stream: each `scan` of it then skips
// the setup that does not depend on the source.
//
//	- A refusal is one `scan` gives every source, found before any is read. A refusal of the paths' routing
//	  comes from each scan, as from `scan`. Either way the request is usable: its scans refuse as `scan`
//	  does.
//	- The request's inputs must not change while it is planned (prepare again after). `request_init`
//	  drops the plan, and `destroy` frees it with the rest.
//	- Allocates only what `scan` would, the storage for more than `MAX_PATH_QUERIES` names, with the
//	  request's allocator.
@(require_results)
prepare :: proc(req: ^Request($KINDS)) -> Maybe(Error) {
	req.state.planned, req.state.kept.ok = false, false
	err := request_fault(nil, req, core_pkg.request_allocator(req))
	if err == nil {
		req.state.planned = prepared_plan(req)
	}
	return err
}

// Plan `req` over every source whose root is an object (`PLAN_SRC`), the plan any other one's `scan`
// re-plans. False for a request with no such plan: one the tape route may answer, or one routing refuses
// (each scan then routes as `scan` does, and gives the refusal).
@(private = "file")
prepared_plan :: proc(req: ^Request($KINDS)) -> bool {
	plan_src := transmute([]byte)string(PLAN_SRC)
	// Inlined here, so `scan_request` stays their one call and inlines them too.
	return !#force_inline tape_routable(req) &&
		#force_inline route_paths(&req.state.route, plan_src, req.paths, req.duplicates, core_pkg.request_allocator(req), automaton_forced(req.dialect, req.duplicates)) == nil
}

@(private = "file", require_results)
scan_prepared :: proc(src: []byte, req: ^Request($KINDS)) -> Maybe(Error) {
	// `request_fault`'s one check of the source.
	fits := true
	when .Nodes in KINDS || .Dom in KINDS {
		fits = u64(len(src)) <= MAX_ROW_SOURCE
	}
	if fits && route_rebase(&req.state.route, src) {
		req.state.route.kept = &req.state.kept
		defer req.state.route.kept = nil
		return scan_request(src, req, planned = true)
	}
	err := scan_request(src, req, planned = false)
	// A plan made again holds its keys anew.
	req.state.planned, req.state.kept.ok = prepared_plan(req), false
	return err
}

// The public result of a walk that returned `fault` beside `verdict`.
@(private)
scan_error :: proc(verdict: Maybe(Error), fault: scan_pkg.Walk_Fault) -> Maybe(Error) {
	if fault.capacity != .None {
		return Error{kind = .Over_Capacity}
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
		if req.state.route.matcher != .None {
			if req.state.route.n_auto > 0 {
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
// never refuses (the CLI, as jq keeps the last of a repeated key). Built without, `scan` and `build` refuse a
// `.Refuse` request as `.Bad_Option`, before any byte is read. `unmarshal` keeps it.
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
// pre-flight. Each limit of `walk.Capacity` is checked here, or in `route_paths` where the router's shapes
// decide it, so no refusal follows a write. The walk's own checks (`resolve_queries`) only restate these.
@(private = "file")
request_fault :: proc(src: []byte, req: ^Request($KINDS), alloc: runtime.Allocator) -> Maybe(Error) {
	BAD_OPTION :: Error{kind = .Bad_Option}
	// Every scan and `prepare` pass through this check, so no walk sees `.Default`.
	req.duplicates = core_pkg.duplicates_or(req.duplicates, .Last)
	when !REFUSE_DUPLICATES {
		if req.duplicates == .Refuse {
			return BAD_OPTION
		}
	}
	if req.strictness == .Lazy && req.duplicates != .First && req.duplicates != .Refuse {
		return BAD_OPTION
	}
	when .Nodes in KINDS || .Dom in KINDS {
		if req.strictness == .Structural {
			return BAD_OPTION
		}
	}
	// `paths` and `.Path` in `$KINDS` come together.
	when .Path in KINDS {
		if len(req.paths) == 0 {
			return BAD_OPTION
		}
	} else {
		if len(req.paths) > 0 {
			return BAD_OPTION
		}
	}
	// A row's `u32` spans cannot address more: refused, not truncated.
	when .Nodes in KINDS || .Dom in KINDS {
		if u64(len(src)) > MAX_ROW_SOURCE {
			return Error{kind = .Source_Too_Wide, offset = MAX_ROW_SOURCE}
		}
	}
	return outputs_fault(req, len(req.paths) > 0, alloc)
}

// The first output the request owns that was made with another allocator than the request's, or none.
// `paths_used` says the walk will write `answers`. A fresh output has no allocator and agrees with any.
@(private = "file")
outputs_fault :: #force_inline proc(req: ^Request($KINDS), paths_used: bool, alloc: runtime.Allocator) -> Maybe(Error) {
	MISMATCH :: Error{kind = .Bad_Option}
	if paths_used && !walk.allocator_ok(req.answers.allocator, alloc) {
		return MISMATCH
	}
	// The plan's spill arrays are bound together, so one speaks for all.
	if !walk.allocator_ok(req.state.route.spill.keys.allocator, alloc) {
		return MISMATCH
	}
	when .Nodes in KINDS || .Dom in KINDS {
		if !walk.allocator_ok(req.doc.rows.allocator, alloc) {
			return MISMATCH
		}
	}
	// The read cache is made in the rows' allocator, so their check covers it.
	when .Dom in KINDS {
		if !walk.allocator_ok(req.doc.values.allocator, alloc) {
			return MISMATCH
		}
	}
	return nil
}

// The whole-document result over the bytes the last scan read. `nil` is the only claim "this document is
// valid".
//
//	- A no-op when that scan covered them (`coverage == .Full`, no stop), else a `.Strict` re-walk under the
//	  request's limits.
//	- A refused scan covered nothing.
//	- The result is committed to the request: `coverage` becomes `.Full`, `stop` nil, so a second call is
//	  the no-op.
//	- Under `Duplicates.Refuse` the re-walk refuses a repeated key too. A refused spill of its keys is
//	  `.Out_Of_Memory` at offset 0.
@(require_results)
validate_remaining :: proc(req: ^Request($KINDS)) -> Maybe(Error) {
	// The key check keeps its spilled keys in `context.allocator`, as `scan` does, given back
	// on return.
	prev := context.allocator
	context.allocator = core_pkg.request_allocator(req)
	defer context.allocator = prev
	err, validity := scan_pkg.validate_remaining(req.state.src, req.state.verdict, req.coverage, req.stop, req.limits, REFUSE_DUPLICATES && req.duplicates == .Refuse)
	req.state.verdict, req.coverage, req.stop = err, validity, nil
	return err
}
