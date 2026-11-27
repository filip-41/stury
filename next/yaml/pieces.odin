package yaml

import "base:runtime"
import "core:bytes"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Reads YAML texts arriving in piece windows (`Options.pieces`).
//
// In multi-document YAML streams (separated by column-0 `...` / `---` document boundaries outside quotes and block
// scalars), completed documents are validated/processed and released immediately as windows arrive (`p.keep` advances
// past each sealed document), keeping only the currently open document buffered so memory stays bounded while results,
// faults, budgets, and partial trees agree identically with whole-text reads.

@(private)
Piece :: struct {
	using state: hook.Piece_State,
	pos:         u64,
	scanned:     u64,
	doc_done:    bool,
	doc_close:   u64,
}

@(private)
piece_free :: proc(p: ^tape.Pieces) {
	hook.piece_release(p)
}

@(private = "file")
last_line_start_in :: proc "contextless" (text: []u8, lo, to: u64) -> u64 #no_bounds_check {
	if to <= lo { return lo }
	if nl := bytes.last_index_byte(text[lo:to], '\n'); nl >= 0 { return lo + u64(nl) + 1 }
	return lo
}

// Fast O(new bytes) scan checking whether `text[max(doc_lo, scan_from):to]` contains a candidate column-0 `...` line
// (terminated by `\n`) or a `---` + whitespace/break marker strictly past `doc_lo`.
@(private = "file")
has_doc_boundary :: proc "contextless" (text: []u8, doc_lo, scan_from, to: u64) -> bool #no_bounds_check {
	if to <= doc_lo + 3 { return false }
	ls := last_line_start_in(text, doc_lo, min(scan_from, to))
	for ls < to {
		nl := bytes.index_byte(text[ls:to], '\n')
		has_nl := nl >= 0
		if ls + 3 < to {
			b := text[ls]
			if (b == '.' || b == '-') && text[ls + 1] == b && text[ls + 2] == b {
				c := text[ls + 3]
				if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
					if b == '.' && has_nl { return true }
					if b == '-' && ls > doc_lo { return true }
				}
			}
		}
		if !has_nl { break }
		ls += u64(nl) + 1
	}
	return false
}

// Advances `pos` past complete, valid ASCII blank, `# comment`, or `...` lines in a single-document tail so trailing
// comments/markers across many windows stay O(1) memory while preserving exact UTF-8/control-char fault parity.
@(private = "file")
skip_tail_safe :: proc "contextless" (text: []u8, pos, to: u64) -> u64 #no_bounds_check {
	cur := pos
	for cur < to {
		nl := bytes.index_byte(text[cur:to], '\n')
		if nl < 0 { break }
		line_end := cur + u64(nl)
		end := line_end
		if end > cur && text[end - 1] == '\r' { end -= 1 }
		// Reject lone CR or non-ASCII/control bytes so the real parser validates them identically.
		ok := true
		for p := cur; p < end; p += 1 {
			c := text[p]
			if !((c >= 0x20 && c < 0x7f) || c == '\t') { ok = false; break }
		}
		if !ok { break }
		i := cur
		for i < end && (text[i] == ' ' || text[i] == '\t') { i += 1 }
		if i == end || text[i] == '#' {
			cur = line_end + 1
			continue
		}
		if i == cur && cur + 3 <= end && text[cur] == '.' && text[cur + 1] == '.' && text[cur + 2] == '.' &&
			(cur + 3 == end || text[cur + 3] == ' ' || text[cur + 3] == '\t') {
			j := cur + 3
			for j < end && (text[j] == ' ' || text[j] == '\t') { j += 1 }
			if j == end || text[j] == '#' {
				cur = line_end + 1
				continue
			}
		}
		break
	}
	return cur
}

