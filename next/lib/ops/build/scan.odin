package build

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// Compact typed dynamic list for `Scanner`'s internal scratch buffers, sharing `Scanner.scratch` as its allocator.
@(private)
Scan_List :: struct($T: typeid) {
	data: [^]T,
	len:  u32,
	cap:  u32,
}

@(private)
Scan_Raw_List :: struct {
	data: rawptr,
	len:  u32,
	cap:  u32,
}

#assert(size_of(Scan_List(u32)) == size_of(Scan_Raw_List))
#assert(offset_of(Scan_List(u32), data) == offset_of(Scan_Raw_List, data))
#assert(offset_of(Scan_List(u32), len) == offset_of(Scan_Raw_List, len))
#assert(offset_of(Scan_List(u32), cap) == offset_of(Scan_Raw_List, cap))

@(private)
Scan_Flag :: enum u8 {
	By_Place,  // an `Index`, `Slice`, or limited `All` picked the coming value, so it keeps a `Scan_Kept`
	Forced,    // the coming value is element `forced_at` of its array, read again with its picks made
	Replaying, // inside a `rewalk`, where every array keeps the elements its negative indexes may take
	Rewalks,   // the format has `.Rewalk`, so an array whose elements only steps from the end take replays
	Stop,      // `stop_early`
	Stopped,   // stopped early once every path settled
	// Under `stop_early`, or a limit on a path or a step, the scan tracks its settled paths. Once all are, `stop_early`
	// ends the walk, and otherwise the scan keeps nothing more while the walk judges the rest of the text. A scan of
	// facts takes every token, as the comments past the last settled value may be a kept node's.
	Settles,
	// Set for a scan of a text in pieces, which copies the bytes it keeps out of each window into `held`/`bytes`.
	Holds,
}

@(private)
Scan_Flags :: bit_set[Scan_Flag; u8]

// The hook of a scan: a `Builder` that keeps only what the paths of a demand reach. Its registers are the builder's.
// A container on the paths has a frame, which holds the demand nodes live in it. A value a path ends at is kept as its
// grain says (whole, as its keys and count, or as its node), and its steps are still followed when longer paths go on
// inside it.
//
// Hot per-token fields (`frames`, `picks`, `key_text`, `demand`, `has_key`, `flags`, `end_of`, `facts`, `key_skips`,
// `dups`, `alike`, `scattered`) sit in Cache Line 0 (`0..63` on 64-bit), followed by match/leaf/reopen/record fields in
// Cache Lines 1–2 (`64..191`), with `b: Builder` 64-byte aligned at offset `192`.
Scanner :: struct {
	// Cache Line 0 (0..63 on 64-bit)
	frames:    Scan_List(Scan_Frame), // the containers on the paths, the root's first, one per builder level
	picks:     Scan_List(u32), // the demand nodes that took the coming value
	// What a key token's offsets index: the document's `src`, or the bytes a read of a text in pieces holds the keys in
	// once they lie before its window, as a delimited text's header does.
	key_text:  []u8,
	demand:    ^tape.Demand,
	has_key:   bool, // `key` holds the key of the coming value (separate byte to avoid RMW hazard with `flags`)
	flags:     Scan_Flags,
	end_of:    Scan_End, // what the next token is, when it is the `End` of a container
	facts:     bool, // `Demand.facts`
	// Whether `scanner_key_skip_hook` skips a member no step takes at its key. A scan that keeps facts, which
	// `scan_pass` places, does not, nor does a read in pieces of a format whose window may end between a key and its
	// value. A delimited window never does, so its scan sets it when it keeps no facts.
	key_skips: bool,
	dups:      tape.Duplicates, // the read's policy, resolved
	// Every step from the root is an `All` with no limit, so the members a step takes are the same in every child of
	// the root, as a walk of `.Columns` needs to pass the columns it learnt from one record in the rest.
	alike:     bool,
	// The walk gives its tokens out of text order, as a table of a TOML text that later statements add to does, so the
	// scan holds the text itself, once, one span from its first byte, and not the bytes of each token.
	scattered: bool,

	// Cache Line 1 (64..127 on 64-bit)
	key:       tape.Token, // with `has_key`, the key of the coming value
	// For each demand edge whose key met a member of an object: in the high 32 bits the generation of the object's
	// frame, in the low 32 bits the number of answers made before it. A mark is valid only for the frame of its
	// generation.
	marks:     []u64,
	answers:   Scan_List(Scan_Answer),
	// By level, the frame an element of the array at the level above opened with. The array's later elements of its
	// kind reopen with it. Valid while the array's `element` is not `End`.
	elements:  Scan_List(Scan_Frame),

	// Cache Line 2 (128..191 on 64-bit)
	live:      Scan_List(u32), // the demand nodes live in the frames, each frame's from its `live`
	record:    Scan_Record, // the first record, which a `fixed` walk's later records are made again from
	// The frames opened, so the last one's generation. Under `f.drops` `scan_drop` reuses node slots, so `scan_open`
	// and `scan_reopen_grow` call `scan_wrap_opens` if this wraps around to 0 after 2^32 frames.
	opens:     u32,
	wait_at:   tape.Node_Index, // with `facts`, the node index waiting comments mark
	pending:   int, // the paths not done

	// Cache Lines 3..8 (192..575 on 64-bit): 64-byte aligned `Builder`
	b:         Builder,

	// Warm / cold fields (576+ on 64-bit)
	kept:      Scan_List(Scan_Kept),
	missing:   Scan_List(Scan_Missing),
	ring:      Scan_List(Scan_Ring), // what the scan held before each element a step from the end can still take
	tokens:    Scan_List(tape.Token), // the token of each element a replaying array's negative `Index` can still take
	// The marks of the `Name` steps of the deep demand nodes of each open frame that has them, as they were before it
	// opened, since such a step is live in the frames inside it too.
	saved:     Scan_List(u64),
	made:      []u32, // with a limited demand, the answers each path holds that no step took back
	done:      []bool, // the paths settled, a bool per path, kept while `.Settles`
	rewalk:    Rewalk, // the proc that gives this hook the value at `lo` again
	walk:      rawptr, // the walk giving this hook its tokens, which `rewalk` reads in
	replay:    hook.Replay,
	dropped:   u64, // the members the walk passed with no token since the last `End`, which the open object counts
	forced_at: u64,
	// With `facts`, the comments before the next token start at `wait_from` in the builder's facts. They mark the node
	// `wait_at` that the token is stored at, unless the walk passes the token while that node is still the next one
	// written.
	wait_from: int,
	passed:    tape.Node_Index, // with `facts`, the node written next when the walk last passed a value
	_pad0:     u32,
	held:      [dynamic]tape.Held_Span,
	bytes:     [dynamic]u8,
	hold_from: u64,
	held_live: int, // the bytes held once the last `hold_drop` ran
	// The span of the text whose bytes the keys of later nodes name, as a delimited text's header names each row's
	// cells, which a scan in pieces holds whole, once, and not per key. Empty for a text whose keys lie before their
	// values.
	head:      [2]u64,
	room:      ^Scan_Room,
	scratch:   runtime.Allocator, // allocator for transient scan lists and marks/made/done, freed in `scanner_free`
	protocol:  hook.Protocol(SCANNER_CAPS, hook.Levels(scanner_levels_held, scanner_levels_grow), hook.Unused, hook.Keeps(Builder, scanner_builder, builder_keep_whole, builder_keep_stubs)),
}

