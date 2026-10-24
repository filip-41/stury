package json

// The router: `scan` sends each path of a request to the engine that serves its shape, at runtime and
// once per call. Both engines are the walk's own, and the router only chooses and translates.
//
//	path automaton   every path the demand matcher does not take: the general matcher. A path without
//	                 `Any` owes `Missing` and `Type_Mismatch`. A path with one answers once per match, or
//	                 once per element under `per_element`, which only the automaton serves
//	demand matcher   a column path `Any^k Name` (every record's member at one depth), plain
//	                 single-name paths over a root object, and gated columns `(Name|Any)+ Name`
//	                 (`.logs[].id`: a column under named members) when they are the request's only
//	                 paths
//
// The automaton is bounded: `MAX_PATH_QUERIES` paths of at most `MAX_PATH_STEPS` steps each, refused as
// `Over_Capacity` before the walk. The demand matcher is not: any number of keys, a
// column of any depth, bounded only by the document. A request that fits the common case, at most
// `MAX_ROUTED` matcher keys, plans into the arrays of `Route`. A longer one spills into request-owned
// storage.

import "base:runtime"
import "core:slice"
import core_pkg "../core"
import "scan/walk"
import scan_pkg "scan"

// Compile every single-name path and column to the automaton, so a test document is checked across both
// engines. A build define (`-define:FORCE_AUTOMATON=true`), not a name of the contract: a test package reads it
// with its own `#config`.
@(private)
FORCE_AUTOMATON :: #config(FORCE_AUTOMATON, false)

@(private = "file")
MAX_ROUTED :: walk.MAX_PATH_QUERIES

@(private)
Route_Matcher :: enum u8 {
	None, // every path runs on the automaton
	Slots, // plain single-name paths over a root object: one slot per key, `Missing` owed after the walk
	Names, // the same paths under `.All`: rows as for `.Rows`, then `Missing` owed after the walk
	Rows, // a column: one row per matched member, written into `Request.answers` by the walk
}

// One call's plan, kept on the `Request` so routing allocates and zeroes nothing in steady state.
@(private)
Route :: struct {
	matcher:   Route_Matcher,
	// Anything with a `limit` is truncated after the walk.
	any_limit: bool,
	n_keys:    int,
	n_auto:    int,
	// The matcher's depth (`Demand_Spec.depth`) and, for slots, the root object's offset.
	depth:     u64,
	root_lo:   u64,
	// A gated column's names and the walk's state (`Demand_Spec.gate`). `gate.gated` is zero for any
	// other plan.
	gate:      walk.Demand_Gate,
	// The paths the automaton runs, as indices into `Request.paths`, ascending. At most `MAX_ROUTED`:
	// the automaton's own bound.
	auto:      [MAX_ROUTED]u32,
	// The matcher's keys: `row_keys[i].tag` is the path key i answers, in rows or in slots.
	// Read them through `route_store`: past `MAX_ROUTED` they live in `spill`.
	keys:      [MAX_ROUTED]string,
	row_keys:  [MAX_ROUTED]walk.Demand_Row_Key,
	fields:    [MAX_ROUTED]walk.Field_Value,
	spill:     Route_Spill,
	// Whether the last walk met an object a `.First` or `.Last` `Any` step must resolve key by key
	// (`settle_wild`).
	unresolved:   bool,
	// Set by the edits, whose scans want every entry of an object, a repeated key's too: `Any` then reads them
	// all whatever `duplicates` says.
	every_member: bool,
	// The walk's resolution a prepared scan keeps for the next (`prepare`), set only for its scan.
	kept:      ^walk.Resolved_Queries,
}

// What a plan holds past `MAX_ROUTED`, allocated with the request's allocator, resized per call and
// freed by `route_destroy`. The three arrays of a call that spills have `n_keys` elements and the inline
// ones go unused. `counts` is each path's answers so far under a `limit`.
@(private)
Route_Spill :: struct {
	keys:      [dynamic]string,
	row_keys:  [dynamic]walk.Demand_Row_Key,
	fields:    [dynamic]walk.Field_Value,
	counts:    [dynamic]int,
}

