// `build` is used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
#+private
package dsv

import "base:intrinsics"
import "base:runtime"
import spell "../core/spell"
import core "../core"
import compose "../core/compose"
import kernel "../core/kernel"
import build "../core/build"
import typed "../core/typed"

// dsv's document, built from the walk's tokens over the caller's bytes. A headed text is an `Array` of `Object` records
// whose first child is the header row, an `Array` of role `Key` whose cells name every record's columns. A text without
// a header is an `Array` of `Array`s. A cell is `Plain` until a reader asks `core.kind`, and a headed record's shared keys
// sit in the table's header.

// dsv's handles, one per spec, which only `as` names. A handle's readers are the readers a constant build of its spec
// holds, and its services the passes of that spec, so a call through a handle never switches on the spec. The tables
// hold pointers to the bound tables, so they are set at startup and never written after.
HANDLES := [Spec]core.Readers {
	.Csv   = handle_readers(.Csv, &SERVICES[.Csv]),
	.Tsv   = handle_readers(.Tsv, &SERVICES[.Tsv]),
	.Plain = handle_readers(.Plain, &SERVICES[.Plain]),
}

SERVICES := [Spec]core.Services {
	.Csv   = handle_services(.Csv),
	.Tsv   = handle_services(.Tsv),
	.Plain = handle_services(.Plain),
}

// The readers of the handle of spec `S`: `readers_of(S)` with the services of `S`.
handle_readers :: proc "contextless" ($S: Spec, services: ^core.Services) -> core.Readers {
	r := readers_of(S)^
	r.services = services
	return r
}

