package csv

import "base:intrinsics"
import "base:runtime"
import "core:simd"
import core_pkg "../core"

// One field's bytes as written, `src[lo:hi]`. A quoted field's quotes are included; a CR before the record's
// LF is not. `field_text` reads its text.
Field :: struct {
	lo, hi: u64,
}

// One record: its fields, which index `src` and are valid until the next `next_record`, and `at`, the offset
// of its first byte in the input. `src` is the input for `records` and `each_record`, and the reader's window
// for `records_from`. `dialect` is the one the record was read in, its delimiter spelled out; `field_text`
// decodes the fields by it.
Record :: struct {
	fields:  []Field,
	at:      u64,
	src:     []byte,
	dialect: Dialect,
}

// A pull iterator over an input's records (`next_record`). Its `state` is internal; `err` is the fault that
// ended it. A record is yielded only after every byte up to its end is checked, so the records before a
// fault are yielded and the one holding it is not.
Records :: struct {
	using state: Records_State,
	err:         Maybe(Error),
}

@(private)
Records_State :: struct {
	src:      []byte,
	// The block being read starts at `block`. `seps` are its separators not yet read, of which `lfs` end records.
	block:    int,
	seps:     u64,
	lfs:      u64,
	carry:    Carry,
	// The block's fault. It lies past the last separator in `seps`.
	fault:    Maybe(Error),
	// The start of the open field and of the open record.
	field_lo: int,
	rec_lo:   int,
	fields:   [dynamic]Field,
	width:    int, // the first record's field count, 0 until it is read
	scan:     Scan,
	// `records_past_stop` reads the blocks at or past `stop`: the input's end, the block holding the first byte
	// past the open line's cap, or under `more` the bytes not yet read.
	stop:     int,
	// `records_from`'s window: the input continues past `src`. A block is read only once `src` holds it and the
	// `READ_AHEAD` bytes a UTF-8 sequence starting in it could reach. `starved` is set when `src` runs out.
	more:     bool,
	starved:  bool,
	ended:    bool,
}

// The records of `src` in `opts.dialect`, judged at `opts.strictness` (`.Lazy` is `.Structural`) and capped by
// `opts.limits`; `opts.duplicates` and `opts.no_header` are not read. A dialect or limit the scanner refuses is
// `.Bad_Option` on `err`. Record fields are allocated with `allocator`; `destroy` frees them.
@(require_results)
records :: proc(src: []byte, opts := Read_Opts{}, allocator := context.allocator) -> (it: Records) {
	s, ok := scan_setup(opts.dialect, opts.limits, opts.strictness)
	it = records_of(src, s, allocator)
	if !ok {
		it.err = Error{kind = .Bad_Option}
	}
	return
}

@(private)
records_of :: proc(src: []byte, s: Scan, allocator: runtime.Allocator) -> (it: Records) {
	start := core_pkg.bom_len(src)
	it = {src = src, block = start - 64, carry = CARRY_START, field_lo = start, rec_lo = start, scan = s}
	it.stop = len(src) if s.max_bytes == 0 else 0
	it.fields.allocator = allocator
	return
}

@(private)
records_free :: proc(it: ^Records) {
	delete(it.fields)
	it.fields = {}
}

// The next record, or false at the end or on a fault in `it.err`. From a `Record_Reader`, also false on a
// failure of the reader in `read_err`.
next_record :: proc {
	next_slice_record,
	next_reader_record,
}

// A record's fields are cleared only when it is yielded, so when `records_from` calls again after reading more
// input, it resumes the record it was reading. The list holds only the open record, and its capacity never
// exceeds `max_fields`.
@(private, require_results)
next_slice_record :: proc(it: ^Records) -> (rec: Record, ok: bool) {
	return scan_record(it, it, Field, Record)
}

// Where a record's cells go: `Records` keeps them as the `Field`s of its open record; a document's `Row_Build`
// writes them as rows. Each sink has a `sink_cells` (its open record's cells, as a list of `C`), a `cell_put`
// (one cell, false on a fault in `it.err`), a `cells_reserve` (room for `need` cells, false on a fault) and a
// `cells_take` (the record at `lo` once its cells are in, as an `R`, false on a fault).
@(private)
sink_cells :: proc {
	field_cells,
	row_cells,
}

