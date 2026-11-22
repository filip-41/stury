package json

import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The reads of a text in pieces that `validate`, `build`, `find` and `scan` run for `Options.pieces`. Each keeps its
// hook, and the memory budget its blocks are counted in, in its own block from the first window to the last.

// Walks the window `src` of the text in pieces `opts.pieces` for hook `h` from its registers `regs`, and updates
// `opts.pieces` (`more`, `at`, `keep`, `open`) for the next window. A window must start at or before `keep` and end at
// or after `at`, and the first window must start the text.
@(private)
piece_read :: proc(src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	p := opts.pieces
	s, serr := hook.piece_state(p)
	if serr != nil {
		return 0, serr, false
	}
	to := p.from + u64(len(src))
	if p.from > p.keep || to < p.at {
		return 0, tape.Piece_Gap{p.keep, p.at, p.from, to}, false
	}
	if !s.started {
		a := hook.piece_lists(p)
		s.opened.allocator, s.levels.allocator, s.names.allocator, s.steps_buf.allocator = a, a, a, a
		s.run.comments.allocator = a
	}
	text := hook.piece_src(src, p.from)
	pw := Piece_Walk{s = s, from = p.from, end = to, more = !p.last, ctx = ctx}
	start := raw_data(text)
	if s.place == PLACE_ROOT && s.last == 0 && s.cut.on == 0 && s.run.state == 0 {
		if pw.more && piece_bom_open(src) {
			p.more, p.at, p.keep, p.open = true, to, 0, nil
			return 0, nil, false
		}
		start = kernel.skip_ws(start[bom_length(text):], start[to:])
	}
	r, took := walk_value(text, start, S, true, opts.tolerate, depth_limit(opts), opts.budget.steps, h, regs, allocator, ctx, &pw, on)
	root_close, err, _ = hook.walk_error(r, &RULES)
	p.more, p.at = pw.ended, to
	if pw.ended {
		p.keep = piece_keep_from(s, S)
		if e := hook.piece_path(p, text, &FORMATS[S]); e != nil {
			return 0, e, took
		}
	} else {
		p.open = nil
	}
	return root_close, err, took
}

@(private)
validate_pieces :: proc(src: []u8, $S: Spec, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	p := opts.pieces
	s := hook.piece_state(p) or_return
	h: hook.No_Hooks
	a := hook.piece_blocks(p, opts.budget.memory, allocator)
	regs := s.regs
	ctx := context
	_, err, _ := piece_read(src, S, opts, &h, &regs, a, &ctx, hook.no_hook)
	// No later read needs the bytes of a token the window cut short that lie before the point where its read continues.
	if p.more && s.cut.on != 0 {
		p.keep = max(p.keep, piece_cut_keep(s.cut))
	}
	return hook.memory_budget_error(&s.blocks, err)
}

// The build's hook state kept between windows.
@(private)
Build_Piece :: struct {
	b: build.Builder,
}

@(private)
build_piece_free :: proc(held: rawptr, allocator: runtime.Allocator) {
	blk := (^Build_Piece)(held)
	_, _ = build.builder_end(&blk.b, {}, 0, runtime.Allocator_Error.Out_Of_Memory)
	free(blk, allocator)
}

// Builds a text in pieces. The document's nodes point into the text, so the build keeps every byte, and each window
// starts at the text's start.
@(private)
build_pieces :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (doc: tape.Document, err: tape.Error) {
	p := opts.pieces
	s := hook.piece_state(p) or_return
	blk := (^Build_Piece)(s.hook)
	if blk == nil {
		if s.started {
			return {}, nil
		}
		blk = new(Build_Piece, p.allocator) or_return
		allocator := hook.piece_blocks(p, opts.budget.memory, caller)
		build.builder_start(&blk.b, src, &FORMATS[S], max(len(src) / BUILD_BYTES_PER_NODE, SCAN_NODES), node_most(max(u64), opts), nil, allocator)
		if blk.b.err != nil {
			e := hook.memory_budget_error(&s.blocks, blk.b.err)
			free(blk, p.allocator)
			return {}, e
		}
		s.hook, s.hook_free, s.regs = blk, build_piece_free, build.builder_regs(&blk.b)
	}
	blk.b.doc.src = hook.piece_src(src, p.from)
	regs := s.regs
	on :: build.builder_hook_facts when S != .Json else build.builder_hook
	root_close, werr, tolerated := piece_read(src, S, opts, &blk.b, &regs, blk.b.doc.allocator, &blk.b.ctx, on)
	if werr == nil && p.more {
		p.keep = 0
		if !p.so_far {
			return {}, nil
		}
		doc, err = build.builder_so_far(&blk.b, regs, p.at, caller)
		err = read_end(&doc, err, &s.blocks, tolerated, caller)
	return
	}
	defer {
		free(blk, p.allocator)
		s.hook = nil
	}
	doc, err = build.builder_end(&blk.b, regs, root_close, werr)
	if err == nil {
		err = build.builder_dups(&doc, opts.dups, &RULES)
	}
	err = read_end(&doc, err, &s.blocks, tolerated, caller)
	return
}

