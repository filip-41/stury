package dsv

import "base:intrinsics"
import core "../core"

// Counts the cells and records that a block's separators end, for `validate`. The delimiters between two LFs are
// counted with `count_ones`, so the work is per record, not per cell. `done` is true with `r` set when a width fault
// ends the walk.
@(private)
read_cells :: #force_inline proc "contextless" ($COMMENTS: bool, w: ^Pass($S, $H), base: [^]u8, pos: int, seps, lfs, clfs: u64) -> (r: u64, done: bool) {
	rec_lo, cells, width := w.rec_lo, w.cells, w.width
	seps, m := seps, lfs
	for m != 0 {
		k := u64(intrinsics.count_trailing_zeros(m))
		m &= m - 1
		before := u64(1) << k - 1
		cells += int(intrinsics.count_ones(seps & before))
		seps &= ~before
		seps &= seps - 1
		at := pos + int(k)
		// An empty line, a line holding only a CR, and a comment line are no records, they set no width and do not
		// break one.
		comment := false
		when COMMENTS {
			comment = clfs & (u64(1) << k) != 0
		}
		if !comment && at != rec_lo && !(at == rec_lo + 1 && base[rec_lo] == '\r') {
			if fault, _ := record_width(w, cells + 1, &width); fault {
				w.rec_lo, w.cells, w.width = rec_lo, cells, width
				return core.fault_at(u64(rec_lo), .Bad_Structure, u8(Detail.Field_Count)), true
			}
		}
		rec_lo, cells = at + 1, 0
	}
	w.rec_lo, w.cells, w.width = rec_lo, cells + int(intrinsics.count_ones(seps)), width
	return 0, false
}

// Whether `.Ragged` accepts a record of `cells` cells in a text whose first record has `width` cells. With no header
// any count is accepted, with a header only a count below `width`.
@(private)
ragged :: #force_inline proc "contextless" (w: ^Pass($S, $H), cells, width: int) -> bool {
	return .Ragged in w.tolerate && (w.no_header || cells < width)
}

// Sets `width` from the first record. A later record of `cells` cells that differs from `width` faults unless `.Ragged`
// accepts it, and `fault` is then true. `wide` is true when `cells` is above `width`, whose fault is at the delimiter
// past the width.
@(private)
record_width :: #force_inline proc "contextless" (w: ^Pass($S, $H), cells: int, width: ^int) -> (fault: bool, wide: bool) {
	if width^ == 0 {
		width^ = cells
		return
	}
	if cells != width^ && !ragged(w, cells, width^) {
		return true, cells > width^
	}
	return
}

// Emits a column's header cell as the `Key` token its cell names it by, and returns the hook's action with the token's
// span. A `Stop` ends the walk. The width check refuses a record wider than the header before this runs, so `cells` is
// below `len(keys)` and a cell with no key is `unreachable`, not a dropped cell.
@(private)
put_key :: #force_inline proc "contextless" (h: ^$H, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, keys: []core.Token, cells: int) -> (a: core.Action, lo: u64, n: u32) {
	if cells < 0 || cells >= len(keys) {
		unreachable()
	}
	k := key_at(keys, cells)
	// A `Key` is always a `Plain` of role `Key`. Both are passed as constants, so a hook that tells tokens apart by
	// kind or role folds its whole call away for a header cell.
	return emit(h, on, hs, k.lo, k.n, .Plain, .Key, k.spelling), k.lo, k.n
}

// `put_key` without the index test, for a run whose cells are known to be below `width`, one key per cell.
@(private)
put_key_n :: #force_inline proc "contextless" (h: ^$H, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, keys: []core.Token, cells: int) -> (a: core.Action, lo: u64, n: u32) {
	k := key_at(keys, cells)
	return emit(h, on, hs, k.lo, k.n, .Plain, .Key, k.spelling), k.lo, k.n
}

// Emits a cell as a `Plain` value token with its spelling, and returns the action with the token's span.
@(private)
put_value :: #force_inline proc "contextless" (h: ^$H, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, base: [^]u8, field_lo, hi: int, esc, lax: bool, $S: Spec) -> (a: core.Action, lo: u64, n: u32) {
	return emit(h, on, hs, u64(field_lo), u32(hi - field_lo), .Plain, .Value, spelling(base, field_lo, hi, esc, lax, S)), u64(field_lo), u32(hi - field_lo)
}