// The run-time services of spec `S`, which a handle reaches.
handle_services :: proc "contextless" ($S: Spec) -> core.Services {
	return {
		build    = proc(src: []u8, as: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
			return build_spec(src, S, as.readers, options_of(as), refuse_duplicates, allocator)
		},
		validate = proc "contextless" (src: []u8, as: core.As) -> Maybe(core.Fault) {return validate_spec(src, S, options_of(as))},
		scan     = proc(src: []u8, as: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (core.Document, core.Path_Error) {
			return scan_spec(src, S, as, paths, read, state, on, allocator)
		},
		write    = document_write,
		edit     = edit_of(S),
		plans    = rawptr(proc(T: typeid, as: core.As, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {
			return plan_built(T, S, options_of(as), opts, checks_of(S), allocator)
		}),
		reads    = checks_of(S),
		tokens   = &TOKENS,
		records  = framing_of(S),
		docs     = record_docs(S),
	}
}

// dsv's fault table, which names the format whatever the spec.
rules_of :: proc "contextless" () -> ^core.Rules {
	return &RULES
}

// `Token.spelling`'s bit for a quoted CSV cell holding a `""`, set only on a walk for `Cells` or `Batch`. Bits 0 to 14
// belong to a number node's kind and digit counts, so a cell that becomes a number node never carries it.
SPELLING_DOUBLED :: u16(1 << 15)

// `Token.spelling`'s bit for the key of a column past the header's last cell, which `column_key` makes. Its text is
// `n`, the column's 1-based position, in decimal. A key is never a number node, so it shares `core.NUMBER_EXP`'s bit.
SPELLING_COLUMN :: u16(1 << 14)

#assert(SPELLING_DOUBLED & (core.SPELLING_DECODE | core.SPELLING_QUOTED | core.SPELLING_LAX | core.NUMBER_KIND_MASK) == 0)

build_spec :: proc(src: []u8, $S: Spec, readers: ^core.Readers, opts: Options, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
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
	doc, err := build_reserved(src, S, readers, opts, refuse_duplicates, allocator, max(len(src) / 2, count + 2), 0, start, keys)
	if err.kind == .No_Memory {
		// The allocator refused the estimate or a growth. Reading the text again sizes every buffer exactly, so only a
		// document that does not fit the allocator fails. The hook tests capacity before a close, which writes no node,
		// so the buffer holds one node more than the text has, and `builder_end` returns it.
		need: build.Count
		regs: core.Hook_Regs
		walk_keys(src, 0, S, opts, &need, &regs, build.builder_hook_count_keyless, keys)
		doc, err = build_reserved(src, S, readers, opts, refuse_duplicates, allocator, need.nodes + count + 2, need.facts, start, keys)
	}
	opts := opts
	if err.kind == .None {
		// A write ends its lines as the text's first row ends, header or record, read before a widened header has keys
		// with no bytes. A line end inside a quoted cell is the cell's text.
		opts.crlf = len(doc.nodes) > 1 && line_end_before(src, record_end(&doc, 1)) == "\r\n"
		doc.as = as_of(readers, S, opts)
	}
	wide := count
	if .Ragged in opts.tolerate && count > 0 && err.kind == .None {
		it := core.children(&doc, core.ROOT)
		for rec in core.child_next(&it) {
			wide = max(wide, core.length(&doc, rec))
		}
	}
	if wide == count {
		return doc, err
	}
	// A record wider than the header names its extra columns by position, so the header row is read again with their
	// keys after its own, and the first read sized every buffer.
	wider, kerr := make([]core.Token, wide, allocator)
	if kerr != nil {
		core.destroy(&doc)
		return {}, {kind = .No_Memory}
	}
	defer delete(wider, allocator)
	copy(wider, keys)
	for c in count ..< wide {
		wider[c] = column_key(keys, c)
	}
	nodes, facts := len(doc.nodes) + wide - count + 1, len(doc.facts)
	core.destroy(&doc)
	return build_reserved(src, S, readers, opts, refuse_duplicates, allocator, nodes, facts, start, wider)
}

// Reads `src` into a builder with room for `nodes` nodes and `facts` facts, which the hooks grow past. `keys` holds a
// token per header cell, and `start` is the header's first byte.
build_reserved :: proc(src: []u8, $S: Spec, readers: ^core.Readers, opts: Options, refuse_duplicates: bool, allocator: runtime.Allocator, nodes, facts, start: int, keys: []core.Token) -> (core.Document, core.Document_Error) {
	// A record is a container inside the document's array, so a dsv text nests at most two containers and 8 stack slots
	// cover it.
	// The document holds the options it was read with, so every edit service judges a recorded text and writes its
	// separators the way this text reads.
	// The table is the first allocation, so a refused growth of the buffers above it still returns its tail to an arena.
	tables, terr := make([]core.Table, 1, allocator)
	if terr != nil {
		return {}, {kind = .No_Memory}
	}
	b := build.builder_start(src, as_of(readers, S, opts), refuse_duplicates, allocator, nodes, 8, facts)
	core.set_tables(&b.doc, tables)
	if len(b.doc.nodes) == 0 {
		// The reservation was refused and the node array is nil, so no hook may run.
		return build.builder_end(&b, build.BUILDER_REGS, nil)
	}
	regs := build.BUILDER_REGS
	// The header row is written before the walk, so the root's token steps over it and the walk's `Key` tokens name its
	// cells. A text with no row leaves the root's next node zeroed for the hook's test. The row is the table's header before
	// the walk, since `builder_end` recounts the members of a wide record through the readers, which read it.
	count := len(keys)
	if count > 0 {
		b.doc.nodes[1] = core.Node{lo = u64(start), kind = .Array, role = .Key}
		tables[0].header = 1
		build.builder_close_node(&b, count + 2, 1, u32(count))
	} else {
		b.doc.nodes[1] = {}
	}
	fault: Maybe(core.Fault)
	if opts.infer {
		if opts.comment != 0 {
			b.root_close, fault = walk_keys(src, 0, S, opts, &b, &regs, keyless_facts_infer, keys)
		} else {
			b.root_close, fault = walk_keys(src, 0, S, opts, &b, &regs, keyless_infer, keys)
		}
	} else if opts.comment != 0 {
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
	if err.kind == .None {
		doc.kinds_stored = true
		finish_table(&doc, opts)
	}
	return doc, err
}

// The builder's keyless hooks for a build with `infer`: a cell is stored as the kind `spelling_resolve` reads it as.
@(private)
keyless_infer :: #force_inline proc "contextless" (h: ^build.Builder, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return build.builder_hook_keyless(h, s, infer_token(h.doc.src, t))
}

@(private)
keyless_facts_infer :: #force_inline proc "contextless" (h: ^build.Builder, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return build.builder_hook_keyless_facts(h, s, infer_token(h.doc.src, t))
}

// An unquoted, undecoded value cell as `infer` reads it: `true` and `false` are those kinds, and an RFC 8259 number is
// `.Number` with its digit counts as JSON's walk spells them. The first byte picks the work, so a text cell costs one
// load. Any other cell stays `.Plain`, which an empty cell, a quoted one and a TSV escape always are.
@(private)
infer_token :: #force_inline proc "contextless" (src: []u8, t: core.Token) -> core.Token {
	t := t
	if t.kind != .Plain || t.role != .Value || t.n == 0 || t.spelling != 0 {
		return t
	}
	hi := t.lo + u64(t.n)
	switch src[t.lo] {
	case 't':
		if string(src[t.lo:hi]) == "true" {
			t.kind = .True
		}
	case 'f':
		if string(src[t.lo:hi]) == "false" {
			t.kind = .False
		}
	case '-', '0' ..= '9':
		if int_digits, frac_digits, has_exp, ok := spell.number_shape_strict(src, t.lo, hi); ok {
			t.kind = .Number
			t.spelling = core.number_spelling(0, int_digits, frac_digits) | (core.NUMBER_EXP if has_exp else 0)
		}
	}
	return t
}

