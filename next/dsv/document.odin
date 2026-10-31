package dsv

import "base:intrinsics"
import "base:runtime"
import core "../core"
import kernel "../core/kernel"

// dsv's document, built from the walk's tokens over the caller's bytes. A headed text is an `Array` of `Array` records
// whose first child is the header row, an `Array` of role `Key` whose cells name every record's columns. A text without
// a header is an `Array` of `Array`s. A cell is text until a reader calls `resolve`, and the Map readers of a record
// read its cells by their column's header cell, through `Document.header`.

// dsv's edit services, in rodata. The three specs share this table, and each service dispatches on `doc.spec`, since
// the specs differ only in how a recorded text is read.
@(private, rodata)
EDIT := core.Edit_Spelling {
	record     = edit_record_at,
	reads      = edit_reads_at,
	comment    = edit_comment,
	record_sep = edit_record_sep,
}

// dsv's spelling services, in rodata. Every dsv document points to one of the three tables, one per spec. A CSV cell's
// backslash is a byte, a TSV cell's is an escape, and a Plain cell has neither quotes nor escapes, so the three decode
// a cell differently.
@(private)
SPELLING_CSV := core.Spelling {
	text       = spelling_text_csv,
	key_equals = spelling_key_equals_csv,
	number     = spelling_number,
	resolve    = spelling_resolve,
	close_end  = close_end,
	edit       = &EDIT,
}

@(private)
SPELLING_TSV := core.Spelling {
	text       = spelling_text_tsv,
	key_equals = spelling_key_equals_tsv,
	number     = spelling_number,
	resolve    = spelling_resolve,
	close_end  = close_end,
	edit       = &EDIT,
}

@(private)
SPELLING_PLAIN := core.Spelling {
	text       = spelling_text_plain,
	key_equals = spelling_key_equals_plain,
	number     = spelling_number,
	resolve    = spelling_resolve,
	close_end  = close_end,
	edit       = &EDIT,
}

// The spelling bits dsv sets. Bit 0 (`SPELLING_DECODE`) means `text` must decode a cell, bit 1 (`SPELLING_QUOTED`) a
// quoted CSV cell. No other bit is set.

@(private)
spelling_for :: #force_inline proc "contextless" ($S: Spec) -> ^core.Spelling {
	when S == .Csv {
		return &SPELLING_CSV
	} else when S == .Tsv {
		return &SPELLING_TSV
	} else {
		return &SPELLING_PLAIN
	}
}

