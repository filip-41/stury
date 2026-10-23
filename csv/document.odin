package csv

// The document: the span of every field of a CSV text, and the readers over them. A text is read once, by the
// same scanner `records` runs; a cell's text is decoded when it is read.

import "core:math"
import "core:mem"
import "core:strconv"
import "core:unicode/utf8"
import core_pkg "../core"

// A parsed CSV text: the spans of its fields, over your source bytes. Make one with `build` and read it through
// the procedures in this file; its fields are internal.
//
//	- `src` is borrowed and must outlive every read: a cell's text is a slice of it unless it holds a `""` or an
//	  escape.
//	- Rows count from the first record after the header (from the first record when there is no header), as
//	  `unmarshal`'s paths do.
//	- Everything else is owned by whoever built it, and `document_destroy` is the only teardown.
//	- Spans are 16 bytes per field: a document of a large text is large.
Document :: struct {
	src:        []byte,
	dialect:    Dialect,
	// The header's fields, none without a header.
	names:      [dynamic]Field,
	// The fields of every row in order: `width` apiece, or, in a `ragged` dialect, row `i`'s from `starts[i]` to
	// `starts[i + 1]`.
	fields:     [dynamic]Field,
	starts:     [dynamic]int,
	rows:       int,
	width:      int,
	// Built `.Lazy`: a string is judged as UTF-8 when it is read.
	judge_utf8: bool,
	// The strings that held a `""` or an escape, decoded once each into `arena`. `decoded_at` is made at the first
	// decode, a slot per name and then per field: 0 until its text is decoded, then 1 + its index in `decoded`.
	decoded_at: []u32,
	decoded:    [dynamic]string,
	arena:      mem.Dynamic_Arena,
}

// Read `src` in `dialect` and keep the span of every field. `header` takes the first record as the column
// names. `strictness` and `limits` are `records`'; `.Lazy` additionally judges the UTF-8 of each string
// `get_string` reads. `err` is the first fault of the text, `.Bad_Option` for a dialect or limit the scanner
// refuses, or `.Out_Of_Memory`, with `Document` the zero value.
@(require_results)
build :: proc(
	src: []byte,
	dialect := Dialect{},
	header := true,
	strictness := Strictness.Strict,
	limits := Limits{},
	allocator := context.allocator,
) -> (doc: Document, err: Maybe(Error)) {
	it := records(src, dialect, strictness, limits, allocator)
	defer records_destroy(&it)
	if it.err != nil {
		return {}, it.err
	}
	doc = {src = src, dialect = dialect, judge_utf8 = strictness == .Lazy}
	doc.names.allocator, doc.fields.allocator, doc.starts.allocator = allocator, allocator, allocator
	if header {
		if rec, more := next_record(&it); more {
			doc.width = len(rec.fields)
			if _, aerr := append(&doc.names, ..rec.fields); aerr != nil {
				document_destroy(&doc)
				return {}, Error{kind = .Out_Of_Memory}
			}
		}
	}
	if dialect.ragged {
		if _, aerr := append(&doc.starts, 0); aerr != nil {
			document_destroy(&doc)
			return {}, Error{kind = .Out_Of_Memory}
		}
	}
	// The rows' fields stay in the iterator's list, which the document takes.
	it.keep = true
	for rec in next_kept_record(&it) {
		doc.width = max(doc.width, len(rec.fields))
		doc.rows += 1
		if dialect.ragged {
			if _, aerr := append(&doc.starts, it.base); aerr != nil {
				document_destroy(&doc)
				return {}, Error{kind = .Out_Of_Memory}
			}
		}
		if doc.rows == 1 {
			reserve_rest(&it, rec)
		}
	}
	if it.err != nil {
		document_destroy(&doc)
		return {}, it.err
	}
	doc.fields, it.fields = it.fields, {}
	return
}

// Room in the iterator's list for the fields the rest of the text will hold, judged by the first row `rec`:
// what the first row's bytes hold, scaled to the text's. A guess that is short costs a regrow and one that is
// long costs address space nobody touches. A reserve that fails is no error: the list grows as it needs.
@(private)
reserve_rest :: proc(it: ^Records, rec: Record) {
	row_bytes := int(rec.fields[len(rec.fields) - 1].hi - rec.at) + 1
	guess := len(it.src) / row_bytes * len(rec.fields)
	guess = min(guess + guess / 8, len(it.src) / 2 + 1)
	_ = reserve(&it.fields, guess)
	set_limit(it)
}

