package html

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Incremental streaming reads for HTML5 texts arriving in windows (`Options.pieces != nil`).
// Incoming windows feed chunks incrementally into the HTML5 tokenizer and tree builder at safe UTF-8,
// entity, and markup boundaries. `validate` detaches open-stack metadata and advances `p.keep` past
// consumed raw bytes so raw window retention stays bounded while preserving exact HTML5 parity.

@(private)
Piece :: struct {
	using state:     hook.Piece_State,
	tree:            Html_Tree,
	stream:          Stream_Pause,
	tree_spec:       Tree_Spec,
	error_mode:      Error_Mode,
	tree_open:       bool,
	tree_done:       bool,
	release_src:     bool,
	deferred_depth:  bool,
	deferred_err_at: u64,
	seen_to:         u64,
}

@(private)
piece_free :: proc(p: ^tape.Pieces) {
	s := (^Piece)(p.state)
	if s.tree_open {
		tree_destroy(&s.tree)
		s.tree_open = false
	}
	hook.piece_release(p)
}

@(private = "file")
piece_budget_err :: #force_inline proc "contextless" (s: ^Piece, err: tape.Error) -> tape.Error {
	return hook.memory_budget_error(&s.lists, hook.memory_budget_error(&s.blocks, err))
}

@(private = "file")
piece_fail :: proc(p: ^tape.Pieces, s: ^Piece, err: tape.Error) -> (bool, tape.Error) {
	if s.tree_open {
		tree_destroy(&s.tree)
		s.tree_open = false
	}
	p.more, p.open = false, nil
	return false, piece_budget_err(s, err)
}

@(private = "file")
piece_feed_tree :: proc(
	p: ^tape.Pieces,
	s: ^Piece,
	text: []u8,
	to: u64,
	tree_spec: Tree_Spec,
	opts: Options,
	fopts: Fragment_Options,
	error_mode: Error_Mode,
	release_src: bool,
	caller: runtime.Allocator,
) -> (
	ready: bool,
	err: tape.Error,
) {
	_ = hook.piece_blocks(p, opts.budget.memory, caller)
	lists := hook.piece_lists(p)

	if !s.tree_open && !s.tree_done {
		from := u64(0)
		enc := Encoding.Utf_8
		enc_at := u64(0)
		found := false
		if tree_spec == .Document {
			if !p.last && to < PRESCAN_BYTES {
				p.more, p.at, p.keep, p.open = true, to, 0, nil
				return false, nil
			}
			enc, enc_at, from, found = sniffed(text[:min(to, PRESCAN_BYTES)])
			if found && (enc == .Replacement || enc == .Utf_16be || enc == .Utf_16le) {
				return piece_fail(p, s, tape.Fault{at = enc_at, rules = &RULES, kind = .Bad_Char, detail = u8(Detail.Encoding)})
			}
		}
		start, ierr := tree_init(&s.tree, text, tree_spec, opts, fopts, error_mode, lists)
		if ierr != nil {
			return piece_fail(p, s, ierr)
		}
		s.tree_open = true
		s.tree_spec = tree_spec
		s.error_mode = error_mode
		s.release_src = release_src
		if tree_spec == .Document {
			s.tree.encoding = enc if found else .Utf_8
			s.tree.tentative = !found
			s.tree.enc_at = enc_at
		}
		s.stream = {
			pos        = from,
			judged     = from,
			content    = start,
			in_foreign = s.tree.in_foreign,
		}
		s.seen_to = from
	}

	s.tree.src = text
	s.tree.src_from = p.from

	scan_from := max(s.seen_to, p.from)
	if s.deferred_depth {
		if scan_from < to {
			scan_encoding_bytes(text[scan_from:to], &s.tree.seen_high, &s.tree.seen_esc)
			s.seen_to = to
		}
		if !encoding_ok_seen(s.tree.encoding, s.tree.seen_high, s.tree.seen_esc) {
			return piece_fail(p, s, tape.Fault{at = s.tree.enc_at, rules = &RULES, kind = .Bad_Char, detail = u8(Detail.Encoding)})
		}
		if !p.last {
			p.more, p.at, p.keep, p.open = true, to, to if s.release_src else 0, nil
			return false, nil
		}
		return piece_fail(p, s, tape.Exceeded{at = s.deferred_err_at, kind = .Depth})
	}

	if !s.tree.tentative && s.tree.encoding != .Utf_8 {
		if scan_from < to && !reads_as_utf8(text[scan_from:to], s.tree.encoding) {
			return piece_fail(p, s, tape.Fault{at = s.tree.enc_at, rules = &RULES, kind = .Bad_Char, detail = u8(Detail.Encoding)})
		}
	}

	tok_err := tokenize_chunk(text, &s.tree, &s.stream, to, p.last, lists)
	if s.tree.misread {
		return piece_fail(p, s, tape.Fault{at = s.tree.at, rules = &RULES, kind = .Bad_Char, detail = u8(Detail.Encoding)})
	}
	if s.tree.oom {
		return piece_fail(p, s, runtime.Allocator_Error.Out_Of_Memory)
	}
	if tok_err != nil {
		return piece_fail(p, s, tok_err)
	}
	if s.tree.too_deep {
		if !p.last && !s.tree.tentative && s.tree.encoding != .Utf_8 {
			s.deferred_depth = true
			s.deferred_err_at = s.tree.at
			if scan_from < to {
				scan_encoding_bytes(text[scan_from:to], &s.tree.seen_high, &s.tree.seen_esc)
				s.seen_to = to
			}
			p.more, p.at, p.keep, p.open = true, to, to if s.release_src else 0, nil
			return false, nil
		}
		return piece_fail(p, s, tape.Exceeded{at = s.tree.at, kind = .Depth})
	}

	if !p.last {
		if s.release_src {
			keep := s.stream.pos
			if len(s.tree.pending) > 0 {
				keep = min(keep, s.tree.pending[0].lo)
			}
			tree_detach_window(&s.tree)
			if s.tree.oom {
				return piece_fail(p, s, runtime.Allocator_Error.Out_Of_Memory)
			}
			if scan_from < keep {
				scan_encoding_bytes(text[scan_from:keep], &s.tree.seen_high, &s.tree.seen_esc)
				s.seen_to = max(s.seen_to, keep)
			}
			p.more, p.at, p.keep, p.open = true, to, keep, nil
		} else {
			if scan_from < s.stream.pos {
				scan_encoding_bytes(text[scan_from:s.stream.pos], &s.tree.seen_high, &s.tree.seen_esc)
				s.seen_to = max(s.seen_to, s.stream.pos)
			}
			p.more, p.at, p.keep, p.open = true, to, 0, nil
		}
		return false, nil
	}

	ferr := tree_finish(&s.tree, to, tok_err)
	if ferr != nil {
		return piece_fail(p, s, ferr)
	}
	s.tree_done = true
	p.more, p.open = false, nil
	return true, nil
}

