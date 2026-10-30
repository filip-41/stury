package dsv

import "base:intrinsics"
import core "../core"
import kernel "../core/kernel"

// State carried from one block to the next, for the blocks and the open record. `rec_lo` is the first byte of the
// record that holds the cursor, `field_lo` the first byte of its open cell, `cells` the number of cells it has ended,
// and `width` the first record's cell count, 0 until a record sets it. A record opens at its first separator. An empty
// line, or a line holding only a CR, is no record, makes no tokens and sets no width.
@(private)
Pass :: struct($S: Spec, $H: typeid) {
	n:         int,
	h:         ^H,
	// Masks the last block left for this one. `in_quote` is all ones while a quoted field is open, `start` has bit 0
	// set when byte 0 follows a separator, `close` bit 0 set after a closing quote, `cr` bit 0 set when the last byte
	// is a CR with no LF yet, and `esc` is 1 after a backslash at the last byte.
	// `prev_high` is set when the last block held a byte past 0x7F, whose sequence this block may continue.
	in_quote:  u64,
	start:     u64,
	close:     u64,
	cr:        u64,
	esc:       u64,
	// `line` has bit 0 set when the last block ended with an LF, `comment` when it ended inside a comment line.
	line:      u64,
	comment:   u64,
	// Whether the cell still open at the block's end holds a backslash, for a TSV text. The next block's `carry`
	// starts from it.
	field_esc: bool,
	prev_high: bool,
	utf8:      kernel.Utf8_State,
	rec_lo:    int,
	field_lo:  int,
	cells:     int,
	width:     int,
	// The hooked lane. `keys` holds the header's cells as the `Key` tokens a data cell names its column with, `delim`
	// is the byte between cells, `no_header` says the text has no header, `in_header` that the header is the record
	// being read, `open` that the open record has made its opening token, and `muted` that the hook passed the record
	// over.
	keys:      []core.Token,
	delim:     byte,
	no_header: bool,
	in_header: bool,
	open:      bool,
	muted:     bool,
	// Whether any block so far has held a quote byte. While it is false, a block with no quote uses the path with no
	// quote judgement and no quoted-field state.
	quoted:    bool,
	// `Options.tolerate`. The pass reads it at a block fault, at a record width check, and once per block in
	// `read_tokens`, for `lax`.
	tolerate:  bit_set[Tolerance; u8],
}

// Returns the CR bytes with no LF after them in `bad`, leaving out bit 63, whose CR the next block judges. `carried` is
// true when a CR from the block before has no LF at byte 0 here, and the fault is then at `pos - 1`.
@(private)
cr_fault :: #force_inline proc "contextless" (w: ^Pass($S, $H), cr, nl: u64) -> (bad: u64, carried: bool) {
	return cr & ~(nl >> 1) & ~(u64(1) << 63), w.cr & ~nl != 0
}

// Returns the block's bytes that are inside a comment line, and the LFs that end such a line. `starts` has a bit at
// each comment byte that begins a line outside a quoted field, and `in_comment` says the block starts inside a comment
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