#assert(size_of(Scanner) % size_of(u64) == 0)

when size_of(rawptr) == 8 {
	#assert(offset_of(Scanner, frames) == 0)
	#assert(offset_of(Scanner, picks) == 16)
	#assert(offset_of(Scanner, key_text) == 32)
	#assert(offset_of(Scanner, demand) == 48)
	#assert(offset_of(Scanner, scattered) == 63)
	#assert(offset_of(Scanner, key) == 64)
	#assert(offset_of(Scanner, live) == 128)
	#assert(offset_of(Scanner, b) == 192)
}

SCANNER_CAPS :: hook.Capabilities{.Skips, .Levels, .Keeps, .Walk, .Credits, .Columns}

// Which container's `End` is the next token, when this hook skipped it or kept it as a whole.
@(private)
Scan_End :: enum u8 {
	None,
	Skipped, // a container this hook skipped
	Picked,  // a container picks took, kept whole or stored as one node, its picks still in `picks`
	Settled, // every path is settled without `stop_early`, so no token is taken from here on
}

// The open stack of a scanner, which is its builder's, as `hook.Levels` reads it.
@(private = "file")
scanner_levels_held :: #force_inline proc "contextless" (h: rawptr) -> int {
	return len((^Scanner)(h).b.stack)
}

@(private = "file")
scanner_levels_grow :: #force_inline proc "contextless" (h: rawptr, want: int, _: ^hook.Regs, _: u64) -> bool {
	return builder_deepen(&(^Scanner)(h).b, want, nil, 0)
}

// The builder a scanner keeps containers with, as `hook.Keeps` reads it.
@(private = "file")
scanner_builder :: #force_inline proc "contextless" (h: rawptr) -> rawptr {
	return &(^Scanner)(h).b
}

@(private = "file")
builder_keep_whole :: #force_inline proc "contextless" (h: rawptr, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	return builder_hook_kept((^Builder)(h), s, t)
}

@(private = "file")
builder_keep_stubs :: #force_inline proc "contextless" (h: rawptr, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	return builder_hook_stubs((^Builder)(h), s, t)
}

// Gives hook `h` the value at `lo` again from registers `s`. Returns the walk's result.
Rewalk :: #type proc "contextless" (h: ^Scanner, s: ^hook.Regs, lo: u64) -> hook.Walk_Result

@(private)
Scan_Frame_Flag :: enum u8 {
	Whole,   // every child is kept, a path ending at the container or at one holding it
	Object,  // true for an object (`obj` arm of `u` live), false for an array (`arr` arm live)
	Passes,  // an object whose members no step takes are passed
	Alls,    // an `All` takes any member, every child is kept, or every key is
	// An array not kept whole whose positional steps are all non-negative indexes, so an element no `Index` takes is
	// passed with no picks.
	Indexed,
	// Its positional steps are all negative indexes, so each element is passed and the ones they take are read again at
	// its close.
	Replays,
	// Its positional steps are all from the end and the format cannot walk an element again, so each element they may
	// take is kept, and its nodes go once no step can take it.
	Drops,
	// An object a path ends at with grain `.Keys`, so each member no step takes is kept with its value, a container
	// value as one unread node.
	Keys,
	Slices,  // it has `Slice` steps, which pick past the ring's check in `scan_element`, so it has a ring
	Deep,    // a demand node live in it is deep, so the marks of its `Name` steps are saved while it is open
	Uniform, // `takes_from == 0 && takes_to == max(u64)`: every element picks the same positional demand nodes
}

@(private)
Scan_Frame_Flags :: bit_set[Scan_Frame_Flag; u16]

// A container on the paths, packed into one 64-byte cache line. `.Object in flags` selects `u.obj` vs `u.arr`.
@(private)
Scan_Frame :: struct {
	count:   u64, // the children passed
	live:    u32, // its demand nodes in `Scanner.live`
	n_live:  u32,
	gen:     u32, // its generation, which the marks of its members carry
	// The number of steps its close still has to check because no child has met them: the `Name` steps of an object
	// that no member has met yet, or the `Index` steps of an array.
	unmet:   u32,
	// With `.Indexed`, or in an object that `.Passes`, the demand node of its one `Index` or `Name` step when that node
	// has no step past it, so a scalar child the step takes is kept with no picks. 0 for none.
	leaf:    u32,
	flags:   Scan_Frame_Flags,
	// For an array with no positional steps, where each element picks the same demand nodes: the kind of the element
	// whose frame `Scanner.elements` holds at the level below, else `End`. An element of that kind reopens it.
	element: tape.Kind,
	_pad:    u8,
	u:       struct #raw_union {
		obj: struct {
			lengths: u64, // a bit per length its `Name` steps have, past 63 counted from 0
			heads:   u64, // a bit per first byte its `Name` steps have, by the byte's low six bits
			tails:   u64, // a bit per last byte its `Name` steps have, by the byte's low six bits
			// In an object that `.Passes`, one more than the edge of its one live demand node's one step when that step
			// is a `Name` and the node is not deep, so a key is judged with no look at the demand node. 0 for none.
			named:   u32,
			_pad:    u32,
		},
		arr: struct {
			fills:  u64, // the fewest elements an array has for each of its `Index` steps to take one
			places: u64, // a bit per element below 64 an `Index` step takes
			ring:   u32, // its entries in `Scanner.ring`, or in `Scanner.tokens` when it `.Replays`, `ring_k` of them
			ring_k: u32,
			_pad:   u64,
		},
	},
}

#assert(size_of(Scan_Frame) == 64)

// An answer as the walk made it, its node as `tape.answer` gives it.
@(private)
Scan_Answer :: struct {
	node:    tape.Node_Index,
	path:    u32,
	pos:     u64, // twice the value's node index, or twice the close's less one for a miss the close found
	leaf:    u32, // the demand node the answer came from
	outcome: tape.Presence,
	dead:    bool, // a repeated key or a negative index took it back
	_pad:    [2]u8,
}

#assert(size_of(Scan_Answer) == 24)

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
// A list that outgrows its part moves to the scratch allocator, and a demand with more edges than `marks` holds, or
// more paths than `done` holds, allocates those too.
Scan_Room :: struct {
	frames:   [8]Scan_Frame,
	elements: [8]Scan_Frame,
	live:     [16]u32,
	picks:    [16]u32,
	answers:  [16]Scan_Answer,
	kept:     [16]Scan_Kept,
	marks:    [32]u64,
	made:     [32]u32,
	done:     [32]bool,
}

