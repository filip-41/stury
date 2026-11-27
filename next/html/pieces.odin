package html

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Reading an HTML5 text in pieces (`Options.pieces != nil`). Windows before `last` keep from byte 0 (`keep = 0`),
// and `p.last` runs the full tree walk.

@(private)
Piece :: struct { using state: hook.Piece_State }

@(private)
piece_free :: proc(p: ^tape.Pieces) { hook.piece_release(p) }

@(private)
piece_read :: proc(
	src: []u8, $S: Spec, opts: Options, fopts: Fragment_Options, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), keep_state: ^Kept = nil,
) -> (u64, tape.Error, bool) {
	hook.check(H)
	p := opts.pieces
	_, text, to, e := hook.piece_begin(p, Piece, piece_free, src)
	if e != nil { return 0, e, false }
	if !p.last { p.more, p.at, p.keep, p.open = true, to, 0, nil; return 0, nil, false }
	p.more, p.open = false, nil
	return walk_tree_text(text, .Fragment if S == .Fragment else .Document, opts, fopts, 0, true, h, regs, allocator, ctx, on, keep_state)
}

@(private)
validate_pieces :: proc(src: []u8, $S: Spec, opts: Options, fopts: Fragment_Options, allocator: runtime.Allocator) -> tape.Error {
	if e := tape.options_refused(&FORMATS[S], opts); e != nil { return e }
	if !build.validate_dups(&FORMATS[S], opts) { return tape.Bad_Option{"dups"} }
	p := opts.pieces
	if p == nil { return tape.Bad_Option{"pieces"} }
	_, text, to, e := hook.piece_begin(p, Piece, piece_free, src)
	if e != nil { return e }
	if !p.last { p.more, p.at, p.keep, p.open = true, to, 0, nil; return nil }
	s := (^Piece)(p.state)
	a := hook.piece_blocks(p, opts.budget.memory, allocator)
	p.more, p.open = false, nil
	o := opts; o.pieces = nil
	return hook.memory_budget_error(&s.blocks, validate_as(text, S, build.read_lax(o), o, fopts, a))
}

@(private)
build_pieces :: proc(src: []u8, $S: Spec, opts: Options, fopts: Fragment_Options, caller: runtime.Allocator) -> (doc: tape.Document, err: tape.Error) {
	p := opts.pieces
	if p == nil { return {}, tape.Bad_Option{"pieces"} }
	if p.last {
		text := tape.piece_src(src, p.from)
		_ = hook.piece_state(p, Piece) or_return
		s := (^Piece)(p.state)
		m: hook.Read_Budget
		d, berr := build_as_inner(text, S, opts, fopts, hook.piece_blocks(p, opts.budget.memory, caller), &m)
		p.more, p.open = false, nil
		return d, hook.memory_budget_error(&s.blocks, berr)
	}
	if e := tape.options_refused(&FORMATS[S], opts); e != nil { return {}, e }
	_ = hook.piece_state(p, Piece) or_return
	_, _, to, e := hook.piece_begin(p, Piece, piece_free, src)
	if e != nil { return {}, e }
	p.more, p.at, p.keep, p.open = true, to, 0, nil
	return {}, nil
}

@(private)
find_pieces :: proc(src: []u8, path: []tape.Step, $S: Spec, read: tape.Read_Options, opts: Options, fopts: Fragment_Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return piece_read(src, S, opts, {}, h, regs, a, ctx, build.finder_key_skip_hook)
	}
	if S == .Fragment && fopts != {} {
		if _, refused := html_find_path(&FORMATS[S], opts, path); refused != nil { return {}, refused }
		p := opts.pieces
		_, text, to, e := hook.piece_begin(p, Piece, piece_free, src)
		if e != nil { return {}, e }
		s := (^Piece)(p.state)
		if !p.last { p.more, p.at, p.keep, p.open = true, to, 0, nil; return {}, nil }
		p.more, p.open = false, nil
		o := opts; o.pieces = nil
		a, ferr := find_fragment(text, path, fopts, read, o, hook.piece_blocks(p, opts.budget.memory, caller))
		if ferr == nil && a.outcome == .Found && a.hi > a.lo {
			lists := hook.piece_lists(p)
			if buf, berr := make([]u8, a.hi - a.lo, lists); berr == nil {
				copy(buf, text[a.lo:a.hi]); delete(p.text, lists); p.text = buf
			} else { ferr = berr }
		}
		return a, hook.memory_budget_error(&s.blocks, ferr)
	}
	return build.read_find_pieces(src, path, &FORMATS[S], read, opts, caller, respell, Piece, walk)
}

@(private)
scan_pieces :: proc(src: []u8, demand: ^tape.Demand, $S: Spec, read: tape.Read_Options, opts: Options, fopts: Fragment_Options, caller: runtime.Allocator) -> (doc: tape.Document, err: tape.Error) {
	p := opts.pieces
	if e := html_scan_refused(&FORMATS[S], opts, demand); e != nil { return {}, e }
	s := hook.piece_state(p, Piece) or_return
	if !p.last {
		_, _, to, e := hook.piece_begin(p, Piece, piece_free, src)
		if e != nil { return {}, e }
		p.more, p.at, p.keep, p.open = true, to, 0, nil
		return {}, nil
	}
	text := tape.piece_src(src, p.from)
	p.more, p.open = false, nil
	alloc := hook.piece_blocks(p, opts.budget.memory, caller)
	k: Kept
	k.ends.allocator, k.texts.allocator, k.pieces.allocator, k.open.allocator = alloc, alloc, alloc, alloc
	defer kept_destroy(&k)
	o := opts; o.pieces = nil
	d, serr := scan_held_once(text, demand, S, read, o, fopts, alloc, &k)
	if serr == nil && !seal_state(&d, &k, d.allocator) { tape.destroy(&d); serr = runtime.Allocator_Error.Out_Of_Memory }
	return d, hook.memory_budget_error(&s.blocks, serr)
}

@(private, cold)
scan_held_once :: proc(src: []u8, demand: ^tape.Demand, spec: Spec, read: tape.Read_Options, opts: Options, fopts: Fragment_Options, caller: runtime.Allocator, k: ^Kept) -> (tape.Document, tape.Error) {
	doc, err := build_scan_once(src, demand, spec, read, opts, fopts, caller, k)
	if err != nil { return {}, err }
	if len(src) > 0 && len(doc.nodes) > 0 {
		copied, cerr := runtime.mem_alloc_non_zeroed(len(src), 1, caller)
		if cerr != nil { tape.destroy(&doc); return {}, cerr }
		intrinsics.mem_copy_non_overlapping(raw_data(copied), raw_data(src), len(src))
		held := [1]tape.Held_Span{{0, 0}}
		old_ext := doc.ext
		new_ext, eerr := tape.ext_make(held[:], old_ext.format if old_ext != nil else nil, caller, old_ext.origin if old_ext != nil else {})
		if eerr != nil { delete(copied, caller); tape.destroy(&doc); return {}, eerr }
		if old_ext != nil { free(old_ext, doc.allocator) }
		doc.ext, doc.src = new_ext, copied
		doc.flags += {.Held, .Owns_Src}
	}
	return doc, nil
}
