package dsv

import "base:intrinsics"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The tokens of a hooked pass. A block's separators in order, each ending a cell or a record, give every token's span:
// an `Array` for the text, then for each record an `Object` (an `Array` without a header), each cell as its column's
// header cell (role `Key`) and the cell itself, and an `End` over the record's line end, 1 byte for LF and 2 for CR LF.
// The text's `End` is at its end, with `n` 0. A quoted cell's span leaves out its quotes, and a cell's leaves out the CR
// of a CR LF. The header makes no tokens, and an empty line or a line holding only a CR is no record.

// The spelling of a comment line's token: its marker is one byte and nothing closes it.
@(private)
COMMENT_SPELLING :: u16(1)

// Gives the hook the token from `lo` of `n` bytes, through its `Keeps` inside a record or text it keeps, after growing
// its room for a node it has no place for. A walk with `LAX` takes a step of `Budget.steps` per container, and stops
// at the first past it with no token. The builder's table hook `builder_hook_rows` stores no key, so a key needs no room
// for it and every other hook gets room for its keys.
@(private)
emit :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), hs: ^hook.Regs, lo: u64, n: u32, kind: tape.Kind, role: tape.Role, spelling: u16, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Action {
	t := tape.Token{lo, n, kind, role, spelling}
	when LAX {
		if kind == .Array || kind == .Object {
			w.steps[0] -= 1
			if w.steps[0] == 0 {
				return .Stop
			}
		}
	}
	when .Keeps in C {
		if w.keep != 0 {
			return give_kept(w, hs, t)
		}
	}
	when .Rooms in C {
		if kind != .End && role <= .Key && !(role == .Key && rawptr(on) == rawptr(build.builder_hook_rows)) && uintptr(hs.a) == w.rooms {
			// The growth takes a copy of the registers, so their address reaches no call.
			grown := hs^
			ok := hook.rooms_grow(w.h, &grown, lo)
			hs^ = grown
			if !ok {
				w.refused = true
				return .Stop
			}
			w.rooms = hook.rooms_end(w.h)
		}
	}
	a: hook.Action
	hs^, a = on(w.h, hs^, t)
	return a
}

// Gives the inner hook of the hook's `Keeps` token `t`, after growing the inner hook's room when it has `.Rooms`.
@(private)
give_kept :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), hs: ^hook.Regs, t: tape.Token) -> hook.Action {
	when .Keeps in C {
		K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 3)
		Inner :: intrinsics.type_polymorphic_record_parameter_value(K, 0)
		IC :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(Inner, hook.PROTOCOL_FIELD), 0)
		when .Rooms in IC {
			inner := (^Inner)(hook.keeps_inner(w.h))
			if t.kind != .End && t.role <= .Key && uintptr(hs.a) == hook.rooms_end(inner) {
				grown := hs^
				ok := hook.rooms_grow(inner, &grown, t.lo)
				hs^ = grown
				if !ok {
					w.refused = true
					return .Stop
				}
				when .Rooms in C {
					// The inner hook's room may be the hook's own.
					w.rooms = hook.rooms_end(w.h)
				}
			}
		}
		a: hook.Action
		if w.keep == 2 {
			hs^, a = hook.keeps_give(w.h, hs^, t, true)
		} else {
			hs^, a = hook.keeps_give(w.h, hs^, t, false)
		}
		return a
	} else {
		return .Next
	}
}

