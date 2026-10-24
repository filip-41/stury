package csv

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:simd"
import "core:strings"
import "core:unicode/utf8"
import core_pkg "../core"
import "../core/bits"
import "../core/spell"

// Why `marshal` refused: core's `Marshal_Error`. CSV reports `Bad_Utf8` (a string or field name), `Non_Finite`,
// `Unsupported` (a root that is not a list of a struct, or a field whose type `unmarshal` cannot read),
// `Plan_Mismatch`, `Not_A_Member`, `Bad_Option`, `Unwritable` (`Quoting.None`), `Write_Failed`
// (`marshal_to_writer`) and `Out_Of_Memory`. It never reports `Bad_State`, `Too_Deep`, `Cycle` or `Bad_Raw`.
Marshal_Error :: core_pkg.Marshal_Error

// How `marshal` writes: the zero value writes RFC 4180 with a header and LF after each record.
Marshal_Opts :: struct {
	dialect:   Dialect, // `ragged` is not read
	no_header: bool,
	crlf:      bool, // CRLF after each record, as RFC 4180 writes it
}

// Write `v`, a slice or dynamic array of a struct, as CSV that `unmarshal` reads back into equal values: a
// header of the field names, then one record per element, into a new buffer from `allocator`.
//
//	- Under `Quoting.Quotes` a cell holding the delimiter, a quote, CR or LF is quoted, with each quote
//	  doubled. An empty string is `""` and reads back present. A nil `Maybe` is an empty cell.
//	- Under `Quoting.None` a cell is written unchanged. An empty string is an empty cell, which reads back
//	  absent: as the zero string, so in a `Maybe` it is `.Unwritable`. Under `.Backslash` each delimiter, CR,
//	  LF, NUL and backslash is escaped. A cell holding one the dialect cannot escape is `.Unwritable`.
//	- A first cell starting with the comment byte, a BOM at the start of the output, and a number holding the
//	  delimiter are quoted or escaped, or else `.Unwritable`.
//	- A float is its shortest round-trip digits, an enum its member's name (or, under `Plan_Opts.enums =
//	  .Int`, its integer), a bool `true` or `false`.
//
// A record that is empty, or one empty cell (a nil `Maybe`, an empty string under `Quoting.None`), would be a
// blank line, which reads back as no record: `.Unwritable`. With `plan` nil the plan is this thread's cached one
// for `T`. A refusal returns a nil slice.
@(require_results)
marshal :: proc(
	v: $T,
	opts := Marshal_Opts{},
	plan: ^Type_Plan = nil,
	allocator := context.allocator,
) -> (out: []byte, err: Marshal_Error) where intrinsics.type_is_slice(T) || intrinsics.type_is_dynamic_array(T) {
	buf := make([dynamic]u8, allocator)
	if err = marshal_append(&buf, v, opts, plan); err != .None {
		delete(buf)
		return nil, err
	}
	return buf[:], .None
}

// `marshal` appended to `out` as a text of its own: the bytes already in `out` are not part of it, and the
// BOM guard applies only when `out` is empty. On a refusal `out` is as it was on entry; its capacity may have
// grown.
@(require_results)
marshal_append :: proc(
	out: ^[dynamic]u8,
	v: $T,
	opts := Marshal_Opts{},
	plan: ^Type_Plan = nil,
) -> Marshal_Error where intrinsics.type_is_slice(T) || intrinsics.type_is_dynamic_array(T) {
	return marshal_run(out, v, opts, plan, {})
}

// `marshal` written to `w` as the text is made, through a buffer of about `spell.SINK_FLUSH_AT` bytes from
// `allocator`, freed before return. On a refusal `w` may already hold a prefix of the text.
@(require_results)
marshal_to_writer :: proc(
	w: io.Writer,
	v: $T,
	opts := Marshal_Opts{},
	plan: ^Type_Plan = nil,
	allocator := context.allocator,
) -> Marshal_Error where intrinsics.type_is_slice(T) || intrinsics.type_is_dynamic_array(T) {
	buf, aerr := make([dynamic]u8, 0, 2 * spell.SINK_FLUSH_AT, allocator)
	if aerr != nil {
		return .Out_Of_Memory
	}
	defer delete(buf)
	return marshal_run(&buf, v, opts, plan, w)
}