@(private)
piece_read :: proc(
	src: []u8, $S: Spec, opts: Options, fopts: Fragment_Options, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), keep_state: ^Kept = nil,
) -> (u64, tape.Error, bool) {
	hook.check(H)
	p := opts.pieces
	s, text, to, e := hook.piece_begin(p, Piece, piece_free, src)
	if e != nil { return 0, e, false }
	tree_spec := Tree_Spec.Fragment if S == .Fragment else .Document
	ready, ferr := piece_feed_tree(p, s, text, to, tree_spec, opts, fopts, .None, false, allocator)
	if ferr != nil { return 0, ferr, false }
	if !ready { return 0, nil, false }
	defer {
		if s.tree_open {
			tree_destroy(&s.tree)
			s.tree_open = false
		}
	}
	context = ctx^
	s.tree.src = text
	r := emit_tree_walk(&s.tree, tree_spec, opts, h, regs, build.read_steps(opts), keep_state, true, on)
	at, walk_err, _ := hook.walk_error(hook.Walk_Result(r), &RULES)
	return at, piece_budget_err(s, walk_err), false
}

@(private)
validate_pieces :: proc(src: []u8, $S: Spec, opts: Options, fopts: Fragment_Options, allocator: runtime.Allocator) -> tape.Error {
	if e := tape.options_refused(&FORMATS[S], opts); e != nil { return e }
	if !build.validate_dups(&FORMATS[S], opts) { return tape.Bad_Option{"dups"} }
	p := opts.pieces
	if p == nil { return tape.Bad_Option{"pieces"} }
	s, text, to, e := hook.piece_begin(p, Piece, piece_free, src)
	if e != nil { return e }
	tree_spec := Tree_Spec.Fragment if S == .Fragment else .Document
	ready, ferr := piece_feed_tree(p, s, text, to, tree_spec, opts, fopts, .First, true, allocator)
	if ferr != nil { return ferr }
	if !ready { return nil }
	defer {
		if s.tree_open {
			tree_destroy(&s.tree)
			s.tree_open = false
		}
	}
	if opts.budget.steps != 0 {
		if at, exceeded := check_tree_steps(&s.tree, tree_spec, build.read_steps(opts)); exceeded {
			return tape.Exceeded{at = at, kind = .Steps}
		}
	}
	return parse_error_fault(s.tree.errors[0]) if len(s.tree.errors) > 0 else nil
}