// The find's hook state kept between windows.
@(private)
Find_Piece :: struct {
	f:    build.Finder,
	room: build.Find_Room,
}

@(private)
find_piece_free :: proc(held: rawptr, allocator: runtime.Allocator) {
	blk := (^Find_Piece)(held)
	build.finder_end(&blk.f)
	free(blk, allocator)
}

// Returns the answer of a find over a text in pieces. Its bytes are copied out of the window it closes in into
// `Pieces.text`. Until then the read keeps from its first byte, and from the first byte of each span its rings hold.
@(private)
find_pieces :: proc(src: []u8, path: []tape.Step, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (answer: tape.Span_Answer, err: tape.Error) {
	p := opts.pieces
	s := hook.piece_state(p) or_return
	blk := (^Find_Piece)(s.hook)
	if blk == nil {
		if s.started {
			return {}, nil
		}
		blk = new(Find_Piece, p.allocator) or_return
		allocator := hook.piece_blocks(p, opts.budget.memory, caller)
		e: runtime.Allocator_Error
		if blk.f, e = build.finder_start(src, &FORMATS[S], path, read, respell, nil, &blk.room, allocator); e != nil {
			free(blk, p.allocator)
			return {}, hook.memory_budget_error(&s.blocks, e)
		}
		s.hook, s.hook_free = blk, find_piece_free
	}
	text := hook.piece_src(src, p.from)
	blk.f.src = text
	regs := s.regs
	_, werr, tolerated := piece_read(src, S, opts, &blk.f, &regs, blk.f.allocator, &blk.f.ctx, build.finder_hook)
	if werr == nil {
		if e := find_piece_copy(p, s, &blk.f, text); e != nil {
			werr = e
		}
	}
	if werr == nil && p.more {
		p.keep = min(p.keep, build.finder_holds(&blk.f))
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
	answer = build.finder_answer(&blk.f)
	answer.tolerated = tolerated
	return answer, nil
}

// Copies the bytes of the finder's answer out of the window `text` once the answer is complete and not yet copied.
@(private)
find_piece_copy :: proc(p: ^tape.Pieces, s: ^hook.Piece_State, f: ^build.Finder, text: []u8) -> runtime.Allocator_Error {
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
	h:    build.Scanner,
	room: build.Scan_Room,
}

@(private)
scan_piece_free :: proc(held: rawptr, allocator: runtime.Allocator) {
	blk := (^Scan_Piece)(held)
	_, _ = build.scanner_end(&blk.h, {}, 0, runtime.Allocator_Error.Out_Of_Memory)
	free(blk, allocator)
}

// Returns the document of a scan over a text in pieces. Its keys, scalars and facts are copied out of each window as it
// ends, so the read keeps only what the walk needs, and the document is `.Held`.
@(private)
scan_pieces :: proc(src: []u8, demand: ^tape.Demand, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (doc: tape.Document, err: tape.Error) {
	p := opts.pieces
	s := hook.piece_state(p) or_return
	blk := (^Scan_Piece)(s.hook)
	if blk == nil {
		if s.started {
			return {}, nil
		}
		blk = new(Scan_Piece, p.allocator) or_return
		allocator := hook.piece_blocks(p, opts.budget.memory, caller)
		if e := build.scanner_start(&blk.h, src, &FORMATS[S], demand, read, nil, SCAN_NODES, node_most(max(u64), opts), nil, &blk.room, allocator); e != nil {
			free(blk, p.allocator)
			return {}, hook.memory_budget_error(&s.blocks, e)
		}
		s.hook, s.hook_free, s.regs = blk, scan_piece_free, build.builder_regs(&blk.h.b)
	}
	text := hook.piece_src(src, p.from)
	blk.h.b.doc.src = text
	regs := s.regs
	root_close, werr, tolerated := piece_read(src, S, opts, &blk.h, &regs, blk.h.b.doc.allocator, &blk.h.b.ctx, build.scanner_hook)
	if werr == nil {
		if e := build.scanner_hold(&blk.h, regs, text); e != nil {
			werr = e
		}
	}
	if werr == nil && p.more {
		// A scan of facts copies a comment's bytes out of the window in which the walk gives it. That window may be
		// later than the one holding its bytes, when the run's end was not in the same window.
		if blk.h.facts {
			p.keep = min(p.keep, piece_run_facts(s))
		}
		if !p.so_far {
			return {}, nil
		}
		doc, err = build.scanner_so_far(&blk.h, regs, p.at, caller)
		err = read_end(&doc, err, &s.blocks, tolerated, caller)
	return
	}
	defer {
		free(blk, p.allocator)
		s.hook = nil
	}
	doc, err = build.scanner_end(&blk.h, regs, root_close, werr)
	err = read_end(&doc, err, &s.blocks, tolerated, caller)
	return
}
