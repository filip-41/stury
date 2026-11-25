package dsv

import "base:intrinsics"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The walk of a delimited text, in 64-byte blocks. A block is reduced to masks of its delimiter, LF, CR and quote
// bytes. `prefix_xor` of the quote mask marks the bytes inside quoted cells, and every later test is a bit test on a
// mask: quote placement, a CR that no LF follows, the delimiters and LFs that are the text's rather than a cell's, and
// the delimiters between two LFs, which count a record's cells for the width check. UTF-8 is checked a block at a
// time, on a block that is not all ASCII or that follows a block that left a sequence open. A hooked walk turns the
// same masks into tokens (tokens.odin). A validate compiles the pass with `EMIT` false, which leaves out the token
// code and the header's keys.

// The state a pass carries from one block to the next, including the open record's. `rec_lo` is the first byte
// of the record that holds the cursor, `field_lo` the first byte of its open cell, `cells` the number of cells it has
// ended, and `width` the first record's cell count, 0 until a record sets it. A record opens at its first separator.
// An empty line, or a line holding only a CR, is no record, makes no tokens and sets no width.
@(private)
Pass :: struct($S: Spec, $H: typeid, $LAX: bool, $C: hook.Capabilities) {
	n:          int,
	h:          ^H,
	// Masks the last block left for this one. `in_quote` is all ones while a quoted cell is open, `start` has bit 0
	// set when byte 0 follows a separator, `close` bit 0 set after a closing quote, `cr` bit 0 set when the last byte
	// is a CR with no LF yet, and `esc` is 1 after an odd run of backslashes at the last byte. `line` has bit 0 set
	// when the last block ended with an LF, `in_comment` when it ended inside a comment line.
	in_quote:   u64,
	start:      u64,
	close:      u64,
	cr:         u64,
	esc:        u64,
	line:       u64,
	in_comment: u64,
	// The address one past the hook's room for nodes, for a hook with `.Rooms`.
	rooms:      uintptr,
	utf8:       kernel.Utf8_State,
	rec_lo:     int,
	field_lo:   int,
	cells:      int,
	width:      int,
	widest:     int, // the most cells a record had
	// The header's cells as the `Key` tokens a data cell names its column with.
	keys:       []tape.Token,
	// With `.Columns`, the columns whose keys the hook takes, by `column_bit`. The first record the hook read whole
	// sets it. Until then it holds every column, and `taken` gathers the columns the hook did not skip in that record.
	columns:    u64,
	taken:      u64,
	learnt:     bool,
	// With `LAX`, one more than the containers the walk may still open, 0 once it opened one past `Budget.steps`.
	steps:      [int(LAX)]u64,
	// With `LAX`, the read of a text in pieces whose window the pass reads, nil for a whole text.
	piece:      [int(LAX)]^Piece,
	tolerate:   tape.Tolerances,
	delim:      u8,
	keep:       Kept, // how the hook keeps the open record, or the text with `keep_root`
	keep_root:  bool,
	// Whether the cell open at the block's end holds a backslash in a TSV text, or a `""` in a CSV text.
	field_esc:  bool,
	// Whether the last block held a byte past 0x7F, whose sequence this block may continue.
	prev_high:  bool,
	in_header:  bool, // the header is the record being read
	open:       bool, // the open record has made its opening token
	muted:      bool, // the hook passed the open record over
	// Whether any block so far has held a quote byte. While it is false, a block with no quote runs the path that
	// judges no quotes and keeps no quoted-cell state.
	quoted:     bool,
	// Whether the cell open at the block's end holds an ill-formed sequence `.Invalid_Utf8` tolerated. Only a pass that
	// gives tokens sets it.
	open_ill:   bool,
	// The walk starts inside the text's `Array` and gives no opening of it, as a walk of one record as the root of a
	// text of its bytes, or of a part of a text past its first, does.
	opened:     bool,
	// The walk ends inside the text's `Array` and gives no `End` of it, as a walk of one record, or of a part of a text
	// before its last, does.
	unclosed:   bool,
	// With `opened`, the walk reads a record it passed again for its hook, from the record's first byte to its `End`.
	again:      bool,
	p:          Pass_Options, // the options the walk was started with, which a walk again reads under
	leveled:    bool, // the hook's levels hold a record's
	// One past the first byte of the comment lines no record has followed yet, so 0 means none is held.
	held:       int,
	// The comment lines before this byte precede the header and were given as the text's own.
	given:      int,
	tolerated:  bool, // the walk took a rule of `tolerate`
}

