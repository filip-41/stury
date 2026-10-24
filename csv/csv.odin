package csv

// The CSV codec's public surface: delimited records over the shared `core` type plan. Where the public names
// live:
//
//	csv.odin            `Error`, `Error_Kind`, the path `Step`s (`Name`, `Index`, `Any`), `Dialect`, `Quoting`,
//	                    `Escapes`, `TSV`, `Strictness`, `Limits`,
//	                    `Read_Opts`, `validate`, `error_position` and `render_error`
//	records.odin        `records`, `next_record`, `Records`, `Record`, `Field` and `field_text`
//	record_reader.odin  `records_from` and `Record_Reader`
//	each_record.odin    `each_record` and `Batch_Runner`
//	unmarshal.odin      `unmarshal`, `unmarshal_check`, `Unmarshal_Opts`, `Duplicates`,
//	                    `Unknown_Fields`, `Unmarshal_Error`, `Unmarshal_Error_Kind`
//	marshal.odin        `marshal`, `marshal_append`, `marshal_to_writer`, `Marshal_Opts`, `Marshal_Error`
//	record_writer.odin  `write_record`
//	type_plan.odin      `Type_Plan`, `type_plan_init`, `Plan_Opts`, `Enum_Spelling`,
//	                    `Type_Hook`, `Marshal_Hook`, `Unmarshal_Hook`, `plan_cache_clear`
//	document.odin       `Document`, `build`, `destroy`, `row_count`, `column_count`, `column`,
//	                    `row_fields`, `get_field`, `get_name`, `get_string`, `get_int`, `get_float`, `get_bool`
//	find.odin           `Path`, `Path_Spec`, `Path_Error`, `Path_Error_Kind`, `find`,
//	                    `find_column`
//	edit.odin           `Edit`, `APPEND`, `splice`, `set`, `insert`, `remove`
//
// The scanner (scan.odin) and the edits' cell writer (edit_spell.odin) are internal.
//
// In every dialect a record ends at LF or CRLF, and a field ends at the delimiter. A CR outside a quoted
// field must be followed by LF. One leading UTF-8 BOM is skipped. A line that is empty or holds only a CR is
// not a record. A final LF ends the last record and starts no new one. Every record has as many fields as
// the first, unless the dialect is `ragged`, and at most `Limits.max_fields`. Under `.Strict` every byte
// must be UTF-8.
//
//	- `Quoting.Quotes` (RFC 4180): a field whose first byte is `"` is quoted. It runs to its closing quote,
//	  reads `""` as one quote, and may hold the delimiter, CR and LF. A quote anywhere else is refused.
//	- `Quoting.None`: a quote is text, and a field cannot hold the delimiter, CR or LF.
//	- `Escapes.Backslash` (with `Quoting.None`): `\t`, `\n`, `\r`, `\0` and `\\` read as a tab, LF, CR, NUL and backslash.
//	  Any other byte after a backslash, or a backslash ending a field, is refused (`.Bad_Escape`).
//	- `comment`: a line whose first byte is the comment byte is not a record. Elsewhere, or inside a quoted
//	  field, the byte is text.

import "base:intrinsics"
import core_pkg "../core"

// A fault in the text: the offset of the first byte that is invalid where it stands, or `len(src)` when the
// text ends inside a quoted field (`.Truncated`).
Error :: core_pkg.Error

// What an `Error` is: `Bad_Char` at a misplaced quote, CR or malformed UTF-8 lead, `Truncated` where a quoted
// field or a UTF-8 sequence never ends, `Bad_Escape` at a backslash that opens no escape, `Field_Count` at the
// first byte of a record with more or fewer fields than the first, `Limit_Fields` at the first byte of a record
// with more than `Limits.max_fields`, `Limit_Record` at the first byte of a line longer than
// `Limits.max_record_bytes`, `Bad_Option` (at no byte) for a dialect or limit the scanner refuses, and
// `Out_Of_Memory` where `next_record` could not hold a record's fields or `records_from` its window. The enum
// is core's and shared by every format. CSV never reports `Bad_Literal`, `Bad_Number`, `Limit_Digits`,
// `Limit_Scale`, `Too_Deep`, `Trailing`, `Source_Too_Wide` or `Duplicate_Key`.
Error_Kind :: core_pkg.Error_Kind