// `v` appended to `buf`, or with `to` set streamed through it.
@(private)
marshal_run :: proc(buf: ^[dynamic]u8, v: $T, opts: Marshal_Opts, plan: ^Type_Plan, to: io.Writer) -> (err: Marshal_Error) {
	w, dialect_ok := spell_writer(opts.dialect, nil, buf.allocator)
	if !dialect_ok {
		return .Bad_Option
	}
	w.hook_text.allocator = buf.allocator
	defer delete(w.hook_text)
	tmp: Type_Plan = ---
	p, ok := plan_for(plan, T, &tmp)
	if !ok {
		return .Plan_Mismatch
	}
	defer plan_done(p, plan, &tmp, err == .Out_Of_Memory)
	w.plan = p
	w.buf = buf^
	start := len(buf^)
	defer {
		buf^ = w.buf
		if err != .None && to.procedure == nil {
			(^runtime.Raw_Dynamic_Array)(buf).len = start
		}
	}
	row := row_op(p) or_return
	switch {
	case w.quotes && w.comment == 0:
		write_chunks(&w, v, row, opts, to, true, false) or_return
	case w.quotes:
		write_chunks(&w, v, row, opts, to, true, true) or_return
	case w.comment == 0:
		write_chunks(&w, v, row, opts, to, false, false) or_return
	case:
		write_chunks(&w, v, row, opts, to, false, true) or_return
	}
	return .None
}

// The header and the records of `v`, all at once, or with `to` set in chunks of records, each written to `to`
// before the next is made. Each chunk's record count is set from the one before it to fill about
// `spell.SINK_FLUSH_AT` bytes.
@(private)
write_chunks :: proc(w: ^Writer, v: $T, row: Plan_Op, opts: Marshal_Opts, to: io.Writer, $Q, $C: bool) -> Marshal_Error {
	if to.procedure == nil {
		return write_records_of(w, v, row, opts, Q, C)
	}
	chunk := 256
	for at, first := 0, true; first || at < len(v); first = false {
		hi := min(len(v), at + chunk)
		o := opts
		o.no_header ||= !first
		write_records_of(w, v[at:hi], row, o, Q, C) or_return
		written := len(w.buf)
		// Every chunk but the last keeps its final line break in the buffer. `put_text`'s BOM guard treats an
		// empty buffer as the output's start, so the buffer must not be empty after the first chunk.
		keep := 0 if hi == len(v) else 1
		if _, err := io.write_full(to, w.buf[:written - keep]); err != nil {
			return .Write_Failed
		}
		remove_range(&w.buf, 0, written - keep)
		chunk = clamp(chunk * spell.SINK_FLUSH_AT / max(written, 1), 1, 1 << 20)
		at = hi
	}
	return .None
}

// The header (unless `opts.no_header`) and the records of `v`, in a dialect that quotes cells (`$Q`) or not, with a
// comment byte (`$C`) or none. A record that writes nothing would be a blank line, which reads back as no
// record, so it is `.Unwritable`. Only a plan of fewer than two fields can write nothing, since two fields
// write a delimiter; `$N` is set for such a plan.
@(private)
write_records :: proc(w: ^Writer, v: $T, row: Plan_Op, opts: Marshal_Opts, $Q, $C, $N: bool) -> Marshal_Error {
	p := w.plan
	if !opts.no_header {
		head_at := len(w.buf)
		for f, k in p.fields[row.elem:][:row.count] {
			if k > 0 {
				put(w, w.delim) or_return
			}
			put_text(w, string(p.keys[f.key_lo:f.key_hi]), Q) or_return
		}
		guard_record(w, head_at) or_return
		when N {
			if len(w.buf) == head_at {
				return .Unwritable
			}
		}
		put_break(w, opts.crlf) or_return
	}
	for &e in v {
		when C || N {
			rec_at := len(w.buf)
		}
		for f, k in p.fields[row.elem:][:row.count] {
			if k > 0 {
				put(w, w.delim) or_return
			}
			at := len(w.buf)
			put_cell(w, &p.ops[f.op], rawptr(uintptr(&e) + f.offset), Q) or_return
			if w.in_numbers {
				quote_number(w, at) or_return
			}
		}
		when C {
			guard_record(w, rec_at) or_return
		}
		when N {
			if len(w.buf) == rec_at {
				return .Unwritable
			}
		}
		put_break(w, opts.crlf) or_return
	}
	return .None
}

