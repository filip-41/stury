// `build` is used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
package dsv

import "base:intrinsics"
import "base:runtime"
import "core:bytes"
import spell "../core/spell"
import core "../core"
import compose "../core/compose"
import kernel "../core/kernel"
import build "../core/build"

// dsv's document, built from the walk's tokens over the caller's bytes. A headed text is an `Array` of `Map` records
// whose first child is the header row, an `Array` of role `Key` whose cells name every record's columns. A text without
// a header is an `Array` of `Array`s. A cell is text until a reader calls `resolve`, and a headed record's shared keys
// sit in `Document.shared_keys`.

// dsv's edit services, in rodata. The three specs share this table, and each service dispatches on `doc.as.spec`,
// since the specs differ only in how a recorded text is read.
@(private, rodata)
EDIT := core.Edit_Spelling {
	value         = edit_value_at,
	key_text      = edit_key_text,
	comment       = edit_comment,
	member_sep    = edit_cell_sep,
	insert_check  = edit_insert_check,
	interior      = edit_interior,
	fact_slot     = edit_fact_slot,
	emptied       = edit_emptied,
	plan          = edit_plan,
	commit        = edit_commit,
	flat          = true,
}

@(private, rodata)
ROOT_EDIT := compose.Root_Spelling {
	root_head     = compose_root_head,
	root_junction = compose_root_junction,
}

@(private)
edit_commit :: proc(list: ^core.Edit_List, spec: u8, allocator: runtime.Allocator) -> (out: []u8, dropped: int, err: core.Document_Error) {
	return compose.commit(list, spec, &ROOT_EDIT, allocator)
}

// dsv's spelling services, in rodata, the same table for every spec. A service dispatches on `doc.as.spec`, since the
// specs decode a cell differently: a CSV cell's backslash is a byte and its `""` a quote, a TSV cell's backslash is an
// escape, and a Plain cell has neither quotes nor escapes.
@(private)
SPELLING := core.Spelling {
	text       = spelling_text,
	key_equals = spelling_key_equals,
	number     = spelling_number,
	build      = build_as,
	validate   = validate_as,
	scan       = scan_as,
	resolve    = spelling_resolve,
	close_end  = close_end,
	query      = build.query,
	edit       = &EDIT,
	tag_key    = "csv",
	write      = document_write,
	tokens     = &TOKENS,
	records    = &RECORDS,
}

// The spelling bits dsv sets. Bit 0 (`SPELLING_DECODE`) means `text` must decode a cell, bit 1 (`SPELLING_QUOTED`) a
// quoted CSV cell, and bit 2 (`SPELLING_LAX`) that a tolerated ill-formed sequence may grow its decode.

// `Token.spelling`'s bit for a quoted CSV cell holding a `""`, set only on a walk for `Cells` or `Batch`.
@(private)
SPELLING_DOUBLED :: u16(8)

// Reads a delimited text as spec `S` into a document, allocating its nodes with `allocator`. `opts.no_header` makes the
// first record data. `refuse_duplicates` returns an error at a header name that repeats another in the header row. The
// document borrows `src`, which must outlive it, and `core.destroy` frees the document. It is `core.build` with
// `as(spec, opts)`.
build :: #force_inline proc(src: []u8, spec: Spec, opts := Options{}, refuse_duplicates := false, allocator := context.allocator) -> (core.Document, core.Document_Error) {
	return core.build(src, as(spec, opts), refuse_duplicates, allocator)
}

// The handle's build: the walk compiled for the handle's spec.
@(private)
build_as :: proc(src: []u8, as: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	switch Spec(as.spec) {
	case .Csv:   return build_spec(src, .Csv, options_of(as), refuse_duplicates, allocator)
	case .Tsv:   return build_spec(src, .Tsv, options_of(as), refuse_duplicates, allocator)
	case .Plain: return build_spec(src, .Plain, options_of(as), refuse_duplicates, allocator)
	}
	return {}, {kind = .Bad_Spec}
}

