// `build` is used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
package dsv

import "base:intrinsics"
import "base:runtime"
import spell "../core/spell"
import core "../core"
import kernel "../core/kernel"
import build "../core/build"

// dsv's document, built from the walk's tokens over the caller's bytes. A headed text is an `Array` of `Array` records
// whose first child is the header row, an `Array` of role `Key` whose cells name every record's columns. A text without
// a header is an `Array` of `Array`s. A cell is text until a reader calls `resolve`, and the Map readers of a record
// read its cells by their column's header cell, through `Document.header`.

// dsv's edit services, in rodata. The three specs share this table, and each service dispatches on `doc.read.spec`,
// since the specs differ only in how a recorded text is read.
@(private, rodata)
EDIT := core.Edit_Spelling {
	record     = edit_record_at,
	reads      = edit_reads_at,
	comment    = edit_comment,
	record_sep = edit_record_sep,
}

// dsv's spelling services, in rodata, the same table for every spec. A service dispatches on `doc.read.spec`, since the
// specs decode a cell differently: a CSV cell's backslash is a byte and its `""` a quote, a TSV cell's backslash is an
// escape, and a Plain cell has neither quotes nor escapes.
@(private)
SPELLING := core.Spelling {
	text       = spelling_text,
	key_equals = spelling_key_equals,
	number     = spelling_number,
	resolve    = spelling_resolve,
	close_end  = close_end,
	edit       = &EDIT,
}

// The spelling bits dsv sets. Bit 0 (`SPELLING_DECODE`) means `text` must decode a cell, bit 1 (`SPELLING_QUOTED`) a
// quoted CSV cell. No other bit is set.

// Reads a delimited text as spec `S` into a document, allocating its nodes with `allocator`. `opts.no_header` makes the
// first record data. `refuse_duplicates` returns an error at a header name that repeats another in the header row. The
// document borrows `src`, which must outlive it, and `core.destroy` frees the document.
build :: proc(src: []u8, $S: Spec, opts := Options{}, refuse_duplicates := false, allocator := context.allocator) -> (core.Document, core.Document_Error) {
	if f, bad := option_fault(S, opts).?; bad {
		return {}, {kind = .Walk, inner = f}
	}
	// A record is a container inside the document's array, so a dsv text nests at most two containers and 8 stack
	// slots cover it. The node reservation is `len(src) / 2` nodes, an estimate because a cell is not always one byte,
	// and the hook checks capacity as it grows.
	b := build.builder_start(src, &SPELLING, refuse_duplicates, allocator, 2, 8)
	// The document stores the dialect it was read with, so every edit service judges a recorded text and writes its
	// separators the way this text reads. `spec` is what the spelling and edit services dispatch on.
	b.doc.read.spec = u8(S)
	b.doc.read.delimiter = delimiter_of(S, opts)
	b.doc.read.comment = opts.comment
	b.doc.read.no_header = opts.no_header
	if len(b.doc.nodes) == 0 {
		// The reservation was refused and the node array is nil, so no hook may run.
		doc, err := build.builder_end(&b, build.BUILDER_REGS, nil)
		return doc, err
	}
	regs := build.BUILDER_REGS
	// The header row is written before the walk, so the root's token steps over it and the walk's `Key` tokens name
	// its cells. `header_cells` sizes the row by scanning the header record. A text with no header, or no record to
	// read, leaves the root's next node zeroed for the hook's test.
	count := 0
	if !opts.no_header {
		start := record_start(src, int(core.text_start(src, 0)), opts.comment)
		if start < len(src) {
			count = header_cells(src, start, S, opts)
			if rerr := build.builder_reserve(&b, count + 2); rerr.kind != .None {
				doc, err := build.builder_end(&b, regs, nil)
				return doc, err
			}
			b.doc.nodes[1] = core.Node{lo = u64(start), kind = .Array, role = .Key}
			build.builder_close_node(&b, count + 2, 1, u32(count))
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
			doc, err := build.builder_end(&b, regs, nil)
			return doc, err
		}
		keys = fresh
	}
	defer if keys != nil {
		delete(keys, allocator)
	}
	fault: Maybe(core.Fault)
	if opts.comment != 0 {
		_, fault = walk_keys(src, 0, S, opts, &b, &regs, build.builder_hook_keyless_facts, keys)
	} else {
		_, fault = walk_keys(src, 0, S, opts, &b, &regs, build.builder_hook_keyless, keys)
	}
	if count > 0 {
		// The header's cells go into the slots the root's token steps over, before the builder shrinks the node array.
		copy(b.doc.nodes[2:2 + count], keys)
	}
	if refuse_duplicates && count > 0 {
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
			build.builder_refuse_result(&b, core.Node_Index(1), core.Node_Index(count + 2))
		}
	}
	doc, err := build.builder_end(&b, regs, fault)
	if err.kind != .None {
		return doc, err
	}
	// The header row is the root's first child, an `Array` of role `Key`. A text without one has no such node.
	if i := int(core.ROOT) + 1; i < len(doc.nodes) && doc.nodes[i].kind == .Array && doc.nodes[i].role == .Key {
		doc.header = core.Node_Index(i)
	}
	return doc, err
}