// Gives the comments before the header, then the text's opening `Array` at `lo`, and reads the hook's answer. `done`
// with the walk's result when the hook stopped the walk, or passed over the text or the rest of it, which is then
// judged with no tokens.
@(private)
open_text :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, opts: Pass_Options, hs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) {
	if w.record {
		return 0, false
	}
	if opts.comment != 0 && !opts.no_header {
		if r, done = give_head_comments(w, src, opts.comment, hs, on); done {
			return
		}
	}
	a := emit(w, hs, lo, 0, .Array, .Value, 0, on)
	switch a {
	case .Next, .Grow:
	case .Skip, .Rest:
		r = judge_from(w, src, lo, opts, 0)
		if u8(r) == 0 && a == .Skip && emit(w, hs, u64(len(src)), 0, .End, .Value, 0, on) == .Stop {
			r = stopped(u64(len(src)), 0)
		}
		return r, true
	case .Keep, .Keep_Stubs:
		w.keep, w.keep_root = 2 if a == .Keep_Stubs else 1, true
		if give_kept(w, hs, {lo, 0, .Array, .Value, 0}) == .Stop {
			return stopped(lo, 0), true
		}
	case .Stop:
		return stopped(lo, 0), true
	}
	return 0, false
}

// Gives the text's `End` at `n`, after the comment lines past its last record as its foot, through the hook's `Keeps`
// first for a text it keeps.
@(private)
close_text :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, comment: u8, n: int, hs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) {
	if w.record {
		return 0, false
	}
	if w.held != 0 {
		if r, done = give_comments(w, src, comment, n, .Comment_Foot, hs, on); done {
			return
		}
	}
	if w.keep != 0 {
		if give_kept(w, hs, {u64(n), 0, .End, .Value, 0}) == .Stop {
			return stopped(u64(n), 0), true
		}
		w.keep, w.keep_root = 0, false
	}
	if emit(w, hs, u64(n), 0, .End, .Value, 0, on) == .Stop {
		return stopped(u64(n), 0), true
	}
	return 0, false
}

// Gives each comment line from the first one held up to `upto` as a token of `role`, and holds none after. The lines
// there are empty lines, comment lines and the header, which opens with no comment byte. A comment's span leaves out
// the CR of a CR LF, which belongs to the line end.
@(private, cold)
give_comments :: #force_no_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, comment: u8, upto: int, role: tape.Role, hs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) #no_bounds_check {
	lo := w.held - 1
	w.held = 0
	for lo < upto {
		end := lo
		for end < upto && src[end] != '\n' {
			end += 1
		}
		hi := end
		if end < upto && hi > lo && src[hi - 1] == '\r' {
			hi -= 1
		}
		if hi > lo && src[lo] == comment {
			if emit(w, hs, u64(lo), u32(hi - lo), .Plain, role, COMMENT_SPELLING, on) == .Stop {
				return stopped(u64(lo), u32(hi - lo)), true
			}
		}
		lo = end + 1
	}
	return 0, false
}

// Gives the comment lines before the header as comments of the text, before the text's opening token, and marks them
// given so the pass holds none of them. A text with no record after its header holds them as its foot.
@(private, cold)
give_head_comments :: #force_no_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, comment: u8, hs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) {
	start := int(text_start(src, 0))
	header := record_start(src, start, comment)
	if header == len(src) || record_start(src, scan_record(src, header, 0, S, w.delim).line_end + 1, comment) >= len(src) {
		return 0, false
	}
	w.held, w.given = start + 1, header
	return give_comments(w, src, comment, header, .Comment, hs, on)
}