// A header cell from `field_lo` to `hi` as a `Plain` token of role `Key`.
@(private)
key_of :: #force_inline proc "contextless" (base: [^]u8, field_lo, hi: int, esc, lax: bool, $S: Spec) -> core.Token {
	return {u64(field_lo), u32(hi - field_lo), .Plain, .Key, spelling(base, field_lo, hi, esc, lax, S)}
}

// Stores the header cell from `field_lo` to `hi` at `keys[cells]` when `cells` is below `len(keys)`. A buffer sized
// from `header_cells` holds every header cell.
@(private)
put_header_key :: #force_inline proc "contextless" (keys: []core.Token, cells: int, base: [^]u8, field_lo, hi: int, esc, lax: bool, $S: Spec) {
	if cells < len(keys) {
		keys[cells] = key_of(base, field_lo, hi, esc, lax, S)
	}
}

// A cell's `Token.spelling`. Bit 0 (`SPELLING_DECODE`) says `text` must decode the cell, bit 1 (`SPELLING_QUOTED`) that
// it is a quoted CSV cell. A quoted cell's first byte is a quote, and an unquoted cell's never is, since a quote at a
// cell's first byte opens a quoted field and one anywhere else is refused or, under `.Bare_Quote`, a cell byte. A TSV
// cell sets bit 0 when its span holds a backslash, which the pass's block mask answers, or when `lax` is set.
@(private)
spelling :: #force_inline proc "contextless" (base: [^]u8, field_lo, hi: int, esc, lax: bool, $S: Spec) -> u16 {
	when S == .Csv {
		quoted := hi > field_lo && base[field_lo] == '"'
		if quoted {
			return core.SPELLING_DECODE | core.SPELLING_QUOTED
		}
		// An unquoted cell is its span, decoded under `lax` so an ill-formed sequence can read as U+FFFD.
		return core.SPELLING_DECODE if lax else 0
	} else {
		return core.SPELLING_DECODE if esc || lax else 0
	}
}

// The bits of a block mask for the byte offsets `[lo, hi)`, with `lo` and `hi` from 0 to 64. Returns 0 when `lo >= hi`.
@(private)
bits_between :: #force_inline proc "contextless" (lo, hi: int) -> u64 {
	if lo >= hi {
		return 0
	}
	all := ~u64(0)
	hi_bits: u64
	if hi < 64 {
		hi_bits = all << u64(hi)
	}
	return (all << u64(lo)) & ~hi_bits
}

// Whether the cell from `field_lo` to `hi` holds a backslash, read from the block's mask `bs`. `carry` covers the part
// of a cell that opened in an earlier block. With `bs` 0 the answer is `carry` for a cell that opened before `pos`.
@(private)
span_esc :: #force_inline proc "contextless" (bs: u64, pos, field_lo, hi: int, carry: bool) -> bool {
	if bs == 0 {
		return carry && field_lo < pos
	}
	lo := field_lo - pos
	if lo < 0 {
		return carry || bs & bits_between(0, hi - pos) != 0
	}
	return bs & bits_between(lo, hi - pos) != 0
}

// `keys[i]` with no bounds check, for a caller that has proven `i < len(keys)`.
@(private)
key_at :: #force_inline proc "contextless" (keys: []core.Token, i: int) -> core.Token #no_bounds_check {
	return keys[i]
}

// Emits a cell's column key (unless `no_header`) and then the cell's value. Used for the last cell of a record, whose
// key index is the record's cell count.
@(private)
put_cell :: #force_inline proc "contextless" (h: ^$H, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, base: [^]u8, keys: []core.Token, no_header: bool, cells: int, field_lo, hi: int, esc, lax: bool, $S: Spec) -> (a: core.Action, lo: u64, n: u32) {
	if !no_header {
		k, klo, kn := put_key(h, on, hs, keys, cells)
		switch k {
		case .Next:
		case .Skip:
			// The hook passed this key over, so its cell's value is passed over too.
			return .Skip, klo, kn
		case .Stop:
			return .Stop, klo, kn
		}
	}
	return put_value(h, on, hs, base, field_lo, hi, esc, lax, S)
}