// The 1-based line and column `err` points at in `src`, counting bytes, or (0, 0) where it points at no byte
// (a `.Bad_Option` or an `.Out_Of_Memory`, or an offset past `src`).
@(require_results)
error_position :: proc(src: []byte, err: Error) -> (line, col: int) {
	return core_pkg.error_position(src, err)
}

// `err` (an `Error`, `Unmarshal_Error` or `Path_Error`) as text: `line:col: <kind>` with the kind's enum name,
// or `offset N: <kind>` when it has no position. `src` is the input the failing call read.
//
// An `Unmarshal_Error` that points at no byte (`.Unsupported`, `.Bad_Option`, `.Plan_Mismatch`) has no
// position prefix. A `.Syntax` one is followed by `: <syntax>`. Its path follows as ` at [3].name`.
//
// A `Path_Error` has a source position for `.Bad_Source`, and for `.Encode` or `.Unplaceable` when it has a
// record. `.Bad_Path` has `offset N` into the path text, `.Bad_Result` into the edited text. `.Bad_Row` is
// followed by ` (N)`. The `syntax` or `encode` result comes last.
//
// The text is allocated with `allocator`.
@(require_results)
render_error :: proc(src: []byte, err: $E, allocator := context.allocator) -> string {
	return core_pkg.render_error(src, err, allocator)
}

// A step of an `Unmarshal_Error`'s path.
Step :: core_pkg.Step
Name :: core_pkg.Name
Index :: core_pkg.Index
Any :: core_pkg.Any

// How a field may be quoted.
Quoting :: enum u8 {
	Quotes, // RFC 4180 quoted fields
	None,   // a quote is text
}

// How a field spells a byte it cannot hold as itself.
Escapes :: enum u8 {
	None,
	Backslash, // `\t`, `\n`, `\r`, `\0`, `\\`; needs `Quoting.None`
}

// How a text spells its records. The zero value is RFC 4180 with `,` between fields. `.Bad_Option` refuses:
//
//	- a delimiter that is a quote, CR, LF or not ASCII
//	- a comment byte that is CR, LF, the delimiter, not ASCII, or a quote under `.Quotes`
//	- `.Backslash` escapes under `.Quotes`
//	- under `.Backslash`, a backslash as delimiter or comment byte, or `t`, `n`, `r` or `0` as delimiter
Dialect :: struct {
	delimiter: byte, // 0 is `,`
	quoting:   Quoting,
	escapes:   Escapes,
	comment:   byte, // 0 for none; a line whose first byte is this is not a record
	ragged:    bool, // records may hold different field counts (no `.Field_Count`)
}

// Tab-separated values as jq's `@tsv` writes them and PostgreSQL's text `COPY` reads them.
TSV :: Dialect{delimiter = '\t', quoting = .None, escapes = .Backslash}

// How much of the text is judged. `.Strict` judges every byte. `.Structural` judges the structure (quotes,
// CR, escapes, field counts) and not UTF-8. `.Lazy` is `.Structural` for `validate` and `records`; `unmarshal`
// under it judges the UTF-8 of every cell it reads and skips the rest.
Strictness :: core_pkg.Strictness

// Caps on what a text may hold. The zero value caps nothing.
Limits :: struct {
	max_fields:       int, // a record with more fields is refused (`.Limit_Fields`), 0 for no cap
	// A line (record, blank or comment) with more bytes than this before its LF is refused with
	// `.Limit_Record` at its first byte, as soon as the first byte past the cap is read. 0 for no cap. It also
	// bounds the window `records_from` holds.
	max_record_bytes: int,
}

// How a read takes its text: one struct for `validate`, `records`, `records_from`, `each_record`, `build`, `find`,
// `find_column` and the path edits, embedded in `Unmarshal_Opts`. The zero value is RFC 4180 with a header,
// every byte judged, no caps. A procedure that does not read a field says so.
Read_Opts :: struct {
	dialect:    Dialect,
	strictness: Strictness,
	// `unmarshal`'s reading of a header name two columns share (`Duplicates`). Only `unmarshal` reads it.
	duplicates: Duplicates,
	limits:     Limits,
	// The first record is data, not column names.
	no_header:  bool,
}

