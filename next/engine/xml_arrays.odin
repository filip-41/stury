package engine

import "base:runtime"
import "core:mem"
import "core:slice"
import "stury:lib/base/regex"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"
import "stury:xml"

@(private = "file")
MAX_SCHEMA_STATES :: 64

@(private = "file")
Schema_State :: [dynamic]rules.Node_Index

// Decides whether the JSON Schema `desc` expects an `.Array` at `path` (decoded element names from the document root,
// e.g. `["root", "orders", "order"]`).
//
// Maintains a bounded set of alternative conjunction states (each state is a set of ANDed `rules.Node_Index`es):
// - `$ref` and `allOf` stay within the same conjunction state, while `anyOf`, `oneOf`, `if/then/else`, `$dynamicRef`,
//   and optional `dependentSchemas` fork separate alternative conjunction states so mutually exclusive arms (e.g.
//   `oneOf` branches with `additionalProperties: false`) never poison each other.
// - At each segment in `path`, intermediate array schemas transparently unwrap through `items` (ANDed within the
//   conjunction) and `prefixItems` / `contains` / `unevaluatedItems` (forked as alternative element states) so nested
//   arrays of objects (e.g. `root.orders[].order[]`) resolve cleanly.
// - Stepping a property name `seg` within a conjunction checks `properties`, `patternProperties`, and
//   `additionalProperties` across all nodes in that conjunction first; ONLY when nothing in the conjunction evaluated
//   `seg` does it fall back to `unevaluatedProperties` across all nodes in the conjunction (including nodes with
//   `n.object < 0`, e.g. `allOf` + `unevaluatedProperties`).
//
// At the reached target state set, returns `true` iff ANY satisfiable target conjunction allows `.Array` AND either:
//   1. `.Array` is the only non-null allowed kind (`kinds <= {.Array, .Null}`, e.g. `type: "array"` or
//      `type: ["array", "null"]`), OR
//   2. an array-specific keyword (`items`, `prefixItems`, `contains`, `minItems > 0`, `maxItems`, `uniqueItems`, or
//      `unevaluatedItems`) is present on at least one node in the conjunction.
// An unconstrained `{}` catch-all schema (`EVERY_KIND` with no array keywords) returns `false`.
// Zero `context.temp_allocator`, WASM-clean.
@(require_results)
schema_expects_array :: proc(desc: ^rules.Description, path: []string, allocator := context.allocator) -> bool {
	if desc == nil || desc.root < 0 || int(desc.root) >= len(desc.nodes) {
		return false
	}
	node_count := len(desc.nodes)

	visited, verr := make([]bool, node_count, allocator)
	if verr != nil {
		return false
	}
	defer delete(visited, allocator)

	states: [dynamic]Schema_State
	states.allocator = allocator
	defer free_state_list(&states)

	next_states: [dynamic]Schema_State
	next_states.allocator = allocator
	defer free_state_list(&next_states)

	init_st: Schema_State
	init_st.allocator = allocator
	if _, aerr := append(&init_st, desc.root); aerr != nil {
		delete(init_st)
		return false
	}
	if _, aerr := append(&states, init_st); aerr != nil {
		delete(init_st)
		return false
	}

	re_scratch: regex.Scratch
	has_scratch := false
	defer if has_scratch {
		regex.scratch_destroy(&re_scratch)
	}

	for seg in path {
		// 1. Expand all conjunctions (splitting `oneOf`/`anyOf`/`if-then-else`/`$dynamicRef`, adding optional
		// `dependentSchemas` forks, and transparently descending through intermediate array item schemas).
		expand_states_for_step(desc, &states, visited, allocator)
		if len(states) == 0 {
			return false
		}

		// 2. Step each conjunction state independently by property `seg`.
		clear_state_list(&next_states)
		for st in states {
			if len(next_states) >= MAX_SCHEMA_STATES {
				break
			}
			// A conjunction that cannot accept an object cannot match any object property.
			if .Object not_in rules.kinds_of(desc, st[:]) {
				continue
			}

			slice.zero(visited)
			child: Schema_State
			child.allocator = allocator
			any_evaluated := false

			for nid in st {
				if nid < 0 || int(nid) >= node_count {
					continue
				}
				n := &desc.nodes[nid]
				if n.object < 0 || int(n.object) >= len(desc.objects) {
					continue
				}
				obj := &desc.objects[n.object]
				local_matched := false

				for m in obj.members {
					if !m.only_required && m.name == seg {
						local_matched = true
						any_evaluated = true
						add_unique_node(&child, visited, m.node, node_count)
					}
				}
				for pat in obj.patterns {
					if match_schema_pattern(pat.expression, seg, &re_scratch, &has_scratch, allocator) {
						local_matched = true
						any_evaluated = true
						add_unique_node(&child, visited, pat.node, node_count)
					}
				}
				if !local_matched && obj.additional != rules.NONE {
					any_evaluated = true
					add_unique_node(&child, visited, obj.additional, node_count)
				}
			}

			// Apply `unevaluatedProperties` across ALL nodes in this conjunction (including `n.object < 0`)
			// ONLY if no node in the conjunction evaluated `seg`.
			if !any_evaluated {
				for nid in st {
					if nid < 0 || int(nid) >= node_count {
						continue
					}
					n := &desc.nodes[nid]
					if up, has_up := n.unevaluated_properties.?; has_up && up != rules.NONE {
						add_unique_node(&child, visited, up, node_count)
					}
				}
			}

			if len(child) == 0 {
				delete(child)
				continue
			}
			append_unique_state(&next_states, child)
		}

		states, next_states = next_states, states
		if len(states) == 0 {
			return false
		}
	}

	// Evaluate each reached target conjunction state independently.
	for st in states {
		if len(st) == 0 {
			continue
		}
		branches, complete := rules.branches(desc, st[:], choices = true, limit = MAX_SCHEMA_STATES, allocator = allocator, scratch = allocator)
		if complete {
			matched := false
			for b in branches {
				if len(b) == 0 {
					continue
				}
				if conjunction_expects_array(desc, b[:]) {
					matched = true
					break
				}
			}
			for b in branches {
				delete(b)
			}
			delete(branches, allocator)
			if matched {
				return true
			}
		} else {
			// Fallback when combinator expansion exceeds branch limit: cycle-safe BFS on this state.
			tmp: Schema_State
			tmp.allocator = allocator
			if _, aerr := append(&tmp, ..st[:]); aerr == nil {
				expand_nodes_flat(desc, &tmp, visited)
				for id in tmp {
					n := &desc.nodes[id]
					if .Array in n.kinds && (n.kinds <= {.Array, .Null} || node_has_array_keyword(n)) {
						delete(tmp)
						return true
					}
				}
			}
			delete(tmp)
		}
	}
	return false
}