// Reads a delimited text as spec `S` into a document, allocating its nodes with `allocator`. `opts.no_header` makes the
// first record data. `dups` `.Refuse` returns an error at a header name that repeats another in the header row. The
// document borrows `src`, which must outlive it, and `core.destroy` frees the document.
build :: proc(src: []u8, $S: Spec, opts := Options{}, dups := core.Duplicates.Last, allocator := context.allocator) -> (core.Document, core.Document_Error) {
	if f, bad := option_fault(S, opts).?; bad {
		return {}, {kind = .Walk, inner = f}
	}
	// A record is a container inside the document's array, so a dsv text nests at most two containers and 8 stack
	// slots cover it. The node reservation is `len(src) / 2` nodes, an estimate because a cell is not always one byte,
	// and the hook checks capacity as it grows.
	b := core.builder_start(src, spelling_for(S), dups, allocator, 2, 8)
	// The document stores the dialect it was read with, so every edit service judges a recorded text and writes its
	// separators the way this text reads. `spelling_for` sets the spelling table, and `spec` is stored beside it for
	// the edit services.
	b.doc.spec = u8(S)
	b.doc.delimiter = delimiter_of(S, opts)
	b.doc.comment = opts.comment
	b.doc.no_header = opts.no_header
	if len(b.doc.nodes) == 0 {
		// The reservation was refused and the node array is nil, so no hook may run.
		doc, err := core.builder_end(&b, core.BUILDER_REGS, nil)
		return doc, err
	}
	regs := core.BUILDER_REGS
	// The builder hook keeps the open container's index and its child count in `s.b`, and the depth in `s.c`.
	regs.b = u64(core.NO_NODE) << 32
	regs.c = 0
	// The header row is written before the walk, so the root's token steps over it and the walk's `Key` tokens name
	// its cells. `header_cells` sizes the row by scanning the header record. A text with no header, or no record to
	// read, leaves the root's next node zeroed for the hook's test.
	count := 0
	if !opts.no_header {
		start := record_start(src, int(core.text_start(src, 0)), opts.comment)
		if start < len(src) {
			count = header_cells(src, start, S, opts)
			if rerr := core.builder_reserve(&b, count + 2); rerr.kind != .None {
				doc, err := core.builder_end(&b, regs, nil)
				return doc, err
			}
			b.doc.nodes[1] = core.Node{u64(start), u32(count + 1), .Array, .Key, u16(min(count, int(core.CHILDREN_MAX)))}
		}
	}
	if count == 0 {
		b.doc.nodes[1] = {}
	}
	// The key buffer holds the header's cells for the walk, which then allocates none. It is separate from the node
	// array because that array moves as the walk grows it, and the row's slots are filled from it after the walk.
	keys: []core.Token
	if count > 0 {
		fresh, kerr := make([]core.Token, count, allocator)
		if kerr != nil {
			b.err = {kind = .No_Memory}
			doc, err := core.builder_end(&b, regs, nil)
			return doc, err
		}
		keys = fresh
	}
	defer if keys != nil {
		delete(keys, allocator)
	}
	fault: Maybe(core.Fault)
	if opts.comment != 0 {
		_, fault = walk(src, 0, S, opts, &b, &regs, core.builder_hook_keyless_facts, keys)
	} else {
		_, fault = walk(src, 0, S, opts, &b, &regs, core.builder_hook_keyless, keys)
	}
	if count > 0 {
		// The header's cells go into the slots the root's token steps over, before the builder shrinks the node array.
		copy(b.doc.nodes[2:2 + count], keys)
	}
	if dups == .Refuse && count > 0 {
		// A fault inside the header row leaves some slots zero, whose kind is not `Plain`. Check a complete row, and
		// merge the result as the builder's close path does: the earliest repeat wins and a refused allocation
		// replaces no earlier error.
		filled := true
		if _, bad := fault.?; bad {
			for i in 0 ..< count {
				if keys[i].kind != .Plain {
					filled = false
					break
				}
			}
		}
		if filled {
			if e := core.duplicate_key(&b.doc, 1, u32(count + 2), allocator, true); e.kind != .None {
				switch {
				case e.kind == .Duplicate_Key:
					if b.err.kind != .Duplicate_Key || e.at < b.err.at {
						b.err = e
					}
				case b.err.kind == .None:
					b.err = e
				}
			}
		}
	}
	doc, err := core.builder_end(&b, regs, fault)
	if err.kind != .None {
		return doc, err
	}
	// The header row is the root's first child, an `Array` of role `Key`. A text without one has no such node.
	if i := int(core.ROOT) + 1; i < len(doc.nodes) && doc.nodes[i].kind == .Array && doc.nodes[i].role == .Key {
		doc.header = u32(i)
	}
	return doc, err
}

// Decodes one cell. A CSV cell's inner bytes have each `""` read as `"`, or a TSV cell's bytes have each accepted
// escape read as the byte it spells. A byte past 0x7F reads as one UTF-8 character, or U+FFFD over its maximal subpart
// when it is ill-formed. `buf` holds the bytes of a character read in parts, `at` the next one and `n` how many are
// left.
@(private)
Dsv_Decoded :: struct {
	src:    []u8,
	p, end: u64,
	tsv:    bool,
	quoted: bool,
	buf:    [4]u8,
	n:      u8,
	at:     u8,
}

@(private)
dsv_decoded_init :: proc(src: []u8, n: core.Node, $S: Spec) -> Dsv_Decoded {
	when S == .Csv {
		quoted := n.spelling & core.SPELLING_QUOTED != 0
		if quoted {
			lo, hi := core.inner_span(src, n)
			return {src = src, p = lo, end = hi, quoted = true}
		}
		return {src = src, p = n.lo, end = n.lo + u64(n.n)}
	} else when S == .Tsv {
		return {src = src, p = n.lo, end = n.lo + u64(n.n), tsv = true}
	} else {
		return {src = src, p = n.lo, end = n.lo + u64(n.n)}
	}
}

