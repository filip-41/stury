package dsv

import "base:intrinsics"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The tokens of a hooked pass. A block's separators in order, each ending a cell or a record, give every token's span:
// an `Array` for the text, then for each record an `Object` (an `Array` without a header), each cell as its column's
// header cell (role `Key`) and the cell itself, and an `End` over the record's line end, 1 byte for LF and 2 for CR LF.
// The text's `End` is at its end, with `n` 0. A quoted cell's span leaves out its quotes, and a cell's span leaves out
// the CR of a CR LF. The header makes no tokens, and an empty line or a line holding only a CR is no record.

// Returns the bits of a block mask for the byte offsets `[lo, hi)`, with `lo` and `hi` from 0 to 64. Returns 0 when
// `lo >= hi`.
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

// Returns whether the cell from `field_lo` to `hi` holds a bit of the block's mask `bs`. `carry` is true when the part
// of the cell in an earlier block holds one. With `bs` 0 the answer is `carry` for a cell that opened before `pos`.
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

// Returns the separators of `seps` that end a cell holding a bit of the block's mask `marks`, which has no bit at a
// separator. The addition carries a mark through its cell's bytes, all ones in `~seps`, into the separator that ends
// it. With `carry` the cell open at the block's start holds a mark, so the first separator is returned.
@(private)
ends_marked :: #force_inline proc "contextless" (seps, marks: u64, carry: bool) -> u64 {
	ends := (~seps + marks) & seps
	if carry {
		ends |= seps & -seps
	}
	return ends
}

// Drops the record that ended from the block's masks: its `d` delimiters, then the LF that ends it.
@(private)
drop_line :: #force_inline proc "contextless" (m, lf: ^u64, d: u64) {
	m^ &= ~d
	m^ &= m^ - 1
	lf^ &= lf^ - 1
}

// Returns the width fault of the record at `lo`, at the byte where `scan_record` finds its first cell past `width`. A
// record that makes no tokens keeps no position for the fault, so the scan reads its separators.
@(private, cold)
wide_fault :: #force_no_inline proc "contextless" (src: []u8, lo, width: int, $S: Spec, delim: u8) -> hook.Walk_Result {
	return fault_at(u64(scan_record(src, lo, width, S, delim).wide_at), .Bad_Width, .Too_Many)
}

// A run of a record's cells in the block at `pos` of the text at `base`. `d` holds the delimiters that end the run's
// cells, `esc_ends` the separators that end a cell holding an escape, and `lax_ends` those that end a cell holding an
// ill-formed sequence `.Invalid_Utf8` tolerated.
@(private)
Cell_Run :: struct {
	base:     [^]u8,
	pos:      int,
	d:        u64,
	esc_ends: u64,
	lax_ends: u64,
}

// The token reader's state that a pass carries from one block to the next: the open cell's first byte and number,
// whether it holds an escape from an earlier block, and the hook's registers. A pass holds it in a local whose address
// reaches no call, each cold call being given a copy, so that it can stay in registers from block to block.
@(private)
Token_State :: struct {
	field_lo: int,
	cells:    int,
	carry:    bool,
	regs:     hook.Regs,
}

// Gives the cells of a record wider than `width` up to the one that ends at `width`'s delimiter, then returns the fault
// at that delimiter. With `KEYS` the record is headed, so each cell has a `Key` before it.
@(private, cold)
read_wide :: #force_no_inline proc "contextless" ($KEYS: bool, w: ^Pass($S, $H, $LAX, $C), opts: Pass_Options, hs: ^hook.Regs, run: Cell_Run, field_lo, cells, width: int, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	// `last` is the delimiter that ends the cell numbered `width - 1`, the first cell past the width's delimiters.
	last := run.d
	for _ in 1 ..< width - cells {
		last &= last - 1
	}
	last &= -last
	upto := run
	upto.d &= last | (last - 1)
	_, _, r, done := values_run(true, KEYS, false, true, w, opts, hs, upto, field_lo, cells, on)
	if done {
		return r
	}
	return fault_at(u64(run.pos + int(intrinsics.count_trailing_zeros(last))), .Bad_Width, .Too_Many)
}

// Gives a run of a headed record's cells under `.Ragged` once it reaches the header's width, each after its column's
// key.
@(private, cold)
read_ragged :: #force_no_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), opts: Pass_Options, hs: ^hook.Regs, run: Cell_Run, field_lo, cells: int, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (next_lo, count: int, r: hook.Walk_Result, done: bool) {
	return values_run(true, true, true, true, w, opts, hs, run, field_lo, cells, on)
}

