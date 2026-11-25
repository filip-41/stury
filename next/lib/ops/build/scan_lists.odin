package build

import "base:runtime"
import "core:slice"
import "stury:lib/core/tape"

// Partial-document finalization (`scan_lists`), demand refusal checks (`scan_refused`, `scan_cuts`), and helpers
// shared between `Scanner` and `Query` (`paths_fail`, `room_list`, `list_grow`).

// Why a scan of `demand` over a text of `format` under `opts` is refused, as `path_read_refused` judges it, or for a
// step from the end past a `Descend`, which would take back the answers under an element it passes that a `Descend`
// from a value inside that element may give again. `query` answers such a path.
@(private, require_results)
scan_refused :: proc "contextless" (format: ^tape.Format, opts: tape.Options, demand: ^tape.Demand) -> tape.Error {
	path_read_refused(format, opts) or_return
	if !demand.deep {
		return nil
	}
	for node in demand.nodes {
		for edge in demand.edges[node.edges:][:node.n_edges] {
			if node.deep && tape.step_reach(edge.step) > 0 {
				return tape.Bad_Option{"path"}
			}
		}
	}
	return nil
}

// Whether a step of `demand` has a limit, which settles its paths once the step takes no more.
@(private, require_results)
scan_cuts :: proc "contextless" (demand: ^tape.Demand) -> bool {
	for e in demand.edges {
		#partial switch step in e.step {
		case tape.All:
			if step.limit > 0 {
				return true
			}
		case tape.Slice:
			if step.limit > 0 {
				return true
			}
		}
	}
	return false
}

// Points `list` at `room`, empty, so that it grows into `allocator` once it outgrows the room.
@(private)
room_list :: proc "contextless" (list: ^[dynamic]$T, room: []$E, allocator: runtime.Allocator) {
	(^runtime.Raw_Dynamic_Array)(list)^ = {data = raw_data(room), len = 0, cap = len(room) * size_of(E) / size_of(T), allocator = allocator}
}

// Grows a list of entries of `size` bytes to twice its capacity, at least 8 entries and at least `least`, under `ctx`. A
// list `in_room` moves out of the room it started in.
@(private, cold, require_results)
list_grow :: #force_no_inline proc "contextless" (ctx: ^runtime.Context, list: ^runtime.Raw_Dynamic_Array, size, align, least: int, in_room: bool) -> runtime.Allocator_Error {
	max_items := max(int) / size
	if least > max_items || list.allocator.procedure == nil {
		return .Out_Of_Memory
	}
	context = ctx^
	doubled := 2 * list.cap if list.cap <= max_items / 2 else max_items
	want := min(max(doubled, 8, least), max_items)
	data: []u8
	err: runtime.Allocator_Error
	if in_room {
		if data, err = runtime.mem_alloc_non_zeroed(want * size, align, list.allocator); err == nil {
			runtime.mem_copy_non_overlapping(raw_data(data), list.data, list.len * size)
		}
	} else {
		data, err = runtime.non_zero_mem_resize(list.data, list.cap * size, want * size, align, list.allocator)
	}
	took(err, raw_data(data), want * size) or_return
	list.data, list.cap = raw_data(data), want
	return nil
}

// Gives each path ending under demand node `to` of `dm` the answer `outcome` through `answer` to `sink`, at the value
// `at` placed at `pos`. `.Missing` is for a value that is null or missing, at the value or the container that lacks it,
// read as `.Missing` past the path's last `All`, held by `owner` when there is one, and as `.Wrong_Kind` before it, the
// step that met it `d` steps from the root. Past a `Descend` a value the steps cannot follow gives no answer.
@(private)
paths_fail :: #force_inline proc "contextless" (sink: ^$S, dm: ^tape.Demand, to: u32, outcome: tape.Presence, d: u64, at, owner: tape.Node_Index, pos: u64, $answer: proc "contextless" (sink: ^S, node: tape.Node_Index, path: u32, outcome: tape.Presence, pos: u64, leaf: u32) -> runtime.Allocator_Error) -> runtime.Allocator_Error #no_bounds_check {
	if outcome <= .Wrong_Kind && dm.nodes[to].deep {
		return nil
	}
	return paths_answer_fail(sink, dm, to, outcome, d, at, owner, pos, answer)
}

@(private = "file")
paths_answer_fail :: proc "contextless" (sink: ^$S, dm: ^tape.Demand, to: u32, outcome: tape.Presence, d: u64, at, owner: tape.Node_Index, pos: u64, $answer: proc "contextless" (sink: ^S, node: tape.Node_Index, path: u32, outcome: tape.Presence, pos: u64, leaf: u32) -> runtime.Allocator_Error) -> runtime.Allocator_Error #no_bounds_check {
	for m in to ..= dm.nodes[to].last {
		node := dm.nodes[m]
		for p in dm.ends[node.ends:][:node.n_ends] {
			if outcome != .Missing {
				answer(sink, at, p, outcome, pos, m) or_return
			} else if tape.path_refused(d, u64(dm.paths[p].alls_end)) == .Missing {
				answer(sink, owner if owner != tape.NO_NODE else at, p, .Missing, pos, m) or_return
			} else {
				answer(sink, at, p, .Wrong_Kind, pos, m) or_return
			}
		}
	}
	return nil
}

