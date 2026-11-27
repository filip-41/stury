package hook

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/tape"

// The walk's and the hook's state that a read of a text in pieces carries from one piece to the next. A format keeps
// what its grammar needs past it in a block whose first field is this.
Piece_State :: struct {
	started:   bool,
	nest:      Nest,
	rested:    bool,
	tolerated: bool,
	regs:      Regs,
	steps:     u64, // with `Budget.steps`, one more than the containers the walk may still open
	// The open containers, the root's first.
	opened:    [dynamic]Open_Level,
	names:     [dynamic]u8, // the open path's names
	steps_buf: [dynamic]tape.Step,
	hook:      rawptr, // the read's hook, in its own block
	hook_free: proc(hook: rawptr, allocator: runtime.Allocator),
	answer:    [2]u64, // with `find`, the span `text` holds
	// With `Budget.memory`, the count of the lists above and `Pieces.text` (`lists`) and of the read's own blocks
	// (`blocks`), one count from the first window to the last.
	lists:     Memory_Budget,
	blocks:    Memory_Budget,
}

// How the walk treats the tokens of a container its hook answered `Skip`, `Keep`, `Keep_Stubs` or `Rest` for, and
// with `Pass` those of the value of a member whose key it answered `Skip` for.
Nest :: enum u8 {
	None,
	Skip,
	Keep,
	Keep_Stubs,
	Rest,
	Pass,
}

// An open container of a text in pieces, and the member or element being read in it.
Open_Level :: struct {
	key:    tape.Token, // in an object, the key of the member being read, `n` 0 and `kind` `.End` for none
	count:  u64, // the values it has given
	name:   int, // where `key`'s text is in the open path's names once copied out of its window, -1 before
	name_n: u32,
	object: bool,
}

// The state of `p`, a block of the format's type `P` whose first field is a `Piece_State`, which its first read makes.
// Every read of `p` names the same `P`.
piece_state :: proc(p: ^tape.Pieces, $P: typeid) -> (s: ^P, err: runtime.Allocator_Error) {
	#assert(intrinsics.type_is_subtype_of(P, Piece_State))
	if p.state == nil {
		if p.allocator.procedure == nil {
			p.allocator = context.allocator
		}
		p.state = new(P, p.allocator) or_return
		p.release = piece_release
	}
	return (^P)(p.state), nil
}

// Starts a read of the window `src` of the text in pieces `p`: its state `s`, a block of the format's type `P`, which
// the first read makes with `release` as its `Pieces.release` when that is not nil, the window as the slice its tokens'
// offsets index (`tape.piece_src`) and the offset past it, or the error of a window that does not hold the bytes the
// read needs.
piece_begin :: proc(p: ^tape.Pieces, $P: typeid, release: proc(p: ^tape.Pieces), src: []u8) -> (s: ^P, text: []u8, to: u64, err: tape.Error) {
	state, serr := piece_state(p, P)
	if serr != nil {
		return nil, nil, 0, serr
	}
	if release != nil {
		p.release = release
	}
	to, err = tape.piece_window(p, src)
	return state, tape.piece_src(src, p.from), to, err
}

// Frees the state of `p` that `piece_state` made. A format whose block holds lists of its own sets `Pieces.release` to
// a procedure that frees them, then calls this.
piece_release :: proc(p: ^tape.Pieces) {
	s := (^Piece_State)(p.state)
	if s.hook != nil {
		s.hook_free(s.hook, p.allocator)
	}
	delete(s.opened)
	delete(s.names)
	delete(s.steps_buf)
	free(s, p.allocator)
}

// The allocator for the lists of `p.state` and `p.text`, which holds them within `Budget.memory` once `piece_blocks`
// set it.
piece_lists :: proc "contextless" (p: ^tape.Pieces) -> runtime.Allocator {
	s := (^Piece_State)(p.state)
	if s.lists.limit == 0 {
		return p.allocator
	}
	return memory_budget(&s.lists)
}

// The allocator for the blocks a read of a window takes from `allocator`. With `memory` not 0 they count with the lists
// of `p` against it, held from window to window.
piece_blocks :: proc "contextless" (p: ^tape.Pieces, memory: u64, allocator: runtime.Allocator) -> runtime.Allocator {
	if memory == 0 {
		return allocator
	}
	s := (^Piece_State)(p.state)
	if s.lists.limit == 0 {
		s.lists = {backing = p.allocator, limit = memory, peer = &s.blocks}
		s.blocks = {limit = memory, peer = &s.lists}
	}
	s.blocks.backing = allocator
	return memory_budget(&s.blocks)
}