// Writes the table's first row and width, which the walk's nodes decide. A text read with `Ragged` has no common width,
// and a text with no record has no row to measure.
finish_table :: proc(doc: ^core.Document, opts: Options) {
	t := &doc.tables_at[0]
	header := core.header_of(doc)
	t.first_row = core.Node_Index(len(doc.nodes))
	if header != 0 {
		t.first_row = header + core.Node_Index(doc.nodes[header].n)
	} else if len(doc.nodes) > 1 {
		t.first_row = 1
	}
	if .Ragged in opts.tolerate || int(t.first_row) >= len(doc.nodes) {
		return
	}
	t.width = u32(core.length(doc, header)) if header != 0 else doc.nodes[t.first_row].n - 1
}

// Returns quoted CSV cell `n`'s span without its quote pair. The walk gives a quoted cell only once it closes it.
inner_span :: #force_inline proc "contextless" (n: core.Node) -> (lo, hi: u64) {
	return n.lo + 1, n.lo + u64(n.n) - 1
}

// Decodes one cell. A CSV cell's inner bytes have each `""` read as `"`, or a TSV cell's bytes have each accepted
// escape read as the byte it spells. A byte past 0x7F reads as one UTF-8 character, or U+FFFD over its maximal subpart
// when it is ill-formed. `pending` holds the rest of a character read in parts. The walk accepted the cell, so a TSV
// backslash has its letter.
Dsv_Decoded :: struct {
	src:     []u8,
	p, end:  u64,
	tsv:     bool,
	quoted:  bool,
	pending: spell.Pending,
}

dsv_decoded_init :: proc "contextless" (src: []u8, n: core.Node, spec: Spec) -> Dsv_Decoded {
	if spec == .Csv {
		if n.spelling & core.SPELLING_QUOTED != 0 {
			lo, hi := inner_span(n)
			return {src = src, p = lo, end = hi, quoted = true}
		}
		return {src = src, p = n.lo, end = n.lo + u64(n.n)}
	}
	return {src = src, p = n.lo, end = n.lo + u64(n.n), tsv = spec == .Tsv}
}

dsv_decoded_next :: proc "contextless" (d: ^Dsv_Decoded) -> (b: u8, ok: bool) {
	if b, ok = spell.pending_next(&d.pending); ok {
		return
	}
	if d.p >= d.end {
		return 0, false
	}
	c := d.src[d.p]
	if d.tsv && c == '\\' {
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
	spelled, n, q := spell.utf8_lax_char(base[d.p:], base[d.end:])
	d.p = u64(intrinsics.ptr_sub(q, base))
	return spell.pending_give(&d.pending, spelled, n), true
}

// Whether a quoted cell's inner span is its text: it holds no `""` and no ill-formed sequence. A cell holding `""`
// decodes to fewer bytes, and one marked `SPELLING_LAX` holds an ill-formed sequence that decodes as U+FFFD. The walk
// accepted the cell, so a quote in its inner span is the first of a `""` pair.
plain_quoted :: proc "contextless" (src: []u8, n: core.Node) -> bool {
	lo, hi := inner_span(n)
	return n.spelling & core.SPELLING_LAX == 0 && kernel.index_byte(src[lo:hi], '"') < 0
}

// The bytes of cell `n` of `src` that are its text, for a cell that needs no decode: a quoted CSV cell without `""` and
// with well-formed UTF-8 is its inner span, and another cell its span. False for a cell that must be decoded.
written_text :: #force_inline proc "contextless" (src: []u8, n: core.Node, spec: Spec) -> (text: []u8, ok: bool) {
	if spec == .Csv && n.spelling & core.SPELLING_QUOTED != 0 && plain_quoted(src, n) {
		lo, hi := inner_span(n)
		return src[lo:hi], true
	}
	if n.spelling & core.SPELLING_DECODE == 0 {
		return src[n.lo:n.lo + u64(n.n)], true
	}
	return nil, false
}

