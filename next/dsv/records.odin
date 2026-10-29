package dsv

import "base:intrinsics"
import core "../core"

// The cells and records a block's separators end, for `validate`: the delimiters between two LFs are counted with
// `count_ones`, so a block pays per record, not per cell. `done` is set with the result of a width fault.
@(private)
read_cells :: #force_inline proc "contextless" (w: ^Pass($S, $H), base: [^]u8, pos: int, seps, lfs: u64) -> (r: u64, done: bool) {
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
		// A line that is empty, or holds only a CR, is no record: it sets no width and breaks none.
		if at != rec_lo && !(at == rec_lo + 1 && base[rec_lo] == '\r') {
			if width == 0 {
				width = cells + 1
			} else if cells + 1 != width && !ragged(w, cells + 1, width) {
				w.rec_lo, w.cells, w.width = rec_lo, cells, width
				return fault_at(rec_lo, .Bad_Structure, .Field_Count), true
			}
		}
		rec_lo, cells = at + 1, 0
	}
	w.rec_lo, w.cells, w.width = rec_lo, cells + int(intrinsics.count_ones(seps)), width
	return 0, false
}

// Whether `.Ragged` takes a record of `cells` cells in a text whose first has `width`: any width with no header,
// and fewer cells with one.
@(private)
ragged :: #force_inline proc "contextless" (w: ^Pass($S, $H), cells, width: int) -> bool {
	return .Ragged in w.tolerate && (w.no_header || cells < width)
}

// A column's header cell as the `Key` token its cell names it by. `Skip` asks for the cell's own token to be passed
// over and `Stop` ends the walk, and both come with the token's span. A cell past the header's last makes no token:
// its record is wider than the header and faults at its line end.
@(private)
put_key :: #force_inline proc "contextless" (h: ^$H, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, keys: []core.Token, cells: int) -> (a: core.Action, lo: u64, n: u32) {
	if cells < len(keys) {
		k := keys[cells]
		// A `Key` is always a `Plain` of role `Key`: passed as constants, a hook that tells tokens
		// apart by kind or role folds its whole call away for a header cell.
		return emit(h, on, hs, k.lo, k.n, .Plain, .Key, k.spelling), k.lo, k.n
	}
	return .Skip, 0, 0
}

// `put_key` for a run that has already proven it names one key per cell: no test of the key's index, which is the
// cell's own, per cell.
@(private)
put_key_n :: #force_inline proc "contextless" (h: ^$H, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, keys: []core.Token, cells: int) -> (a: core.Action, lo: u64, n: u32) {
	k := key_at(keys, cells)
	return emit(h, on, hs, k.lo, k.n, .Plain, .Key, k.spelling), k.lo, k.n
}

// A cell's own token, `Plain`, with its spelling.
@(private)
put_value :: #force_inline proc "contextless" (h: ^$H, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, base: [^]u8, field_lo, hi: int, $S: Spec) -> (a: core.Action, lo: u64, n: u32) {
	return emit(h, on, hs, u64(field_lo), u32(hi - field_lo), .Plain, .Value, spelling(base, field_lo, hi, S)), u64(field_lo), u32(hi - field_lo)
}

// A header cell as the `Key` token its column's cells name it by.
@(private)
key_of :: #force_inline proc "contextless" (base: [^]u8, field_lo, hi: int, $S: Spec) -> core.Token {
	return {u64(field_lo), u32(hi - field_lo), .Plain, .Key, spelling(base, field_lo, hi, S)}
}

// A cell's `Token.spelling`: 1 when it is quoted (CSV). A quoted cell's first byte is a quote, and an unquoted cell's
// never is: a quote at a cell's first byte opens a quoted field, and one anywhere else is refused or, under
// `.Bare_Quote`, a byte of the cell.
@(private)
spelling :: #force_inline proc "contextless" (base: [^]u8, field_lo, hi: int, $S: Spec) -> u16 {
	when S == .Csv {
		return u16(hi > field_lo && base[field_lo] == '"')
	} else {
		return 0
	}
}

// `keys[i]`, for a caller that has proven `i` is in the slice: a run's cell count against the keys left.
@(private)
key_at :: #force_inline proc "contextless" (keys: []core.Token, i: int) -> core.Token #no_bounds_check {
	return keys[i]
}

// One cell: its column's header cell as a `Key`, then the cell itself, for the record end's single cell where a
// header may or may not reach.
@(private)
put_cell :: #force_inline proc "contextless" (h: ^$H, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, base: [^]u8, keys: []core.Token, no_header: bool, cells: int, field_lo, hi: int, $S: Spec) -> (a: core.Action, lo: u64, n: u32) {
	if !no_header {
		k, klo, kn := put_key(h, on, hs, keys, cells)
		switch k {
		case .Next:
		case .Skip:
			return .Skip, klo, kn
		case .Stop:
			return .Stop, klo, kn
		}
	}
	return put_value(h, on, hs, base, field_lo, hi, S)
}

