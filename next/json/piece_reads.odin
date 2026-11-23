package json

import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// JSON's walk of a window of a text in pieces, which the piece reads of `build` run.

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
	r, took := walk_value(text, start, S, true, opts.tolerate, build.read_depth(opts), opts.budget.steps, h, regs, allocator, ctx, &pw, on)
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
	walk :: proc(src: []u8, opts: Options, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		root_close, err, tolerated := piece_read(src, S, opts, h, regs, a, ctx, hook.no_hook)
		// No later read needs the bytes of a token the window cut short that lie before the point where its read
		// continues.
		p := opts.pieces
		if s := (^hook.Piece_State)(p.state); p.more && s.cut.on != 0 {
			p.keep = max(p.keep, piece_cut_keep(s.cut))
		}
		return root_close, err, tolerated
	}
	return build.read_validate_pieces(src, opts, allocator, walk)
}

@(private)
build_pieces :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Builder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		on :: build.builder_hook_facts when S != .Json else build.builder_hook
		return piece_read(src, S, opts, h, regs, a, ctx, on)
	}
	return build.read_build_pieces(src, &FORMATS[S], &RULES, opts, caller, walk)
}

@(private)
find_pieces :: proc(src: []u8, path: []tape.Step, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return piece_read(src, S, opts, h, regs, a, ctx, build.finder_hook)
	}
	return build.read_find_pieces(src, path, &FORMATS[S], read, opts, caller, respell, walk)
}

@(private)
scan_pieces :: proc(src: []u8, demand: ^tape.Demand, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		root_close, err, tolerated := piece_read(src, S, opts, h, regs, a, ctx, build.scanner_hook)
		// A scan of facts copies a comment's bytes out of the window in which the walk gives it. That window may be
		// later than the one holding its bytes, when the run's end was not in the same window.
		if p := opts.pieces; err == nil && p.more && h.facts {
			p.keep = min(p.keep, piece_run_facts((^hook.Piece_State)(p.state)))
		}
		return root_close, err, tolerated
	}
	return build.read_scan_pieces(src, demand, &FORMATS[S], read, opts, caller, walk)
}
