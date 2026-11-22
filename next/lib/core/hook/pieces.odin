package hook

import "base:runtime"
import "stury:lib/core/tape"

// The walk's and the hook's state that a read of a text in pieces carries from one piece to the next.
Piece_State :: struct {
	started:   bool,
	place:     u8, // the format's place in its grammar past the last token, 0 at the text's start
	nest:      Nest,
	rested:    bool,
	tolerated: bool,
	regs:      Regs,
	last:      u64, // one past the last token the walk gave, or past the run of comments `run` held back before it
	nest_open: u64, // with `nest`, the containers open inside the one the hook passed
	steps:     u64, // with `Budget.steps`, one more than the containers the walk may still open
	// The open containers, the root's first, and per container a format's level.
	opened:    [dynamic]Open_Level,
	levels:    [dynamic]u32,
	names:     [dynamic]u8, // the open path's names
	steps_buf: [dynamic]tape.Step,
	memo:      []u8, // what the format's walk keeps across pieces
	hook:      rawptr, // the read's hook, in its own block
	hook_free: proc(hook: rawptr, allocator: runtime.Allocator),
	answer:    [2]u64, // with `find`, the span `text` holds
	cut:       Cut_Token,
	run:       Cut_Run,
	// With `Budget.memory`, the count of the lists above and `Pieces.text` (`lists`) and of the read's own blocks
	// (`blocks`), one count from the first window to the last.
	lists:     Memory_Budget,
	blocks:    Memory_Budget,
}

// A token the window ended inside, read up to `on`, which the next window reads on from rather than from its first
// byte. `on` is 0 for none.
Cut_Token :: struct {
	lo, on:   u64,
	digits:   [2]u64, // a number's integer and fraction digits so far
	spelling: u16, // the spelling so far
	part:     u8, // the format's part of the token `on` is in
	quote:    u8, // a string's closing quote
}

// A run of white space and comments the window ended inside, read up to `on`, which the next window reads on from. Its
// comments wait in `comments` for the token past the run, which decides their roles, and are given to the hook in the
// window the run ends in, which may no longer hold their bytes: a hook that reads a comment's bytes holds them itself.
Cut_Run :: struct {
	state:    u8, // the format's state the run is read in, 0 for none
	part:     u8, // the format's part of the run `on` is in
	place:    u8, // the format's place in its grammar before the run's first comment
	line:     bool, // a line ends in the run before `on`
	crossed:  bool, // the run crossed the one comma it may hold
	held:     bool, // the comment `on` is in holds a line end
	comma:    u32, // with `crossed`, the comments before the comma
	lo:       u64, // the first byte of the comment `on` is in
	on:       u64,
	// The run's comments so far, for a hook, each `Comment_Inline` or `Comment` for one the token past the run decides.
	comments: [dynamic]tape.Token,
}

// How the walk treats the tokens of a container its hook answered `Skip`, `Keep`, `Keep_Stubs` or `Rest` for.
Nest :: enum u8 {
	None,
	Skip,
	Keep,
	Keep_Stubs,
	Rest,
}

// An open container of a text in pieces, and the member or element being read in it.
Open_Level :: struct {
	key:      tape.Token, // in an object, the key of the member being read, `n` 0 and `kind` `.End` for none
	count:    u64, // the values it has given
	object:   bool,
	name:     i32, // where `key`'s text is in the open path's names once copied out of its window, -1 before
	name_n:   u32,
}

// The bytes of the window of `src` taken at offset `from`, as a slice that its tokens' offsets in the whole text index.
// Its bytes before `from` are not to be read: a read starts at or past `keep`, which no window starts past, and a
// hook reads only tokens of that read or bytes its `keep` holds. Its base, the window's address less `from`, is
// computed in integers and only added to, with no bounds, so it may wrap below zero with no effect on an index past it.
piece_src :: #force_inline proc "contextless" (src: []u8, from: u64) -> []u8 {
	return ([^]u8)(uintptr(raw_data(src)) - uintptr(from))[:from + u64(len(src))]
}

// The state of `p`, which its first read makes.
piece_state :: proc(p: ^tape.Pieces) -> (s: ^Piece_State, err: runtime.Allocator_Error) {
	if p.state == nil {
		if p.allocator.procedure == nil {
			p.allocator = context.allocator
		}
		p.state = new(Piece_State, p.allocator) or_return
		p.release = piece_release
	}
	return (^Piece_State)(p.state), nil
}

@(private)
piece_release :: proc(p: ^tape.Pieces) {
	s := (^Piece_State)(p.state)
	if s.hook != nil {
		s.hook_free(s.hook, p.allocator)
	}
	delete(s.opened)
	delete(s.levels)
	delete(s.names)
	delete(s.steps_buf)
	delete(s.run.comments)
	delete(s.memo, p.allocator)
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
	names := make([dynamic]u8, 0, len(s.names), s.names.allocator) or_return
	defer {
		delete(s.names)
		s.names = names
	}
	clear(&s.steps_buf)
	for &lv in s.opened {
		if !lv.object || lv.key.kind == .End {
			continue
		}
		at := len(names)
		if lv.name >= 0 {
			append(&names, ..s.names[lv.name:][:lv.name_n]) or_return
		} else {
			room := max(tape.text_room(f, src, lv.key), int(lv.key.n))
			resize(&names, at + room) or_return
			text, ok := tape.node_text_of(f, src, lv.key, names[at:])
			if !ok {
				text = ""
			}
			if raw_data(text) != raw_data(names[at:]) {
				copy(names[at:], text)
			}
			resize(&names, at + len(text)) or_return
		}
		lv.name, lv.name_n = i32(at), u32(len(names) - at)
	}
	for lv, i in s.opened {
		if !lv.object {
			if i + 1 < len(s.opened) {
				append(&s.steps_buf, tape.Step(tape.Index(lv.count - 1))) or_return
			}
		} else if lv.key.kind != .End {
			append(&s.steps_buf, tape.Step(tape.Name(string(names[lv.name:][:lv.name_n])))) or_return
		}
	}
	p.open = s.steps_buf[:]
	return nil
}

