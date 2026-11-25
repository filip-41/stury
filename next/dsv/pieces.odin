package dsv

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Walks a text in pieces. A window's walk runs the pass over the window's whole blocks, which are the blocks a walk of
// the whole text reads, and stops before the first block whose bytes, and the bytes past it that a UTF-8 sequence
// begun in it may run into, the window does not hold. The next window's walk reads on from that block with the pass's
// state as the last block left it, so every mask, token and fault is the whole walk's. What crosses a window's end is
// the state the pass carries from block to block: an open quoted cell, a closing quote that a quote past it doubles, a
// CR whose LF is to come, a TSV backslash, an open comment line, an open UTF-8 sequence, and the open record with its
// cells so far. The header's keys are kept in the read's own list, and once the header has ended its bytes are copied
// out, so a window past it need not hold them. A hook that passes over the rest of the text has it judged by the same
// pass with no tokens.

// The bytes from a block's start that a window must hold before its walk reads the block: the 64 bytes of the block
// and the 3 more that a UTF-8 sequence begun in its last byte may run into.
@(private)
PIECE_AHEAD :: 64 + 3

// What a delimited walk keeps from one piece to the next, besides the pass, which `Piece_State.memo` holds.
@(private)
Piece :: struct {
	using state: hook.Piece_State,
	pos:         u64, // the first byte of the block the next window's walk reads
	records:     u64, // the records opened so far
	more:        bool, // bytes may follow the window being walked
	// With `Piece_State.rested`, the hook passed over the rest of the text, which the walk judges with no tokens, and
	// `skip_end` says it skipped the text, whose `End` is given at the text's end.
	skip_end:    bool,
	keys:        [dynamic]tape.Token, // the header's keys read so far
	headed:      bool, // the header has ended
	keyed:       bool, // the header's keys are all in `keys`, so a validate counts the cells of the records past it
	widest:      int, // the most cells a record had
	head:        [dynamic]u8, // once the header has ended, the bytes of its keys from `head_lo`
	head_lo:     u64,
	// While the first walk waits, where `piece_starts` stopped: in which part of the opening, the header's first byte,
	// and what it has read of the header's line.
	opening:     Opening,
	frame:       Frame_At,
	header_lo:   int,
	header:      Record_Scan,
}

// The part of a text's opening `piece_starts` reads next.
@(private)
Opening :: enum u8 {
	Text, // the byte order mark
	Header, // the empty and comment lines before the header
	Line, // the header's line
	Next, // the empty and comment lines past the header
}

// The state of a read of a text in pieces, made at its first window, whose lists the read's own allocator holds.
@(private)
piece_open_state :: proc(p: ^tape.Pieces) -> (s: ^Piece, lists: runtime.Allocator, err: runtime.Allocator_Error) {
	s = hook.piece_state(p, Piece) or_return
	p.release = piece_free
	lists = hook.piece_lists(p)
	s.keys.allocator, s.head.allocator, s.opened.allocator, s.names.allocator, s.steps_buf.allocator = lists, lists, lists, lists, lists
	return
}

@(private)
piece_free :: proc(p: ^tape.Pieces) {
	s := (^Piece)(p.state)
	delete(s.keys)
	delete(s.head)
	hook.piece_release(p)
}

