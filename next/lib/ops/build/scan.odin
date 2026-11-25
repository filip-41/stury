package build

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The hook of a scan: a `Builder` that keeps only what the paths of a demand reach. Its registers are the builder's.
// A container on the paths has a frame, which holds the demand nodes live in it. A value a path ends at is kept as its
// grain says (whole, as its keys and count, or as its node), and its steps are still followed when longer paths go on
// inside it.
Scanner :: struct {
	b:           Builder,
	demand:      ^tape.Demand,
	frames:      [dynamic]Scan_Frame, // the containers on the paths, the root's first, one per builder level
	// By level, the frame an element of the array at the level above opened with. The array's later elements of its
	// kind reopen with it. Valid while the array's `element` is not `End`.
	elements:    [dynamic]Scan_Frame,
	live:        [dynamic]u32, // the demand nodes live in the frames, each frame's from its `live`
	picks:       [dynamic]u32, // the demand nodes that took the coming value
	answers:     [dynamic]Scan_Answer,
	kept:        [dynamic]Scan_Kept,
	missing:     [dynamic]Scan_Missing,
	ring:        [dynamic]Scan_Ring, // what the scan held before each element a step from the end can still take
	tokens:      [dynamic]tape.Token, // the token of each element a replaying array's negative `Index` can still take
	// The marks of the `Name` steps of the deep demand nodes of each open frame that has them, as they were before it
	// opened, since such a step is live in the frames inside it too.
	saved:       [dynamic]u64,
	rewalk:      Rewalk, // the proc that gives this hook the value at `lo` again
	walk:        rawptr, // the walk giving this hook its tokens, which `rewalk` reads in
	// For each demand edge whose key met a member of an object: in the high 32 bits the generation of the object's
	// frame, in the low 32 bits the number of answers made before it. A mark is valid only for the frame of its
	// generation.
	marks:       []u64,
	made:        []u32, // with a limited demand, the answers each path holds that no step took back
	// With `facts`, the comments before the next token start at `wait_from` in the builder's facts. They mark the node
	// `wait_at` that the token is stored at, unless the walk passes the token while that node is still the next one
	// written.
	wait_from:   int,
	wait_at:     tape.Node_Index,
	passed:      tape.Node_Index, // with `facts`, the node written next when the walk last passed a value
	facts:       bool, // `Demand.facts`
	opens:       u32, // the frames opened, so the last one's generation. A frame is a node, which keeps this from wrapping
	done:        []bool, // the paths settled, a bool per path, kept while `settles`
	pending:     int, // the paths not done
	key:         tape.Token, // with `has_key`, the key of the coming value
	has_key:     bool,
	by_place:    bool, // an `Index` picked the coming value, so it keeps a `Scan_Kept`
	forced:      bool, // the coming value is element `forced_at` of its array, read again with its picks made
	forced_at:   u64,
	replaying:   bool, // inside a `rewalk`, where every array keeps the elements its negative indexes may take
	end_of:      Scan_End, // what the next token is, when it is the `End` of a container
	dups:        tape.Duplicates, // the read's policy, resolved
	rewalks:     bool, // the format has `.Rewalk`, so an array whose elements only steps from the end take replays
	// Whether `scanner_key_skip_hook` skips a member no step takes at its key. A scan that keeps facts, which
	// `scan_pass` places, does not, nor does a read in pieces of a format whose window may end between a key and its
	// value. A delimited window never does, so its scan sets it when it keeps no facts.
	key_skips:   bool,
	// Every step from the root is an `All` with no limit, so the members a step takes are the same in every child of
	// the root, as a walk of `.Columns` needs to pass the columns it learnt from one record in the rest.
	alike:       bool,
	replay:      hook.Replay,
	record:      Scan_Record, // the first record, which a `fixed` walk's later records are made again from
	stop:        bool, // `stop_early`
	stopped:     bool,
	// Under `stop_early`, or a limit on a path or a step, the scan tracks its settled paths. Once all are, `stop_early`
	// ends the walk, and otherwise the scan keeps nothing more while the walk judges the rest of the text. A scan of
	// facts takes every token, as the comments past the last settled value may be a kept node's.
	settles:     bool,
	// `holds` is set for a scan of a text in pieces, which copies the bytes it keeps out of each window. `held` is the
	// spans, `bytes` their bytes, and `hold_from` the offset from which the walk's tokens are not held yet.
	holds:       bool,
	held:        [dynamic]tape.Held_Span,
	bytes:       [dynamic]u8,
	hold_from:   u64,
	held_live:   int, // the bytes held once the last `hold_drop` ran
	// The walk gives its tokens out of text order, as a table of a TOML text that later statements add to does, so the
	// scan holds the text itself, once, one span from its first byte, and not the bytes of each token.
	scattered:   bool,
	// What a key token's offsets index: the document's `src`, or the bytes a read of a text in pieces holds the keys in
	// once they lie before its window, as a delimited text's header does.
	key_text:    []u8,
	// The span of the text whose bytes the keys of later nodes name, as a delimited text's header names each row's
	// cells, which a scan in pieces holds whole, once, and not per key. Empty for a text whose keys lie before their
	// values.
	head:        [2]u64,
	room:        ^Scan_Room,
	dropped:     u64, // the members the walk passed with no token since the last `End`, which the open object counts
	protocol:    hook.Protocol(SCANNER_CAPS, hook.Levels(scanner_levels_held, scanner_levels_grow), hook.Unused, hook.Keeps(Builder, scanner_builder, builder_keep_whole, builder_keep_stubs)),
}

SCANNER_CAPS :: hook.Capabilities{.Skips, .Levels, .Keeps, .Walk, .Credits, .Columns}

// Which container's `End` is the next token, when this hook skipped it or kept it as a whole.
Scan_End :: enum u8 {
	None,
	Skipped, // a container this hook skipped
	Picked, // a container picks took, kept whole or stored as one node, its picks still in `picks`
	Settled, // every path is settled without `stop_early`, so no token is taken from here on
}

// The open stack of a scanner, which is its builder's, as `hook.Levels` reads it.
@(private)
scanner_levels_held :: #force_inline proc "contextless" (h: rawptr) -> int {
	return len((^Scanner)(h).b.stack)
}

@(private)
scanner_levels_grow :: #force_inline proc "contextless" (h: rawptr, want: int, _: ^hook.Regs, _: u64) -> bool {
	return builder_deepen(&(^Scanner)(h).b, want, nil, 0)
}

// The builder a scanner keeps containers with, as `hook.Keeps` reads it.
@(private)
scanner_builder :: #force_inline proc "contextless" (h: rawptr) -> rawptr {
	return &(^Scanner)(h).b
}

@(private)
builder_keep_whole :: #force_inline proc "contextless" (h: rawptr, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	return builder_hook_kept((^Builder)(h), s, t)
}

@(private)
builder_keep_stubs :: #force_inline proc "contextless" (h: rawptr, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	return builder_hook_stubs((^Builder)(h), s, t)
}

// Gives hook `h` the value at `lo` again from registers `s`. Returns the walk's result.
Rewalk :: #type proc "contextless" (h: ^Scanner, s: ^hook.Regs, lo: u64) -> hook.Walk_Result

// A container on the paths.
@(private)
Scan_Frame :: struct {
	count:   u64, // the children passed
	live:    u32, // its demand nodes in `Scanner.live`
	n_live:  u32,
	ring:    u32, // its entries in `Scanner.ring`, or in `Scanner.tokens` when it `replays`, `ring_k` of them
	ring_k:  u32,
	whole:   bool, // every child is kept, a path ending at the container or at one holding it
	object:  bool,
	passes:  bool, // an object whose members no step takes are passed
	alls:    bool, // an `All` takes any member, every child is kept, or every key is
	gen:     u32, // its generation, which the marks of its members carry
	lengths: u64, // a bit per length its `Name` steps have, past 63 counted from 0
	heads:   u64, // a bit per first byte its `Name` steps have, by the byte's low six bits
	tails:   u64, // a bit per last byte its `Name` steps have, by the byte's low six bits
	// The number of steps its close still has to check because no child has met them: the `Name` steps of an object
	// that no member has met yet, or the `Index` steps of an array.
	unmet:   u32,
	fills:   u64, // the fewest elements an array has for each of its `Index` steps to take one
	places:  u64, // a bit per element below 64 an `Index` step takes
	// An array not kept whole whose positional steps are all non-negative indexes, so an element no `Index` takes is
	// passed with no picks.
	indexed: bool,
	// With `indexed`, or in an object that `passes`, the demand node of its one `Index` or `Name` step when that node has
	// no step past it, so a scalar child the step takes is kept with no picks. 0 for none, as the root is no step's node.
	leaf:    u32,
	// In an object that `passes`, one more than the edge of its one live demand node's one step when that step is a
	// `Name` and the node is not deep, so a key is judged with no look at the demand node. 0 for none.
	named:   u32,
	// Its positional steps are all negative indexes, so each element is passed and the ones they take are read again at
	// its close.
	replays: bool,
	// Its positional steps are all from the end and the format cannot walk an element again, so each element they may
	// take is kept, and its nodes go once no step can take it.
	drops:   bool,
	// An object a path ends at with grain `.Keys`, so each member no step takes is kept with its value, a container
	// value as one unread node.
	keys:    bool,
	slices:  bool, // it has `Slice` steps, which pick past the ring's check in `scan_element`, so it has a ring
	deep:    bool, // a demand node live in it is deep, so the marks of its `Name` steps are saved while it is open
	// For an array with no positional steps, where each element picks the same demand nodes: the kind of the element
	// whose frame `Scanner.elements` holds at the level below, else `End`. An element of that kind reopens it.
	element: tape.Kind,
	// Elements `takes_from` up to `takes_to` are those every positional step of an array takes (a `Slice` from the
	// start or an `All` with a limit), and they pick the same demand nodes.
	takes_from:    u64,
	takes_to:      u64,
}