// Applies XML array normalization mode `mode` to built document `doc`.
// - `.Auto`: no-op (`nil`).
// - `.Always`: wraps every non-`#text` child element at depth >= 1 in an array.
// - `.Schema`: requires non-nil `desc` (else `tape.Bad_Option{"schema"}`), wrapping single elements where
//   `schema_expects_array(desc, path)` is true and collapsing repeated siblings into arrays.
// Refuses partial, borrowed, nil, or non-XML documents cleanly with `tape.Bad_Option`.
@(require_results)
apply_xml_arrays :: proc(
	doc: ^tape.Document,
	mode: tape.Xml_Arrays,
	desc: ^rules.Description = nil,
	allocator := context.allocator,
) -> tape.Error {
	if mode > max(tape.Xml_Arrays) {
		return tape.Bad_Option{"format"}
	}
	if mode == .Auto {
		return nil
	}
	if doc == nil || doc.partial != nil || .Borrowed in doc.flags {
		return tape.Bad_Option{"document"}
	}
	if doc.format == nil || doc.format.options != .Xml {
		return tape.Bad_Option{"format"}
	}
	switch mode {
	case .Auto:
		return nil
	case .Always:
		return xml.normalize_arrays(doc, .Always, nil, nil, allocator)
	case .Schema:
		if desc == nil {
			return tape.Bad_Option{"schema"}
		}
		Pred_Ctx :: struct {
			desc:      ^rules.Description,
			allocator: runtime.Allocator,
		}
		ctx := Pred_Ctx{desc = desc, allocator = allocator}
		pred :: proc(raw: rawptr, path: []string) -> bool {
			c := (^Pred_Ctx)(raw)
			return schema_expects_array(c.desc, path, c.allocator)
		}
		return xml.normalize_arrays(doc, .Schema, pred, &ctx, allocator)
	}
	return tape.Bad_Option{"format"}
}