// Whether `src` is CSV in `opts.dialect`. `opts.duplicates` and `opts.no_header` are not read: the header is a
// record like the others. Allocates nothing without `runner`. With a runner, the text is split into pieces that
// its threads and the caller validate in parallel (`each_record`), with the same result.
@(require_results)
validate :: proc(src: []byte, opts := Read_Opts{}, runner: ^Batch_Runner = nil) -> Maybe(Error) {
	s, ok := scan_setup(opts.dialect, opts.limits, opts.strictness)
	if !ok {
		return Error{kind = .Bad_Option}
	}
	if core_pkg.batch_lanes(runner, len(src)) > 1 {
		return validate_pieces(src, s, runner)
	}
	return validate_span(src, core_pkg.bom_len(src), 0, s)
}

// `validate` of `src` from `lo`, a line's first byte, where every record has `width` fields (0: the first
// record's), in the scan mode of `s`.
@(private)
validate_span :: proc(src: []byte, lo, width: int, s: Scan) -> Maybe(Error) {
	switch s.mode {
	case {}:
		return validate_in(src, lo, width, s, {})
	case {.Skip_Utf8}:
		return validate_in(src, lo, width, s, {.Skip_Utf8})
	case {.Comments}:
		return validate_in(src, lo, width, s, {.Comments})
	case {.Comments, .Skip_Utf8}:
		return validate_in(src, lo, width, s, {.Comments, .Skip_Utf8})
	case {.Unquoted}:
		return validate_in(src, lo, width, s, {.Unquoted})
	case {.Unquoted, .Skip_Utf8}:
		return validate_in(src, lo, width, s, {.Unquoted, .Skip_Utf8})
	case {.Unquoted, .Comments}:
		return validate_in(src, lo, width, s, {.Unquoted, .Comments})
	case {.Unquoted, .Comments, .Skip_Utf8}:
		return validate_in(src, lo, width, s, {.Unquoted, .Comments, .Skip_Utf8})
	case {.Unquoted, .Escapes}:
		return validate_in(src, lo, width, s, {.Unquoted, .Escapes})
	case {.Unquoted, .Escapes, .Skip_Utf8}:
		return validate_in(src, lo, width, s, {.Unquoted, .Escapes, .Skip_Utf8})
	case {.Unquoted, .Escapes, .Comments}:
		return validate_in(src, lo, width, s, {.Unquoted, .Escapes, .Comments})
	case {.Unquoted, .Escapes, .Comments, .Skip_Utf8}:
		return validate_in(src, lo, width, s, {.Unquoted, .Escapes, .Comments, .Skip_Utf8})
	}
	unreachable()
}

// `validate`'s state between blocks. The next block starts at `pos`. The open line starts at `rec_lo` and
// has `fields` fields so far. `width` is the first record's field count, 0 until it is read.
@(private)
Validate_Walk :: struct {
	pos, rec_lo:   int,
	fields, width: int,
	cy:            Carry,
}

// `validate_span` in one scan mode. Only the block at `stop` can hold the first byte past the open line's
// cap, so only that block checks the cap.
@(private)
validate_in :: proc(src: []byte, lo, start_width: int, s: Scan, $M: Scan_Mode) -> Maybe(Error) {
	delimiter, comment := s.delim, s.comment
	w := Validate_Walk{pos = lo, rec_lo = lo, fields = 1, width = start_width, cy = CARRY_START}
	pos, rec_lo, fields, width, cy := w.pos, w.rec_lo, w.fields, w.width, w.cy
	stop := line_cap_stop(pos, rec_lo, s.max_bytes, len(src))
	for {
		for pos < stop {
			seps, lfs, fault, kind := scan_block(src, pos, delimiter, comment, &cy, M)
			if fault >= 0 {
				cut := u64(1) << u64(max(fault - pos, 0)) - 1
				seps &= cut
				lfs &= cut
			}
			if e, bad := validate_lines(src, pos, seps, lfs, &rec_lo, &fields, &width, s, M); bad {
				return e
			}
			if fault >= 0 {
				return open_record_fault(fields, rec_lo, s, fault, kind)
			}
			pos += 64
		}
		if pos >= len(src) {
			break
		}
		w.pos, w.rec_lo, w.fields, w.width, w.cy = pos, rec_lo, fields, width, cy
		if e, done := validate_capped_block(src, &w, s, M); done {
			return e
		}
		pos, rec_lo, fields, width, cy = w.pos, w.rec_lo, w.fields, w.width, w.cy
		stop = line_cap_stop(pos, rec_lo, s.max_bytes, len(src))
	}
	if fault, kind := scan_end(src, &cy); fault >= 0 {
		return open_record_fault(fields, rec_lo, s, fault, kind)
	}
	if rec_lo < len(src) && fields != width && !no_record(src, rec_lo, len(src), comment, M) {
		if k, _ := record_fault(width, fields, s); k != .None {
			return Error{offset = u64(rec_lo), kind = k}
		}
	}
	return nil
}