// The matcher's per-key arrays for a plan of `n` keys: the inline ones, or the spill's.
@(private)
Route_Store :: struct {
	keys:      []string,
	row_keys:  []walk.Demand_Row_Key,
	fields:    []walk.Field_Value,
}

@(private)
route_store :: #force_inline proc(plan: ^Route, n: int) -> Route_Store {
	if n > MAX_ROUTED {
		s := &plan.spill
		return {s.keys[:n], s.row_keys[:n], s.fields[:n]}
	}
	return {plan.keys[:n], plan.row_keys[:n], plan.fields[:n]}
}

@(private)
route_destroy :: proc(plan: ^Route) {
	s := &plan.spill
	delete(s.keys)
	delete(s.row_keys)
	delete(s.fields)
	delete(s.counts)
}

// Size one spill array to `n` elements under `alloc`. The pre-flight (`outputs_fault`) has agreed the
// allocator, so adopting it only binds an array that has none yet.
@(private = "file")
spill_to :: proc(arr: ^[dynamic]$T, n: int, alloc: runtime.Allocator) -> bool {
	walk.adopt_allocator(arr, alloc)
	return resize(arr, n) == nil
}

// How a path is served, from its steps alone.
@(private)
Path_Shape :: enum u8 {
	Automaton,
	Single_Name, // `Name`
	Column, // `Any^k Name`, k >= 1
	Gated_Column, // `(Name|Any)+ Name` with both a `Name` and an `Any` before the last step, at most
	              // `MAX_PATH_STEPS` steps: `.logs[].id`
}

// The shape of path `p`, and for a column its wildcard count: a `per_element` path, which owes its misses, is
// the automaton's. A one-step path, the common one, reads one step.
@(private)
path_shape :: #force_inline proc(p: Path) -> (shape: Path_Shape, wild: int) {
	steps := p.steps
	n := len(steps)
	for wild < n {
		if _, is_any := steps[wild].(Any); !is_any {
			break
		}
		wild += 1
	}
	ends_named := false
	if n > 0 {
		_, ends_named = steps[n - 1].(Name)
	}
	switch {
	case wild == 0 && n == 1 && ends_named:  return .Single_Name, 0
	case wild == n - 1 && ends_named && n > 1 && !p.per_element: return .Column, wild
	case !ends_named || n > core_pkg.MAX_PATH_STEPS || p.per_element: return .Automaton, wild
	}
	has_any, has_name := false, false
	for st in steps[:n - 1] {
		switch _ in st {
		case Any:   has_any = true
		case Name:  has_name = true
		case Index: return .Automaton, wild
		}
	}
	if has_any && has_name {
		return .Gated_Column, 0
	}
	return .Automaton, wild
}

// Whether two gated columns share every step before their last: one gate serves both.
@(private)
same_gate :: proc(a, b: []Step) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) - 1 {
		na, a_named := a[i].(Name)
		nb, b_named := b[i].(Name)
		if a_named != b_named || na != nb {
			return false
		}
	}
	return true
}

// The offset of the root value when it is an object, past a BOM and whitespace. A document that opens on
// its brace, the common one, skips the scan.
@(private = "file")
root_object :: #force_inline proc(src: []byte) -> (lo: u64, ok: bool) {
	if len(src) > 0 && src[0] == '{' {
		return 0, true
	}
	return root_object_padded(src)
}

@(private = "file")
root_object_padded :: #force_no_inline proc(src: []byte) -> (lo: u64, ok: bool) {
	i := scan_pkg.bom_len(src)
	for i < len(src) && walk.is_space(src[i]) {
		i += 1
	}
	return u64(i), i < len(src) && src[i] == '{'
}

// What a plan reads of a source is whether its root is an object (`root_object`), so one made over `PLAN_SRC`
// serves every source whose root is: a prepared plan (`prepare`).
@(private)
PLAN_SRC :: "{"