// Sets up `h` as a scanner of `demand` over `src`, with `nodes`, `most` and `frames` as `builder_start` takes them.
// The node room grows as it fills. With no `rewalk` it reads each value once, keeping nodes where a replay would read a
// value again. `scratch`, when set, backs transient lists and `marks`/`made`/`done` freed in `scanner_end`.
@(require_results)
scanner_start :: proc(h: ^Scanner, src: []u8, format: ^tape.Format, demand: ^tape.Demand, dups: tape.Duplicates, read: tape.Read_Options, rewalk: Rewalk, nodes, most: int, frames: []u64, room: ^Scan_Room, allocator: runtime.Allocator, lent: []tape.Node = nil, budget: ^hook.Memory_Budget = nil, scratch: runtime.Allocator = {}) -> (err: runtime.Allocator_Error) {
	scratch_alloc := scratch if scratch.procedure != nil else allocator
	builder_start(&h.b, src, format, nodes, most, frames, allocator, budget, lent, scratch = scratch_alloc)
	if h.b.err != nil {
		h.demand = nil
		return h.b.err
	}
	h.key_text = src
	h.demand = demand
	h.rewalk, h.walk = rewalk, nil
	h.dups = tape.read_dups(format, dups)
	h.facts = demand.facts
	h.key_skips = !demand.facts
	h.alike = tape.demand_children_alike(demand)
	h.scattered = false
	h.end_of = .None
	flags: Scan_Flags
	if .Rewalk in format.caps && rewalk != nil {
		flags += {.Rewalks}
	}
	if read.stop_early {
		flags += {.Stop}
	}
	if read.stop_early || !demand.facts && (demand.limited || scan_cuts(demand)) {
		flags += {.Settles}
	}
	h.flags = flags
	h.has_key = false
	if demand.facts {
		h.b.flags += {.Keep_Facts}
	}
	h.key = {}
	h.opens = 0
	h.pending = len(demand.paths)
	h.passed, h.wait_at = tape.NO_NODE, tape.NO_NODE
	h.wait_from, h.forced_at, h.dropped = 0, 0, 0
	h.replay, h.record = {}, {}
	h.held, h.bytes = nil, nil
	h.held.allocator, h.bytes.allocator = allocator, allocator
	h.hold_from, h.held_live, h.head = 0, 0, {}
	h.room = room
	h.scratch = scratch_alloc
	h.marks, h.made, h.done = nil, nil, nil
	h.frames, h.elements, h.live, h.picks, h.answers, h.kept, h.missing, h.ring, h.tokens, h.saved = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
	defer if err != nil {
		scanner_free(h)
		if .Counts_Borrowed not_in h.b.flags && cap(h.b.counts) > 0 {
			delete(h.b.counts)
		}
		tape.destroy(&h.b.doc)
		h.demand = nil
	}
	made := len(demand.paths) if demand.limited else 0
	if len(demand.edges) <= len(room.marks) && len(demand.paths) <= len(room.done) {
		h.marks, h.done = room.marks[:len(demand.edges)], room.done[:len(demand.paths)]
		if made > 0 {
			h.made = room.made[:made]
		}
	} else {
		// The marks, the answers made and the settled paths share one block from `h.scratch`.
		marks, counts := len(demand.edges) * size_of(u64), made * size_of(u32)
		total := marks + counts + len(demand.paths)
		if total > 0 && h.scratch.procedure == nil {
			return .Out_Of_Memory
		}
		block, merr := runtime.mem_alloc_non_zeroed(total, align_of(u64), h.scratch)
		if e := took(merr, raw_data(block), total); e != nil {
			return e
		}
		h.marks = ([^]u64)(raw_data(block))[:len(demand.edges)]
		if made > 0 {
			h.made = ([^]u32)(raw_data(block[marks:]))[:made]
		}
		h.done = ([^]bool)(raw_data(block[marks + counts:]))[:len(demand.paths)]
	}
	scan_lists_reset(h, room)
	// Every pick of a value or key is of a distinct edge, or the root, so `picks` never grows past this.
	if !scan_reserve(h, &h.picks, len(demand.edges) + 1) {
		err = h.b.err
	}
	return
}

// Starts `h` for another value of the read it was started for by `scanner_start` and ended by `scanner_end`, with the
// same arguments. What the demand and the read fix is kept, all per-record state is reset, and the lists go back to
// `room`. A scanner never started, with a different demand/room/scratch, or whose marks or picks outgrow the room, is
// started as `scanner_start` does.
@(private, require_results)
scanner_restart :: proc(h: ^Scanner, src: []u8, format: ^tape.Format, demand: ^tape.Demand, dups: tape.Duplicates, read: tape.Read_Options, rewalk: Rewalk, nodes, most: int, frames: []u64, room: ^Scan_Room, allocator: runtime.Allocator, lent: []tape.Node = nil, budget: ^hook.Memory_Budget = nil, scratch: runtime.Allocator = {}) -> runtime.Allocator_Error {
	scratch_alloc := scratch if scratch.procedure != nil else allocator
	if h.demand != demand || h.room != room || h.scratch != scratch_alloc || !scan_in_room(h, raw_data(h.marks)) || len(demand.edges) >= len(room.picks) {
		return scanner_start(h, src, format, demand, dups, read, rewalk, nodes, most, frames, room, allocator, lent, budget, scratch)
	}
	if h.b.doc.allocator == allocator {
		builder_again(&h.b, src, format, nodes, most, frames, budget, lent)
	} else {
		builder_start(&h.b, src, format, nodes, most, frames, allocator, budget, lent, scratch = scratch_alloc)
	}
	if h.b.err != nil {
		return h.b.err
	}
	if h.facts {
		h.b.flags += {.Keep_Facts}
	}
	h.key_text = src
	h.scattered = false
	h.has_key = false
	h.flags &= {.Rewalks, .Stop, .Settles}
	h.walk, h.dropped = nil, 0
	h.end_of, h.opens, h.pending, h.passed, h.wait_at = .None, 0, len(demand.paths), tape.NO_NODE, tape.NO_NODE
	h.wait_from, h.hold_from, h.held_live, h.head = 0, 0, 0, {}
	h.held.allocator, h.bytes.allocator = allocator, allocator
	h.replay, h.record = {}, {}
	scan_lists_reset(h, room)
	return nil
}

// Points the scan's lists at `room`, empty, and clears its marks, answers made and settled paths. No frame has
// generation 0, so a zero mark is valid for none.
@(private = "file")
scan_lists_reset :: proc "contextless" (h: ^Scanner, room: ^Scan_Room) {
	scan_list_room(&h.frames, room.frames[:])
	scan_list_room(&h.elements, room.elements[:])
	scan_list_room(&h.live, room.live[:])
	scan_list_room(&h.picks, room.picks[:])
	scan_list_room(&h.answers, room.answers[:])
	scan_list_room(&h.kept, room.kept[:])
	h.missing, h.ring, h.tokens, h.saved = {}, {}, {}, {}
	runtime.mem_zero(raw_data(h.marks), len(h.marks) * size_of(u64))
	runtime.mem_zero(raw_data(h.made), len(h.made) * size_of(u32))
	runtime.mem_zero(raw_data(h.done), len(h.done))
}

