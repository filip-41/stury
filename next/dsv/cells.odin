// The cells of dsv's records: a row's split into its cells, and the cell and column services of `core/records`.
package dsv

import "base:intrinsics"
import "core:strconv"
import core "../core"
import kernel "../core/kernel"
import records "../core/records"

// Splits `row` into `b.cells`, which grows to hold them all. Returns the cell count, or false when they do not fit in
// memory.
@(private)
split_all :: proc(it: ^records.Reader, b: ^Batch, src: []u8, row: Batch_Row, spec: Spec, opts: Options, role: core.Role) -> (int, bool) {
	for {
		sp := Split{out = b.cells[:]}
		if _, a := split_any(src, row, spec, opts, role, &sp, {}, on_split); a != .Stop {
			return sp.n, true
		}
		b.cells.allocator = it.allocator
		if resize(&b.cells, max(2 * len(b.cells), 64)) != nil {
			return 0, false
		}
	}
}

// `split_cells` for a spelling known at run time, for the cold readers.
@(private)
split_any :: proc "contextless" (src: []u8, row: Batch_Row, spec: Spec, opts: Options, role: core.Role, h: ^$H, regs: core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (core.Hook_Regs, core.Action) {
	switch spec {
	case .Csv:   return split_cells(src, row, .Csv, opts, role, h, regs, on)
	case .Tsv:   return split_cells(src, row, .Tsv, opts, role, h, regs, on)
	case .Plain: return split_cells(src, row, .Plain, opts, role, h, regs, on)
	}
	return regs, .Stop
}

// A split's buffer: the first `n` tokens of `out` are the row's cells.
@(private)
Split :: struct {
	out: []core.Token,
	n:   int,
}

// The hook of a split into a buffer, which stops the split at a cell past the buffer's end.
@(private)
on_split :: proc "contextless" (s: ^Split, r: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	if s.n == len(s.out) {
		return r, .Stop
	}
	s.out[s.n] = t
	s.n += 1
	return r, .Next
}

// Passes the cells of the judged row `row` to the hook `on` as `Plain` tokens of `role`, spelled as the hooked pass
// spells them, and returns the hook's last action. The row starts outside a quoted field, so its quotes pair up from
// its first byte.
@(private)
split_cells :: proc "contextless" (src: []u8, row: Batch_Row, $S: Spec, opts: Options, role: core.Role, h: ^$H, regs: core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	T :: kernel.Tier(0)
	base := raw_data(src)
	lo, hi := int(row.at), int(row.hi)
	delim := delimiter_of(S, opts)
	lax := .Invalid_Utf8 in opts.tolerate
	field_lo := lo
	carry := false
	regs := regs
	a: core.Action
	when S == .Csv {
		in_quote, close, start: u64 = 0, 0, 1
	}
	for pos := lo; ; pos += 64 {
		blk := kernel.load(base[pos:]) if len(src) - pos >= 64 else kernel.load_padded(T, src, pos)
		live := bits_between(0, min(hi - pos, 64))
		d := kernel.pack(kernel.eq(blk, delim)) & live
		bs: u64
		when S == .Csv {
			// With no branch on the row's quotes, since a text's quoted cells fall in no pattern.
			q := kernel.pack(kernel.eq(blk, '"')) & live
			instr := kernel.prefix_xor(T, q) ~ in_quote
			if .Bare_Quote in opts.tolerate {
				// A quote the pass read as a tolerated bare quote is text, so the quotes pair up without it.
				for {
					bare := q & instr & ~((d & ~instr) << 1 | start | (q & ~instr) << 1 | close)
					if bare == 0 {
						break
					}
					q &~= bare & -bare
					instr = kernel.prefix_xor(T, q) ~ in_quote
				}
			}
			closing := q & ~instr
			d &= ~instr
			bs = (closing << 1 | close) & q
			in_quote, close, start = u64(0) - (instr >> 63), closing >> 63, d >> 63
		} else when S == .Tsv {
			bs = kernel.pack(kernel.eq(blk, '\\')) & live
		}
		plain := bs == 0 && !carry
		for d != 0 {
			at := pos + int(intrinsics.count_trailing_zeros(d))
			d &= d - 1
			esc := !plain && span_esc(bs, pos, field_lo, at, carry)
			if regs, a = on(h, regs, {u64(field_lo), u32(at - field_lo), .Plain, role, spelling(base, field_lo, at, esc, lax, S)}); a == .Stop {
				return regs, a
			}
			field_lo = at + 1
		}
		if hi - pos <= 64 {
			esc := !plain && span_esc(bs, pos, field_lo, hi, carry)
			return on(h, regs, {u64(field_lo), u32(hi - field_lo), .Plain, role, spelling(base, field_lo, hi, esc, lax, S)})
		}
		carry = !plain && span_esc(bs, pos, field_lo, pos + 64, carry)
	}
}

// The batch row `rec` is, when `rec` is the row `next` gave last.
@(private)
held_row :: #force_inline proc(it: ^records.Reader, rec: records.Record) -> (Batch_Row, bool) {
	b := (^Batch)(it.format)
	if b == nil || b.at == 0 {
		return {}, false
	}
	row := b.rows[b.at - 1]
	return row, row.at + it.base == rec.at
}

