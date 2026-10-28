package csv

// The document: a CSV text as core's rows, read with core's readers and `query`, as a JSON document is. `build`
// reads a whole text; `record_document` makes one record a document of its own, keyed by a `Header`.
//
//	- With a header, a text is an array of objects, one per record, each mapping the header's names to the
//	  record's cells in column order; a record shorter than the header has no member for the columns it lacks.
//	  Without one (`no_header`), an array of arrays.
//	- A cell is a string: a quoted cell's text without its quotes and with each `""` as one quote, an escaped
//	  cell's with each escape as the byte it spells. An empty cell is null; a quoted `""` is the empty string.
//	- A record's span is its bytes as written, without its line break; a cell's is the field's (`Field`).
//	- Both builds decode every cell and name that needs it, so no read writes and any number of threads may read
//	  a document at once (`core.Document`'s decoded tier).

import "base:runtime"
import core_pkg "../core"

// A CSV text or record as rows: see the file's header. `src` is borrowed from `build`'s caller, and owned by a
// `record_document`. Everything else is owned by whoever built it, and `destroy` frees it.
Document :: core_pkg.Document

// The root value: the text's array, or a record document's object.
ROOT :: core_pkg.ROOT

// A walk over one container's members (`children`, `members`).
Members :: core_pkg.Members

// core's readers of a document's rows, as `json` forwards them.
kind :: core_pkg.kind
get_string :: core_pkg.get_string
get_key :: core_pkg.get_key
get_raw :: core_pkg.get_raw
child_count :: core_pkg.child_count
child :: proc {
	core_pkg.child_by_key,
	core_pkg.child_by_index,
}
children :: proc {
	core_pkg.members_of,
	core_pkg.children_next,
}
members :: proc {
	core_pkg.members_of,
	core_pkg.members_next,
}

// Read `src` in `opts.dialect` into a document (the file's header). Unless `opts.no_header`, the first record is
// the column names. The text is judged `.Strict` whatever `opts.strictness` says, and capped by `opts.limits`.
//
//	- `duplicates` is how a header name two columns share is read: `.Default`, `.Last` and `.All` keep every
//	  member, and `child` by key reads the last; `.First` keeps the first column's member only; `.Refuse` is
//	  `.Duplicate_Key` at the repeated header cell.
//	- A record with more fields than the header (a `ragged` dialect) is `.Bad_Structure` with `Fault.Field_Count`:
//	  no name keys its last cells.
//	- `.Source_Too_Wide` refuses a text longer than row offsets (u32) address, `offset` being that limit.
//
// `err` is the text's first fault or one of these, or `.Out_Of_Memory`; the `Document` is then the zero value.
// `runner` is not read: the build is one thread's.
@(require_results)
build :: proc(src: []byte, opts := Read_Opts{}, allocator := context.allocator, runner: ^Batch_Runner = nil) -> (doc: Document, err: Maybe(Error)) {
	if u64(len(src)) > core_pkg.MAX_ROW_SOURCE {
		return {}, Error{kind = .Source_Too_Wide, offset = core_pkg.MAX_ROW_SOURCE}
	}
	read := opts
	read.strictness = .Strict
	it := records(src, read, allocator)
	defer destroy(&it)
	if it.err != nil {
		return {}, it.err
	}
	doc = {src = src, spelling = spelling_of(opts.dialect), decoded = true, distinct_keys = true}
	doc.rows.allocator, doc.values.allocator, doc.key_texts.allocator = allocator, allocator, allocator
	err = build_rows(&doc, &it, opts)
	if err == nil {
		err = it.err
	}
	if err != nil {
		document_destroy(&doc)
		return {}, err
	}
	return
}

// The member key a cell row carries: its span and its `.Key_*` flags.
@(private)
Cell_Key :: struct {
	lo, hi: u32,
	flags:  core_pkg.Row_Flags,
}

// The key of a cell with no name: an array element.
@(private)
NO_CELL_KEY :: Cell_Key{core_pkg.NO_KEY, core_pkg.NO_KEY, {}}

