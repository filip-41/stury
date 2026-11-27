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
			if .Deep in node.flags && tape.step_reach(edge.step) > 0 {
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
	if outcome <= .Wrong_Kind && .Deep in dm.nodes[to].flags {
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
@(private, require_results)
scan_lists :: proc(h: ^Scanner, doc: ^tape.Document, answers: []Scan_Answer, missing: []Scan_Missing, made: []u32) -> runtime.Allocator_Error #no_bounds_check {
	allocator := doc.allocator
	paths := len(h.demand.paths)
	// Fast paths for the common single-record / empty / 1-answer scans without replay or limits.
	if h.record.replayed == 0 && !h.demand.limited && h.kept.len == 0 {
		if len(answers) == 0 && len(missing) == 0 {
			x := tape.partial_block(paths, 0, 0, 0, 0, h.dups, allocator) or_return
			x.facts = h.facts
			doc.partial = x
			return nil
		}
		if len(answers) == 1 && !answers[0].dead && len(missing) <= 1 {
			a := answers[0]
			names := len(missing[0].name) if len(missing) == 1 else 0
			x := tape.partial_block(paths, 1, 0, len(missing), names, h.dups, allocator) or_return
			x.facts = h.facts
			doc.partial = x
			for p in int(a.path) + 1 ..= paths {
				x.starts[p] = 1
			}
			x.answers[0] = {a.node, a.outcome}
			if len(missing) == 1 {
				m := missing[0]
				x.missing[0] = {m.node, 0, u32(len(m.name))}
				copy(x.names, m.name)
			}
			return nil
		}
	}

	Part :: struct {
		answers: []Scan_Answer,
		missing: []Scan_Missing,
		rounds:  int,
		step:    tape.Node_Index,
	}
	parts_buf: [2]Part
	parts: []Part
	tail_answers := answers
	tail_missing := missing
	live := 0
	if r := &h.record; r.replayed > 0 {
		rounds := int(r.replayed) + 1
		first, first_missing := answers[:r.answers], missing[:r.missing]
		tail_answers, tail_missing = answers[len(first):], missing[len(first_missing):]
		parts_buf = {{first, first_missing, rounds, tape.Node_Index(r.size)}, {tail_answers, tail_missing, 1, 0}}
		parts = parts_buf[:]
		for a in first {
			live += rounds * int(!a.dead)
		}
	} else {
		parts_buf[0] = {answers, missing, 1, 0}
		parts = parts_buf[:1]
	}

	unordered := false
	for a, i in tail_answers {
		live += int(!a.dead)
		unordered ||= i > 0 && scan_answer_before(a, tail_answers[i - 1])
	}
	if unordered {
		slice.stable_sort_by(tail_answers, scan_answer_before)
	}
	if h.demand.limited {
		runtime.mem_zero(raw_data(made), len(made) * size_of(u32))
		for &a in answers {
			if limit := h.demand.paths[a.path].limit; !a.dead && limit > 0 {
				a.dead = made[a.path] == limit
				made[a.path] += u32(!a.dead)
				live -= int(a.dead)
			}
		}
	}

	n_missing, names := 0, 0
	for part in parts {
		n_missing += part.rounds * len(part.missing)
		for m in part.missing {
			names += part.rounds * len(m.name)
		}
	}
	x := tape.partial_block(paths, live, int(h.kept.len), n_missing, names, h.dups, allocator) or_return
	x.facts = h.facts
	doc.partial = x

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
	dst := raw_data(x.answers)
	for part in parts {
		for k in 0 ..< part.rounds {
			shift := tape.Node_Index(k) * part.step
			if paths == 1 {
				n := x.starts[0]
				for a in part.answers {
					if !a.dead {
						dst[n] = {a.node + shift, a.outcome}
						n += 1
					}
				}
				x.starts[0] = n
				continue
			}
			for a in part.answers {
				if !a.dead {
					dst[x.starts[a.path]] = {a.node + shift, a.outcome}
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
	if h.kept.len > 0 {
		runtime.mem_copy_non_overlapping(raw_data(x.kept), h.kept.data, int(h.kept.len) * size_of(Scan_Kept))
	}
	if n_missing > 0 {
		for i in 1 ..< len(tail_missing) {
			if tail_missing[i].node < tail_missing[i - 1].node {
				slice.stable_sort_by(tail_missing, proc(a, b: Scan_Missing) -> bool { return a.node < b.node })
				break
			}
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
	}
	return nil
}

@(private = "file", require_results)
scan_answer_before :: #force_inline proc(a, b: Scan_Answer) -> bool {
	return a.pos < b.pos || a.pos == b.pos && a.path < b.path
}