@(private)
dsv_decoded_next :: proc(d: ^Dsv_Decoded) -> (b: u8, ok: bool) {
	if d.n > 0 {
		b = d.buf[d.at]
		d.at += 1
		d.n -= 1
		return b, true
	}
	if d.p >= d.end {
		return 0, false
	}
	c := d.src[d.p]
	if d.tsv && c == '\\' {
		if d.p + 1 >= d.end {
			d.p = d.end
			return '\\', true
		}
		e := d.src[d.p + 1]
		d.p += 2
		switch e {
		case 't':
			return '\t', true
		case 'n':
			return '\n', true
		case 'r':
			return '\r', true
		case '0':
			return 0, true
		case '\\':
			return '\\', true
		case:
			unreachable()
		}
	}
	if d.quoted && c == '"' && d.p + 1 < d.end && d.src[d.p + 1] == '"' {
		d.p += 2
		return '"', true
	}
	if c < 0x80 {
		d.p += 1
		return c, true
	}
	base := raw_data(d.src)
	q, kind := kernel.utf8_char(base[d.p:], base[d.end:])
	if kind == .None {
		n := int(intrinsics.ptr_sub(q, base[d.p:]))
		copy(d.buf[:], d.src[d.p:d.p + u64(n)])
		d.p += u64(n)
		d.n = u8(n - 1)
		d.at = 1
		return d.buf[0], true
	}
	q = kernel.utf8_subpart(base[d.p:], base[d.end:])
	d.p += u64(intrinsics.ptr_sub(q, base[d.p:]))
	d.buf = {0xEF, 0xBF, 0xBD, 0}
	d.n = 2
	d.at = 1
	return d.buf[0], true
}

// Whether a cell is its own text, with no quoted CSV cell, no TSV backslash and well-formed UTF-8. Such a cell is a
// slice of the source, with no decode.
@(private)
dsv_plain :: proc(src: []u8, n: core.Node, $S: Spec) -> bool {
	when S == .Csv {
		if n.spelling & core.SPELLING_QUOTED != 0 {
			return false
		}
	}
	b := src[n.lo:n.lo + u64(n.n)]
	i := 0
	for i < len(b) {
		c := b[i]
		if S == .Tsv && c == '\\' {
			return false
		}
		if c < 0x80 {
			i += 1
			continue
		}
		q, kind := kernel.utf8_char(raw_data(b)[i:], raw_data(b)[len(b):])
		if kind != .None {
			return false
		}
		i += int(intrinsics.ptr_sub(q, raw_data(b)[i:]))
	}
	return true
}

// dsv's `Spelling.text`. It returns a plain cell as a slice of the source, and decodes a quoted or escaped cell into
// `buf` or `allocator`.
@(private)
spelling_text :: proc(doc: ^core.Document, i: u32, buf: []u8, allocator: runtime.Allocator, $S: Spec) -> (string, bool) {
	n := doc.nodes[i]
	when S != .Tsv {
		if dsv_plain(doc.src, n, S) {
			return string(doc.src[n.lo:n.lo + u64(n.n)]), true
		}
	}
	// A cell carries `SPELLING_DECODE` when its span must be decoded. That is a TSV cell with a backslash, which the
	// pass's block mask answers, and any cell under `lax`, where a tolerated ill-formed sequence reads as U+FFFD.
	return core.decode_text(buf, allocator, dsv_decoded_init(doc.src, n, S), dsv_decoded_next)
}

@(private)
spelling_text_csv :: proc(doc: ^core.Document, i: u32, buf: []u8, allocator := context.allocator) -> (string, bool) {
	return spelling_text(doc, i, buf, allocator, .Csv)
}

@(private)
spelling_text_tsv :: proc(doc: ^core.Document, i: u32, buf: []u8, allocator := context.allocator) -> (string, bool) {
	return spelling_text(doc, i, buf, allocator, .Tsv)
}

@(private)
spelling_text_plain :: proc(doc: ^core.Document, i: u32, buf: []u8, allocator := context.allocator) -> (string, bool) {
	return spelling_text(doc, i, buf, allocator, .Plain)
}

// dsv's `Spelling.key_equals`. It returns whether cell `i` decodes to `name`, with no allocation. A plain cell is
// compared by its span, a quoted or escaped one byte by byte as it decodes.
@(private)
spelling_key_equals :: proc(doc: ^core.Document, i: u32, name: string, $S: Spec) -> bool {
	n := doc.nodes[i]
	when S != .Tsv {
		if dsv_plain(doc.src, n, S) {
			return core.bytes_equal(doc.src[n.lo:n.lo + u64(n.n)], transmute([]u8)name)
		}
	}
	d := dsv_decoded_init(doc.src, n, S)
	at := 0
	for {
		b, ok := dsv_decoded_next(&d)
		if !ok {
			return at == len(name)
		}
		if at >= len(name) || name[at] != b {
			return false
		}
		at += 1
	}
}