// An answer as the walk made it, its node as `tape.answer` gives it.
@(private)
Scan_Answer :: struct {
	node:    tape.Node_Index,
	path:    u32,
	pos:     u64, // twice the value's node index, or twice the close's less one for a miss the close found
	leaf:    u32, // the demand node the answer came from
	outcome: tape.Presence,
	dead:    bool, // a repeated key or a negative index took it back
}

// The first record of the root array of a `fixed` walk, closed, when each later record makes what it made: a node for
// the record, the key and value of each column it took, and the answers and missing names it made, at nodes `size`
// on from the record before. Those answers and names are all the scan's lists hold, and the later records' are made
// from them in `scan_lists`. A replayed record pushes no frame, and the walk gives its cells with no token, which its
// `End` makes.
@(private)
Scan_Record :: struct {
	open:     tape.Node_Index, // the first record's node
	size:     u32, // its nodes
	spelling: u16, // its node's spelling once closed
	answers:  u32, // the answers it made
	missing:  u32, // the missing names it recorded
	replayed: u32, // the records after it, each replaying it
	ready:    bool, // the later records are replayed
	tried:    bool, // the first record closed
	on:       bool, // the open record replays it, with its cells in `Scanner.cells` while `replays`, else as tokens
	lo:       u64, // while `replays`, the open record's first byte
}

// A child kept by its place in its container, laid out as the document's kept child.
@(private)
Scan_Kept :: struct {
	node:  tape.Node_Index,
	index: u32,
}

@(private)
Scan_Missing :: struct {
	node: tape.Node_Index,
	name: string,
}

// What a scan held, as the lengths of its lists, when an element a ring keeps began. Taking the element back drops
// what the lists gained since.
@(private)
Scan_Ring :: struct {
	answers, node, kept, missing, counts, facts: u32,
}

// The room a scan's lists start in, on the caller's stack, so that a scan of few paths and answers allocates no list.
// A list that outgrows its part moves to the allocator, and a demand with more edges than `marks` holds, or more paths
// than `done` holds, allocates those too.
Scan_Room :: struct {
	frames:  [8]Scan_Frame,
	elements: [8]Scan_Frame,
	live:    [16]u32,
	picks:   [16]u32,
	answers: [16]Scan_Answer,
	kept:    [16]Scan_Kept,
	marks:   [32]u64,
	made:    [32]u32,
	done:    [32]bool,
}

// Sets up `h` as a scanner of `demand` over `src`, with `nodes`, `most` and `frames` as `builder_start` takes them.
// The node room grows as it fills. With no `rewalk` it reads each value once, keeping nodes where a replay would read a
// value again.
@(require_results)
scanner_start :: proc(h: ^Scanner, src: []u8, format: ^tape.Format, demand: ^tape.Demand, dups: tape.Duplicates, read: tape.Read_Options, rewalk: Rewalk, nodes, most: int, frames: []u64, room: ^Scan_Room, allocator: runtime.Allocator, lent: []tape.Node = nil, budget: ^hook.Memory_Budget = nil) -> (err: runtime.Allocator_Error) {
	h^ = {}
	builder_start(&h.b, src, format, nodes, most, frames, allocator, budget, lent)
	h.key_text = src
	if h.b.err != nil {
		return h.b.err
	}
	defer if err != nil {
		scanner_free(h, allocator)
		delete(h.b.counts)
		tape.destroy(&h.b.doc)
		h^ = {}
	}
	h.demand, h.rewalk, h.rewalks = demand, rewalk, .Rewalk in format.caps && rewalk != nil
	h.key_skips, h.alike = !demand.facts, tape.demand_children_alike(demand)
	h.dups = tape.read_dups(format, dups)
	h.stop, h.pending = read.stop_early, len(demand.paths)
	h.settles = h.stop || !demand.facts && (demand.limited || scan_cuts(demand))
	h.b.keep_facts, h.facts, h.passed, h.wait_at = demand.facts, demand.facts, tape.NO_NODE, tape.NO_NODE
	h.room = room
	h.held.allocator, h.bytes.allocator = allocator, allocator
	made := len(demand.paths) if demand.limited else 0
	if len(demand.edges) <= len(room.marks) && len(demand.paths) <= len(room.done) {
		h.marks, h.done = room.marks[:len(demand.edges)], room.done[:len(demand.paths)]
		if made > 0 {
			h.made = room.made[:made]
		}
	} else {
		// The marks, the answers made and the settled paths share one block.
		marks, counts := len(demand.edges) * size_of(u64), made * size_of(u32)
		block, merr := runtime.mem_alloc_non_zeroed(marks + counts + len(demand.paths), align_of(u64), allocator)
		if e := took(merr, raw_data(block), marks + counts + len(demand.paths)); e != nil {
			return e
		}
		h.marks = ([^]u64)(raw_data(block))[:len(demand.edges)]
		if made > 0 {
			h.made = ([^]u32)(raw_data(block[marks:]))[:made]
		}
		h.done = ([^]bool)(raw_data(block[marks + counts:]))[:len(demand.paths)]
	}
	scan_lists_reset(h, room, allocator)
	// Every pick of a value or key is of a distinct edge, or the root, so `picks` never grows past this.
	if !scan_reserve(h, &h.picks, len(demand.edges) + 1) {
		err = h.b.err
	}
	return
}

// Starts `h` for another value of the read it was started for by `scanner_start` and ended by `scanner_end`, with the
// same arguments. What the demand and the read fix is kept, and the lists go back to the room. A scanner never started,
// or whose marks or picks outgrow the room, is started as `scanner_start` does.
@(require_results)
scanner_restart :: proc(h: ^Scanner, src: []u8, format: ^tape.Format, demand: ^tape.Demand, dups: tape.Duplicates, read: tape.Read_Options, rewalk: Rewalk, nodes, most: int, frames: []u64, room: ^Scan_Room, allocator: runtime.Allocator, lent: []tape.Node = nil) -> runtime.Allocator_Error {
	if h.demand != demand || !scan_in_room(h, raw_data(h.marks)) || len(demand.edges) >= len(room.picks) {
		return scanner_start(h, src, format, demand, dups, read, rewalk, nodes, most, frames, room, allocator, lent)
	}
	if h.b.doc.allocator == allocator {
		builder_again(&h.b, src, format, nodes, most, frames, nil, lent)
	} else {
		builder_start(&h.b, src, format, nodes, most, frames, allocator, nil, lent)
	}
	if h.b.err != nil {
		return h.b.err
	}
	h.b.keep_facts = h.facts
	h.walk, h.stopped, h.has_key, h.by_place, h.forced, h.replaying, h.dropped = nil, false, false, false, false, false, 0
	h.end_of, h.opens, h.pending, h.passed, h.wait_at = .None, 0, len(demand.paths), tape.NO_NODE, tape.NO_NODE
	h.wait_from, h.hold_from, h.held_live = 0, 0, 0
	h.replay, h.record = {}, {}
	scan_lists_reset(h, room, allocator)
	return nil
}

// Points the scan's lists at `room`, empty, and the rest at `allocator`, and clears its marks, answers made and settled
// paths. No frame has generation 0, so a zero mark is valid for none.
@(private)
scan_lists_reset :: proc "contextless" (h: ^Scanner, room: ^Scan_Room, allocator: runtime.Allocator) {
	room_list(&h.frames, room.frames[:], allocator)
	room_list(&h.elements, room.elements[:], allocator)
	room_list(&h.live, room.live[:], allocator)
	room_list(&h.picks, room.picks[:], allocator)
	room_list(&h.answers, room.answers[:], allocator)
	room_list(&h.kept, room.kept[:], allocator)
	h.missing, h.ring, h.tokens, h.saved = nil, nil, nil, nil
	h.missing.allocator, h.ring.allocator, h.tokens.allocator, h.saved.allocator = allocator, allocator, allocator, allocator
	runtime.mem_zero(raw_data(h.marks), len(h.marks) * size_of(u64))
	runtime.mem_zero(raw_data(h.made), len(h.made) * size_of(u32))
	runtime.mem_zero(raw_data(h.done), len(h.done))
}

// Why a scan of `demand` over a text of `format` under `opts` is refused, as `path_read_refused` judges it, or for a
// step from the end past a `Descend`, which would take back the answers under an element it passes that a `Descend`
// from a value inside that element may give again. `query` answers such a path.
@(private)
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
@(private)
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