// Sets `p.open` from the open containers of `p`, whose window is `src` of a text of format `f`. A key's text is copied
// out of the window the first time a read ends past it, as a later window may not hold it.
piece_path :: proc(p: ^tape.Pieces, src: []u8, f: ^tape.Format) -> runtime.Allocator_Error {
	s := (^Piece_State)(p.state)
	lists := piece_lists(p)
	names := make([dynamic]u8, 0, len(s.names), lists) or_return
	// Where each open level's key name lies in `names`, which the levels take once the whole path is built.
	places, perr := make([][2]int, len(s.opened), lists)
	if perr != nil {
		delete(names)
		return perr
	}
	placed := false
	defer {
		delete(places, lists)
		if !placed {
			delete(names)
		}
	}
	p.open = nil
	clear(&s.steps_buf)
	for lv, i in s.opened {
		if !lv.object || lv.key.kind == .End {
			continue
		}
		at := len(names)
		if lv.name >= 0 {
			append(&names, ..s.names[lv.name:][:lv.name_n]) or_return
		} else {
			room := max(tape.text_room(f, src, lv.key), int(lv.key.n))
			resize(&names, at + room) or_return
			text, ok := tape.node_text(f, src, lv.key, names[at:])
			if !ok {
				text = ""
			}
			if raw_data(text) != raw_data(names[at:]) {
				copy(names[at:], text)
			}
			resize(&names, at + len(text)) or_return
		}
		places[i] = {at, len(names) - at}
	}
	for lv, i in s.opened {
		if !lv.object {
			if i + 1 < len(s.opened) {
				append(&s.steps_buf, tape.Step(tape.Index(lv.count - 1))) or_return
			}
		} else if lv.key.kind != .End {
			append(&s.steps_buf, tape.Step(tape.Name(string(names[places[i][0]:][:places[i][1]])))) or_return
		}
	}
	for &lv, i in s.opened {
		if lv.object && lv.key.kind != .End {
			lv.name, lv.name_n = places[i][0], u32(places[i][1])
		}
	}
	delete(s.names)
	s.names, placed = names, true
	p.open = s.steps_buf[:]
	return nil
}

// Where a binary walk of a text in pieces resumes: at byte `i`, `d` levels deep with innermost frame `top`,
// and `passing` true when skipping the value of a skipped key.
Piece_Cut :: struct {
	i, d, top: u64,
	passing:   bool,
}

// Maps a container hook action to the `Nest` mode carried across piece boundaries.
nest_of :: #force_inline proc "contextless" (a: Action) -> Nest {
	#partial switch a {
	case .Skip:
		return .Skip
	case .Keep:
		return .Keep
	case .Keep_Stubs:
		return .Keep_Stubs
	case .Rest:
		return .Rest
	}
	return .None
}

// Copies `d` levels of `stack` into `frames` (using `frames`'s own allocator).
piece_levels :: proc "contextless" (frames: ^[dynamic]u8, stack: [^]$L, d: u64) -> bool {
	context = runtime.default_context()
	size := int(d) * size_of(L)
	if resize(frames, size) != nil {
		return false
	}
	intrinsics.mem_copy_non_overlapping(raw_data(frames^), stack, size)
	return true
}

// Records a container open/close token in `s.opened` for `Pieces.open`, setting `refused^` on OOM.
piece_track_container :: #force_no_inline proc "contextless" (ctx: ^runtime.Context, s: ^Piece_State, refused: ^bool, t: tape.Token) -> bool #no_bounds_check {
	n := len(s.opened)
	if t.kind == .End {
		pop_safe(&s.opened)
		if n > 1 {
			s.opened[n - 2].key.kind = .End
		}
		return true
	}
	if n > 0 && t.role == .Value {
		s.opened[n - 1].count += 1
	}
	level := Open_Level{key = {kind = .End}, object = t.kind == .Object, name = -1}
	if n < cap(s.opened) {
		raw := (^runtime.Raw_Dynamic_Array)(&s.opened)
		([^]Open_Level)(raw.data)[n] = level
		raw.len = n + 1
		return true
	}
	return piece_open_grow(ctx, s, refused, level)
}

@(private = "file", cold)
piece_open_grow :: #force_no_inline proc "contextless" (ctx: ^runtime.Context, s: ^Piece_State, refused: ^bool, level: Open_Level) -> bool {
	context = ctx^
	if _, e := append(&s.opened, level); e != nil {
		refused^ = true
		return false
	}
	return true
}

// Drops claims whose required byte offset has been reached by `to`.
piece_claims_prune :: proc(claims: ^[dynamic][2]u64, to: u64) {
	for k := 0; k < len(claims); {
		if claims[k][1] <= to {
			ordered_remove(claims, k)
		} else {
			k += 1
		}
	}
}