@(private)
cell_put :: proc {
	field_put,
	row_put,
}

@(private)
cells_reserve :: proc {
	reserve_fields,
	reserve_cells,
}

@(private)
cells_take :: proc {
	take_fields,
	take_cells,
}

// The cells of the next record onto `sink`, as `C`s, and the record as the sink takes it, or false at the end or on
// a fault in `it.err`. The open record's cells are `sink_cells(sink)`, kept across calls until the sink takes them.
@(private, require_results)
scan_record :: #force_inline proc(it: ^Records, sink: ^$S, $C, $R: typeid) -> (out: R, ok: bool) {
	if it.err != nil {
		return
	}
	src := it.src
	for {
		for it.seps == 0 {
			if it.fault != nil {
				it.err = it.fault
				return
			}
			it.block += 64
			if it.block >= it.stop {
				switch records_past_stop(it) {
				case .Scan:
				case .Scanned:
					continue
				case .Starved:
					return
				case .Ended:
					return last_cells(it, sink, C, R)
				}
			}
			fault: int
			kind: Error_Kind
			if it.scan.mode == {} {
				it.seps, it.lfs, fault, kind = scan_block(src, it.block, it.scan.delim, 0, &it.carry, {})
			} else {
				it.seps, it.lfs, fault, kind = scan_dialect_block(it)
			}
			if fault >= 0 {
				cut_block(it, &it.seps, &it.lfs, fault, Error{offset = u64(fault), kind = kind})
			}
		}
		// The block's separators and the cells' count are kept in locals. They are written back to `it` and the
		// sink before any return, rescan or growth.
		seps, lfs, field_lo, block := it.seps, it.lfs, it.field_lo, it.block
		cells := sink_cells(sink)
		data, n := ([^]C)(cells.data), cells.len
		limit := cells.cap
		for seps != 0 {
			// The delimiters before the record's LF (or the block's end) all end fields of the open record. Room
			// for them is reserved once, then each field is one put.
			end := lfs & seps
			before := (end & -end) - 1
			if delims := seps & before; delims != 0 {
				if k := int(intrinsics.count_ones(delims)); limit - n < k {
					cells.len = n
					if !cells_reserve(it, sink, n + k) {
						return
					}
					data = ([^]C)(cells.data)
					limit = cells.cap
				}
				for delims != 0 {
					at := block + int(intrinsics.count_trailing_zeros(delims))
					delims &= delims - 1
					if !cell_put(it, sink, src, data, n, field_lo, at) {
						return
					}
					n += 1
					field_lo = at + 1
				}
				seps &= ~before
			}
			if seps == 0 {
				break
			}
			at := block + int(intrinsics.count_trailing_zeros(seps))
			seps &= seps - 1
			hi := at
			if hi > field_lo && src[hi - 1] == '\r' {
				hi -= 1
			}
			if n >= limit {
				cells.len = n
				if !cells_reserve(it, sink, n + 1) {
					return
				}
				data = ([^]C)(cells.data)
				limit = cells.cap
			}
			if !cell_put(it, sink, src, data, n, field_lo, hi) {
				return
			}
			n += 1
			field_lo = at + 1
			cells.len = n
			it.seps, it.field_lo = seps, field_lo
			lo := it.rec_lo
			it.rec_lo = at + 1
			if n == 1 && skip_line(it, lo, at) {
				n = 0
				continue
			}
			return cells_take(it, sink, lo)
		}
		cells.len = n
		it.seps, it.field_lo = 0, field_lo
	}
}

@(private)
Past_Stop :: enum u8 {
	Scan,    // read the block normally
	Scanned, // the block is read and its line cap checked
	Starved, // `src` does not hold the block yet
	Ended,   // past the input's last block
}

