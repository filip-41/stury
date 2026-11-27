package toml

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Reads a text in windows. The statements of a text read into the same tree as a whole text's, so a window's read does
// what the whole read does from where the last window stopped: it frames the statement at the read's position, which
// must lie whole in the window, reads it, and gives the tokens the tree then holds, as the walk of a whole text does,
// so every token, fault and answer is the whole read's. A statement a window ends inside is framed on in the next
// window from where the framing stopped, so no byte is framed twice, and read once whole, so the window the statement
// ends in holds it from its first byte.
//
// What a window answers early depends on the hook. A hook that cannot stop, as a build's, is given no token until the
// text ends. A hook that can stop is given the tokens the walk reaches, which a table that later statements may still
// add to holds back: the walk gives a table's members in the order the text first names them, and the text may add to
// a table written before the member it is at, so it waits to give what follows the table until the table is sealed
// (an inline table, an array, or an element of an array of tables a later element follows) or the text ends. The read
// keeps from the first byte of what it has read and not given, so a text of tables written one after another is held
// from its second table on.

@(private = "file")
Tree_Budget :: hook.Memory_Budget

// What a read of a text in pieces keeps from one window to the next, besides the state `hook.Piece_State` holds.
@(private)
Piece :: struct {
	using state: hook.Piece_State,
	parser:      Parser, // the tree and the position of the statements read so far
	frames:      [dynamic]Frame, // the walk's open containers
	ending:      Statement_End, // where the statement at the read's position ends, as far as it is read
	floor:       int, // with `nest`, the frame of the container the nest ends with
	base:        int, // the levels the hook held before the walk
	begun:       bool, // the parser is made
	first:       bool, // the first statement is read, which a hook that can stop is given the root after
	rooted:      bool, // the root's tokens were given
	counts:      bool, // the walk counts `Budget.steps`
	tree_budget: Tree_Budget, // counts `opts.scratch` against `Budget.memory`
}

// Where the search for a statement's end is. A statement ends at a line end outside a comment, a string and a bracket.
@(private)
End_State :: enum u8 {
	Blank, // before the statement's first byte, over blank lines
	Blank_Comment, // in a comment before the statement
	Body,
	Body_Comment,
	Basic, // in a basic string on one line
	Basic_Escape,
	Quote, // after one `"`: a basic string, or the start of an empty one or of a multi-line one
	Quotes, // after two `"`
	Literal,
	Literal_Quote,
	Literal_Quotes,
	Multi, // in a multi-line basic string, counting the `"` run it is at the end of
	Multi_Escape,
	Multi_Literal,
}

@(private)
Statement_End :: struct {
	at:     int, // the next byte to frame
	state:  End_State,
	depth:  u32, // the brackets and braces open
	quotes: u8, // the quotes in a run at the end of a multi-line string
}

// Whether the window holds the statement at the parser's position whole, with the blank lines and comments before it
// and its line end, framing on from where the last call stopped. The framing is of what the grammar lets run past a
// line end: strings, arrays, and inline tables of 1.1. It reads a text the grammar refuses as far as the statement the
// fault is in, which the statement's read then judges.
@(private)
statement_ends :: proc "contextless" (s: ^Piece, p: ^Parser) -> bool #no_bounds_check {
	f := &s.ending
	src := p.src
	n := len(src)
	i := max(f.at, p.pos)
	state := f.state
	depth := f.depth
	quotes := f.quotes
	done := false
	for i < n && !done {
		b := src[i]
		switch state {
		case .Blank:
			switch b {
			case ' ', '\t', '\n', '\r': i += 1
			case '#':                   state, i = .Blank_Comment, i + 1
			case:                       state = .Body
			}
		case .Blank_Comment, .Body_Comment:
			if b == '\n' { state = .Blank if state == .Blank_Comment else .Body } else { i += 1 }
		case .Body:
			i += 1
			switch b {
			case '"':      state = .Quote
			case '\'':     state = .Literal_Quote
			case '#':      state = .Body_Comment
			case '[', '{': depth += 1
			case ']', '}': depth -= 1 if depth > 0 else 0
			case '\n':
				if depth == 0 { state, done = .Blank, true }
			}
		case .Quote, .Literal_Quote:
			q := u8('"') if state == .Quote else u8('\'')
			if b == q {
				state, i = .Quotes if state == .Quote else .Literal_Quotes, i + 1
			} else {
				state = .Basic if state == .Quote else .Literal
			}
		case .Quotes, .Literal_Quotes:
			q := u8('"') if state == .Quotes else u8('\'')
			if b == q {
				state, quotes, i = .Multi if state == .Quotes else .Multi_Literal, 0, i + 1
			} else {
				state = .Body
			}
		case .Basic, .Literal:
			q := u8('"') if state == .Basic else u8('\'')
			switch {
			case b == '\\' && state == .Basic: state, i = .Basic_Escape, i + 1
			case b == q:                       state, i = .Body, i + 1
			case b == '\n':                    state = .Body
			case:                              i += 1
			}
		case .Basic_Escape:
			if b == '\n' { state = .Body } else { state, i = .Basic, i + 1 }
		case .Multi, .Multi_Literal:
			q := u8('"') if state == .Multi else u8('\'')
			switch {
			case b == q:
				quotes, i = quotes + 1, i + 1
				if quotes == 5 { state = .Body }
			case quotes >= 3:
				state = .Body
			case b == '\\' && state == .Multi:
				quotes, state, i = 0, .Multi_Escape, i + 1
			case:
				quotes, i = 0, i + 1
			}
		case .Multi_Escape:
			state, i = .Multi, i + 1
		}
	}
	f.at, f.state, f.depth, f.quotes = i, state, depth, quotes
	return done
}