// Whether a plan made over `PLAN_SRC` serves `src`, re-based onto it: only a plan of root names holds anything
// of its source, the root's offset.
@(private)
route_rebase :: #force_inline proc(plan: ^Route, src: []byte) -> bool {
	if plan.matcher != .Slots && plan.matcher != .Names {
		return true
	}
	lo, is_object := root_object(src)
	plan.root_lo = lo
	return is_object
}

// The common request, every path one name over a root object, planned in one pass: the slots' keys in path
// order, each row key only its tag. False (the plan's keys are then scratch) when some path or the root is another shape.
@(private = "file")
route_all_named :: proc(plan: ^Route, src: []byte, paths: []Path) -> bool {
	lo, is_object := root_object(src)
	if !is_object {
		return false
	}
	for p, i in paths {
		if len(p.steps) != 1 {
			return false
		}
		name, is_name := p.steps[0].(Name)
		if !is_name {
			return false
		}
		plan.keys[i] = string(name)
		plan.row_keys[i].tag = u32(i)
	}
	plan.matcher = .Slots
	plan.n_keys = len(paths)
	plan.depth = 1
	plan.root_lo = lo
	return true
}

// Whether `paths` are gated columns sharing the first's gate.
@(private)
all_gated :: proc(paths: []Path) -> bool {
	for p in paths {
		if shape, _ := path_shape(p); shape != .Gated_Column || !same_gate(p.steps, paths[0].steps) {
			return false
		}
	}
	return len(paths) > 0
}

// Plan `paths` into `plan`. `automaton_only` gives every path to the automaton, the one engine a JSONC
// walk and a `.Refuse` walk carry. Touches nothing but the plan.
@(private)
route_paths :: proc(plan: ^Route, src: []byte, paths: []Path, duplicates: Duplicates, alloc: runtime.Allocator, automaton_only := false) -> Maybe(Error) {
	plan.matcher = .None
	plan.gate.gated = 0
	plan.any_limit = false
	plan.n_keys = 0
	plan.n_auto = 0

	// The common request fits the inline arrays and plans in one pass.
	if !FORCE_AUTOMATON && !automaton_only && duplicates != .All && len(paths) > 0 && len(paths) <= MAX_ROUTED && route_all_named(plan, src, paths) {
		return {}
	}
	return route_general(plan, src, paths, duplicates, alloc, automaton_only)
}

// What `route_general` counts over the paths: the plain names, the columns at the depth `wild` (the first
// column's, -1 with none).
@(private = "file")
Path_Tally :: struct {
	n_single, n_column, wild: int,
}

// Any request. Out of line: the common request never reaches it.
@(private = "file")
route_general :: #force_no_inline proc(plan: ^Route, src: []byte, paths: []Path, duplicates: Duplicates, alloc: runtime.Allocator, automaton_only: bool) -> Maybe(Error) {
	force := FORCE_AUTOMATON || automaton_only
	tally, refused := route_tally(paths, force)
	if err, bad := refused.?; bad {
		return err
	}
	served := route_serve(plan, src, paths, duplicates, force, tally)
	n_keys := 0
	#partial switch served {
	case .Column:       n_keys = tally.n_column
	case .Single_Name:  n_keys = tally.n_single
	case .Gated_Column: n_keys = len(paths)
	}
	if n_keys > MAX_ROUTED {
		if !spill_to(&plan.spill.keys, n_keys, alloc) || !spill_to(&plan.spill.row_keys, n_keys, alloc) ||
		   !spill_to(&plan.spill.fields, n_keys, alloc) {
			return Error{kind = .Out_Of_Memory}
		}
	}
	if err, bad := route_assign(plan, paths, served, tally.wild, n_keys).?; bad {
		return err
	}
	if plan.any_limit && len(paths) > MAX_ROUTED {
		if !spill_to(&plan.spill.counts, len(paths), alloc) {
			return Error{kind = .Out_Of_Memory}
		}
	}
	return {}
}