// A header column's member key, and under `.Key_Escaped` its decoded text. `dropped` is a repeated name `.First`
// gives no member.
@(private = "file")
Column_Key :: struct {
	key:     Cell_Key,
	dropped: bool,
	text:    core_pkg.Row_Str,
}

// The rows of `it`'s records onto `doc`: the root array, then each record and its cells, which the scan writes
// as rows (`Row_Build`).
@(private = "file")
build_rows :: proc(doc: ^Document, it: ^Records, opts: Read_Opts) -> Maybe(Error) {
	ROOM :: Error{kind = .Out_Of_Memory}
	if _, aerr := append(&doc.rows, core_pkg.Row{key_lo = core_pkg.NO_KEY, key_hi = core_pkg.NO_KEY, kind = .Array}); aerr != nil {
		return ROOM
	}
	columns: [dynamic]Column_Key
	columns.allocator = doc.rows.allocator
	defer delete(columns)
	b := Row_Build{doc = doc, at = 1, dialect = opts.dialect, escapes = opts.dialect.quoting == .Backslash, quotes = opts.dialect.quoting == .Quotes}
	b.keys.allocator = doc.rows.allocator
	defer delete(b.keys)
	named := max(int)
	if !opts.no_header {
		if rec, more := next_record(it); more {
			header_keys(doc, rec, opts.dialect, opts.duplicates, &columns) or_return
		}
		named = len(columns)
		if reserve(&b.keys, named) != nil {
			return ROOM
		}
		for c in columns {
			append(&b.keys, row_key(c.key))
		}
	}
	// Without a dropped column or an escaped name, a record's cells are the rows the scan wrote.
	plain := true
	for c in columns {
		plain &&= !c.dropped && .Key_Escaped not_in c.key.flags
	}
	kind := core_pkg.Kind.Array if opts.no_header else .Object
	records, first, last := 0, u32(0), u32(0)
	open_cells(&b)
	for {
		lo := scan_record(it, &b, core_pkg.Row, int) or_break
		n := b.cells.len
		if n > named {
			return fault_error(u64(lo), .Field_Count)
		}
		cells := ([^]core_pkg.Row)(b.cells.data)
		hi := cells[n - 1].hi
		if !plain {
			n = name_cells(doc, columns[:], cells, n, b.at) or_return
		}
		([^]core_pkg.Row)(raw_data(doc.rows))[b.at] = {lo = u32(lo), hi = hi, key_lo = core_pkg.NO_KEY, key_hi = core_pkg.NO_KEY, subtree_size = u32(n + 1), kind = kind, cnt = u32(n)}
		b.at += 1 + n
		(^runtime.Raw_Dynamic_Array)(&doc.rows).len = b.at
		if records == 0 {
			first = u32(lo)
			reserve_rows(doc, int(hi) - lo + 1, n + 1)
		}
		records, last = records + 1, hi
		b.cells.len = 0
		open_cells(&b)
	}
	if it.err != nil {
		return it.err
	}
	doc.rows[0].lo, doc.rows[0].hi = first, last
	doc.rows[0].subtree_size, doc.rows[0].cnt = u32(len(doc.rows)), u32(records)
	return nil
}

// A document's build as `scan_record`'s sink: the open record's cells are written as rows right after its record
// row, `doc.rows[at]`, which is past the list's length until the record is taken. `cells` is the open record's
// cells as a list over the rows' spare capacity, capped by `keys`: a key per column there is room for.
@(private)
Row_Build :: struct {
	doc:     ^Document,
	cells:   runtime.Raw_Dynamic_Array,
	keys:    [dynamic]Row_Key,
	at:      int,
	dialect: Dialect,
	escapes: bool, // `dialect` reads backslash escapes
	quotes:  bool, // `dialect` reads quoted fields
}

// A column's cell row as words: `span` is the row's second word (`key_lo`, `key_hi`), and `null` and `bare` its
// third (`subtree_size` 1, `kind`, `flags`, `first_esc` 0) for an empty cell and for a bare string.
@(private)
Row_Key :: struct {
	span, null, bare: u64,
}