// The bit a read of one record sets in its pass's capabilities. Such a pass starts at the record's first byte in the
// whole text and ends after the first LF outside a quoted cell, which it finds as it reads, with the walk's result at
// the byte past it. The bytes of a block past that LF are not judged.
@(private)
ONE_RECORD :: transmute(hook.Capabilities)u32(1 << 31)

// The bit of the pass's capabilities of a walk of a header of `MASKED_WIDTH` cells or more for an `alike` hook of
// `.Columns` in a CSV text, whose pass takes the cells of the columns it learnt by mask (`values_masked`). It is a pass
// of its own so that a narrow text's pass has none of its code.
@(private)
MASK_COLUMNS :: transmute(hook.Capabilities)u32(1 << 30)

// The pass's own bits lie past the hook's capabilities, and no field of `Pass` depends on its capabilities, so a walk
// reads one pass as another of the same walk with other bits (`walk_text`, `values_masked`).
#assert(int(max(hook.Capability)) < 30)
#assert(size_of(Pass(.Csv, hook.No_Hooks, false, {})) == size_of(Pass(.Csv, hook.No_Hooks, false, ONE_RECORD + MASK_COLUMNS)))
#assert(offset_of(Pass(.Csv, hook.No_Hooks, true, {}), tolerated) == offset_of(Pass(.Csv, hook.No_Hooks, true, ONE_RECORD + MASK_COLUMNS), tolerated))

// How a hook keeps a record or the text, from its answer at the opening token.
@(private)
Kept :: enum u8 {
	None,
	Whole, // `Keep`
	Stubs, // `Keep_Stubs`
}

// Returns the CR bytes with no LF after them in `bad`, leaving out bit 63, whose CR the next block judges. `carried` is
// true when a CR from the block before, `last` bit 0, has no LF at byte 0 here, and the fault is then at `pos - 1`.
@(private)
cr_fault :: #force_inline proc "contextless" (last, cr, nl: u64) -> (bad: u64, carried: bool) {
	return cr & ~(nl >> 1) & ~(u64(1) << 63), last & ~nl != 0
}

// Returns the masks of a CSV block's quotes `q` and separators `seps`: the bytes inside quoted cells, the closing
// quotes, the separators outside quoted cells, and the bare quotes. A quote opens a cell only at a cell's first byte,
// and one that opens a run anywhere else is bare. `in_quote` is all ones when the block starts inside a quoted cell,
// and `start` and `close` have bit 0 set when its byte 0 follows a separator or a closing quote.
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