// Writes `list`'s edits as spec `as`, returning the text the caller frees with `allocator`. A delimited text writes
// only its own spec: another spec would respell every cell, so the commit refuses it before it splices anything.
commit :: proc(list: ^core.Edit_List, as: Spec, allocator := context.allocator) -> (out: []u8, dropped: int, err: core.Document_Error) {
	if list.doc == nil {
		return nil, 0, {kind = .Bad_Index}
	}
	if list.doc.spelling.edit == nil || list.doc.spelling.edit.record == nil || as != Spec(list.doc.read.spec) {
		return nil, 0, {kind = .Bad_Spec}
	}
	return core.commit_as(list, u8(as), allocator)
}

// Returns node `n`'s span without a surrounding quote pair, if it has one. A quoted CSV cell has that shape.
@(private)
inner_span :: #force_inline proc(src: []u8, n: core.Node) -> (lo, hi: u64) {
	lo, hi = n.lo, n.lo + u64(n.n)
	if hi >= lo + 2 {
		a, b := src[lo], src[hi - 1]
		if (a == '"' || a == '\'') && a == b {
			lo += 1
			hi -= 1
		}
	}
	return
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
dsv_decoded_init :: proc(src: []u8, n: core.Node, spec: Spec) -> Dsv_Decoded {
	if spec == .Csv {
		if n.spelling & core.SPELLING_QUOTED != 0 {
			lo, hi := inner_span(src, n)
			return {src = src, p = lo, end = hi, quoted = true}
		}
		return {src = src, p = n.lo, end = n.lo + u64(n.n)}
	}
	return {src = src, p = n.lo, end = n.lo + u64(n.n), tsv = spec == .Tsv}
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

// Whether a quoted cell's inner span is its text: it holds no `""` and its bytes are well-formed UTF-8. A cell holding
// `""` decodes to fewer bytes, and one under `lax` held an ill-formed sequence that decodes as U+FFFD. The byte scan
// moves eight bytes at a time while they are ASCII and hold no quote byte.
@(private)
plain_quoted :: proc(src: []u8, n: core.Node) -> bool {
	lo, hi := inner_span(src, n)
	b := src[lo:hi]
	i := 0
	base := raw_data(b)
	for i + 8 <= len(b) {
		w := intrinsics.unaligned_load((^u64)(base[i:]))
		x := w ~ 0x2222_2222_2222_2222
		quotes := (x - 0x0101_0101_0101_0101) & ~x & 0x8080_8080_8080_8080
		if quotes != 0 || w & 0x8080_8080_8080_8080 != 0 {
			break
		}
		i += 8
	}
	for i < len(b) {
		c := b[i]
		if c == '"' {
			// The walk accepted the cell, so a quote in its inner span is the first of a `""` pair.
			return false
		}
		if c < 0x80 {
			i += 1
			continue
		}
		q, kind := kernel.utf8_char(base[i:], base[len(b):])
		if kind != .None {
			return false
		}
		i += int(intrinsics.ptr_sub(q, base[i:]))
	}
	return true
}

// dsv's `Spelling.text`. It returns a cell that needs no decode as a slice of the source: a quoted CSV cell without
// `""` and with well-formed UTF-8 as its inner span, and another cell as its span. It decodes a quoted cell holding
// `""`, a TSV escape and a `lax` cell into `buf`, and returns false when `buf` is too short.
@(private)
spelling_text :: proc(doc: ^core.Document, i: core.Node_Index, buf: []u8) -> (s: string, ok: bool) {
	n := doc.nodes[i]
	spec := Spec(doc.read.spec)
	if spec == .Csv && n.spelling & core.SPELLING_QUOTED != 0 && plain_quoted(doc.src, n) {
		lo, hi := inner_span(doc.src, n)
		return string(doc.src[lo:hi]), true
	}
	if n.spelling & core.SPELLING_DECODE == 0 {
		return string(doc.src[n.lo:n.lo + u64(n.n)]), true
	}
	// A cell carries `SPELLING_DECODE` when its span must be decoded. That is a quoted CSV cell holding `""`, a TSV
	// cell with a backslash, which the pass's block mask answers, and any cell under `lax`, where a tolerated ill-formed
	// sequence reads as U+FFFD.
	return spell.decode_text(buf, dsv_decoded_init(doc.src, n, spec), dsv_decoded_next)
}

// dsv's text reader, exported so a caller that knows the format calls it without the table. It decodes into `buf` and
// returns false for a container, an index past the last node, or a `buf` too short for the decoded cell.
text :: #force_inline proc(doc: ^core.Document, i: core.Node_Index, buf: []u8) -> (s: string, ok: bool) {
	if int(i) >= len(doc.nodes) {
		return "", false
	}
	n := doc.nodes[i]
	if n.kind > .Plain {
		return "", false
	}
	return spelling_text(doc, i, buf)
}