#assert(size_of(core_pkg.Row) == 32 && offset_of(core_pkg.Row, key_lo) == 8 && offset_of(core_pkg.Row, subtree_size) == 16)
#assert(offset_of(core_pkg.Row, kind) == 20 && offset_of(core_pkg.Row, flags) == 21 && offset_of(core_pkg.Row, first_esc) == 22)

@(private)
row_key :: proc(k: Cell_Key) -> Row_Key {
	meta :: proc(kind: core_pkg.Kind, flags: core_pkg.Row_Flags) -> u64 {
		return 1 | u64(kind) << 32 | u64(transmute(u8)flags) << 40
	}
	return {u64(k.lo) | u64(k.hi) << 32, meta(.Null, k.flags), meta(.String, k.flags + {.Bare})}
}

// The record at `lo`, once it keeps the field count.
@(private)
take_cells :: #force_inline proc(it: ^Records, b: ^Row_Build, lo: int) -> (int, bool) {
	return lo, width_ok(it, b.cells.len, lo)
}

@(private)
row_cells :: #force_inline proc(b: ^Row_Build) -> ^runtime.Raw_Dynamic_Array {
	return &b.cells
}

// An empty cell is null, and one not opening with a quote is a bare string, unless backslashes escape; any other
// is `cell_row`'s.
@(private)
row_put :: #force_inline proc(it: ^Records, b: ^Row_Build, src: []byte, data: [^]core_pkg.Row, n, lo, hi: int) -> bool #no_bounds_check {
	// `n` is below `cells.cap`, so `keys` holds it; a field is inside `src`.
	key := b.keys[n]
	meta := key.null
	if lo != hi {
		if src[lo] == '"' || b.escapes {
			return row_put_read(it, b, src, &data[n], n, lo, hi)
		}
		meta = key.bare
	}
	// Four words, so the row is two pair stores rather than a store per field.
	(^[4]u64)(&data[n])^ = {u64(lo) | u64(hi) << 32, key.span, meta, 0}
	return true
}

// `row_put` for a cell whose text `cell_row` reads. A quoted cell is a string row as `row_put` writes a bare one,
// without `.Bare`, its text decoded only when it holds a `""`.
@(private = "file")
row_put_read :: proc(it: ^Records, b: ^Row_Build, src: []byte, r: ^core_pkg.Row, n, lo, hi: int) -> bool #no_bounds_check {
	// The key is read here, not passed: passed, every cell would spill it for this call.
	k := b.keys[n]
	if b.quotes && src[lo] == '"' {
		(^[4]u64)(r)^ = {u64(lo) | u64(hi) << 32, k.span, k.bare &~ (1 << (40 + u64(core_pkg.Row_Flag.Bare))), 0}
		// The scanner closed the quote, so the field holds both quotes.
		if !holds_span(src, lo + 1, hi - lo - 2, '"') || cell_decoded(r, src[lo + 1:hi - 1], b.dialect, b.doc) {
			return true
		}
	} else if cell_row(r, {u32(k.span), u32(k.span >> 32), transmute(core_pkg.Row_Flags)u8(k.null >> 40)}, src, {u64(lo), u64(hi)}, b.dialect, 0, b.doc) {
		return true
	}
	it.err = Error{kind = .Out_Of_Memory}
	return false
}

// Room for `need` cells of the open record: rows past it, and a key for each column, a column past the header's
// keyed as an array element.
@(cold, private)
reserve_cells :: proc(it: ^Records, b: ^Row_Build, need: int) -> bool {
	if need > it.scan.max_fields {
		it.err = fault_error(u64(it.rec_lo), .Too_Many_Fields)
		return false
	}
	for len(b.keys) < need {
		if _, aerr := append(&b.keys, row_key(NO_CELL_KEY)); aerr != nil {
			it.err = Error{kind = .Out_Of_Memory}
			return false
		}
	}
	rows := (^runtime.Raw_Dynamic_Array)(&b.doc.rows)
	if b.at + 1 + need > rows.cap {
		// A reserve copies the list's length only: the open record's rows are counted while it moves them.
		rows.len = b.at + 1 + b.cells.len
		aerr := non_zero_reserve(&b.doc.rows, max(2 * rows.cap, b.at + 1 + need))
		rows.len = b.at
		if aerr != nil {
			it.err = Error{kind = .Out_Of_Memory}
			return false
		}
	}
	open_cells(b)
	return true
}