// Whether `p` is in the room the scan's lists start in.
@(private)
scan_in_room :: #force_inline proc "contextless" (h: ^Scanner, p: rawptr) -> bool {
	at := uintptr(p) - uintptr(h.room)
	return at < size_of(Scan_Room)
}

// Takes a walk's token into the partial document.
scanner_hook :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	return scanner_take(h, s, t, false)
}

// `scanner_hook` for a walk that passes a member no step takes at its key: one whose members are placed by position,
// as a delimited text's cells are and `.Columns` reads, and one that owes a container's `End` only when it gives the
// container, as TOML's, whose `End` is found in its table tree. A walk of another format gives the value, which costs
// it less.
scanner_key_skip_hook :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	return scanner_take(h, s, t, true)
}

@(private)
scanner_take :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token, $COLUMNS: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	when COLUMNS {
		// Every record of the root array after the first replays it, which reopens its frame.
		if h.record.ready && t.kind == .Object && s.c == 1 {
			return scan_record_open(h, s, t)
		}
	}
	if t.role > .Key {
		if h.facts {
			return s, scan_fact(h, s, t)
		}
		return s, .Next
	}
	if h.end_of != .None {
		end := h.end_of
		if end == .Settled {
			return s, read_rest(t)
		}
		h.end_of = .None
		if end == .Picked {
			return scan_past(h, s, h.picks[:], s.c)
		}
		return s, .Next
	}
	// A key that no `Name` of the open object can match is passed without further work. So is a member no step took.
	// With `COLUMNS` and `key_skips`, in an object whose members no step takes, a member no step took is counted and
	// its value skipped at the key. Whether a step takes a member depends on its key and its place only, as `.Columns`
	// needs.
	when COLUMNS {
		if h.record.on && t.kind != .End {
			return scan_record_token(h, s, t)
		}
	}
	if t.role == .Key {
		f := &h.frames[len(h.frames) - 1]
		clear(&h.picks)
		if !f.alls && scan_key_unmatched(h, f, t) {
			when COLUMNS {
				if f.passes && h.key_skips {
					f.count += 1
					return s, .Skip
				}
			}
			return s, .Next
		}
		h.key, h.has_key, h.by_place = t, true, false
		// The scan's document keeps the key, and a document carries no credit.
		h.key.spelling = tape.without_credit(h.key.spelling)
		// A `Name` takes a key of any scalar kind by its text.
		if f.named != 0 {
			e := f.named - 1
			edge := &h.demand.edges[e]
			if t.kind <= .Plain && tape.key_names(h.b.doc.format, h.key_text, t, string(edge.step.(tape.Name))) {
				scan_name_meets(h, f, e, edge.to, false)
			}
		} else if t.kind <= .Plain {
			scanner_key(h, t, true)
		} else {
			scanner_key(h, t, false)
		}
		when COLUMNS {
			if f.passes && h.key_skips && len(h.picks) == 0 {
				h.has_key = false
				f.count += 1
				return s, .Skip
			}
		}
		return s, .Next
	}
	if t.kind == .End {
		when COLUMNS {
			if h.record.on {
				return scan_record_close(h, s)
			}
		}
		return scanner_close(h, s, t, COLUMNS)
	}
	if s.c > 0 && !h.forced {
		f := &h.frames[s.c - 1]
		if f.passes || f.indexed {
			if f.passes && len(h.picks) == 0 || f.indexed && !scan_index_takes(f) {
				f.count += 1
				return scan_pass(h, s, t)
			}
			if f.leaf != 0 && t.kind <= .Plain {
				return scan_leaf(h, s, t, f)
			}
		}
		if t.kind == f.element && f.count < f.takes_to {
			return scan_reopen(h, s, t, f)
		}
	}
	if t.kind <= .Plain {
		return scanner_value(h, s, t, true)
	}
	return scanner_value(h, s, t, false)
}

// Whether an `Index` step of the array `f` takes its next element.
@(private)
scan_index_takes :: #force_inline proc "contextless" (f: ^Scan_Frame) -> bool {
	return f.count < f.fills && (f.count >= 64 || f.places & (1 << f.count) != 0)
}

// Whether no `Name` of the object `f` can match key `t`, because none has its length, its first byte or its last. A key
// that needs decoding is judged by its decoded length when its spelling holds an exact credit, otherwise never.
@(private)
scan_key_unmatched :: #force_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame, t: tape.Token) -> bool #no_bounds_check {
	if tape.text_decodes(t) {
		if t.kind == .Number || t.spelling & tape.SPELLING_CREDIT_EXACT == 0 {
			return false
		}
		d := u64(t.n) - u64(tape.spelling_credit(t.spelling))
		return f.lengths & (1 << (d & 63)) == 0
	}
	return f.lengths & (1 << (t.n & 63)) == 0 || t.n > 0 && (f.heads & (1 << (h.key_text[t.lo] & 63)) == 0 || f.tails & (1 << (h.key_text[t.lo + u64(t.n) - 1] & 63)) == 0)
}

// Returns the partial document the walk built, or the error that ended it with everything freed. `regs` are the hook's
// registers at the walk's end and `root_close` is the end of the root value.
@(require_results)
scanner_end :: proc(h: ^Scanner, regs: hook.Regs, root_close: u64, err: tape.Error) -> (doc: tape.Document, e: tape.Error) {
	allocator := h.b.doc.allocator
	defer scanner_free(h, allocator)
	regs := regs
	e = err
	if e == nil {
		e = builder_error(&h.b)
	}
	if e == nil && (h.stopped || h.end_of == .Settled) {
		// The containers the stop left open are on the paths, their counts not known, as their ends were not read. A
		// replaying array stops only in its replay, with every element passed, so its count is known.
		for regs.c > 0 {
			f := h.frames[regs.c - 1]
			open := tape.Node_Index(regs.b >> 32)
			if !f.replays {
				f.count = 0
			}
			regs = scan_close_partial(h, regs, f.count)
			if !f.replays {
				h.b.doc.nodes[open].spelling |= tape.MAX_CHILDREN
			}
		}
	}
	if e == nil && len(h.b.doc.facts) > 0 {
		scan_check_facts(h, regs)
	}
	doc, e = builder_end(&h.b, regs, 0 if h.stopped else root_close, e)
	if e != nil {
		return
	}
	if h.stopped {
		doc.flags += {.Stopped}
	}
	if refused := scan_lists(h, &doc, h.answers[:], h.missing[:], h.made); refused != nil {
		tape.destroy(&doc)
		return {}, refused
	}
	if h.holds {
		if refused := hold_spans(h, &doc); refused != nil {
			tape.destroy(&doc)
			return {}, refused
		}
		doc.src = h.bytes[:]
		doc.flags += {.Owns_Src}
		h.bytes = {}
	}
	return
}

@(private)
scanner_key :: proc "contextless" (h: ^Scanner, t: tape.Token, $NAMED: bool) #no_bounds_check {
	f := &h.frames[len(h.frames) - 1]
	dm := h.demand
	for n in h.live[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for e in node.edges ..< node.edges + node.n_edges {
			edge := &dm.edges[e]
			#partial switch step in edge.step {
			case tape.Name:
				if NAMED && tape.key_names(h.b.doc.format, h.key_text, t, string(step)) {
					scan_name_meets(h, f, e, edge.to, node.deep)
				}
			case tape.All:
				if tape.all_takes(step.limit, f.count, true, h.dups) {
					scan_put(&h.picks, edge.to)
				}
			}
		}
	}
}

// Takes the member of the object `f` whose key the `Name` of demand edge `e`, to node `to`, reads: the first of its key,
// or under `.Last` one that takes back what the member before it answered.
@(private)
scan_name_meets :: #force_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame, e, to: u32, deep: bool) #no_bounds_check {
	mark := h.marks[e]
	if u32(mark >> 32) != f.gen {
		f.unmet -= 1
	} else if !deep {
		// Past a `Descend` a `Name` takes each member of its key.
		switch tape.name_take(h.dups, true) {
		case .Take:
		case .Pass:
			return
		case .Replace:
			scan_kill(h, int(u32(mark)), len(h.answers), to)
		}
	}
	h.marks[e] = u64(f.gen) << 32 | u64(len(h.answers))
	scan_put(&h.picks, to)
}