// Opens a record at `rec_lo`, with the `Array` or `Object` its hook tests, and reads the hook's answer. `done` with the
// walk's result when the hook stopped the walk or passed over the rest of the text, which is then judged with no
// tokens against `width`, the records' width so far. A record the hook passes over is `muted`, and one it keeps is
// given to the inner hook of its `Keeps`.
@(private)
open_record :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, opts: Pass_Options, hs: ^hook.Regs, rec_lo, width: int, muted: ^bool, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) {
	if opts.limit < 2 {
		return hook.walk_result(u64(rec_lo), hook.WALK_TOO_DEEP), true
	}
	when .Levels in C {
		// The first record opens the walk's deepest level.
		if !w.leveled {
			if hook.levels_held(w.h) <= int(hs.c) {
				grown := hs^
				ok := hook.levels_grow(w.h, int(hs.c) + 1, &grown, u64(rec_lo))
				hs^ = grown
				if !ok {
					return hook.walk_result(u64(rec_lo), hook.WALK_NO_MEMORY), true
				}
			}
			w.leveled = true
			when .Rooms in C {
				// Growing the hook's levels may have grown its room.
				w.rooms = hook.rooms_end(w.h)
			}
		}
	}
	if w.held != 0 {
		given := hs^
		rr, stop := give_comments(w, src, opts.comment, rec_lo, .Comment, &given, on)
		hs^ = given
		if stop {
			return rr, true
		}
	}
	kind := tape.Kind.Array if opts.no_header else .Object
	a := emit(w, hs, u64(rec_lo), 0, kind, .Value, 0, on)
	switch a {
	case .Next, .Grow:
	case .Skip:
		muted^ = true
	case .Rest:
		return judge_from(w, src, u64(rec_lo), opts, width), true
	case .Keep, .Keep_Stubs:
		w.keep = 2 if a == .Keep_Stubs else 1
		if give_kept(w, hs, {u64(rec_lo), 0, kind, .Value, 0}) == .Stop {
			return stopped(u64(rec_lo), 0), true
		}
	case .Stop:
		return stopped(u64(rec_lo), 0), true
	}
	return 0, false
}

// Gives the `End` of a record over its line end from `lo` of `n` bytes, through the hook's `Keeps` first for a record
// it keeps.
@(private)
close_record :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), hs: ^hook.Regs, lo: int, n: u32, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> bool {
	when .Keeps in C {
		if w.keep != 0 && !w.keep_root {
			if give_kept(w, hs, {u64(lo), n, .End, .Value, 0}) == .Stop {
				return false
			}
			w.keep = 0
		}
	}
	return emit(w, hs, u64(lo), n, .End, .Value, 0, on) != .Stop
}

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

// Sets `width` from the first record. A later record of `cells` cells that differs from `width` faults unless `.Ragged`
// is tolerated, and `fault` is then true. `wide` is true when `cells` is above `width`, whose fault is at the delimiter
// past the width.
@(private)
record_width :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), cells: int, width: ^int) -> (fault: bool, wide: bool) {
	if width^ == 0 {
		width^ = cells
		w.widest = cells
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

// The token of the cell from `field_lo` to `hi` with role `role`: its span, kind and spelling. `esc` says the span
// holds a TSV backslash or a CSV `""`, and `lax` an ill-formed sequence `.Invalid_Utf8` tolerated, whose decode may
// grow past its span. A CSV cell whose first byte is a quote is quoted, and an unquoted cell's never is, since a quote
// at a cell's first byte opens a quoted cell and one anywhere else is refused or, under `.Bare_Quote`, a cell byte. An
// empty unquoted value cell is null. Under `infer` an unquoted value cell that needs no decode and is `true`, `false`
// or a JSON number is that value. With `quoted` false no quote has been read, so no cell is quoted.
@(private)
cell_token :: #force_inline proc "contextless" ($S: Spec, base: [^]u8, field_lo, hi: int, esc, lax: bool, role: tape.Role, infer, quoted: bool) -> tape.Token {
	spelling := tape.SPELLING_DECODE | tape.SPELLING_LAX if lax else 0
	if esc {
		spelling |= tape.SPELLING_DECODE
	}
	lo, n := field_lo, hi - field_lo
	when S == .Csv {
		if quoted {
			// With no branch on the first byte, since a text's quoted cells fall in no pattern.
			q := int(n > 0 && base[field_lo] == '"')
			lo, n = lo + q, n - 2 * q
			spelling |= -u16(q) & tape.SPELLING_QUOTED
		}
	}
	kind := tape.Kind.String
	if role == .Value && hi == field_lo {
		kind = .Null
	} else if role == .Value && infer && spelling == 0 {
		return infer_token(base, u64(lo), u32(n))
	}
	return {u64(lo), u32(n), kind, role, spelling}
}

// An unquoted value cell that needs no decode, as `infer` reads it: `true` and `false` are those kinds, and an RFC
// 8259 number is a `Number` with its digit counts as JSON's walk spells them. The first byte picks the work, so a text
// cell costs one load.
@(private)
infer_token :: #force_inline proc "contextless" (base: [^]u8, lo: u64, n: u32) -> tape.Token {
	t := tape.Token{lo, n, .String, .Value, 0}
	switch base[lo] {
	case 't':
		if n == 4 && string(base[lo:][:4]) == "true" {
			t.kind = .True
		}
	case 'f':
		if n == 5 && string(base[lo:][:5]) == "false" {
			t.kind = .False
		}
	case '-', '0' ..= '9':
		if spelling, ok := number_shape(base, lo, lo + u64(n)); ok {
			t.kind, t.spelling = .Number, spelling
		}
	}
	return t
}