// Points `b.cells` past the open record's row, its capacity what both the rows and the keys have room for.
@(private = "file")
open_cells :: #force_inline proc(b: ^Row_Build) {
	rows := (^runtime.Raw_Dynamic_Array)(&b.doc.rows)
	b.cells.data = rawptr(uintptr(rows.data) + uintptr((b.at + 1) * size_of(core_pkg.Row)))
	b.cells.cap = min(rows.cap - b.at - 1, len(b.keys))
}

// The `n` cell rows of the record at row `at` as `columns` key them: a dropped column's row removed, an escaped
// name's text noted in `key_texts`. The count kept.
@(private = "file")
name_cells :: proc(doc: ^Document, columns: []Column_Key, cells: [^]core_pkg.Row, n, at: int) -> (kept: int, err: Maybe(Error)) {
	for c in 0 ..< n {
		col := columns[c]
		if col.dropped {
			continue
		}
		if .Key_Escaped in col.key.flags {
			if _, aerr := append(&doc.key_texts, core_pkg.Key_Text{Node(at + 1 + kept), col.text}); aerr != nil {
				return 0, Error{kind = .Out_Of_Memory}
			}
		}
		cells[kept] = cells[c]
		kept += 1
	}
	return
}

// The member keys of header `rec`'s columns, onto `keys`, each escaped name decoded onto `doc.values`. A name
// that repeats is dropped under `.First`, is `.Duplicate_Key` at its cell under `.Refuse`, and otherwise clears
// `doc.distinct_keys`. Out of line: it runs once per text, and inlined into `build_rows` it costs the record
// loop registers.
@(private = "file")
header_keys :: #force_no_inline proc(doc: ^Document, rec: Record, dialect: Dialect, duplicates: Duplicates, keys: ^[dynamic]Column_Key) -> Maybe(Error) {
	names, aerr := header_names(doc.src, rec.fields, dialect, keys.allocator)
	defer header_names_destroy(&names, keys.allocator)
	if aerr != nil || reserve(keys, len(rec.fields)) != nil {
		return Error{kind = .Out_Of_Memory}
	}
	for f, c in rec.fields {
		k := Column_Key{key = {lo = u32(f.lo), hi = u32(f.hi)}}
		if names.repeats[c] >= 0 {
			#partial switch duplicates {
			case .Refuse:
				return Error{kind = .Duplicate_Key, offset = f.lo}
			case .First:
				k.dropped = true
			case:
				doc.distinct_keys = false
			}
		}
		text, decode := field_view(doc.src, f, dialect)
		if u64(len(text)) == f.hi - f.lo {
			k.key.flags = {.Key_Bare}
		}
		if decode {
			k.text = decoded_onto(doc, text, dialect) or_return
			k.key.flags += {.Key_Escaped}
		}
		append(keys, k)
	}
	return nil
}

// The names of a header's columns, decoded as `field_text` decodes a field, and what each repeats: the one rule
// every reader of a header applies before its `Duplicates` policy.
@(private)
Header_Names :: struct {
	text:    []byte, // the names back to back
	names:   []string, // in column order, each a slice of `text`
	repeats: []int, // per column, the nearest earlier column of the same name, or -1
}