// Emits the first `width` cells of a record wider than `width`, then returns the fault at the delimiter that opens cell
// `width`. Such a record does not reach the returning caller. With `$KEYS` set the record is headed, so each cell has a
// `Key` before it, else each cell is a `Plain` value. A caller with no header passes `keys` nil.
@(private, cold)
read_wide :: #force_no_inline proc "contextless" ($KEYS: bool, h: ^$H, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, base: [^]u8, keys: []core.Token, pos: int, d: u64, cells, field_lo, width: int, bs: u64, carry, lax: bool, $S: Spec) -> u64 {
	cells, field_lo := cells, field_lo
	dm := d
	for dm != 0 {
		kk := intrinsics.count_trailing_zeros(dm)
		at := pos + int(kk)
		dm &= dm - 1
		esc := false
		when S == .Tsv {
			esc = span_esc(bs, pos, field_lo, at, carry)
		}
		if KEYS {
			// `cells` is the cell's own count and its column's index.
			k, klo, kn := put_key_n(h, on, hs, keys, cells)
			if k == .Stop {
				return stopped(klo, kn)
			} else if k == .Next {
				if a, lo, n := put_value(h, on, hs, base, field_lo, at, esc, lax, S); a == .Stop {
					return stopped(lo, n)
				}
			}
		} else if a, lo, n := put_value(h, on, hs, base, field_lo, at, esc, lax, S); a == .Stop {
			return stopped(lo, n)
		}
		field_lo = at + 1
		cells += 1
		if cells == width {
			return core.fault_at(u64(at), .Bad_Structure, u8(Detail.Field_Count))
		}
	}
	unreachable()
}

// Emits a run of a record's cells as `Plain` values. `$ESC` compiles the TSV backslash test in or out, chosen per block
// by `plain_block`.
@(private)
values_run :: #force_inline proc "contextless" ($ESC: bool, h: ^$H, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, base: [^]u8, pos: int, d: u64, field_lo, cells: int, bs: u64, carry, lax: bool, $S: Spec) -> (field_lo2, cells2: int, r: u64, done: bool) {
	dm := d
	field_lo2, cells2 = field_lo, cells
	for dm != 0 {
		kk := intrinsics.count_trailing_zeros(dm)
		at := pos + int(kk)
		dm &= dm - 1
		esc := false
		when ESC {
			when S == .Tsv {
				esc = span_esc(bs, pos, field_lo2, at, carry)
			}
		}
		if a, lo, n := put_value(h, on, hs, base, field_lo2, at, esc, lax, S); a == .Stop {
			return field_lo2, cells2, stopped(lo, n), true
		}
		cells2 += 1
		field_lo2 = at + 1
	}
	return
}

// `values_run` for a headed record, one `Key` before each value. `cells2` is the cell's own count and its column's
// index, so the run keeps no other counter.
@(private)
keys_run :: #force_inline proc "contextless" ($ESC: bool, h: ^$H, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, base: [^]u8, keys: []core.Token, pos: int, d: u64, field_lo, cells: int, bs: u64, carry, lax: bool, $S: Spec) -> (field_lo2, cells2: int, r: u64, done: bool) {
	dm := d
	field_lo2, cells2 = field_lo, cells
	for dm != 0 {
		kk := intrinsics.count_trailing_zeros(dm)
		at := pos + int(kk)
		dm &= dm - 1
		esc := false
		when ESC {
			when S == .Tsv {
				esc = span_esc(bs, pos, field_lo2, at, carry)
			}
		}
		if k, klo, kn := put_key_n(h, on, hs, keys, cells2); k == .Stop {
			return field_lo2, cells2, stopped(klo, kn), true
		} else if k == .Next {
			if a, lo, n := put_value(h, on, hs, base, field_lo2, at, esc, lax, S); a == .Stop {
				return field_lo2, cells2, stopped(lo, n), true
			}
		}
		cells2 += 1
		field_lo2 = at + 1
	}
	return
}