// `write_records` for the plan's width.
@(private)
write_records_of :: proc(w: ^Writer, v: $T, row: Plan_Op, opts: Marshal_Opts, $Q, $C: bool) -> Marshal_Error {
	if row.count < 2 {
		return write_records(w, v, row, opts, Q, C, true)
	}
	return write_records(w, v, row, opts, Q, C, false)
}

@(private)
Writer :: struct {
	plan:       ^Type_Plan,
	buf:        [dynamic]u8,
	delim:      byte,
	comment:    byte, // 0 for none
	// An empty `buf` is the output's start, where a cell starting with a BOM would read as the text's BOM.
	at_start:   bool,
	quotes:     bool,
	escapes:    bool,
	in_numbers: bool, // the delimiter is a byte a spelled number may hold
	hook_text:  [dynamic]u8, // the text a write hook made, before it is quoted
	// Per byte: `SPECIAL` when `put_text` quotes or escapes a cell holding it, `HIGH` when it is not ASCII.
	class:      [256]u8,
}

@(private)
SPECIAL :: 1
@(private)
HIGH :: 2

// A writer over `plan` for `dialect`. `ok` is false for a dialect the scanner refuses.
@(private)
spell_writer :: proc(dialect: Dialect, plan: ^Type_Plan, allocator: runtime.Allocator) -> (w: Writer, ok: bool) {
	s := scan_setup(dialect, {}) or_return
	w = Writer{plan = plan, delim = s.delim, quotes = .Unquoted not_in s.mode, escapes = .Escapes in s.mode, comment = s.comment, at_start = true}
	w.in_numbers = strings.index_byte("0123456789+-.eE", w.delim) >= 0
	for c in 0x80 ..< 0x100 {
		w.class[c] = HIGH
	}
	w.class[w.delim], w.class['\r'], w.class['\n'] = SPECIAL, SPECIAL, SPECIAL
	if w.quotes {
		w.class['"'] = SPECIAL
	} else {
		w.class['\\'], w.class[0] = SPECIAL, SPECIAL
	}
	w.buf = make([dynamic]u8, allocator)
	return w, true
}

// Quotes the cell written from `at` when it is a number holding the delimiter. `put_text` already quotes every
// other cell that needs it.
@(private)
quote_number :: proc(w: ^Writer, at: int) -> Marshal_Error {
	n := len(w.buf) - at
	if n == 0 || w.buf[at] == '"' || strings.index_byte(string(w.buf[at:]), w.delim) < 0 {
		return .None
	}
	if !w.quotes {
		return .Unwritable
	}
	room(w, 2) or_return
	commit(w, 2)
	cell := w.buf[at:]
	copy(cell[1:], cell[:n])
	cell[0], cell[n + 1] = '"', '"'
	return .None
}

// The element's struct op of the plan's list, every field one `put_cell` writes.
@(private)
row_op :: proc(p: ^Type_Plan) -> (row: Plan_Op, err: Marshal_Error) {
	root := plan_op(p, type_info_of(p.root)) or_return
	return cell_struct(p, p.ops[root].elem)
}

// The struct op at `idx`, every field one `put_cell` writes.
@(private)
cell_struct :: proc(p: ^Type_Plan, idx: u32) -> (op: Plan_Op, err: Marshal_Error) {
	op = p.ops[idx]
	if op.kind != .Struct || op.refused {
		return {}, .Unsupported
	}
	for f in p.fields[op.elem:][:op.count] {
		if !writes_cell(p, p.ops[f.op]) {
			return {}, .Unsupported
		}
	}
	return
}

@(private)
Plan_Op :: core_pkg.Plan_Op

@(private)
writes_cell :: proc(p: ^Type_Plan, op: Plan_Op) -> bool {
	if op.kind == .Hook {
		return p.writes[op.elem] != nil
	}
	if op.kind == .Union {
		ti := runtime.type_info_base(op.info).variant.(runtime.Type_Info_Union)
		return op.count == 1 && ti.tag_type != nil && writes_cell(p, p.ops[p.fields[op.elem].op])
	}
	return is_cell_kind(op.kind, op.size)
}