// The text of cell `n` of `src`, a text of spec `spec`, and dsv's `Readers.text`. It returns a cell that needs no
// decode as a slice of the source. It decodes a quoted cell holding `""`, a TSV escape and a `lax` cell into `buf`, and returns
// false when `buf` is too short.
cell_text :: proc(src: []u8, n: core.Node, spec: Spec, buf: []u8) -> (s: string, ok: bool) {
	if text, written := written_text(src, n, spec); written {
		return string(text), true
	}
	if n.spelling & SPELLING_COLUMN != 0 {
		text: [spell.INT_ROOM]u8
		name := text[:spell.u64_text(&text[0], u64(n.n))]
		return string(buf[:copy(buf, name)]), len(buf) >= len(name)
	}
	// A cell carries `SPELLING_DECODE` when its span must be decoded. That is a quoted CSV cell holding `""`, a TSV
	// cell with a backslash, which the pass's block mask answers, and a cell holding an ill-formed sequence
	// `.Invalid_Utf8` tolerated, which reads as U+FFFD.
	return spell.decode_text(buf, dsv_decoded_init(src, n, spec), dsv_decoded_next)
}

// dsv's `Readers.key_equals`. It returns whether cell `i` decodes to `name`, with no allocation. A cell that needs no
// decode is compared by its span, or by its inner span for a quoted cell without `""`, and one that needs it byte by
// byte as it decodes.
spelling_key_equals :: proc "contextless" (doc: ^core.Token_View, n: core.Node, name: string) -> bool {
	spec := Spec(doc.spec)
	if text, written := written_text(doc.src, n, spec); written {
		return spell.bytes_equal(text, transmute([]u8)name)
	}
	if n.spelling & SPELLING_COLUMN != 0 {
		text: [spell.INT_ROOM]u8
		return spell.bytes_equal(text[:spell.u64_text(&text[0], u64(n.n))], transmute([]u8)name)
	}
	return spell.decoded_equals(dsv_decoded_init(doc.src, n, spec), dsv_decoded_next, name)
}



// dsv's `Readers.number`. It returns the JSON number a value cell spells, and false for any other cell. A quoted cell,
// a TSV escape and a key cell are never numbers, since no JSON number holds a quote, a backslash or a byte past 0x7F. A
// header cell names a column and answers as a JSON key node does.
spelling_number :: proc(doc: ^core.Token_View, n: core.Node) -> (core.Number, bool) {
	if n.role != .Value {
		return {}, false
	}
	return spell.number_strict(doc.src, n.lo, n.lo + u64(n.n))
}

// dsv's `Readers.resolve` of a cell. An empty value cell, which holds no quotes, is `.Null`, as a typed read and the
// CLI read it, and any other cell is `.String`. With the document's `infer`, a `true` or `false` value cell is `.True`
// or `.False`, and a value cell that is exactly a JSON number is `.Number`. A quoted cell and a TSV escape are
// `.String`, since no number, `true` or `false` holds a quote or a backslash.
spelling_resolve :: proc(doc: ^core.Document, i: core.Node_Index) -> core.Kind {
	n := doc.nodes[i]
	// A key cell is text, as a JSON key node is, since a header cell names a column whatever it spells.
	if n.role != .Value {
		return .String
	}
	if n.n == 0 {
		return .Null
	}
	if !options_of(doc.as).infer {
		return .String
	}
	lo, hi := n.lo, n.lo + u64(n.n)
	switch string(doc.src[lo:hi]) {
	case "true":
		return .True
	case "false":
		return .False
	}
	if _, is_number := spell.number_strict(doc.src, lo, hi); is_number {
		return .Number
	}
	return .String
}

