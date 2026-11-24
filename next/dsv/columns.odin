package dsv

import "base:intrinsics"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The columns a hook of `.Columns` takes, which the pass learns from the first record it reads whole and passes with no
// token in the records after it.

// The bit of column `c` in a pass's `columns`: its own below `hook.COLUMN_BITS`, and the last bit for every column from
// there on. The mask tells the shift it is in range, so it needs no test of its own.
@(private)
column_bit :: #force_inline proc "contextless" (c: int) -> u64 {
	return u64(1) << (u64(min(c, hook.COLUMN_BITS)) & 63)
}

// Whether the cell of column `c` of the open record, from `field_lo` to `hi` of the text at `base`, passes with no
// token: the hook of `.Columns` skipped that column's key in the record the pass learnt its columns from, or the hook
// replays the record, and the cell's value token is stored in the hook's `cells`, as `infer` leaves it for
// `columns_close`. A record the hook keeps gives every cell. `esc`, `lax` and `quoted` are as `cell_token` reads them.
@(private)
column_passes :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), base: [^]u8, c, field_lo, hi: int, esc, lax, quoted: bool) -> bool #no_bounds_check {
	when .Columns in C {
		if w.columns & column_bit(c) == 0 && w.keep == .None {
			return true
		}
		if !w.h.replay.replays {
			return false
		}
		// A replayed record has the first record's width, at most `hook.COLUMN_BITS`, the length of `cells`, and a
		// wider one gives no cell past that width (`read_wide`).
		w.h.replay.cells[w.h.replay.given] = cell_token(S, base, field_lo, hi, esc, lax, .Value, false, quoted)
		w.h.replay.given += 1
		return true
	} else {
		return false
	}
}

// Gives each cell of `cells` that `infer` reads, of the text at `base`, the token `cell_token` gives it under `infer`:
// an unquoted cell that needs no decode. Out of line, so that a pass holds one copy of `infer_token`'s code.
@(private)
infer_kept :: #force_no_inline proc "contextless" (base: [^]u8, cells: []tape.Token) #no_bounds_check {
	for &t in cells {
		if t.kind == .String && t.spelling == 0 {
			t = tape.infer_token(base, t.lo, t.n)
		}
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

// Called before the `End` of a record of `cells` cells that the hook read, of the text at `base`. Adds the cells that
// passed with no token to the hook's `dropped`, or, for a record the hook replays, makes the value tokens of the cells
// `column_passes` kept. In the first record it sets `columns` from the keys the hook took, when the hook's steps are
// `alike` in every record. Columns past that record's last count as taken.
@(private)
columns_close :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), opts: Pass_Options, base: [^]u8, cells: int) #no_bounds_check {
	when .Columns in C {
		if w.keep != .None {
			return
		}
		if w.h.replay.replays {
			if opts.infer {
				infer_kept(base, w.h.replay.cells[:w.h.replay.given])
			}
			return
		}
		if w.learnt {
			passed := int(intrinsics.count_ones(~w.columns & (column_bit(cells) - 1)))
			if w.columns >> 63 == 0 && cells > hook.COLUMN_BITS {
				passed += cells - hook.COLUMN_BITS
			}
			w.h.dropped += u64(passed)
			return
		}
		// A hook whose steps differ from record to record takes every column of every record.
		if w.h.alike {
			w.columns = w.taken | ~(column_bit(cells) - 1) if cells < hook.COLUMN_BITS else w.taken
		}
		w.learnt = true
	}
}