// Free everything a document owns, and empty it. Strings read from it dangle after.
document_destroy :: proc(doc: ^Document) {
	if doc.decoded_at != nil {
		mem.dynamic_arena_destroy(&doc.arena)
		delete(doc.decoded_at, doc.fields.allocator)
		delete(doc.decoded)
	}
	delete(doc.names)
	delete(doc.fields)
	delete(doc.starts)
	doc^ = {}
}

// How many rows the document holds, the header not counted.
@(require_results)
row_count :: proc(doc: ^Document) -> int {
	return doc.rows
}

// The field count of a record: the header's, or the first's without a header. In a `ragged` dialect, the
// widest record's.
@(require_results)
column_count :: proc(doc: ^Document) -> int {
	return doc.width
}

// The column the header names `name`, the first of them when several do. `ok` is false for a name the header
// lacks, and for a document with no header.
@(require_results)
column :: proc(doc: ^Document, name: string) -> (col: int, ok: bool) {
	return column_of(doc.src, doc.names[:], doc.dialect, name)
}

// The fields of `row`, nil past the last row. A row of a `ragged` dialect may be shorter or longer than
// `column_count`.
@(require_results)
row_fields :: proc(doc: ^Document, row: int) -> []Field {
	if row < 0 || row >= doc.rows {
		return nil
	}
	if doc.dialect.ragged {
		return doc.fields[doc.starts[row]:doc.starts[row + 1]]
	}
	return doc.fields[row * doc.width:][:doc.width]
}

// The field at `row` and `col` as written (`Field`). `ok` is false for a row or column the document lacks.
@(require_results)
get_field :: proc(doc: ^Document, row, col: int) -> (f: Field, ok: bool) {
	i := field_index(doc, row, col) or_return
	#no_bounds_check return doc.fields[i], true
}

// The index in `doc.fields` of the field at `row` and `col`, false for a row or column the document lacks.
@(private)
field_index :: #force_inline proc(doc: ^Document, row, col: int) -> (i: int, ok: bool) {
	if !doc.dialect.ragged {
		// Every row holds `width` fields: `fields` holds `rows * width`.
		return row * doc.width + col, uint(row) < uint(doc.rows) && uint(col) < uint(doc.width)
	}
	if uint(row) >= uint(doc.rows) {
		return
	}
	// `starts` holds `rows + 1` ascending indexes into `fields`.
	#no_bounds_check lo, hi := doc.starts[row], doc.starts[row + 1]
	return lo + col, uint(col) < uint(hi - lo)
}

// The decoded text of header column `col` (`get_string`'s rules), valid until `document_destroy`.
@(require_results)
get_name :: proc(doc: ^Document, col: int) -> (s: string, ok: bool) {
	if col < 0 || col >= len(doc.names) {
		return "", false
	}
	return read_text(doc, doc.names[col], col)
}

// The decoded text of a cell, valid until `document_destroy`: a quoted cell's without its quotes and with each
// `""` as one quote, an escaped cell's with each escape as the byte it spells (`field_text`).
//
//	- Text that holds neither is a slice of `doc.src`. Any other is decoded once and kept by the document.
//	- Reads of such cells write the document, so they must not run on several threads at once.
//	- `ok` is false for a row or column the document lacks, when a decoded string could not be allocated, and,
//	  for a document built `.Lazy`, when the cell is not UTF-8. An empty cell is `""` with `ok` true.
@(require_results)
get_string :: proc(doc: ^Document, row, col: int) -> (s: string, ok: bool) {
	i := field_index(doc, row, col) or_return
	#no_bounds_check f := doc.fields[i]
	return read_text(doc, f, len(doc.names) + i)
}

// The integer a cell spells, read as `unmarshal` reads one into an `i64`: `[+-]?digits`, a quoted cell's
// without its quotes. `ok` is false for an empty cell, any other text, and a value `i64` does not hold.
@(require_results)
get_int :: proc(doc: ^Document, row, col: int) -> (v: i64, ok: bool) {
	text := present_text(doc, row, col) or_return
	mag, over, neg, fault := read_int(text)
	if fault != .None || over || mag > u128(max(u64)) {
		return 0, false
	}
	stored := core_pkg.shape_int_store(u64(mag), neg, &v, size_of(i64), true)
	return v, stored == .None
}