// Count the paths by shape. Refused when a path is longer than the one step bound: a long column would
// otherwise be served by the row matcher, which has none.
@(private = "file")
route_tally :: proc(paths: []Path, force: bool) -> (t: Path_Tally, refused: Maybe(Error)) {
	t.wild = -1
	for p in paths {
		if len(p.steps) > core_pkg.MAX_PATH_STEPS {
			return t, Error{kind = .Over_Capacity}
		}
		shape, k := path_shape(p)
		switch shape {
		case .Column:
			// The matcher reads one wildcard depth, the first column's. A column of another depth runs on
			// the automaton.
			if t.wild < 0 && !force {
				t.wild = k
			}
			if k == t.wild {
				t.n_column += 1
			}
		case .Single_Name:
			t.n_single += 1
		case .Automaton, .Gated_Column:
		}
	}
	return
}

// Pick the matcher and set the plan's depth, gate and root, and return the shape it serves; with no matcher
// `.Automaton` takes every path. A gated column takes it only when every path shares one gate, compiled
// into the demand-only walk alone. A slot holds one extent per key, so `.All` reads plain names in rows
// instead. A root that is not an object stays with the automaton (it owes `Type_Mismatch`).
@(private = "file")
route_serve :: proc(plan: ^Route, src: []byte, paths: []Path, duplicates: Duplicates, force: bool, t: Path_Tally) -> Path_Shape {
	if t.wild >= 0 {
		plan.matcher = .Rows
		plan.depth = u64(t.wild + 1)
		return .Column
	}
	if !force && all_gated(paths) {
		ref := paths[0].steps
		plan.matcher = .Rows
		plan.depth = u64(len(ref))
		// Step `d` reads the members of an object at depth `d + 1`.
		for st, d in ref[:len(ref) - 1] {
			if name, is_name := st.(Name); is_name {
				plan.gate.gated |= u64(1) << u64(d + 1)
				plan.gate.names[d + 1] = string(name)
			}
		}
		return .Gated_Column
	}
	if t.n_single != 0 && !force {
		if lo, is_object := root_object(src); is_object {
			plan.matcher = .Names if duplicates == .All else .Slots
			plan.depth = 1
			plan.root_lo = lo
			return .Single_Name
		}
	}
	return .Automaton
}

// Hand each path to the matcher's keys when it has the `served` shape, else to the automaton, and
// record `n_keys`.
@(private = "file")
route_assign :: proc(plan: ^Route, paths: []Path, served: Path_Shape, wild, n_keys: int) -> Maybe(Error) {
	store := route_store(plan, n_keys)
	j := 0
	for p, i in paths {
		if shape, k := path_shape(p); shape == served && shape != .Automaton && (shape != .Column || k == wild) {
			store.keys[j] = string(p.steps[len(p.steps) - 1].(Name))
			// A slot holds one answer per key, so a limit never cuts a slot-served path.
			plan.any_limit ||= plan.matcher != .Slots && p.limit > 0
			store.row_keys[j] = walk.Demand_Row_Key{tag = u32(i), limit = u32(clamp(p.limit, 0, int(max(u32))))}
			j += 1
		} else {
			if plan.n_auto == walk.MAX_PATH_QUERIES {
				return Error{kind = .Over_Capacity}
			}
			plan.any_limit ||= p.limit > 0
			plan.auto[plan.n_auto] = u32(i)
			plan.n_auto += 1
		}
	}
	plan.n_keys = n_keys
	if walk.names_over_capacity(store.keys) {
		return Error{kind = .Over_Capacity}
	}
	return nil
}

// A slot's answer: a found key is a `Found`, a key the document lacked is `Missing`. The matcher writes a
// slot whole or not at all, so a miss is all zero and the span and kind copy without a branch.
@(private = "file")
slot_answer :: #force_inline proc(root_lo: u64, path: u32, f: walk.Field_Value) -> Path_Answer {
	return Path_Answer{
		lo = f.lo, hi = f.hi, owner = root_lo, query = path, node = NO_NODE, kind = f.kind,
		outcome = .Found if f.found else .Missing,
	}
}