@(private)
scan_list_room :: #force_inline proc "contextless" (list: ^Scan_List($T), room: []T) {
	list^ = {data = raw_data(room), len = 0, cap = u32(len(room))}
}

@(private)
list_slice :: #force_inline proc "contextless" (list: Scan_List($T)) -> []T {
	return list.data[:list.len]
}

// Whether `p` is in the room the scan's lists start in. Unsigned subtraction wraps safely because `Scan_Room` is a
// single contiguous object that cannot straddle address 0.
@(private, require_results)
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

// `#no_bounds_check` invariants guaranteed by the walk protocol and `scanner_start`:
// - On `.Key`, `h.frames.len >= 1` (keys only arrive inside an open object frame);
// - On values with `s.c > 0 && !(.Forced in h.flags)`, `s.c <= u64(h.frames.len)`;
// - `h.picks.cap >= len(h.demand.edges) + 1`, so `h.picks.len < h.picks.cap` on every distinct-edge pick;
// - `t.lo + u64(t.n) <= u64(len(h.key_text))` for every undecoded key token.
@(private = "file")
scanner_take :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token, $COLUMNS: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	when COLUMNS {
		// Every record of the root array after the first replays it, which reopens its frame.
		if .Ready in h.record.flags && t.kind == .Object && s.c == 1 {
			return scan_record_open(h, s, t)
		}
	}
	if t.role > .Key {
		if h.facts {
			return s, scan_fact(h, s, t)
		}
		return s, .Next
	}
	if intrinsics.expect(h.end_of == .Settled, false) {
		return s, read_rest(t)
	}
	// A key that no `Name` of the open object can match is passed without further work. So is a member no step took.
	// With `COLUMNS` and `key_skips`, in an object whose members no step takes, a member no step took is counted and
	// its value skipped at the key. Whether a step takes a member depends on its key and its place only, as `.Columns`
	// needs.
	when COLUMNS {
		if .On in h.record.flags && t.kind != .End {
			return scan_record_token(h, s, t)
		}
	}
	if t.role == .Key {
		f := &h.frames.data[h.frames.len - 1]
		h.picks.len = 0
		if .Alls not_in f.flags && scan_key_unmatched(h, f, t) {
			when COLUMNS {
				if .Passes in f.flags && h.key_skips {
					f.count += 1
					return s, .Skip
				}
			}
			return s, .Next
		}
		h.key = t
		h.key.spelling = tape.without_credit(h.key.spelling)
		h.has_key = true
		// Fast path for a single non-deep `Name` edge with an undecoded scalar key of <= 16 bytes (zero calls).
		// Longer/decoded keys, duplicate keys, and multi-step frames route to `scan_key_slow`.
		if f.u.obj.named != 0 && t.kind <= .Plain && !tape.text_decodes(t) && t.n <= 16 {
			e := f.u.obj.named - 1
			edge := &h.demand.edges[e]
			if name, ok := edge.step.(tape.Name); ok && scan_key_short_eq(h.key_text, t, string(name)) {
				if u32(h.marks[e] >> 32) != f.gen {
					f.unmet -= 1
					h.marks[e] = u64(f.gen) << 32 | u64(h.answers.len)
					h.picks.data[0] = edge.to
					h.picks.len = 1
				} else {
					scan_key_slow(h, t)
				}
			}
		} else {
			scan_key_slow(h, t)
		}
		when COLUMNS {
			if .Passes in f.flags && h.key_skips && h.picks.len == 0 {
				h.has_key = false
				f.count += 1
				return s, .Skip
			}
		}
		return s, .Next
	}
	if t.kind == .End {
		if h.end_of != .None {
			end := h.end_of
			h.end_of = .None
			if end == .Picked {
				return scan_past(h, s, list_slice(h.picks), s.c)
			}
			return s, .Next
		}
		when COLUMNS {
			if .On in h.record.flags {
				return scan_record_close(h, s)
			}
		}
		return scanner_close(h, s, t, COLUMNS)
	}
	if s.c > 0 && .Forced not_in h.flags {
		f := &h.frames.data[s.c - 1]
		if f.flags & {.Passes, .Indexed} != {} {
			if .Passes in f.flags && h.picks.len == 0 || .Indexed in f.flags && !scan_index_takes(f) {
				f.count += 1
				return scan_pass(h, s, t)
			}
			if f.leaf != 0 && t.kind <= .Plain {
				return scan_leaf(h, s, t, f)
			}
		}
		if t.kind > .Plain && t.kind == f.element {
			return scan_reopen(h, s, t, f)
		}
	}
	if t.kind <= .Plain {
		return scanner_value(h, s, t, true)
	}
	return scanner_value(h, s, t, false)
}

// Inline equality check for an undecoded key token `t` of at most 16 bytes against `name`, with zero calls.
// Caller guarantees `!tape.text_decodes(t) && t.n <= 16 && t.lo + u64(t.n) <= u64(len(src))`.
@(private = "file", require_results)
scan_key_short_eq :: #force_inline proc "contextless" (src: []u8, t: tape.Token, name: string) -> bool #no_bounds_check {
	n := len(name)
	if int(t.n) != n {
		return false
	}
	a, b := raw_data(src)[t.lo:], raw_data(name)
	switch {
	case n >= 8:
		head := intrinsics.unaligned_load((^u64)(a)) == intrinsics.unaligned_load((^u64)(b))
		return head && intrinsics.unaligned_load((^u64)(a[n - 8:])) == intrinsics.unaligned_load((^u64)(b[n - 8:]))
	case n >= 4:
		head := intrinsics.unaligned_load((^u32)(a)) == intrinsics.unaligned_load((^u32)(b))
		return head && intrinsics.unaligned_load((^u32)(a[n - 4:])) == intrinsics.unaligned_load((^u32)(b[n - 4:]))
	case n >= 2:
		return intrinsics.unaligned_load((^u16)(a)) == intrinsics.unaligned_load((^u16)(b)) && a[n - 1] == b[n - 1]
	}
	return n == 0 || a[0] == b[0]
}

// Out-of-line key matching for multi-step frames, decoded or >16-byte keys, non-scalar keys, and duplicate keys.
@(private = "file")
scan_key_slow :: #force_no_inline proc "contextless" (h: ^Scanner, t: tape.Token) #no_bounds_check {
	f := &h.frames.data[h.frames.len - 1]
	if f.u.obj.named != 0 {
		e := f.u.obj.named - 1
		edge := &h.demand.edges[e]
		if name, ok := edge.step.(tape.Name); ok && t.kind <= .Plain && tape.key_names(h.b.doc.format, h.key_text, t, string(name)) {
			scan_name_meets(h, f, e, edge.to, false)
		}
		return
	}
	if t.kind <= .Plain {
		scanner_key(h, f, t, true)
	} else {
		scanner_key(h, f, t, false)
	}
}

// Whether an `Index` step of the array `f` takes its next element. Caller guarantees `.Object not_in f.flags`.
@(private = "file", require_results)
scan_index_takes :: #force_inline proc "contextless" (f: ^Scan_Frame) -> bool {
	return f.count < f.u.arr.fills && (f.count >= 64 || f.u.arr.places & (1 << f.count) != 0)
}

