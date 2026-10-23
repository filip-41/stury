package csv

import "base:intrinsics"
import "base:runtime"
import "core:bytes"
import core_pkg "../core"

// One field's bytes as written, `src[lo:hi]`: a quoted field's quotes included, a CR before the record's LF
// not. `field_text` reads its text.
Field :: struct {
	lo, hi: u64,
}

// One record: its fields, which index `src`, valid until the next `next_record`, and the offset of its first
// byte in the input. `src` is the input for `records` and `each_record`, and the reader's window for
// `records_from`.
Record :: struct {
	fields: []Field,
	at:     u64,
	src:    []byte,
}

// A pull over an input's records (`next_record`). The fields are the iterator's own but `err`: the fault that
// ended it. A record is yielded only once every byte up to its end has been checked, so the records before a
// fault are yielded and the one holding it is not.
Records :: struct {
	src:      []byte,
	// The block being read starts at `block`. `seps` are its separators not yet read, of which `lfs` end records.
	block:    int,
	seps:     u64,
	lfs:      u64,
	carry:    Carry,
	// The block's fault, past its last separator `seps` holds.
	fault:    Maybe(Error),
	// Where the field and the record now open start.
	field_lo: int,
	rec_lo:   int,
	fields:   [dynamic]Field,
	width:    int, // the first record's field count, 0 until it is read
	scan:     Scan,
	// Blocks at or past `stop` are read by `records_past_stop`: the input's end, the block that holds an open
	// line's byte past its cap, or under `more` the bytes not yet read.
	stop:     int,
	// `records_from`'s window: the input goes on past `src`. A block is read only once `src` holds it and the
	// bytes a UTF-8 sequence opening in it could reach (`READ_AHEAD`), and `starved` says `src` ran out.
	more:     bool,
	starved:  bool,
	ended:    bool,
	err:      Maybe(Error),
}

// The records of `src` in `dialect`, judged at `strictness` (`.Lazy` is `.Structural`) and capped by `limits`.
// A dialect or limit the scanner refuses is `.Bad_Option` on `err`. The fields of a record are held in
// `allocator` (`records_destroy`).
@(require_results)
records :: proc(
	src: []byte,
	dialect := Dialect{},
	strictness := Strictness.Strict,
	limits := Limits{},
	allocator := context.allocator,
) -> (it: Records) {
	s, ok := scan_setup(dialect, limits, strictness)
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

// Free what `records` or `records_from` allocated.
records_destroy :: proc {
	records_free,
	reader_destroy,
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

// A record's fields are cleared as it is yielded, so a call `records_from` makes again once it has read more
// goes on with the record it was reading.
@(private, require_results)
next_slice_record :: proc(it: ^Records) -> (rec: Record, ok: bool) {
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
				cut := u64(1) << u64(max(fault - it.block, 0)) - 1
				it.seps &= cut
				it.lfs &= cut
				it.fault = Error{offset = u64(fault), kind = kind}
			}
		}
		// The block's separators, and the fields' length, run in locals: `it` is written back before any
		// return, rescan or growth.
		seps, lfs, field_lo, block := it.seps, it.lfs, it.field_lo, it.block
		fields := (^runtime.Raw_Dynamic_Array)(&it.fields)
		data, n := ([^]Field)(fields.data), fields.len
		for seps != 0 {
			b := u64(intrinsics.count_trailing_zeros(seps))
			seps &= seps - 1
			at := block + int(b)
			lf := lfs >> b & 1 != 0
			hi := at
			if lf && hi > field_lo && src[hi - 1] == '\r' {
				hi -= 1
			}
			if n < fields.cap {
				data[n] = {u64(field_lo), u64(hi)}
				n += 1
			} else {
				fields.len = n
				if !grow_fields(it, field_lo, hi) {
					return
				}
				data, n = ([^]Field)(fields.data), fields.len
			}
			field_lo = at + 1
			if !lf {
				continue
			}
			fields.len = n
			it.seps, it.field_lo = seps, field_lo
			lo := it.rec_lo
			it.rec_lo = at + 1
			if n == 1 && skip_line(it, lo, at) {
				n = 0
				continue
			}
			return yield(it, lo)
		}
		fields.len = n
		it.seps, it.field_lo = 0, field_lo
	}
}

@(private)
Past_Stop :: enum u8 {
	Scan,    // read the block as any other
	Scanned, // the block is read, its line cap judged
	Starved, // `src` does not hold the block yet
	Ended,   // past the input's last block
}