// The tokens a block's separators end, for `walk`. The separators before the block's next LF are the open record's
// delimiter cells, and they run through a loop of their own: it holds no LF test, no CR, no width and no `End`, and
// no test of the record's state, which is chosen once for the run. The record's last cell and its `End` are the
// outer loop's work, once per record.
@(private)
read_tokens :: #force_inline proc "contextless" (w: ^Pass($S, $H), base: [^]u8, pos: int, seps, lfs: u64, hs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (r: u64, done: bool) {
	// The open record's state lives in locals for the block: `Pass` is one struct, and a field read per cell is a
	// load per cell.
	rec_lo, field_lo, cells := w.rec_lo, w.field_lo, w.cells
	width := w.width
	h, keys := w.h, w.keys
	header, no_header, muted, open := w.in_header, w.no_header, w.muted, w.open
	m, lf := seps, lfs
	for m != 0 {
		// `k` is the block's next LF, or 64 when the rest of the block holds none: everything below it is a
		// delimiter of the open record.
		k := u64(64)
		if lf != 0 {
			k = intrinsics.count_trailing_zeros(lf)
		}
		d := m
		if k < 64 {
			// Parenthesised whole: `&` binds tighter than `-` here, so `m & (1 << k) - 1` would be a different mask.
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
			// The header record's cells are the `Key` tokens its columns' cells name them by.
			dm := d
			for dm != 0 {
				kk := intrinsics.count_trailing_zeros(dm)
				at := pos + int(kk)
				dm &= dm - 1
				if cells < len(keys) {
					keys[cells] = key_of(base, field_lo, at, S)
				}
				cells += 1
				field_lo = at + 1
			}
		} else if muted {
			// A hook passed this record over: its cells are still counted, and its bytes judged, but make no tokens.
			if d != 0 {
				cells += int(intrinsics.count_ones(d))
				field_lo = pos + 64 - int(intrinsics.count_leading_zeros(d))
			}
		} else if no_header {
			// No header: every cell is one `Plain`, and no key is named.
			dm := d
			for dm != 0 {
				kk := intrinsics.count_trailing_zeros(dm)
				at := pos + int(kk)
				dm &= dm - 1
				if a, lo, n := put_value(h, on, hs, base, field_lo, at, S); a == .Stop {
					return stopped(lo, n), true
				}
				cells += 1
				field_lo = at + 1
			}
		} else if cells + int(intrinsics.count_ones(d)) > len(keys) {
			// A record wider than the header, so wider than the keys: it faults at its own line end, so its cells
			// are counted and its bytes judged, and they make no tokens.
			if d != 0 {
				cells += int(intrinsics.count_ones(d))
				field_lo = pos + 64 - int(intrinsics.count_leading_zeros(d))
			}
		} else {
			// A data record's run of cells, each naming its column's header cell: one key per cell, proven once.
			// The run is counted once, so a hook that reads no key keeps no index per cell.
			dm, key := d, cells
			for dm != 0 {
				kk := intrinsics.count_trailing_zeros(dm)
				at := pos + int(kk)
				dm &= dm - 1
				if k, klo, kn := put_key_n(h, on, hs, keys, key); k == .Stop {
					return stopped(klo, kn), true
				} else if k == .Next {
					if a, lo, n := put_value(h, on, hs, base, field_lo, at, S); a == .Stop {
						return stopped(lo, n), true
					}
				}
				key += 1
				field_lo = at + 1
			}
			cells += int(intrinsics.count_ones(d))
		}
		if k == 64 {
			break
		}
		// The LF that ends the record, and the cell it ends. The CR of a CRLF is the line end's, not the cell's, so
		// it leaves the cell's span and gives the record's `End` its second byte.
		at := pos + int(k)
		hi := at
		if at > field_lo && base[at - 1] == '\r' {
			hi = at - 1
		}
		if !open {
			// A line that is empty, or holds only a CR, is no record: no token, and no width.
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
		if header {
			if cells < len(keys) {
				keys[cells] = key_of(base, field_lo, hi, S)
			}
		} else if !muted {
			a, lo, n := put_cell(h, on, hs, base, keys, no_header, cells, field_lo, hi, S)
			if a == .Stop {
				return stopped(lo, n), true
			}
		}
		cells += 1
		field_lo = at + 1
		if width == 0 {
			width = cells
		} else if cells != width && !ragged(w, cells, width) {
			return fault_at(rec_lo, .Bad_Structure, .Field_Count), true
		}
		if !muted && !header {
			if emit(h, on, hs, u64(hi), u32(at + 1 - hi), .End, .Value, 0) == .Stop {
				return stopped(u64(hi), u32(at + 1 - hi)), true
			}
		}
		rec_lo, cells, open, muted = at + 1, 0, false, false
		header = false
		// The delimiters of the record that ended, and its LF.
		m &= ~d
		m &= m - 1
		lf &= lf - 1
	}
	w.rec_lo, w.field_lo, w.cells, w.width = rec_lo, field_lo, cells, width
	w.in_header, w.muted, w.open = header, muted, open
	return 0, false
}

// The tokens of the record the text ends in, which no LF ends: its opening token, its open cell, and an `End` of no
// bytes at the text's end.
@(private)
read_last_tokens :: #force_inline proc "contextless" (w: ^Pass($S, $H), base: [^]u8, hs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (r: u64, done: bool) {
	// A trailing CR is a fault already reported, so this record holds a cell.
	if w.width == 0 {
		w.width = w.cells + 1
	} else if w.cells + 1 != w.width && !ragged(w, w.cells + 1, w.width) {
		return fault_at(w.rec_lo, .Bad_Structure, .Field_Count), true
	}
	hi := w.n
	if w.in_header {
		if w.cells < len(w.keys) {
			w.keys[w.cells] = key_of(base, w.field_lo, hi, S)
		}
		return 0, false
	}
	if w.muted {
		return 0, false
	}
	if !w.open {
		w.open = true
		switch emit(w.h, on, hs, u64(w.rec_lo), 0, w.no_header ? .Array : .Map, .Value, 0) {
		case .Next:
		case .Skip:
			w.muted = true
			return 0, false
		case .Stop:
			return stopped(u64(w.rec_lo), 0), true
		}
	}
	if a, lo, n := put_cell(w.h, on, hs, base, w.keys, w.no_header, w.cells, w.field_lo, hi, S); a == .Stop {
		return stopped(lo, n), true
	}
	if emit(w.h, on, hs, u64(hi), 0, .End, .Value, 0) == .Stop {
		return stopped(u64(hi), 0), true
	}
	return 0, false
}