// The decimal a cell spells, read as `unmarshal` reads one into an `f64` (`1.5`, `.5`, `1.`, with an optional
// exponent), correctly rounded. `ok` is false for an empty cell, any other text, and a value past `f64`'s range.
@(require_results)
get_float :: proc(doc: ^Document, row, col: int) -> (v: f64, ok: bool) {
	text := present_text(doc, row, col) or_return
	if !is_decimal(text) {
		return 0, false
	}
	v, _ = strconv.parse_f64(text)
	return v, !math.is_inf(v)
}

// `true` or `false`, as `unmarshal` reads a bool. `ok` is false for an empty cell and any other text.
@(require_results)
get_bool :: proc(doc: ^Document, row, col: int) -> (v: bool, ok: bool) {
	text := present_text(doc, row, col) or_return
	switch text {
	case "true":
		return true, true
	case "false":
		return false, true
	}
	return false, false
}

// The cell's text as `unmarshal` reads a scalar from it (`authored`): a quoted cell's without its quotes, none
// for an empty cell, which `unmarshal` reads as absent.
@(private)
present_text :: proc(doc: ^Document, row, col: int) -> (text: string, ok: bool) {
	f := get_field(doc, row, col) or_return
	if f.lo == f.hi {
		return "", false
	}
	r := Reader{src = doc.src, dialect = doc.dialect}
	return authored(&r, f), true
}

// The decoded text of `f`, kept in slot `key` of `decoded_at` when it had to be decoded.
@(private)
read_text :: #force_inline proc(doc: ^Document, f: Field, key: int) -> (s: string, ok: bool) {
	if doc.judge_utf8 && !utf8.valid_string(string(doc.src[f.lo:f.hi])) {
		return "", false
	}
	text, decode := field_view(doc.src, f, doc.dialect)
	if !decode {
		return string(text), true
	}
	return read_decoded(doc, text, key)
}

// The decoded text of `text`, a `field_view` that needs decoding, kept in slot `key` once decoded.
@(private)
read_decoded :: proc(doc: ^Document, text: []byte, key: int) -> (s: string, ok: bool) {
	if doc.decoded_at == nil {
		allocator := doc.fields.allocator
		slots, err := make([]u32, len(doc.names) + len(doc.fields), allocator)
		if err != nil {
			return "", false
		}
		doc.decoded_at = slots
		doc.decoded.allocator = allocator
		mem.dynamic_arena_init(&doc.arena, allocator, allocator)
	}
	if at := doc.decoded_at[key]; at != 0 {
		return doc.decoded[at - 1], true
	}
	out, _, err := field_decode(text, doc.dialect, mem.dynamic_arena_allocator(&doc.arena))
	if err != nil {
		return "", false
	}
	// Past `max(u32)` decoded strings a text is decoded again at each read; each copy lives as long as the arena.
	if len(doc.decoded) < int(max(u32)) {
		if _, aerr := append(&doc.decoded, string(out)); aerr != nil {
			return "", false
		}
		doc.decoded_at[key] = u32(len(doc.decoded))
	}
	return string(out), true
}

// Whether the text of `f` in `src`, read in `dialect`, is `name`: `field_text` compared without decoding.
@(private)
text_is :: proc(src: []byte, f: Field, dialect: Dialect, name: string) -> bool {
	text := src[f.lo:f.hi]
	j := 0
	switch {
	case dialect.quoting == .Quotes && len(text) > 0 && text[0] == '"':
		inner := text[1:len(text) - 1]
		for i := 0; i < len(inner); i += 1 {
			if j >= len(name) || inner[i] != name[j] {
				return false
			}
			j += 1
			// The scanner passed only doubled quotes inside the field.
			if inner[i] == '"' {
				i += 1
			}
		}
		return j == len(name)
	case dialect.escapes == .Backslash:
		for i := 0; i < len(text); i += 1 {
			c := text[i]
			if c == '\\' {
				i += 1
				c = unescaped(text[i])
			}
			if j >= len(name) || c != name[j] {
				return false
			}
			j += 1
		}
		return j == len(name)
	}
	return string(text) == name
}