@(private)
spelling_key_equals_csv :: proc(doc: ^core.Document, i: u32, name: string) -> bool {
	return spelling_key_equals(doc, i, name, .Csv)
}

@(private)
spelling_key_equals_tsv :: proc(doc: ^core.Document, i: u32, name: string) -> bool {
	return spelling_key_equals(doc, i, name, .Tsv)
}

@(private)
spelling_key_equals_plain :: proc(doc: ^core.Document, i: u32, name: string) -> bool {
	return spelling_key_equals(doc, i, name, .Plain)
}

// `dsv_plain` with the spec of the document's spelling table.
@(private)
plain_cell :: proc(doc: ^core.Document, n: core.Node) -> bool {
	if doc.spelling == &SPELLING_TSV {
		return dsv_plain(doc.src, n, .Tsv)
	}
	if doc.spelling == &SPELLING_PLAIN {
		return dsv_plain(doc.src, n, .Plain)
	}
	return dsv_plain(doc.src, n, .Csv)
}

// dsv's `Spelling.number`. It returns the JSON number a plain value cell spells, else `Wide`. A cell that needs
// decoding, a quoted cell, a TSV escape and a key cell all return `Wide`. A header cell names a column and answers as a
// JSON key node does.
@(private)
spelling_number :: proc(doc: ^core.Document, i: u32) -> core.Number {
	n := doc.nodes[i]
	if n.role != .Value || !plain_cell(doc, n) {
		return {0, .Wide}
	}
	s := doc.src[n.lo:n.lo + u64(n.n)]
	if num, is_number := core.number_json(s, 0, u64(len(s))); is_number {
		return num
	}
	return {0, .Wide}
}

// dsv's `Spelling.resolve`. It returns `.String` by default. With `opts.infer`, a plain empty cell is `.Null`, a plain
// `true` or `false` is `.True` or `.False`, and a plain cell that is exactly a JSON number is `.Number`. A quoted cell
// or a TSV escape is `.String`.
@(private)
spelling_resolve :: proc(doc: ^core.Document, i: u32, opts: core.Resolve_Options) -> core.Kind {
	n := doc.nodes[i]
	if n.kind != .Plain {
		return n.kind
	}
	// A key cell is text, as a JSON key node is, since a header cell names a column whatever it spells.
	if n.role != .Value {
		return .String
	}
	if !opts.infer {
		return .String
	}
	if !plain_cell(doc, n) {
		return .String
	}
	s := doc.src[n.lo:n.lo + u64(n.n)]
	switch string(s) {
	case "":
		return .Null
	case "true":
		return .True
	case "false":
		return .False
	}
	if _, is_number := core.number_json(s, 0, u64(len(s))); is_number {
		return .Number
	}
	return .String
}

// The shape of an edit's text. `arrays` counts its `Array` tokens, `cells` its `Plain` tokens, `record_lo` is the
// second `Array`'s byte, and `last_cell_end` is one past the last `Plain`'s bytes.
@(private)
Text_Shape :: struct {
	arrays:        int,
	cells:         int,
	record_lo:     u64,
	last_cell_end: u64,
}

@(private)
shape_hook :: proc "contextless" (h: ^Text_Shape, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	switch t.kind {
	case .Array:
		h.arrays += 1
		if h.arrays == 2 {
			h.record_lo = t.lo
		}
	case .Plain:
		h.cells += 1
		h.last_cell_end = t.lo + u64(t.n)
	case .End, .Null, .False, .True, .Number, .String, .Map:
	}
	return s, .Next
}

// Checks that an edit's text is a record of at least one cell, with its record at the text's start and its last cell
// ending at the text's end, so the text writes no line end of its own. A recorded text that holds the delimiter outside
// quotes reads as two cells and is refused, and so is one that starts a line with the comment byte, which the walk reads
// as no record. A CSV or TSV cell holding the delimiter must be quoted or escaped by the caller. Plain has no quote, so
// its cells cannot hold the delimiter at all. Returns the cell count.
@(private)
edit_record :: proc(doc: ^core.Document, src: []u8, _: runtime.Allocator, $S: Spec) -> (cells: int, err: core.Document_Error) {
	h: Text_Shape
	regs: core.Hook_Regs
	_, fault := walk(src, 0, S, {no_header = true, delimiter = doc.delimiter, comment = doc.comment}, &h, &regs, shape_hook)
	if f, bad := fault.?; bad {
		return 0, {kind = .Bad_Value, inner = f}
	}
	if h.arrays != 2 || h.cells < 1 || h.record_lo != 0 || h.last_cell_end != u64(len(src)) {
		return 0, {kind = .Bad_Value}
	}
	return h.cells, {}
}