@(private)
scanner_value :: proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token, $scalar: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	s := s
	d := s.c
	index: u64
	whole := false
	if h.forced {
		h.forced = false
		index = h.forced_at
	} else if d == 0 {
		clear(&h.picks)
		h.by_place = false
		if len(h.demand.paths) > 0 {
			scan_put(&h.picks, 0)
		} else if h.stop {
			h.stopped = true
			return s, .Stop
		}
	} else {
		f := &h.frames[d - 1]
		index = f.count
		f.count += 1
		whole = f.whole
		if !f.object {
			ok: bool
			if s, ok = scan_element(h, s, f, index, t, d); !ok {
				return s, scan_halt(h, t)
			}
		} else if f.keys && len(h.picks) == 0 {
			return scan_stub(h, s, t)
		}
	}
	if len(h.picks) == 0 && !whole {
		return scan_pass(h, s, t)
	}
	owner := tape.Node_Index(s.b >> 32)
	if h.has_key {
		s, _ = builder_step(&h.b, s, h.key, false, true)
		h.has_key = false
	}
	at := builder_cursor(&h.b, s)
	if h.by_place {
		scan_push(h, &h.kept, Scan_Kept{at, u32(index)})
	}
	dm := h.demand
	live := u32(len(h.live))
	answered := len(h.answers)
	ends, stubs := false, false
	// A `Descend` takes the value itself: the node it leads to takes what its node takes, so the list grows as it is read.
	for i := 0; i < len(h.picks); i += 1 {
		n := h.picks[i]
		node := dm.nodes[n]
		if node.descend != 0 {
			scan_descend(h, node.descend)
		}
		for p in dm.ends[node.ends:][:node.n_ends] {
			scan_answer(h, at, p, .Found, 2 * u64(at), n)
		}
		ends ||= node.whole
		stubs ||= node.keys
		when scalar {
			// No step enters a scalar.
			for edge in dm.edges[node.edges:][:node.n_edges] {
				paths_fail(h, dm, edge.to, tape.step_refused(t.kind), d, at, owner, 2 * u64(at), scan_answer)
			}
		} else {
			enters := false
			for edge in dm.edges[node.edges:][:node.n_edges] {
				if tape.step_enters(edge.step, t.kind) {
					enters = true
				} else {
					paths_fail(h, dm, edge.to, .Wrong_Kind, d, at, owner, 2 * u64(at), scan_answer)
				}
			}
			// An array a `.Keys` grain keeps has a frame that counts its elements.
			if enters || node.keys && t.kind == .Array {
				scan_push(h, &h.live, n)
			}
		}
	}
	when scalar {
		s, _ = builder_step(&h.b, s, t, false, true)
		return scan_past(h, s, h.picks[:], d)
	}
	if u32(len(h.live)) > live {
		s, _ = builder_step(&h.b, s, t, false, true)
		scan_open(h, t, live, whole || ends)
		if d > 0 && h.b.err == nil {
			scan_keep_element(h, d, t.kind, len(h.answers) == answered)
		}
		return s, .Stop if h.b.err != nil else .Next
	}
	if h.b.err != nil {
		return s, .Stop
	}
	// Kept whole: a value a path ends at, and a child of a container kept whole. An object a `.Keys` grain keeps is
	// kept as its members, with each container value as one node. A container no step could enter is stored as one
	// node. The hook is called next at its `End`, so `picks` holds until then.
	h.end_of = .Picked
	if whole || ends {
		return s, .Keep
	}
	if stubs && t.kind == .Object {
		h.b.stubs = d + 1
		return s, .Keep_Stubs
	}
	ok: bool
	if s, ok = builder_unread(&h.b, s, t); !ok {
		return s, .Stop
	}
	return s, .Skip
}

// Keeps a member no path takes of an object a `.Keys` grain keeps: its key, and its value `t`, a container as one
// unread node.
@(private)
scan_stub :: proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	h.has_key = false
	kept, action := builder_step(&h.b, s, h.key, false, true)
	if action == .Stop {
		return kept, .Stop
	}
	if t.kind <= .Plain {
		return builder_step(&h.b, kept, t, false, true)
	}
	ok: bool
	if kept, ok = builder_unread(&h.b, kept, t); !ok {
		return kept, .Stop
	}
	h.end_of = .Skipped
	return kept, .Skip
}

// Keeps scalar child `t` of the container `f`, which its one step takes to demand node `f.leaf`: the child's node, with
// its key in an object and its place in an array, and the answers of the paths the node ends.
@(private)
scan_leaf :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token, f: ^Scan_Frame) -> (hook.Regs, hook.Action) #no_bounds_check {
	s := s
	if f.object {
		s, _ = builder_step(&h.b, s, h.key, false, true)
		h.has_key = false
	}
	at := builder_cursor(&h.b, s)
	if !f.object {
		scan_push(h, &h.kept, Scan_Kept{at, u32(f.count)})
	}
	f.count += 1
	dm := h.demand
	node := dm.nodes[f.leaf]
	for p in dm.ends[node.ends:][:node.n_ends] {
		scan_answer(h, at, p, .Found, 2 * u64(at), f.leaf)
	}
	kept, _ := builder_step(&h.b, s, t, false, true)
	return scan_left(h, kept)
}

// Opens again the frame the first child of the container `f` opened with, for child `t` of the same kind, a member with
// its key. Past the elements its positional steps all take, the next element picks again.
@(private)
scan_reopen :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token, f: ^Scan_Frame) -> (hook.Regs, hook.Action) #no_bounds_check {
	d := s.c
	f.count += 1
	if f.count >= f.takes_to {
		f.element = .End
	}
	live := f.live + f.n_live
	opened := s
	if h.has_key {
		opened, _ = builder_step(&h.b, s, h.key, false, true)
		h.has_key = false
	}
	action: hook.Action
	opened, action = builder_step(&h.b, opened, t, false, true)
	if action == .Stop {
		return opened, .Stop
	}
	if !scan_reserve(h, &h.frames, 1) {
		return opened, .Stop
	}
	frames := (^runtime.Raw_Dynamic_Array)(&h.frames)
	g := &([^]Scan_Frame)(frames.data)[frames.len]
	frames.len += 1
	g^ = h.elements[d]
	h.opens += 1
	g.gen, g.live = h.opens, live
	// The element's live demand nodes are those it opened with, past the array's. No frame writes over them between one
	// element of the array and the next, since no other frame opens at its level.
	(^runtime.Raw_Dynamic_Array)(&h.live).len = int(live + g.n_live)
	return opened, .Next
}

// Opens a record that replays the first record, which the root counts, with no frame. When its nodes fit the room,
// none of them grows it, so its cells come with no token and its nodes are stored at its `End`. Otherwise its node is
// stored now and its cells come as tokens, so the room grows at the token whose node finds it full, as it does for a
// record read whole.
@(private)
scan_record_open :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	h.frames[0].count += 1
	h.record.on = true
	if s.a + u64(h.record.size) * size_of(tape.Node) <= h.b.end {
		h.replay.replays, h.replay.given, h.record.lo = true, 0, t.lo
		return s, .Next
	}
	return scan_record_grows(h, s, t)
}

@(private, cold)
scan_record_grows :: #force_no_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	opened, action := builder_step(&h.b, s, t, false, true)
	return opened, .Stop if action == .Stop else .Next
}

// Takes key or value `t` of a replayed record whose cells come as tokens: a value stores its key's node and its own.
@(private, cold)
scan_record_token :: #force_no_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if t.role == .Key {
		h.key, h.has_key = t, true
		h.key.spelling = tape.without_credit(h.key.spelling)
		return s, .Next
	}
	s := s
	s, _ = builder_step(&h.b, s, h.key, false, true)
	h.has_key = false
	s, _ = builder_step(&h.b, s, t, false, true)
	return s, .Stop if h.b.err != nil else .Next
}

// Closes a replayed record as the first record's close made it: the record's node closed, after the key's and the
// value's node of each column, which are stored here when the walk gave the cells in `cells`.
@(private)
scan_record_close :: #force_no_inline proc "contextless" (h: ^Scanner, s: hook.Regs) -> (hook.Regs, hook.Action) #no_bounds_check {
	s := s
	r := &h.record
	h.dropped, r.on = 0, false
	r.replayed += 1
	if h.replay.replays {
		h.replay.replays = false
		h.b.closed = builder_cursor(&h.b, s)
		nodes := ([^]tape.Node)(uintptr(s.a))
		nodes[0] = {r.lo, r.size, .Object, .Value, r.spelling}
		first := h.b.doc.nodes[r.open:]
		for c in 0 ..< r.size / 2 {
			nodes[1 + 2 * c] = first[1 + 2 * c]
			nodes[2 + 2 * c] = h.replay.cells[c]
		}
		s.a += u64(r.size) * size_of(tape.Node)
		s.b += 1
		return s, .Next
	}
	open := tape.Node_Index(s.b >> 32)
	node := &h.b.doc.nodes[open]
	node.n = r.size
	node.spelling = r.spelling
	h.b.closed = open
	s.c -= 1
	s.b = h.b.stack[s.c]
	return s, .Next
}