// Walks the window `src` of the text in pieces `opts.pieces` for hook `h` from its registers `regs`, and updates
// `opts.pieces` (`more`, `at`, `keep`, `open`) for the next window. `head`, when given, is given the header's keys and
// the most cells a record had. A window must start at or before `keep` and end at or after `at`, and the first window
// must start the text. The first walk waits for a window that holds the bytes a text's opening needs: past a byte order
// mark, and with comment lines before a header, the start of the record past the header, which says whether they are
// the text's or its foot.
@(private)
piece_read :: proc(src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), head: ^Head) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	W :: Pass(S, H, true, C)
	context = ctx^
	p := opts.pieces
	s, lists, serr := piece_open_state(p)
	if serr != nil {
		return 0, serr, false
	}
	to, gap := tape.piece_window(p, src)
	if gap != nil {
		return 0, gap, false
	}
	po := options_resolved(S, opts)
	text := hook.piece_src(src, p.from)
	more := !p.last
	// A build judges the header's repeats when it has built it. Another read judges them when a window first holds it.
	refuse := opts.dups == .Refuse && H != build.Rows_Builder
	if !s.started {
		if more && !piece_starts(s, text, to, S, po, refuse) {
			p.more, p.at, p.keep, p.open = true, to, 0, nil
			return 0, nil, false
		}
		if refuse {
			if e := header_fault(text, S, po, lists); e != nil {
				p.more, p.open = false, nil
				return 0, e, false
			}
		}
		memo, e := make([]u8, size_of(W), lists)
		if e = build.took(e, raw_data(memo), size_of(W)); e != nil {
			return 0, e, false
		}
		s.memo = memo
		w := (^W)(raw_data(memo))
		pass_start(w, int(to), h, po, opts.budget.steps)
		w.in_header = !po.no_header
	}
	w := (^W)(raw_data(s.memo))
	w.n, w.h, w.p, w.piece[0] = int(to), h, po, s
	s.more = more
	when .Rooms in C {
		w.rooms = hook.rooms_end(h)
	}
	w.keys = s.keys[:]
	when .Walk in C {
		h.walk = w
	}
	r: hook.Walk_Result
	when H == hook.No_Hooks {
		if w.in_header && !s.started && po.limit >= RECORD_DEPTH && u64(len(text)) <= u64(max(u32)) {
			// The header gives its keys as tokens, from the text's first byte. The records are counted by a walk that
			// starts there again, as it does for a whole text, so its blocks are those of the text's.
			r = run_pass(w, text, 0, po, regs, header_ends, true)
			if u8(r) == hook.WALK_STOPPED && w.steps[0] != 0 {
				w^ = {}
				pass_start(w, int(to), h, po, opts.budget.steps)
				w.in_header, w.p, w.piece[0], w.keys = true, po, s, s.keys[:]
				s.keyed, s.records = true, 0
				r = run(w, text, 0, po, regs, on)
			}
			r = steps_ended(w, r)
		} else {
			r = steps_ended(w, run(w, text, 0, po, regs, on))
		}
	} else {
		r = steps_ended(w, run(w, text, 0, po, regs, on))
	}
	when .Walk in C {
		h.walk = nil
	}
	s.started = true
	s.headed, s.widest = !po.no_header && !w.in_header, w.widest
	if head != nil {
		head.keys, head.widest = s.keys[:], w.widest
	}
	if !po.no_header && !w.in_header && len(s.head) == 0 && len(s.keys) > 0 {
		if e := piece_hold_head(s, text); e != nil {
			return 0, e, w.tolerated
		}
	}
	if u8(r) != hook.WALK_MORE {
		p.more, p.open = false, nil
		root_close, err, _ = hook.walk_error(r, &RULES)
		return root_close, err, w.tolerated
	}
	s.regs = regs^
	p.more, p.at, p.keep = true, to, piece_keep(w)
	if e := piece_open(p, s, w, text); e != nil {
		return 0, e, w.tolerated
	}
	return 0, nil, w.tolerated
}

// The hook of a validate's walk of a header: it stops at the first record, whose opening the walk has counted.
@(private)
header_ends :: proc "contextless" (h: ^hook.No_Hooks, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	return s, .Stop if t.kind == .Object else .Next
}

// Whether a first window ending at `to` of a text in pieces holds what the text's opening needs: past a possible byte
// order mark, and under comments with a header, the first byte of the record past the header, not a CR whose next
// byte may make it an empty line. Each window goes on reading the opening where the last one stopped, in `s`.
@(private)
piece_starts :: proc "contextless" (s: ^Piece, src: []u8, to: u64, $S: Spec, p: Pass_Options, refuse: bool) -> bool {
	if to < 3 {
		return false
	}
	if p.no_header || p.comment == 0 && !refuse {
		return true
	}
	f := &s.frame
	if s.opening == .Text {
		f.i, s.opening = int(text_start(src, 0)), .Header
	}
	if s.opening == .Header {
		if !record_start_on(src, f, p.comment, true) {
			return false
		}
		s.opening, s.header_lo, s.header, f.first = .Line, f.i, {cells = 1, wide_at = -1}, true
	}
	if s.opening == .Line {
		if !scan_record_on(src, s.header_lo, 0, S, p.delim, &s.header, f, true, false) {
			return false
		}
		s.opening, f.i = .Next, s.header.line_end + 1
	}
	return p.comment == 0 || record_start_on(src, f, p.comment, true)
}