// Gives a run of a record's cells as values, from the cell at `field_lo` numbered `cells`, and returns the first byte
// and number of the cell past the run. `ESC` compiles the escape test and the ill-formed UTF-8 test in or out, chosen
// per block. With `KEYS` the record is headed, so each cell's column key precedes its value and the cell's own number
// is that key's index. `PAST` lets that index pass the header's last cell, for `.Ragged`. `QUOTES` compiles in the test
// of a quoted cell, which a text with no quote so far does not need.
@(private)
values_run :: #force_inline proc "contextless" ($ESC, $KEYS, $PAST, $QUOTES: bool, w: ^Pass($S, $H, $LAX, $C), opts: Pass_Options, hs: ^hook.Regs, run: Cell_Run, field_lo, cells: int, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (next_lo, count: int, r: hook.Walk_Result, done: bool) {
	dm := run.d
	next_lo, count = field_lo, cells
	for dm != 0 {
		k := intrinsics.count_trailing_zeros(dm)
		at := run.pos + int(k)
		dm &= dm - 1
		esc, lax := false, false
		when ESC {
			esc = run.esc_ends & (u64(1) << k) != 0
			lax = run.lax_ends & (u64(1) << k) != 0
		}
		when KEYS {
			// A key the hook skips has its cell passed with no token.
			if passes, value := column_passes(w, run.base, count, next_lo, at, esc, lax, QUOTES); passes {
				if value {
					if a, lo, n := put_value(w, opts, hs, run.base, next_lo, at, esc, lax, QUOTES, on); a == .Stop {
						return next_lo, count, stopped(lo, n), true
					}
				}
				count += 1
				next_lo = at + 1
				continue
			}
			ka, klo, kn := put_key(PAST, w, hs, count, next_lo, at, on)
			if ka == .Stop {
				return next_lo, count, stopped(klo, kn), true
			}
			if ka == .Skip {
				count += 1
				next_lo = at + 1
				continue
			}
			column_taken(w, count)
		}
		if a, lo, n := put_value(w, opts, hs, run.base, next_lo, at, esc, lax, QUOTES, on); a == .Stop {
			return next_lo, count, stopped(lo, n), true
		}
		count += 1
		next_lo = at + 1
	}
	return
}

// The fewest cells a header has for a walk to take the cells of its learnt columns by mask, as `MASK_COLUMNS` says. A
// narrower record costs less cell by cell.
@(private)
MASKED_WIDTH :: 12

// `values_run` of a headed record's cells for a hook of `.Columns` whose columns are learnt: the cells of columns it
// takes are read one by one, and the cells between them pass with no token and no test. A bit of the learnt `columns`
// is a column below the 63rd, and the last bit is every column from there on.
@(private)
values_masked :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), opts: Pass_Options, hs: ^hook.Regs, run: Cell_Run, field_lo, cells: int, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (next_lo, count: int, r: hook.Walk_Result, done: bool) {
	// The cells the hook takes are read by the pass without `MASK_COLUMNS`, so this code is not read again from it.
	v := (^Pass(S, H, LAX, C - MASK_COLUMNS))(w)
	dm := run.d
	next_lo, count = field_lo, cells
	high := u64(0) - w.columns >> 63
	taken := high
	if count < hook.COLUMN_BITS {
		below := u64(1) << u64(hook.COLUMN_BITS - count) - 1
		taken = (w.columns >> u64(count)) & below | high & ~below
	}
	taken &= u64(1) << u64(intrinsics.count_ones(dm)) - 1
	for taken != 0 {
		for skip := intrinsics.count_trailing_zeros(taken); skip != 0; skip -= 1 {
			next_lo = run.pos + int(intrinsics.count_trailing_zeros(dm)) + 1
			dm &= dm - 1
			count += 1
			taken >>= 1
		}
		taken >>= 1
		one := run
		one.d = dm & -dm
		dm &= dm - 1
		next_lo, count, r, done = values_run(true, true, false, true, v, opts, hs, one, next_lo, count, on)
		if done {
			return
		}
	}
	if dm != 0 {
		count += int(intrinsics.count_ones(dm))
		next_lo = run.pos + 64 - int(intrinsics.count_leading_zeros(run.d))
	}
	return
}