// Whether no `Name` of the object `f` can match key `t`, because none has its length, its first byte or its last. A key
// that needs decoding is judged by its decoded length when its spelling holds an exact credit, otherwise never.
// `#no_bounds_check` invariant: `.Object in f.flags` and `t.lo + u64(t.n) <= u64(len(h.key_text))` when undecoded.
@(private = "file", require_results)
scan_key_unmatched :: #force_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame, t: tape.Token) -> bool #no_bounds_check {
	if tape.text_decodes(t) {
		if t.kind == .Number || t.spelling & tape.SPELLING_CREDIT_EXACT == 0 {
			return false
		}
		d := u64(t.n) - u64(tape.spelling_credit(t.spelling))
		return f.u.obj.lengths & (1 << (d & 63)) == 0
	}
	return f.u.obj.lengths & (1 << (t.n & 63)) == 0 || t.n > 0 && (f.u.obj.heads & (1 << (h.key_text[t.lo] & 63)) == 0 || f.u.obj.tails & (1 << (h.key_text[t.lo + u64(t.n) - 1] & 63)) == 0)
}

// Returns the partial document the walk built, or the error that ended it with everything freed. `regs` are the hook's
// registers at the walk's end and `root_close` is the end of the root value.
@(require_results)
scanner_end :: proc(h: ^Scanner, regs: hook.Regs, root_close: u64, err: tape.Error) -> (doc: tape.Document, e: tape.Error) {
	defer scanner_free(h)
	regs := regs
	e = err
	if e == nil {
		e = builder_error(&h.b)
	}
	if e == nil && (.Stopped in h.flags || h.end_of == .Settled) {
		// The containers the stop left open are on the paths, their counts not known, as their ends were not read. A
		// replaying array stops only in its replay, with every element passed, so its count is known.
		for regs.c > 0 {
			f := h.frames.data[regs.c - 1]
			open := tape.Node_Index(regs.b >> 32)
			if .Replays not_in f.flags {
				f.count = 0
			}
			regs = scan_close_partial(h, regs, f.count)
			if .Replays not_in f.flags {
				h.b.doc.nodes[open].spelling |= tape.MAX_CHILDREN
			}
		}
	}
	if e == nil && len(h.b.doc.facts) > 0 {
		scan_check_facts(h, regs)
	}
	stopped := .Stopped in h.flags
	doc, e = builder_end(&h.b, regs, 0 if stopped else root_close, e)
	if e != nil {
		return
	}
	if stopped {
		doc.flags += {.Stopped}
	}
	if refused := scan_lists(h, &doc, list_slice(h.answers), list_slice(h.missing), h.made); refused != nil {
		tape.destroy(&doc)
		return {}, refused
	}
	if .Holds in h.flags {
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

@(private = "file")
scanner_key :: #force_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame, t: tape.Token, $NAMED: bool) #no_bounds_check {
	dm := h.demand
	for n in h.live.data[f.live:][:f.n_live] {
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
@(private = "file")
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
			scan_kill(h, int(u32(mark)), int(h.answers.len), to)
		}
	}
	h.marks[e] = u64(f.gen) << 32 | u64(h.answers.len)
	scan_put(&h.picks, to)
}

@(private)
scanner_value :: proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token, $scalar: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	s := s
	d := s.c
	index: u64
	whole := false
	if .Forced in h.flags {
		h.flags -= {.Forced}
		index = h.forced_at
	} else if d == 0 {
		h.picks.len = 0
		h.flags -= {.By_Place}
		if len(h.demand.paths) > 0 {
			scan_put(&h.picks, 0)
		} else if .Stop in h.flags {
			h.flags += {.Stopped}
			return s, .Stop
		}
	} else {
		f := &h.frames.data[d - 1]
		index = f.count
		f.count += 1
		whole = .Whole in f.flags
		if .Object not_in f.flags {
			ok: bool
			if s, ok = scan_element(h, s, f, index, t, d); !ok {
				return s, scan_halt(h, t)
			}
		} else if .Keys in f.flags && h.picks.len == 0 {
			return scan_stub(h, s, t)
		}
	}
	if h.picks.len == 0 && !whole {
		return scan_pass(h, s, t)
	}
	owner := tape.Node_Index(s.b >> 32)
	if h.has_key {
		s, _ = builder_step(&h.b, s, h.key, false, true)
		h.has_key = false
	}
	at := builder_cursor(&h.b, s)
	by_place := .By_Place in h.flags
	if by_place {
		h.flags -= {.By_Place}
		scan_push(h, &h.kept, Scan_Kept{at, u32(index)})
	}
	dm := h.demand
	live := h.live.len
	answered := h.answers.len
	ends, stubs := false, false
	// A `Descend` takes the value itself: the node it leads to takes what its node takes, so the list grows as it is read.
	for i := u32(0); i < h.picks.len; i += 1 {
		n := h.picks.data[i]
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
		return scan_past(h, s, list_slice(h.picks), d)
	}
	if h.live.len > live {
		s, _ = builder_step(&h.b, s, t, false, true)
		scan_open(h, t, live, whole || ends)
		if d > 0 && h.b.err == nil {
			scan_keep_element(h, d, t.kind, h.answers.len == answered && !by_place)
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
	if s, ok = builder_unread(&h.b, s, t, true); !ok {
		return s, .Stop
	}
	return s, .Skip
}

// Keeps a member no path takes of an object a `.Keys` grain keeps: its key, and its value `t`, a container as one
// unread node.
@(private = "file")
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
	if kept, ok = builder_unread(&h.b, kept, t, true); !ok {
		return kept, .Stop
	}
	h.end_of = .Skipped
	return kept, .Skip
}

// Keeps scalar child `t` of the container `f`, which its one step takes to demand node `f.leaf`: the child's node, with
// its key in an object and its place in an array, and the answers of the paths the node ends.
// Invariants: `f.leaf != 0` guarantees `!(.Settles in h.flags) && h.made == nil`, and when `.Object in f.flags` that
// `h.key.kind <= .Plain && h.key.role == .Key`.
@(private = "file")
scan_leaf :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token, f: ^Scan_Frame) -> (hook.Regs, hook.Action) #no_bounds_check {
	dm := h.demand
	node := dm.nodes[f.leaf]
	is_obj := .Object in f.flags
	if intrinsics.expect(node.n_ends == 1 && s.a + 2 * size_of(tape.Node) <= h.b.end && h.answers.len < h.answers.cap && (is_obj || h.kept.len < h.kept.cap), true) {
		s := s
		if is_obj {
			((^[2]u64)(uintptr(s.a)))^ = transmute([2]u64)h.key
			s.a += size_of(tape.Node)
			h.has_key = false
		}
		at := builder_cursor(&h.b, s)
		if !is_obj {
			kn := h.kept.len
			h.kept.data[kn] = {at, u32(f.count)}
			h.kept.len = kn + 1
		}
		f.count += 1
		an := h.answers.len
		h.answers.data[an] = {at, dm.ends[node.ends], 2 * u64(at), f.leaf, .Found, false, {}}
		h.answers.len = an + 1
		((^[2]u64)(uintptr(s.a)))^ = transmute([2]u64)t
		s.a += size_of(tape.Node)
		s.b += 1
		return s, .Next
	}
	return scan_leaf_grow(h, s, t)
}

