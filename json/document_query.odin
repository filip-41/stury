package json

// The query walk: `query` and `query_in` append every value a path reaches inside one built document.

import "base:runtime"
import core_pkg "../core"
import "scan/walk"

// Append to `out` the answers `path` gives in `doc` from node `n` (`query` from the root), in document order: the answers a `.Path` scan gives under
// the default `.Last`, each `node` the value in `doc`.
//
//	- At most `path.limit` values are found (0 is every one).
//	- `Name` is `child` by key (the last duplicate), `Index` counts from the end when negative, `Any` takes
//	  every member, an object's repeated key once, at its first place with its last value, as jq reads it.
//	- A path with no `Any` step that does not land appends one `.Missing` or `.Type_Mismatch` answer, owned by
//	  the container it missed in; a `per_element` path answers each element a step does not apply to; any
//	  other path that does not land appends nothing.
//	- An empty path is `n` itself, owned by the container holding it, and `NO_NODE` or a document with no
//	  root gives nothing.
//	- Text that does not parse is `.Bad_Path` at the byte the parser stopped on; a path of more than
//	  `MAX_PATH_STEPS` steps, text or a built `Path`, is `.Over_Capacity` with nothing appended, as the scan and
//	  the edits refuse it.
//	- `.Out_Of_Memory` is `out` refusing to grow; the answers appended before that stay.
//	- Besides `out` it allocates only for a text longer than 256 bytes with an escaped quoted name, and for
//	  the keys of an object past QUERY_SMALL members that `Any` reads, both in the document's allocator and
//	  freed before return; a refusal there is `.Out_Of_Memory` too.
@(require_results)
query_in :: proc(doc: ^Document, n: Node, path: Path_Spec, out: ^[dynamic]Answer) -> (err: Maybe(Path_Error)) {
	when ODIN_DEBUG {
		core_pkg.check_node(doc, n)
	}
	buf: core_pkg.Path_Buf
	p := core_pkg.path_resolve(path, &buf, doc.rows.allocator) or_return
	defer delete(buf.heap, doc.rows.allocator)
	if !has(doc, n) {
		return nil
	}
	w := Query_Walk{doc = doc, mode = .Last, out = out, path = p, nodes = true}
	if !query_from(&w, n, holder_of(doc, n), p.steps) {
		return core_pkg.PATH_OUT_OF_MEMORY
	}
	return nil
}

// `query_in` from the root.
@(require_results)
query :: proc(doc: ^Document, path: Path_Spec, out: ^[dynamic]Answer) -> (err: Maybe(Path_Error)) {
	return query_in(doc, ROOT, path, out)
}

// The container holding `n`, `NO_NODE` for the root: the nearest row before it whose run covers it.
@(private = "file")
holder_of :: proc(doc: ^Document, n: Node) -> Node {
	for i := int(n) - 1; i >= 0; i -= 1 {
		if i + int(doc.rows[i].subtree_size) > int(n) {
			return Node(i)
		}
	}
	return NO_NODE
}

// A path's walk over a document: each answer goes to `out`, owned by the container it was met in, until `limit`
// more counted answers are wanted (`answer_cut`). `mode` is the occurrence of a repeated key that answers; under
// `.Last` a path with no `Any` step reads one branch. `nodes` keeps each found value's row in `node`.
@(private)
Query_Walk :: struct {
	doc:     ^Document,
	mode:    Duplicates,
	out:     ^[dynamic]Answer,
	path:    Path,
	query:   u32,
	nodes:   bool,
	counted: int,
}