@(private)
put_cell :: proc(w: ^Writer, op: ^Plan_Op, data: rawptr, $Q: bool) -> Marshal_Error {
	#partial switch op.kind {
	case .Bool:
		return put_text(w, "true" if #force_inline core_pkg.shape_uint_load(data, op.size) != 0 else "false", Q)
	case .Int:
		p := room(w, spell.INT_ROOM) or_return
		commit(w, spell.spell_i64(p, #force_inline core_pkg.shape_int_load(data, op.size)))
		return .None
	case .Uint:
		p := room(w, spell.INT_ROOM) or_return
		commit(w, spell.spell_u64(p, #force_inline core_pkg.shape_uint_load(data, op.size)))
		return .None
	case .Wide_Int, .Wide_Uint:
		buf: [48]u8
		return put_text(w, spell.spell_u128(buf[:], (^u128)(data)^, op.kind == .Wide_Int), Q)
	case .Float:
		x := #force_inline core_pkg.shape_float_load(data, op.size)
		if spell.is_non_finite(x) {
			return .Non_Finite
		}
		p := room(w, spell.F64_ROOM) or_return
		commit(w, spell.spell_f64(p, x))
		return .None
	case .Enum_Int, .Enum_Uint:
		v := core_pkg.plan_enum_value(op^, data)
		if w.plan.opts.enums == .Int {
			p := room(w, spell.INT_ROOM) or_return
			commit(w, spell.spell_i64(p, v) if op.kind == .Enum_Int else spell.spell_u64(p, u64(v)))
			return .None
		}
		m, found := core_pkg.plan_enum_member(w.plan, op^, v)
		if !found {
			return .Not_A_Member
		}
		return put_text(w, string(w.plan.keys[m.lo:m.hi]), Q)
	case .Rune:
		r := (^rune)(data)^
		bytes, n := utf8.encode_rune(r)
		if !utf8.valid_rune(r) {
			return .Bad_Utf8
		}
		return put_text(w, string(bytes[:n]), Q)
	case .String:
		s := (^string)(data)^
		if len(s) == 0 {
			return put_empty(w, Q)
		}
		return put_text(w, s, Q)
	case .Cstring:
		c := (^cstring)(data)^
		if c == nil {
			return .None
		}
		return put_text(w, string(c), Q) if len(c) > 0 else put_empty(w, Q)
	case .Union:
		ti := runtime.type_info_base(op.info).variant.(runtime.Type_Info_Union)
		arm := w.plan.fields[op.elem]
		if #force_inline core_pkg.shape_uint_load(rawptr(uintptr(data) + ti.tag_offset), u8(ti.tag_type.size)) != u64(arm.offset) {
			return .None
		}
		when !Q {
			// An empty cell reads back as no value, not as an empty one.
			p := &w.plan.ops[arm.op]
			if p.kind == .String && len((^string)(data)^) == 0 {
				return .Unwritable
			}
			if p.kind == .Hook {
				return put_hooked(w, p, data, Q, true)
			}
		}
		return put_cell(w, &w.plan.ops[arm.op], data, Q)
	}
	return put_other(w, op, data, Q)
}

// The kinds `put_cell` has no case for, kept out of its switch so that hooks cost the plain kinds nothing.
@(cold, private)
put_other ::proc(w: ^Writer, op: ^Plan_Op, data: rawptr, $Q: bool) -> Marshal_Error {
	if op.kind == .Hook {
		return put_hooked(w, op, data, Q, false)
	}
	return .Unsupported
}

// The text the hook of `op` writes for the value at `data`, as one cell. An empty text is an empty string.
// When `maybe` (the value of a `Maybe`) and no cell is quoted, an empty text is `.Unwritable`.
@(private)
put_hooked :: proc(w: ^Writer, op: ^Plan_Op, data: rawptr, $Q: bool, maybe: bool) -> Marshal_Error {
	clear(&w.hook_text)
	w.plan.writes[op.elem](&w.hook_text, data) or_return
	text := string(w.hook_text[:])
	if len(text) == 0 {
		when !Q {
			if maybe {
				return .Unwritable
			}
		}
		return put_empty(w, Q)
	}
	return put_text(w, text, Q)
}

// An empty text: `""`, or an empty cell where no cell is quoted.
@(private)
put_empty :: proc(w: ^Writer, $Q: bool) -> Marshal_Error {
	when Q {
		p := room(w, 2) or_return
		p[0], p[1] = '"', '"'
		commit(w, 2)
	}
	return .None
}

// `s` as one cell. Where cells are quoted, it is quoted when it holds the delimiter, a quote, CR or LF.
// Where they are not, `put_unquoted` writes it when it holds the delimiter, a backslash, CR or LF.
@(private)
put_text :: proc(w: ^Writer, s: string, $Q: bool) -> Marshal_Error {
	p := room(w, 2 * len(s) + 2) or_return
	special, high := scan_text(w, s, Q)
	// A BOM at the start of the output would read as the text's BOM, not the cell's.
	special |= len(w.buf) == 0 && w.at_start && core_pkg.bom_len(transmute([]byte)s) > 0
	if high && !utf8.valid_string(s) {
		return .Bad_Utf8
	}
	if !special {
		copy_text(p, s)
		commit(w, len(s))
		return .None
	}
	when !Q {
		return put_unquoted(w, s, p)
	}
	// A 16-byte window with no quote is stored whole. `p` has room for twice `s` plus two quotes, so the store
	// stays inside it however many quotes came before.
	p[0] = '"'
	src := raw_data(s)
	i, n := 0, 1
	for i + 16 <= len(s) {
		v := bits.load(src[i:])
		intrinsics.unaligned_store((^bits.V)(p[n:]), v)
		if !bits.any_eq(v, '"') {
			i += 16
			n += 16
			continue
		}
		n = put_doubled(p, n, src, i, i + 16)
		i += 16
	}
	n = put_doubled(p, n, src, i, len(s))
	p[n] = '"'
	commit(w, n + 1)
	return .None
}

// `src[i:end]` written to `p` from `n`, each quote doubled; where the write ends.
@(private)
put_doubled :: #force_inline proc(p: [^]u8, n: int, src: [^]u8, i, end: int) -> int {
	n := n
	for k in i ..< end {
		c := src[k]
		p[n] = c
		n += 1
		if c == '"' {
			p[n] = '"'
			n += 1
		}
	}
	return n
}

// `s` copied to `p`, which has room for it. A short text is copied by two overlapping loads and stores of its
// size class, a longer one by 16-byte windows, the last overlapping the one before.
@(private)
copy_text :: #force_inline proc(p: [^]u8, s: string) {
	n := len(s)
	src := raw_data(s)
	switch {
	case n > 64:
		intrinsics.mem_copy_non_overlapping(p, src, n)
	case n >= 16:
		for i := 0; i < n - 16; i += 16 {
			intrinsics.unaligned_store((^bits.V)(p[i:]), bits.load(src[i:]))
		}
		intrinsics.unaligned_store((^bits.V)(p[n - 16:]), bits.load(src[n - 16:]))
	case n >= 8:
		a, b := intrinsics.unaligned_load((^u64)(src)), intrinsics.unaligned_load((^u64)(src[n - 8:]))
		intrinsics.unaligned_store((^u64)(p), a)
		intrinsics.unaligned_store((^u64)(p[n - 8:]), b)
	case n >= 4:
		a, b := intrinsics.unaligned_load((^u32)(src)), intrinsics.unaligned_load((^u32)(src[n - 4:]))
		intrinsics.unaligned_store((^u32)(p), a)
		intrinsics.unaligned_store((^u32)(p[n - 4:]), b)
	case n > 0:
		p[0], p[n / 2], p[n - 1] = src[0], src[n / 2], src[n - 1]
	}
}

// `s` as a cell of a dialect with no quotes. Under `.Backslash` each delimiter, CR, LF, NUL and backslash is
// escaped. A delimiter, CR or LF the dialect cannot escape, or a BOM at the start of the output, is
// `.Unwritable`. `p` has room for twice `s`.
@(cold, private)
put_unquoted :: proc(w: ^Writer, s: string, p: [^]u8) -> Marshal_Error {
	if len(w.buf) == 0 && w.at_start && core_pkg.bom_len(transmute([]byte)s) > 0 {
		return .Unwritable
	}
	n := 0
	for c in transmute([]byte)s {
		if c == w.delim || c == '\r' || c == '\n' || (c == '\\' || c == 0) && w.escapes {
			p[n], p[n + 1] = '\\', escape_letter(c)
			if !w.escapes || p[n + 1] == 0 {
				return .Unwritable
			}
			n += 2
		} else {
			p[n] = c
			n += 1
		}
	}
	commit(w, n)
	return .None
}

// The letter that escapes `c` after a backslash, or 0 for a byte no escape spells.
@(private)
escape_letter :: proc(c: byte) -> byte {
	switch c {
	case '\t':
		return 't'
	case '\n':
		return 'n'
	case '\r':
		return 'r'
	case '\\':
		return '\\'
	case 0:
		return '0'
	}
	return 0
}

// Makes the record written from `at`, whose first cell starts with the comment byte, read back as a record:
// quotes that cell, escapes its first byte when the comment byte is a tab, or returns `.Unwritable`. The cell
// holds nothing `put_text` quotes.
@(cold, private)
guard_comment :: proc(w: ^Writer, at: int) -> Marshal_Error {
	switch {
	case w.quotes:
		end := at
		for end < len(w.buf) && w.buf[end] != w.delim {
			end += 1
		}
		if _, err := inject_at(&w.buf, end, '"'); err != nil {
			return .Out_Of_Memory
		}
		if _, err := inject_at(&w.buf, at, '"'); err != nil {
			return .Out_Of_Memory
		}
	case w.escapes && w.comment == '\t':
		w.buf[at] = '\\'
		if _, err := inject_at(&w.buf, at + 1, 't'); err != nil {
			return .Out_Of_Memory
		}
	case:
		return .Unwritable
	}
	return .None
}

// Makes the record starting at `from` in `w.buf` read back as a record when its first cell starts with the
// comment byte (`guard_comment`).
@(private)
guard_record :: #force_inline proc(w: ^Writer, from: int) -> Marshal_Error {
	if w.comment != 0 && len(w.buf) > from && w.buf[from] == w.comment {
		return guard_comment(w, from)
	}
	return .None
}

