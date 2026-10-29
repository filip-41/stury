package dsv

import "base:intrinsics"
import core "../core"
import kernel "../core/kernel"

// What the blocks and the open record carry from one block to the next. `rec_lo` is the first byte of the record
// holding the cursor, `field_lo` the first byte of its open cell, and `cells` the cells it has ended. `width` is the
// first record's cell count, 0 until a record sets it. A record is opened when its first separator is read, since a
// line that is empty, or holds only a CR, is no record: it makes no tokens and sets no width.
@(private)
Pass :: struct($S: Spec, $H: typeid) {
	n:         int,
	h:         ^H,
	// The last block's open runs: inside a quoted field, after a separator, right after a closing quote, in a CR, in
	// a backslash.
	// `prev_high` is whether the last block held a byte past 0x7F, whose sequence this block may continue.
	in_quote:  u64,
	start:     u64,
	close:     u64,
	cr:        u64,
	esc:       u64,
	prev_high: bool,
	utf8:      kernel.Utf8_State,
	rec_lo:    int,
	field_lo:  int,
	cells:     int,
	width:     int,
	// The hooked lane: the header's cells as the `Key` tokens a data cell names its column with, whether the text
	// has a header, whether the header is the record being read, whether the open record has made its opening
	// token, and whether its tokens are passed over.
	keys:      []core.Token,
	no_header: bool,
	in_header: bool,
	open:      bool,
	muted:     bool,
	// Whether a block of the text has held a quote byte. A text whose blocks have held none holds no quoted field,
	// so its blocks need no quote judgement and its quoted-field state stays clear.
	quoted:    bool,
}