@(private)
query_from :: proc(w: ^Query_Walk, n, holder: Node, steps: []Step) -> bool {
	if w.path.limit > 0 && w.counted >= w.path.limit {
		return true
	}
	doc := w.doc
	if len(steps) == 0 {
		return query_out(w, n, holder, .Found)
	}
	kd, _ := kind(doc, n)
	switch s in steps[0] {
	case Name:
		if kd != .Object {
			return query_fail(w, n, holder, steps, false, kd)
		}
		if w.mode == .Last {
			next := child(doc, n, string(s))
			if next == NO_NODE {
				return query_fail(w, n, holder, steps, true, kd)
			}
			return query_from(w, next, n, steps[1:])
		}
		it := members(doc, n)
		hit := false
		for k, c in members(&it) {
			if k != string(s) {
				continue
			}
			hit = true
			query_from(w, c, n, steps[1:]) or_return
			if w.mode == .First {
				return true
			}
		}
		if it.node < it.end {
			return false
		}
		return hit || query_fail(w, n, holder, steps, true, kd)
	case Index:
		if kd != .Array {
			return query_fail(w, n, holder, steps, false, kd)
		}
		next := child(doc, n, int(s))
		if next == NO_NODE {
			return query_fail(w, n, holder, steps, true, kd)
		}
		return query_from(w, next, n, steps[1:])
	case Any:
		if kd != .Object && kd != .Array {
			return query_fail(w, n, holder, steps, false, kd)
		}
		if kd == .Object && w.mode != .All {
			return query_distinct(w, n, steps[1:])
		}
		it := children(doc, n)
		for c in children(&it) {
			query_from(w, c, n, steps[1:]) or_return
		}
	}
	return true
}

// One answer, `n` met in `holder` (`NO_NODE` for a step that does not apply).
@(private = "file")
query_out :: proc(w: ^Query_Walk, n, holder: Node, outcome: Path_Outcome) -> bool {
	if core_pkg.answer_cut(w.path.limit, &w.counted, outcome, w.path.per_element) {
		return true
	}
	rows := w.doc.rows[:]
	a := Answer{owner = NO_OWNER if holder == NO_NODE else u64(rows[holder].lo), query = w.query, node = NO_NODE, outcome = outcome}
	if n != NO_NODE {
		a.lo, a.hi, a.kind = u64(rows[n].lo), u64(rows[n].hi), rows[n].kind
		a.node = n if w.nodes else NO_NODE
	}
	_, err := append(w.out, a)
	return err == nil
}

// `steps[0]` does not apply at `n`, a `met` held in `holder`: it `missed` its member or element there, or `n` is
// another kind. The path's one miss when it has no `Any` step, an answer of a `per_element` path, else nothing.
@(private = "file")
query_fail :: proc(w: ^Query_Walk, n, holder: Node, steps: []Step, missed: bool, met: Kind) -> bool {
	owner := n if missed else holder
	if w.path.per_element {
		return query_out(w, NO_NODE, owner, walk.per_element_outcome(steps, missed, met))
	}
	if !walk.steps_have_any(w.path.steps) {
		return query_out(w, NO_NODE, owner, .Missing if missed else .Type_Mismatch)
	}
	return true
}

// The members of object `n` that `Any` reads, `steps` next: a repeated key once, at its first place, with the
// first member's value under `.First` and the last's under `.Last`.
@(private = "file")
query_distinct :: proc(w: ^Query_Walk, n: Node, steps: []Step) -> bool {
	doc := w.doc
	count := child_count(doc, n)
	small: [QUERY_SMALL]Node
	names: [QUERY_SMALL]string
	picked := small[:]
	seen: map[string]int
	big := count > QUERY_SMALL
	defer if big {
		delete(picked, doc.rows.allocator)
		delete(seen)
	}
	if big {
		err: runtime.Allocator_Error
		if picked, err = make([]Node, count, doc.rows.allocator); err != nil {
			return false
		}
		if seen, err = make(map[string]int, count, doc.rows.allocator); err != nil {
			return false
		}
	}
	kept := 0
	it := members(doc, n)
	for k, c in members(&it) {
		at := -1
		if big {
			at = seen[k] - 1
		} else {
			for i in 0 ..< kept {
				if names[i] == k {
					at = i
					break
				}
			}
		}
		if at < 0 {
			picked[kept] = c
			if big {
				seen[k] = kept + 1
			} else {
				names[kept] = k
			}
			kept += 1
		} else if w.mode == .Last {
			picked[at] = c
		}
	}
	if it.node < it.end {
		return false
	}
	for c in picked[:kept] {
		query_from(w, c, n, steps) or_return
	}
	return true
}

// The members `query_distinct` tells apart on the stack; an object with more keeps them in a map.
@(private = "file")
QUERY_SMALL :: 16