// What `next_record` does with the block at `it.block`, which is at or past `it.stop`. Sets the next `stop`.
@(cold, private)
records_past_stop :: proc(it: ^Records) -> Past_Stop {
	n := len(it.src)
	if it.more && it.block + 64 + READ_AHEAD > n {
		it.block -= 64
		it.starved = true
		return .Starved
	}
	if it.block >= n {
		return .Ended
	}
	if stop := line_cap_stop(it.block, it.rec_lo, it.scan.max_bytes, n); stop > it.block {
		it.stop = min(stop, n - 64 - READ_AHEAD + 1) if it.more else stop
		return .Scan
	}
	seps, lfs, fault, kind := scan_dialect_block(it)
	if fault >= 0 {
		cut_block(it, &seps, &lfs, fault, Error{offset = u64(fault), kind = kind})
	}
	if at, lo := line_cap_fault(lfs, it.block, it.rec_lo, it.scan.max_bytes, n); at >= 0 && (fault < 0 || at < fault) {
		cut_block(it, &seps, &lfs, at, fault_error(u64(lo), .Record_Too_Long))
	}
	it.seps, it.lfs = seps, lfs
	// The next block checks the cap of the line open at its start.
	it.stop = it.block + 64
	return .Scanned
}

// The block at `it.block` in the iterator's scan mode.
@(private)
scan_dialect_block :: proc(it: ^Records) -> (seps, lfs: u64, fault: int, kind: Error_Kind) {
	src, pos, d, c, cy := it.src, it.block, it.scan.delim, it.scan.comment, &it.carry
	switch it.scan.mode {
	case {}:
		return scan_block(src, pos, d, c, cy, {})
	case {.Skip_Utf8}:
		return scan_block(src, pos, d, c, cy, {.Skip_Utf8})
	case {.Comments}:
		return scan_block(src, pos, d, c, cy, {.Comments})
	case {.Comments, .Skip_Utf8}:
		return scan_block(src, pos, d, c, cy, {.Comments, .Skip_Utf8})
	case {.Unquoted}:
		return scan_block(src, pos, d, c, cy, {.Unquoted})
	case {.Unquoted, .Skip_Utf8}:
		return scan_block(src, pos, d, c, cy, {.Unquoted, .Skip_Utf8})
	case {.Unquoted, .Comments}:
		return scan_block(src, pos, d, c, cy, {.Unquoted, .Comments})
	case {.Unquoted, .Comments, .Skip_Utf8}:
		return scan_block(src, pos, d, c, cy, {.Unquoted, .Comments, .Skip_Utf8})
	case {.Unquoted, .Escapes}:
		return scan_block(src, pos, d, c, cy, {.Unquoted, .Escapes})
	case {.Unquoted, .Escapes, .Skip_Utf8}:
		return scan_block(src, pos, d, c, cy, {.Unquoted, .Escapes, .Skip_Utf8})
	case {.Unquoted, .Escapes, .Comments}:
		return scan_block(src, pos, d, c, cy, {.Unquoted, .Escapes, .Comments})
	case {.Unquoted, .Escapes, .Comments, .Skip_Utf8}:
		return scan_block(src, pos, d, c, cy, {.Unquoted, .Escapes, .Comments, .Skip_Utf8})
	}
	unreachable()
}

// Drops the block's separators and LFs from `at` on, where `fault` stops the read.
@(private)
cut_block :: #force_inline proc(it: ^Records, seps, lfs: ^u64, at: int, fault: Error) {
	cut := u64(1) << u64(max(at - it.block, 0)) - 1
	seps^ &= cut
	lfs^ &= cut
	it.fault = fault
}

// The cells of the record after the last LF onto `sink`, once the input's end is checked.
@(private)
last_cells :: proc(it: ^Records, sink: ^$S, $C, $R: typeid) -> (out: R, ok: bool) {
	if it.ended {
		return
	}
	it.ended = true
	if fault, kind := scan_end(it.src, &it.carry); fault >= 0 {
		it.err = Error{offset = u64(fault), kind = kind}
		return
	}
	if it.rec_lo == len(it.src) {
		return
	}
	cells := sink_cells(sink)
	n := cells.len
	if n >= cells.cap && !cells_reserve(it, sink, n + 1) {
		return
	}
	if !cell_put(it, sink, it.src, ([^]C)(cells.data), n, it.field_lo, len(it.src)) {
		return
	}
	cells.len = n + 1
	if n == 0 && skip_line(it, it.rec_lo, len(it.src)) {
		return
	}
	return cells_take(it, sink, it.rec_lo)
}