// Emits the tokens a block's separators end. The delimiters before the block's next LF are the open record's cells and
// run through a loop of their own, which holds no LF test, no CR, no width check and no `End`, and chooses the record's
// state once per run. The record's last cell and its `End` are the outer loop's work, once per record.
@(private)
read_tokens :: #force_inline proc "contextless" ($COMMENTS: bool, w: ^Pass($S, $H), base: [^]u8, pos: int, seps, lfs, clfs, bs: u64, hs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (r: u64, done: bool) {
	// The open record's state is copied into locals for the block, since a field read per cell is a load per cell.
	// `carry` is whether the cell open at the block's start holds a backslash from an earlier block.
	rec_lo, field_lo, cells := w.rec_lo, w.field_lo, w.cells
	width := w.width
	h, keys := w.h, w.keys
	header, no_header, muted, open := w.in_header, w.no_header, w.muted, w.open
	carry := w.field_esc
	// A block with no backslash mask and no carry has no cell that starts in it with an escape, which is almost every
	// block, so the runs below take `$ESC` false and the range work is a branch per block, not per cell.
	plain_block := bs == 0 && !carry
	lax := .Invalid_Utf8 in w.tolerate
	m, lf := seps, lfs
	for m != 0 {
		// `k` is the block's next LF, or 64 when the rest of the block holds none. The separators below `k` are
		// delimiters of the open record.
		k := u64(64)
		if lf != 0 {
			k = intrinsics.count_trailing_zeros(lf)
		}
		d := m
		if k < 64 {
			// The parentheses matter, `&` binds tighter than `-`, so `m & (1 << k) - 1` would be a different mask.
			d = m & ((u64(1) << k) - 1)
		}
		if !open && d != 0 {
			open = true
			if !muted && !header {
				switch emit(h, on, hs, u64(rec_lo), 0, no_header ? .Array : .Map, .Value, 0) {
				case .Next:
				case .Skip:
					muted = true
				case .Stop:
					return stopped(u64(rec_lo), 0), true
				}
			}
		}
		if header {
			// The header record's cells are written as the `Key` tokens its columns' cells name them by.
			dm := d
			for dm != 0 {
				kk := intrinsics.count_trailing_zeros(dm)
				at := pos + int(kk)
				dm &= dm - 1
				esc := false
				when S == .Tsv {
					if !plain_block {
						esc = span_esc(bs, pos, field_lo, at, carry)
					}
				}
				put_header_key(keys, cells, base, field_lo, at, esc, lax, S)
				cells += 1
				field_lo = at + 1
			}
		} else if muted {
			// The hook passed this record over, so its cells are counted and its bytes judged, but make no tokens.
			if d != 0 {
				if width != 0 && !(.Ragged in w.tolerate && no_header) && cells + int(intrinsics.count_ones(d)) >= width {
					return core.fault_at(u64(scan_record(base[:w.n], rec_lo, width, S, w.delim).fault_at), .Bad_Structure, u8(Detail.Field_Count)), true
				}
				cells += int(intrinsics.count_ones(d))
				field_lo = pos + 64 - int(intrinsics.count_leading_zeros(d))
			}
		} else if no_header {
			// No header, so every cell is a `Plain` value and no key is emitted.
			if width != 0 && .Ragged not_in w.tolerate && cells + int(intrinsics.count_ones(d)) >= width {
				return read_wide(false, h, on, hs, base, nil, pos, d, cells, field_lo, width, bs, carry, lax, S), true
			}
			rr: u64
			dd: bool
			if plain_block {
				field_lo, cells, rr, dd = values_run(false, h, on, hs, base, pos, d, field_lo, cells, bs, carry, lax, S)
			} else {
				field_lo, cells, rr, dd = values_run(true, h, on, hs, base, pos, d, field_lo, cells, bs, carry, lax, S)
			}
			if dd {
				return rr, true
			}
		} else if cells + int(intrinsics.count_ones(d)) >= width {
			return read_wide(true, h, on, hs, base, keys, pos, d, cells, field_lo, width, bs, carry, lax, S), true
		} else {
			// A data record's run of cells, each after its column's key. The cell's own count is the key's index, and
			// the run advances that count only.
			rr: u64
			dd: bool
			if plain_block {
				field_lo, cells, rr, dd = keys_run(false, h, on, hs, base, keys, pos, d, field_lo, cells, bs, carry, lax, S)
			} else {
				field_lo, cells, rr, dd = keys_run(true, h, on, hs, base, keys, pos, d, field_lo, cells, bs, carry, lax, S)
			}
			if dd {
				return rr, true
			}
		}
		if k == 64 {
			break
		}
		// The LF that ends the record, and the cell it ends. The CR of a CR LF belongs to the line end, so it leaves
		// the cell's span and becomes the second byte of the record's `End`.
		at := pos + int(k)
		hi := at
		if at > field_lo && base[at - 1] == '\r' {
			hi = at - 1
		}
		comment := false
		when COMMENTS {
			comment = clfs & (u64(1) << k) != 0
		}
		if comment {
			// A comment line is no record, it makes only its own `Comment` token, sets no width, and the line after it
			// starts fresh. Its span leaves out the CR of a CR LF, which belongs to the line end.
			end := at
			if at > rec_lo && base[at - 1] == '\r' {
				end = at - 1
			}
			switch emit(h, on, hs, u64(rec_lo), u32(end - rec_lo), .Plain, .Comment, 1) {
			case .Next, .Skip:
			case .Stop:
				return stopped(u64(rec_lo), u32(end - rec_lo)), true
			}
			rec_lo, field_lo = at + 1, at + 1
			m &= ~d
			m &= m - 1
			lf &= lf - 1
			continue
		}
		if !open {
			// An empty line, or a line holding only a CR, is no record, it makes no token and sets no width.
			if hi == rec_lo {
				rec_lo, field_lo = at + 1, at + 1
				m &= ~d
				m &= m - 1
				lf &= lf - 1
				continue
			}
			open = true
			if !muted && !header {
				switch emit(h, on, hs, u64(rec_lo), 0, no_header ? .Array : .Map, .Value, 0) {
				case .Next:
				case .Skip:
					muted = true
				case .Stop:
					return stopped(u64(rec_lo), 0), true
				}
			}
		}
		esc := false
		when S == .Tsv {
			if !plain_block {
				esc = span_esc(bs, pos, field_lo, at, carry)
			}
		}
		if header {
			put_header_key(keys, cells, base, field_lo, hi, esc, lax, S)
		} else if !muted {
			a, lo, n := put_cell(h, on, hs, base, keys, no_header, cells, field_lo, hi, esc, lax, S)
			if a == .Stop {
				return stopped(lo, n), true
			}
		}
		cells += 1
		field_lo = at + 1
		if fault, wide := record_width(w, cells, &width); fault {
			if wide {
				return core.fault_at(u64(scan_record(base[:w.n], rec_lo, width, S, w.delim).fault_at), .Bad_Structure, u8(Detail.Field_Count)), true
			}
			return core.fault_at(u64(hi), .Bad_Structure, u8(Detail.Field_Count)), true
		}
		if !muted && !header {
			if emit(h, on, hs, u64(hi), u32(at + 1 - hi), .End, .Value, 0) == .Stop {
				return stopped(u64(hi), u32(at + 1 - hi)), true
			}
		}
		rec_lo, cells, open, muted = at + 1, 0, false, false
		header = false
		// Clears the delimiters of the record that ended, and its LF, from the masks.
		m &= ~d
		m &= m - 1
		lf &= lf - 1
	}
	w.rec_lo, w.field_lo, w.cells, w.width = rec_lo, field_lo, cells, width
	w.in_header, w.muted, w.open = header, muted, open
	// The cell still open at the block's end carries its backslash state into the next block, as `field_esc`.
	w.field_esc = false
	when S == .Tsv {
		if !plain_block {
			w.field_esc = span_esc(bs, pos, field_lo, pos + 64, carry)
		}
	}
	return 0, false
}

