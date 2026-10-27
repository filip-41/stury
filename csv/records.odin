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
// for `records_from`.
Record :: struct {
	fields: []Field,
	at:     u64,
	src:    []byte,
}

// A pull iterator over an input's records (`next_record`). Every field is internal except `err`, the fault
// that ended it. A record is yielded only after every byte up to its end is checked, so the records before a
// fault are yielded and the one holding it is not.
Records :: struct {
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
	// `fields[:base]` holds the yielded records `build` keeps. Under `keep`, a yielded record's fields stay in
	// the list and the next record's fields follow them.
	base:     int,
	keep:     bool,
	// How far `fields` may grow without a check (`set_limit`): its capacity, capped at `max_fields` past `base`.
	limit:    int,
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
	err:      Maybe(Error),
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
// input, it resumes the record it was reading.
@(private, require_results)
next_slice_record :: proc(it: ^Records) -> (rec: Record, ok: bool) {
	return records_step(it, false)
}

// `next_slice_record` for `build`, which keeps every yielded record's fields in the list.
@(private, require_results)
next_kept_record :: proc(it: ^Records) -> (rec: Record, ok: bool) {
	return records_step(it, true)
}

// Under `KEEP`, the open record starts at `base` and its fields may reach `limit` without a check. Without it,
// the list holds only the open record and its capacity never exceeds `max_fields`.
@(private, require_results)
records_step :: #force_inline proc(it: ^Records, $KEEP: bool) -> (rec: Record, ok: bool) {
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
					return last_record(it)
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
		// The block's separators and the fields' length are kept in locals. They are written back to `it` before
		// any return, rescan or growth.
		seps, lfs, field_lo, block := it.seps, it.lfs, it.field_lo, it.block
		fields := (^runtime.Raw_Dynamic_Array)(&it.fields)
		data, n := ([^]Field)(fields.data), fields.len
		base, limit := 0, fields.cap
		when KEEP {
			base, limit = it.base, it.limit
		}
		for seps != 0 {
			// The delimiters before the record's LF (or the block's end) all end fields of the open record. Room
			// for them is reserved once, then each field is one store.
			end := lfs & seps
			before := (end & -end) - 1
			if delims := seps & before; delims != 0 {
				if k := int(intrinsics.count_ones(delims)); limit - n < k {
					fields.len = n
					if !reserve_fields(it, n + k) {
						return
					}
					data = ([^]Field)(fields.data)
					limit = fields.cap
					when KEEP {
						limit = it.limit
					}
				}
				for delims != 0 {
					at := block + int(intrinsics.count_trailing_zeros(delims))
					delims &= delims - 1
					data[n] = {u64(field_lo), u64(at)}
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
			if n < limit {
				data[n] = {u64(field_lo), u64(hi)}
				n += 1
			} else {
				fields.len = n
				if !grow_fields(it, field_lo, hi) {
					return
				}
				data, n = ([^]Field)(fields.data), fields.len
				limit = fields.cap
				when KEEP {
					limit = it.limit
				}
			}
			field_lo = at + 1
			fields.len = n
			it.seps, it.field_lo = seps, field_lo
			lo := it.rec_lo
			it.rec_lo = at + 1
			if n - base == 1 && skip_line(it, lo, at) {
				n = base
				continue
			}
			return yield(it, lo, KEEP)
		}
		fields.len = n
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
		cut_block(it, &seps, &lfs, at, Error{offset = u64(lo), kind = .Limit_Record})
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

// The record after the last LF, once the input's end is checked.
@(private)
last_record :: proc(it: ^Records) -> (rec: Record, ok: bool) {
	if it.ended {
		return
	}
	it.ended = true
	if fault, kind := scan_end(it.src, &it.carry); fault >= 0 {
		it.err = Error{offset = u64(fault), kind = kind}
		return
	}
	if it.rec_lo == len(it.src) || !add_field(it, it.field_lo, len(it.src)) {
		return
	}
	if len(it.fields) - it.base == 1 && skip_line(it, it.rec_lo, len(it.src)) {
		return
	}
	if it.keep {
		return yield(it, it.rec_lo, true)
	}
	return yield(it, it.rec_lo, false)
}

@(private)
add_field :: #force_inline proc(it: ^Records, lo, hi: int) -> bool {
	if n := len(it.fields); n < it.limit {
		(^runtime.Raw_Dynamic_Array)(&it.fields).len = n + 1
		it.fields[n] = {u64(lo), u64(hi)}
		return true
	}
	return grow_fields(it, lo, hi)
}

// `add_field` when the list is full.
@(private)
grow_fields :: proc(it: ^Records, lo, hi: int) -> bool {
	n := len(it.fields)
	reserve_fields(it, n + 1) or_return
	(^runtime.Raw_Dynamic_Array)(&it.fields).len = n + 1
	it.fields[n] = {u64(lo), u64(hi)}
	return true
}

// Reserves room for `need` fields of the open record. Capacity never exceeds `max_fields`; a record that needs
// more is refused.
@(cold, private)
reserve_fields :: proc(it: ^Records, need: int) -> bool {
	if need - it.base > it.scan.max_fields {
		it.err = Error{offset = u64(it.rec_lo), kind = .Limit_Fields}
		return false
	}
	if need > cap(it.fields) && reserve(&it.fields, it.base + min(max(2 * cap(it.fields), need, 16) - it.base, it.scan.max_fields)) != nil {
		it.err = Error{kind = .Out_Of_Memory}
		return false
	}
	set_limit(it)
	return true
}

@(private)
set_limit :: #force_inline proc(it: ^Records) {
	it.limit = it.base + min(cap(it.fields) - it.base, it.scan.max_fields)
}

// Whether the one-field line `src[lo:hi]` holds no record: it is blank, or a comment.
@(private)
skip_line :: #force_inline proc(it: ^Records, lo, hi: int) -> bool {
	return blank(it.src, lo, hi) || .Comments in it.scan.mode && it.src[lo] == it.scan.comment
}

