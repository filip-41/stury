package dsv

import "base:intrinsics"

// The columns a hook of `.Columns` takes, which the pass learns from the first record it reads whole and passes with no
// token in the records after it.

// The bit of column `c` in a pass's `columns`: its own below 63, and bit 63 for every column from 63 on.
@(private)
column_bit :: #force_inline proc "contextless" (c: int) -> u64 {
	return u64(1) << u64(min(c, 63))
}

// Whether the cell of column `c` of the open record passes with no token: the hook of `.Columns` skipped that column's
// key in the record the pass learnt its columns from. A record the hook keeps gives every cell.
@(private)
column_passes :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), c: int) -> bool {
	when .Columns in C {
		return w.columns & column_bit(c) == 0 && w.keep == .None
	} else {
		return false
	}
}

// Records that the hook took the key of column `c`, while the pass learns its columns from a record it does not keep.
@(private)
column_taken :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), c: int) {
	when .Columns in C {
		if !w.learnt && w.keep == .None {
			w.taken |= column_bit(c)
		}
	}
}

// Called before the `End` of a record of `cells` cells that the hook read. Adds the cells that passed with no token to
// the hook's `dropped`. In the first such record it sets `columns` from the keys the hook took, when the hook's steps
// are `alike` in every record. Columns past that record's last count as taken.
@(private)
columns_close :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), cells: int) {
	when .Columns in C {
		if w.keep != .None {
			return
		}
		if w.learnt {
			passed := int(intrinsics.count_ones(~w.columns & (column_bit(cells) - 1)))
			if w.columns >> 63 == 0 && cells > 63 {
				passed += cells - 63
			}
			w.h.dropped += u64(passed)
			return
		}
		// A hook whose steps differ from record to record takes every column of every record.
		if w.h.alike {
			w.columns = w.taken | ~(column_bit(cells) - 1) if cells < 63 else w.taken
		}
		w.learnt = true
	}
}