@(private = "file")
conjunction_expects_array :: proc "contextless" (desc: ^rules.Description, conj: []rules.Node_Index) -> bool {
	k := rules.kinds_of(desc, conj)
	if .Array not_in k {
		return false
	}
	if k <= {.Array, .Null} {
		return true
	}
	for id in conj {
		if id >= 0 && int(id) < len(desc.nodes) && node_has_array_keyword(&desc.nodes[id]) {
			return true
		}
	}
	return false
}

@(private = "file")
node_has_array_keyword :: proc "contextless" (n: ^rules.Node) -> bool {
	return n.array >= 0 ||
		n.rules.unique ||
		n.rules.min_items > 0 ||
		n.rules.max_items != nil ||
		n.unevaluated_items != nil
}

@(private = "file")
clear_state_list :: proc(list: ^[dynamic]Schema_State) {
	for s in list {
		delete(s)
	}
	clear(list)
}

@(private = "file")
free_state_list :: proc(list: ^[dynamic]Schema_State) {
	for s in list {
		delete(s)
	}
	delete(list^)
}

// Appends `st` to `list` (taking ownership) unless an identical sorted state already exists or `MAX_SCHEMA_STATES` is reached.
@(private = "file")
append_unique_state :: proc(list: ^[dynamic]Schema_State, st: Schema_State) {
	st := st
	if len(st) == 0 || len(list) >= MAX_SCHEMA_STATES {
		delete(st)
		return
	}
	slice.sort(st[:])
	// Compact duplicates in place.
	w := 1
	for i in 1 ..< len(st) {
		if st[i] != st[w - 1] {
			st[w] = st[i]
			w += 1
		}
	}
	resize(&st, w)
	for existing in list {
		if len(existing) == len(st) && slice.equal(existing[:], st[:]) {
			delete(st)
			return
		}
	}
	if _, err := append(list, st); err != nil {
		delete(st)
	}
}

