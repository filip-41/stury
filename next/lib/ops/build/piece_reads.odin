package build

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The reads of a text in pieces that `validate`, `build`, `find` and `scan` run for `Options.pieces`, over the state a
// format keeps from piece to piece as `$P`, a type whose first field is a `hook.Piece_State`, and its walk of one window
// as `$walk`, which walks the window from the state `Options.pieces` holds and updates it (`more`,
// `at`, `keep`, `open`) for the next window. Each read keeps its hook, and the memory budget its blocks are counted in,
// in its own block from the first window to the last.

read_validate_pieces :: proc(src: []u8, format: ^tape.Format, opts: tape.Options, caller: runtime.Allocator, $P: typeid, $walk: proc(src: []u8, opts: tape.Options, h: ^hook.No_Hooks, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool)) -> tape.Error {
	if e := tape.options_refused(format, opts); e != nil {
		return e
	}
	if !validate_dups(opts) {
		return tape.Bad_Option{"dups"}
	}
	p := opts.pieces
	s := hook.piece_state(p, P) or_return
	h: hook.No_Hooks
	a := hook.piece_blocks(p, opts.budget.memory, caller)
	regs := s.regs
	ctx := context
	_, err, _ := walk(src, opts, &h, &regs, a, &ctx)
	return hook.memory_budget_error(&s.blocks, err)
}

// The build's hook state kept between windows.
@(private)
Build_Piece :: struct {
	b: Builder,
}

@(private)
build_piece_free :: proc(held: rawptr, allocator: runtime.Allocator) {
	blk := (^Build_Piece)(held)
	_, _ = builder_end(&blk.b, {}, 0, runtime.Allocator_Error.Out_Of_Memory)
	free(blk, allocator)
}

// Builds a text in pieces. The document's nodes point into the text, so the build keeps every byte, and each window
// starts at the text's start. `finish` settles the document once the last window ends it, as `read_build`'s does, and
// `so_far`, when given, settles each document so far, and on an error destroys it.
read_build_pieces :: proc(src: []u8, format: ^tape.Format, rules: ^tape.Rules, opts: tape.Options, caller: runtime.Allocator, $P: typeid, $walk: proc(src: []u8, opts: tape.Options, h: ^Builder, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool), $finish: proc(doc: ^tape.Document, opts: tape.Options, rules: ^tape.Rules) -> tape.Error, so_far: proc(doc: ^tape.Document, opts: tape.Options, rules: ^tape.Rules) -> tape.Error = nil) -> (doc: tape.Document, err: tape.Error) {
	if e := tape.options_refused(format, opts); e != nil {
		return {}, e
	}
	p := opts.pieces
	s := hook.piece_state(p, P) or_return
	blk := (^Build_Piece)(s.hook)
	if blk == nil {
		if s.started {
			return {}, nil
		}
		blk = new(Build_Piece, p.allocator) or_return
		allocator := hook.piece_blocks(p, opts.budget.memory, caller)
		builder_start(&blk.b, src, format, max(len(src) / BUILD_BYTES_PER_NODE, SCAN_NODES), node_most(max(u64), opts), nil, allocator)
		if blk.b.err != nil {
			e := hook.memory_budget_error(&s.blocks, blk.b.err)
			free(blk, p.allocator)
			return {}, e
		}
		s.hook, s.hook_free, s.regs = blk, build_piece_free, builder_regs(&blk.b)
	}
	blk.b.doc.src = hook.piece_src(src, p.from)
	regs := s.regs
	root_close, werr, tolerated := walk(src, opts, &blk.b, &regs, blk.b.doc.allocator, &blk.b.ctx)
	if werr == nil && p.more {
		p.keep = 0
		if !p.so_far {
			return {}, nil
		}
		doc, err = builder_so_far(&blk.b, regs, p.at, caller)
		if err == nil && so_far != nil {
			err = so_far(&doc, opts, rules)
		}
		err = read_end(&doc, err, &s.blocks, tolerated, caller)
		return
	}
	defer {
		free(blk, p.allocator)
		s.hook = nil
	}
	doc, err = builder_end(&blk.b, regs, root_close, werr)
	if err == nil {
		err = finish(&doc, opts, rules)
	}
	err = read_end(&doc, err, &s.blocks, tolerated, caller)
	return
}

// The find's hook state kept between windows.
@(private)
Find_Piece :: struct {
	f:    Finder,
	room: Find_Room,
}

@(private)
find_piece_free :: proc(held: rawptr, allocator: runtime.Allocator) {
	blk := (^Find_Piece)(held)
	finder_end(&blk.f)
	free(blk, allocator)
}