// Gives a column's header cell as the `Key` token its cell names it by, and returns the hook's action with the span of
// the record's cell from `field_lo` to `hi`, which a `Stop` at the key reports. With `PAST` a cell may lie past the
// header's last, which only `.Ragged` reads, and is named by `column_key`. Without it the caller has proven the cell
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

// Stores the header cell from `field_lo` to `hi` at `keys[cells]` as a key token, when `cells` is below `len(keys)`.
// A buffer sized from `header_cells` holds every header cell.
@(private)
put_header_key :: #force_inline proc "contextless" ($S: Spec, keys: []tape.Token, cells: int, base: [^]u8, field_lo, hi: int, esc, lax: bool) {
	if cells < len(keys) {
		keys[cells] = cell_token(S, base, field_lo, hi, esc, lax, .Key, false, true)
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

// Whether the cell from `field_lo` to `hi` holds a bit of the block's mask `bs`. `carry` covers the part of a cell that
// opened in an earlier block. With `bs` 0 the answer is `carry` for a cell that opened before `pos`.
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

// The separators of `seps` that end a cell holding a bit of the block's mask `marks`, a mask of no separator. A bit
// carries through its cell's bytes, all ones in `~seps`, into the separator that ends it. With `carry` the cell open at
// the block's start holds one, so the first separator does.
@(private)
ends_marked :: #force_inline proc "contextless" (seps, marks: u64, carry: bool) -> u64 {
	ends := (~seps + marks) & seps
	if carry {
		ends |= seps & -seps
	}
	return ends
}

// `keys[i]` with no bounds check, for a caller that has proven `i < len(keys)`.
@(private)
key_at :: #force_inline proc "contextless" (keys: []tape.Token, i: int) -> tape.Token #no_bounds_check {
	return keys[i]
}

// The `Key` token of column `c`: its header cell, or past the header's last, which only `.Ragged` reads, a key named by
// its 1-based position. That key holds no bytes: `n` is the position, which its decode writes out, and `lo` the
// header's first byte, so the span stays inside the text, which holds the header's line and the `c` delimiters before
// the cell.
@(private)
column_key :: #force_inline proc "contextless" (keys: []tape.Token, c: int) -> tape.Token {
	if c < len(keys) {
		return key_at(keys, c)
	}
	return {keys[0].lo if len(keys) > 0 else 0, u32(c + 1), .String, .Key, tape.SPELLING_DECODE | SPELLING_COLUMN}
}

// The bit of column `c` in a pass's `columns`: its own below 63, and bit 63 for every column from 63 on.
@(private)
column_bit :: #force_inline proc "contextless" (c: int) -> u64 {
	return u64(1) << u64(min(c, 63))
}

// Whether the cell of column `c` of the open record passes with no token, as the hook of `.Columns` skipped its key in
// the record it learnt the columns from. A record a hook keeps gives every cell.
@(private)
column_passes :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), c: int) -> bool {
	when .Columns in C {
		return w.columns & column_bit(c) == 0 && w.keep == 0
	} else {
		return false
	}
}

