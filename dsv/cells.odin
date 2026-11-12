// The cells of dsv's records: a row's split into its cells, and the cell and column services of `core/records`.
package dsv

import "base:intrinsics"
import "core:strconv"
import spell "../core/spell"
import core "../core"
import kernel "../core/kernel"
import write "../core/write"
import records "../core/records"

// dsv's `Readers.number`, exported so a caller that knows the format calls it without the table. It returns the JSON
// number a value cell spells, and false for any other cell. A quoted cell, a TSV escape and a key cell are never numbers,
// since no JSON number holds a quote, a backslash or a byte past 0x7F. A header cell names a column and answers as a JSON
// key node does.
number :: proc(v: ^core.Token_View, t: core.Token) -> (core.Number, bool) {
	if t.role != .Value {
		return {}, false
	}
	return spell.number_strict(v.src, t.lo, t.lo + u64(t.n))
}

// dsv's `Readers.text`, exported so a caller that knows the format calls it without the table: a cell's text as the
// spec the view was read as decodes it, into `buf` when it needs decoding. A container returns false.
text :: proc(v: ^core.Token_View, t: core.Token, buf: []u8) -> (s: string, ok: bool) {
	return cell_text(v.src, t, Spec(v.spec), buf)
}

// Splits `row` into `b.cells`, which grows to hold them all, or its first `upto` cells. Returns the cell count, whether
// it is the row's, or false when they do not fit in memory.
@(private)
split_all :: #force_inline proc(it: ^records.Reader, b: ^Batch, src: []u8, row: Batch_Row, $S: Spec, opts: Options, role: core.Role, upto := max(int)) -> (n: int, whole, ok: bool) {
	for {
		sp := Split{out = b.cells[:min(len(b.cells), upto)]}
		if _, a := split_cells(src, row, S, opts, role, &sp, {}, on_split); a != .Stop || sp.n == upto {
			return sp.n, a != .Stop, true
		}
		b.cells.allocator = it.allocator
		if resize(&b.cells, max(2 * len(b.cells), 64)) != nil {
			return
		}
	}
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
split_cells :: proc "contextless" (src: []u8, row: Batch_Row, $S: Spec, opts: Options, role: core.Role, h: ^$H, regs: core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (core.Hook_Regs, core.Action) {
	if row.lax {
		return split_lax_row(src, row, S, opts, role, h, regs, on)
	}
	return split_row(false, src, row, S, opts, role, h, regs, on)
}

// `split_cells` on a row that holds an ill-formed sequence `.Invalid_Utf8` tolerated.
@(private, cold)
split_lax_row :: #force_no_inline proc "contextless" (src: []u8, row: Batch_Row, $S: Spec, opts: Options, role: core.Role, h: ^$H, regs: core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (core.Hook_Regs, core.Action) {
	return split_row(true, src, row, S, opts, role, h, regs, on)
}

// `split_cells`, with `$LAX` compiling in the reads of the row's ill-formed sequences.
@(private)
split_row :: #force_inline proc "contextless" ($LAX: bool, src: []u8, row: Batch_Row, $S: Spec, opts: Options, role: core.Role, h: ^$H, regs: core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	T :: kernel.Tier(0)
	base := raw_data(src)
	lo, hi := int(row.at), int(row.hi)
	delim := spec_delimiter(S, opts.delimiter)
	field_lo := lo
	// `carry` and `ill_open` say the cell open at the block's start holds a backslash or a `""`, and an ill-formed
	// sequence.
	carry, ill_open := false, false
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
			instr, closing, outside, bare := quote_masks(T, q, d, in_quote, start, close)
			if .Bare_Quote in opts.tolerate {
				// A quote the pass read as a tolerated bare quote is text, so the quotes pair up without it.
				for bare != 0 {
					q &~= bare & -bare
					instr, closing, outside, bare = quote_masks(T, q, d, in_quote, start, close)
				}
			}
			d = outside
			bs = (closing << 1 | close) & q
			in_quote, close, start = u64(0) - (instr >> 63), closing >> 63, d >> 63
		} else when S == .Tsv {
			bs = kernel.pack(kernel.eq(blk, '\\')) & live
		}
		ill: u64
		ill_carry := ill_open
		when LAX {
			back: int
			ill, back = ill_leads(base, lo, pos, hi)
			ill_carry ||= back >= field_lo
		}
		plain := bs | ill == 0 && !(carry || ill_carry)
		for d != 0 {
			at := pos + int(intrinsics.count_trailing_zeros(d))
			d &= d - 1
			esc := !plain && span_esc(bs, pos, field_lo, at, carry)
			lax := !plain && span_esc(ill, pos, field_lo, at, ill_carry)
			if regs, a = on(h, regs, {u64(field_lo), u32(at - field_lo), .Plain, role, spelling(base, field_lo, at, esc, lax, S)}); a == .Stop {
				return regs, a
			}
			field_lo = at + 1
		}
		if hi - pos <= 64 {
			esc := !plain && span_esc(bs, pos, field_lo, hi, carry)
			lax := !plain && span_esc(ill, pos, field_lo, hi, ill_carry)
			return on(h, regs, {u64(field_lo), u32(hi - field_lo), .Plain, role, spelling(base, field_lo, hi, esc, lax, S)})
		}
		carry = !plain && span_esc(bs, pos, field_lo, pos + 64, carry)
		when LAX {
			ill_open = !plain && span_esc(ill, pos, field_lo, pos + 64, ill_carry)
		}
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