// Returns the answer of a find over a text in pieces. Its bytes are copied out of the window it closes in into
// `Pieces.text`. Until then the read keeps from its first byte, and from the first byte of each span its rings hold.
read_find_pieces :: proc(src: []u8, path: []tape.Step, format: ^tape.Format, read: tape.Read_Options, opts: tape.Options, caller: runtime.Allocator, respell: proc "contextless" (src: []u8, lo, hi: u64) -> u16, $P: typeid, $walk: proc(src: []u8, opts: tape.Options, h: ^Finder, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool)) -> (answer: tape.Span_Answer, err: tape.Error) {
	if e := tape.options_refused(format, opts); e != nil {
		return {}, e
	}
	p := opts.pieces
	s := hook.piece_state(p, P) or_return
	blk := (^Find_Piece)(s.hook)
	if blk == nil {
		if s.started {
			return {}, nil
		}
		blk = new(Find_Piece, p.allocator) or_return
		allocator := hook.piece_blocks(p, opts.budget.memory, caller)
		if e := finder_start(&blk.f, src, format, path, opts.dups, read, respell, nil, &blk.room, allocator); e != nil {
			free(blk, p.allocator)
			return {}, hook.memory_budget_error(&s.blocks, e)
		}
		s.hook, s.hook_free = blk, find_piece_free
	}
	text := hook.piece_src(src, p.from)
	blk.f.src, blk.f.key_text = text, text
	regs := s.regs
	_, werr, tolerated := walk(src, opts, &blk.f, &regs, blk.f.allocator, &blk.f.ctx)
	if werr == nil {
		if e := find_piece_copy(p, s, &blk.f, text); e != nil {
			werr = e
		}
	}
	if werr == nil && p.more {
		p.keep = min(p.keep, finder_holds(&blk.f))
		return {}, nil
	}
	defer {
		find_piece_free(blk, p.allocator)
		s.hook = nil
	}
	if werr != nil {
		return {}, hook.memory_budget_error(&s.blocks, werr)
	}
	if blk.f.refused {
		return {}, hook.memory_budget_error(&s.blocks, runtime.Allocator_Error.Out_Of_Memory)
	}
	if a := blk.f.answer; a.outcome != .Not_Loaded && a.hi > a.lo {
		blk.f.src = hook.piece_src(p.text, a.lo)
	}
	answer = finder_answer(&blk.f)
	answer.tolerated = tolerated
	return answer, nil
}

// Copies the bytes of the finder's answer out of the window `text` once the answer is complete and not yet copied.
@(private)
find_piece_copy :: proc(p: ^tape.Pieces, s: ^hook.Piece_State, f: ^Finder, text: []u8) -> runtime.Allocator_Error {
	a := f.answer
	if a.outcome == .Not_Loaded || f.pending || a.hi <= a.lo || s.answer == {a.lo, a.hi} {
		return nil
	}
	lists := hook.piece_lists(p)
	buf := make([]u8, a.hi - a.lo, lists) or_return
	copy(buf, text[a.lo:a.hi])
	delete(p.text, lists)
	p.text, s.answer = buf, {a.lo, a.hi}
	return nil
}

// The scan's hook state kept between windows.
@(private)
Scan_Piece :: struct {
	h:    Scanner,
	room: Scan_Room,
}

@(private)
scan_piece_free :: proc(held: rawptr, allocator: runtime.Allocator) {
	blk := (^Scan_Piece)(held)
	_, _ = scanner_end(&blk.h, {}, 0, runtime.Allocator_Error.Out_Of_Memory)
	free(blk, allocator)
}

// Returns the document of a scan over a text in pieces. Its keys, scalars and facts are copied out of each window as it
// ends, so the read keeps only what the walk needs, and the document is `.Held`. A walk that holds comments back past a
// window's end keeps their bytes for a scan of facts, which copies them out in the window that gives them.
read_scan_pieces :: proc(src: []u8, demand: ^tape.Demand, format: ^tape.Format, read: tape.Read_Options, opts: tape.Options, caller: runtime.Allocator, $P: typeid, $walk: proc(src: []u8, opts: tape.Options, h: ^Scanner, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool)) -> (doc: tape.Document, err: tape.Error) {
	if e := tape.options_refused(format, opts); e != nil {
		return {}, e
	}
	p := opts.pieces
	s := hook.piece_state(p, P) or_return
	blk := (^Scan_Piece)(s.hook)
	if blk == nil {
		if s.started {
			return {}, nil
		}
		blk = new(Scan_Piece, p.allocator) or_return
		allocator := hook.piece_blocks(p, opts.budget.memory, caller)
		if e := scanner_start(&blk.h, src, format, demand, opts.dups, read, nil, SCAN_NODES, node_most(max(u64), opts), nil, &blk.room, allocator); e != nil {
			free(blk, p.allocator)
			return {}, hook.memory_budget_error(&s.blocks, e)
		}
		blk.h.key_skips = false
		s.hook, s.hook_free, s.regs = blk, scan_piece_free, builder_regs(&blk.h.b)
	}
	text := hook.piece_src(src, p.from)
	blk.h.b.doc.src, blk.h.key_text = text, text
	regs := s.regs
	root_close, werr, tolerated := walk(src, opts, &blk.h, &regs, blk.h.b.doc.allocator, &blk.h.b.ctx)
	if werr == nil {
		if e := scanner_hold(&blk.h, regs, text); e != nil {
			werr = e
		}
	}
	if werr == nil && p.more {
		if !p.so_far {
			return {}, nil
		}
		doc, err = scanner_so_far(&blk.h, regs, p.at, caller)
		err = read_end(&doc, err, &s.blocks, tolerated, caller)
		return
	}
	defer {
		free(blk, p.allocator)
		s.hook = nil
	}
	doc, err = scanner_end(&blk.h, regs, root_close, werr)
	err = read_end(&doc, err, &s.blocks, tolerated, caller)
	return
}
