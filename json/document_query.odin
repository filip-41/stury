package json

// The query walk: `query` appends every value a path reaches inside one built document.

import "base:runtime"
import core_pkg "../core"
import "core:strings"
import "scan/walk"

// Append to `out` every value `path` reaches from `n`, in document order: the values a `.Path` scan finds
// under the default `.Last`.
//
//	- At most `path.limit` values are appended (0 is every one).
//	- `Name` is `child` by key (the last duplicate), `Index` counts from the end when negative, `Any` takes
//	  every member, an object's repeated key once, at its first place with its last value, as jq reads it,
//	  and a step that does not land yields nothing.
//	- An empty path is `n` itself, and `NO_NODE` reaches nothing.
//	- Text that does not parse is `.Bad_Path` at the byte the parser stopped on; a path of more than
//	  `MAX_PATH_STEPS` steps, text or a built `Path`, is `.Over_Capacity` with nothing appended, as the scan and
//	  the edits refuse it.
//	- `.Out_Of_Memory` is `out` refusing to grow; the values appended before that stay.
//	- Besides `out` it allocates only for a text longer than 256 bytes with an escaped quoted name, and for
//	  the keys of an object past QUERY_SMALL members that `Any` reads, both in the document's allocator and
//	  freed before return; a refusal there is `.Out_Of_Memory` too.
@(require_results)
query :: proc(doc: ^Document, n: Node, path: Path_Spec, out: ^[dynamic]Node) -> (err: Maybe(Path_Error)) {
	when ODIN_DEBUG {
		check_node(doc, n)
	}
	steps: [core_pkg.MAX_PATH_STEPS]Step
	stack: [SCRATCH_BYTES]u8 = ---
	text, is_text := path.(string)
	heap := len(text) > len(stack) && strings.index_byte(text, '\\') >= 0
	names := make([]u8, len(text), doc.rows.allocator) if heap else stack[:]
	if names == nil {
		return core_pkg.PATH_OUT_OF_MEMORY
	}
	defer if heap {
		delete(names, doc.rows.allocator)
	}
	p, _ := path.(Path)
	if is_text {
		p = parse_path(text, steps[:], names) or_return
	} else if len(p.steps) > core_pkg.MAX_PATH_STEPS {
		return Path_Error{kind = .Over_Capacity}
	}
	if !has(doc, n) {
		return nil
	}
	w := Query_Walk{doc = doc, mode = .Last, out = out, limit = p.limit}
	if !query_from(&w, n, NO_NODE, p.steps) {
		return core_pkg.PATH_OUT_OF_MEMORY
	}
	return nil
}

// A path's walk over a document: the values reached go to `out`, each beside the container it was met in (`NO_NODE`
// for the root) when `holders` is not nil, until `limit` more counted answers are wanted (0: every one).
// `mode` is the occurrence of a repeated key that answers. With `outcomes`, the walk answers as a `per_element`
// path does: a step that does not apply is an answer too, `NO_NODE` in `out` beside the container that lacks
// its member or holds the value it met, and `outcomes` holds each answer's `Path_Outcome`.
@(private)
Query_Walk :: struct {
	doc:      ^Document,
	mode:     Duplicates,
	out:      ^[dynamic]Node,
	holders:  ^[dynamic]Node,
	outcomes: ^[dynamic]Path_Outcome,
	// The `Path.limit` and the counted answers written so far (`answer_cut`).
	limit:    int,
	counted:  int,
}

@(private)
query_from :: proc(w: ^Query_Walk, n, holder: Node, steps: []Step) -> bool {
	if w.limit > 0 && w.counted >= w.limit {
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
		it := members_of(doc, n)
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

// One answer, `n` met in `holder` (`NO_NODE` for a step that does not apply, under `outcomes`).
@(private = "file")
query_out :: proc(w: ^Query_Walk, n, holder: Node, outcome: Path_Outcome) -> bool {
	if core_pkg.answer_cut(w.limit, &w.counted, outcome, w.outcomes != nil) {
		return true
	}
	if _, err := append(w.out, n); err != nil {
		return false
	}
	if w.holders != nil {
		if _, err := append(w.holders, holder); err != nil {
			return false
		}
	}
	if w.outcomes != nil {
		if _, err := append(w.outcomes, outcome); err != nil {
			return false
		}
	}
	return true
}

// `steps[0]` does not apply at `n`, a `met` held in `holder`: it `missed` its member or element there, or `n` is
// another kind. Nothing, but for a `per_element` walk (`outcomes`), which answers it as the scan does.
@(private = "file")
query_fail :: proc(w: ^Query_Walk, n, holder: Node, steps: []Step, missed: bool, met: Kind) -> bool {
	if w.outcomes == nil {
		return true
	}
	return query_out(w, NO_NODE, n if missed else holder, walk.per_element_outcome(steps, missed, met))
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
	it := members_of(doc, n)
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