// Expands `states` in place before stepping a property segment:
// - Splits `oneOf`/`anyOf`/`if-then-else`/`$dynamicRef` via `rules.branches` into separate conjunction states.
// - Forks optional `dependentSchemas` as additional candidate conjunction states.
// - Transparently unwraps intermediate array item schemas (`items` ANDed, `prefixItems`/`contains`/`unevaluatedItems`
//   forked) so nested arrays of objects descend cleanly while staying cycle-safe and bounded by `MAX_SCHEMA_STATES`.
@(private = "file")
expand_states_for_step :: proc(
	desc: ^rules.Description,
	states: ^[dynamic]Schema_State,
	visited: []bool,
	allocator: runtime.Allocator,
) {
	node_count := len(desc.nodes)
	out: [dynamic]Schema_State
	out.allocator = allocator

	// Phase 1: branch each input state via `rules.branches`.
	for st in states {
		if len(out) >= MAX_SCHEMA_STATES {
			break
		}
		branches, complete := rules.branches(desc, st[:], choices = true, limit = MAX_SCHEMA_STATES, allocator = allocator, scratch = allocator)
		if complete {
			for b in branches {
				append_unique_state(&out, b)
			}
			delete(branches, allocator)
		} else {
			cloned: Schema_State
			cloned.allocator = allocator
			if _, err := append(&cloned, ..st[:]); err == nil {
				expand_nodes_flat(desc, &cloned, visited)
				append_unique_state(&out, cloned)
			} else {
				delete(cloned)
			}
		}
	}

	// Phase 2: worklist over `out` to fork `dependentSchemas` and transparently descend through intermediate arrays.
	// Since `append_unique_state` deduplicates and caps `len(out) <= MAX_SCHEMA_STATES`, this loop is strictly bounded.
	for i := 0; i < len(out) && len(out) < MAX_SCHEMA_STATES; i += 1 {
		// Copy current state's node slice length & IDs via index lookup because `append_unique_state` may reallocate `out`.
		st_len := len(out[i])

		// 2a. Optional `dependentSchemas` forks (keeps `out[i]` untouched in case the trigger property isn't present).
		for j in 0 ..< st_len {
			if len(out) >= MAX_SCHEMA_STATES {
				break
			}
			nid := out[i][j]
			if nid < 0 || int(nid) >= node_count {
				continue
			}
			n := &desc.nodes[nid]
			if n.object < 0 || int(n.object) >= len(desc.objects) {
				continue
			}
			for dep in desc.objects[n.object].dependents {
				if dn, has := dep.node.?; has && dn != rules.NONE && !slice.contains(out[i][:], dn) {
					forked: Schema_State
					forked.allocator = allocator
					if _, e1 := append(&forked, ..out[i][:]); e1 == nil {
						if _, e2 := append(&forked, dn); e2 == nil {
							add_branched_states(desc, &out, forked, visited, allocator)
						} else {
							delete(forked)
						}
					} else {
						delete(forked)
					}
					if len(out) >= MAX_SCHEMA_STATES {
						break
					}
				}
			}
		}

		if len(out) >= MAX_SCHEMA_STATES {
			break
		}

		// 2b. Transparent array descent when `.Array` is allowed in this conjunction.
		if .Array not_in rules.kinds_of(desc, out[i][:]) {
			continue
		}

		items_conj: Schema_State
		items_conj.allocator = allocator
		has_items := false

		// First pass: collect ANDed `items` schemas across all array nodes in `out[i]`.
		for j in 0 ..< len(out[i]) {
			nid := out[i][j]
			if nid < 0 || int(nid) >= node_count {
				continue
			}
			n := &desc.nodes[nid]
			if n.array >= 0 && int(n.array) < len(desc.arrays) {
				arr := &desc.arrays[n.array]
				if arr.items != rules.NONE {
					has_items = true
					if !slice.contains(items_conj[:], arr.items) {
						_, _ = append(&items_conj, arr.items)
					}
				}
			}
		}

		// Apply `unevaluatedItems` ONLY when no `items` schema existed in the conjunction.
		if !has_items {
			for j in 0 ..< len(out[i]) {
				nid := out[i][j]
				if nid < 0 || int(nid) >= node_count {
					continue
				}
				if ui, has_ui := desc.nodes[nid].unevaluated_items.?; has_ui && ui != rules.NONE {
					if !slice.contains(items_conj[:], ui) {
						_, _ = append(&items_conj, ui)
					}
				}
			}
		}

		if len(items_conj) > 0 {
			add_branched_states(desc, &out, items_conj, visited, allocator)
		} else {
			delete(items_conj)
		}

		// Second pass: fork `prefixItems` and `contains` alternatives as separate element states.
		for j in 0 ..< len(out[i]) {
			if len(out) >= MAX_SCHEMA_STATES {
				break
			}
			nid := out[i][j]
			if nid < 0 || int(nid) >= node_count {
				continue
			}
			n := &desc.nodes[nid]
			if n.array < 0 || int(n.array) >= len(desc.arrays) {
				continue
			}
			arr := &desc.arrays[n.array]
			for p in arr.prefix {
				if p == rules.NONE || len(out) >= MAX_SCHEMA_STATES {
					continue
				}
				ps: Schema_State
				ps.allocator = allocator
				if _, err := append(&ps, p); err == nil {
					add_branched_states(desc, &out, ps, visited, allocator)
				} else {
					delete(ps)
				}
			}
			if c, has_c := arr.contains.?; has_c && c != rules.NONE && len(out) < MAX_SCHEMA_STATES {
				cs: Schema_State
				cs.allocator = allocator
				if _, err := append(&cs, c); err == nil {
					add_branched_states(desc, &out, cs, visited, allocator)
				} else {
					delete(cs)
				}
			}
		}
	}

	free_state_list(states)
	states^ = out
}

