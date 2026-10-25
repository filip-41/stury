package csv

// The document: the span of every field of a CSV text, with readers over them. The text is scanned once, by
// the scanner `records` runs. A cell's text is decoded when it is read.

import "core:mem"
import "core:unicode/utf8"

// A parsed CSV text: the spans of its fields in the source bytes. Make one with `build` and read it through
// the procedures in this file. Its fields are internal.
//
//	- `src` is borrowed and must outlive every read: a cell's text is a slice of it unless it holds a `""` or an
//	  escape.
//	- Rows count from the first record after the header (from the first record when there is no header), as
//	  `unmarshal`'s paths do.
//	- The rest is owned by the caller that built it and freed by `destroy`.
//	- Each field's span takes 16 bytes.
Document :: struct {
	src:        []byte,
	dialect:    Dialect,
	// The header's fields, none without a header.
	names:      [dynamic]Field,
	// The fields of every row in order: `width` per row, or in a `ragged` dialect row `i`'s from `starts[i]`
	// to `starts[i + 1]`.
	fields:     [dynamic]Field,
	starts:     [dynamic]int,
	rows:       int,
	width:      int,
	// Built `.Lazy`: a string is judged as UTF-8 when it is read.
	judge_utf8: bool,
	// The strings that held a `""` or an escape, each decoded once into `arena`. `decoded_at` is allocated at the
	// first decode, with one slot per header name and then per field: 0 until its text is decoded, then 1 + its
	// index in `decoded`.
	decoded_at: []u32,
	decoded:    [dynamic]string,
	arena:      mem.Dynamic_Arena,
}

// Read `src` in `opts.dialect` and keep the span of every field. Unless `opts.no_header`, the first record is the
// column names. `strictness` and `limits` are as for `records`. Under `.Lazy`, `get_string` also judges the UTF-8
// of each string it reads. `err` is the text's first fault, `.Bad_Option` for a dialect or limit the scanner
// refuses, or `.Out_Of_Memory`; the `Document` is then the zero value.
@(require_results)
build :: proc(src: []byte, opts := Read_Opts{}, allocator := context.allocator) -> (doc: Document, err: Maybe(Error)) {
	dialect := opts.dialect
	it := records(src, opts, allocator)
	defer destroy(&it)
	if it.err != nil {
		return {}, it.err
	}
	doc = {src = src, dialect = dialect, judge_utf8 = opts.strictness == .Lazy}
	doc.names.allocator, doc.fields.allocator, doc.starts.allocator = allocator, allocator, allocator
	if !opts.no_header {
		if rec, more := next_record(&it); more {
			doc.width = len(rec.fields)
			if _, aerr := append(&doc.names, ..rec.fields); aerr != nil {
				destroy(&doc)
				return {}, Error{kind = .Out_Of_Memory}
			}
		}
	}
	if dialect.ragged {
		if _, aerr := append(&doc.starts, 0); aerr != nil {
			destroy(&doc)
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
				destroy(&doc)
				return {}, Error{kind = .Out_Of_Memory}
			}
		}
		if doc.rows == 1 {
			reserve_rest(&it, rec)
		}
	}
	if it.err != nil {
		destroy(&doc)
		return {}, it.err
	}
	doc.fields, it.fields = it.fields, {}
	return
}

// Reserves room in the iterator's list for the rest of the text's fields, estimated from the first row `rec`:
// its fields per byte, scaled to the text's length. Too small an estimate costs a regrow; too large costs
// untouched address space. A failed reserve is not an error: the list grows as needed.
@(private)
reserve_rest :: proc(it: ^Records, rec: Record) {
	row_bytes := int(rec.fields[len(rec.fields) - 1].hi - rec.at) + 1
	guess := len(it.src) / row_bytes * len(rec.fields)
	guess = min(guess + guess / 8, len(it.src) / 2 + 1)
	_ = reserve(&it.fields, guess)
	set_limit(it)
}

// Free everything an owner holds, and empty it: a `Document`, the `Records` of `records`, a `Record_Reader` or a
// `Type_Plan`. Strings read from a document dangle after.
destroy :: proc {
	document_destroy,
	records_free,
	reader_destroy,
	type_plan_destroy,
}