@(private = "file", cold)
scan_leaf_grow :: #force_no_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	s := s
	f := &h.frames.data[s.c - 1]
	if .Object in f.flags {
		s, _ = builder_step(&h.b, s, h.key, false, true)
		h.has_key = false
	}
	at := builder_cursor(&h.b, s)
	if .Object not_in f.flags {
		scan_push(h, &h.kept, Scan_Kept{at, u32(f.count)})
	}
	f.count += 1
	dm := h.demand
	node := dm.nodes[f.leaf]
	for p in dm.ends[node.ends:][:node.n_ends] {
		scan_push(h, &h.answers, Scan_Answer{at, p, 2 * u64(at), f.leaf, .Found, false, {}})
	}
	kept, _ := builder_step(&h.b, s, t, false, true)
	return kept, .Stop if h.b.err != nil else .Next
}

// Opens again the frame the first child of the container `f` opened with, for child `t` of the same kind, a member with
// its key. Caller guarantees `t.kind > .Plain && t.kind == f.element`, and `has_key` implies `h.key.kind <= .Plain`.
@(private = "file")
scan_reopen :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token, f: ^Scan_Frame) -> (hook.Regs, hook.Action) #no_bounds_check {
	if intrinsics.expect(s.a + 2 * size_of(tape.Node) <= h.b.end && h.frames.len < h.frames.cap && h.opens < max(u32), true) {
		d := s.c
		f.count += 1
		live := f.live + f.n_live
		opened := s
		if h.has_key {
			((^[2]u64)(uintptr(opened.a)))^ = transmute([2]u64)h.key
			opened.a += size_of(tape.Node)
			h.has_key = false
		}
		a := builder_cursor(&h.b, opened)
		((^[2]u64)(uintptr(opened.a)))^ = transmute([2]u64)t
		h.b.stack[opened.c] = opened.b + 1
		opened.c += 1
		opened.a += size_of(tape.Node)
		opened.b = u64(a) << 32
		fn := h.frames.len
		g := &h.frames.data[fn]
		h.frames.len = fn + 1
		g^ = h.elements.data[d]
		h.opens += 1
		g.gen, g.live = h.opens, live
		// The element's live demand nodes are those it opened with, past the array's. No frame writes over them between
		// one element of the array and the next, since no other frame opens at its level.
		h.live.len = live + g.n_live
		return opened, .Next
	}
	return scan_reopen_grow(h, s, t)
}

@(private = "file", cold)
scan_reopen_grow :: #force_no_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) #no_bounds_check {
	d := s.c
	f := &h.frames.data[d - 1]
	f.count += 1
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
	if h.opens == max(u32) {
		scan_wrap_opens(h)
	} else {
		h.opens += 1
	}
	fn := h.frames.len
	g := &h.frames.data[fn]
	h.frames.len = fn + 1
	g^ = h.elements.data[d]
	g.gen, g.live = h.opens, live
	h.live.len = live + g.n_live
	return opened, .Next
}

// Renumbers open frame generations to `1..len(h.frames)` and remaps `h.marks`/`h.saved` when `h.opens` wraps around
// under `f.drops`, leaving `h.opens = u32(len(h.frames)) + 1` so no generation is 0 or collides with an open frame.
@(private = "file", cold)
scan_wrap_opens :: #force_no_inline proc "contextless" (h: ^Scanner) #no_bounds_check {
	frames := list_slice(h.frames)
	remap :: proc "contextless" (entries: []u64, frames: []Scan_Frame) #no_bounds_check {
		for &m in entries {
			g := u32(m >> 32)
			if g == 0 {
				continue
			}
			found := u32(0)
			for f, i in frames {
				if f.gen == g {
					found = u32(i + 1)
					break
				}
			}
			m = u64(found) << 32 | u64(u32(m)) if found != 0 else 0
		}
	}
	remap(h.marks, frames)
	remap(list_slice(h.saved), frames)
	for &f, i in frames {
		f.gen = u32(i + 1)
	}
	h.opens = u32(len(frames)) + 1
}

// Records in the container at depth `d` the frame its child of `kind` just opened, for later children of that kind to
// reopen with. It does so only when the child made no answer, in a `.Uniform` array (every element picks the same
// demand nodes), and in an object whose one step is a `Name`, which picks every member it takes alike.
@(private = "file")
scan_keep_element :: #force_inline proc "contextless" (h: ^Scanner, d: u64, kind: tape.Kind, reopens: bool) #no_bounds_check {
	f := &h.frames.data[d - 1]
	is_obj := .Object in f.flags
	// An `Index` picks one element, and a ring keeps an entry per element.
	if f.unmet != 0 || (f.u.obj.named == 0 if is_obj else f.u.arr.ring_k != 0) {
		return
	}
	f.element = .End
	// A reopened element skips `scanner_value`, which lists the kept elements of a partial array, and `scan_open`, which
	// saves the marks of a deep frame.
	if !reopens || .Uniform not_in f.flags || .Deep in h.frames.data[d].flags {
		return
	}
	if int(h.elements.len) <= int(d) {
		if !scan_reserve(h, &h.elements, int(d) + 1 - int(h.elements.len)) {
			return
		}
		h.elements.len = u32(d) + 1
	}
	h.elements.data[d] = h.frames.data[d]
	h.frames.data[d - 1].element = kind
}

// Passes a value no step took. A container is skipped, giving no more tokens up to its `End`.
@(private = "file")
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

// Makes an answer of `path` at `node`, through demand node `leaf`. `pos` orders the answers: twice a node index, or one
// less for a miss a close found. A refused growth is held in the builder's error, so the result is nil.
@(private = "file")
scan_answer :: #force_inline proc "contextless" (h: ^Scanner, node: tape.Node_Index, path: u32, outcome: tape.Presence, pos: u64, leaf: u32) -> runtime.Allocator_Error {
	if h.made == nil || scan_limit(h, path) {
		scan_push(h, &h.answers, Scan_Answer{node, path, pos, leaf, outcome, false, {}})
	}
	return nil
}

// Whether a limited demand keeps an answer of `path` as it is made. It keeps one past the path's limit only while a
// step may still take back an earlier one. A path whose answers no step takes back is settled at its limit.
@(private = "file", cold)
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
	for &a in h.answers.data[lo:hi] {
		if a.leaf >= to && a.leaf <= last && !a.dead {
			a.dead = true
			if h.made != nil && h.demand.paths[a.path].limit > 0 {
				h.made[a.path] -= 1
			}
		}
	}
}