// The value tokens of `rec`, the row `next` gave last, or false for another or when they do not fit in memory.
@(private)
cells_of :: proc(it: ^records.Reader, rec: records.Record) -> ([]core.Token, bool) {
	row, held := held_row(it, rec)
	if !held {
		return nil, false
	}
	b := (^Batch)(it.format)
	if b.split_row != b.at {
		spec, opts := Spec(it.as.spec), options_of(it.as)
		ok: bool
		if b.split, ok = split_all(it, b, it.src, row, spec, opts, .Value); !ok {
			return nil, false
		}
		b.split_row = b.at
	}
	return b.cells[:b.split], true
}

@(private)
column_of :: proc(it: ^records.Reader, name: string) -> int {
	if it.format == nil {
		// The first row is read to frame the header, then given back.
		_, _ = records.next(it)
		// In memory `pos` is where the next frame starts, and only a stream's moves back to the batch's first row.
		if b := (^Batch)(it.format); b != nil && b.at > 0 {
			b.at = 0
			if it.input.procedure != nil {
				it.pos = b.from
			}
		}
	}
	b := (^Batch)(it.format)
	if b == nil {
		return -1
	}
	view := core.Token_View{src = b.key_src, as = it.as}
	for &key, c in b.keys {
		if spelling_key_equals(&view, key, name) {
			return c
		}
	}
	// Under `.Ragged` a column past the header's last is named by its position.
	c, number := strconv.parse_int(name, 10)
	if number && c > len(b.keys) && .Ragged in options_of(it.as).tolerate && spelling_key_equals(&view, column_key(b.keys, c - 1), name) {
		return c - 1
	}
	return -1
}

// A cell below the split buffer's length splits the row only up to it. A quoted cell with a `""` the split marked, read
// strictly, is undoubled with no general decode.
@(private)
cell_of :: proc(it: ^records.Reader, rec: records.Record, column: int, buf: []u8) -> (string, bool) {
	b := (^Batch)(it.format)
	spec := Spec(it.as.spec)
	row, held := held_row(it, rec)
	if held && b.split_row == b.at {
		if column < 0 || column >= b.split {
			return "", false
		}
		t := b.cells[column]
		if t.spelling & (core.SPELLING_QUOTED | core.SPELLING_DECODE) == 0 {
			return string(it.src[t.lo:t.lo + u64(t.n)]), true
		}
		if t.spelling & (SPELLING_DOUBLED | core.SPELLING_LAX) == SPELLING_DOUBLED && len(buf) >= int(t.n) {
			return undoubled(buf, string(it.src[t.lo + 1:t.lo + u64(t.n) - 1])), true
		}
		return cell_text(it.src, t, spec, buf)
	}
	if held && 0 <= column && column < len(b.cells) {
		opts := options_of(it.as)
		sp := Split{out = b.cells[:column + 1]}
		split_any(it.src, row, spec, opts, .Value, &sp, {}, on_split)
		if sp.n <= column {
			return "", false
		}
		return cell_text(it.src, sp.out[column], spec, buf)
	}
	cells, ok := cells_of(it, rec)
	if !ok || column < 0 || column >= len(cells) {
		return "", false
	}
	return cell_text(it.src, cells[column], spec, buf)
}

// The texts of the cells of `rec`, the row `next` gave last, in `b.texts`, nil for an empty unquoted cell.
@(private)
cells_texts :: proc(it: ^records.Reader, rec: records.Record, buf: []u8) -> ([]Maybe(string), bool) #no_bounds_check {
	cells, ok := cells_of(it, rec)
	b := (^Batch)(it.format)
	if !ok {
		return nil, false
	}
	if len(b.texts) != len(cells) {
		b.texts.allocator = it.allocator
		if resize(&b.texts, len(cells)) != nil {
			return nil, false
		}
	}
	buf := buf
	for t, i in cells {
		switch {
		case t.n == 0:
			b.texts[i] = nil
		case t.spelling & (core.SPELLING_QUOTED | core.SPELLING_DECODE) == 0:
			b.texts[i] = string(it.src[t.lo:t.lo + u64(t.n)])
		case:
			s, decoded := cell_of(it, rec, i, buf)
			if !decoded {
				return nil, false
			}
			if raw_data(s) == raw_data(buf) {
				buf = buf[len(s):]
			}
			b.texts[i] = s
		}
	}
	return b.texts[:], true
}
