package engine

import "base:runtime"
import "core:mem"
import "core:slice"
import "stury:lib/base/regex"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"
import "stury:xml"

Schema_Description :: rules.Description
destroy_schema_description :: rules.description_destroy

@(private = "file")
MAX_SCHEMA_STATES :: 64

@(private = "file")
Schema_State :: [dynamic]rules.Node_Index

// Decides whether the JSON Schema `desc` expects an `.Array` at `path` (decoded element names from root).
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

	states, next_states: [dynamic]Schema_State
	states.allocator, next_states.allocator = allocator, allocator
	defer free_state_list(&states)
	defer free_state_list(&next_states)

	init_st: Schema_State
	init_st.allocator = allocator
	if _, e1 := append(&init_st, desc.root); e1 != nil {
		delete(init_st)
		return false
	}
	if _, e2 := append(&states, init_st); e2 != nil {
		delete(init_st)
		return false
	}

	re_scratch: regex.Scratch
	has_scratch := false
	defer if has_scratch {
		regex.scratch_destroy(&re_scratch)
	}

	for seg in path {
		expand_states_for_step(desc, &states, visited, allocator)
		if len(states) == 0 {
			return false
		}
		clear_state_list(&next_states)
		for st in states {
			if len(next_states) >= MAX_SCHEMA_STATES {
				break
			}
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
						local_matched, any_evaluated = true, true
						add_unique_node(&child, visited, m.node, node_count)
					}
				}
				for pat in obj.patterns {
					if match_schema_pattern(pat.expression, seg, &re_scratch, &has_scratch, allocator) {
						local_matched, any_evaluated = true, true
						add_unique_node(&child, visited, pat.node, node_count)
					}
				}
				if !local_matched && obj.additional != rules.NONE {
					any_evaluated = true
					add_unique_node(&child, visited, obj.additional, node_count)
				}
			}
			if !any_evaluated {
				for nid in st {
					if nid >= 0 && int(nid) < node_count {
						if up, has_up := desc.nodes[nid].unevaluated_properties.?; has_up && up != rules.NONE {
							add_unique_node(&child, visited, up, node_count)
						}
					}
				}
			}
			append_unique_state(&next_states, child)
		}
		states, next_states = next_states, states
		if len(states) == 0 {
			return false
		}
	}

	for st in states {
		if len(st) == 0 {
			continue
		}
		branches, complete := rules.branches(desc, st[:], choices = true, limit = MAX_SCHEMA_STATES, allocator = allocator, scratch = allocator)
		if complete {
			matched := false
			for b in branches {
				if len(b) > 0 && conjunction_expects_array(desc, b[:]) {
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
	if mode == .Always {
		return xml.normalize_arrays(doc, .Always, nil, nil, allocator)
	}
	if desc == nil {
		return tape.Bad_Option{"schema"}
	}
	Pred_Ctx :: struct {
		desc:      ^rules.Description,
		allocator: runtime.Allocator,
	}
	ctx := Pred_Ctx{desc = desc, allocator = allocator}
	return xml.normalize_arrays(doc, .Schema, proc(raw: rawptr, path: []string) -> bool {
		c := (^Pred_Ctx)(raw)
		return schema_expects_array(c.desc, path, c.allocator)
	}, &ctx, allocator)
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
	return n.array >= 0 || n.rules.unique || n.rules.min_items > 0 || n.rules.max_items != nil || n.unevaluated_items != nil
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
	clear_state_list(list)
	delete(list^)
}

@(private = "file")
append_unique_state :: proc(list: ^[dynamic]Schema_State, st: Schema_State) {
	st := st
	if len(st) == 0 || len(list) >= MAX_SCHEMA_STATES {
		delete(st)
		return
	}
	slice.sort(st[:])
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

@(private = "file")
fork_and_branch :: proc(desc: ^rules.Description, out: ^[dynamic]Schema_State, base: []rules.Node_Index, extra: rules.Node_Index, visited: []bool, allocator: runtime.Allocator) {
	if len(out) >= MAX_SCHEMA_STATES {
		return
	}
	seed: Schema_State
	seed.allocator = allocator
	if len(base) > 0 {
		if _, err := append(&seed, ..base); err != nil {
			delete(seed)
			return
		}
	}
	if extra != rules.NONE {
		if _, err := append(&seed, extra); err != nil {
			delete(seed)
			return
		}
	}
	add_branched_states(desc, out, seed, visited, allocator)
}

@(private = "file")
expand_states_for_step :: proc(desc: ^rules.Description, states: ^[dynamic]Schema_State, visited: []bool, allocator: runtime.Allocator) {
	node_count := len(desc.nodes)
	out: [dynamic]Schema_State
	out.allocator = allocator

	for st in states {
		if len(out) >= MAX_SCHEMA_STATES {
			break
		}
		fork_and_branch(desc, &out, st[:], rules.NONE, visited, allocator)
	}

	for i := 0; i < len(out) && len(out) < MAX_SCHEMA_STATES; i += 1 {
		st_len := len(out[i])
		for j in 0 ..< st_len {
			if len(out) >= MAX_SCHEMA_STATES {
				break
			}
			nid := out[i][j]
			if nid < 0 || int(nid) >= node_count {
				continue
			}
			n := &desc.nodes[nid]
			if n.object >= 0 && int(n.object) < len(desc.objects) {
				for dep in desc.objects[n.object].dependents {
					if dn, has := dep.node.?; has && dn != rules.NONE && !slice.contains(out[i][:], dn) {
						fork_and_branch(desc, &out, out[i][:], dn, visited, allocator)
					}
				}
			}
		}
		if len(out) >= MAX_SCHEMA_STATES || .Array not_in rules.kinds_of(desc, out[i][:]) {
			continue
		}

		items_conj: Schema_State
		items_conj.allocator = allocator
		has_items := false
		for j in 0 ..< len(out[i]) {
			nid := out[i][j]
			if nid >= 0 && int(nid) < node_count {
				n := &desc.nodes[nid]
				if n.array >= 0 && int(n.array) < len(desc.arrays) {
					if item := desc.arrays[n.array].items; item != rules.NONE {
						has_items = true
						if !slice.contains(items_conj[:], item) {
							_, _ = append(&items_conj, item)
						}
					}
				}
			}
		}
		if !has_items {
			for j in 0 ..< len(out[i]) {
				nid := out[i][j]
				if nid >= 0 && int(nid) < node_count {
					if ui, has_ui := desc.nodes[nid].unevaluated_items.?; has_ui && ui != rules.NONE && !slice.contains(items_conj[:], ui) {
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
				if p != rules.NONE {
					fork_and_branch(desc, &out, nil, p, visited, allocator)
				}
			}
			if c, has_c := arr.contains.?; has_c && c != rules.NONE {
				fork_and_branch(desc, &out, nil, c, visited, allocator)
			}
		}
	}

	free_state_list(states)
	states^ = out
}

@(private = "file")
add_branched_states :: proc(desc: ^rules.Description, out: ^[dynamic]Schema_State, seed: Schema_State, visited: []bool, allocator: runtime.Allocator) {
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
		for arm in n.all_of { add_unique_node(nodes, visited, arm, node_count) }
		for arm in n.any_of { add_unique_node(nodes, visited, arm, node_count) }
		for arm in n.one_of { add_unique_node(nodes, visited, arm, node_count) }
		if t, has := n.cond.then.?; has { add_unique_node(nodes, visited, t, node_count) }
		if o, has := n.cond.other.?; has { add_unique_node(nodes, visited, o, node_count) }
	}
}

@(private = "file")
match_schema_pattern :: proc(expr, seg: string, scratch: ^regex.Scratch, has_scratch: ^bool, allocator: runtime.Allocator) -> bool {
	if !has_scratch^ {
		scr, serr := regex.scratch_make(allocator)
		if serr.kind != .None {
			return false
		}
		scratch^, has_scratch^ = scr, true
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
