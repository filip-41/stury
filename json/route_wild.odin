package json

// The wildcard route: a `.First` or `.Last` path through `Any` reads an object's repeated key as one member, at
// its first place, as jq does. The scan walks answer every occurrence, so a walk that meets an object an `Any`
// step reads counts it (`Route.unresolved`) and the paths with an `Any` step are answered again from the tape,
// which holds the keys. The paths without one keep the walk's answers.

import "base:runtime"
import core_pkg "../core"
import "scan/walk"

// Answer the `Any` paths of `req` from its rows, building them first when `$KINDS` holds none. The build is
// `.Strict`. A document it refuses (one a `.Structural` or `.Lazy` walk passed) keeps the walk's answers and
// result, which settled no repeat.
@(private)
settle_wild :: proc(src: []byte, req: ^Request($KINDS), alloc: runtime.Allocator) -> Maybe(Path_Error) {
	if u64(len(src)) > MAX_ROW_SOURCE {
		return Path_Error{kind = .Over_Capacity}
	}
	// The walk's answers for the paths the tape does not answer.
	kept := make([dynamic]Answer, 0, len(req.answers), alloc)
	defer delete(kept)
	for a in req.answers {
		if !walk.steps_have_any(req.inputs.paths[a.query].steps) {
			append(&kept, a)
		}
	}
	// The rows are this call's scratch: a request that did not ask for them holds none.
	rows_asked :: .Nodes in KINDS || .Dom in KINDS
	defer if !rows_asked {
		clear(&req.doc.rows)
	}
	when !rows_asked {
		if done, result := wild_build_rows(src, req, alloc); done {
			return result
		}
	}
	clear(&req.answers)
	// The walk's coverage and stop stand: the settling build answered the wildcard paths, it did not replace
	// the request's own reading.
	req.state.src = src
	req.groups.grouped = false
	walk.adopt_allocator(&req.answers, alloc)
	if _, err := append(&req.answers, ..kept[:]); err != nil {
		return core_pkg.PATH_OUT_OF_MEMORY
	}
	for p, i in req.inputs.paths {
		if !walk.steps_have_any(p.steps) {
			continue
		}
		// The rows are scratch unless the request asked for them, so only then does an answer name its node.
		w := core_pkg.Query_Walk{doc = &req.doc, mode = req.inputs.read.duplicates, out = &req.answers, path = p, query = u32(i), nodes = rows_asked}
		if !core_pkg.query_from(&w, ROOT, NO_NODE, p.steps) {
			return core_pkg.PATH_OUT_OF_MEMORY
		}
	}
	return nil
}

// Build `req.doc.rows` for `settle_wild`. `done` says the settling ends here with `result`: the build's own
// refusal, or nil when the document is one the build refuses and the walk's answers stand.
@(private = "file")
wild_build_rows :: proc(src: []byte, req: ^Request($KINDS), alloc: runtime.Allocator) -> (done: bool, result: Maybe(Path_Error)) {
	// The build walks without the plan, which a prepared request keeps for its next scan.
	route, strictness := req.state.route, req.inputs.read.strictness
	verdict, coverage, stop := req.state.verdict, req.state.coverage, req.state.stop
	defer req.state.route.matcher, req.state.route.n_auto, req.state.route.gate.gated = route.matcher, route.n_auto, route.gate.gated
	req.inputs.read.strictness = .Strict
	fault := scan_rows(src, req, alloc)
	req.inputs.read.strictness = strictness
	// The bytes the build validated are its own reading, needed to answer the wildcard paths from rows: the
	// request's result covers what its walk read, as when the build refuses the document.
	req.state.coverage, req.state.stop = coverage, stop
	// The first of several texts builds whole, and `.Trailing` is the scan's own result.
	if e, bad := scan_error(req.state.verdict, fault).?; bad {
		if e.kind == .Over_Capacity || e.kind == .Out_Of_Memory {
			return true, e
		}
		if e.kind != .Bad_Source || e.syntax != .Trailing {
			req.state.verdict = verdict
			return true, nil
		}
	}
	return false, nil
}