// `values_run` with the tests the block needs: no escape or ill-formed UTF-8 test in a `plain` block, where no cell
// holding either ends, and no quoted-cell test while the text has held no quote.
@(private)
values_run_for :: #force_inline proc "contextless" ($KEYS: bool, plain, quoted: bool, w: ^Pass($S, $H, $LAX, $C), opts: Pass_Options, hs: ^hook.Regs, run: Cell_Run, field_lo, cells: int, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (next_lo, count: int, r: hook.Walk_Result, done: bool) {
	when KEYS && MASK_COLUMNS <= C {
		// A record the hook keeps gives every cell.
		if w.learnt && w.keep == .None && w.columns != ~u64(0) {
			return values_masked(w, opts, hs, run, field_lo, cells, on)
		}
	}
	if plain && !quoted {
		return values_run(false, KEYS, false, false, w, opts, hs, run, field_lo, cells, on)
	}
	if plain {
		return values_run(false, KEYS, false, true, w, opts, hs, run, field_lo, cells, on)
	}
	return values_run(true, KEYS, false, true, w, opts, hs, run, field_lo, cells, on)
}

// Stores the header's cells that the delimiters `run.d` end as the `Key` tokens that name its columns' cells, from the
// cell at `field_lo` numbered `cells`, and returns the first byte and number of the cell past them. `done` is true
// when a walk in pieces cannot grow its list of keys.
@(private)
header_run :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), run: Cell_Run, plain: bool, field_lo, cells: int) -> (next_lo, count: int, r: hook.Walk_Result, done: bool) {
	dm := run.d
	next_lo, count = field_lo, cells
	for dm != 0 {
		k := intrinsics.count_trailing_zeros(dm)
		at := run.pos + int(k)
		dm &= dm - 1
		esc, lax := false, false
		if !plain {
			esc = run.esc_ends & (u64(1) << k) != 0
			lax = run.lax_ends & (u64(1) << k) != 0
		}
		if !put_header_key(w, count, run.base, next_lo, at, esc, lax) {
			return next_lo, count, hook.walk_result(u64(at), hook.WALK_NO_MEMORY), true
		}
		count += 1
		next_lo = at + 1
	}
	return
}

