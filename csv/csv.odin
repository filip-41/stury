package csv

// The CSV codec's public surface: delimited records over the shared `core` type plan. Where the public names
// live:
//
//	csv.odin            `Error`, `Error_Kind`, the path `Step`s (`Name`, `Index`, `Any`), `Dialect`, `Quoting`,
//	                    `Escapes`, `TSV`, `Strictness`, `Limits`,
//	                    `validate`, `error_position`, `render_error` and `render_error_to_writer`
//	records.odin        `records`, `next_record`, `records_destroy`, `Records`, `Record`, `Field` and `field_text`
//	record_reader.odin  `records_from` and `Record_Reader`
//	each_record.odin    `each_record` and `Batch_Runner`
//	unmarshal.odin      `unmarshal`, `unmarshal_check`, `Unmarshal_Opts`, `Duplicates`,
//	                    `Unknown_Fields`, `Unmarshal_Error`, `Unmarshal_Error_Kind`
//	marshal.odin        `marshal`, `marshal_append`, `marshal_to_writer`, `Marshal_Opts`, `Marshal_Error`
//	record_writer.odin  `write_record`
//	type_plan.odin      `Type_Plan`, `type_plan_init`, `type_plan_destroy`, `Plan_Opts`, `Enum_Spelling`,
//	                    `Type_Hook`, `Marshal_Hook`, `Unmarshal_Hook`, `plan_cache_clear`
//	document.odin       `Document`, `build`, `document_destroy`, `row_count`, `column_count`, `column`,
//	                    `row_fields`, `get_field`, `get_name`, `get_string`, `get_int`, `get_float`, `get_bool`
//	find.odin           `Path`, `Path_Spec`, `Path_Error`, `Path_Error_Kind`, `find`,
//	                    `find_column`
//	edit.odin           `Edit`, `APPEND`, `splice`, `set`, `insert`, `remove`
//
// The scanner (scan.odin) and the edits' cell writer (edit_spell.odin) are internal.
//
// What the scanner reads, in every dialect: records end at LF, or CRLF, which is one break, and fields at the
// delimiter. A CR outside a quoted field that is not before an LF is refused. One leading UTF-8 BOM is
// stepped over, a line holding nothing (or only a CR) is no record, and a final LF ends the last record,
// starting none. Every record has as many fields as the first, unless the dialect is `ragged`, and at most
// `Limits.max_fields`. Under `.Strict` every byte is UTF-8.
//
//	- `Quoting.Quotes` (RFC 4180): a field is quoted when its first byte is `"`, and then runs to the matching
//	  closing quote, a doubled `""` inside it reading as one quote, and holds the delimiter, CR and LF as text.
//	  A quote anywhere else is refused.
//	- `Quoting.None`: a quote is text, and a field cannot hold the delimiter, CR or LF.
//	- `Escapes.Backslash` (with `Quoting.None`): `\t`, `\n`, `\r`, `\0` and `\\` read as a tab, LF, CR, NUL and backslash.
//	  Any other byte after a backslash, or a backslash ending a field, is refused (`.Bad_Escape`).
//	- `comment`: a line whose first byte is the comment byte is no record, whatever it holds up to its LF. The
//	  byte anywhere else, or inside a quoted field, is text.

import "base:intrinsics"
import core_pkg "../core"

// A fault in the text: the offset of the first byte that cannot extend it, or `len(src)` when it ended inside
// a quoted field (`.Truncated`).
Error :: core_pkg.Error

// What an `Error` is: `Bad_Char` at a misplaced quote, CR or malformed UTF-8 lead, `Truncated` where a quoted
// field or a UTF-8 sequence never ends, `Bad_Escape` at a backslash that opens no escape, `Field_Count` at the
// first byte of a record with more or fewer fields than the first, `Limit_Fields` at the first byte of a record
// with more than `Limits.max_fields`, `Limit_Record` at the first byte of a line longer than
// `Limits.max_record_bytes`, `Bad_Option` (at no byte) for a dialect or limit the scanner refuses, and
// `Out_Of_Memory` where `next_record` could not hold a record's fields or `records_from` its window. The one
// enum is core's, so that code over several formats reads one `Error`; CSV never reports `Bad_Literal`,
// `Bad_Number`, `Limit_Digits`, `Limit_Scale`, `Too_Deep`, `Trailing`, `Source_Too_Wide` or `Duplicate_Key`.
Error_Kind :: core_pkg.Error_Kind

