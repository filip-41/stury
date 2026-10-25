package json

// The wildcard route: a `.First` or `.Last` path through `Any` reads an object's repeated key as one member, at
// its first place, as jq does. The scan walks answer every occurrence, so a walk that meets an object an `Any`
// step reads counts it (`Route.unresolved`) and the paths with an `Any` step are answered again from the tape,
// which holds the keys. The paths without one keep the walk's answers.

import "base:runtime"
import "scan/walk"

// Answer the `Any` paths of `req` from its rows, building them first when `$KINDS` holds none. The build is
// `.Strict`. A document it refuses (one a `.Structural` or `.Lazy` walk passed) keeps the walk's answers and
// result, which settled no repeat.
@(private)
settle_wild :: proc(src: []byte, req: ^Request($KINDS), alloc: runtime.Allocator) -> Maybe(Error) {
	if u64(len(src)) > MAX_ROW_SOURCE {
		return Error{kind = .Over_Capacity}
	}
	// The walk's answers for the paths the tape does not answer.
	kept := make([dynamic]Path_Answer, 0, len(req.answers), alloc)
	defer delete(kept)
	for a in req.answers {
		if !walk.steps_have_any(req.paths[a.query].steps) {
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
	req.state.groups.grouped = false
	walk.adopt_allocator(&req.answers, alloc)
	if _, err := append(&req.answers, ..kept[:]); err != nil {
		return Error{kind = .Out_Of_Memory}
	}
	nodes := make([dynamic]Node, alloc)
	holders := make([dynamic]Node, alloc)
	outcomes := make([dynamic]Path_Outcome, alloc)
	defer delete(nodes)
	defer delete(holders)
	defer delete(outcomes)
	for p, i in req.paths {
		if !walk.steps_have_any(p.steps) {
			continue
		}
		clear(&nodes)
		clear(&holders)
		clear(&outcomes)
		if !wild_path_answers(req, p, i, &nodes, &holders, &outcomes) {
			return Error{kind = .Out_Of_Memory}
		}
	}
	return nil
}

// Build `req.doc.rows` for `settle_wild`. `done` says the settling ends here with `result`: the build's own
// refusal, or nil when the document is one the build refuses and the walk's answers stand.
@(private = "file")
wild_build_rows :: proc(src: []byte, req: ^Request($KINDS), alloc: runtime.Allocator) -> (done: bool, result: Maybe(Error)) {
	// The build walks without the plan, which a prepared request keeps for its next scan.
	route, strictness := req.state.route, req.strictness
	verdict, coverage, stop := req.state.verdict, req.coverage, req.stop
	defer req.state.route.matcher, req.state.route.n_auto, req.state.route.gate.gated = route.matcher, route.n_auto, route.gate.gated
	req.strictness = .Strict
	fault := scan_rows(src, req, alloc)
	req.strictness = strictness
	// The bytes the build validated are its own reading, needed to answer the wildcard paths from rows: the
	// request's result covers what its walk read, as when the build refuses the document.
	req.coverage, req.stop = coverage, stop
	// The first of several texts builds whole, and `.Trailing` is the scan's own result.
	if e, bad := scan_error(req.state.verdict, fault).?; bad {
		if e.kind == .Over_Capacity || e.kind == .Out_Of_Memory {
			return true, e
		}
		if e.kind != .Trailing {
			req.state.verdict = verdict
			return true, nil
		}
	}
	return false, nil
}

// Append the answers of path `p` (index `i`, with an `Any` step) read from the rows. False when an output
// could not grow. `nodes`, `holders` and `outcomes` are the caller's scratch, emptied for this path.
@(private = "file")
wild_path_answers :: proc(req: ^Request($KINDS), p: Path, i: int, nodes, holders: ^[dynamic]Node, outcomes: ^[dynamic]Path_Outcome) -> bool {
	w := Query_Walk{
		doc = &req.doc, mode = req.duplicates, out = nodes, holders = holders, left = p.limit if p.limit > 0 else max(int),
		outcomes = outcomes if p.per_element else nil,
	}
	if !query_from(&w, ROOT, NO_NODE, p.steps) {
		return false
	}
	for n, j in nodes {
		owner := walk.NO_OWNER if holders[j] == NO_NODE else u64(req.doc.rows[holders[j]].lo)
		found := Path_Answer{owner = owner, query = u32(i), node = NO_NODE, outcome = .Found if n != NO_NODE else outcomes[j]}
		if n != NO_NODE {
			row := req.doc.rows[n]
			found.lo, found.hi, found.kind = u64(row.lo), u64(row.hi), row.kind
			found.node = n if .Nodes in KINDS || .Dom in KINDS else NO_NODE
		}
		if _, err := append(&req.answers, found); err != nil {
			return false
		}
	}
	return true
}