// The `Header_Names` of header fields `fields`, read from `src` in `dialect`, in `allocator`, which
// `header_names_destroy` takes back. A refused allocation leaves nothing to free.
@(private, require_results)
header_names :: proc(src: []byte, fields: []Field, dialect: Dialect, allocator: runtime.Allocator) -> (h: Header_Names, err: runtime.Allocator_Error) {
	defer if err != nil {
		header_names_destroy(&h, allocator)
	}
	size := 0
	for f in fields {
		size += int(f.hi - f.lo)
	}
	h.text = make([]byte, size, allocator) or_return
	h.names = make([]string, len(fields), allocator) or_return
	h.repeats = make([]int, len(fields), allocator) or_return
	last := make(map[string]int, len(fields), allocator) or_return
	defer delete(last)
	w := 0
	for f, c in fields {
		text, decode := field_view(src, f, dialect)
		n := field_unescape(text, h.text[w:], dialect) if decode else copy(h.text[w:], text)
		name := string(h.text[w:][:n])
		prev, seen := last[name]
		h.names[c], h.repeats[c] = name, prev if seen else -1
		if map_insert(&last, name, c) == nil {
			return h, .Out_Of_Memory
		}
		w += n
	}
	h.text = h.text[:w]
	return
}

@(private)
header_names_destroy :: proc(h: ^Header_Names, allocator: runtime.Allocator) {
	delete(h.text, allocator)
	delete(h.names, allocator)
	delete(h.repeats, allocator)
	h^ = {}
}

// Reserves room for the rows of every record, estimated from the first: its `rows` per `bytes`, scaled to the
// text's length. Too small an estimate costs a regrow; too large costs untouched address space. A failed reserve
// is not an error: the rows grow as needed.
@(private = "file")
reserve_rows :: proc(doc: ^Document, bytes, rows: int) {
	guess := len(doc.src) / bytes * rows
	guess = min(guess + guess / 8, len(doc.src) / 2 + 2)
	_ = non_zero_reserve(&doc.rows, len(doc.rows) + guess)
}

// Writes `r`, the row of cell `f` of `src` under member key `key`, its span moved by `shift` (wrapping): null when it
// is empty, else a string, flagged `.Bare` when unquoted and, when it holds a `""` or an escape, `.Str_Escaped` with
// its text decoded onto `doc.values`. False when `doc.values` cannot grow. The row is written in one composite store:
// patched in place field by field, it costs every cell a store per field.
@(private)
cell_row :: #force_inline proc(r: ^core_pkg.Row, key: Cell_Key, src: []byte, f: Field, dialect: Dialect, shift: u64, doc: ^Document) -> bool {
	kind, flags := core_pkg.Kind.Null, key.flags
	text: []byte
	decode: bool
	if f.lo != f.hi {
		kind = .String
		text, decode = field_view(src, f, dialect)
		if u64(len(text)) == f.hi - f.lo {
			flags += {.Bare}
		}
	}
	r^ = {lo = u32(f.lo + shift), hi = u32(f.hi + shift), key_lo = key.lo, key_hi = key.hi, subtree_size = 1, kind = kind, flags = flags}
	return !decode || cell_decoded(r, text, dialect, doc)
}

// Cell row `r` with `text`, its view, decoded onto `doc.values`; false when `doc.values` cannot grow.
@(private = "file")
cell_decoded :: #force_no_inline proc(r: ^core_pkg.Row, text: []byte, dialect: Dialect, doc: ^Document) -> bool {
	s, err := decoded_onto(doc, text, dialect)
	r.payload.str = s
	r.flags += {.Str_Escaped, .Decoded}
	return err == nil
}

// `text`, a `field_view` of a field inside `doc.src` to decode, decoded onto the end of `doc.values`.
@(private)
decoded_onto :: #force_inline proc(doc: ^Document, text: []byte, dialect: Dialect) -> (s: core_pkg.Row_Str, err: Maybe(Error)) {
	values := &doc.values
	at := len(values)
	// A decoded text is never longer than its field, and a document's fields are disjoint and no longer than
	// `doc.src`, so the first reserve, to `src`'s length, holds every text decoded after it. A growing list would
	// move, and the allocator then hands later builds' rows fresh pages to fault in.
	if at + len(text) > cap(values) && non_zero_reserve(values, max(len(doc.src), at + len(text))) != nil {
		return {}, Error{kind = .Out_Of_Memory}
	}
	n := field_unescape(text, ([^]u8)(raw_data(values^))[at:][:len(text)], dialect)
	(^runtime.Raw_Dynamic_Array)(values).len = at + n
	return {u32(at), u32(n)}, nil
}