// Scans the text in 64-byte blocks and returns the result word. With `$EMIT` false the hooked lane is compiled out, for
// `validate`, which records no positions or keys. With `$COMMENTS` false the comment-line work is compiled out.
@(private)
pass :: #force_inline proc "contextless" ($T: kernel.Tier, $S: Spec, $EMIT: bool, $COMMENTS: bool,
	src: []u8, lo: u64, opts: Options, h: ^$H, regs: ^core.Hook_Regs,
	$on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action),
	keys: []core.Token) -> u64 {
	base := raw_data(src)
	n := len(src)
	w := Pass(S, H) {
		n = n,
		h = h,
		keys = keys,
		delim = delimiter_of(S, opts),
		no_header = opts.no_header,
		tolerate = opts.tolerate,
		start = 1,
		line = 1,
		in_header = !opts.no_header,
	}
	hs := regs^
	delim := w.delim
	comment := opts.comment
	_ = comment
	// `hs` holds the hook's registers across the whole walk. It is written back to `regs` on every return path.
	defer regs^ = hs

	pos := int(core.text_start(src, lo))
	w.rec_lo, w.field_lo = pos, pos

	when EMIT {
		// The text's opening `Array` token, at `lo` with `n` 0. A hook that passes it over leaves the walk to
		// `judge`, which makes no tokens.
		switch emit(h, on, &hs, lo, 0, .Array, .Value, 0) {
		case .Next:
		case .Skip:
			return judge(src, lo, S, opts)
		case .Stop:
			return stopped(lo, 0)
		}
	}

	for pos < n {
		rem := n - pos
		b: kernel.Block
		valid: u64
		if rem >= 64 {
			b = kernel.load(base[pos:])
			valid = ~u64(0)
		} else {
			// The last block is partial and zero-padded. A zero byte is no delimiter, no quote and ASCII, and `valid`
			// clears the mask bits past the text's end.
			b = kernel.load_padded(T, src, pos)
			valid = u64(1) << u64(rem) - 1
		}

		seps, lfs, clfs: u64
		bs: u64
		cb: u64
		_ = cb
		fault := -1
		kind := core.Fault_Kind.Bad_Char
		detail := Detail.None
		when S == .Csv {
			m := kernel.pack_n([4]kernel.Block {
				kernel.eq(b, '"'),
				kernel.eq(b, delim),
				kernel.eq(b, '\n'),
				kernel.eq(b, '\r'),
			})
			q, d, nl, crm := m[0], m[1], m[2], m[3]
			// A comment line's bytes are text, they make no separator, open no quoted field and hold no CR, and its LF
			// still ends the line. Each run is cleared from `q`, `d` and `crm` before the next line start is judged,
			// so a quote in a comment line does not flip the quoted-field state.
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
					instr0: u64
					if w.quoted || q != 0 {
						instr0 = kernel.prefix_xor(T, q) ~ w.in_quote
					}
					live := remaining & ~instr0
					if live == 0 {
						break
					}
					s := live & -live
					run, lf := comment_span(nl, s, false)
					cb |= run
					clfs |= lf
					q &= ~run
					d &= ~run
					crm &= ~run
					remaining &~= s
				}
				w.comment = cb >> 63
			}
			// With no quote byte in this block and none in any earlier block, no quoted field is open, so every
			// separator is a delimiter or an LF, no quote placement needs judging, and `w.in_quote` stays clear.
			if !w.quoted && q == 0 {
				seps = d | nl
				lfs = nl
				bad, carried := cr_fault(&w, crm, nl)
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
					// `prefix_xor` of the quote mask marks the bytes inside quoted fields, an opening quote starts a
					// run and a closing quote ends it. Once a text has held a quote every block uses this path, because a
					// branch per block on its own quotes mispredicts on a text that quotes some cells and not others.
					instr = kernel.prefix_xor(T, q) ~ w.in_quote
					open := q & instr
					closing = q & ~instr
					seps = (d | nl) & ~instr
					lfs = nl & ~instr
					cr = crm & ~instr
					// A quote opens a field only at the cell's first byte. A closing quote may be followed only by a
					// quote that doubles it, the delimiter, LF, CR or the end of the text.
					after := closing << 1 | w.close
					bare = open & ~(seps << 1 | w.start | after)
					bad = bare | after & ~(q | d | nl | crm | ~valid)
					cr_bad, c := cr_fault(&w, cr, nl)
					bad |= cr_bad
					carried = c
					// Under `.Bare_Quote` a tolerated bare quote is no quote, and the block's quotes pair up again
					// without it.
					first := bad & -bad
					if bare & first == 0 || .Bare_Quote not_in w.tolerate {
						break
					}
					q &~= first
				}
				if carried {
					fault = pos - 1
				} else if bad != 0 {
					fault = pos + int(intrinsics.count_trailing_zeros(bad))
					if bare & (bad & -bad) != 0 {
						detail = .Bare_Quote
					}
				}
				// All ones when the block ended inside a quoted field, the mask the next block's run starts from.
				w.in_quote = u64(0) - (instr >> 63)
				w.start = seps >> 63
				w.close = closing >> 63
				w.cr = cr >> 63
			}
		} else {
			when S == .Tsv {
				m := kernel.pack_n([3]kernel.Block {
					kernel.eq(b, delim),
					kernel.eq(b, '\n'),
					kernel.eq(b, '\r'),
				})
				d, nl, crm := m[0], m[1], m[2]
				// A block with no backslash holds no escaped cell, so the mask is packed only for a block that holds
				// one. On arm64 `any_lane` is a horizontal maximum rather than the packing's lane fold.
				bsm := kernel.eq(b, '\\')
				if kernel.any_lane(bsm) {
					bs = kernel.pack(bsm)
				}
			} else {
				m := kernel.pack_n([3]kernel.Block {
					kernel.eq(b, delim),
					kernel.eq(b, '\n'),
					kernel.eq(b, '\r'),
				})
				d, nl, crm := m[0], m[1], m[2]
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
			bad, carried := cr_fault(&w, crm, nl)
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
					if at := escape_fault(src, pos, cb, &w.esc); at >= 0 && (fault < 0 || at < fault) {
						fault, kind = at, .Bad_Escape
					}
				}
			}
		}
		when COMMENTS {
			w.line = nl >> 63
		}

		// `bs` is unused in a `$EMIT` false build, where `read_cells` receives no backslash mask.
		_ = bs

		// UTF-8 is checked on a block with a byte past 0x7F, and on an ASCII block only when the block before left a
		// sequence open. `utf8_fault` searches back no further than `lo`.
		check := false
		if kernel.is_ascii(b) {
			if w.prev_high {
				kernel.utf8_ascii_block(T, &w.utf8)
				w.prev_high = false
				check = true
			}
		} else {
			kernel.utf8_block(T, b, &w.utf8)
			w.prev_high = true
			check = true
		}
		if check && !kernel.utf8_clean(T, w.utf8) && .Invalid_Utf8 not_in w.tolerate {
			if at, k := utf8_fault(src, int(lo), pos); at >= 0 && (fault < 0 || at < fault) {
				fault, kind = at, k
			}
		}

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
				return core.fault_at(u64(w.field_lo), .Too_Wide)
			}
			if r, done := read_tokens(COMMENTS, &w, base, pos, seps, lfs, clfs, bs, &hs, on); done {
				return r
			}
		} else {
			if r, done := read_cells(COMMENTS, &w, base, pos, seps, lfs, clfs); done {
				return r
			}
		}

		if fault >= 0 {
			return core.fault_at(u64(fault), kind, u8(detail))
		}
		pos += 64
	}

	// Faults that only the text's end shows, in text order. They are a CR or backslash left open by the last block, a
	// UTF-8 sequence left open, a quoted field never closed, then the last cell's width.
	if w.cr != 0 {
		return core.fault_at(u64(n - 1), .Bad_Char)
	}
	when S == .Tsv {
		if w.esc != 0 {
			return core.fault_at(u64(n - 1), .Bad_Escape)
		}
	}
	// A UTF-8 sequence the text cuts short is ill-formed, and `utf8_fault` reports it at `n`. An unclosed quoted field is
	// a separate `Truncated` fault at `n`.
	if w.prev_high && !kernel.utf8_ok(w.utf8) && .Invalid_Utf8 not_in w.tolerate {
		if at, k := utf8_fault(src, int(lo), n); at >= 0 {
			return core.fault_at(u64(at), k)
		}
	}
	when S == .Csv {
		if w.in_quote != 0 {
			return core.fault_at(u64(n), .Truncated)
		}
	}
	when EMIT {
		if n - w.field_lo > int(max(u32)) {
			return core.fault_at(u64(w.field_lo), .Too_Wide)
		}
	}

	// The record the text ends in, when no LF ends it. A text that ends inside a comment line ends in no record, the
	// whole last line is a comment whether or not it has a line end.
	last := w.rec_lo < n
	when COMMENTS {
		last = last && w.comment == 0
		if w.comment != 0 && w.rec_lo < n {
			switch emit(h, on, &hs, u64(w.rec_lo), u32(n - w.rec_lo), .Plain, .Comment, 1) {
			case .Next, .Skip:
			case .Stop:
				return stopped(u64(w.rec_lo), u32(n - w.rec_lo))
			}
		}
	}
	if last {
		when EMIT {
			if r, done := read_last_tokens(&w, base, &hs, on); done {
				return r
			}
		} else {
			if fault, _ := record_width(&w, w.cells + 1, &w.width); fault {
				return core.fault_at(u64(w.rec_lo), .Bad_Structure, u8(Detail.Field_Count))
			}
		}
	}

	when EMIT {
		if emit(h, on, &hs, u64(n), 0, .End, .Value, 0) == .Stop {
			return stopped(u64(n), 0)
		}
	}
	return core.fault_at(u64(n), .None)
}