@(private)
piece_read :: proc(
	src: []u8,
	$S: Spec,
	opts: Options,
	h: ^$H,
	regs: ^hook.Regs,
	allocator: runtime.Allocator,
	ctx: ^runtime.Context,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
	allow_empty := false,
	check_tail := true,
	allow_complex := false,
) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	context = ctx^
	p := opts.pieces
	s, text, to, e := hook.piece_begin(p, Piece, piece_free, src)
	if e != nil {
		return 0, e, false
	}

	if !s.started {
		if !p.last && to < 3 {
			p.more, p.at, p.keep, p.open = true, to, 0, nil
			return 0, nil, false
		}
		s.started = true
		s.steps = build.read_steps(opts)
		s.pos = 3 if (to >= 3 && text[0] == 0xef && text[1] == 0xbb && text[2] == 0xbf) else 0
		s.scanned = s.pos
	}

	// Multi-document stream validation (`validate_pieces`): stream and release each sealed document incrementally.
	when H == hook.No_Hooks {
		if allow_empty && !check_tail {
			if !p.last {
				for has_doc_boundary(text, s.pos, s.scanned, to) {
					sealed, _, end_pos, next_steps := probe_sealed_doc(text, s.pos, S, true, opts, s.steps, true, allocator, ctx)
					if !sealed || end_pos <= s.pos {
						s.scanned = last_line_start_in(text, s.pos, to)
						break
					}
					s.steps = next_steps
					s.pos = end_pos
					s.scanned = end_pos
				}
				if s.scanned < last_line_start_in(text, s.pos, to) {
					s.scanned = last_line_start_in(text, s.pos, to)
				}
				p.more, p.at, p.keep, p.open = true, to, s.pos, nil
				return 0, nil, false
			}
			p.more, p.at, p.keep, p.open = false, to, to, nil
			return validate_stream_from(text, s.pos, s.steps, S, true, opts, h, regs, allocator, ctx)
		}
	}

	// Single-document streaming (`build`, `find`, `scan`, `walk`, `walk_next`):
	// once document 1 is sealed at an explicit `...` / `---` boundary, walk it immediately and advance `p.keep` past it.
	if !s.doc_done && !p.last {
		if has_doc_boundary(text, s.pos, s.scanned, to) {
			sealed, found, _, _ := probe_sealed_doc(text, s.pos, S, true, opts, s.steps, allow_complex, allocator, ctx)
			if sealed && found {
				end_pos: u64
				stopped: bool
				rc, werr, tol := walk_text(text, S, true, opts, h, regs, allocator, ctx, on, s.pos, allow_empty, false, allow_complex, &end_pos, nil, &stopped)
				s.regs = regs^
				if werr != nil || stopped || !check_tail {
					p.more, p.at, p.keep, p.open = false, to, to, nil
					return rc, werr, tol
				}
				s.doc_done = true
				s.doc_close = rc
				s.pos = skip_tail_safe(text, end_pos, to)
				s.scanned = s.pos
				p.more, p.at, p.keep, p.open = true, to, s.pos, nil
				return rc, nil, tol
			}
			s.scanned = last_line_start_in(text, s.pos, to)
		} else {
			s.scanned = last_line_start_in(text, s.pos, to)
		}
		p.more, p.at, p.keep, p.open = true, to, s.pos, nil
		return 0, nil, false
	}

	if s.doc_done {
		if !p.last {
			s.pos = skip_tail_safe(text, s.pos, to)
			p.more, p.at, p.keep, p.open = true, to, s.pos, nil
			return s.doc_close, nil, false
		}
		p.more, p.at, p.keep, p.open = false, to, to, nil
		if check_tail {
			if terr := check_tail_from(text, s.pos, S, opts, allow_complex, allocator, ctx); terr != nil {
				return s.doc_close, terr, false
			}
		}
		return s.doc_close, nil, false
	}

	p.more, p.at, p.keep, p.open = false, to, to, nil
	rc, werr, tol := walk_text(text, S, true, opts, h, regs, allocator, ctx, on, s.pos, allow_empty, check_tail, allow_complex)
	s.regs = regs^
	return rc, werr, tol
}

@(private)
validate_pieces :: proc(src: []u8, $S: Spec, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	walk :: proc(src: []u8, opts: Options, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return piece_read(src, S, opts, h, regs, a, ctx, hook.no_hook, allow_empty = true, check_tail = false, allow_complex = true)
	}
	return build.read_validate_pieces(src, &FORMATS[S], opts, allocator, Piece, walk)
}

@(private)
build_pieces :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Builder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return piece_read(src, S, opts, h, regs, a, ctx, build.builder_hook_facts)
	}
	return build.read_build_pieces(src, &FORMATS[S], &RULES, opts, caller, Piece, walk, build.builder_finish_dups, build.builder_finish_dups)
}

@(private)
find_pieces :: proc(src: []u8, path: []tape.Step, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return piece_read(src, S, opts, h, regs, a, ctx, build.finder_key_skip_hook)
	}
	return build.read_find_pieces(src, path, &FORMATS[S], read, opts, caller, respell_number, Piece, walk)
}

@(private)
scan_pieces :: proc(src: []u8, demand: ^tape.Demand, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		h.scattered = true
		return piece_read(src, S, opts, h, regs, a, ctx, build.scanner_key_skip_hook)
	}
	return build.read_scan_pieces(src, demand, &FORMATS[S], read, opts, caller, Piece, walk)
}
