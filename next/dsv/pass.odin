package dsv

import "base:intrinsics"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The walk of a delimited text, in passes of 64-byte blocks. A block is reduced to masks of its delimiter, LF, CR and
// quote bytes, `prefix_xor` of the quote mask marks the bytes inside quoted cells, and every later test is a bit test
// on a mask: quote placement, a CR that no LF follows, the delimiters and LFs that are the text's rather than a
// cell's, and the delimiters between two LFs that count a record's cells for the width check. UTF-8 is judged a block
// at a time, and only for a block that is not all ASCII. A hooked walk turns the same masks into tokens (tokens.odin).
// A validate compiles the pass with `EMIT` false, which leaves out the token code and the header's keys.

// The state a pass carries from one block to the next, for the blocks and the open record. `rec_lo` is the first byte
// of the record that holds the cursor, `field_lo` the first byte of its open cell, `cells` the number of cells it has
// ended, and `width` the first record's cell count, 0 until a record sets it. A record opens at its first separator.
// An empty line, or a line holding only a CR, is no record, makes no tokens and sets no width.
@(private)
Pass :: struct($S: Spec, $H: typeid, $LAX: bool, $C: hook.Capabilities) {
	n:         int,
	h:         ^H,
	// Masks the last block left for this one. `in_quote` is all ones while a quoted cell is open, `start` has bit 0
	// set when byte 0 follows a separator, `close` bit 0 set after a closing quote, `cr` bit 0 set when the last byte
	// is a CR with no LF yet, and `esc` is 1 after a backslash at the last byte. `line` has bit 0 set when the last
	// block ended with an LF, `comment` when it ended inside a comment line.
	in_quote:  u64,
	start:     u64,
	close:     u64,
	cr:        u64,
	esc:       u64,
	line:      u64,
	comment:   u64,
	// The address one past the hook's room for nodes, for a hook with `.Rooms`.
	rooms:     uintptr,
	utf8:      kernel.Utf8_State,
	rec_lo:    int,
	field_lo:  int,
	cells:     int,
	width:     int,
	widest:    int, // the most cells a record had
	// The header's cells as the `Key` tokens a data cell names its column with.
	keys:      []tape.Token,
	// With `.Columns`, the columns whose keys the hook takes, by `column_bit`, which the first record the hook read
	// whole sets. Until then every column, and `taken` gathers the columns that record's hook did not skip.
	columns:   u64,
	taken:     u64,
	learnt:    bool,
	limit:     u64, // `Budget.depth`
	// With `LAX`, one more than the containers the walk may still open, 0 once it opened one past `Budget.steps`.
	steps:     [int(LAX)]u64,
	// With `LAX`, the read of a text in pieces whose window the pass reads, nil for a whole text.
	piece:     [int(LAX)]^Piece,
	tolerate:  tape.Tolerances,
	delim:     u8,
	// 0, or how the hook keeps the record or the text it answered `Keep` or `Keep_Stubs` for: 1 whole, 2 as stubs.
	keep:      u8,
	keep_root: bool,
	// Whether the cell open at the block's end holds a backslash in a TSV text, or a `""` in a CSV text.
	field_esc: bool,
	// Whether the last block held a byte past 0x7F, whose sequence this block may continue.
	prev_high: bool,
	no_header: bool,
	in_header: bool, // the header is the record being read
	open:      bool, // the open record has made its opening token
	muted:     bool, // the hook passed the open record over
	// Whether any block so far has held a quote byte. While it is false, a block with no quote takes the path with no
	// quote judgement and no quoted-cell state.
	quoted:    bool,
	// Whether the cell open at the block's end holds an ill-formed sequence `.Invalid_Utf8` tolerated, on a hooked
	// pass, or the line open there, on a validate's.
	open_ill:  bool,
	// The walk starts inside the text's `Array` and gives no opening of it, as a walk of one record as the root of a
	// text of its bytes, or of a part of a text past its first, does.
	opened:    bool,
	// The walk ends inside the text's `Array` and gives no `End` of it, as a walk of one record, or of a part of a text
	// before its last, does.
	unclosed:  bool,
	// With `opened`, the walk reads a record it passed again for its hook, from the record's first byte to its `End`.
	again:     bool,
	p:         Pass_Options, // the options the walk was started with, which a walk again reads under
	leveled:   bool, // the hook's levels hold a record's
	// One past the first byte of the comment lines no record has followed yet, 0 when none is held.
	held:      int,
	given:     int, // the comment lines before this byte lie before the header and came before the text's opening

	tolerated: bool, // the walk took a rule of `tolerate`
	refused:   bool, // the hook's room could not grow
}