// Notes that the hook took the key of column `c`, while the pass learns its columns from a record it does not keep.
@(private)
column_taken :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), c: int) {
	when .Columns in C {
		if !w.learnt && w.keep == 0 {
			w.taken |= column_bit(c)
		}
	}
}

// Before the `End` of a record of `cells` cells the hook read: adds the cells that passed with no token to the hook's
// `dropped`, and learns the columns from the first such record. A column past that record's last is taken.
@(private)
columns_close :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), cells: int) {
	when .Columns in C {
		if w.keep != 0 {
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
		w.columns = w.taken | ~(column_bit(cells) - 1) if cells < 63 else w.taken
		w.learnt = true
	}
}

// Gives a cell's column key (unless `no_header`) and then the cell's value, unless the hook skips the key. Used for the
// last cell of a record, whose key index is the record's cell count.
@(private)
put_cell :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), opts: Pass_Options, hs: ^hook.Regs, base: [^]u8, cells: int, field_lo, hi: int, esc, lax: bool, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (a: hook.Action, lo: u64, n: u32) {
	if !opts.no_header {
		if column_passes(w, cells) {
			return .Skip, 0, 0
		}
		if k, klo, kn := put_key(true, w, hs, cells, field_lo, hi, on); k == .Stop || k == .Skip {
			return k, klo, kn
		}
		column_taken(w, cells)
	}
	return put_value(w, opts, hs, base, field_lo, hi, esc, lax, w.quoted, on)
}

// Drops the record that ended from the block's masks: its `d` delimiters, then the LF that ends it.
@(private)
drop_line :: #force_inline proc "contextless" (m, lf: ^u64, d: u64) {
	m^ &= ~d
	m^ &= m^ - 1
	lf^ &= lf^ - 1
}

// The width fault of the record at `lo`, at the byte `scan_record` finds its first cell past `width`. A record that makes
// no tokens keeps no position for the fault, so the scan reads its separators.
@(private, cold)
wide_fault :: #force_no_inline proc "contextless" (src: []u8, lo, width: int, $S: Spec, delim: u8) -> hook.Walk_Result {
	return fault_at(u64(scan_record(src, lo, width, S, delim).fault_at), .Bad_Width, .Too_Many)
}

// Gives the cells of a record wider than `width` up to the one that ends at `width`'s delimiter, then returns the fault
// at that delimiter. With `KEYS` the record is headed, so each cell has a `Key` before it.
@(private, cold)
read_wide :: #force_no_inline proc "contextless" ($KEYS: bool, w: ^Pass($S, $H, $LAX, $C), opts: Pass_Options, hs: ^hook.Regs, base: [^]u8, pos: int, d: u64, cells, field_lo, width: int, esc_ends, lax_ends: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	// `last` is the delimiter that ends the cell numbered `width - 1`, the first cell past the width's delimiters.
	last := d
	for _ in 1 ..< width - cells {
		last &= last - 1
	}
	last &= -last
	_, _, r, done := values_run(true, KEYS, false, true, w, opts, hs, base, pos, d & (last | (last - 1)), field_lo, cells, esc_ends, lax_ends, on)
	if done {
		return r
	}
	return fault_at(u64(pos + int(intrinsics.count_trailing_zeros(last))), .Bad_Width, .Too_Many)
}

// Gives a run of a headed record's cells under `.Ragged` once it reaches the header's width, each after its column's
// key.
@(private, cold)
read_ragged :: #force_no_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), opts: Pass_Options, hs: ^hook.Regs, base: [^]u8, pos: int, d: u64, field_lo, cells: int, esc_ends, lax_ends: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (field_lo2, cells2: int, r: hook.Walk_Result, done: bool) {
	return values_run(true, true, true, true, w, opts, hs, base, pos, d, field_lo, cells, esc_ends, lax_ends, on)
}

