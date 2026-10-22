package json

// The wildcard route: a `.First` or `.Last` path through `Any` reads an object's repeated key as one member, at
// its first place, as jq does. The scan walks answer every occurrence, so a walk that meets an object an `Any`
// step reads counts it (`Route.unresolved`) and the paths with an `Any` step are answered again from the tape,
// which holds the keys. The paths without one keep the walk's answers.

import "base:runtime"
import core_pkg "../core"

// Answer the `Any` paths of `req` from its rows, building them first when `$Q` holds none. The build is
// `.Strict`. A document it refuses (one a `.Structural` or `.Lazy` walk passed) keeps the walk's answers and
// result, which settled no repeat.
@(private)
settle_wild :: proc(src: []byte, req: ^Request($Q), alloc: runtime.Allocator) -> Scan_Error {
	if u64(len(src)) > MAX_ROW_SOURCE {
		return Request_Error{kind = .Over_Capacity, query_kind = .Path, capacity = .Node_Source_Bytes}
	}
	// The walk's answers for the paths the tape does not answer.
	kept := make([dynamic]Path_Answer, 0, len(req.answers), alloc)
	defer delete(kept)
	for a in req.answers {
		if !path_has_any(req.paths[a.query].steps) {
			append(&kept, a)
		}
	}
	// The rows are this call's scratch: a request that did not ask for them holds none.
	rows_asked :: .Nodes in Q || .Dom in Q
	defer if !rows_asked {
		clear(&req.doc.rows)
	}
	when !rows_asked {
		// The build walks without the plan, which a prepared request keeps for its next scan.
		route, strictness := req.route, req.strictness
		verdict, coverage, stop := req.verdict, req.coverage, req.stop
		defer req.route.matcher, req.route.n_auto, req.route.gate.gated = route.matcher, route.n_auto, route.gate.gated
		req.strictness = .Strict
		fault := scan_rows(src, req, alloc)
		req.strictness = strictness
		// The first of several texts builds whole, and `.Trailing` is the scan's own result.
		if err := scan_error(req.verdict, fault); err != nil {
			e, is_fault := err.(Error)
			if !is_fault || e.kind == .Out_Of_Memory {
				return err
			}
			if e.kind != .Trailing {
				req.verdict, req.coverage, req.stop = verdict, coverage, stop
				return nil
			}
		}
	}
	clear(&req.answers)
	req.src, req.stop, req.coverage = src, nil, .Full
	req.groups.grouped = false
	core_pkg.adopt_allocator(&req.answers, alloc)
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
		if !path_has_any(p.steps) {
			continue
		}
		clear(&nodes)
		clear(&holders)
		clear(&outcomes)
		w := Query_Walk{
			doc = &req.doc, mode = req.duplicates, out = &nodes, holders = &holders, left = p.limit if p.limit > 0 else max(int),
			outcomes = &outcomes if p.per_element else nil,
		}
		if !query_from(&w, ROOT, NO_NODE, p.steps) {
			return Error{kind = .Out_Of_Memory}
		}
		for n, j in nodes {
			owner := core_pkg.NO_OWNER if holders[j] == NO_NODE else u64(req.doc.rows[holders[j]].lo)
			found := Path_Answer{owner = owner, query = u32(i), node = NO_NODE, outcome = .Found if n != NO_NODE else outcomes[j]}
			if n != NO_NODE {
				row := req.doc.rows[n]
				found.lo, found.hi, found.kind = u64(row.lo), u64(row.hi), row.kind
				found.node = n if .Nodes in Q || .Dom in Q else NO_NODE
			}
			if _, err := append(&req.answers, found); err != nil {
				return Error{kind = .Out_Of_Memory}
			}
		}
	}
	return nil
}

// Whether `steps` has an `Any` step, whose answers the tape settles.
@(private = "file")
path_has_any :: proc(steps: []Step) -> bool {
	for st in steps {
		if _, is_any := st.(Any); is_any {
			return true
		}
	}
	return false
}