// The options of one pass: `Dsv_Options` with the delimiter resolved, and the read's tolerances and depth.
@(private)
Pass_Options :: struct {
	tolerate:  tape.Tolerances,
	delim:     u8,
	comment:   u8,
	no_header: bool,
	infer:     bool,
	limit:     u64,
}

// The options a pass reads when a read takes every default, as constants the pass folds.
@(private)
default_options :: #force_inline proc "contextless" ($S: Spec) -> Pass_Options {
	return {delim = spec_delimiter(S, 0), limit = max(u64)}
}

// Returns the CR bytes with no LF after them in `bad`, leaving out bit 63, whose CR the next block judges. `carried` is
// true when a CR from the block before has no LF at byte 0 here, and the fault is then at `pos - 1`.
@(private)
cr_fault :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), cr, nl: u64) -> (bad: u64, carried: bool) {
	return cr & ~(nl >> 1) & ~(u64(1) << 63), w.cr & ~nl != 0
}

// The masks of a CSV block's quotes `q` and separators `seps`: the bytes inside quoted cells, the closing quotes, the
// separators outside quoted cells, and the bare quotes. A quote opens a cell only at a cell's first byte, and one that
// opens a run anywhere else is bare. `in_quote` is all ones when the block starts inside a quoted cell, and `start`
// and `close` have bit 0 set when its byte 0 follows a separator or a closing quote.
@(private)
quote_masks :: #force_inline proc "contextless" ($T: kernel.Tier, q, seps, in_quote, start, close: u64) -> (instr, closing, outside, bare: u64) {
	instr = kernel.prefix_xor(T, q) ~ in_quote
	closing = q & ~instr
	outside = seps & ~instr
	bare = q & instr & ~(outside << 1 | start | closing << 1 | close)
	return
}

// Returns the block's bytes that are inside a comment line, and the LFs that end such a line. `starts` has a bit at
// each comment byte that begins a line outside a quoted cell, and `in_comment` says the block starts inside a comment
// line. The LF that ends a comment line is not a comment byte, it is returned in `lfs`.
@(private)
comment_span :: #force_inline proc "contextless" (nl, starts: u64, in_comment: bool) -> (bytes: u64, lfs: u64) {
	if in_comment {
		if nl == 0 {
			return ~u64(0), 0
		}
		first := nl & -nl
		bytes |= first - 1
		lfs |= first
	}
	for s := starts; s != 0; s &= s - 1 {
		k := u64(intrinsics.count_trailing_zeros(s))
		rest := nl & (~u64(0) << k)
		if rest == 0 {
			bytes |= ~u64(0) << k
		} else {
			first := rest & -rest
			bytes |= (first - 1) & ~((u64(1) << k) - 1)
			lfs |= first
		}
	}
	return
}