@(private)
take_fields :: #force_inline proc(it: ^Records, _: ^Records, lo: int) -> (rec: Record, ok: bool) {
	return yield(it, lo)
}

@(private)
field_cells :: #force_inline proc(it: ^Records) -> ^runtime.Raw_Dynamic_Array {
	return (^runtime.Raw_Dynamic_Array)(&it.fields)
}

@(private)
field_put :: #force_inline proc(_: ^Records, _: ^Records, _: []byte, data: [^]Field, n, lo, hi: int) -> bool {
	data[n] = {u64(lo), u64(hi)}
	return true
}

// Reserves room for `need` fields of the open record. Capacity never exceeds `max_fields`; a record that needs
// more is refused.
@(cold, private)
reserve_fields :: proc(it: ^Records, _: ^Records, need: int) -> bool {
	if need > it.scan.max_fields {
		it.err = fault_error(u64(it.rec_lo), .Too_Many_Fields)
		return false
	}
	if need > cap(it.fields) && reserve(&it.fields, min(max(2 * cap(it.fields), need, 16), it.scan.max_fields)) != nil {
		it.err = Error{kind = .Out_Of_Memory}
		return false
	}
	return true
}

// Whether the one-field line `src[lo:hi]` holds no record: it is blank, or a comment.
@(private)
skip_line :: #force_inline proc(it: ^Records, lo, hi: int) -> bool {
	return blank(it.src, lo, hi) || .Comments in it.scan.mode && it.src[lo] == it.scan.comment
}

@(private)
yield :: #force_inline proc(it: ^Records, lo: int) -> (rec: Record, ok: bool) {
	if !width_ok(it, len(it.fields), lo) {
		return
	}
	rec = {fields = it.fields[:], at = u64(lo), src = it.src, dialect = it.scan.dialect}
	clear(&it.fields)
	return rec, true
}

// Whether the record at `lo`, of `n` fields, keeps the field count; its fault in `it.err` when not.
@(private)
width_ok :: #force_inline proc(it: ^Records, n, lo: int) -> bool {
	if n != it.width {
		f: Fault
		if f, it.width = record_fault(it.width, n, it.scan); f != .None {
			it.err = fault_error(u64(lo), f)
			return false
		}
	}
	return true
}

// The text of field `k` of `rec`, read in the record's dialect. A quoted field loses its quotes and reads each
// `""` as one quote. Under `.Backslash` each escape reads as the byte it spells. A field with nothing to decode is
// a slice of `rec.src`, with `escaped` false. A field with `""` or an escape is decoded into `allocator`, with
// `escaped` true; the caller frees it.
@(require_results)
field_text :: #force_inline proc(rec: Record, k: int, allocator := context.allocator) -> (text: string, escaped: bool, err: runtime.Allocator_Error) {
	return cell_text(rec.src, rec.fields[k], rec.dialect, allocator)
}

// `field_text` of `f`, a field the scanner read from `src` in `dialect`.
@(private, require_results)
cell_text :: #force_inline proc(src: []byte, f: Field, dialect: Dialect, allocator: runtime.Allocator) -> (text: string, escaped: bool, err: runtime.Allocator_Error) {
	// `src[f.lo:f.hi]`'s bounds check, in two unsigned compares.
	if f.lo > f.hi || f.hi > u64(len(src)) {
		runtime.slice_expr_error_lo_hi_loc(lo = int(f.lo), hi = int(f.hi), len = len(src))
	}
	view, decode := field_view(src, f, dialect)
	if decode {
		return field_decode(view, dialect, allocator)
	}
	return string(view), false, nil
}

// The text of `f` as written, without a quoted field's quotes, and whether it holds a `""` or an escape for
// `field_decode`. Inline so that a field with nothing to decode costs no call. `f` must be a field the scanner
// read from `src`: inside `src`, and at least two bytes long if quoted.
@(private)
field_view :: #force_inline proc(src: []byte, f: Field, dialect: Dialect) -> (text: []byte, decode: bool) #no_bounds_check {
	text = src[f.lo:f.hi]
	switch {
	case dialect.quoting == .Quotes && len(text) > 0 && text[0] == '"':
		return text[1:len(text) - 1], holds_span(src, int(f.lo) + 1, len(text) - 2, '"')
	case dialect.quoting == .Backslash:
		return text, holds_span(src, int(f.lo), len(text), '\\')
	}
	return text, false
}