@(private)
build_spec :: proc(src: []u8, $S: Spec, opts: Options, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	if f, bad := option_fault(S, opts).?; bad {
		return {}, {kind = .Walk, inner = f}
	}
	// `header_cells` sizes the row by scanning the header record. A text with no header, or no record to read, has no
	// row. The key buffer holds the header's cells for the walk, which then allocates none, and for a second walk if the
	// reservation is refused. It is separate from the node array because that array moves as the walk grows it.
	start, count := 0, 0
	if !opts.no_header {
		start = record_start(src, int(core.text_start(src, 0)), opts.comment)
		if start < len(src) {
			count = header_cells(src, start, S, opts)
		}
	}
	keys: []core.Token
	if count > 0 {
		fresh, kerr := make([]core.Token, count, allocator)
		if kerr != nil {
			return {}, {kind = .No_Memory}
		}
		keys = fresh
	}
	defer if keys != nil {
		delete(keys, allocator)
	}
	// The node reservation is `len(src) / 2` nodes, an estimate because a cell is not always one byte, and the hook
	// checks capacity as it grows. A header row of `count` cells and its node follow the root.
	doc, err := build_reserved(src, S, opts, refuse_duplicates, allocator, max(len(src) / 2, count + 2), 0, start, keys)
	if err.kind != .No_Memory {
		return doc, err
	}
	// The allocator refused the estimate or a growth. Reading the text again sizes every buffer exactly, so only a
	// document that does not fit the allocator fails. The hook tests capacity before a close, which writes no node, so
	// the buffer holds one node more than the text has, and `builder_end` returns it.
	need: build.Count
	regs: core.Hook_Regs
	walk_keys(src, 0, S, opts, &need, &regs, build.builder_hook_count_keyless, keys)
	return build_reserved(src, S, opts, refuse_duplicates, allocator, need.nodes + count + 2, need.facts, start, keys)
}

// Reads `src` into a builder with room for `nodes` nodes and `facts` facts, which the hooks grow past. `keys` holds a
// token per header cell, and `start` is the header's first byte.
@(private)
build_reserved :: proc(src: []u8, $S: Spec, opts: Options, refuse_duplicates: bool, allocator: runtime.Allocator, nodes, facts, start: int, keys: []core.Token) -> (core.Document, core.Document_Error) {
	// A record is a container inside the document's array, so a dsv text nests at most two containers and 8 stack slots
	// cover it.
	// The document holds the options it was read with, so every edit service judges a recorded text and writes its
	// separators the way this text reads.
	line := bytes.index_byte(src, '\n')
	layout := opts
	layout.crlf = line > 0 && src[line - 1] == '\r'
	b := build.builder_start(src, as(S, layout), refuse_duplicates, allocator, nodes, 8, facts)
	if len(b.doc.nodes) == 0 {
		// The reservation was refused and the node array is nil, so no hook may run.
		return build.builder_end(&b, build.BUILDER_REGS, nil)
	}
	regs := build.BUILDER_REGS
	// The header row is written before the walk, so the root's token steps over it and the walk's `Key` tokens name its
	// cells. A text with no row leaves the root's next node zeroed for the hook's test.
	count := len(keys)
	if count > 0 {
		b.doc.nodes[1] = core.Node{lo = u64(start), kind = .Array, role = .Key}
		build.builder_close_node(&b, count + 2, 1, u32(count))
	} else {
		b.doc.nodes[1] = {}
	}
	fault: Maybe(core.Fault)
	if opts.comment != 0 {
		b.root_close, fault = walk_keys(src, 0, S, opts, &b, &regs, build.builder_hook_keyless_facts, keys)
	} else {
		b.root_close, fault = walk_keys(src, 0, S, opts, &b, &regs, build.builder_hook_keyless, keys)
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
		doc.shared_keys = core.Node_Index(i)
	}
	return doc, err
}

// Returns node `n`'s span without a surrounding quote pair, if it has one. A quoted CSV cell has that shape.
@(private)
inner_span :: #force_inline proc "contextless" (src: []u8, n: core.Node) -> (lo, hi: u64) {
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
// when it is ill-formed. `pending` holds the rest of a character read in parts.
@(private)
Dsv_Decoded :: struct {
	src:     []u8,
	p, end:  u64,
	tsv:     bool,
	quoted:  bool,
	pending: spell.Pending,
}