// Gives the tokens of the separators `seps` of the block at `pos`, with `lfs` the LFs among them, `bs` the bytes that
// make a cell need a decode and `clfs` the LFs that end a comment line. The delimiters before the block's next LF are
// the open record's cells and run through an inner loop that has no LF test, no CR test, no width check and no `End`,
// and that chooses the record's state once per run. The outer loop gives each record's last cell and its `End`. With
// `LAX_UTF8` the block is read with the escape and sequence tests, and the cells that hold an ill-formed sequence
// `.Invalid_Utf8` tolerated, whose leads are `ill` with `ill_back` the lead of one that starts before the block, are
// spelled for it. `quoted` is whether the text has held a quote. `t` is written back only when no token ends the walk.
@(private)
block_tokens :: #force_inline proc "contextless" ($LAX_UTF8: bool, comments: bool, w: ^Pass($S, $H, $LAX, $C), src: []u8, opts: Pass_Options, t: ^Token_State, quoted: bool, pos: int, seps, lfs, bs, clfs, ill: u64, ill_back: int, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) #no_bounds_check {
	base := raw_data(src)
	hs := &t.regs
	field_lo, cells := t.field_lo, t.cells
	no_header := opts.no_header
	carry := t.carry
	// Every cell that the block ends, except the one open at its start, is shorter than 64 bytes. That cell can
	// exceed `max(u32)` only if it opened more than `max(u32) - 64` bytes before `pos`, so the test runs only then.
	if u64(pos - field_lo) > u64(max(u32)) - 64 && cell_too_wide(base, field_lo, pos, seps) {
		return fault_at(u64(field_lo), .Too_Wide), true
	}
	when !LAX_UTF8 && .Skips not_in C {
		// No cell or record ends in the block, so no token is made, and the open cell holds an escape if it did or
		// the block has one.
		if seps == 0 {
			t.carry ||= bs != 0
			return 0, false
		}
	}
	// `ill_carry` is whether the cell open at the block's start holds an ill-formed sequence, from the blocks before
	// or from the lead `ill_back` this block's check found.
	ill_carry := false
	when LAX_UTF8 {
		ill_carry = w.open_ill || ill_back >= field_lo
	}
	// The separators that end a cell holding an escape, and one holding an ill-formed sequence. A block where no
	// cell ends with either takes the runs with `ESC` false, so the escape work is per block.
	marked := bs | ill != 0 || carry || ill_carry
	run := Cell_Run{base = base, pos = pos}
	if marked {
		run.esc_ends = ends_marked(seps, bs, carry)
		run.lax_ends = ends_marked(seps, ill, ill_carry)
	}
	plain_block := !LAX_UTF8 && run.esc_ends | run.lax_ends == 0
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
			d = m & ((u64(1) << k) - 1)
		}
		run.d = d
		if !w.open && d != 0 {
			w.open = true
			if !w.in_header {
				if opened, stop := open_record(w, src, opts, hs, w.rec_lo, w.width, &w.muted, on); stop {
					return opened, true
				}
			}
		}
		// `ended` says a run of cells ended the walk with `result`.
		result: hook.Walk_Result
		ended: bool
		if d == 0 {
			// The record's next separator is its LF. A run reaching past the width faulted at an earlier run, so
			// none is reached here.
		} else if w.in_header {
			field_lo, cells, result, ended = header_run(w, run, plain_block, field_lo, cells)
		} else if w.muted {
			// The hook passed this record over, so its cells are counted and its bytes judged, but make no tokens.
			if w.width != 0 && .Ragged not_in w.tolerate && cells + int(intrinsics.count_ones(d)) >= w.width {
				return wide_fault(src, w.rec_lo, w.width, S, w.delim), true
			}
			cells += int(intrinsics.count_ones(d))
			field_lo = pos + 64 - int(intrinsics.count_leading_zeros(d))
		} else if no_header {
			// No header, so every cell is a value and no key is given. A cold call takes a run built for it, so the
			// local `run` stays in registers.
			if w.width != 0 && .Ragged not_in w.tolerate && cells + int(intrinsics.count_ones(d)) >= w.width {
				given := t.regs
				wide := read_wide(false, w, opts, &given, Cell_Run{base, pos, d, run.esc_ends, run.lax_ends}, field_lo, cells, w.width, on)
				t.regs = given
				return wide, true
			}
			field_lo, cells, result, ended = values_run_for(false, plain_block, quoted, w, opts, hs, run, field_lo, cells, on)
		} else if cells + int(intrinsics.count_ones(d)) >= w.width {
			if .Ragged not_in w.tolerate {
				given := t.regs
				wide := read_wide(true, w, opts, &given, Cell_Run{base, pos, d, run.esc_ends, run.lax_ends}, field_lo, cells, w.width, on)
				t.regs = given
				return wide, true
			}
			given := t.regs
			field_lo, cells, result, ended = read_ragged(w, opts, &given, Cell_Run{base, pos, d, run.esc_ends, run.lax_ends}, field_lo, cells, on)
			t.regs = given
		} else {
			// A data record's run of cells, each after its column's key. The cell's own number is the key's index, and
			// the run advances that number only.
			field_lo, cells, result, ended = values_run_for(true, plain_block, quoted, w, opts, hs, run, field_lo, cells, on)
		}
		if ended {
			return result, true
		}
		if k == 64 {
			break
		}
		// The LF that ends the record also ends a cell. The CR of a CR LF belongs to the line end, so it is left out
		// of the cell's span and is the first byte of the record's `End`.
		at := pos + int(k)
		hi := at
		if at > field_lo && base[at - 1] == '\r' {
			hi = at - 1
		}
		if comments && clfs & (u64(1) << k) != 0 {
			// A comment line is no record: it sets no width, and the line after it starts fresh. It is held until a
			// record or the text's end tells whether it is a `Comment` or the text's foot.
			if w.held == 0 && w.rec_lo >= w.given {
				w.held = w.rec_lo + 1
			}
			w.rec_lo, field_lo = at + 1, at + 1
			drop_line(&m, &lf, d)
			continue
		}
		if !w.open {
			// An empty line, or a line holding only a CR, is no record: it makes no token and sets no width.
			if hi == w.rec_lo {
				w.rec_lo, field_lo = at + 1, at + 1
				drop_line(&m, &lf, d)
				continue
			}
			w.open = true
			if !w.in_header {
				if opened, stop := open_record(w, src, opts, hs, w.rec_lo, w.width, &w.muted, on); stop {
					return opened, true
				}
			}
		}
		// `k` is below 64 here, and a plain block has no escape ends.
		esc := run.esc_ends >> k & 1 != 0
		lax := false
		when LAX_UTF8 {
			lax = run.lax_ends >> k & 1 != 0
		}
		if w.in_header {
			if !put_header_key(w, cells, base, field_lo, hi, esc, lax) {
				return hook.walk_result(u64(hi), hook.WALK_NO_MEMORY), true
			}
		} else if !w.muted {
			a, lo, n := put_cell(w, opts, hs, base, cells, field_lo, hi, esc, lax, on)
			if a == .Stop {
				return stopped(lo, n), true
			}
		}
		cells += 1
		field_lo = at + 1
		if fault, wide := record_width(w, cells, &w.width); fault {
			if wide {
				return wide_fault(src, w.rec_lo, w.width, S, w.delim), true
			}
			return fault_at(u64(hi), .Bad_Width, .Too_Few), true
		}
		if !w.in_header && !w.muted && !no_header {
			columns_close(w, opts, base, cells)
		}
		// A one-record pass gives the `End` of a record at its line end with `n` 0, as a pass of the record's own
		// bytes does.
		line_n := u32(at + 1 - hi)
		when ONE_RECORD <= C {
			line_n = 0
		}
		if !w.in_header && !close_record(w, hs, hi, line_n, on) {
			return stopped(u64(hi), line_n), true
		}
		when .Walk in C {
			if w.again {
				return hook.walk_result(u64(at + 1), 0), true
			}
		}
		when ONE_RECORD <= C {
			return hook.walk_result(u64(at + 1), 0), true
		}
		// A read in pieces needs to know the header has ended.
		w.rec_lo, cells, w.open, w.muted, w.in_header = at + 1, 0, false, false, false
		drop_line(&m, &lf, d)
	}
	// The cell open at the block's end passes its escape state to the next block.
	next_carry := false
	when LAX_UTF8 {
		w.open_ill = false
	}
	if marked {
		next_carry = span_esc(bs, pos, field_lo, pos + 64, carry)
		when LAX_UTF8 {
			w.open_ill = span_esc(ill, pos, field_lo, pos + 64, ill_carry)
		}
	}
	carry = next_carry
	t.field_lo, t.cells, t.carry = field_lo, cells, carry
	return 0, false
}