// Scans the text from `lo` in 64-byte blocks and returns the walk's result. With `EMIT` false the token code is
// compiled out, for a validate. With `COMMENTS` false the comment-line work is compiled out. `T` is the kernel tier the
// instance is built for. `keys` holds a token per
// header cell for a pass that reads a header, and `width` above 0 is the width a pass from a record's first byte checks
// records against.
@(private)
pass :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, opts: Pass_Options, hs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), $EMIT: bool, $COMMENTS: bool, $T: kernel.Tier) -> hook.Walk_Result {
	base := raw_data(src)
	n := len(src)
	delim := w.delim
	comment := opts.comment
	_ = comment

	pos, resumed := piece_resumes(w)
	if !resumed {
		pos = int(text_start(src, lo))
		w.rec_lo, w.field_lo = pos, pos
		when EMIT {
			// The text's opening `Array` token, at `lo` with `n` 0.
			if r, done := open_text(w, src, lo, opts, hs, on); done {
				return r
			}
		}
	}

	for pos < n {
		when LAX {
			if piece_holds(w, pos, n) {
				return piece_stop(w, pos)
			}
		}
		rem := n - pos
		b: kernel.Block
		valid: u64
		if rem >= 64 {
			b = kernel.load(base[pos:])
			valid = ~u64(0)
		} else {
			// The last block is partial and zero-padded. A zero byte is no delimiter, no quote and ASCII, and `valid`
			// clears the mask bits past the text's end.
			b = kernel.load_padded(src, pos)
			valid = u64(1) << u64(rem) - 1
		}

		seps, lfs, clfs: u64
		bs: u64
		cb: u64
		_ = cb
		fault := -1
		kind := tape.Fault_Kind.Bad_Char
		detail := Detail.None
		when S == .Csv {
			m := kernel.pack_n([4]kernel.Block{kernel.eq(b, '"'), kernel.eq(b, delim), kernel.eq(b, '\n'), kernel.eq(b, '\r')})
			q, d, nl, crm := m[0], m[1], m[2], m[3]
			// A comment line's bytes are text: they make no separator, open no quoted cell and hold no CR, and its LF
			// still ends the line. Each run is cleared from `q`, `d` and `crm` before the next line start is judged,
			// so a quote in a comment line does not flip the quoted-cell state.
			when COMMENTS {
				if w.comment != 0 {
					run, lf := comment_span(nl, 0, true)
					cb |= run
					clfs |= lf
					q &= ~run
					d &= ~run
					crm &= ~run
				}
				remaining := ((nl << 1) | w.line) & kernel.pack(kernel.eq(b, comment))
				for remaining != 0 {
					s := remaining & -remaining
					remaining &~= s
					if w.quoted || q != 0 {
						// Under `.Bare_Quote` the quotes before a line start pair up without its bare ones, which the
						// quote loop below would drop only after the comment lines are cleared.
						if .Bare_Quote in w.tolerate {
							for {
								_, _, _, bare := quote_masks(T, q, d | nl, w.in_quote, w.start, w.close)
								if bare &= s - 1; bare == 0 {
									break
								}
								q &~= bare & -bare
								w.tolerated = true
							}
						}
						if s & (kernel.prefix_xor(T, q) ~ w.in_quote) != 0 {
							continue
						}
					}
					run, lf := comment_span(nl, s, false)
					cb |= run
					clfs |= lf
					q &= ~run
					d &= ~run
					crm &= ~run
				}
				w.comment = cb >> 63
			}
			// With no quote byte in this block and none in any earlier block, no quoted cell is open, so every
			// separator is a delimiter or an LF, no quote placement needs judging, and `w.in_quote` stays clear.
			if !w.quoted && q == 0 {
				seps = d | nl
				lfs = nl
				bad, carried := cr_fault(w, crm, nl)
				if carried {
					fault = pos - 1
				} else if bad != 0 {
					fault = pos + int(intrinsics.count_trailing_zeros(bad))
				}
				w.start = seps >> 63
				w.cr = crm >> 63
			} else {
				w.quoted = true
				instr, closing, cr, bad, bare: u64
				carried: bool
				for {
					// Once a text has held a quote every block takes this path, as a branch per block on its own quotes
					// mispredicts on a text that quotes some cells and not others.
					instr = kernel.prefix_xor(T, q) ~ w.in_quote
					open := q & instr
					closing = q & ~instr
					seps = (d | nl) & ~instr
					lfs = nl & ~instr
					cr = crm & ~instr
					// A quote opens a cell only at the cell's first byte. A closing quote may be followed only by a
					// quote that doubles it, the delimiter, LF, CR or the end of the text.
					after := closing << 1 | w.close
					bare = open & ~(seps << 1 | w.start | after)
					bad = bare | after & ~(q | d | nl | crm | ~valid)
					cr_bad, c := cr_fault(w, cr, nl)
					bad |= cr_bad
					carried = c
					// Under `.Bare_Quote` a tolerated bare quote is no quote, and the block's quotes pair up again
					// without it.
					first := bad & -bad
					if bare & first == 0 || .Bare_Quote not_in w.tolerate {
						break
					}
					q &~= first
					w.tolerated = true
				}
				// A quote that opens right after a closing one is the second of a `""`, which a cell's decode reads.
				when EMIT {
					bs = (closing << 1 | w.close) & q
				}
				if carried {
					fault = pos - 1
				} else if bad != 0 {
					fault = pos + int(intrinsics.count_trailing_zeros(bad))
				}
				// All ones when the block ended inside a quoted cell, the mask the next block's run starts from.
				w.in_quote = u64(0) - (instr >> 63)
				w.start = seps >> 63
				w.close = closing >> 63
				w.cr = cr >> 63
			}
		} else {
			m := kernel.pack_n([3]kernel.Block{kernel.eq(b, delim), kernel.eq(b, '\n'), kernel.eq(b, '\r')})
			d, nl, crm := m[0], m[1], m[2]
			when S == .Tsv {
				// A block with no backslash holds no escaped cell, so the mask is packed only for a block that holds
				// one.
				bsm := kernel.eq(b, '\\')
				if kernel.any_lane(bsm) {
					bs = kernel.pack(bsm)
				}
			}
			seps = d | nl
			lfs = nl
			// A comment line's bytes are text, its LF ends the line, and a backslash in it opens no escape.
			when COMMENTS {
				starts := ((nl << 1) | w.line) & kernel.pack(kernel.eq(b, comment))
				cb, clfs = comment_span(nl, starts, w.comment != 0)
				d &= ~cb
				crm &= ~cb
				bs &= ~cb
				seps = d | nl
				w.comment = cb >> 63
			}
			bad, carried := cr_fault(w, crm, nl)
			if carried {
				fault = pos - 1
			} else if bad != 0 {
				fault = pos + int(intrinsics.count_trailing_zeros(bad))
			}
			w.cr = crm >> 63
			when S == .Tsv {
				// A backslash must open one of the five escapes. Any other byte after it is a `.Bad_Escape` fault at
				// the backslash.
				if bs != 0 || w.esc != 0 {
					if at := escape_fault(T, b, bs, pos, &w.esc); at >= 0 && (fault < 0 || at < fault) {
						fault, kind = at, .Bad_Escape
					}
				}
			}
		}
		when COMMENTS {
			w.line = nl >> 63
		}
		_ = bs

		// UTF-8 is checked on a block with a byte past 0x7F, and on an ASCII block only when the block before left a
		// sequence open. Under `.Invalid_Utf8` a block whose check fails is read for the leads of its ill-formed
		// sequences, as the mask `ill`, and `ill_back` is the lead of one that starts in the block before and that
		// this block's check found. The tolerance is for cells: an ill-formed sequence in a comment line is still a
		// fault, as it is in a JSONC comment.
		ill: u64
		ill_back := -1
		check := kernel.utf8_next(T, b, kernel.is_ascii(b), &w.utf8, &w.prev_high)
		if check && !kernel.utf8_clean(T, w.utf8) {
			if .Invalid_Utf8 not_in w.tolerate {
				// A sequence the text cuts short is reported at the text's end, after a quoted cell the text leaves
				// open, so a block padded past the end does not report it first.
				if at, k, dd := utf8_fault(src, int(lo), pos); at >= 0 && k != .Truncated && (fault < 0 || at < fault) {
					fault, kind, detail = at, k, dd
				}
			} else {
				// The error state starts clean again, so the next block's check reports that block's errors only.
				w.utf8.err = {}
				when EMIT || COMMENTS {
					ill, ill_back = ill_leads(base, int(lo), pos, n)
				}
				when COMMENTS {
					if at, k, dd := comment_utf8_fault(src, pos, ill, ill_back, cb | clfs); at >= 0 && (fault < 0 || at < fault) {
						fault, kind, detail = at, k, dd
					}
				}
				w.tolerated = true
			}
		}

		_, _ = ill, ill_back

		// A fault ends the read at its byte, and the separators past it are cleared, so no record that reaches it is
		// counted and no cell of one is read.
		if fault >= 0 {
			cut := u64(1) << u64(max(fault - pos, 0)) - 1
			seps &= cut
			lfs &= cut
			clfs &= cut
		}

		when EMIT {
			// Every cell that the block ends, except the one open at its start, is shorter than 64 bytes. That cell can
			// exceed `max(u32)` only if it opened more than `max(u32) - 64` bytes before `pos`, so the test runs only
			// then.
			if pos - w.field_lo > int(max(u32)) - 64 && cell_too_wide(base, w.field_lo, pos, seps) {
				return fault_at(u64(w.field_lo), .Too_Wide)
			}
			// A block that holds an ill-formed sequence, or that a cell holding one is open across, reads its cells'
			// spellings through a cold instance, so the clean instance holds no test of them.
			if .Invalid_Utf8 in opts.tolerate && (ill != 0 || ill_back >= 0 || w.open_ill) {
				if r, done := read_lax_tokens(COMMENTS, w, src, opts, pos, seps, lfs, clfs, bs, ill, ill_back, hs, on); done {
					return r
				}
			} else if r, done := read_tokens(false, COMMENTS, w, src, opts, pos, seps, lfs, clfs, bs, 0, -1, hs, on); done {
				return r
			}
		} else {
			if r, done := read_cells(COMMENTS, w, base, pos, seps, lfs, clfs); done {
				return r
			}
		}

		if fault >= 0 {
			// A mask fault names its rule by its byte: a CR with no LF, a quote in an unquoted cell, else a byte after a
			// closing quote.
			if kind == .Bad_Char && detail == .None {
				detail = .Bare_Quote if base[fault] == '"' else .Lone_Cr if base[fault] == '\r' else .After_Quote
			}
			return fault_at(u64(fault), kind, detail)
		}
		pos += 64
	}
	when LAX {
		if piece_holds(w, pos, n) {
			return piece_stop(w, pos)
		}
	}

	// Faults that only the text's end shows, in text order: a CR or backslash left open by the last block, a quoted
	// cell never closed, a UTF-8 sequence left open, then the last cell's width.
	if w.cr != 0 {
		return fault_at(u64(n - 1), .Bad_Char, .Lone_Cr)
	}
	when S == .Tsv {
		if w.esc != 0 {
			return fault_at(u64(n - 1), .Bad_Escape)
		}
	}
	// An unclosed quoted cell is a `Truncated` fault at its opening quote. A sequence ill-formed before the end, as a
	// lead the last block ends on that no sequence starts with, is a fault of that block and comes first.
	when S == .Csv {
		if w.in_quote != 0 {
			if w.prev_high && !kernel.utf8_ok(w.utf8) && .Invalid_Utf8 not_in w.tolerate {
				if at, k, d := utf8_fault(src, int(lo), n); at >= 0 && k != .Truncated {
					return fault_at(u64(at), k, d)
				}
			}
			return fault_at(u64(scan_record(src, w.rec_lo, 0, S, delim).quote), .Truncated, .Open_Quote)
		}
	}
	if w.prev_high && !kernel.utf8_ok(w.utf8) {
		comment_open := false
		when COMMENTS {
			comment_open = w.comment != 0
		}
		if .Invalid_Utf8 not_in w.tolerate || comment_open {
			if at, k, d := utf8_fault(src, int(lo), n); at >= 0 {
				return fault_at(u64(at), k, d)
			}
		}
		when EMIT {
			_, back := ill_leads(base, int(lo), n, n)
			if back >= w.field_lo {
				w.open_ill, w.tolerated = true, true
			}
		}
	}
	when EMIT {
		if n - w.field_lo > int(max(u32)) {
			return fault_at(u64(w.field_lo), .Too_Wide)
		}
	}

	// The record the text ends in, when no LF ends it. A text that ends inside a comment line ends in no record: the
	// whole last line is a comment whether or not it has a line end.
	last := w.rec_lo < n
	when COMMENTS {
		last = last && w.comment == 0
		when EMIT {
			if w.comment != 0 && w.rec_lo < n && w.held == 0 && w.rec_lo >= w.given {
				w.held = w.rec_lo + 1
			}
		}
	}
	if last {
		when EMIT {
			if r, done := read_last_tokens(w, src, opts, hs, on); done {
				return r
			}
		} else {
			if fault, wide := record_width(w, w.cells + 1, &w.width); fault {
				return fault_at(u64(w.rec_lo), .Bad_Width, .Too_Many if wide else .Too_Few)
			}
		}
	}

	when EMIT {
		if r, done := close_text(w, src, opts.comment, n, hs, on); done {
			return r
		}
	}
	return hook.walk_result(u64(n), 0)
}

// The walk's result when the hook stopped on the token at `lo` of `n` bytes.
@(private)
stopped :: #force_inline proc "contextless" (lo: u64, n: u32) -> hook.Walk_Result {
	return hook.walk_result(lo + u64(n), hook.WALK_STOPPED)
}

// The result of a fault of `kind` at `at` with `detail`.
@(private)
fault_at :: #force_inline proc "contextless" (at: u64, kind: tape.Fault_Kind, detail := Detail.None) -> hook.Walk_Result {
	return hook.walk_result(at, u8(kind), u8(detail))
}