// Gives a run of a record's cells as values. `ESC` compiles the escape test and the ill-formed UTF-8 test in or out,
// chosen per block. With `KEYS` the record is headed, so each cell's column key precedes its value and the cell's own
// count is that key's index. `PAST` lets that index pass the header's last cell, for `.Ragged`. `QUOTES` compiles in
// the test of a quoted cell, which a text with no quote read so far needs none of.
@(private)
values_run :: #force_inline proc "contextless" ($ESC, $KEYS, $PAST, $QUOTES: bool, w: ^Pass($S, $H, $LAX, $C), opts: Pass_Options, hs: ^hook.Regs, base: [^]u8, pos: int, d: u64, field_lo, cells: int, esc_ends, lax_ends: u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (field_lo2, cells2: int, r: hook.Walk_Result, done: bool) {
	dm := d
	field_lo2, cells2 = field_lo, cells
	for dm != 0 {
		kk := intrinsics.count_trailing_zeros(dm)
		at := pos + int(kk)
		dm &= dm - 1
		esc, lax := false, false
		when ESC {
			esc = esc_ends & (u64(1) << kk) != 0
			lax = lax_ends & (u64(1) << kk) != 0
		}
		when KEYS {
			// A key the hook skips has its cell passed with no token.
			if column_passes(w, cells2) {
				cells2 += 1
				field_lo2 = at + 1
				continue
			}
			k, klo, kn := put_key(PAST, w, hs, cells2, field_lo2, at, on)
			if k == .Stop {
				return field_lo2, cells2, stopped(klo, kn), true
			}
			if k == .Skip {
				cells2 += 1
				field_lo2 = at + 1
				continue
			}
			column_taken(w, cells2)
		}
		if a, lo, n := put_value(w, opts, hs, base, field_lo2, at, esc, lax, QUOTES, on); a == .Stop {
			return field_lo2, cells2, stopped(lo, n), true
		}
		cells2 += 1
		field_lo2 = at + 1
	}
	return
}