// dsv's `Spelling.key_equals`. It returns whether cell `i` decodes to `name`, with no allocation. A cell that needs no
// decode is compared by its span, or by its inner span for a quoted cell without `""`, and one that needs it byte by
// byte as it decodes.
@(private)
spelling_key_equals :: proc(doc: ^core.Document, i: core.Node_Index, name: string) -> bool {
	n := doc.nodes[i]
	spec := Spec(doc.read.spec)
	if spec == .Csv && n.spelling & core.SPELLING_QUOTED != 0 && plain_quoted(doc.src, n) {
		lo, hi := inner_span(doc.src, n)
		return spell.bytes_equal(doc.src[lo:hi], transmute([]u8)name)
	}
	if n.spelling & core.SPELLING_DECODE == 0 {
		return spell.bytes_equal(doc.src[n.lo:n.lo + u64(n.n)], transmute([]u8)name)
	}
	d := dsv_decoded_init(doc.src, n, spec)
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




// dsv's `Spelling.number`. It returns the JSON number a value cell spells, else `Wide`. A quoted cell, a TSV escape and
// a key cell all return `Wide`, since no JSON number holds a quote, a backslash or a byte past 0x7F. A header cell names
// a column and answers as a JSON key node does.
@(private)
spelling_number :: proc(doc: ^core.Document, i: core.Node_Index) -> core.Number {
	n := doc.nodes[i]
	if n.role != .Value {
		return {0, .Wide}
	}
	s := doc.src[n.lo:n.lo + u64(n.n)]
	if num, is_number := spell.number_json(s, 0, u64(len(s))); is_number {
		return num
	}
	return {0, .Wide}
}

// dsv's number reader, exported so a caller that knows the format calls it without the table. A value cell that is
// exactly a JSON number reads as that number, and every other cell and a container read `.Wide`.
number :: #force_inline proc(doc: ^core.Document, i: core.Node_Index) -> core.Number {
	if int(i) < len(doc.nodes) && doc.nodes[i].kind <= .Plain {
		return spelling_number(doc, i)
	}
	return {0, .Wide}
}

// dsv's `Spelling.resolve`. It returns `.String` by default. With `opts.infer`, an empty value cell is `.Null`, a `true`
// or `false` value cell is `.True` or `.False`, and a value cell that is exactly a JSON number is `.Number`. A quoted
// cell and a TSV escape are `.String`, since no number, `true` or `false` holds a quote or a backslash.
@(private)
spelling_resolve :: proc(doc: ^core.Document, i: core.Node_Index, opts: core.Resolve_Options) -> core.Kind {
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
	s := doc.src[n.lo:n.lo + u64(n.n)]
	switch string(s) {
	case "":
		return .Null
	case "true":
		return .True
	case "false":
		return .False
	}
	if _, is_number := spell.number_json(s, 0, u64(len(s))); is_number {
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
	_, fault := walk(src, 0, S, {no_header = true, delimiter = doc.read.delimiter, comment = doc.read.comment}, &h, &regs, shape_hook)
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
	t := bit_set[Tolerance; u8]{.Invalid_Utf8, .Ragged, .Bare_Quote} if tolerate else {}
	return validate(src, S, {no_header = doc.read.no_header, delimiter = doc.read.delimiter, comment = doc.read.comment, tolerate = t}).?
}

// Returns the line end record `i` ends with, or an empty string when it has none.
@(private)
record_line_end :: proc(doc: ^core.Document, i: core.Node_Index) -> string {
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
	switch Spec(doc.read.spec) {
	case .Csv:   return edit_record(doc, src, allocator, .Csv)
	case .Tsv:   return edit_record(doc, src, allocator, .Tsv)
	case .Plain: return edit_record(doc, src, allocator, .Plain)
	}
	return 0, {kind = .Bad_Value}
}

@(private)
edit_reads_at :: proc(doc: ^core.Document, src: []u8, tolerate: bool, spec: u8) -> (core.Fault, bool) {
	// A spec change would respell every cell, which is the writer's job, so the text must use the document's own grammar.
	if spec != doc.read.spec {
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
	return (.Byte if doc.read.comment != 0 else .None), doc.read.comment
}

// The byte just past record `i`'s line end, CR LF included. A record at the text's end stops past its last cell. The
// root ends at `len(doc.src)`. Only a container span read calls it.
@(private, cold)
record_end :: proc(doc: ^core.Document, i: core.Node_Index) -> u64 {
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
close_end :: proc(doc: ^core.Document, i: core.Node_Index) -> u64 {
	if i == core.ROOT {
		return u64(len(doc.src))
	}
	return record_end(doc, i)
}