// The lowest offset the walk of the next window reads: the open record's first byte, the first comment line held, and
// the three bytes before its block, where a UTF-8 sequence that runs into the block may begin.
@(private)
piece_keep :: proc "contextless" (w: ^Pass($S, $H, $LAX, $C)) -> u64 {
	pos := w.piece[0].pos
	keep := min(u64(w.rec_lo), pos - min(pos, 3))
	if w.held != 0 {
		keep = min(keep, u64(w.held - 1))
	}
	return keep
}

// Copies the bytes of the header's keys out of the window `text` the header ended in.
@(private, cold)
piece_hold_head :: proc(s: ^Piece, text: []u8) -> runtime.Allocator_Error {
	first, last := s.keys[0], s.keys[len(s.keys) - 1]
	_, tail := quotes(text, last)
	lo, hi := key_start(text, first), last.lo + u64(last.n) + u64(tail)
	resize(&s.head, int(hi - lo)) or_return
	copy(s.head[:], text[lo:hi])
	s.head_lo = lo
	return nil
}

// What the offsets of the keys of a text in pieces index for a hook reading window `text`: the header's bytes the read
// holds once the header has ended, else the window.
@(private)
piece_keys :: proc "contextless" (p: ^tape.Pieces, text: []u8) -> []u8 {
	s := (^Piece)(p.state)
	if len(s.head) == 0 {
		return text
	}
	return hook.piece_src(s.head[:], s.head_lo)
}

// Sets `p.open` from the walk's place: inside the root array, and once a record has opened, at its index and, under a
// header, at the key of the cell being read.
@(private)
piece_open :: proc(p: ^tape.Pieces, s: ^Piece, w: ^Pass($S, $H, $LAX, $C), text: []u8) -> runtime.Allocator_Error {
	clear(&s.opened)
	append(&s.opened, hook.Open_Level{key = {kind = .End}, count = s.records, name = -1}) or_return
	if w.open && !w.in_header {
		lv := hook.Open_Level{key = {kind = .End}, count = u64(w.cells), object = !w.p.no_header, name = -1}
		if lv.object {
			lv.key = column_key(w.keys, w.cells)
		}
		append(&s.opened, lv) or_return
	}
	return hook.piece_path(p, piece_keys(p, text), &FORMATS[S])
}

// Appends header key `t` to the keys of a walk in pieces, in the list's own allocator. False when the list cannot grow.
@(private, cold)
piece_put_key :: #force_no_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), t: tape.Token) -> bool {
	when LAX {
		s := w.piece[0]
		context = runtime.default_context()
		if _, e := append(&s.keys, t); e != nil {
			return false
		}
		w.keys = s.keys[:]
	}
	return true
}

// Whether the pass reads on from the block where the last window's walk stopped, and that block.
@(private)
piece_resumes :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C)) -> (pos: int, ok: bool) {
	when LAX {
		if w.piece[0] != nil && w.piece[0].started {
			return int(w.piece[0].pos), true
		}
	}
	return 0, false
}

// Whether the window lacks bytes of the block at `pos`, or of those past it, that more bytes may give.
@(private)
piece_holds :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), pos, n: int) -> bool {
	when LAX {
		return w.piece[0] != nil && w.piece[0].more && n - pos < PIECE_AHEAD
	} else {
		return false
	}
}

// Ends the walk of a window before the block at `pos`, which the next window's walk reads.
@(private, cold)
piece_stop :: #force_no_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), pos: int) -> hook.Walk_Result {
	when LAX {
		w.piece[0].pos = u64(pos)
	}
	return hook.walk_result(u64(pos), hook.WALK_MORE)
}