// Frees the state of a read of a text in pieces, whose lists the read's own allocator holds.
@(private)
piece_free :: proc(p: ^tape.Pieces) {
	s := (^Piece)(p.state)
	context.allocator = hook.piece_lists(p)
	if s.begun {
		parser_destroy(&s.parser)
	}
	delete(s.frames)
	hook.piece_release(p)
}

// Walks the window `src` of the text in pieces `opts.pieces` for hook `h` from its registers `regs`, and updates
// `opts.pieces` (`more`, `at`, `keep`, `open`) for the next window. A window must start at or before `keep` and end at
// or after `at`, and the first window must start the text. A hook that can stop is given the tokens the walk reaches
// in the statements the window holds, and any other none before the last window.
@(private)
piece_read :: proc(src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	hook.check(H)
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	context = ctx^
	p := opts.pieces
	s, text, to, e := hook.piece_begin(p, Piece, piece_free, src)
	if e != nil {
		return 0, e, false
	}
	lists := hook.piece_lists(p)
	context.allocator = lists
	if !s.begun {
		if to < 3 && !p.last {
			// A byte order mark is judged whole.
			p.more, p.at, p.keep, p.open = true, to, 0, nil
			return 0, nil, false
		}
		tree_allocator := hook.scratch(opts, lists, &s.tree_budget)
		if !parser_init(&s.parser, text, S == .Toml_1_1, build.read_depth(opts), tree_allocator) {
			return 0, hook.memory_budget_error(&s.tree_budget, runtime.Allocator_Error.Out_Of_Memory), false
		}
		s.begun = true
		s.frames.allocator, s.steps_buf.allocator = lists, lists
		s.parser.own = true
		s.parser.pos = text_start(text, 0)
		s.ending.at = s.parser.pos
		s.steps, s.counts = build.read_steps(opts), opts.budget.steps != 0
	}
	pa := &s.parser
	pa.src, pa.final = text, p.last
	w := Walk(H, true, C) {
		p      = pa,
		hooks  = h,
		frames = &s.frames,
		levels = s.base,
		floor  = s.floor,
		nest   = s.nest,
		steps  = {s.steps},
		piece  = {s},
	}
	when .Rooms in C {
		w.rooms = hook.rooms_end(h)
	}
	hs := regs^
	r := walk_end(&w, piece_walk(&w, &hs, s, on))
	spelled_into(&w)
	regs^ = hs
	s.steps, s.nest, s.floor, s.base, s.regs = w.steps[0], w.nest, w.floor, w.levels, hs
	if u8(r) == hook.WALK_MORE {
		// A hook that can stop is given the root, whose span starts at the text's first byte, with the first statement.
		keep := min(u64(pa.pos), held_from(&w))
		when .Skips in C {
			if !s.rooted {
				keep = 0
			}
		}
		p.more, p.at, p.keep = true, to, max(p.keep, keep)
		if e := piece_open(p, s); e != nil {
			return 0, e, false
		}
		return 0, nil, false
	}
	p.more, p.open = false, nil
	if u8(r) == 0 {
		return to, nil, false
	}
	root_close, err, _ = hook.walk_error(r, &RULES)
	return root_close, hook.memory_budget_error(&s.tree_budget, err), false
}

