package dsv

import "base:intrinsics"
import "stury:lib/core/hook"

// What a validate's pass counts instead of giving tokens: the cells and records a block's separators end, and the
// width the records are checked against.

// Counts the cells and records that a block's separators end, for a validate. The delimiters between two LFs are
// counted with `count_ones`, so the work is per record, not per cell. `done` is true when a width fault ends the walk.
@(private)
read_cells :: #force_inline proc "contextless" ($COMMENTS: bool, w: ^Pass($S, $H, $LAX, $C), rs: ^Cells_State, base: [^]u8, pos: int, seps, lfs, clfs: u64) -> (r: hook.Walk_Result, done: bool) {
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
		// An empty line, a line holding only a CR, and a comment line are no records: they set no width and do not
		// break one.
		comment := false
		when COMMENTS {
			comment = clfs & (u64(1) << k) != 0
		}
		if !comment && at != rec_lo && !(at == rec_lo + 1 && base[rec_lo] == '\r') {
			when LAX {
				if opens_past_steps(rs) {
					w.rec_lo, w.cells, w.width = rec_lo, cells, width
					return stopped(u64(rec_lo), 0), true
				}
			}
			if fault, wide := record_width(w, cells + 1, &width); fault {
				w.rec_lo, w.cells, w.width = rec_lo, cells, width
				return fault_at(u64(rec_lo), .Bad_Width, .Too_Many if wide else .Too_Few), true
			}
			when LAX {
				rs.in_header = false
			}
			when H == Record_Run {
				if record_run_add(w.h, base, rec_lo, at) {
					w.rec_lo, w.cells, w.width = at + 1, 0, width
					return stopped(u64(at), 1), true
				}
			}
		}
		rec_lo, cells = at + 1, 0
		when LAX {
			rs.open = false
		}
	}
	w.rec_lo, w.cells, w.width = rec_lo, cells + int(intrinsics.count_ones(seps)), width
	when LAX {
		// A record opens at its first delimiter, as the `Object` token of a walk with tokens does.
		if w.cells > 0 && opens_past_steps(rs) {
			return stopped(u64(rec_lo), 0), true
		}
	}
	return 0, false
}

// The records' state of a validate's walk with `LAX`, which its pass keeps in registers over the block loop and stores
// to the pass with `cells_end` as the loop ends, as a store to the piece would alias the pass. Each record opened past
// the header takes one of `steps`, so the records it opened are the steps it took.
@(private)
Cells_State :: struct {
	open, in_header: bool,
	steps:           u64,
}

@(private)
cells_start :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C)) -> (rs: Cells_State) {
	when LAX {
		rs = {w.open, w.in_header, w.steps[0]}
	}
	return
}

@(private)
cells_end :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), rs: ^Cells_State) {
	when LAX {
		if w.piece[0] != nil {
			w.piece[0].records += w.steps[0] - rs.steps
		}
		w.open, w.in_header, w.steps[0] = rs.open, rs.in_header, rs.steps
	}
}

// Opens the record the walk reached a delimiter of, unless it is open, and counts the container it opens against
// `steps` past the header. True when it is the first past them.
@(private)
opens_past_steps :: #force_inline proc "contextless" (rs: ^Cells_State) -> bool {
	if rs.open {
		return false
	}
	rs.open = true
	if rs.in_header {
		return false
	}
	rs.steps -= 1
	return rs.steps == 0
}

// Counts the container that the record at `rec_lo` opens against `Budget.steps`, once, for a validate whose walk makes
// no tokens, and returns the walk's result with `done` when it is the first past them. The header opens none.
@(private)
step_record :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), rec_lo: int) -> (r: hook.Walk_Result, done: bool) {
	when LAX {
		rs := cells_start(w)
		past := opens_past_steps(&rs)
		cells_end(w, &rs)
		if past {
			return stopped(u64(rec_lo), 0), true
		}
	}
	return 0, false
}

// Makes `cells`, those of the first record, the width and the most cells a record had.
@(private)
set_width :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), cells: int, width: ^int) {
	width^ = cells
	w.widest = cells
}

// Sets `width` from the first record. A later record of `cells` cells that differs from `width` is a fault unless
// `.Ragged` is tolerated, and `fault` is then true. `wide` is true when `cells` is above `width`, whose fault is at the
// delimiter past the width.
@(private)
record_width :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), cells: int, width: ^int) -> (fault: bool, wide: bool) {
	if width^ == 0 {
		set_width(w, cells, width)
		return
	}
	if cells != width^ {
		if .Ragged not_in w.tolerate {
			return true, cells > width^
		}
		w.tolerated = true
		w.widest = max(w.widest, cells)
	}
	return
}