// Keeps the first record of the root array, frame `f`, closed at node `open` with its nodes up to `end`, for the later
// records to replay, when each makes what it made: the walk is `fixed`, the root opens their frames again, and no
// answer depends on a cell's kind or on what the records before it settled.
@(private, cold)
scan_learn_record :: #force_no_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame, open, end: tape.Node_Index) #no_bounds_check {
	h.record.tried = true
	// Without limits a path settles by its depth only, so a record that settled none leaves the later ones none to
	// settle.
	if !h.replay.fixed || h.facts || h.made != nil || h.pending != len(h.demand.paths) || h.stopped || h.end_of != .None || h.b.err != nil {
		return
	}
	// The columns from `hook.COLUMN_BITS` on share a bit, so a record wider than that may be given the keys of columns
	// it did not take, and a record the walk replays gives at most that many cells.
	if !f.passes || f.count > hook.COLUMN_BITS || len(h.frames) != 2 || len(h.kept) != 0 {
		return
	}
	// The root opens every later record's frame again, and its close makes no answer, so the later records' answers
	// follow the first's in the scan's lists.
	root := h.frames[0]
	if root.object || root.element != .Object || root.takes_to != max(u64) || root.unmet != 0 {
		return
	}
	dm := h.demand
	for n in h.live[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for edge in dm.edges[node.edges:][:node.n_edges] {
			#partial switch _ in edge.step {
			case tape.Name, tape.All:
				// A step into a cell answers by the cell's kind.
				if dm.nodes[edge.to].n_edges != 0 {
					return
				}
			}
		}
	}
	// Every answer and missing name so far is the record's, made in the order of its nodes.
	pos := u64(0)
	for a in h.answers {
		if a.node < open || a.node >= end || a.pos < pos {
			return
		}
		pos = a.pos
	}
	for m in h.missing {
		if m.node != open {
			return
		}
	}
	// Its nodes are the key and value of each column it took.
	if (end - open) % 2 != 1 || int(end - open) / 2 > len(h.replay.cells) {
		return
	}
	for k := open + 1; k < end; k += 2 {
		if h.b.doc.nodes[k].role != .Key || h.b.doc.nodes[k + 1].kind > .Plain {
			return
		}
	}
	h.record = {open = open, size = u32(end - open), spelling = h.b.doc.nodes[open].spelling, answers = u32(len(h.answers)), missing = u32(len(h.missing)), ready = true, tried = true}
}

// Records in the container at depth `d` the frame its child of `kind` just opened, for later children of that kind to
// reopen with. It does so only when the child made no answer, in an array while the elements are those every
// positional step of the array takes, and in an object whose one step is a `Name`, which picks every member it takes
// alike.
@(private)
scan_keep_element :: #force_inline proc "contextless" (h: ^Scanner, d: u64, kind: tape.Kind, reopens: bool) #no_bounds_check {
	f := &h.frames[d - 1]
	// An `Index` picks one element, and a ring keeps an entry per element.
	if f.unmet != 0 || f.ring_k != 0 || f.object && f.named == 0 {
		return
	}
	in_takes := f.count - 1 >= f.takes_from && f.count < f.takes_to
	f.element = .End
	// A reopened element skips `scanner_value`, which lists the kept elements of a partial array, and `scan_open`, which
	// saves the marks of a deep frame.
	if !reopens || !in_takes || h.by_place || h.frames[d].deep {
		return
	}
	elements := (^runtime.Raw_Dynamic_Array)(&h.elements)
	if elements.len <= int(d) {
		if !scan_reserve(h, &h.elements, int(d) + 1 - elements.len) {
			return
		}
		elements.len = int(d) + 1
	}
	h.elements[d] = h.frames[d]
	h.frames[d - 1].element = kind
}

// Passes a value no step took. A container is skipped, giving no more tokens up to its `End`.
@(private)
scan_pass :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	h.has_key = false
	if h.facts {
		if h.passed = builder_cursor(&h.b, s); h.passed == h.wait_at {
			scan_unwait(h, t.lo)
		}
	}

	if t.kind > .Plain {
		h.end_of = .Skipped
		return s, .Skip
	}
	return s, .Next
}

// Takes the demand nodes that pick element `index`, whose token is `t`, of the array `f` at depth `d`. Returns whether
// the walk goes on, which a refused growth or a stop at a cut ends.
@(private)
scan_element :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, f: ^Scan_Frame, index: u64, t: tape.Token, d: u64) -> (hook.Regs, bool) #no_bounds_check {
	s := s
	dm := h.demand
	clear(&h.picks)
	h.by_place = false
	// A replaying array's steps are all from the end, and pick at its close.
	live := h.live[f.live:][:f.n_live] if !f.replays else nil
	for n in live {
		node := dm.nodes[n]
		for edge in dm.edges[node.edges:][:node.n_edges] {
			#partial switch step in edge.step {
			case tape.Index:
				// Every element a negative index may take is kept, and the answers of those it does not take go, unless
				// the array replays the ones it takes.
				if step < 0 && !f.replays || u64(step) == index {
					scan_put(&h.picks, edge.to)
					h.by_place = true
				}
			case tape.All:
				if tape.all_takes(step.limit, index, false, h.dups) {
					scan_put(&h.picks, edge.to)
					// A step or path limit leaves the array partial, so each element it keeps holds its place.
					h.by_place ||= step.limit > 0 || h.demand.limited
				} else if h.settles && index == u64(step.limit) && !scan_cut(h, edge.to, d) {
					return s, false
				}
			case tape.Slice:
				// A slice from the end picks past the ring's check.
				if tape.step_reach(step) == 0 && !scan_slice_pick(h, step, index, edge.to, d) {
					return s, false
				}
			}
		}
	}
	if f.ring_k == 0 {
		return s, true
	}
	// The ring is at the end of its list while the elements arrive, because an inner frame's close cuts the list back,
	// so it grows with the elements up to its size.
	k := u64(f.ring_k)
	slot := f.ring + u32(index % k)
	if f.replays {
		if index >= k {
			h.tokens[slot] = t
			return s, true
		}
		scan_push(h, &h.tokens, t)
		return s, h.b.err == nil
	}
	// Slices from the end pick here, except in a replaying array, whose slices are all from the end and pick at its
	// close.
	if f.slices && !scan_slice_picks(h, f, index, d) {
		return s, false
	}
	if index < k {
		scan_push(h, &h.ring, scan_ring_mark(h, s))
		return s, h.b.err == nil
	}
	// Element `index - k` passes out of the ring, so no negative index takes it.
	next := h.ring[f.ring + u32((index + 1) % k)]
	hi := len(h.answers) if k == 1 else int(next.answers)
	scan_kill_negatives(h, f, int(h.ring[slot].answers), hi, max(u64))
	if f.drops {
		s = scan_drop(h, s, f, h.ring[slot], builder_cursor(&h.b, s) if k == 1 else tape.Node_Index(next.node))
	}
	h.ring[slot] = scan_ring_mark(h, s)
	return s, true
}

@(private)
scan_ring_mark :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs) -> Scan_Ring {
	return {u32(len(h.answers)), u32(builder_cursor(&h.b, s)), u32(len(h.kept)), u32(len(h.missing)), u32(len(h.b.counts)), u32(len(h.b.doc.facts))}
}

// Drops the element of the array `f` whose nodes run from `from.node` to `hi`, and what the scan holds of them, from
// the list lengths `from` records. The nodes past them move down, with every entry that names one, and so do the ring
// entries of the array's later elements.
@(private, cold)
scan_drop :: #force_no_inline proc "contextless" (h: ^Scanner, s: hook.Regs, f: ^Scan_Frame, from: Scan_Ring, hi: tape.Node_Index) -> hook.Regs #no_bounds_check {
	s := s
	lo := tape.Node_Index(from.node)
	gone := hi - lo
	// An element no step picked was not stored.
	if gone == 0 {
		return s
	}
	end := builder_cursor(&h.b, s)
	copy(h.b.doc.nodes[lo:], h.b.doc.nodes[hi:end])
	s.a -= u64(gone) * size_of(tape.Node)
	s.b -= 1
	// Whether the node `at` names stays. Moves it down past the nodes that go.
	moved :: #force_inline proc "contextless" (at: ^tape.Node_Index, lo, hi: tape.Node_Index) -> bool {
		if at^ == tape.NO_NODE || at^ < lo {
			return true
		}
		if at^ < hi {
			return false
		}
		at^ -= hi - lo
		return true
	}

	for &a in h.answers[from.answers:] {
		if a.pos >= 2 * u64(hi) {
			a.pos -= 2 * u64(gone)
		} else if a.pos >= 2 * u64(lo) && !a.dead {
			a.dead = true
			if h.made != nil {
				h.made[a.path] -= 1
			}
		}
		if a.node >= hi {
			a.node -= gone
		}
	}
	kept, missing, counts := int(from.kept), int(from.missing), int(from.counts)
	for k in h.kept[from.kept:] {
		k := k
		if moved(&k.node, lo, hi) {
			h.kept[kept] = k
			kept += 1
		}
	}
	for m in h.missing[from.missing:] {
		m := m
		if moved(&m.node, lo, hi) {
			h.missing[missing] = m
			missing += 1
		}
	}
	for c in h.b.counts[from.counts:] {
		c := c
		if moved(&c.node, lo, hi) {
			h.b.counts[counts] = c
			counts += 1
		}
	}
	gone_kept, gone_missing, gone_counts := u32(len(h.kept) - kept), u32(len(h.missing) - missing), u32(len(h.b.counts) - counts)
	(^runtime.Raw_Dynamic_Array)(&h.kept).len = kept
	(^runtime.Raw_Dynamic_Array)(&h.missing).len = missing
	(^runtime.Raw_Dynamic_Array)(&h.b.counts).len = counts
	for &fact in h.b.doc.facts[from.facts:] {
		if !moved(&fact.node, lo, hi) {
			fact.node = tape.NO_NODE
		}
	}
	if !moved(&h.b.closed, lo, hi) {
		h.b.closed = tape.NO_NODE
	}
	if !moved(&h.passed, lo, hi) {
		h.passed = tape.NO_NODE
	}
	if !moved(&h.wait_at, lo, hi) {
		h.wait_at = tape.NO_NODE
	}
	for &r in h.ring[f.ring:] {
		if r.node >= u32(hi) {
			r.node -= u32(gone)
			r.kept -= gone_kept
			r.missing -= gone_missing
			r.counts -= gone_counts
		}
	}
	scan_shed(h, int(from.answers))
	return s
}