// Emits the tokens of the record the text ends in, which no LF ends. It emits its opening token, its open cell, and an
// `End` of `n` 0 at the text's end.
@(private)
read_last_tokens :: #force_inline proc "contextless" (w: ^Pass($S, $H), base: [^]u8, hs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (r: u64, done: bool) {
	// A trailing CR is a fault already reported, so this record holds a cell. A last record wider than `width` returns
	// the fault from `scan_record` before any token. A short one emits its tokens, then faults at the text's end.
	if !w.in_header && w.width != 0 && w.cells + 1 > w.width && !ragged(w, w.cells + 1, w.width) {
		return core.fault_at(u64(scan_record(base[:w.n], w.rec_lo, w.width, S, w.delim).fault_at), .Bad_Structure, u8(Detail.Field_Count)), true
	}
	hi := w.n
	esc := w.field_esc
	if w.in_header {
		put_header_key(w.keys, w.cells, base, w.field_lo, hi, esc, (.Invalid_Utf8 in w.tolerate), S)
		return 0, false
	}
	if !w.muted && !w.open {
		w.open = true
		switch emit(w.h, on, hs, u64(w.rec_lo), 0, w.no_header ? .Array : .Map, .Value, 0) {
		case .Next:
		case .Skip:
			w.muted = true
		case .Stop:
			return stopped(u64(w.rec_lo), 0), true
		}
	}
	if !w.muted {
		if a, lo, n := put_cell(w.h, on, hs, base, w.keys, w.no_header, w.cells, w.field_lo, hi, esc, (.Invalid_Utf8 in w.tolerate), S); a == .Stop {
			return stopped(lo, n), true
		}
	}
	if fault, _ := record_width(w, w.cells + 1, &w.width); fault {
		return core.fault_at(u64(hi), .Bad_Structure, u8(Detail.Field_Count)), true
	}
	if !w.muted {
		if emit(w.h, on, hs, u64(hi), 0, .End, .Value, 0) == .Stop {
			return stopped(u64(hi), 0), true
		}
	}
	return 0, false
}