// The one pass. `$EMIT` false compiles the hooked lane out: `validate` then touches no positions and no keys.
@(private)
pass :: #force_inline proc "contextless" ($T: kernel.Tier, $S: Spec, $EMIT: bool,
	src: []u8, lo: u64, opts: Options, h: ^$H, regs: ^core.Hook_Regs,
	$on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action),
	keys: []core.Token) -> u64 {
	base := raw_data(src)
	n := len(src)
	w := Pass(S, H) {
		n = n,
		h = h,
		keys = keys,
		no_header = opts.no_header,
		start = 1,
		in_header = !opts.no_header,
	}
	hs := regs^
	// The hook's registers come back with every token and are written once, whichever way the walk ends.
	defer regs^ = hs

	pos := int(core.text_start(src, lo))
	w.rec_lo, w.field_lo = pos, pos

	when EMIT {
		// The text is one `Array`, opened at its first byte and closed at its end. Passed over, it is only judged.
		switch emit(h, on, &hs, lo, 0, .Array, .Value, 0) {
		case .Next:
		case .Skip:
			return judge(src, lo, S)
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
			// The last, partial block, zero-padded: a zero is no delimiter, no quote and ASCII, and `valid` clears
			// what the masks make of the lanes past the text anyway.
			b = kernel.load_padded(T, src, pos)
			valid = u64(1) << u64(rem) - 1
		}

		seps, lfs: u64
		fault := -1
		kind := core.Fault_Kind.Bad_Char
		when S == .Csv {
			m := kernel.pack_n([4]kernel.Block {
				kernel.eq(b, '"'),
				kernel.eq(b, ','),
				kernel.eq(b, '\n'),
				kernel.eq(b, '\r'),
			})
			q, d, nl, crm := m[0], m[1], m[2], m[3]
			// A text whose blocks have held no quote byte, and whose block holds none, holds no quoted field: every
			// separator is a delimiter or an LF, no quote's placement needs judging, and the state that carries a
			// quoted field across blocks stays clear.
			if !w.quoted && q == 0 {
				seps = d | nl
				lfs = nl
				// A CR is judged with the byte after it: the one in bit 63 is the next block's.
				bad := crm & ~(nl >> 1) & ~(u64(1) << 63)
				if w.cr & ~nl != 0 {
					fault = pos - 1
				} else if bad != 0 {
					fault = pos + int(intrinsics.count_trailing_zeros(bad))
				}
				w.start = seps >> 63
				w.cr = crm >> 63
			} else {
				w.quoted = true
				// The bytes inside quoted fields, from the quotes: an opening quote flips the run on, a closing off.
				// Once a text has held a quote, every block takes this way: a branch per block on its own quotes
				// mispredicts on a text that quotes some cells and not others.
				instr := kernel.prefix_xor(T, q) ~ w.in_quote
				open := q & instr
				closing := q & ~instr
				seps = (d | nl) & ~instr
				lfs = nl & ~instr
				cr := crm & ~instr
				// A quote opens a field only at its first byte, and a closing quote may be followed only by a quote
				// that doubles it, the delimiter, LF, CR, or the end of the text.
				after := closing << 1 | w.close
				bad := open & ~(seps << 1 | w.start | after)
				bad |= after & ~(q | d | nl | crm | ~valid)
				// A CR is judged with the byte after it: the one in bit 63 is the next block's.
				bad |= cr & ~(nl >> 1) & ~(u64(1) << 63)
				if w.cr & ~nl != 0 {
					fault = pos - 1
				} else if bad != 0 {
					fault = pos + int(intrinsics.count_trailing_zeros(bad))
				}
				// All ones when the block ended inside a quoted field: the mask the next block's run starts from.
				w.in_quote = u64(0) - (instr >> 63)
				w.start = seps >> 63
				w.close = closing >> 63
				w.cr = cr >> 63
			}
		} else {
			m := kernel.pack_n([4]kernel.Block {
				kernel.eq(b, '\t'),
				kernel.eq(b, '\n'),
				kernel.eq(b, '\r'),
				kernel.eq(b, '\\'),
			})
			d, nl, crm, bs := m[0], m[1], m[2], m[3]
			seps = d | nl
			lfs = nl
			bad := crm & ~(nl >> 1) & ~(u64(1) << 63)
			if w.cr & ~nl != 0 {
				fault = pos - 1
			} else if bad != 0 {
				fault = pos + int(intrinsics.count_trailing_zeros(bad))
			}
			w.cr = crm >> 63
			// A backslash opens one of the five escapes, and any other byte after it is a fault at the backslash.
			if bs != 0 || w.esc != 0 {
				if at := escape_fault(src, pos, &w.esc); at >= 0 && (fault < 0 || at < fault) {
					fault, kind = at, .Bad_Escape
				}
			}
		}

		// UTF-8: a block whose bytes are all ASCII can hold only the fault a sequence of the block before left open,
		// which only that block's judgement shows. The search for a fault reaches back no further than the walk's
		// first byte.
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
		if check && !kernel.utf8_clean(T, w.utf8) {
			if at, k := utf8_fault(src, int(lo), pos); at >= 0 && (fault < 0 || at < fault) {
				fault, kind = at, k
			}
		}

		// A fault stops the read at its byte: the separators past it are no separators, so no line that reaches it is
		// judged and no cell of one is read.
		if fault >= 0 {
			cut := u64(1) << u64(max(fault - pos, 0)) - 1
			seps &= cut
			lfs &= cut
		}

		when EMIT {
			// Every cell the block ends but the one open at its start is shorter than the block, and that one can be
			// longer than `Token.n` holds only if it opened that far before the block's end.
			if pos - w.field_lo > int(max(u32)) - 64 && cell_too_wide(base, w.field_lo, pos, seps) {
				return fault_at(w.field_lo, .Too_Wide)
			}
			if r, done := read_tokens(&w, base, pos, seps, lfs, &hs, on); done {
				return r
			}
		} else {
			if r, done := read_cells(&w, base, pos, seps, lfs); done {
				return r
			}
		}

		if fault >= 0 {
			return fault_at(fault, kind)
		}
		pos += 64
	}

	// What only the text's end shows, in text order: a CR or a backslash the last block left open, a UTF-8 sequence
	// left open, a quoted field that never closed, then the last cell's width.
	if w.cr != 0 {
		return fault_at(n - 1, .Bad_Char)
	}
	when S == .Tsv {
		if w.esc != 0 {
			return fault_at(n - 1, .Bad_Escape)
		}
	}
	if w.prev_high && !kernel.utf8_ok(w.utf8) {
		if at, k := utf8_fault(src, int(lo), n); at >= 0 {
			return fault_at(at, k)
		}
	}
	when S == .Csv {
		if w.in_quote != 0 {
			return fault_at(n, .Truncated)
		}
	}
	when EMIT {
		if n - w.field_lo > int(max(u32)) {
			return fault_at(w.field_lo, .Too_Wide)
		}
	}

	// The record the text ends in, when no LF ends it.
	if w.rec_lo < n {
		when EMIT {
			if r, done := read_last_tokens(&w, base, &hs, on); done {
				return r
			}
		} else {
			if w.width == 0 {
				w.width = w.cells + 1
			} else if w.cells + 1 != w.width {
				return fault_at(w.rec_lo, .Bad_Structure, .Field_Count)
			}
		}
	}

	when EMIT {
		if emit(h, on, &hs, u64(n), 0, .End, .Value, 0) == .Stop {
			return stopped(u64(n), 0)
		}
	}
	return fault_at(n, NO_FAULT)
}