// The block at `it.block`, at or past `it.stop`: what `next_record` does with it, and the next `stop`.
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
		cut := u64(1) << u64(max(fault - it.block, 0)) - 1
		seps &= cut
		lfs &= cut
		it.fault = Error{offset = u64(fault), kind = kind}
	}
	if at, lo := line_cap_fault(lfs, it.block, it.rec_lo, it.scan.max_bytes, n); at >= 0 && (fault < 0 || at < fault) {
		cut := u64(1) << u64(at - it.block) - 1
		seps &= cut
		lfs &= cut
		it.fault = Error{offset = u64(lo), kind = .Limit_Record}
	}
	it.seps, it.lfs = seps, lfs
	// The next block judges the line open at its start.
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
	if len(it.fields) == 1 && skip_line(it, it.rec_lo, len(it.src)) {
		return
	}
	return yield(it, it.rec_lo)
}

@(private)
add_field :: #force_inline proc(it: ^Records, lo, hi: int) -> bool {
	if n := len(it.fields); n < cap(it.fields) {
		(^runtime.Raw_Dynamic_Array)(&it.fields).len = n + 1
		it.fields[n] = {u64(lo), u64(hi)}
		return true
	}
	return grow_fields(it, lo, hi)
}

// `add_field` past the fields' capacity, which never passes `max_fields`: the field past it is refused.
@(private)
grow_fields :: proc(it: ^Records, lo, hi: int) -> bool {
	n := len(it.fields)
	if n >= it.scan.max_fields {
		it.err = Error{offset = u64(it.rec_lo), kind = .Limit_Fields}
		return false
	}
	if reserve(&it.fields, min(max(2 * n, 16), it.scan.max_fields)) != nil {
		it.err = Error{kind = .Out_Of_Memory}
		return false
	}
	(^runtime.Raw_Dynamic_Array)(&it.fields).len = n + 1
	it.fields[n] = {u64(lo), u64(hi)}
	return true
}

// Whether the one-field line `src[lo:hi]` holds no record: it is blank, or a comment.
@(private)
skip_line :: #force_inline proc(it: ^Records, lo, hi: int) -> bool {
	return blank(it.src, lo, hi) || .Comments in it.scan.mode && it.src[lo] == it.scan.comment
}

@(private)
yield :: proc(it: ^Records, lo: int) -> (rec: Record, ok: bool) {
	if len(it.fields) != it.width {
		k: Error_Kind
		if k, it.width = record_fault(it.width, len(it.fields), it.scan); k != .None {
			it.err = Error{offset = u64(lo), kind = k}
			return
		}
	}
	rec = {fields = it.fields[:], at = u64(lo), src = it.src}
	clear(&it.fields)
	return rec, true
}

// The text of `f` in `src`, a field `records` read in `dialect`: a quoted field's without its quotes, each `""`
// read as one quote, and under `.Backslash` each escape read as the byte it spells. A field with nothing to
// decode is a slice of `src` with `escaped` false. One with `""` or an escape is decoded into `allocator`,
// `escaped` true, and the caller frees it.
@(require_results)
field_text :: proc(src: []byte, f: Field, dialect := Dialect{}, allocator := context.allocator) -> (text: []byte, escaped: bool, err: runtime.Allocator_Error) {
	text = src[f.lo:f.hi]
	if dialect.quoting == .None {
		if dialect.escapes == .Backslash {
			return unescape(text, allocator)
		}
		return text, false, nil
	}
	if len(text) == 0 || text[0] != '"' {
		return text, false, nil
	}
	text = text[1:len(text) - 1]
	k := bytes.index_byte(text, '"')
	if k < 0 {
		return text, false, nil
	}
	out := make([]byte, len(text) - bytes.count(text, {'"'}) / 2, allocator) or_return
	n := copy(out, text[:k + 1])
	for i := k + 2; i < len(text); i += 1 {
		out[n] = text[i]
		n += 1
		// The scanner passed only doubled quotes inside the field.
		if text[i] == '"' {
			i += 1
		}
	}
	return out[:n], true, nil
}

// `text` with each backslash escape read as the byte it spells, decoded into `allocator` when it holds one.
@(private)
unescape :: proc(text: []byte, allocator: runtime.Allocator) -> (out: []byte, escaped: bool, err: runtime.Allocator_Error) {
	k := bytes.index_byte(text, '\\')
	if k < 0 {
		return text, false, nil
	}
	out = make([]byte, len(text), allocator) or_return
	n := copy(out, text[:k])
	for i := k; i < len(text); i += 1 {
		c := text[i]
		// The scanner passed only the five escapes, each whole inside its field.
		if c == '\\' {
			i += 1
			c = unescaped(text[i])
		}
		out[n] = c
		n += 1
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