// Whether the hook of a walk in pieces passed over the rest of the text, and whether it skipped the text, whose `End`
// it is still given.
@(private)
piece_rested :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C)) -> (rested, skip_end: bool) {
	when LAX {
		if w.piece[0] != nil {
			return w.piece[0].rested, w.piece[0].skip_end
		}
	}
	return false, false
}

// In a walk in pieces, makes the pass judge the rest of the text with no tokens, as `judge_from` does for a whole text,
// and returns true. With `skip` the text's `End` is still given. Returns false for a whole text.
@(private)
piece_rests :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), skip: bool) -> bool {
	when LAX {
		if w.piece[0] != nil {
			w.piece[0].rested, w.piece[0].skip_end = true, skip
			return true
		}
	}
	return false
}

@(private)
piece_count_record :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C)) {
	when LAX {
		if w.piece[0] != nil {
			w.piece[0].records += 1
		}
	}
}

@(private)
validate_pieces :: proc(src: []u8, $S: Spec, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	walk :: proc(src: []u8, opts: Options, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return piece_read(src, S, opts, h, regs, ctx, hook.no_hook, nil)
	}
	return build.read_validate_pieces(src, &FORMATS[S], opts, allocator, Piece, walk)
}

@(private)
build_pieces :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Builder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		head: Head
		root_close, err, tolerated := piece_read(src, S, opts, build.rows_of(h), regs, ctx, build.builder_hook_rows, &head)
		if err == nil && !opts.pieces.more && len(head.keys) > 0 {
			err = store_header(h, a, head)
		}
		if s := (^Piece)(opts.pieces.state); err != nil && s != nil && len(s.head) > 0 {
			head_end := int(s.head_lo) + len(s.head)
			if s.head[len(s.head) - 1] == '\n' {
				head_end -= 1
			}
			po := options_resolved(S, opts)
			err = repeat_first(err, tape.piece_src(s.head[:], s.head_lo), S, po, head.keys, opts, a, head_end)
		}
		return root_close, err, tolerated
	}
	return build.read_build_pieces(src, &FORMATS[S], &RULES, opts, caller, Piece, walk, finish_built, table_so_far)
}

// Settles a build's document so far as a table: its rows read whole so far and the row the cut is inside with its cells
// so far, under the header once the header has ended, widened by a key for each column a row past it named.
@(private)
table_so_far :: proc(doc: ^tape.Document, opts: Options, rules: ^tape.Rules) -> tape.Error {
	s := (^Piece)(opts.pieces.state)
	if len(doc.nodes) == 0 {
		return nil
	}
	if s.headed && len(s.keys) > 0 {
		ext, err := table_ext(doc.allocator, s.keys[:], max(s.widest, len(s.keys)))
		if err != nil {
			tape.destroy(doc)
			return err
		}
		doc.ext = ext
	}
	return finish_table(doc, opts, true)
}

@(private)
find_pieces :: proc(src: []u8, path: []tape.Step, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		h.key_text = piece_keys(opts.pieces, h.key_text)
		return piece_read(src, S, opts, h, regs, ctx, build.finder_hook, nil)
	}
	return build.read_find_pieces(src, path, &FORMATS[S], read, opts, caller, tape.number_respell, Piece, walk)
}

@(private)
scan_pieces :: proc(src: []u8, demand: ^tape.Demand, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		p := opts.pieces
		h.key_text = piece_keys(p, h.key_text)
		// A window ends between two blocks, never between a key and its value, so the scan passes a member no step
		// takes at its key, as it does in a whole text.
		h.key_skips = !h.facts
		root_close, err, tolerated := piece_read(src, S, opts, h, regs, ctx, build.scanner_key_skip_hook, nil)
		if s := (^Piece)(p.state); s != nil && len(s.head) > 0 {
			h.head = {s.head_lo, s.head_lo + u64(len(s.head))}
		}
		return root_close, err, tolerated
	}
	return build.read_scan_pieces(src, demand, &FORMATS[S], read, opts, caller, Piece, walk)
}