// Removes the answers taken back from the list from `from` on, so an array whose elements go as its ring passes them
// holds only the answers of the elements its ring keeps. A ring entry or mark past a removed answer stops counting it.
@(private)
scan_shed :: proc "contextless" (h: ^Scanner, from: int) #no_bounds_check {
	answers := h.answers[:]
	dead_before :: proc "contextless" (answers: []Scan_Answer, from, at: int) -> (n: u32) #no_bounds_check {
		for a in answers[from:at] {
			n += u32(a.dead)
		}
		return
	}
	if dead_before(answers, from, len(answers)) == 0 {
		return
	}
	for &r in h.ring {
		if int(r.answers) > from {
			r.answers -= dead_before(answers, from, int(r.answers))
		}
	}
	for &m in h.marks {
		if at := int(u32(m)); at > from {
			m -= u64(dead_before(answers, from, at))
		}
	}
	n := from
	for a in answers[from:] {
		if !a.dead {
			answers[n] = a
			n += 1
		}
	}
	(^runtime.Raw_Dynamic_Array)(&h.answers).len = n
}

// Whether a step from the end of the array `f`, which has `f.count` elements, takes element `e`.
@(private)
scan_ring_takes :: proc "contextless" (h: ^Scanner, f: ^Scan_Frame, e: u64) -> bool #no_bounds_check {
	dm := h.demand
	for n in h.live[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for edge in dm.edges[node.edges:][:node.n_edges] {
			if tape.child_takes(edge.step, e, f.count, false, h.dups) {
				return true
			}
		}
	}
	return false
}

// Takes the demand nodes the `Slice` steps from the end of the array `f` at depth `d` pick for element `index`.
@(private)
scan_slice_picks :: #force_no_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame, index: u64, d: u64) -> bool #no_bounds_check {
	dm := h.demand
	for n in h.live[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for edge in dm.edges[node.edges:][:node.n_edges] {
			if step, ok := edge.step.(tape.Slice); ok && tape.step_reach(step) > 0 && !scan_slice_pick(h, step, index, edge.to, d) {
				return false
			}
		}
	}
	return true
}

// Takes the demand node `to` for element `index` when `step` may take it, before its array's count is known. Past
// the last element it can take, under `settles`, the paths through it that settle there are done. Returns whether the
// walk goes on.
@(private)
scan_slice_pick :: #force_inline proc "contextless" (h: ^Scanner, step: tape.Slice, index: u64, to: u32, d: u64) -> bool {
	if tape.slice_takes(step, index, 0) {
		scan_put(&h.picks, to)
		h.by_place = true
		return true
	}
	return !h.settles || index != tape.slice_cut(step) || scan_cut(h, to, d)
}

// Settles, under `settles`, the paths through demand node `to` that a positional step at depth `d` takes no more
// elements for. Returns whether the scan takes more tokens.
@(private, cold)
scan_cut :: #force_no_inline proc "contextless" (h: ^Scanner, to: u32, d: u64) -> bool {
	if d - 1 <= h.demand.reach {
		scan_settle(h, to, d - 1)
		if h.pending == 0 {
			scan_settled(h)
			return false
		}
	}
	return true
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

@(private)
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

// Makes an answer of `path` at `node`, through demand node `leaf`. `pos` orders the answers: twice a node index, or one
// less for a miss a close found. A refused growth is held in the builder's error, so the result is nil.
@(private)
scan_answer :: #force_inline proc "contextless" (h: ^Scanner, node: tape.Node_Index, path: u32, outcome: tape.Presence, pos: u64, leaf: u32) -> runtime.Allocator_Error {
	if h.made == nil || scan_limit(h, path) {
		scan_push(h, &h.answers, Scan_Answer{node, path, pos, leaf, outcome, false})
	}
	return nil
}

// Whether a limited demand keeps an answer of `path` as it is made. It keeps one past the path's limit only while a
// step may still take back an earlier one. A path whose answers no step takes back is settled at its limit.
@(private, cold)
scan_limit :: #force_no_inline proc "contextless" (h: ^Scanner, path: u32) -> bool #no_bounds_check {
	x := h.demand.paths[path]
	if x.limit == 0 {
		return true
	}
	final := tape.path_final(x, h.dups) >= x.length
	if final && h.made[path] >= x.limit {
		return false
	}
	h.made[path] += 1
	if final && h.made[path] == x.limit && !h.done[path] {
		h.done[path] = true
		h.pending -= 1
	}
	return true
}

// Takes back the answers from `lo` to `hi` that came through demand node `to`.
@(private)
scan_kill :: #force_no_inline proc "contextless" (h: ^Scanner, lo, hi: int, to: u32) #no_bounds_check {
	last := h.demand.nodes[to].last
	for &a in h.answers[lo:hi] {
		if a.leaf >= to && a.leaf <= last && !a.dead {
			a.dead = true
			if h.made != nil {
				h.made[a.path] -= 1
			}
		}
	}
}

// Takes back the answers from `lo` to `hi`, those of element `element` of the array `f`, that came through a step
// from the end that does not take it. `count` is the array's length, 0 while unknown. An element that has passed out of
// every reach from the end (`element` is `max(u64)`) is kept only by a `Slice` that starts from the start.
@(private)
scan_kill_negatives :: proc "contextless" (h: ^Scanner, f: ^Scan_Frame, lo, hi: int, element: u64, count: u64 = 0) #no_bounds_check {
	dm := h.demand
	for n in h.live[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for edge in dm.edges[node.edges:][:node.n_edges] {
			#partial switch step in edge.step {
			case tape.Index:
				if at, in_array := tape.index_in(i64(step), count); step < 0 && (!in_array || element != at) {
					scan_kill(h, lo, hi, edge.to)
				}
			case tape.Slice:
				if count == 0 && step.lo < 0 || count > 0 && !tape.slice_takes(step, element, count) {
					scan_kill(h, lo, hi, edge.to)
				}
			}
		}
	}
}

// Answers the paths whose `Name` or `Index` steps at the closing container `f` at depth `d`, node `open`, met no child,
// and records each missing name once, though several demand nodes may look for it.
@(private, cold)
scan_close_misses :: #force_no_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame, d: u64, open: tape.Node_Index, pos: u64) #no_bounds_check {
	dm := h.demand
	missed := len(h.missing)
	for n in h.live[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for e in node.edges ..< node.edges + node.n_edges {
			edge := dm.edges[e]
			#partial switch step in edge.step {
			case tape.Name:
				if f.object && u32(h.marks[e] >> 32) != f.gen {
					if !scan_missed(h, missed, string(step)) {
						scan_push(h, &h.missing, Scan_Missing{open, string(step)})
					}
					paths_fail(h, dm, edge.to, .Missing, d, open, open, pos, scan_answer)
				}
			case tape.Index:
				if _, in_array := tape.index_in(i64(step), f.count); !f.object && !in_array {
					paths_fail(h, dm, edge.to, .Missing, d, open, open, pos, scan_answer)
				}

			}
		}
	}
}

// Whether the close that records missing names from `from` in `Scanner.missing` has recorded `name`.
@(private)
scan_missed :: proc "contextless" (h: ^Scanner, from: int, name: string) -> bool {
	for m in h.missing[from:] {
		if m.name == name {
			return true
		}
	}
	return false
}