// The column names a `record_document` keys a record's cells by, made from a header record by `header_of`.
//
//	- `names` are decoded, in column order, and `columns` holds the field each keys; `width` is the header's
//	  field count.
//	- `text` is the names back to back: each record document copies it, and its keys are spans of that copy.
//	- `distinct_keys` is false when a name repeats.
//	- Everything is owned, in `allocator`, and freed by `destroy`.
Header :: struct {
	names:         []string,
	columns:       []int,
	width:         int,
	text:          []byte,
	distinct_keys: bool,
	allocator:     runtime.Allocator,
}

// The header of `rec`, its names decoded in the record's dialect. A name that repeats follows `duplicates`, as in
// `build`: kept under `.Default`, `.Last` and `.All` (`distinct_keys` false), left out under `.First`, and
// `.Duplicate_Key` under `.Refuse` at the repeat's first byte, counted from the input's as `rec.at` is.
// `.Out_Of_Memory` when `allocator` refuses. The header is the zero value on an error.
@(require_results)
header_of :: proc(rec: Record, duplicates := Duplicates.Default, allocator := context.allocator) -> (h: Header, err: Maybe(Error)) {
	names, aerr := header_names(rec.src, rec.fields, rec.dialect, allocator)
	if aerr != nil {
		return {}, Error{kind = .Out_Of_Memory}
	}
	// The names' lists become the header's, kept names moved forward over the ones left out: `kept <= c`, so
	// column `c`'s name and repeat are read before anything is written over them.
	h = {names = names.names, columns = names.repeats, text = names.text, width = len(rec.fields), distinct_keys = true, allocator = allocator}
	w, kept := 0, 0
	for name, c in names.names {
		if names.repeats[c] >= 0 {
			#partial switch duplicates {
			case .Refuse:
				offset := rec.at + (rec.fields[c].lo - rec.fields[0].lo)
				header_destroy(&h)
				return {}, Error{kind = .Duplicate_Key, offset = offset}
			case .First:
				continue
			case:
				h.distinct_keys = false
			}
		}
		n := copy(h.text[w:], name)
		h.names[kept], h.columns[kept] = string(h.text[w:][:n]), c
		w, kept = w + n, kept + 1
	}
	h.text, h.names, h.columns = h.text[:w], h.names[:kept], h.columns[:kept]
	return
}

// The columns of `h` that `names` name, in column order, as a header of their own: what a `record_document`
// of only those cells is keyed by. A name `h` lacks is left out; a name `h` repeats keys its last column. Allocated
// with `allocator`; `.Out_Of_Memory` when it refuses, the header then the zero value.
@(require_results)
header_pick :: proc(h: ^Header, names: []string, allocator := context.allocator) -> (picked: Header, err: Maybe(Error)) {
	marks := make([]bool, len(h.names), allocator)
	defer delete(marks, allocator)
	if marks == nil && len(h.names) > 0 {
		return {}, Error{kind = .Out_Of_Memory}
	}
	count, size := 0, 0
	for name in names {
		for k := len(h.names) - 1; k >= 0; k -= 1 {
			if h.names[k] == name {
				count += int(!marks[k])
				size += len(name) if !marks[k] else 0
				marks[k] = true
				break
			}
		}
	}
	picked = {width = h.width, distinct_keys = true, allocator = allocator}
	aerr: runtime.Allocator_Error
	if picked.text, aerr = make([]byte, size, allocator); aerr == nil {
		picked.names, aerr = make([]string, count, allocator)
	}
	if aerr == nil {
		picked.columns, aerr = make([]int, count, allocator)
	}
	if aerr != nil {
		header_destroy(&picked)
		return {}, Error{kind = .Out_Of_Memory}
	}
	w, i := 0, 0
	for marked, k in marks {
		if !marked {
			continue
		}
		n := copy(picked.text[w:], h.names[k])
		picked.names[i], picked.columns[i] = string(picked.text[w:][:n]), h.columns[k]
		w, i = w + n, i + 1
	}
	return
}

