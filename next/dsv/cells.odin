package dsv

import "base:intrinsics"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// Tokens of cells and of their keys, and the column tracking of a `.Columns` walk.

// The token of the cell from `field_lo` to `hi` with role `role`: its span, kind and spelling. `esc` says the span
// holds a TSV backslash or a CSV `""`. `lax` says it holds an ill-formed sequence that `.Invalid_Utf8` tolerated,
// whose decode may be longer than its span. A CSV cell is quoted when its first byte is a quote. A quote at any other
// byte is refused or, under `.Bare_Quote`, is a cell byte. An empty value cell is null. Under `infer` a value cell that
// needs no decode and is `true`, `false` or a JSON number has that kind. With `quoted` false no quote has been read, so
// no cell is quoted.
@(private)
cell_token :: #force_inline proc "contextless" ($S: Spec, base: [^]u8, field_lo, hi: int, esc, lax: bool, role: tape.Role, infer, quoted: bool) -> tape.Token {
	spelling := tape.SPELLING_DECODE | tape.SPELLING_LAX if lax else 0
	if esc {
		spelling |= tape.SPELLING_DECODE
	}
	lo, n := field_lo, hi - field_lo
	when S == .Csv {
		if quoted {
			// Whether a cell is quoted follows no pattern a branch predicts, so the first byte becomes 0 or 1 and is
			// applied arithmetically.
			q := int(n > 0 && base[field_lo] == '"')
			lo, n = lo + q, n - 2 * q
			spelling |= -u16(q) & tape.SPELLING_QUOTED
		}
	}
	kind := tape.Kind.String
	if role == .Value && hi == field_lo {
		kind = .Null
	} else if role == .Value && infer && spelling == 0 {
		return tape.infer_token(base, u64(lo), u32(n))
	}
	return {u64(lo), u32(n), kind, role, spelling}
}

// Gives the hook the `Key` token of the column `cells`, and returns the hook's action with the span of the record's
// cell from `field_lo` to `hi`, which a `Stop` at the key reports. With `PAST` the cell may lie past the header's last,
// which only `.Ragged` reads, and its key comes from `column_key`. Without it the caller has checked that the cell is
// below the header's width.
@(private)
put_key :: #force_inline proc "contextless" ($PAST: bool, w: ^Pass($S, $H, $LAX, $C), hs: ^hook.Regs, cells: int, field_lo, hi: int, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (a: hook.Action, lo: u64, n: u32) {
	k := column_key(w.keys, cells) when PAST else key_at(w.keys, cells)
	// The kind and role are constants, so a hook that tells tokens apart by them folds its whole call away for a key.
	return emit(w, hs, k.lo, k.n, .String, .Key, k.spelling, on), u64(field_lo), u32(hi - field_lo)
}

// Gives a cell as a value token, and returns the action with the cell's span.
@(private)
put_value :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), opts: Pass_Options, hs: ^hook.Regs, base: [^]u8, field_lo, hi: int, esc, lax, quoted: bool, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (a: hook.Action, lo: u64, n: u32) {
	t := cell_token(S, base, field_lo, hi, esc, lax, .Value, opts.infer, quoted)
	return emit(w, hs, t.lo, t.n, t.kind, .Value, t.spelling, on), u64(field_lo), u32(hi - field_lo)
}

// Stores the header cell from `field_lo` to `hi` at `w.keys[cells]` as a key token, when `cells` is below
// `len(w.keys)`. A buffer sized from `header_cells` holds every header cell. A walk in pieces appends the key to the
// read's list of keys instead, and returns false when the list cannot grow.
@(private)
put_header_key :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), cells: int, base: [^]u8, field_lo, hi: int, esc, lax: bool) -> bool {
	t := cell_token(S, base, field_lo, hi, esc, lax, .Key, false, true)
	when LAX {
		if w.piece[0] != nil {
			return piece_put_key(w, t)
		}
	}
	if cells < len(w.keys) {
		w.keys[cells] = t
	}
	return true
}

// Gives a cell's column key (unless `no_header`) and then the cell's value, unless the hook skips the key. For the last
// cell of a record, whose key index is the record's cell count.
@(private)
put_cell :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), opts: Pass_Options, hs: ^hook.Regs, base: [^]u8, cells: int, field_lo, hi: int, esc, lax: bool, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (a: hook.Action, lo: u64, n: u32) {
	if !opts.no_header {
		if column_passes(w, base, cells, field_lo, hi, esc, lax, w.quoted) {
			return .Skip, 0, 0
		}
		if k, klo, kn := put_key(true, w, hs, cells, field_lo, hi, on); k == .Stop || k == .Skip {
			return k, klo, kn
		}
		column_taken(w, cells)
	}
	return put_value(w, opts, hs, base, field_lo, hi, esc, lax, w.quoted, on)
}

// `keys[i]` with no bounds check, for a caller that has proven `i < len(keys)`.
@(private)
key_at :: #force_inline proc "contextless" (keys: []tape.Token, i: int) -> tape.Token #no_bounds_check {
	return keys[i]
}

// The `Key` token of column `c`: its header cell, or for a column past the header's last, which only `.Ragged` reads, a
// key whose `lo` is the 1-based position and holds no bytes of the text.
@(private)
column_key :: #force_inline proc "contextless" (keys: []tape.Token, c: int) -> tape.Token {
	if c < len(keys) {
		return key_at(keys, c)
	}
	return placed_key(c)
}

// The key of column `c` past the header's last, out of line because only `.Ragged` reads one. Its `lo` is the 1-based
// position, not an offset. `SPELLING_PLACED` with `n` 0 tells every reader this, so it never reads as text bytes.
@(private, cold)
placed_key :: #force_no_inline proc "contextless" (c: int) -> tape.Token {
	return {u64(c + 1), 0, .String, .Key, tape.SPELLING_DECODE | tape.SPELLING_PLACED}
}