// Gives the tokens a block's separators end. The delimiters before the block's next LF are the open record's cells and
// run through a loop of their own, which holds no LF test, no CR, no width check and no `End`, and chooses the record's
// state once per run. The record's last cell and its `End` are the outer loop's work, once per record. `LAX` compiles
// in the spelling of the cells that hold an ill-formed sequence `.Invalid_Utf8` tolerated, whose leads are `ill`. With `LAX_UTF8` every
// block is read with the escape and sequence tests.
@(private)
read_tokens :: #force_inline proc "contextless" ($LAX_UTF8: bool, comments: bool, w: ^Pass($S, $H, $LAX, $C), src: []u8, opts: Pass_Options, pos: int, seps, lfs, clfs, bs, ill: u64, ill_back: int, outer: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) {
	base := raw_data(src)
	// The block's registers are a local whose address reaches no call, each cold call taking a copy, so they stay in
	// registers across the block's tokens.
	regs := outer^
	defer outer^ = regs
	hs := &regs
	// The open record's state is copied into locals for the block, since a field read per cell is a load per cell.
	// `carry` is whether the cell open at the block's start holds an escape from an earlier block.
	rec_lo, field_lo, cells := w.rec_lo, w.field_lo, w.cells
	width := w.width
	header, no_header, muted, open := w.in_header, opts.no_header, w.muted, w.open
	carry := w.field_esc
	// `ill_carry` is whether the cell open at the block's start holds an ill-formed sequence, from the blocks before or
	// from the lead `ill_back` this block's check found.
	ill_carry := false
	when LAX_UTF8 {
		ill_carry = w.open_ill || ill_back >= field_lo
	}
	// The separators that end a cell holding an escape, and one holding an ill-formed sequence. A block where no cell
	// ends with either, which is almost every block, takes the runs with `ESC` false, so the escape work is per block.
	marked := bs | ill != 0 || carry || ill_carry
	esc_ends, lax_ends: u64
	if marked {
		esc_ends = ends_marked(seps, bs, carry)
		lax_ends = ends_marked(seps, ill, ill_carry)
	}
	plain_block := !LAX_UTF8 && esc_ends | lax_ends == 0
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
		if !open && d != 0 {
			open = true
			if !header {
				if rr, stop := open_record(w, src, opts, hs, rec_lo, width, &muted, on); stop {
					return rr, true
				}
			}
		}
		// `dd` says a run of cells ended the walk with the result `rr`.
		rr: hook.Walk_Result
		dd: bool
		if header {
			// The header record's cells are written as the `Key` tokens its columns' cells name them by.
			dm := d
			for dm != 0 {
				kk := intrinsics.count_trailing_zeros(dm)
				at := pos + int(kk)
				dm &= dm - 1
				esc, lax := false, false
				if !plain_block {
					esc = esc_ends & (u64(1) << kk) != 0
					lax = lax_ends & (u64(1) << kk) != 0
				}
				put_header_key(S, w.keys, cells, base, field_lo, at, esc, lax)
				cells += 1
				field_lo = at + 1
			}
		} else if muted {
			// The hook passed this record over, so its cells are counted and its bytes judged, but make no tokens.
			if d != 0 {
				if width != 0 && .Ragged not_in w.tolerate && cells + int(intrinsics.count_ones(d)) >= width {
					return wide_fault(src, rec_lo, width, S, w.delim), true
				}
				cells += int(intrinsics.count_ones(d))
				field_lo = pos + 64 - int(intrinsics.count_leading_zeros(d))
			}
		} else if no_header {
			// No header, so every cell is a value and no key is given.
			if width != 0 && .Ragged not_in w.tolerate && cells + int(intrinsics.count_ones(d)) >= width {
				given := regs
				wide := read_wide(false, w, opts, &given, base, pos, d, cells, field_lo, width, esc_ends, lax_ends, on)
				regs = given
				return wide, true
			}
			if plain_block && !w.quoted {
				field_lo, cells, rr, dd = values_run(false, false, false, false, w, opts, hs, base, pos, d, field_lo, cells, esc_ends, lax_ends, on)
			} else if plain_block {
				field_lo, cells, rr, dd = values_run(false, false, false, true, w, opts, hs, base, pos, d, field_lo, cells, esc_ends, lax_ends, on)
			} else {
				field_lo, cells, rr, dd = values_run(true, false, false, true, w, opts, hs, base, pos, d, field_lo, cells, esc_ends, lax_ends, on)
			}
		} else if cells + int(intrinsics.count_ones(d)) >= width {
			if .Ragged not_in w.tolerate {
				given := regs
				wide := read_wide(true, w, opts, &given, base, pos, d, cells, field_lo, width, esc_ends, lax_ends, on)
				regs = given
				return wide, true
			}
			given := regs
			field_lo, cells, rr, dd = read_ragged(w, opts, &given, base, pos, d, field_lo, cells, esc_ends, lax_ends, on)
			regs = given
		} else if plain_block && !w.quoted {
			// A data record's run of cells, each after its column's key. The cell's own count is the key's index, and
			// the run advances that count only.
			field_lo, cells, rr, dd = values_run(false, true, false, false, w, opts, hs, base, pos, d, field_lo, cells, esc_ends, lax_ends, on)
		} else if plain_block {
			field_lo, cells, rr, dd = values_run(false, true, false, true, w, opts, hs, base, pos, d, field_lo, cells, esc_ends, lax_ends, on)
		} else {
			field_lo, cells, rr, dd = values_run(true, true, false, true, w, opts, hs, base, pos, d, field_lo, cells, esc_ends, lax_ends, on)
		}
		if dd {
			return rr, true
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
		if comments && clfs & (u64(1) << k) != 0 {
			// A comment line is no record: it sets no width, and the line after it starts fresh. It is held until a
			// record or the text's end tells whether it is a `Comment` or the text's foot.
			if w.held == 0 && rec_lo >= w.given {
				w.held = rec_lo + 1
			}
			rec_lo, field_lo = at + 1, at + 1
			drop_line(&m, &lf, d)
			continue
		}
		if !open {
			// An empty line, or a line holding only a CR, is no record: it makes no token and sets no width.
			if hi == rec_lo {
				rec_lo, field_lo = at + 1, at + 1
				drop_line(&m, &lf, d)
				continue
			}
			open = true
			if !header {
				if rr2, stop := open_record(w, src, opts, hs, rec_lo, width, &muted, on); stop {
					return rr2, true
				}
			}
		}
		esc, lax := false, false
		if !plain_block {
			esc = esc_ends & (u64(1) << k) != 0
			lax = lax_ends & (u64(1) << k) != 0
		}
		if header {
			put_header_key(S, w.keys, cells, base, field_lo, hi, esc, lax)
		} else if !muted {
			a, lo, n := put_cell(w, opts, hs, base, cells, field_lo, hi, esc, lax, on)
			if a == .Stop {
				return stopped(lo, n), true
			}
		}
		cells += 1
		field_lo = at + 1
		if fault, wide := record_width(w, cells, &width); fault {
			if wide {
				return wide_fault(src, rec_lo, width, S, w.delim), true
			}
			return fault_at(u64(hi), .Bad_Width, .Too_Few), true
		}
		if !header && !muted && !no_header {
			columns_close(w, cells)
		}
		if !header && !close_record(w, hs, hi, u32(at + 1 - hi), on) {
			return stopped(u64(hi), u32(at + 1 - hi)), true
		}
		when .Walk in C {
			if w.again {
				return hook.walk_result(u64(at + 1), 0), true
			}
		}
		rec_lo, cells, open, muted = at + 1, 0, false, false
		header = false
		drop_line(&m, &lf, d)
	}
	w.rec_lo, w.field_lo, w.cells, w.width = rec_lo, field_lo, cells, width
	w.in_header, w.muted, w.open = header, muted, open
	// The cell still open at the block's end carries its escape state into the next block.
	w.field_esc = false
	when LAX_UTF8 {
		w.open_ill = false
	}
	if marked {
		w.field_esc = span_esc(bs, pos, field_lo, pos + 64, carry)
		when LAX_UTF8 {
			w.open_ill = span_esc(ill, pos, field_lo, pos + 64, ill_carry)
		}
	}
	return 0, false
}

// `read_tokens` on a block that holds an ill-formed sequence `.Invalid_Utf8` tolerated, or that a cell holding one is
// open across. It is a cold copy of the whole reader per hook, so `comments` is a value here and not a parameter, and
// the reader's escape-free runs, which this instance does not use, are left out.
@(private, cold)
read_lax_tokens :: #force_no_inline proc "contextless" (comments: bool, w: ^Pass($S, $H, $LAX, $C), src: []u8, opts: Pass_Options, pos: int, seps, lfs, clfs, bs, ill: u64, ill_back: int, hs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, done: bool) {
	return read_tokens(true, comments, w, src, opts, pos, seps, lfs, clfs, bs, ill, ill_back, hs, on)
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
		put_header_key(S, w.keys, w.cells, base, w.field_lo, hi, esc, w.open_ill)
		_, _ = record_width(w, w.cells + 1, &w.width)
		return 0, false
	}
	if !w.open {
		w.open = true
		if rr, stop := open_record(w, src, opts, hs, w.rec_lo, w.width, &w.muted, on); stop {
			return rr, true
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
		columns_close(w, w.cells + 1)
	}
	if !close_record(w, hs, hi, 0, on) {
		return stopped(u64(hi), 0), true
	}
	return 0, false
}