// Reads on from where the last window stopped, to where this one ends or the walk does.
@(private)
piece_walk :: proc(w: ^Walk($H, $LAX, $C), hs: ^hook.Regs, s: ^Piece, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	pa := w.p
	if !s.rooted {
		whole := reads_whole(w.hooks, C)
		for !pa.done && (whole || !s.first) {
			if !pa.final && !statement_ends(s, pa) {
				return hook.walk_result(u64(pa.pos), hook.WALK_MORE)
			}
			if !statement(pa) {
				return pa.fail
			}
			s.first = true
		}
		when H == hook.No_Hooks {
			if whole && !s.counts {
				return 0
			}
		}
		s.rooted = true
		return walk_root(w, hs, on)
	}
	return drive(w, hs, on)
}

// The first byte of what the walk has read and not given, the lowest offset the next window's walk needs, with the room
// before it that a multi-line string's quotes need.
@(private)
held_from :: proc "contextless" (w: ^Walk($H, $LAX, $C)) -> u64 {
	p := w.p
	lo := max(u64)
	for f in w.frames[:] {
		if next := p.tree.nodes[f.node].first if f.last == NIL else p.tree.nodes[f.last].next; next != NIL {
			x := notes_of(&p.tree, next)
			n := p.tree.nodes[next]
			switch {
			case x.heads != 0:
				lo = min(lo, p.tree.comments[x.head].lo)
			case n.key.kind == .String:
				lo = min(lo, n.key.lo)
			case:
				lo = min(lo, n.value.lo)
			}
		}
		x := notes_of(&p.tree, f.node)
		if x.inline.n != 0 {
			lo = min(lo, x.inline.lo)
		}
		if x.foots != 0 {
			lo = min(lo, p.tree.comments[x.foot].lo)
		}
	}
	return lo - min(lo, 8) if lo != max(u64) else lo
}

// Sets `p.open` to the path of the table the statements read so far have put the text in: the name of each table from
// the root, and the index of each element of an array of tables.
@(private)
piece_open :: proc(p: ^tape.Pieces, s: ^Piece) -> runtime.Allocator_Error {
	clear(&s.steps_buf)
	tree := &s.parser.tree
	for id := s.parser.cur; id != 0; id = tree.nodes[id].parent {
		parent := tree.nodes[tree.nodes[id].parent]
		if parent.kind == .Array {
			index := 0
			for k := parent.first; k != tree.nodes[id].parent && k != NIL && k != id; k = tree.nodes[k].next {
				index += 1
			}
			append(&s.steps_buf, tape.Step(tape.Index(index))) or_return
		} else {
			append(&s.steps_buf, tape.Step(tape.Name(tree.nodes[id].name))) or_return
		}
	}
	slice.reverse(s.steps_buf[:])
	p.open = s.steps_buf[:]
	return nil
}


@(private)
validate_pieces :: proc(src: []u8, $S: Spec, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	walk :: proc(src: []u8, opts: Options, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return piece_read(src, S, opts, h, regs, a, ctx, hook.no_hook)
	}
	return build.read_validate_pieces(src, &FORMATS[S], opts, allocator, Piece, walk)
}

@(private)
build_pieces :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Builder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return piece_read(src, S, opts, h, regs, a, ctx, build.builder_hook_facts)
	}
	return build.read_build_pieces(src, &FORMATS[S], &RULES, opts, caller, Piece, walk, build.builder_finish_dups)
}

@(private)
find_pieces :: proc(src: []u8, path: []tape.Step, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return piece_read(src, S, opts, h, regs, a, ctx, build.finder_key_skip_hook)
	}
	return build.read_find_pieces(src, path, &FORMATS[S], read, opts, caller, respell, Piece, walk)
}

@(private)
scan_pieces :: proc(src: []u8, demand: ^tape.Demand, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	// The scan holds the bytes it keeps out of each window, which the walk gives out of text order. A window may end
	// between a key and its value, so the scan of a text in pieces skips no member at its key, and its walk takes the
	// plain scanner hook.
	walk :: proc(src: []u8, opts: Options, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		h.scattered = true
		return piece_read(src, S, opts, h, regs, a, ctx, build.scanner_hook)
	}
	return spelled_present(build.read_scan_pieces(src, demand, &FORMATS[S], read, opts, caller, Piece, walk))
}