// The 1-based line and column `err` points at in `src`, counting bytes, or (0, 0) where it points at no byte
// (a `.Bad_Option` or an `.Out_Of_Memory`, or an offset past `src`).
@(require_results)
error_position :: proc(src: []byte, err: Error) -> (line, col: int) {
	return core_pkg.error_position(src, err)
}

// `err`, an `Error`, an `Unmarshal_Error` or a `Path_Error`, as `line:col: <kind>`, the kind written as its enum
// name, or `offset N: <kind>` where it has no position. `src` is the text the offset is into, the input the
// faulting call read. An `Unmarshal_Error` is bare where it points at no byte (`.Unsupported`, `.Bad_Option`,
// `.Plan_Mismatch`), has `: <syntax>` after a `.Syntax`, then ` at [3].name` for its path. A `Path_Error` is
// located in the source for `.Bad_Source` and for an `.Encode` or `.Unplaceable` with a record, `offset N` for
// `.Bad_Path` (into the path text) and `.Bad_Result` (into the edited text), ` (N)` after `.Bad_Row`, with the
// `syntax` or `encode` result after it. The text is allocated with `allocator`.
@(require_results)
render_error :: proc(src: []byte, err: $E, allocator := context.allocator) -> string {
	return core_pkg.render_error(src, err, allocator)
}

// `render_error`'s text written to `w`, allocating nothing; `w`'s failure is the `io.Error`, with a prefix of
// the text possibly written.
render_error_to_writer :: proc {
	core_pkg.render_syntax_error_to_writer,
	core_pkg.render_unmarshal_error_to_writer,
	core_pkg.render_path_error_to_writer,
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

// How a text spells its records. The zero value is RFC 4180 with `,` between fields. `.Bad_Option` refuses a
// delimiter that is a quote, CR, LF or not ASCII; a comment byte that is a quote (under `.Quotes`), CR, LF,
// the delimiter or not ASCII; `.Backslash` escapes under `.Quotes`; and, under `.Backslash`, a delimiter or
// comment byte that is a backslash, or a delimiter that is `t`, `n`, `r` or `0`.
Dialect :: struct {
	delimiter: byte, // 0 is `,`
	quoting:   Quoting,
	escapes:   Escapes,
	comment:   byte, // 0 is none: a line whose first byte, outside quotes, is this is no record
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
	// A line (a record, or a blank or comment line) with more bytes than this before its LF is refused at its
	// first byte (`.Limit_Record`), once its first byte past the cap is read; 0 for no cap. It bounds the
	// window `records_from` holds.
	max_record_bytes: int,
}

// Whether `src` is CSV in `dialect`. Allocates nothing without `runner`. With one, the text is cut into pieces
// that `runner`'s threads and the caller validate at once (`each_record`), and the answer is the same.
@(require_results)
validate :: proc(
	src: []byte,
	dialect := Dialect{},
	strictness := Strictness.Strict,
	limits := Limits{},
	runner: ^Batch_Runner = nil,
) -> Maybe(Error) {
	s, ok := scan_setup(dialect, limits, strictness)
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

// Where `validate` stands between blocks: the block at `pos` is next, and the line open there starts at
// `rec_lo` with `fields` fields so far. Every record must have `width`, the first's (0 until it is read).
@(private)
Validate_Walk :: struct {
	pos, rec_lo:   int,
	fields, width: int,
	cy:            Carry,
}

// `validate_span` in one scan mode. Blocks before `stop` cannot hold the byte past an open line's cap, so only
// the block at `stop` looks for it.
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

// The block at `w.pos`, which holds the byte past an open line's cap. `done` with the text's fault.
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

// The lines the block at `pos` ends (`lfs`) judged, and its separators (`seps`) counted into the open line's.
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

// The fault `validate` reports at `fault` inside the line opening at `rec_lo`, `fields` of which are open:
// `.Limit_Fields` when the separators before the fault already closed more than the cap, as `next_record`
// refuses them. A `.Limit_Record` is the line's, at its first byte.
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

// The fault of a record of `fields` fields where `width` were expected, and the width from then on: no fault
// when it is the first record, which sets the width, or when the dialect is ragged.
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