// Checks that an edit's text is a record of at least one cell, with its record at the text's start and its last cell
// ending at the text's end, so the text writes no line end of its own. A recorded text that holds the delimiter outside
// quotes reads as two cells and is refused, and so is one that starts a line with the comment byte, which the walk reads
// as no record. A byte order mark the text starts with is a cell byte, as it is past the text's first byte, and the
// commit refuses an output that it starts. A CSV or TSV cell holding the delimiter must be quoted or escaped by the
// caller. Plain has no quote, so its cells cannot hold the delimiter at all. Returns the cell count.
edit_record :: proc(doc: ^core.Token_View, src: []u8, $S: Spec) -> (cells: int, err: core.Document_Error) {
	layout := options_of(doc.as)
	opts := Options{no_header = true, delimiter = layout.delimiter, comment = layout.comment}
	if f, bad := validate_spec(src, S, opts).?; bad {
		return 0, {kind = .Bad_Value, inner = f}
	}
	s := scan_record(src, 0, 0, S, spec_delimiter(S, opts.delimiter))
	if len(src) == 0 || record_start(src, 0, opts.comment) != 0 || s.line_end != len(src) {
		return 0, {kind = .Bad_Value}
	}
	return s.cells, {}
}

// Returns the cell count every record of a delimited text has: its header's, its first record's, or 0 for an empty text.
dsv_width :: proc(doc: ^core.Document) -> int {
	if keys := core.header_of(doc); keys != 0 {
		return core.length(doc, keys)
	}
	it := core.children(doc, core.ROOT)
	if rec, ok := core.child_next(&it); ok {
		return core.length(doc, rec)
	}
	return 0
}

// The cells of the header's line, the start of the table's header, which goes on with a key for each column a wider
// record names by its position.
header_keys :: proc(doc: ^core.Document) -> []core.Node {
	header := core.header_of(doc)
	keys := doc.nodes[int(header) + 1:][:core.length(doc, header)]
	n := len(keys)
	for n > 0 && keys[n - 1].spelling & SPELLING_COLUMN != 0 {
		n -= 1
	}
	return keys[:n]
}

// The bytes a container's members lie in. The root's records start after its header row and run to the text's end, and
// a record's cells stop at its last cell, since its line end is the root's.
edit_interior :: proc(doc: ^core.Document, c: core.Node_Index) -> (lo, hi: u64) {
	if c == core.ROOT {
		if keys := core.header_of(doc); keys != 0 {
			lo = doc.readers.close_end(doc, keys)
		}
		return lo, u64(len(doc.src))
	}
	lo = doc.nodes[c].lo
	if last, ok := core.child_at(doc, c, core.length(doc, c) - 1); ok {
		return lo, core.node_start(doc.nodes[last]) + u64(len(core.span(doc, last)))
	}
	return lo, doc.readers.close_end(doc, c)
}

// Whether the output holds a fact: a comment on a record, or on the root above its first record, and a foot on the root.
// A comment above a header reads on the root only when a record follows it, which resolves it there.
edit_fact_slot :: proc(doc: ^core.Document, node: core.Node_Index, role: core.Role, emptied: bool) -> bool {
	if role == .Comment_Foot {
		return node == core.ROOT
	}
	if role != .Comment {
		return false
	}
	if node == core.ROOT {
		return core.header_of(doc) != 0 && core.length(doc, core.ROOT) > 0 && !emptied
	}
	n := doc.nodes[node]
	return n.role == .Value && (n.kind == .Array || n.kind == .Object)
}

// Whether the list removes every record. A record is the only value container of a table, so one pass over the edits
// counts the removals. A root insert keeps a record, and a text with no record is no removal.
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
			if n.role == .Value && (n.kind == .Array || n.kind == .Object) {
				removed += 1
			}
		case .Set, .Set_Fact, .Remove_Fact, .Reorder:
		}
	}
	return removed > 0 && removed == core.length(doc, core.ROOT)
}