// Whether `s` holds the delimiter, CR, LF, and a quote (under `$Q`) or a backslash or NUL (otherwise), and
// whether it holds a non-ASCII byte. A short text is read one byte at a time through `w.class`.
@(private)
scan_text :: #force_inline proc(w: ^Writer, s: string, $Q: bool) -> (special, high: bool) {
	n := len(s)
	p := raw_data(s)
	delim := w.delim
	if n < 16 {
		class: u8
		for c in transmute([]byte)s {
			class |= w.class[c]
		}
		return class & SPECIAL != 0, class & HIGH != 0
	}
	dv, qv, cv, lv := bits.V(delim), bits.V('"' when Q else '\\'), bits.V('\r'), bits.V('\n')
	// 16-byte windows, the last one overlapping the one before.
	for k := 0; ; k += 16 {
		i := min(k, n - 16)
		v := bits.load(p[i:])
		m := simd.lanes_eq(v, dv) | simd.lanes_eq(v, qv) | simd.lanes_eq(v, cv) | simd.lanes_eq(v, lv)
		when !Q {
			m |= simd.lanes_eq(v, bits.V(0))
		}
		special |= bits.any_lane(m)
		high |= bits.any_high(v)
		if i == n - 16 {
			return
		}
	}
}

@(private)
put_break :: proc(w: ^Writer, crlf: bool) -> Marshal_Error {
	p := room(w, 2) or_return
	n := 1
	if crlf {
		p[0] = '\r'
		n = 2
	}
	p[n - 1] = '\n'
	commit(w, n)
	return .None
}

@(private)
put :: #force_inline proc(w: ^Writer, c: byte) -> Marshal_Error {
	p := room(w, 1) or_return
	p[0] = c
	commit(w, 1)
	return .None
}

// Room for `n` more bytes past the buffer's end, whose start is returned. `commit` counts those written.
@(private)
room :: #force_inline proc(w: ^Writer, n: int) -> (p: [^]u8, err: Marshal_Error) {
	if cap(w.buf) - len(w.buf) < n {
		if non_zero_reserve(&w.buf, max(2 * cap(w.buf), len(w.buf) + n, 4096)) != nil {
			return nil, .Out_Of_Memory
		}
	}
	return raw_data(w.buf)[len(w.buf):], .None
}

@(private)
commit :: #force_inline proc(w: ^Writer, n: int) {
	(^runtime.Raw_Dynamic_Array)(&w.buf).len += n
}