@(private)
yield :: #force_inline proc(it: ^Records, lo: int, $KEEP: bool) -> (rec: Record, ok: bool) {
	base := 0
	when KEEP {
		base = it.base
	}
	if n := len(it.fields) - base; n != it.width {
		k: Error_Kind
		if k, it.width = record_fault(it.width, n, it.scan); k != .None {
			it.err = Error{offset = u64(lo), kind = k}
			return
		}
	}
	// `base` is never past the list's length: it is only ever set to the length.
	#no_bounds_check rec = {fields = it.fields[base:], at = u64(lo), src = it.src}
	when KEEP {
		it.base = len(it.fields)
		set_limit(it)
	} else {
		clear(&it.fields)
	}
	return rec, true
}

// The text of `f`, a field `records` read from `src` in `dialect`. A quoted field loses its quotes and reads
// each `""` as one quote. Under `.Backslash` each escape reads as the byte it spells. A field with nothing to
// decode is a slice of `src`, with `escaped` false. A field with `""` or an escape is decoded into
// `allocator`, with `escaped` true; the caller frees it.
@(require_results)
field_text :: #force_inline proc(src: []byte, f: Field, dialect := Dialect{}, allocator := context.allocator) -> (text: []byte, escaped: bool, err: runtime.Allocator_Error) {
	// `src[f.lo:f.hi]`'s bounds check, in two unsigned compares.
	if f.lo > f.hi || f.hi > u64(len(src)) {
		runtime.slice_expr_error_lo_hi_loc(lo = int(f.lo), hi = int(f.hi), len = len(src))
	}
	decode: bool
	if text, decode = field_view(src, f, dialect); decode {
		return field_decode(text, dialect, allocator)
	}
	return text, false, nil
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
	case dialect.quoting == .None && dialect.escapes == .Backslash:
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

// `text`, a `field_view` holding a `""` or an escape, decoded into `allocator`. Each `""` reads as one quote,
// or under `Quoting.None` each backslash escape as the byte it spells. A 16-byte window with no quote or
// backslash is copied whole. The decoded text is never longer than `text`, so the store stays inside `out`.
@(private)
field_decode :: proc(text: []byte, dialect: Dialect, allocator: runtime.Allocator) -> (out: []byte, escaped: bool, err: runtime.Allocator_Error) {
	out = runtime.mem_alloc_non_zeroed(len(text), 1, allocator) or_return
	mark := byte('\\') if dialect.quoting == .None else '"'
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
	for i + 16 <= len(text) {
		v := core_pkg.load(src[i:])
		if !core_pkg.any_eq(v, mark) {
			intrinsics.unaligned_store((^core_pkg.V)(dst[n:]), v)
			i += 16
			n += 16
			continue
		}
		for end := i + 16; i < end; {
			step(src, dst, &i, &n, mark)
		}
	}
	for i < len(text) {
		step(src, dst, &i, &n, mark)
	}
	return out[:n], true, nil
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