// Checks a cell's text, empty or exactly one cell under the document's grammar, or with `record` a record inserted into
// the root, whose width is the commit's to judge.
edit_cells :: proc(doc: ^core.Token_View, src: []u8, record: bool, record_at: Record_Check) -> core.Document_Error {
	if len(src) == 0 && !record {
		return {}
	}
	cells, err := record_at(doc, src)
	return err if err.kind != .None || record || cells == 1 else {kind = .Bad_Value}
}

// Writes a decoded name as one cell of the document's spec. A CSV name that would not read back bare is quoted, as is
// one a byte order mark starts, which would read as the text's mark at its start, and a TSV name's escapes are written. Plain has neither, and neither has a spelling for every name, so what is written may
// still be no cell, which the caller checks. Returns false when `text` cannot grow.
edit_key_text :: proc(doc: ^core.Document, name: []u8, text: ^[dynamic]u8) -> bool {
	delimiter, comment := doc.as.opts[0], doc.as.opts[1]
	#partial switch Spec(doc.as.spec) {
	case .Csv:
		quoted := len(name) > 0 && name[0] == comment || core.text_start(name, 0) != 0
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

// Returns the line end that ends just before byte `p` of `src`, or an empty string when none does.
line_end_before :: proc(src: []u8, p: u64) -> string {
	if p == 0 || src[p-1] != '\n' {
		return ""
	}
	return "\r\n" if p >= 2 && src[p-2] == '\r' else "\n"
}

// The line end a record insert writes. It is the first line end a record has, else its header's, else LF.
edit_record_sep :: proc(doc: ^core.Document) -> string {
	it := core.children(doc, core.ROOT)
	for rec in core.child_next(&it) {
		if e := line_end_before(doc.src, record_end(doc, rec)); e != "" {
			return e
		}
	}
	if keys := core.header_of(doc); keys != 0 {
		if e := line_end_before(doc.src, record_end(doc, keys)); e != "" {
			return e
		}
	}
	return "\n"
}

Record_Check :: #type proc(doc: ^core.Token_View, src: []u8) -> (cells: int, err: core.Document_Error)

// The byte just past record `i`'s line end, CR LF included. A record at the text's end stops past its last cell. A
// header row `.Ragged` widened stops past its last named cell, since a key named by position has no bytes. The root
// ends at `len(doc.src)`. Only a container span read calls it.
@(cold)
record_end :: proc(doc: ^core.Document, i: core.Node_Index) -> u64 {
	n := doc.nodes[i]
	p := n.lo
	if n.n > 1 {
		at := int(i) + int(n.n) - 1
		for doc.nodes[at].spelling & SPELLING_COLUMN != 0 {
			at -= 1
		}
		p = doc.nodes[at].lo + u64(doc.nodes[at].n)
	}
	if p < u64(len(doc.src)) && doc.src[p] == '\r' {
		p += 1
	}
	if p < u64(len(doc.src)) && doc.src[p] == '\n' {
		p += 1
	}
	return p
}

// The byte just past container `i`'s close in a document of spec `S`. The root uses `root_close`, or `len(doc.src)`
// when the build did not record it, a record ends at its line end.
@(cold)
close_end_spec :: proc(doc: ^core.Document, i: core.Node_Index, $S: Spec) -> u64 {
	if i == core.ROOT {
		if doc.root_close != 0 {
			return doc.root_close
		}
		return u64(len(doc.src))
	}
	if doc.partial {
		return record_end_by_walk(doc, i, S)
	}
	return record_end(doc, i)
}

// What a walk from a record's first byte finds: the end of the first record's line.
Record_End :: struct {
	end: u64,
}

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
@(cold)
record_end_by_walk :: proc(doc: ^core.Document, i: core.Node_Index, $S: Spec) -> u64 {
	h: Record_End
	regs: core.Hook_Regs
	lo := doc.nodes[i].lo
	fault: Maybe(core.Fault)
	opts := Options{no_header = true, delimiter = doc.as.opts[0], comment = doc.as.opts[1], tolerate = {.Invalid_Utf8, .Ragged, .Bare_Quote}}
	_, fault = walk(doc.src, lo, S, opts, &h, &regs, record_end_hook)
	if f, bad := fault.?; bad {
		return f.at
	}
	return h.end
}