// Validates the block at `w.pos`, which holds the first byte past the open line's cap. `done` is true when
// the text has a fault, returned in `err`.
@(private, cold)
validate_capped_block :: proc(src: []byte, w: ^Validate_Walk, s: Scan, $M: Scan_Mode) -> (err: Maybe(Error), done: bool) {
	pos := w.pos
	seps, lfs, fault, kind := scan_block(src, pos, s.delim, s.comment, &w.cy, M)
	if fault >= 0 {
		cut := u64(1) << u64(max(fault - pos, 0)) - 1
		seps &= cut
		lfs &= cut
	}
	if at, _ := line_cap_fault(lfs, pos, w.rec_lo, s.max_bytes, len(src)); at >= 0 && (fault < 0 || at < fault) {
		fault, kind = at, .Limit_Record
		cut := u64(1) << u64(at - pos) - 1
		seps &= cut
		lfs &= cut
	}
	if e, bad := validate_lines(src, pos, seps, lfs, &w.rec_lo, &w.fields, &w.width, s, M); bad {
		return e, true
	}
	if fault >= 0 {
		return open_record_fault(w.fields, w.rec_lo, s, fault, kind), true
	}
	w.pos = pos + 64
	return nil, false
}

// Judges each line that ends in the block at `pos` (`lfs`), and adds the block's separators (`seps`) to the
// open line's field count.
@(private)
validate_lines :: #force_inline proc(src: []byte, pos: int, seps, lfs: u64, rec_lo, fields, width: ^int, s: Scan, $M: Scan_Mode) -> (err: Error, bad: bool) {
	seps, lfs := seps, lfs
	for lfs != 0 {
		b := u64(intrinsics.count_trailing_zeros(lfs))
		before := u64(1) << b - 1
		fields^ += int(intrinsics.count_ones(seps & before))
		seps &= ~before
		seps &= seps - 1
		lfs &= lfs - 1
		end := pos + int(b)
		if fields^ != width^ && !no_record(src, rec_lo^, end, s.comment, M) {
			k: Error_Kind
			if k, width^ = record_fault(width^, fields^, s); k != .None {
				return Error{offset = u64(rec_lo^), kind = k}, true
			}
		}
		rec_lo^, fields^ = end + 1, 1
	}
	fields^ += int(intrinsics.count_ones(seps))
	return {}, false
}

// The error `validate` reports for a fault at `fault` in the line starting at `rec_lo`, which has `fields`
// fields so far. It is `.Limit_Fields` when the fields before the fault already exceed the cap, as in
// `next_record`. A `.Limit_Record` points at the line's first byte.
@(private)
open_record_fault :: proc(fields, rec_lo: int, s: Scan, fault: int, kind: Error_Kind) -> Error {
	if fields - 1 > s.max_fields {
		return Error{offset = u64(rec_lo), kind = .Limit_Fields}
	}
	if kind == .Limit_Record {
		return Error{offset = u64(rec_lo), kind = kind}
	}
	return Error{offset = u64(fault), kind = kind}
}

// Whether the line `src[lo:hi]` holds no record: it is blank, or a comment.
@(private)
no_record :: #force_inline proc(src: []byte, lo, hi: int, comment: byte, $M: Scan_Mode) -> bool {
	when .Comments in M {
		return blank(src, lo, hi) || src[lo] == comment
	} else {
		return blank(src, lo, hi)
	}
}

// The fault of a record with `fields` fields where `width` were expected, and the width from then on. The
// first record sets the width. A ragged dialect has no `.Field_Count` fault.
@(private)
record_fault :: proc(width, fields: int, s: Scan) -> (kind: Error_Kind, width_after: int) {
	if fields > s.max_fields {
		return .Limit_Fields, width
	}
	if width == 0 {
		return .None, fields
	}
	return .None if s.ragged else .Field_Count, width
}