// Opens a frame for the container just stored, its live demand nodes those from `live` in `Scanner.live`.
@(private)
scan_open :: proc "contextless" (h: ^Scanner, t: tape.Token, live: u32, whole: bool) #no_bounds_check {
	dm := h.demand
	h.opens += 1
	f := Scan_Frame{live = live, n_live = u32(len(h.live)) - live, whole = whole, alls = whole, object = t.kind == .Object, ring = u32(len(h.ring)), gen = h.opens}
	f.element, f.takes_to, f.indexed = .End, max(u64), t.kind == .Array && !whole
	k: u64
	others := false
	for n in h.live[live:] {
		node := &dm.nodes[n]
		k = max(k, node.neg)
		f.takes_from = max(f.takes_from, node.takes_from)
		f.takes_to = min(f.takes_to, node.takes_to)
		f.unmet += node.names if f.object else node.indexes
		f.fills = max(f.fills, node.fills)
		f.places |= node.places
		f.indexed &&= !node.sliced
		others ||= node.others
		f.alls ||= node.alls
		f.keys ||= node.keys
		f.slices ||= node.slices
		f.deep ||= node.deep
		f.lengths |= node.lengths
		f.heads |= node.heads
		f.tails |= node.tails
	}
	// An array's count is kept by every frame.
	f.keys &&= !whole && f.object
	f.alls ||= f.keys
	f.passes = f.object && !whole && !f.keys
	if t.kind != .Array {
		k = 0
	}
	k = ring_entries(k, h.b.doc.src, h.rewalk != nil)
	// Only one array is read again at a time, so a replay holds at most one more walk and reads each element once
	// more. A format that cannot walk an element alone keeps every element a step from the end may take, and takes back
	// what the elements it does not take answered.
	f.replays = k > 0 && !others && !whole && !h.replaying && h.rewalks
	f.drops = k > 0 && !others && !whole && !h.rewalks
	f.ring_k = u32(k)
	f.indexed &&= k == 0 && !f.alls
	if f.n_live == 1 && (f.indexed || f.passes) {
		if node := dm.nodes[h.live[live]]; node.n_edges == 1 && !node.deep && (f.indexed || node.names == 1) {
			if f.passes {
				f.named = node.edges + 1
			}
			to := dm.edges[node.edges].to
			if dm.nodes[to].n_edges == 0 && dm.nodes[to].descend == 0 && !h.settles && h.made == nil {
				f.leaf = to
			}
		}
	}
	if f.replays {
		f.ring = u32(len(h.tokens))
	}
	if f.deep {
		scan_save_marks(h, live)
	}
	scan_push(h, &h.frames, f)
}

// Takes demand node `to`, which a `Descend` of a node that took the coming value leads to, unless it took it already.
@(private, cold)
scan_descend :: #force_no_inline proc "contextless" (h: ^Scanner, to: u32) #no_bounds_check {
	for n in h.picks {
		if n == to {
			return
		}
	}
	scan_put(&h.picks, to)
}

// Saves the marks of the `Name` steps of the deep demand nodes from `live` in `Scanner.live`, a frame's, as it opens.
@(private, cold)
scan_save_marks :: #force_no_inline proc "contextless" (h: ^Scanner, live: u32) #no_bounds_check {
	dm := h.demand
	for n in h.live[live:] {
		if node := dm.nodes[n]; node.deep {
			for e in node.edges ..< node.edges + node.n_edges {
				if _, named := dm.edges[e].step.(tape.Name); named {
					scan_push(h, &h.saved, h.marks[e])
				}
			}
		}
	}
}

// Gives back the marks `scan_save_marks` saved for the frame `f` as it closes.
@(private, cold)
scan_restore_marks :: #force_no_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame) #no_bounds_check {
	dm := h.demand
	#reverse for n in h.live[f.live:][:f.n_live] {
		if node := dm.nodes[n]; node.deep {
			#reverse for edge, i in dm.edges[node.edges:][:node.n_edges] {
				if _, named := edge.step.(tape.Name); named && len(h.saved) > 0 {
					h.marks[node.edges + u32(i)] = h.saved[len(h.saved) - 1]
					(^runtime.Raw_Dynamic_Array)(&h.saved).len -= 1
				}
			}
		}
	}
}

@(private)
scanner_close :: proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token, $COLUMNS: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	s := s
	d := s.c
	f := &h.frames[d - 1]
	open := tape.Node_Index(s.b >> 32)
	when COLUMNS {
		f.count += h.dropped
		h.dropped = 0
	}
	if f.ring_k > 0 {
		halted: bool
		if s, halted = scan_close_ring(h, s, d); halted {
			// The array stays open, and the end closes it partial with its full count.
			return s, scan_halt(h, t)
		}
		f = &h.frames[d - 1]
	}
	if f.unmet != 0 && (f.object || f.count < f.fills) {
		scan_close_misses(h, f, d, open, 2 * u64(builder_cursor(&h.b, s)) - 1)
	}
	if u64(u32(s.b)) == f.count {
		s, _ = builder_step(&h.b, s, t, false, true)
		h.b.closed = open
	} else {
		s = scan_close_partial(h, s, f.count)
	}
	learns := COLUMNS && d == 2 && !h.record.tried
	if h.settles && d - 1 <= h.demand.reach || learns {
		scan_closed(h, f, d, open, builder_cursor(&h.b, s), learns)
	}
	if f.deep {
		scan_restore_marks(h, f)
	}
	(^runtime.Raw_Dynamic_Array)(&h.live).len = int(f.live)
	if f.replays {
		(^runtime.Raw_Dynamic_Array)(&h.tokens).len = int(f.ring)
	} else {
		(^runtime.Raw_Dynamic_Array)(&h.ring).len = int(f.ring)
	}
	(^runtime.Raw_Dynamic_Array)(&h.frames).len -= 1
	return scan_left(h, s)
}

// After the close of the container `f` at depth `d`, node `open`, whose nodes end at `end`: settles the paths its
// demand nodes settle there, and learns the first record when `learns`.
@(private, cold)
scan_closed :: #force_no_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame, d: u64, open, end: tape.Node_Index, learns: bool) #no_bounds_check {
	if h.settles && d - 1 <= h.demand.reach {
		for n in h.live[f.live:][:f.n_live] {
			scan_settle(h, n, d - 1)
		}
	}
	if learns {
		scan_learn_record(h, f, open, end)
	}
}

// Settles the elements the ring of the closing array at depth `d` holds, now that its count is known: reads again those
// a negative index of a replaying array takes, and else takes back the answers of those no step from the end takes, and
// drops their nodes when the array `drops`. True when a read again ended the scan's keeping.
@(private, cold)
scan_close_ring :: #force_no_inline proc "contextless" (h: ^Scanner, s: hook.Regs, d: u64) -> (hook.Regs, bool) #no_bounds_check {
	s := s
	f := &h.frames[d - 1]
	k := u64(f.ring_k)
	if f.replays {
		for e in max(f.count, k) - k ..< f.count {
			s = scan_replay(h, s, f, e)
			f = &h.frames[d - 1]
			if h.stopped || h.end_of == .Settled || h.b.err != nil {
				return s, true
			}
		}
		return s, false
	}
	for e in max(f.count, k) - k ..< f.count {
		hi := len(h.answers) if e + 1 == f.count else int(h.ring[f.ring + u32((e + 1) % k)].answers)
		scan_kill_negatives(h, f, int(h.ring[f.ring + u32(e % k)].answers), hi, e, f.count)
	}
	if f.drops {
		// Backwards, so the nodes of an element are where its ring entry says.
		for e := f.count; e > max(f.count, k) - k; {
			e -= 1
			if !scan_ring_takes(h, f, e) {
				hi := builder_cursor(&h.b, s) if e + 1 == f.count else tape.Node_Index(h.ring[f.ring + u32((e + 1) % k)].node)
				s = scan_drop(h, s, f, h.ring[f.ring + u32(e % k)], hi)
			}
		}
	}
	return s, false
}

// Reads element `e` of the replaying array `f` again when a negative index takes it, now that its count is known.
@(private)
scan_replay :: proc "contextless" (h: ^Scanner, s: hook.Regs, f: ^Scan_Frame, e: u64) -> hook.Regs #no_bounds_check {
	s := s
	dm := h.demand
	clear(&h.picks)
	// Its positional steps are all from the end, as it replays.
	for n in h.live[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for edge in dm.edges[node.edges:][:node.n_edges] {
			if tape.child_takes(edge.step, e, f.count, false, h.dups) {
				scan_put(&h.picks, edge.to)
			}
		}
	}
	if len(h.picks) == 0 {
		return s
	}
	h.by_place, h.forced, h.forced_at = true, true, e
	t := h.tokens[f.ring + u32(e % u64(f.ring_k))]
	if t.kind <= .Plain {
		s, _ = scanner_value(h, s, t, true)
		return s
	}
	h.replaying = true
	// The first walk judged the element, so the walk read again fails only for want of memory.
	if r := h.rewalk(h, &s, t.lo); u8(r) == hook.WALK_NO_MEMORY && h.b.err == nil {
		h.b.err = .Out_Of_Memory
	}
	h.replaying, h.forced = false, false
	return s
}

// Closes the open container of `s`, of `count` children, as partial.
@(private)
scan_close_partial :: proc "contextless" (h: ^Scanner, s: hook.Regs, count: u64) -> hook.Regs #no_bounds_check {
	s := s
	open := tape.Node_Index(s.b >> 32)
	node := &h.b.doc.nodes[open]
	node.n = u32(builder_cursor(&h.b, s) - open)
	node.spelling = node.spelling & tape.CONTAINER_STYLE | tape.CONTAINER_PARTIAL | u16(min(count, u64(tape.MAX_CHILDREN)))
	if count >= u64(tape.MAX_CHILDREN) {
		builder_partial_count(&h.b, open, u32(count))
	}
	h.b.closed = open
	s.c -= 1
	s.b = h.b.stack[s.c]
	return s
}

// Goes on past a value the demand nodes `picks` took at depth `d`.
@(private)
scan_past :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, picks: []u32, d: u64) -> (hook.Regs, hook.Action) {
	if h.settles && d <= h.demand.reach {
		scan_settle_picks(h, picks, d)
	}
	return scan_left(h, s)
}