// Gives `doc` its answers by path, kept children, missing names and held spans in one block, from `answers` and
// `missing`, which it sorts, and `made`, which it overwrites. With records that replay the first record of a `fixed`
// walk, the first of `answers` and `missing` are the first record's, which each replayed record makes again `size`
// nodes after the record before, ahead of the rest.
//
// `#no_bounds_check` invariants:
// - When `r.replayed > 0`, `r.answers <= len(answers)` and `r.missing <= len(missing)` (recorded by `scan_learn_record`);
// - Every `a.path < u32(paths)` (populated from `Demand.ends`), and `len(made) == paths` when `h.demand.limited`;
// - `tape.partial_block` allocates `x.starts[paths + 1]`, `x.answers[live]`, `x.kept[h.kept.len]`, `x.missing[n_missing]`,
//   and `x.names[names]`, matching the exact counts accumulated before the call.
@(private, require_results)
scan_lists :: proc(h: ^Scanner, doc: ^tape.Document, answers: []Scan_Answer, missing: []Scan_Missing, made: []u32) -> runtime.Allocator_Error #no_bounds_check {
	allocator := doc.allocator
	paths := len(h.demand.paths)
	r := &h.record
	// Each answer of `first` and name of `first_missing` stands for one in each of `rounds` records.
	rounds := int(r.replayed) + 1 if r.replayed > 0 else 0
	first := answers[:r.answers] if rounds > 0 else nil
	first_missing := missing[:r.missing] if rounds > 0 else nil
	rest, rest_missing := answers[len(first):], missing[len(first_missing):]
	// The first record's part is made again in each of `rounds` records, each `size` nodes past the one before, and
	// the rest's part once.
	Part :: struct {
		answers: []Scan_Answer,
		missing: []Scan_Missing,
		rounds:  int,
		step:    tape.Node_Index,
	}
	parts := [2]Part{{first, first_missing, rounds, tape.Node_Index(r.size)}, {rest, rest_missing, 1, 0}}
	live, names := 0, 0
	for a in first {
		live += rounds * int(!a.dead)
	}
	// One pass counts the rest's answers and checks their order.
	unordered := false
	for a, i in rest {
		live += int(!a.dead)
		unordered ||= i > 0 && scan_answer_before(a, rest[i - 1])
	}
	if unordered {
		slice.stable_sort_by(rest, scan_answer_before)
	}
	if h.demand.limited {
		// A path keeps its first answers in document order, up to its limit. A limited demand replays no record, so each
		// answer counts once.
		runtime.mem_zero(raw_data(made), len(made) * size_of(u32))
		for &a in answers {
			if limit := h.demand.paths[a.path].limit; !a.dead && limit > 0 {
				a.dead = made[a.path] == limit
				made[a.path] += u32(!a.dead)
				live -= int(a.dead)
			}
		}
	}
	for part in parts {
		for m in part.missing {
			names += part.rounds * len(m.name)
		}
	}
	n_missing := rounds * len(first_missing) + len(rest_missing)
	x := tape.partial_block(paths, live, int(h.kept.len), n_missing, names, h.dups, allocator) or_return
	x.facts = h.facts
	doc.partial = x
	// Each path's answers in document order, in three steps: count them, turn the counts into starts, place the
	// answers.
	if paths > 1 {
		for part in parts {
			for a in part.answers {
				x.starts[a.path + 1] += u32(part.rounds) * u32(!a.dead)
			}
		}
		for p in 0 ..< paths {
			x.starts[p + 1] += x.starts[p]
		}
	}
	for part in parts {
		for k in 0 ..< part.rounds {
			shift := tape.Node_Index(k) * part.step
			if paths == 1 {
				n := x.starts[0]
				for a in part.answers {
					if !a.dead {
						x.answers[n] = {a.node + shift, a.outcome}
						n += 1
					}
				}
				x.starts[0] = n
				continue
			}
			for a in part.answers {
				if !a.dead {
					x.answers[x.starts[a.path]] = {a.node + shift, a.outcome}
					x.starts[a.path] += 1
				}
			}
		}
	}
	if paths > 0 {
		copy(x.starts[1:], x.starts[:paths])
		x.starts[0] = 0
	}
	#assert(size_of(Scan_Kept) == size_of(type_of(x.kept[0])))
	#assert(offset_of(Scan_Kept, node) == offset_of(type_of(x.kept[0]), node))
	#assert(offset_of(Scan_Kept, index) == offset_of(type_of(x.kept[0]), index))
	runtime.mem_copy_non_overlapping(raw_data(x.kept), h.kept.data, int(h.kept.len) * size_of(Scan_Kept))
	missing_unordered := false
	for m, idx in rest_missing {
		if idx > 0 && m.node < rest_missing[idx - 1].node {
			missing_unordered = true
			break
		}
	}
	if missing_unordered {
		slice.stable_sort_by(rest_missing, proc(a, b: Scan_Missing) -> bool { return a.node < b.node })
	}
	at, i := 0, 0
	for part in parts {
		for k in 0 ..< part.rounds {
			shift := tape.Node_Index(k) * part.step
			for m in part.missing {
				x.missing[i] = {m.node + shift, u32(at), u32(len(m.name))}
				copy(x.names[at:], m.name)
				at += len(m.name)
				i += 1
			}
		}
	}
	return nil
}

@(private = "file", require_results)
scan_answer_before :: #force_inline proc(a, b: Scan_Answer) -> bool {
	return a.pos < b.pos || a.pos == b.pos && a.path < b.path
}