// Whether `src[lo:][:n]` holds `c`. When the span is at most 16 bytes and `src` has 16 bytes from `lo`, one
// masked load answers, with no per-field loop exit to mispredict.
@(private)
holds_span :: #force_inline proc(src: []byte, lo, n: int, c: byte) -> bool {
	if n <= 16 && len(src) - lo >= 16 {
		LANES :: core_pkg.V{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
		v := core_pkg.load(raw_data(src)[lo:])
		return core_pkg.any_lane(simd.lanes_eq(v, core_pkg.V(c)) & simd.lanes_lt(LANES, core_pkg.V(u8(n))))
	}
	return holds(string(src[lo:][:n]), c)
}

// `text`, a `field_view` holding a `""` or an escape, decoded into `allocator` (`field_unescape`).
@(private)
field_decode :: proc(text: []byte, dialect: Dialect, allocator: runtime.Allocator) -> (out: string, escaped: bool, err: runtime.Allocator_Error) {
	buf := runtime.mem_alloc_non_zeroed(len(text), 1, allocator) or_return
	return string(buf[:field_unescape(text, buf, dialect)]), true, nil
}

// Decodes `text`, a `field_view`, into `out`, which holds `len(text)` bytes, and returns the decoded length. Each
// `""` reads as one quote, or under `Quoting.Backslash` each backslash escape as the byte it spells. A 16-byte window
// with no quote or backslash is copied whole. The decoded text is never longer than `text`, so the store stays
// inside `out`.
@(private)
field_unescape :: proc(text, out: []byte, dialect: Dialect) -> int {
	mark := byte('\\') if dialect.quoting == .Backslash else '"'
	src, dst := raw_data(text), raw_data(out)
	i, n := 0, 0
	step :: #force_inline proc(src, dst: [^]byte, i, n: ^int, mark: byte) {
		c := src[i^]
		i^ += 1
		// The scanner accepted only doubled quotes and the five escapes, each complete inside its field.
		if c == mark {
			c = unescaped(src[i^]) if mark == '\\' else c
			i^ += 1
		}
		dst[n^] = c
		n^ += 1
	}
	// A window is stored whole, then the text resumes past its first mark: a mark costs one window, not a step
	// per byte. `n <= i`, so the store stays inside `out`.
	LANES :: core_pkg.V{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
	marked := 0 // past the last mark read: the bytes from here on are copied one to one
	for i + 16 <= len(text) {
		v := core_pkg.load(src[i:])
		intrinsics.unaligned_store((^core_pkg.V)(dst[n:]), v)
		first := int(simd.reduce_min(simd.select(simd.lanes_eq(v, core_pkg.V(mark)), LANES, core_pkg.V(16))))
		if first == 16 {
			i += 16
			n += 16
			continue
		}
		i += first
		n += first
		step(src, dst, &i, &n, mark)
		marked = i
	}
	// The last window ends at the text's end. Its bytes before `i` hold no mark, so storing it over their copy
	// rewrites them unchanged.
	if last := len(text) - 16; last >= marked && i < len(text) {
		v := core_pkg.load(src[last:])
		back := i - last
		if !core_pkg.any_lane(simd.lanes_eq(v, core_pkg.V(mark)) & simd.lanes_ge(LANES, core_pkg.V(u8(back)))) {
			intrinsics.unaligned_store((^core_pkg.V)(dst[n - back:]), v)
			return n + len(text) - i
		}
	}
	for i < len(text) {
		step(src, dst, &i, &n, mark)
	}
	return n
}

// The byte the escape `\c` spells, `c` one of `t`, `n`, `r`, `0` and `\`.
@(private)
unescaped :: #force_inline proc(c: byte) -> byte {
	switch c {
	case 't':
		return '\t'
	case 'n':
		return '\n'
	case 'r':
		return '\r'
	case '0':
		return 0
	}
	return c
}