@(private)
scan_settle_picks :: #force_no_inline proc "contextless" (h: ^Scanner, picks: []u32, d: u64) {
	for n in picks {
		scan_settle(h, n, d)
	}
}

@(private)
scan_left :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs) -> (hook.Regs, hook.Action) {
	if h.b.err != nil {
		return s, .Stop
	}
	if h.settles && h.pending == 0 {
		scan_settled(h)
		return s, .Stop if h.stop else .Next
	}
	return s, .Next
}

// Ends the scan's keeping once every path is settled: `stop_early` stops the walk, and otherwise the hook takes no
// more tokens while the walk judges the rest of the text.
@(private, cold)
scan_settled :: #force_no_inline proc "contextless" (h: ^Scanner) {
	if h.stop {
		h.stopped = true
	} else {
		h.end_of = .Settled
	}
}

// The answer to token `t` of a scan that took its last token, by a stop, a refused growth or every path settled.
@(private)
scan_halt :: #force_inline proc "contextless" (h: ^Scanner, t: tape.Token) -> hook.Action {
	if h.end_of != .Settled || h.b.err != nil {
		return .Stop
	}
	return read_rest(t)
}

// Marks done each path under demand node `n` whose answers are all made once the walk is back at depth `d`.
@(private)
scan_settle :: proc "contextless" (h: ^Scanner, n: u32, d: u64) #no_bounds_check {
	dm := h.demand
	for m in n ..= dm.nodes[n].last {
		node := dm.nodes[m]
		for p in dm.ends[node.ends:][:node.n_ends] {
			x := dm.paths[p]
			settled := d <= u64(tape.path_settles(x, h.dups))
			// A path holding its limit of answers is settled once no step can take one back.
			settled ||= x.limit > 0 && h.made[p] >= x.limit && d <= u64(tape.path_final(x, h.dups))
			if !h.done[p] && settled {

				h.done[p] = true
				h.pending -= 1
			}
		}
	}
}

// With `facts`, keeps comment or tag `t` as a fact of a node the scan keeps. A comment or a tag before a token goes to
// the node that token is stored at, an inline comment to the value before it unless the walk passed that value
// unstored, and a foot to the open container. `.Stop` when memory for the facts is refused.
@(private, cold)
scan_fact :: #force_no_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> hook.Action {
	#partial switch tape.fact_kind(t.role) {
	case .Comment_Foot, .Instruction_Foot:
		// A foot after a key is a markup element's with no child element, which marks the value as a comment does. After
		// a key no step took, it waits as a comment does, and it lies inside the value's span, as no container's foot
		// lies inside the value that follows it.
		if !h.has_key {
			at := builder_cursor(&h.b, s)
			if h.wait_at != at {
				h.wait_at, h.wait_from = at, len(h.b.doc.facts)
			}
			break
		}
		fallthrough
	case .Comment, .Tag, .Attribute, .Instruction, .Doctype:
		// After a key, the token is its value, stored past the key's node.
		at := builder_cursor(&h.b, s)
		if h.wait_at != at {
			h.wait_at, h.wait_from = at, len(h.b.doc.facts)
		}
		a := builder_fact(&h.b, s, t)
		if a == .Next {
			h.b.doc.facts[len(h.b.doc.facts) - 1].node = at + tape.Node_Index(h.has_key)
		}
		return a
	case .Comment_Inline:
		if h.passed == builder_cursor(&h.b, s) {
			return .Next
		}
	case .Directive:
	case:
		return .Next
	}
	return builder_fact(&h.b, s, t)
}

// Drops the facts before the token at `lo` the walk passed unstored, and the feet inside its span.
@(private, cold)
scan_unwait :: #force_no_inline proc "contextless" (h: ^Scanner, lo: u64) {
	for &f in h.b.doc.facts[h.wait_from:] {
		#partial switch f.kind {
		case .Comment, .Tag, .Attribute, .Instruction, .Doctype:
			f.node = tape.NO_NODE
		case .Comment_Foot, .Instruction_Foot:
			if f.lo >= lo {
				f.node = tape.NO_NODE
			}
		}
	}
	h.wait_at = tape.NO_NODE
}

// Drops the comments whose node the scan did not keep, such as one before a token never read or a foot of a root not
// kept.
@(private, cold)
scan_check_facts :: proc "contextless" (h: ^Scanner, regs: hook.Regs) #no_bounds_check {
	nodes := h.b.doc.nodes[:builder_cursor(&h.b, regs)]
	facts := h.b.doc.facts
	kept := 0
	h.b.doc.present = {}
	// A fact past every node of a scan that read the whole text lies past the root, which the build gives the root.
	past := len(nodes) + 1 if !h.stopped && h.end_of != .Settled else len(nodes)
	for f in facts {
		if int(f.node) < past {
			facts[kept] = f
			kept += 1
			if f.kind != .Comment {
				h.b.doc.present += {f.kind}
			}
		}
	}
	h.b.doc.facts = facts[:kept]
}

// Makes room in `list` for `n` more entries. False once a growth is refused, which sets the builder's error.
@(private)
scan_reserve :: #force_inline proc "contextless" (h: ^Scanner, list: ^[dynamic]$T, n: int) -> bool {
	raw := (^runtime.Raw_Dynamic_Array)(list)
	if raw.cap - raw.len >= n {
		return true
	}
	return scan_grow_to(h, raw, size_of(T), align_of(T), raw.len + n)
}

// Appends `v` to a list `scan_reserve` made room in.
@(private)
scan_put :: #force_inline proc "contextless" (list: ^[dynamic]$T, v: T) #no_bounds_check {
	raw := (^runtime.Raw_Dynamic_Array)(list)
	([^]T)(raw.data)[raw.len] = v
	raw.len += 1
}

// Appends `v` to a list of the scan. A refused growth is held in the builder's error, which ends the walk.
@(private)
scan_push :: #force_inline proc "contextless" (h: ^Scanner, list: ^[dynamic]$T, v: T) #no_bounds_check {
	raw := (^runtime.Raw_Dynamic_Array)(list)
	if raw.len == raw.cap && !scan_grow_to(h, raw, size_of(T), align_of(T), raw.len + 1) {
		return
	}
	([^]T)(raw.data)[raw.len] = v
	raw.len += 1
}

@(private, cold)
scan_grow_to :: #force_no_inline proc "contextless" (h: ^Scanner, list: ^runtime.Raw_Dynamic_Array, size, align, least: int) -> bool {
	if err := list_grow(&h.b.ctx, list, size, align, least, scan_in_room(h, list.data)); err != nil {
		if h.b.err == nil {
			h.b.err = err
		}
		return false
	}
	return true
}

// Grows a list of entries of `size` bytes to twice its capacity, at least 8 entries and at least `least`, under `ctx`. A
// list `in_room` moves out of the room it started in.
@(private)
list_grow :: #force_inline proc "contextless" (ctx: ^runtime.Context, list: ^runtime.Raw_Dynamic_Array, size, align, least: int, in_room: bool) -> runtime.Allocator_Error {
	context = ctx^
	want := max(2 * list.cap, 8, least)
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

// Gives `doc` its answers by path, kept children, missing names and held spans in one block, from `answers` and
// `missing`, which it sorts, and `made`, which it overwrites. With records that replay the first record of a `fixed`
// walk, the first of `answers` and `missing` are the first record's, which each replayed record makes again `size`
// nodes after the record before, ahead of the rest.
@(private)
scan_lists :: proc(h: ^Scanner, doc: ^tape.Document, answers: []Scan_Answer, missing: []Scan_Missing, made: []u32) -> runtime.Allocator_Error {
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
	x := tape.partial_block(paths, live, len(h.kept), n_missing, names, h.dups, allocator) or_return
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
	runtime.mem_copy_non_overlapping(raw_data(x.kept), raw_data(h.kept), len(h.kept) * size_of(Scan_Kept))
	slice.stable_sort_by(rest_missing, proc(a, b: Scan_Missing) -> bool { return a.node < b.node })
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

@(private)
scan_answer_before :: #force_inline proc(a, b: Scan_Answer) -> bool {
	return a.pos < b.pos || a.pos == b.pos && a.path < b.path
}

@(private)
scanner_free :: proc(h: ^Scanner, allocator: runtime.Allocator) {
	free_list :: #force_inline proc(h: ^Scanner, list: ^[dynamic]$T) {
		if p := raw_data(list^); p != nil && !scan_in_room(h, p) {
			delete(list^)
		}
	}
	free_list(h, &h.frames)
	free_list(h, &h.elements)
	free_list(h, &h.live)
	free_list(h, &h.picks)
	free_list(h, &h.answers)
	free_list(h, &h.kept)
	free_list(h, &h.missing)
	free_list(h, &h.ring)
	free_list(h, &h.tokens)
	free_list(h, &h.saved)
	if h.held != nil {
		delete(h.held)
	}
	if h.bytes != nil {
		delete(h.bytes)
	}
	h.held, h.bytes = nil, nil

	if !scan_in_room(h, raw_data(h.marks)) {
		runtime.mem_free_with_size(raw_data(h.marks), len(h.marks) * size_of(u64) + len(h.made) * size_of(u32) + len(h.done), allocator)
	}
}