@(private = "file")
add_branched_states :: proc(
	desc: ^rules.Description,
	out: ^[dynamic]Schema_State,
	seed: Schema_State,
	visited: []bool,
	allocator: runtime.Allocator,
) {
	seed := seed
	branches, complete := rules.branches(desc, seed[:], choices = true, limit = MAX_SCHEMA_STATES, allocator = allocator, scratch = allocator)
	if complete {
		delete(seed)
		for b in branches {
			append_unique_state(out, b)
		}
		delete(branches, allocator)
		return
	}
	expand_nodes_flat(desc, &seed, visited)
	append_unique_state(out, seed)
}

@(private = "file")
add_unique_node :: proc(out: ^[dynamic]rules.Node_Index, visited: []bool, id: rules.Node_Index, node_count: int) {
	if id < 0 || int(id) >= node_count || visited[id] {
		return
	}
	visited[id] = true
	_, _ = append(out, id)
}

@(private = "file")
expand_nodes_flat :: proc(desc: ^rules.Description, nodes: ^[dynamic]rules.Node_Index, visited: []bool) {
	node_count := len(desc.nodes)
	slice.zero(visited)
	for id in nodes {
		if id >= 0 && int(id) < node_count {
			visited[id] = true
		}
	}
	for i := 0; i < len(nodes); i += 1 {
		id := nodes[i]
		if id < 0 || int(id) >= node_count {
			continue
		}
		n := &desc.nodes[id]
		if r, has := n.ref.?; has {
			add_unique_node(nodes, visited, r, node_count)
		}
		if dr, has := n.dynamic_ref.?; has {
			add_unique_node(nodes, visited, dr, node_count)
			for a in desc.anchors {
				if a.node == dr {
					for b in desc.anchors {
						if b.name == a.name {
							add_unique_node(nodes, visited, b.node, node_count)
						}
					}
				}
			}
		}
		for arm in n.all_of {
			add_unique_node(nodes, visited, arm, node_count)
		}
		for arm in n.any_of {
			add_unique_node(nodes, visited, arm, node_count)
		}
		for arm in n.one_of {
			add_unique_node(nodes, visited, arm, node_count)
		}
		if t, has := n.cond.then.?; has {
			add_unique_node(nodes, visited, t, node_count)
		}
		if o, has := n.cond.other.?; has {
			add_unique_node(nodes, visited, o, node_count)
		}
	}
}

@(private = "file")
match_schema_pattern :: proc(
	expr: string,
	seg: string,
	scratch: ^regex.Scratch,
	has_scratch: ^bool,
	allocator: runtime.Allocator,
) -> bool {
	if !has_scratch^ {
		scr, serr := regex.scratch_make(allocator)
		if serr.kind != .None {
			return false
		}
		scratch^ = scr
		has_scratch^ = true
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, allocator, allocator, block_size = 4096, out_band_size = 1024)
	defer mem.dynamic_arena_destroy(&arena)

	re, cerr := regex.compile(expr, .Ecma, {}, mem.dynamic_arena_allocator(&arena), allocator, automaton = false)
	if cerr.kind != .None {
		return false
	}
	found, serr := regex.search(&re, seg, 0, nil, scratch)
	return serr.kind == .None && found
}