// `block_tokens` on a block that holds an ill-formed sequence `.Invalid_Utf8` tolerated, or that a cell holding one is
// open across. It is a cold copy of the whole reader per hook, so `comments` is a value here and not a compile-time
// parameter, and the reader's escape-free runs, which this instance does not use, are left out.
@(private, cold)
lax_block_tokens :: #force_no_inline proc "contextless" (comments: bool, w: ^Pass($S, $H, $LAX, $C), src: []u8, opts: Pass_Options, t: ^Token_State, quoted: bool, pos: int, seps, lfs, bs, clfs, ill: u64, ill_back: int, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) {
	return block_tokens(true, comments, w, src, opts, t, quoted, pos, seps, lfs, bs, clfs, ill, ill_back, on)
}

// Gives the tokens of the record the text ends in, which no LF ends: its opening token, its open cell, and an `End` of
// `n` 0 at the text's end.
@(private)
read_last_tokens :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, opts: Pass_Options, hs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) {
	base := raw_data(src)
	// A trailing CR is a fault already reported, so this record holds a cell. A last record wider than `width` returns
	// the fault from `scan_record` before any token. A short one gives its tokens, then faults at the text's end.
	if !w.in_header && w.width != 0 && w.cells + 1 > w.width && .Ragged not_in w.tolerate {
		return wide_fault(src, w.rec_lo, w.width, S, w.delim), true
	}
	hi := w.n
	esc := w.field_esc
	if w.in_header {
		if !put_header_key(w, w.cells, base, w.field_lo, hi, esc, w.open_ill) {
			return hook.walk_result(u64(hi), hook.WALK_NO_MEMORY), true
		}
		set_width(w, w.cells + 1, &w.width)
		return 0, false
	}
	if !w.open {
		w.open = true
		if opened, stop := open_record(w, src, opts, hs, w.rec_lo, w.width, &w.muted, on); stop {
			return opened, true
		}
	}
	if !w.muted {
		if a, lo, n := put_cell(w, opts, hs, base, w.cells, w.field_lo, hi, esc, w.open_ill, on); a == .Stop {
			return stopped(lo, n), true
		}
	}
	if fault, _ := record_width(w, w.cells + 1, &w.width); fault {
		return fault_at(u64(hi), .Bad_Width, .Too_Few), true
	}
	if !w.muted && !opts.no_header {
		columns_close(w, opts, base, w.cells + 1)
	}
	if !close_record(w, hs, hi, 0, on) {
		return stopped(u64(hi), 0), true
	}
	return 0, false
}