// Walks `src` from `lo` in 64-byte blocks and returns the walk's result. With `EMIT` false the token code is compiled
// out, for a validate. With `COMMENTS` false the comment-line code is compiled out. `T` is the kernel tier the
// instance is built for. `w.keys` and `w.width` are read as `Pass` says.
@(private)
pass :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, opts: Pass_Options, hs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), $EMIT: bool, $COMMENTS: bool, $T: kernel.Tier) -> hook.Walk_Result {
	base := raw_data(src)
	n := len(src)
	delim := w.delim
	comment := opts.comment
	_ = comment
	// All ones for a comment byte, 0 for none, so a pass with comment code and no comment byte starts no comment line at
	// a NUL, which a text's last block is padded with.
	comment_on := u64(0) - u64(comment != 0)
	_ = comment_on

	pos, resumed := piece_resumes(w)
	if !resumed {
		pos = int(text_start(src, lo))
		w.rec_lo, w.field_lo = pos, pos
		when EMIT {
			// The text's opening `Array` token, at `lo` with `n` 0.
			if r, done := open_text(w, src, lo, opts, hs, on); done {
				return r
			}
		} else when LAX {
			// The text's `Array` is the first container the budget counts.
			if !w.opened {
				w.steps[0] -= 1
			}
		}
	}

	// With tokens, each block's tokens are read as soon as its masks are made. The masks a block leaves for the next
	// are read from `w` and written back before its tokens, which read `w.quoted`, so they hold no register across the
	// token code. The token reader's state, and without tokens the masks, are locals across the whole pass, written
	// back to `w` when the block loop ends. The block loop sits in an outer one that each of its exits leaves, a shape
	// whose code layout keeps the validate's block loop free of mispredicted branches.
	for pos < n {
		fault := -1
		kind := tape.Fault_Kind.Bad_Char
		detail := Detail.None
		one_end := -1
		window_end := false
		_ = window_end
		when EMIT {
			t := Token_State{field_lo = w.field_lo, cells = w.cells, carry = w.field_esc, regs = hs^}
		} else {
			in_quote, start, close, last_cr, quoted, prev_high := w.in_quote, w.start, w.close, w.cr, w.quoted, w.prev_high
			rs := cells_start(w)
		}
		for pos < n {
			when EMIT {
				in_quote, start, close, last_cr, quoted, prev_high := w.in_quote, w.start, w.close, w.cr, w.quoted, w.prev_high
			}
			when LAX {
				if piece_holds(w, pos, n) {
					window_end = true
					break
				}
			}
			rem := n - pos
			b: kernel.Block
			valid: u64
			if rem >= 64 {
				b = kernel.load(base[pos:])
				valid = ~u64(0)
			} else {
				// The last block is partial and zero-padded. A zero byte is no delimiter, no quote and ASCII, and
				// `valid` clears the mask bits past the text's end.
				b = kernel.load_padded(src, pos)
				valid = u64(1) << u64(rem) - 1
			}

			seps, lfs, clfs: u64
			bs: u64
			cb: u64
			_ = cb
			when S == .Csv {
				m := kernel.pack_n([4]kernel.Block{kernel.eq(b, '"'), kernel.eq(b, delim), kernel.eq(b, '\n'), kernel.eq(b, '\r')})
				q, d, nl, crm := m[0], m[1], m[2], m[3]
				// A comment line's bytes are text: they make no separator, open no quoted cell and hold no CR, and its
				// LF still ends the line. Each run is cleared from `q`, `d` and `crm` before the next line start is
				// judged, so a quote in a comment line does not flip the quoted-cell state.
				when COMMENTS {
					if w.in_comment != 0 {
						run, lf := comment_span(nl, 0, true)
						cb |= run
						clfs |= lf
						q &= ~run
						d &= ~run
						crm &= ~run
					}
					remaining := ((nl << 1) | w.line) & kernel.pack(kernel.eq(b, comment)) & comment_on
					for remaining != 0 {
						s := remaining & -remaining
						remaining &~= s
						if quoted || q != 0 {
							// Under `.Bare_Quote` the quotes before a line start pair up without its bare ones, which
							// the quote loop below would drop only after the comment lines are cleared.
							if .Bare_Quote in opts.tolerate {
								for {
									_, _, _, bare := quote_masks(T, q, d | nl, in_quote, start, close)
									if bare &= s - 1; bare == 0 {
										break
									}
									q &~= bare & -bare
									w.tolerated = true
								}
							}
							if s & (kernel.prefix_xor(T, q) ~ in_quote) != 0 {
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
					w.in_comment = cb >> 63
				}
				// With no quote byte in this block and none in any earlier block, no quoted cell is open, so every
				// separator is a delimiter or an LF, no quote placement needs judging, and `in_quote` stays clear.
				if !quoted && q == 0 {
					seps = d | nl
					lfs = nl
					bad, carried := cr_fault(last_cr, crm, nl)
					if carried {
						fault = pos - 1
					} else if bad != 0 {
						fault = pos + int(intrinsics.count_trailing_zeros(bad))
					}
					start = seps >> 63
					last_cr = crm >> 63
				} else {
					quoted = true
					instr, closing, cr, bad, bare: u64
					carried: bool
					for {
						// Once a text has held a quote every block takes this path, as a branch per block on its own
						// quotes mispredicts on a text that quotes some cells and not others.
						instr = kernel.prefix_xor(T, q) ~ in_quote
						open := q & instr
						closing = q & ~instr
						seps = (d | nl) & ~instr
						lfs = nl & ~instr
						cr = crm & ~instr
						// A quote opens a cell only at the cell's first byte. A closing quote may be followed only by a
						// quote that doubles it, the delimiter, LF, CR or the end of the text.
						after := closing << 1 | close
						bare = open & ~(seps << 1 | start | after)
						// `open` is a quote that starts a run of quoted bytes. `~valid` keeps the zero padding past the
						// text's end from faulting after a closing quote at the last byte.
						bad = bare | after & ~(q | d | nl | crm | ~valid)
						cr_bad, c := cr_fault(last_cr, cr, nl)
						bad |= cr_bad
						carried = c
						// Under `.Bare_Quote` a tolerated bare quote is no quote, and the block's quotes pair up again
						// without it.
						first := bad & -bad
						if bare & first == 0 || .Bare_Quote not_in opts.tolerate {
							break
						}
						q &~= first
						w.tolerated = true
					}
					// A quote that opens right after a closing one is the second of a `""`, which a cell's decode
					// reads.
					when EMIT {
						bs = (closing << 1 | close) & q
					}
					if carried {
						fault = pos - 1
					} else if bad != 0 {
						fault = pos + int(intrinsics.count_trailing_zeros(bad))
					}
					// All ones when the block ended inside a quoted cell, the mask the next block's run starts from.
					in_quote = u64(0) - (instr >> 63)
					start = seps >> 63
					close = closing >> 63
					last_cr = cr >> 63
				}
			} else {
				m := kernel.pack_n([3]kernel.Block{kernel.eq(b, delim), kernel.eq(b, '\n'), kernel.eq(b, '\r')})
				d, nl, crm := m[0], m[1], m[2]
				when S == .Tsv {
					// A block with no backslash holds no escaped cell, so the mask is packed only for a block that
					// holds one.
					bsm := kernel.eq(b, '\\')
					if kernel.any_lane(bsm) {
						bs = kernel.pack(bsm)
					}
				}
				seps = d | nl
				lfs = nl
				// A comment line's bytes are text, its LF ends the line, and a backslash in it opens no escape.
				when COMMENTS {
					starts := ((nl << 1) | w.line) & kernel.pack(kernel.eq(b, comment)) & comment_on
					cb, clfs = comment_span(nl, starts, w.in_comment != 0)
					d &= ~cb
					crm &= ~cb
					bs &= ~cb
					seps = d | nl
					w.in_comment = cb >> 63
				}
				bad, carried := cr_fault(last_cr, crm, nl)
				if carried {
					fault = pos - 1
				} else if bad != 0 {
					fault = pos + int(intrinsics.count_trailing_zeros(bad))
				}
				last_cr = crm >> 63
				when S == .Tsv {
					// A backslash must open one of the five escapes. Any other byte after it is a `.Bad_Escape` fault
					// at the backslash.
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

			// The record a one-record pass reads ends at the block's first LF: the masks and faults past it are the
			// next record's.
			when ONE_RECORD <= C {
				if lfs != 0 {
					k := int(intrinsics.count_trailing_zeros(lfs))
					one_end = pos + k
					keep := ~u64(0) >> u64(63 - k)
					seps &= keep
					lfs &= keep
					if fault > one_end {
						fault = -1
					}
				}
			}

			// UTF-8 is checked on a block with a byte past 0x7F, and on an ASCII block only when the block before left
			// a sequence open. Under `.Invalid_Utf8` a block whose check fails is read for the leads of its ill-formed
			// sequences, as the mask `ill`, and `ill_back` is the lead of one that starts in the block before and that
			// this block's check found. The tolerance is for cells: an ill-formed sequence in a comment line is still a
			// fault, as it is in a JSONC comment.
			ill: u64
			ill_back := -1
			check := kernel.utf8_next(T, b, kernel.is_ascii(b), &w.utf8, &prev_high)
			if check && !kernel.utf8_clean(T, w.utf8) {
				if .Invalid_Utf8 not_in opts.tolerate {
					// A sequence the text cuts short is reported at the text's end, after a quoted cell the text leaves
					// open, so a block padded past the end does not report it first.
					if at, k, dd := utf8_fault(src, int(lo), pos); at >= 0 && k != .Truncated && (fault < 0 || at < fault) && (one_end < 0 || at <= one_end) {
						fault, kind, detail = at, k, dd
					}
				} else {
					// Clears the error state, so the next block's check reports that block's errors only.
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

			when EMIT {
				w.in_quote, w.start, w.close, w.cr, w.quoted, w.prev_high = in_quote, start, close, last_cr, quoted, prev_high
			}

			// A fault ends the read at its byte, and the separators past it are cleared, so no record that reaches it
			// is counted and no cell of one is read.
			if fault >= 0 {
				cut := u64(1) << u64(max(fault - pos, 0)) - 1
				seps &= cut
				lfs &= cut
				clfs &= cut
			}

			when EMIT {
				// A block that holds an ill-formed sequence, or that a cell holding one is open across, reads its
				// cells' spellings through a cold instance, so the clean instance holds no test of them.
				if .Invalid_Utf8 in opts.tolerate && (ill != 0 || ill_back >= 0 || w.open_ill) {
					given := t
					r, done := lax_block_tokens(COMMENTS, w, src, opts, &given, quoted, pos, seps, lfs, bs, clfs, ill, ill_back, on)
					t = given
					if done {
						hs^ = t.regs
						return r
					}
				} else if r, done := block_tokens(false, COMMENTS, w, src, opts, &t, quoted, pos, seps, lfs, bs, clfs, 0, -1, on); done {
					hs^ = t.regs
					return r
				}
			} else {
				if r, done := read_cells(COMMENTS, w, &rs, base, pos, seps, lfs, clfs); done {
					w.in_quote, w.start, w.close, w.cr, w.quoted, w.prev_high = in_quote, start, close, last_cr, quoted, prev_high
					cells_end(w, &rs)
					return r
				}
			}
			if fault >= 0 {
				break
			}
			when ONE_RECORD <= C {
				if lfs != 0 {
					break
				}
			}
			pos += 64
		}
		when EMIT {
			w.field_lo, w.cells, w.field_esc = t.field_lo, t.cells, t.carry
			hs^ = t.regs
		} else {
			w.in_quote, w.start, w.close, w.cr, w.quoted, w.prev_high = in_quote, start, close, last_cr, quoted, prev_high
			cells_end(w, &rs)
		}
		if fault >= 0 {
			// A mask fault names its rule by its byte: a CR with no LF, a quote in an unquoted cell, else a byte after
			// a closing quote.
			if kind == .Bad_Char && detail == .None {
				detail = .Bare_Quote if base[fault] == '"' else .Lone_Cr if base[fault] == '\r' else .After_Quote
			}
			return fault_at(u64(fault), kind, detail)
		}
		when ONE_RECORD <= C {
			if one_end >= 0 {
				return hook.walk_result(u64(one_end + 1), 0)
			}
		}
		when LAX {
			if window_end {
				return piece_stop(w, pos)
			}
		}
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
			comment_open = w.in_comment != 0
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
		if u64(n - w.field_lo) > u64(max(u32)) {
			return fault_at(u64(w.field_lo), .Too_Wide)
		}
	}

	// The record the text ends in, when no LF ends it. A text that ends inside a comment line ends in no record: the
	// whole last line is a comment whether or not it has a line end.
	last := w.rec_lo < n
	when COMMENTS {
		last = last && w.in_comment == 0
		when EMIT {
			if w.in_comment != 0 && w.rec_lo < n && w.held == 0 && w.rec_lo >= w.given {
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
			when LAX {
				// A record wider than the first faults before it opens its container.
				if w.in_header || w.width == 0 || w.cells + 1 <= w.width || .Ragged in w.tolerate {
					if r, done := step_record(w, w.rec_lo); done {
						return r
					}
				}
			}
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

// Returns the walk's result for a hook that stopped on the token at `lo` of `n` bytes.
@(private)
stopped :: #force_inline proc "contextless" (lo: u64, n: u32) -> hook.Walk_Result {
	return hook.walk_result(lo + u64(n), hook.WALK_STOPPED)
}

// Returns the walk's result for a fault of `kind` at `at` with `detail`.
@(private)
fault_at :: #force_inline proc "contextless" (at: u64, kind: tape.Fault_Kind, detail := Detail.None) -> hook.Walk_Result {
	return hook.walk_result(at, u8(kind), u8(detail))
}

// Starts walk `w` of a text of `n` bytes for hook `h` under `p`: at the first line and offset, with the steps
// `Budget.steps` leaves, and the room and the columns the hook's capabilities ask for.
@(private)
pass_start :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), n: int, h: ^H, p: Pass_Options, steps: u64) {
	w.n, w.h, w.delim, w.tolerate, w.start, w.line = n, h, p.delim, p.tolerate, 1, 1
	when LAX {
		w.steps[0] = steps_left(steps)
	}
	when .Rooms in C {
		w.rooms = hook.rooms_end(h)
	}
	when .Columns in C {
		w.columns = ~u64(0)
	}
}

// What `Pass.steps` starts with for `Budget.steps` `steps`: one more, so that 0 says the walk opened one past them, and
// every container for a budget of none.
@(private)
steps_left :: #force_inline proc "contextless" (steps: u64) -> u64 {
	return steps + 1 if steps != 0 && steps < max(u64) else max(u64)
}

// The result `r` of walk `w`, as `WALK_STEPS` at the byte it stopped when its hook was stopped by the steps run out.
@(private)
steps_ended :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), r: hook.Walk_Result) -> hook.Walk_Result {
	when LAX {
		return hook.steps_result(r, w.steps[0])
	}
	return r
}