@(private)
build_pieces :: proc(src: []u8, $S: Spec, opts: Options, fopts: Fragment_Options, caller: runtime.Allocator) -> (doc: tape.Document, err: tape.Error) {
	if e := tape.options_refused(&FORMATS[S], opts); e != nil { return {}, e }
	p := opts.pieces
	if p == nil { return {}, tape.Bad_Option{"pieces"} }
	s, text, to, e := hook.piece_begin(p, Piece, piece_free, src)
	if e != nil { return {}, e }
	tree_spec := Tree_Spec.Fragment if S == .Fragment else .Document
	ready, ferr := piece_feed_tree(p, s, text, to, tree_spec, opts, fopts, .None, false, caller)
	if ferr != nil { return {}, ferr }
	if !ready { return {}, nil }
	defer {
		if s.tree_open {
			tree_destroy(&s.tree)
			s.tree_open = false
		}
	}
	alloc := hook.piece_blocks(p, opts.budget.memory, caller)
	scratch := hook.piece_lists(p)
	d, berr := build_from_tree(&s.tree, text, S, opts, alloc, scratch, &s.blocks, caller)
	return d, piece_budget_err(s, berr)
}

@(private)
find_pieces :: proc(src: []u8, path: []tape.Step, $S: Spec, read: tape.Read_Options, opts: Options, fopts: Fragment_Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return piece_read(src, S, opts, {}, h, regs, a, ctx, build.finder_key_skip_hook)
	}
	if S == .Fragment && fopts != {} {
		steps, refused := html_find_path(&FORMATS[S], opts, path)
		if refused != nil { return {}, refused }
		p := opts.pieces
		s, text, to, e := hook.piece_begin(p, Piece, piece_free, src)
		if e != nil { return {}, e }
		ready, ferr := piece_feed_tree(p, s, text, to, .Fragment, opts, fopts, .None, false, caller)
		if ferr != nil { return {}, ferr }
		if !ready { return {}, nil }
		defer {
			if s.tree_open {
				tree_destroy(&s.tree)
				s.tree_open = false
			}
		}
		alloc := hook.piece_blocks(p, opts.budget.memory, caller)
		a, find_err := find_from_tree(&s.tree, text, steps, .Fragment, build.read_lax(opts), read, opts, alloc)
		if find_err == nil && a.outcome == .Found && a.hi > a.lo {
			lists := hook.piece_lists(p)
			if buf, berr := make([]u8, a.hi - a.lo, lists); berr == nil {
				copy(buf, text[a.lo:a.hi]); delete(p.text, lists); p.text = buf
			} else { find_err = berr }
		}
		return a, piece_budget_err(s, find_err)
	}
	return build.read_find_pieces(src, path, &FORMATS[S], read, opts, caller, respell, Piece, walk)
}

@(private)
scan_pieces :: proc(src: []u8, demand: ^tape.Demand, $S: Spec, read: tape.Read_Options, opts: Options, fopts: Fragment_Options, caller: runtime.Allocator) -> (doc: tape.Document, err: tape.Error) {
	p := opts.pieces
	if e := html_scan_refused(&FORMATS[S], opts, demand); e != nil { return {}, e }
	s, text, to, e := hook.piece_begin(p, Piece, piece_free, src)
	if e != nil { return {}, e }
	tree_spec := Tree_Spec.Fragment if S == .Fragment else .Document
	ready, ferr := piece_feed_tree(p, s, text, to, tree_spec, opts, fopts, .None, false, caller)
	if ferr != nil { return {}, ferr }
	if !ready { return {}, nil }
	defer {
		if s.tree_open {
			tree_destroy(&s.tree)
			s.tree_open = false
		}
	}
	alloc := hook.piece_blocks(p, opts.budget.memory, caller)
	scratch := hook.piece_lists(p)
	k: Kept
	k.ends.allocator, k.texts.allocator, k.pieces.allocator, k.open.allocator = scratch, scratch, scratch, scratch
	defer kept_destroy(&k)
	d, serr := scan_from_tree(&s.tree, text, demand, S, read, opts, alloc, scratch, &s.blocks, caller, &k)
	if s.tree_open {
		tree_destroy(&s.tree)
		s.tree_open = false
	}
	if serr == nil && len(text) > 0 && len(d.nodes) > 0 {
		copied, cerr := runtime.mem_alloc_non_zeroed(len(text), 1, alloc)
		if cerr != nil { tape.destroy(&d); return {}, piece_budget_err(s, cerr) }
		intrinsics.mem_copy_non_overlapping(raw_data(copied), raw_data(text), len(text))
		held := [1]tape.Held_Span{{0, 0}}
		old_ext := d.ext
		new_ext, eerr := tape.ext_make(held[:], old_ext.format if old_ext != nil else nil, alloc, old_ext.origin if old_ext != nil else {})
		if eerr != nil { delete(copied, alloc); tape.destroy(&d); return {}, piece_budget_err(s, eerr) }
		if old_ext != nil { free(old_ext, d.allocator) }
		d.ext, d.src = new_ext, copied
		d.flags += {.Held, .Owns_Src}
	}
	if serr == nil && !seal_state(&d, &k, alloc) { tape.destroy(&d); serr = runtime.Allocator_Error.Out_Of_Memory }
	if serr == nil { d.allocator = caller }
	return d, piece_budget_err(s, serr)
}