// The value tokens of `rec`, the row `next` gave last, or its first `upto`, or false for another or when they do not fit
// in memory, which ends the records with `.No_Memory`.
@(private)
cells_of :: proc(it: ^records.Reader, rec: records.Record, $S: Spec, upto := max(int)) -> ([]core.Token, bool) {
	row, held := held_row(it, rec)
	if !held {
		return nil, false
	}
	b := (^Batch)(it.format)
	if b.split_row != b.at || upto > b.split_cap {
		whole, ok: bool
		if b.split, whole, ok = split_all(it, b, it.src, row, S, options_of(it.as), .Value, upto); !ok {
			it.fault = core.Fault{rules = &RULES, kind = .No_Memory}
			return nil, false
		}
		b.split_row, b.split_cap = b.at, max(int) if whole else upto
	}
	return b.cells[:min(b.split, upto)], true
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

// The row is split only up to the cell. A quoted cell with a `""` the split marked, read strictly, is undoubled with no
// general decode.
@(private)
cell_of_spec :: #force_inline proc(it: ^records.Reader, rec: records.Record, column: int, buf: []u8, $S: Spec) -> (string, bool) {
	if column < 0 {
		return "", false
	}
	cells, ok := cells_of(it, rec, S, column + 1)
	if !ok || column >= len(cells) {
		return "", false
	}
	t := cells[column]
	if t.spelling & (core.SPELLING_QUOTED | core.SPELLING_DECODE) == 0 {
		return string(it.src[t.lo:t.lo + u64(t.n)]), true
	}
	if t.spelling & (SPELLING_DOUBLED | core.SPELLING_LAX) == SPELLING_DOUBLED && len(buf) >= int(t.n) {
		return undoubled(buf, string(it.src[t.lo + 1:t.lo + u64(t.n) - 1])), true
	}
	return cell_text(it.src, t, S, buf)
}

// Makes each unquoted cell of `texts`, the texts of `cells`, the kind `infer` reads it as: a number, true or false.
@(cold, private)
infer_cells :: proc(cells: []core.Token, texts: []write.Scalar) {
	for t, i in cells {
		s, is_text := texts[i].(string)
		if !is_text || t.spelling & (core.SPELLING_QUOTED | core.SPELLING_DECODE) != 0 {
			continue
		}
		#partial switch kind, _ := core.plain_kind(transmute([]u8)s, 0, u64(len(s)), true, true); kind {
		case .True:
			texts[i] = write.Tree_Part.True
		case .False:
			texts[i] = write.Tree_Part.False
		case .Number:
			texts[i] = write.Number_Literal{s}
		}
	}
}

// The first `upto` cells of `rec`, the row `next` gave last, in `b.texts`, nil for an empty unquoted cell. Under `infer`
// an unquoted cell that is a number, `true` or `false` is that kind.
@(private)
cells_texts_spec :: #force_inline proc(it: ^records.Reader, rec: records.Record, buf: []u8, upto: int, $S: Spec) -> ([]write.Scalar, bool) #no_bounds_check {
	cells, ok := cells_of(it, rec, S, upto)
	b := (^Batch)(it.format)
	if !ok {
		return nil, false
	}
	if len(b.texts) != len(cells) {
		b.texts.allocator = it.allocator
		if resize(&b.texts, len(cells)) != nil {
			it.fault = core.Fault{rules = &RULES, kind = .No_Memory}
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
			s, decoded := cell_of_spec(it, rec, i, buf, S)
			if !decoded {
				return nil, false
			}
			if raw_data(s) == raw_data(buf) {
				buf = buf[len(s):]
			}
			b.texts[i] = s
		}
	}
	if options_of(it.as).infer {
		infer_cells(cells, b.texts[:])
	}
	return b.texts[:], true
}