// Turn the slots into answers, in key order. A key the whole document lacked is owed as `Missing` only when
// the walk reached the end, as the automaton owes it.
@(private)
route_slots :: #force_inline proc(answers: ^[dynamic]Path_Answer, plan: ^Route, reached_end: bool) -> bool {
	store := route_store(plan, plan.n_keys)
	n := len(answers^)
	// Room for every answer, the usual case: they are written with no check of their own.
	if reached_end && cap(answers^) - n >= len(store.fields) {
		for f, i in store.fields {
			#no_bounds_check answers[n + i] = slot_answer(plan.root_lo, store.row_keys[i].tag, f)
		}
		walk.edge_publish(answers, n + len(store.fields))
		return true
	}
	return route_slots_append(answers, plan, reached_end)
}

// `route_slots` one append at a time: an array that must grow, or a walk that stopped short.
@(private = "file")
route_slots_append :: #force_no_inline proc(answers: ^[dynamic]Path_Answer, plan: ^Route, reached_end: bool) -> bool {
	store := route_store(plan, plan.n_keys)
	for f, i in store.fields {
		if !f.found && !reached_end {
			continue
		}
		n := len(answers^)
		walk.row_append(answers, slot_answer(plan.root_lo, store.row_keys[i].tag, f))
		if len(answers^) == n {
			return false
		}
	}
	return true
}

// Owe `Missing`, owned by no container (`NO_OWNER`, a miss of the document as a whole), to every `.Names` key
// that matched nothing, in key order, after the walk's rows. Only a walk that reached the end owes it, as the
// automaton does. Out of line: `.All` names are the rare plan.
@(private)
route_missing :: #force_no_inline proc(answers: ^[dynamic]Path_Answer, plan: ^Route, stop: Maybe(u64), err: Maybe(Error)) -> bool {
	if e, faulted := err.?; stop != nil || faulted && e.kind != .Trailing {
		return true
	}
	for k in route_store(plan, plan.n_keys).row_keys {
		if k.owner != walk.NO_OWNER {
			continue
		}
		n := len(answers^)
		walk.row_append(answers, Path_Answer{owner = walk.NO_OWNER, query = k.tag, node = NO_NODE, outcome = .Missing})
		if len(answers^) == n {
			return false
		}
	}
	return true
}

// The answers' last pass, owed when they have retracted rows to drop, a limit to apply, or nodes only a later
// pass can fill: one sweep over `answers` that drops every retracted row, cuts each path to its `limit`, and
// fills the field the walk does not (every `node`). Plain slot, column or automaton answers skip it.
@(private)
finish_answers :: proc(answers: ^[dynamic]Path_Answer, nodes: []walk.Row, plan: ^Route, paths: []Path, has_nodes: bool) {
	inline_counts: [MAX_ROUTED]int
	counts := inline_counts[:]
	if len(paths) > MAX_ROUTED {
		counts = plan.spill.counts[:]
		runtime.mem_zero(raw_data(counts), size_of(int) * len(counts))
	}
	kept := 0
	for answer in answers^ {
		a := answer
		if a.query == walk.RETRACTED_TAG {
			continue
		}
		// A limit counts what jq would output, the `Found` answers (every answer, `per_element`). Whatever comes
		// after the last is cut.
		if limit := paths[a.query].limit; limit > 0 {
			if counts[a.query] >= limit {
				continue
			}
			if a.outcome == .Found || paths[a.query].per_element {
				counts[a.query] += 1
			}
		}
		if has_nodes && a.outcome == .Found {
			a.node = node_at(nodes, a.lo)
		}
		answers[kept] = a
		kept += 1
	}
	resize(answers, kept)
}

// The row of `nodes` that starts at `lo`: rows are preorder, so `lo` ascends and a binary search finds it.
// `NO_NODE` when the tape has no row there.
@(private)
node_at :: proc(nodes: []walk.Row, lo: u64) -> Node {
	i, found := slice.binary_search_by(nodes, lo, proc(r: walk.Row, lo: u64) -> slice.Ordering {
		return slice.cmp(u64(r.lo), lo)
	})
	return Node(i) if found else NO_NODE
}