// Answers the paths whose `Name` or `Index` steps at the closing container `f` at depth `d`, node `open`, met no child,
// and records each missing name once, though several demand nodes may look for it.
@(private = "file", cold)
scan_close_misses :: #force_no_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame, d: u64, open: tape.Node_Index, pos: u64) #no_bounds_check {
	dm := h.demand
	missed := int(h.missing.len)
	is_obj := .Object in f.flags
	for n in h.live.data[f.live:][:f.n_live] {
		node := dm.nodes[n]
		for e in node.edges ..< node.edges + node.n_edges {
			edge := dm.edges[e]
			#partial switch step in edge.step {
			case tape.Name:
				if is_obj && u32(h.marks[e] >> 32) != f.gen {
					if !scan_missed(h, missed, string(step)) {
						scan_push(h, &h.missing, Scan_Missing{open, string(step)})
					}
					paths_fail(h, dm, edge.to, .Missing, d, open, open, pos, scan_answer)
				}
			case tape.Index:
				if _, in_array := tape.index_in(i64(step), f.count); !is_obj && !in_array {
					paths_fail(h, dm, edge.to, .Missing, d, open, open, pos, scan_answer)
				}
			}
		}
	}
}

// Whether the close that records missing names from `from` in `Scanner.missing` has recorded `name`.
// `#no_bounds_check` invariant: `from <= int(h.missing.len)` (captured at entry to `scan_close_misses`).
@(private = "file", require_results)
scan_missed :: proc "contextless" (h: ^Scanner, from: int, name: string) -> bool #no_bounds_check {
	for m in h.missing.data[from:h.missing.len] {
		if m.name == name {
			return true
		}
	}
	return false
}

// Opens a frame for the container just stored, its live demand nodes those from `live` in `Scanner.live`.
@(private = "file")
scan_open :: proc "contextless" (h: ^Scanner, t: tape.Token, live: u32, whole: bool) #no_bounds_check {
	dm := h.demand
	if h.opens == max(u32) {
		scan_wrap_opens(h)
	} else {
		h.opens += 1
	}
	is_obj := t.kind == .Object
	flags: Scan_Frame_Flags
	if whole {
		flags += {.Whole, .Alls}
	}
	if is_obj {
		flags += {.Object}
	} else if !whole {
		flags += {.Indexed}
	}
	f := Scan_Frame{live = live, n_live = h.live.len - live, gen = h.opens, flags = flags, element = .End}
	k := u64(0)
	takes_from, takes_to := u64(0), max(u64)
	others := false
	for n in h.live.data[live:h.live.len] {
		node := &dm.nodes[n]
		k = max(k, node.neg)
		takes_from = max(takes_from, node.takes_from)
		takes_to = min(takes_to, node.takes_to)
		f.unmet += node.names if is_obj else node.indexes
		if is_obj {
			f.u.obj.lengths |= node.lengths
			f.u.obj.heads |= node.heads
			f.u.obj.tails |= node.tails
		} else {
			f.u.arr.fills = max(f.u.arr.fills, node.fills)
			f.u.arr.places |= node.places
			if node.sliced {
				f.flags -= {.Indexed}
			}
		}
		others ||= node.others
		if node.alls {
			f.flags += {.Alls}
		}
		if node.keys {
			f.flags += {.Keys}
		}
		if node.slices {
			f.flags += {.Slices}
		}
		if node.deep {
			f.flags += {.Deep}
		}
	}
	if takes_from == 0 && takes_to == max(u64) {
		f.flags += {.Uniform}
	}
	// An array's count is kept by every frame.
	if whole || !is_obj {
		f.flags -= {.Keys}
	}
	if .Keys in f.flags {
		f.flags += {.Alls}
	}
	if is_obj && !whole && .Keys not_in f.flags {
		f.flags += {.Passes}
	}
	if !is_obj {
		k = ring_entries(k, h.b.doc.src, h.rewalk != nil)
		k = min(k, u64(max(u32)))
		// Only one array is read again at a time, so a replay holds at most one more walk and reads each element once
		// more. A format that cannot walk an element alone keeps every element a step from the end may take, and takes
		// back what the elements it does not take answered.
		if k > 0 && !others && !whole {
			if .Replaying not_in h.flags && .Rewalks in h.flags {
				f.flags += {.Replays}
			} else if .Rewalks not_in h.flags {
				f.flags += {.Drops}
			}
		}
		f.u.arr.ring_k = u32(k)
		f.u.arr.ring = h.tokens.len if .Replays in f.flags else h.ring.len
		if k != 0 || .Alls in f.flags {
			f.flags -= {.Indexed}
		}
	}
	if f.n_live == 1 && f.flags & {.Indexed, .Passes} != {} {
		if node := dm.nodes[h.live.data[live]]; node.n_edges == 1 && !node.deep && (.Indexed in f.flags || node.names == 1) {
			if .Passes in f.flags {
				f.u.obj.named = node.edges + 1
			}
			to := dm.edges[node.edges].to
			if dm.nodes[to].n_edges == 0 && dm.nodes[to].descend == 0 && .Settles not_in h.flags && h.made == nil {
				f.leaf = to
			}
		}
	}
	if .Deep in f.flags {
		scan_save_marks(h, live)
	}
	scan_push(h, &h.frames, f)
}

// Takes demand node `to`, which a `Descend` of a node that took the coming value leads to, unless it took it already.
@(private = "file", cold)
scan_descend :: #force_no_inline proc "contextless" (h: ^Scanner, to: u32) #no_bounds_check {
	for n in list_slice(h.picks) {
		if n == to {
			return
		}
	}
	scan_put(&h.picks, to)
}

// Saves the marks of the `Name` steps of the deep demand nodes from `live` in `Scanner.live`, a frame's, as it opens.
@(private = "file", cold)
scan_save_marks :: #force_no_inline proc "contextless" (h: ^Scanner, live: u32) #no_bounds_check {
	dm := h.demand
	for n in h.live.data[live:h.live.len] {
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
@(private = "file", cold)
scan_restore_marks :: #force_no_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame) #no_bounds_check {
	dm := h.demand
	#reverse for n in h.live.data[f.live:][:f.n_live] {
		if node := dm.nodes[n]; node.deep {
			#reverse for edge, i in dm.edges[node.edges:][:node.n_edges] {
				if _, named := edge.step.(tape.Name); named && h.saved.len > 0 {
					h.marks[node.edges + u32(i)] = h.saved.data[h.saved.len - 1]
					h.saved.len -= 1
				}
			}
		}
	}
}