@(private)
header_destroy :: proc(h: ^Header) {
	delete(h.text, h.allocator)
	delete(h.names, h.allocator)
	delete(h.columns, h.allocator)
	h^ = {}
}

// Record `rec` as a document of its own: an object of `h`'s names, each mapping to the cell of its column, in
// column order, a name whose column the record lacks having no member. The record's bytes and `h.text` are copied,
// so the document outlives the record and its source (a `records_from` window); its spans count from the copy.
//
//	- `rec` must be read in the header record's dialect, after it.
//	- A record with more fields than `h.width` is `.Bad_Structure` with `Fault.Field_Count` at `rec.at`: no
//	  name keys its last cells.
//	- The rows and the copy are one allocation of `allocator`, decoded cells a second one when the record has any.
//	  `.Out_Of_Memory` when it refuses, `.Source_Too_Wide` past u32 offsets; the document is then the zero value.
@(require_results)
record_document :: proc(rec: Record, h: ^Header, allocator := context.allocator) -> (doc: Document, err: Maybe(Error)) {
	n := len(rec.fields)
	if n > h.width {
		return {}, fault_error(rec.at, .Field_Count)
	}
	members := 0
	for c in h.columns {
		members += int(c < n)
	}
	lo, hi := rec.fields[0].lo, rec.fields[n - 1].hi
	keys := len(h.text)
	size := u64(keys) + (hi - lo)
	if size > core_pkg.MAX_ROW_SOURCE {
		return {}, Error{kind = .Source_Too_Wide, offset = core_pkg.MAX_ROW_SOURCE}
	}
	rows_bytes := (members + 1) * size_of(core_pkg.Row)
	block, aerr := runtime.mem_alloc_non_zeroed(rows_bytes + int(size), align_of(core_pkg.Row), allocator)
	if aerr != nil {
		return {}, Error{kind = .Out_Of_Memory}
	}
	src := block[rows_bytes:]
	copy(src, h.text)
	copy(src[keys:], rec.src[lo:hi])
	doc = {src = src, spelling = spelling_of(rec.dialect), decoded = true, distinct_keys = h.distinct_keys}
	doc.rows = transmute([dynamic]core_pkg.Row)runtime.Raw_Dynamic_Array{raw_data(block), members + 1, members + 1, allocator}
	doc.values.allocator = allocator
	row := doc.rows[:]
	row[0] = {lo = u32(keys), hi = u32(size), key_lo = core_pkg.NO_KEY, key_hi = core_pkg.NO_KEY, subtree_size = u32(members + 1), kind = .Object, cnt = u32(members)}
	shift := u64(keys) - lo
	k := 1
	for name, i in h.names {
		c := h.columns[i]
		if c >= n {
			continue
		}
		at := u32(uintptr(raw_data(name)) - uintptr(raw_data(h.text)))
		if !cell_row(&row[k], {at, at + u32(len(name)), {.Key_Bare}}, rec.src, rec.fields[c], rec.dialect, shift, &doc) {
			document_destroy(&doc)
			return {}, Error{kind = .Out_Of_Memory}
		}
		k += 1
	}
	return
}

// Free everything an owner holds, and empty it: a `Document`, a `Header`, a `Table`, the `Records` of `records`,
// a `Request`, a `Record_Reader` or a `Type_Plan`. Strings read from a document dangle after.
destroy :: proc {
	document_destroy,
	header_destroy,
	table_destroy,
	records_free,
	request_destroy,
	reader_destroy,
	record_read_destroy,
	core_pkg.shared_plan_destroy,
}

@(private)
document_destroy :: proc(doc: ^Document) {
	delete(doc.rows)
	delete(doc.values)
	delete(doc.key_texts)
	delete(doc.facts)
	core_pkg.row_cache_destroy(doc)
	doc^ = {}
}

// Whether the text of `f` in `src`, read in `dialect`, is `name`: `cell_text` compared without decoding.
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
	case dialect.quoting == .Backslash:
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
