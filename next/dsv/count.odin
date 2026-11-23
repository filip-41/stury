package dsv

import "base:intrinsics"
import "stury:lib/core/hook"

// What a validate's pass counts instead of giving tokens: the cells and records a block's separators end, and the
// width the records are checked against.

// Counts the cells and records that a block's separators end, for a validate. The delimiters between two LFs are
// counted with `count_ones`, so the work is per record, not per cell. `done` is true when a width fault ends the walk.
@(private)
read_cells :: #force_inline proc "contextless" ($COMMENTS: bool, w: ^Pass($S, $H, $LAX, $C), base: [^]u8, pos: int, seps, lfs, clfs: u64) -> (r: hook.Walk_Result, done: bool) {
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
			if fault, wide := record_width(w, cells + 1, &width); fault {
				w.rec_lo, w.cells, w.width = rec_lo, cells, width
				return fault_at(u64(rec_lo), .Bad_Width, .Too_Many if wide else .Too_Few), true
			}
		}
		rec_lo, cells = at + 1, 0
	}
	w.rec_lo, w.cells, w.width = rec_lo, cells + int(intrinsics.count_ones(seps)), width
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