@(private = "file")
scanner_close :: proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token, $COLUMNS: bool) -> (hook.Regs, hook.Action) #no_bounds_check {
	s := s
	d := s.c
	f := &h.frames.data[d - 1]
	open := tape.Node_Index(s.b >> 32)
	when COLUMNS {
		f.count += h.dropped
		h.dropped = 0
	}
	if .Object not_in f.flags && f.u.arr.ring_k > 0 {
		halted: bool
		if s, halted = scan_close_ring(h, s, d); halted {
			// The array stays open, and the end closes it partial with its full count.
			return s, scan_halt(h, t)
		}
		f = &h.frames.data[d - 1]
	}
	if f.unmet != 0 && (.Object in f.flags || f.count < f.u.arr.fills) {
		scan_close_misses(h, f, d, open, 2 * u64(builder_cursor(&h.b, s)) - 1)
	}
	if u64(u32(s.b)) == f.count {
		s, _ = builder_step(&h.b, s, t, false, true)
		h.b.closed = open
	} else {
		s = scan_close_partial(h, s, f.count)
	}
	learns := COLUMNS && d == 2 && .Tried not_in h.record.flags
	if .Settles in h.flags && d - 1 <= h.demand.reach || learns {
		scan_closed(h, f, d, open, builder_cursor(&h.b, s), learns)
	}
	if .Deep in f.flags {
		scan_restore_marks(h, f)
	}
	h.live.len = f.live
	if .Object not_in f.flags && f.u.arr.ring_k > 0 {
		if .Replays in f.flags {
			h.tokens.len = f.u.arr.ring
		} else {
			h.ring.len = f.u.arr.ring
		}
	}
	h.frames.len -= 1
	return scan_left(h, s)
}

// After the close of the container `f` at depth `d`, node `open`, whose nodes end at `end`: settles the paths its
// demand nodes settle there, and learns the first record when `learns`.
@(private = "file", cold)
scan_closed :: #force_no_inline proc "contextless" (h: ^Scanner, f: ^Scan_Frame, d: u64, open, end: tape.Node_Index, learns: bool) #no_bounds_check {
	if .Settles in h.flags && d - 1 <= h.demand.reach {
		for n in h.live.data[f.live:][:f.n_live] {
			scan_settle(h, n, d - 1)
		}
	}
	if learns {
		scan_learn_record(h, f, open, end)
	}
}

// Closes the open container of `s`, of `count` children, as partial.
@(private = "file")
scan_close_partial :: proc "contextless" (h: ^Scanner, s: hook.Regs, count: u64) -> hook.Regs #no_bounds_check {
	s := s
	open := tape.Node_Index(s.b >> 32)
	node := &h.b.doc.nodes[open]
	node.n = u32(builder_cursor(&h.b, s) - open)
	node.spelling = node.spelling & tape.CONTAINER_STYLE | tape.CONTAINER_PARTIAL | u16(min(count, u64(tape.MAX_CHILDREN)))
	if count >= u64(tape.MAX_CHILDREN) {
		builder_partial_count(&h.b, open, u32(min(count, u64(max(u32)))))
	}
	h.b.closed = open
	s.c -= 1
	s.b = h.b.stack[s.c]
	return s
}

// Goes on past a value the demand nodes `picks` took at depth `d`.
@(private = "file")
scan_past :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs, picks: []u32, d: u64) -> (hook.Regs, hook.Action) {
	if .Settles in h.flags && d <= h.demand.reach {
		scan_settle_picks(h, picks, d)
	}
	return scan_left(h, s)
}

@(private = "file")
scan_settle_picks :: #force_no_inline proc "contextless" (h: ^Scanner, picks: []u32, d: u64) {
	for n in picks {
		scan_settle(h, n, d)
	}
}

@(private = "file")
scan_left :: #force_inline proc "contextless" (h: ^Scanner, s: hook.Regs) -> (hook.Regs, hook.Action) {
	if h.b.err != nil {
		return s, .Stop
	}
	if .Settles in h.flags && h.pending == 0 {
		scan_settled(h)
		return s, .Stop if .Stop in h.flags else .Next
	}
	return s, .Next
}

// Ends the scan's keeping once every path is settled: `stop_early` stops the walk, and otherwise the hook takes no
// more tokens while the walk judges the rest of the text.
@(private, cold)
scan_settled :: #force_no_inline proc "contextless" (h: ^Scanner) {
	if .Stop in h.flags {
		h.flags += {.Stopped}
	} else {
		h.end_of = .Settled
	}
}

// The answer to token `t` of a scan that took its last token, by a stop, a refused growth or every path settled.
@(private = "file", require_results)
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

// Makes room in `list` for `n` more entries. False once a growth is refused, which sets the builder's error.
@(private, require_results)
scan_reserve :: #force_inline proc "contextless" (h: ^Scanner, list: ^Scan_List($T), n: int) -> bool {
	if int(list.cap) - int(list.len) >= n {
		return true
	}
	return scan_grow_to(h, (^Scan_Raw_List)(list), size_of(T), align_of(T), int(list.len) + n)
}

// Appends `v` to a list `scan_reserve` made room in.
// `#no_bounds_check` invariant: caller proved `list.len < list.cap` (e.g. `picks` reserved for `len(edges) + 1`).
@(private)
scan_put :: #force_inline proc "contextless" (list: ^Scan_List($T), v: T) #no_bounds_check {
	list.data[list.len] = v
	list.len += 1
}

// Appends `v` to a list of the scan. A refused growth is held in the builder's error, which ends the walk.
@(private)
scan_push :: #force_inline proc "contextless" (h: ^Scanner, list: ^Scan_List($T), v: T) #no_bounds_check {
	if list.len == list.cap && !scan_grow_to(h, (^Scan_Raw_List)(list), size_of(T), align_of(T), int(list.len) + 1) {
		return
	}
	list.data[list.len] = v
	list.len += 1
}

@(private, cold, require_results)
scan_grow_to :: #force_no_inline proc "contextless" (h: ^Scanner, list: ^Scan_Raw_List, size, align, least: int) -> bool {
	max_items := max(int) / size
	when size_of(int) > 4 {
		max_items = min(max_items, int(max(u32)))
	}
	if least > max_items || h.scratch.procedure == nil {
		if h.b.err == nil {
			h.b.err = .Out_Of_Memory
		}
		return false
	}
	context = h.b.ctx
	cur_cap := int(list.cap)
	doubled := 2 * cur_cap if cur_cap <= max_items / 2 else max_items
	want := min(max(doubled, 8, least), max_items)
	data: []u8
	err: runtime.Allocator_Error
	if scan_in_room(h, list.data) {
		if data, err = runtime.mem_alloc_non_zeroed(want * size, align, h.scratch); err == nil {
			runtime.mem_copy_non_overlapping(raw_data(data), list.data, int(list.len) * size)
		}
	} else {
		data, err = runtime.non_zero_mem_resize(list.data, cur_cap * size, want * size, align, h.scratch)
	}
	if e := took(err, raw_data(data), want * size); e != nil {
		if h.b.err == nil {
			h.b.err = e
		}
		return false
	}
	list.data, list.cap = raw_data(data), u32(want)
	return true
}

@(private = "file")
scanner_free :: proc(h: ^Scanner) {
	free_list :: #force_inline proc(h: ^Scanner, list: ^Scan_List($T)) {
		if list.data != nil && !scan_in_room(h, list.data) {
			runtime.mem_free_with_size(list.data, int(list.cap) * size_of(T), h.scratch)
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
	if raw_data(h.marks) != nil && !scan_in_room(h, raw_data(h.marks)) {
		runtime.mem_free_with_size(raw_data(h.marks), len(h.marks) * size_of(u64) + len(h.made) * size_of(u32) + len(h.done), h.scratch)
	}
}