@(private)
dsv_decoded_init :: proc "contextless" (src: []u8, n: core.Node, spec: Spec) -> Dsv_Decoded {
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
dsv_decoded_next :: proc "contextless" (d: ^Dsv_Decoded) -> (b: u8, ok: bool) {
	if b, ok = spell.pending_next(&d.pending); ok {
		return
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
		for k in 0 ..< len(TSV_LETTERS) {
			if TSV_LETTERS[k] == e {
				return TSV_ESCAPED[k], true
			}
		}
		unreachable()
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
		spelled: [4]u8
		copy(spelled[:], d.src[d.p:d.p + u64(n)])
		d.p += u64(n)
		return spell.pending_give(&d.pending, spelled, n), true
	}
	q = kernel.utf8_subpart(base[d.p:], base[d.end:])
	d.p += u64(intrinsics.ptr_sub(q, base[d.p:]))
	return spell.pending_give(&d.pending, {0xEF, 0xBF, 0xBD, 0}, 3), true
}

// Whether a quoted cell's inner span is its text: it holds no `""` and its bytes are well-formed UTF-8. A cell holding
// `""` decodes to fewer bytes, and one under `lax` held an ill-formed sequence that decodes as U+FFFD. The byte scan
// moves eight bytes at a time while they are ASCII and hold no quote byte.
@(private)
plain_quoted :: proc "contextless" (src: []u8, n: core.Node) -> bool {
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
spelling_text :: proc(v: ^core.Token_View, n: core.Node, buf: []u8) -> (s: string, ok: bool) {
	return cell_text(v.src, n, Spec(v.spec), buf)
}

// The text of cell `n` of `src`, a text of spec `spec`, as `spelling_text` gives it.
@(private)
cell_text :: proc(src: []u8, n: core.Node, spec: Spec, buf: []u8) -> (s: string, ok: bool) {
	if spec == .Csv && n.spelling & core.SPELLING_QUOTED != 0 && plain_quoted(src, n) {
		lo, hi := inner_span(src, n)
		return string(src[lo:hi]), true
	}
	if n.spelling & core.SPELLING_DECODE == 0 {
		return string(src[n.lo:n.lo + u64(n.n)]), true
	}
	// A cell carries `SPELLING_DECODE` when its span must be decoded. That is a quoted CSV cell holding `""`, a TSV
	// cell with a backslash, which the pass's block mask answers, and any cell under `lax`, where a tolerated ill-formed
	// sequence reads as U+FFFD.
	return spell.decode_text(buf, dsv_decoded_init(src, n, spec), dsv_decoded_next)
}

// dsv's `Spelling.key_equals`. It returns whether cell `i` decodes to `name`, with no allocation. A cell that needs no
// decode is compared by its span, or by its inner span for a quoted cell without `""`, and one that needs it byte by
// byte as it decodes.
@(private)
spelling_key_equals :: proc "contextless" (doc: ^core.Token_View, n: core.Node, name: string) -> bool {
	spec := Spec(doc.spec)
	if spec == .Csv && n.spelling & core.SPELLING_QUOTED != 0 && plain_quoted(doc.src, n) {
		lo, hi := inner_span(doc.src, n)
		return spell.bytes_equal(doc.src[lo:hi], transmute([]u8)name)
	}
	if n.spelling & core.SPELLING_DECODE == 0 {
		return spell.bytes_equal(doc.src[n.lo:n.lo + u64(n.n)], transmute([]u8)name)
	}
	return spell.decoded_equals(dsv_decoded_init(doc.src, n, spec), dsv_decoded_next, name)
}




// dsv's `Spelling.number`. It returns the JSON number a value cell spells, else `Wide`. A quoted cell, a TSV escape and
// a key cell all return `Wide`, since no JSON number holds a quote, a backslash or a byte past 0x7F. A header cell names
// a column and answers as a JSON key node does.
@(private)
spelling_number :: proc(doc: ^core.Token_View, n: core.Node) -> core.Number {
	if n.role != .Value {
		return {0, .Wide}
	}
	s := doc.src[n.lo:n.lo + u64(n.n)]
	if num, is_number := spell.number_json(s, 0, u64(len(s))); is_number {
		return num
	}
	return {0, .Wide}
}

// dsv's `Spelling.resolve`. It returns `.String` by default. With the document's `infer`, an empty value cell is `.Null`, a `true`
// or `false` value cell is `.True` or `.False`, and a value cell that is exactly a JSON number is `.Number`. A quoted
// cell and a TSV escape are `.String`, since no number, `true` or `false` holds a quote or a backslash.
@(private)
spelling_resolve :: proc(doc: ^core.Document, i: core.Node_Index) -> core.Kind {
	n := doc.nodes[i]
	if n.kind != .Plain {
		return n.kind
	}
	// A key cell is text, as a JSON key node is, since a header cell names a column whatever it spells.
	if n.role != .Value {
		return .String
	}
	if !options_of(doc.as).infer {
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
edit_record :: proc(doc: ^core.Token_View, src: []u8, _: runtime.Allocator, $S: Spec) -> (cells: int, err: core.Document_Error) {
	h: Text_Shape
	regs: core.Hook_Regs
	layout := options_of(doc.as)
	_, fault := walk(src, 0, S, {no_header = true, delimiter = layout.delimiter, comment = layout.comment}, &h, &regs, shape_hook)
	if f, bad := fault.?; bad {
		return 0, {kind = .Bad_Value, inner = f}
	}
	if h.arrays != 2 || h.cells < 1 || h.record_lo != 0 || h.last_cell_end != u64(len(src)) {
		return 0, {kind = .Bad_Value}
	}
	return h.cells, {}
}

// Returns the cell count every record of a delimited text has: its header's, its first record's, or 0 for an empty text.
@(private)
dsv_width :: proc(doc: ^core.Document) -> int {
	if doc.shared_keys != 0 {
		return core.length(doc, doc.shared_keys)
	}
	it := core.children(doc, core.ROOT)
	if rec, ok := core.child_next(&it); ok {
		return core.length(doc, rec)
	}
	return 0
}

// The bytes a container's members lie in. The root's records start after its header row and run to the text's end, and
// a record's cells stop at its last cell, since its line end is the root's.
@(private)
edit_interior :: proc(doc: ^core.Document, c: core.Node_Index) -> (lo, hi: u64) {
	if c == core.ROOT {
		if doc.shared_keys != 0 {
			lo = close_end(doc, doc.shared_keys)
		}
		return lo, u64(len(doc.src))
	}
	lo = doc.nodes[c].lo
	if last, ok := core.child_at(doc, c, core.length(doc, c) - 1); ok {
		return lo, core.node_start(doc.nodes[last]) + u64(len(core.span(doc, last)))
	}
	return lo, close_end(doc, c)
}

// Whether the output holds a fact: a comment on a record, or on the root above its first record, and a foot on the root.
// A comment above a header reads on the root only when a record follows it, which resolves it there.
@(private)
edit_fact_slot :: proc(doc: ^core.Document, node: core.Node_Index, role: core.Role, emptied: bool) -> bool {
	if role == .Comment_Foot {
		return node == core.ROOT
	}
	if role != .Comment {
		return false
	}
	if node == core.ROOT {
		return doc.shared_keys != 0 && core.length(doc, core.ROOT) > 0 && !emptied
	}
	n := doc.nodes[node]
	return n.role == .Value && (n.kind == .Array || n.kind == .Map)
}

// Whether the list removes every record. A record is the only value container of a table, so one pass over the edits
// counts the removals. A root insert keeps a record, and a text with no record is no removal.
@(private)
edit_emptied :: proc(doc: ^core.Document, list: ^core.Edit_List) -> bool {
	removed := 0
	for e in list.edits {
		switch e.op {
		case .Insert:
			if e.node == core.ROOT {
				return false
			}
		case .Remove:
			if e.node == core.ROOT || int(e.node) >= len(doc.nodes) {
				continue
			}
			n := doc.nodes[e.node]
			if n.role == .Value && (n.kind == .Array || n.kind == .Map) {
				removed += 1
			}
		case .Set, .Set_Fact, .Remove_Fact:
		}
	}
	return removed > 0 && removed == core.length(doc, core.ROOT)
}

// Returns the single-byte string of the delimiter.
@(private)
edit_cell_sep :: proc(doc: ^core.Document) -> string {
	return string(doc.as.opts[:1])
}

// Checks that a cell's text is empty or exactly one cell under the document's grammar.
@(private)
edit_value_at :: proc(doc: ^core.Token_View, src: []u8, allocator: runtime.Allocator) -> core.Document_Error {
	if len(src) == 0 {
		return {}
	}
	cells, err := edit_record_at(doc, src, allocator)
	if err.kind != .None {
		return err
	}
	return {} if cells == 1 else {kind = .Bad_Value}
}

// Checks an insert's text: a record into the root, or a cell into a record. Its width is the commit's to judge.
@(private)
edit_insert_check :: proc(doc: ^core.Document, container: core.Node_Index, text: string, allocator: runtime.Allocator) -> core.Document_Error {
	if container == core.ROOT {
		_, e := edit_record_at(doc, transmute([]u8)text, allocator)
		return e
	}
	return edit_value_at(doc, transmute([]u8)text, allocator)
}

// Writes a decoded name as one cell of the document's spec. A CSV name that would not read back bare is quoted, and a
// TSV name's escapes are written. Plain has neither, and neither has a spelling for every name, so what is written may
// still be no cell, which the caller checks. Returns false when `text` cannot grow.
@(private)
edit_key_text :: proc(doc: ^core.Document, name: []u8, text: ^[dynamic]u8) -> bool {
	delimiter, comment := doc.as.opts[0], doc.as.opts[1]
	#partial switch Spec(doc.as.spec) {
	case .Csv:
		quoted := len(name) > 0 && name[0] == comment
		for b in name {
			quoted = quoted || b == delimiter || b == '"' || b == '\r' || b == '\n'
		}
		if quoted {
			compose.push(text, '"') or_return
		}
		for b in name {
			if b == '"' {
				compose.push(text, '"') or_return
			}
			compose.push(text, b) or_return
		}
		if quoted {
			compose.push(text, '"') or_return
		}
	case .Tsv:
		for b in name {
			if escape := escape_letter(b); escape != 0 {
				compose.push(text, '\\') or_return
				compose.push(text, escape) or_return
			} else {
				compose.push(text, b) or_return
			}
		}
	case:
		compose.push_all(text, name) or_return
	}
	return true
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
	if doc.shared_keys != 0 {
		if e := record_line_end(doc, doc.shared_keys); e != "" {
			return e
		}
	}
	return "\n"
}

@(private)
edit_record_at :: proc(doc: ^core.Token_View, src: []u8, allocator: runtime.Allocator) -> (cells: int, err: core.Document_Error) {
	switch Spec(doc.spec) {
	case .Csv:   return edit_record(doc, src, allocator, .Csv)
	case .Tsv:   return edit_record(doc, src, allocator, .Tsv)
	case .Plain: return edit_record(doc, src, allocator, .Plain)
	}
	return 0, {kind = .Bad_Value}
}

// A delimited text's comment spelling. It is `.Byte` with the document's comment byte, or `.None` when the byte is 0.
@(private)
edit_comment :: proc(doc: ^core.Document, _: u8) -> (core.Comment_Spelling, u8) {
	comment := doc.as.opts[1]
	return (.Byte if comment != 0 else .None), comment
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

// The byte just past container `i`'s close. The root uses `root_close`, or `len(doc.src)` when the build did not
// record it, a record ends at its line end.
@(private, cold)
close_end :: proc(doc: ^core.Document, i: core.Node_Index) -> u64 {
	if i == core.ROOT {
		if doc.root_close != 0 {
			return doc.root_close
		}
		return u64(len(doc.src))
	}
	if doc.partial {
		return record_end_by_walk(doc, i)
	}
	return record_end(doc, i)
}

// What a walk from a record's first byte finds: the end of the first record's line.
@(private)
Record_End :: struct {
	end: u64,
}

@(private)
record_end_hook :: proc "contextless" (h: ^Record_End, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if t.kind != .End {
		return s, .Next
	}
	h.end = t.lo + u64(t.n)
	return s, .Stop
}

// Returns the byte past record `i`'s line end by walking the record, since a partial document may not hold its last cell.
// The walk tolerates every fault, since the read may have tolerated any and a judged text's record bounds stay. A
// stopped read may leave text no walk judged, where this returns the fault's byte.
@(private, cold)
record_end_by_walk :: proc(doc: ^core.Document, i: core.Node_Index) -> u64 {
	h: Record_End
	regs: core.Hook_Regs
	lo := doc.nodes[i].lo
	fault: Maybe(core.Fault)
	opts := Options{no_header = true, delimiter = doc.as.opts[0], comment = doc.as.opts[1], tolerate = {.Invalid_Utf8, .Ragged, .Bare_Quote}}
	switch Spec(doc.as.spec) {
	case .Csv:   _, fault = walk(doc.src, lo, .Csv, opts, &h, &regs, record_end_hook)
	case .Tsv:   _, fault = walk(doc.src, lo, .Tsv, opts, &h, &regs, record_end_hook)
	case .Plain: _, fault = walk(doc.src, lo, .Plain, opts, &h, &regs, record_end_hook)
	}
	if f, bad := fault.?; bad {
		return f.at
	}
	return h.end
}