@(private)
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
// lacks and for a document with no header. The path edits read `duplicates` instead, and refuse a name two
// columns share under `.Default`/`.Refuse`.
@(require_results)
column :: proc(doc: ^Document, name: string) -> (col: int, ok: bool) {
	for f, c in doc.names {
		if text_is(doc.src, f, doc.dialect, name) {
			return c, true
		}
	}
	return -1, false
}

// The column `name` names in a header's fields (`text_is`), under `duplicates`. `col` is -1 when no field names it.
// `repeated` is set, with `at` the repeated column's header field, when `.Default`/`.Refuse` meets a second
// field of that name.
@(private)
named_column :: proc(src: []byte, names: []Field, dialect: Dialect, name: string, duplicates: Duplicates) -> (col: int, at: u64, repeated: bool) {
	first := -1
	last := -1
	for f, c in names {
		if !text_is(src, f, dialect, name) {
			continue
		}
		if first < 0 {
			first, last = c, c
			if duplicates == .First {
				return c, 0, false
			}
			continue
		}
		switch duplicates {
		case .Default, .Refuse:
			return -1, f.lo, true
		case .First:
			// Unreachable: the first match already returned.
		case .Last, .All:
			last = c
		}
	}
	return last, 0, false
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

// The decoded text of header column `col` (`get_string`'s rules), valid until `destroy`.
@(require_results)
get_name :: proc(doc: ^Document, col: int) -> (s: string, ok: bool) {
	if col < 0 || col >= len(doc.names) {
		return "", false
	}
	return read_text(doc, doc.names[col], col)
}

// The decoded text of a cell, valid until `destroy` (`field_text`): a quoted cell without its quotes
// and with each `""` as one quote, an escaped cell with each escape as the byte it spells.
//
//	- Text with neither is a slice of `doc.src`. Other text is decoded once and kept by the document.
//	- Reading a cell that needs decoding writes to the document, so such reads must not run on several
//	  threads at once.
//	- `ok` is false for a row or column the document lacks, when a decoded string could not be allocated, and,
//	  for a document built `.Lazy`, when the cell is not UTF-8. An empty cell is `""` with `ok` true.
@(require_results)
get_string :: proc(doc: ^Document, row, col: int) -> (s: string, ok: bool) {
	i := field_index(doc, row, col) or_return
	#no_bounds_check f := doc.fields[i]
	return read_text(doc, f, len(doc.names) + i)
}

// The integer a cell spells, read by `unmarshal`'s own integer store (`store_int`): `[+-]?digits`, with a quoted
// cell's quotes removed. `ok` is false for an empty cell, any other text, and a value `i64` does not hold.
@(require_results)
get_int :: proc(doc: ^Document, row, col: int) -> (v: i64, ok: bool) {
	text := present_text(doc, row, col) or_return
	if store_int(text, &v, u8(size_of(i64)), true) != .None {
		return 0, false
	}
	return v, true
}

// The binary64 a cell spells, read by `unmarshal`'s own float reader (`read_float_value`) and correctly
// rounded, as `unmarshal` reads a float. `ok` is false for an empty cell, any other text, a nonzero value that
// underflows to zero (`1e-400`, where returning `0, true` hid the loss), or a value with no binary64 (`1e400`).
// A rounded significand (`0.1`, `1e23`) is accepted: it is the value `unmarshal` stores, not an error.
@(require_results)
get_float :: proc(doc: ^Document, row, col: int) -> (v: f64, ok: bool) {
	text := present_text(doc, row, col) or_return
	n := read_float_value(text)
	return n.value, n.exactness == .Exact || n.exactness == .Inexact
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

// The cell's text as `unmarshal` reads a scalar from it (`authored`): with a quoted cell's quotes removed, or
// none for an empty cell, which `unmarshal` reads as absent.
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
	// Past `max(u32)` decoded strings, a text is decoded again at each read, and each copy lives as long as the
	// arena.
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
			// The scanner accepted only doubled quotes inside the field.
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