// Validates an edit's text, strictly or with all three tolerances set. The commit reads its output strictly, then
// tolerantly. A delimited text can write only its own dialect, so `spec` must be the document's.
@(private)
edit_reads :: proc(doc: ^core.Document, src: []u8, tolerate: bool, _: u8, $S: Spec) -> (core.Fault, bool) {
	t := core.tolerances(tolerate, bit_set[Tolerance; u8]{.Invalid_Utf8, .Ragged, .Bare_Quote})
	return validate(src, S, {no_header = doc.no_header, delimiter = doc.delimiter, comment = doc.comment, tolerate = t}).?
}

// Returns the line end record `i` ends with, or an empty string when it has none.
@(private)
record_line_end :: proc(doc: ^core.Document, i: u32) -> string {
	p := record_end(doc, i)
	if p == 0 || doc.src[p-1] != '\n' {
		return ""
	}
	return "\r\n" if p >= 2 && doc.src[p-2] == '\r' else "\n"
}

// The line end a record insert writes. It is the first line end a record has, else its header's, else LF.
@(private)
edit_record_sep :: proc(doc: ^core.Document) -> string {
	it := core.children(doc, core.ROOT)
	for {
		rec, ok := core.child_next(&it)
		if !ok {
			break
		}
		if e := record_line_end(doc, rec); e != "" {
			return e
		}
	}
	if doc.header != 0 {
		if e := record_line_end(doc, doc.header); e != "" {
			return e
		}
	}
	return "\n"
}

@(private)
edit_record_at :: proc(doc: ^core.Document, src: []u8, allocator: runtime.Allocator) -> (cells: int, err: core.Document_Error) {
	switch Spec(doc.spec) {
	case .Csv:   return edit_record(doc, src, allocator, .Csv)
	case .Tsv:   return edit_record(doc, src, allocator, .Tsv)
	case .Plain: return edit_record(doc, src, allocator, .Plain)
	}
	return 0, {kind = .Bad_Value}
}

@(private)
edit_reads_at :: proc(doc: ^core.Document, src: []u8, tolerate: bool, spec: u8) -> (core.Fault, bool) {
	// A spec change would respell every cell, which is the writer's job, so the text must use the document's own grammar.
	if spec != doc.spec {
		return {kind = .Bad_Structure}, true
	}
	switch Spec(spec) {
	case .Csv:   return edit_reads(doc, src, tolerate, spec, .Csv)
	case .Tsv:   return edit_reads(doc, src, tolerate, spec, .Tsv)
	case .Plain: return edit_reads(doc, src, tolerate, spec, .Plain)
	}
	return {}, true
}

// A delimited text's comment spelling. It is `.Byte` with the document's comment byte, or `.None` when the byte is 0.
@(private)
edit_comment :: proc(doc: ^core.Document, _: u8) -> (core.Comment_Spelling, u8) {
	return (.Byte if doc.comment != 0 else .None), doc.comment
}

// The byte just past record `i`'s line end, CR LF included. A record at the text's end stops past its last cell. The
// root ends at `len(doc.src)`. Only a container span read calls it.
@(private, cold)
record_end :: proc(doc: ^core.Document, i: u32) -> u64 {
	n := doc.nodes[i]
	p := n.lo
	if n.n > 1 {
		last := doc.nodes[int(i) + int(n.n) - 1]
		p = last.lo + u64(last.n)
	}
	if p < u64(len(doc.src)) && doc.src[p] == '\r' {
		p += 1
	}
	if p < u64(len(doc.src)) && doc.src[p] == '\n' {
		p += 1
	}
	return p
}

// The byte just past container `i`'s close. The root ends at `len(doc.src)`, and a record at its line end.
@(private, cold)
close_end :: proc(doc: ^core.Document, i: u32) -> u64 {
	if i == core.ROOT {
		return u64(len(doc.src))
	}
	return record_end(doc, i)
}
