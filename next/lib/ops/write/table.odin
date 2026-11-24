package write

import "base:runtime"
import "core:bytes"
import "core:simd"
import "core:slice"
import "core:strings"
import "stury:lib/base/kernel"
import "stury:lib/core/tape"

// The writer of a delimited text, a record a line, whose format gives the rules of its cells: how a cell that holds
// the delimiter, a quote or a line end is spelled, or that it cannot be. A document writes as a table when its value
// is a table a delimited read built, an array whose elements are all objects, under the union of their keys in the
// order they come, or all arrays, or all scalars, a cell a record, with no header, an object as one record, or a scalar
// as one cell.

// How a delimited spec spells a cell's text.
Cells :: enum u8 {
	// CSV: a cell is quoted where it must be, and a quote in it doubled.
	Quoted,
	// TSV: a tab, a line end, a backslash and NUL are escaped by a backslash, and no other delimiter can be held.
	Escaped,
	// Plain: no quote and no escape, so a cell cannot hold the delimiter or a line end.
	Bare,
}

// Writes value `opts.node` of `doc` as a delimited text whose cells `cells` spells and whose options are `d`, its
// delimiter resolved, for target `target`. Comments on the table and its records are written as comment lines under a
// comment byte. Returns the fact kinds dropped.
table :: proc(out: ^Out, doc: ^tape.Document, target: ^tape.Format, cells: Cells, d: tape.Dsv_Options, verbatim: bool, opts: Options, allocator: runtime.Allocator) -> (dropped: tape.Facts, err: Error) {
	holds := target.facts if d.comment != 0 else {}
	w: Tree
	tree_start(&w, doc, opts, holds, allocator) or_return
	t := Table_Write{w = &w, out = out, cells = cells, d = d, native = doc.format.options == .Dsv, whole = .Held not_in doc.flags}
	t.verbatim = verbatim && t.native && t.whole
	t.translate = !t.verbatim && t.native && t.whole && !d.infer
	// The bytes a cell's spec must quote, escape or refuse, and the first bytes that may make a cell read as another
	// value, which `put_cell` judges on its slow path.
	t.special[d.delimiter], t.special['\n'], t.special['\r'] = true, true, true
	switch cells {
	case .Quoted:
		t.special['"'] = true
	case .Escaped:
		t.special['\t'], t.special['\\'], t.special[0] = true, true, true
	case .Bare:
	}
	n := 0
	for c in 0 ..< 256 {
		if t.special[c] {
			t.probe[n] = Block16(u8(c))
			n += 1
		}
	}
	for k in n ..< SPECIAL_MAX {
		t.probe[k] = t.probe[0]
	}
	if d.comment != 0 {
		t.lead[d.comment] = true
	}
	t.lead[0xEF] = true
	if d.infer {
		for c in "tf-0123456789" {
			t.lead[c] = true
		}
	}
	index := tape.Doc_Index{allocator = allocator}
	w.reader.index = &index
	table_rows(&t, opts.sort_keys)
	tape.destroy(&index)
	delete(t.keys_at)
	delete(t.order, allocator)
	dropped = tree_end(&w)
	if w.err == nil {
		w.err = out.err
	}
	return dropped, w.err
}

@(private)
Table_Write :: struct {
	w:       ^Tree,
	out:     ^Out,
	d:       tape.Dsv_Options,
	cells:   Cells,
	native:  bool, // the document is delimited, so a number's bytes are its text
	whole:   bool, // the document holds its text whole, so an unescaped cell's text is its span
	started: bool, // a line is written, so no cell starts the text
	// While the header is written, its width. Its keys read as keys, never null and never typed.
	keys:    int,
	// The document is a text of the target spec read under the target's options, so a cell it read unquoted and
	// unescaped reads back as itself, and only a string that may read as another value needs a look.
	verbatim: bool,
	// The document is a delimited text read whole under other options, with no `infer`, so a run of its plain cells
	// is its source bytes with the delimiters replaced where they hold no byte the target must quote or escape.
	translate: bool,
	special: [256]bool, // the bytes a cell's spec must quote, escape or refuse
	lead:    [256]bool, // the first bytes that may make a cell read as another value
	// The bytes of `special`, each splatted across a block, the last repeated to fill the six.
	probe:   [SPECIAL_MAX]Block16,
	keys_at: [dynamic]tape.Node_Index, // the key of each column of the header
	// Under `sort_keys`, the columns in the order of their keys' texts, else nil for their own order.
	order:   []int,
}

// A block of 16 bytes.
@(private)
Block16 :: #simd[16]u8

// The most bytes a cell's spec must quote, escape or refuse: TSV's delimiter, line ends, tab, backslash and NUL.
@(private)
SPECIAL_MAX :: 6

// The keys a table's records are written under.
@(private)
Header :: struct {
	node:  tape.Node_Index, // a table's header array, the first object of an array of objects, `NO_NODE` for none
	width: int, // its keys, or the first array's cells
	delimited: bool, // a delimited table's header, whose keys are its elements and whose rows name cells by place
	scalars: bool, // the records are scalars, a cell each
}

// Writes the table at `w.i`: its comment lines, its header and its records, the columns by their names under
// `sort_keys`.
@(private)
table_rows :: proc(t: ^Table_Write, sort_keys: bool) {
	w := t.w
	doc := w.doc
	root := w.i
	node := doc.nodes[root]
	if node.kind > .Plain && node.spelling & tape.CONTAINER_PARTIAL != 0 {
		w.err = Refused{root, .Partial}
		return
	}
	// An object or a scalar is the one record of its table.
	single := node.kind != .Array
	header, objects, ok := table_header(t, root, single)
	if !ok {
		return
	}
	// Arrays of cells have no keys to name a header by. Records under keys write with no header line under
	// `no_header`, which reads them back as arrays of cells.
	if !objects && !header.scalars && !t.d.no_header && node.n > 1 {
		w.err = tape.Bad_Option{"no_header"}
		return
	}
	if header.node != tape.NO_NODE && !header_columns(t, &header, root, single, sort_keys) {
		return
	}
	lo := node_facts(w, root)
	root_facts := w.facts[lo:w.fact]
	put_comments(t, root_facts, .Comment, ~tape.Facts{.Comment, .Comment_Foot})
	if header.node != tape.NO_NODE && !t.d.no_header && !table_header_line(t, header) {
		return
	}
	first, end := root + 1, tape.node_after(doc, root)
	if single {
		first = root
	}
	for at := first; at < end; at = tape.node_after(doc, at) {
		if doc.nodes[at].kind > .Plain && doc.nodes[at].spelling & tape.CONTAINER_PARTIAL != 0 {
			w.err = Refused{at, .Partial}
			return
		}
		lo = node_facts(w, at)
		put_comments(t, w.facts[lo:w.fact], .Comment, ~tape.Facts{.Comment})
		if !table_record(t, at, header) {
			return
		}
	}
	put_comments(t, root_facts, .Comment_Foot, {})
}

// The header of the table at `root` and whether its records are objects, false with `w.err` set for an array that is
// no table.
@(private)
table_header :: proc(t: ^Table_Write, root: tape.Node_Index, single: bool) -> (h: Header, objects, ok: bool) {
	w := t.w
	doc := w.doc
	h.node = tape.NO_NODE
	if single {
		if doc.nodes[root].kind == .Object {
			return {node = root}, true, true
		}
		return {node = tape.NO_NODE, width = 1, scalars = true}, false, true
	}
	if doc.ext != nil {
		if ext, tabular := &doc.ext.format.(tape.Tabular_Ext); tabular {
			for tb in ext.tables {
				if tb.node == root {
					h.delimited = true
					if tb.header != 0 {
						h.node, h.width = tb.header, int(doc.nodes[tb.header].n) - 1
					}
					return h, tb.header != 0, true
				}
			}
		}
	}
	if doc.nodes[root].n == 1 {
		return h, !t.d.no_header, true
	}
	#partial switch doc.nodes[root + 1].kind {
	case .Object:
		return {node = root + 1}, true, true
	case .Array:
		return {node = tape.NO_NODE, width = tape.child_count(doc, root + 1, doc.nodes[root + 1])}, false, true
	}
	return {node = tape.NO_NODE, width = 1, scalars = true}, false, true
}

// Lists the key of each column of header `h`, for records that are objects the union of their keys in the order they
// come, and under `sort_keys` the columns in the order of their keys' texts. False with `w.err` set when memory is
// refused.
@(private)
header_columns :: proc(t: ^Table_Write, h: ^Header, root: tape.Node_Index, single, sort_keys: bool) -> bool {
	w := t.w
	err: runtime.Allocator_Error
	if h.delimited {
		if t.keys_at, err = make([dynamic]tape.Node_Index, h.width, w.allocator); err != nil {
			w.err = err
			return false
		}
		for j in 0 ..< h.width {
			t.keys_at[j] = h.node + 1 + tape.Node_Index(j)
		}
	} else if !key_union(t, h, root, single) {
		return false
	}
	if !sort_keys {
		return true
	}
	Named :: struct {
		name:   string,
		column: int,
	}
	named: []Named
	if named, err = make([]Named, h.width, w.allocator); err != nil {
		w.err = err
		return false
	}
	defer {
		for n in named {
			delete(n.name, w.allocator)
		}
		delete(named, w.allocator)
	}
	for &n, j in named {
		s, ok := text_of(w, t.keys_at[j])
		if !ok {
			return false
		}
		if n.name, err = strings.clone(s, w.allocator); err != nil {
			w.err = err
			return false
		}
		n.column = j
	}
	slice.stable_sort_by(named, proc(a, b: Named) -> bool {return a.name < b.name})
	if t.order, err = make([]int, h.width, w.allocator); err != nil {
		w.err = err
		return false
	}
	for n, k in named {
		t.order[k] = n.column
	}
	return true
}

// Lists in `keys_at` the first key of each text of the keys of the records of the table at `root`, `root` itself when
// `single`, in the order they come, and sets the width of `h` to their count.
@(private)
key_union :: proc(t: ^Table_Write, h: ^Header, root: tape.Node_Index, single: bool) -> bool {
	w := t.w
	doc := w.doc
	keys := make([dynamic]tape.Node_Index, w.allocator)
	// The text of each of `keys`. A record's keys are first compared with them in place, as records mostly share them
	// in one order, and only one that differs is looked for among them all.
	names := make([dynamic]string, w.allocator)
	defer {
		for name in names {
			delete(name, w.allocator)
		}
		delete(names)
	}
	first, end := root + 1, tape.node_after(doc, root)
	if single {
		first = root
	}
	err: runtime.Allocator_Error
	for at := first; err == nil && at < end; at = tape.node_after(doc, at) {
		record := doc.nodes[at]
		if record.kind != .Object {
			continue
		}
		record_end := at + tape.Node_Index(record.n)
		j := 0
		for k := at + 1; err == nil && k < record_end; k, j = tape.node_after(doc, k + 1), j + 1 {
			if doc.nodes[k].kind > .Plain {
				w.err = Refused{k, .No_Spelling}
				delete(keys)
				return false
			}
			if j < len(keys) && same_key(doc, k, keys[j]) {
				continue
			}
			s, ok := text_of(w, k)
			if !ok {
				delete(keys)
				return false
			}
			if j < len(names) && names[j] == s || slice.contains(names[:], s) {
				continue
			}
			name: string
			if name, err = strings.clone(s, w.allocator); err == nil {
				if _, err = append(&names, name); err == nil {
					_, err = append(&keys, k)
				} else {
					delete(name, w.allocator)
				}
			}
		}
	}
	if err != nil {
		w.err = err
		delete(keys)
		return false
	}
	t.keys_at, h.width = keys, len(keys)
	return true
}

// Whether keys `a` and `b` of `doc` are spelled with the same bytes and no escape, so they have one text.
@(private)
same_key :: #force_inline proc "contextless" (doc: ^tape.Document, a, b: tape.Node_Index) -> bool #no_bounds_check {
	x, y := doc.nodes[a], doc.nodes[b]
	return x.n == y.n && (x.spelling | y.spelling) & tape.SPELLING_DECODE == 0 && x.kind <= .Plain && y.kind <= .Plain && .Held not_in doc.flags && string(doc.src[x.lo:][:x.n]) == string(doc.src[y.lo:][:y.n])
}

// The column written `k`th.
@(private)
column :: #force_inline proc(t: ^Table_Write, k: int) -> int {
	return t.order[k] if t.order != nil else k
}

// The header's keys as a record, false with `w.err` set for one the spec cannot hold.
@(private)
table_header_line :: proc(t: ^Table_Write, h: Header) -> bool {
	w := t.w
	doc := w.doc
	if h.width == 0 {
		w.err = Refused{h.node, .No_Spelling}
		return false
	}
	t.keys = kept_cells(t, h, h.width)
	defer t.keys = 0
	written := 0
	for c in 0 ..< h.width {
		j := column(t, c)
		at := t.keys_at[j]
		if h.delimited && tape.column_dropped(doc, h.node, j, h.width) {
			continue
		}
		if written > 0 {
			put_byte(t.out, t.d.delimiter)
		}
		if doc.nodes[at].kind > .Plain {
			w.err = Refused{at, .No_Spelling}
			return false
		}
		s, ok := text_of(w, at)
		if !ok || !put_cell(t, at, s, written, false) {
			return false
		}
		written += 1
	}
	put_line_end(t)
	t.started = true
	return true
}

// The cells of a record of `cells` under header `h` that its table keeps: all but those of a repeated header name its
// `Duplicates` policy drops.
@(private)
kept_cells :: proc(t: ^Table_Write, h: Header, cells: int) -> (n: int) {
	if !h.delimited || h.node == tape.NO_NODE {
		return cells
	}
	for j in 0 ..< cells {
		n += int(!tape.column_dropped(t.w.doc, h.node, j, cells))
	}
	return
}

// Writes the record at `at` under header `h`, false with `w.err` set for one that is no record of the table.
@(private)
table_record :: proc(t: ^Table_Write, at: tape.Node_Index, h: Header) -> bool {
	w := t.w
	doc := w.doc
	node := doc.nodes[at]
	switch {
	case h.scalars && node.kind <= .Plain:
		// A null cell alone on its line would read back as no record.
		if node.kind == .Null {
			w.err = Refused{at, .No_Spelling}
			return false
		}
		if !put_record_cell(t, at, 0) {
			return false
		}
	case h.delimited || node.kind == .Array && h.node == tape.NO_NODE && !h.scalars:
		// A delimited row, or an array of cells, written by place.
		count := int(node.n) - 1
		if !h.delimited && (node.kind != .Array || tape.child_count(doc, at, node) != h.width) {
			w.err = Refused{at, .Row_Keys}
			return false
		}
		kept := kept_cells(t, h, count)
		if kept == 0 || kept == 1 && count == 1 && doc.nodes[at + 1].kind == .Null {
			w.err = Refused{at, .No_Spelling}
			return false
		}
		if (t.verbatim || t.translate) && t.order == nil && kept == count {
			if !put_verbatim_cells(t, at + 1, count) {
				return false
			}
			break
		}
		written := 0
		for c in 0 ..< count {
			j := c
			if t.order != nil && count == h.width {
				j = t.order[c]
			}
			if h.delimited && h.node != tape.NO_NODE && tape.column_dropped(doc, h.node, j, count) {
				continue
			}
			if written > 0 {
				put_byte(t.out, t.d.delimiter)
			}
			if !put_record_cell(t, at + 1 + tape.Node_Index(j), written) {
				return false
			}
			written += 1
		}
	case node.kind == .Object && h.node != tape.NO_NODE:
		if h.width == 0 {
			w.err = Refused{at, .No_Spelling}
			return false
		}
		// A record with the header's keys in its order takes its values by place.
		if t.order == nil && int(node.n) == 2 * h.width + 1 {
			k := at + 1
			for j in 0 ..< h.width {
				if doc.nodes[k + 1].kind > .Plain || !same_key(doc, k, t.keys_at[j]) {
					break
				}
				k += 2
			}
			if k == at + tape.Node_Index(node.n) {
				for j in 0 ..< h.width {
					if j > 0 {
						put_byte(t.out, t.d.delimiter)
					}
					value := at + 2 + 2 * tape.Node_Index(j)
					if h.width == 1 && doc.nodes[value].kind == .Null {
						w.err = Refused{at, .No_Spelling}
						return false
					}
					if !put_record_cell(t, value, j) {
						return false
					}
				}
				break
			}
		}
		for j in 0 ..< h.width {
			if j > 0 {
				put_byte(t.out, t.d.delimiter)
			}
			name, ok := text_of(w, t.keys_at[column(t, j)])
			if !ok {
				return false
			}
			value, p := tape.member(w.reader, at, name)
			if p == .Missing && h.width > 1 {
				w.dropped += {.Absent}
				continue
			}
			if p != .Found || h.width == 1 && doc.nodes[value].kind == .Null {
				w.err = Refused{at, .No_Spelling}
				return false
			}
			if !put_record_cell(t, value, j) {
				return false
			}
		}
	case:
		w.err = Refused{at, .Not_A_Table}
		return false
	}
	put_line_end(t)
	t.started = true
	return true
}

// Writes the cell at `at`, the `j`th of its record.
@(private)
put_record_cell :: proc(t: ^Table_Write, at: tape.Node_Index, j: int) -> bool {
	if (t.verbatim || t.translate) && put_verbatim_run(t, at, 1) == 1 {
		return true
	}
	return put_cell_of(t, at, j)
}

// Writes the `cells` cells from node `first` as one record's text, as runs where `put_verbatim_run` takes them.
@(private)
put_verbatim_cells :: proc(t: ^Table_Write, first: tape.Node_Index, cells: int) -> bool {
	// A run that holds a byte the target must spell leaves the rest of the record to `put_cell_of`.
	spelled := false
	for j := 0; j < cells; {
		if j > 0 {
			put_byte(t.out, t.d.delimiter)
		}
		at := first + tape.Node_Index(j)
		k := 0
		if !spelled {
			k = put_verbatim_run(t, at, cells - j)
			spelled = k < 0
		}
		if k > 0 {
			j += k
			continue
		}
		if !put_cell_of(t, at, j) {
			return false
		}
		j += 1
	}
	return true
}

// Whether the cell `c` of a verbatim write reads back as itself from its source bytes: a scalar that is not null,
// quoted, escaped or laxly spelled, and a string that does not start with a byte that may make it read as another
// value. Reads `kind` and `spelling` as one word.
@(private)
verbatim_cell :: #force_inline proc "contextless" (t: ^Table_Write, c: ^tape.Node, src: [^]u8) -> bool {
	#assert(offset_of(tape.Node, spelling) == offset_of(tape.Node, kind) + 2)
	SPELLED :: u32(tape.SPELLING_DECODE | tape.SPELLING_QUOTED | tape.SPELLING_LAX)
	word := (^u32)(&c.kind)^
	kind := word & 0xFF
	if kind - u32(tape.Kind.False) > u32(tape.Kind.Plain) - u32(tape.Kind.False) || word >> 16 & SPELLED != 0 {
		return false
	}
	return kind < u32(tape.Kind.String) && !t.translate || c.n > 0 && !t.lead[src[c.lo]]
}

// Writes the cells from node `first`, at most `left` of them, that `verbatim_cell` takes and that follow one another in
// the source a delimiter byte apart, with one copy of their source bytes, under `translate` each delimiter replaced.
// Returns how many it wrote, 0 for none, which leaves the first to `put_cell_of`, and -1 under `translate` for a run
// that holds a byte the target must spell or that ends `translate`.
@(private)
put_verbatim_run :: proc(t: ^Table_Write, first: tape.Node_Index, left: int) -> int #no_bounds_check {
	doc := t.w.doc
	nodes, src := raw_data(doc.nodes[first:]), raw_data(doc.src)
	lo := nodes[0].lo
	// The byte before the cell the run expects next, so the first cell needs no test of its own.
	gap := lo - 1
	k := 0
	for ; k < left; k += 1 {
		c := &nodes[k]
		if c.lo != gap + 1 || !verbatim_cell(t, c, src) || t.translate && c.lo + u64(c.n) - lo > ROOM_MAX {
			break
		}
		gap = c.lo + u64(c.n)
	}
	if k == 0 || gap > u64(len(doc.src)) {
		return 0
	}
	run := doc.src[lo:gap]
	if t.verbatim {
		put(t.out, run)
		return k
	}
	// Every cell of the document is one byte apart, so a separator that is the target's delimiter, which the search
	// would take for a byte of a cell, is one for the rest of the write, which goes cell by cell.
	if k > 1 && src[nodes[1].lo - 1] == t.d.delimiter {
		t.translate = false
		return -1
	}
	if has_special(t, run) {
		return -1
	}
	p := room(t.out, len(run))
	copy(p[:len(run)], run)
	for c in 1 ..< k {
		p[nodes[c].lo - 1 - lo] = t.d.delimiter
	}
	t.out.cursor += len(run)
	return k
}

// Writes the cell at `at`, the `j`th of its record, as its kind spells it.
@(private)
put_cell_of :: proc(t: ^Table_Write, at: tape.Node_Index, j: int) -> bool {
	w := t.w
	node := w.doc.nodes[at]
	switch node.kind {
	case .Null:
		return true
	case .String, .Plain:
		if t.whole && node.spelling & tape.SPELLING_DECODE == 0 {
			return put_cell(t, at, string(w.doc.src[node.lo:][:node.n]), j, false)
		}
		s, ok := text_of(w, at)
		return ok && put_cell(t, at, s, j, false)
	case .True:
		return put_cell(t, at, "true", j, true)
	case .False:
		return put_cell(t, at, "false", j, true)
	case .Number:
		if t.native {
			return put_cell(t, at, string(tape.span_bytes(w.doc, node.lo, node.n)), j, true)
		}
		buf: [NUMBER_ROOM]u8
		s, ok := number_text(w, at, &buf)
		if !ok {
			if w.err == nil {
				w.err = Refused{at, .No_Spelling}
			}
			return false
		}
		return put_cell(t, at, s, j, true)
	case .Bytes:
		s := bytes_base64(w, at) or_return
		defer delete(s, w.allocator)
		return put_cell(t, at, s, j, false)
	case .Array, .Object, .End:
		w.err = Refused{at, .Not_A_Table}
	}
	return false
}

// Ends a line, with CR LF under `crlf`.
@(private)
put_line_end :: #force_inline proc(t: ^Table_Write) {
	if t.d.crlf {
		put_byte(t.out, '\r')
	}
	put_byte(t.out, '\n')
}

// Writes `s` as cell `j` of its record, the text of node `at`, which reads back as a string, or with `typed` as the
// number or boolean it spells. A cell must not read as another value: empty as null, an untyped `true` or number as
// typed under `infer`, a first cell as a comment line, the text's first bytes as a byte order mark. False with `w.err`
// set when the spec cannot hold it.
@(private)
put_cell :: #force_inline proc(t: ^Table_Write, at: tape.Node_Index, s: string, j: int, typed: bool) -> bool #no_bounds_check {
	b := transmute([]u8)s
	if len(b) > 0 && !t.lead[b[0]] {
		i := 0
		for i < len(b) && !t.special[b[i]] {
			i += 1
		}
		if i == len(b) {
			put(t.out, b)
			return true
		}
	}
	return put_cell_spelled(t, at, s, j, typed)
}

// `put_cell` for a cell that is empty, holds a byte its spec must quote, escape or refuse, or starts with a byte that
// may make it read as another value.
@(private)
put_cell_spelled :: #force_no_inline proc(t: ^Table_Write, at: tape.Node_Index, s: string, j: int, typed: bool) -> bool #no_bounds_check {
	b := transmute([]u8)s
	d := t.d
	// An empty key is a cell of no bytes, but a line of one is a blank line, which a read skips.
	empty := len(b) == 0 && t.keys < 2
	looks_typed := !typed && t.keys == 0 && d.infer && reads_typed(b)
	comment := j == 0 && !empty && d.comment != 0 && b[0] == d.comment
	bom := j == 0 && !t.started && len(b) >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF
	switch t.cells {
	case .Quoted:
		if !(empty || looks_typed || comment || bom || has_special(t, b)) {
			put(t.out, b)
			return true
		}
		if typed {
			break
		}
		put_byte(t.out, '"')
		run := 0
		for from := 0; from < len(b); {
			k := bytes.index_byte(b[from:], '"')
			if k < 0 {
				break
			}
			from += k + 1
			put(t.out, b[run:from])
			run = from - 1
		}
		put(t.out, b[run:])
		put_byte(t.out, '"')
		return true
	case .Escaped:
		// A comment byte that is a tab is escaped, so the line does not start with it.
		if empty || looks_typed || bom || comment && d.comment != '\t' || d.delimiter != '\t' && bytes.index_byte(b, d.delimiter) >= 0 {
			break
		}
		if !has_special(t, b) {
			put(t.out, b)
			return true
		}
		run := 0
		for c, i in b {
			e: u8
			switch c {
			case '\t':
				e = 't'
			case '\n':
				e = 'n'
			case '\r':
				e = 'r'
			case '\\':
				e = '\\'
			case 0:
				e = '0'
			case:
				continue
			}
			put(t.out, b[run:i])
			p := room(t.out, 2)
			p[0], p[1] = '\\', e
			t.out.cursor += 2
			run = i + 1
		}
		put(t.out, b[run:])
		return true
	case .Bare:
		if empty || looks_typed || bom || comment || has_special(t, b) {
			break
		}
		put(t.out, b)
		return true
	}
	t.w.err = Refused{at, .No_Spelling}
	return false
}

// Whether `b` holds a byte of `t.special`. A cell of 16 bytes or more is searched a block at a time out of line, so a
// short cell, the common one, takes no call.
@(private)
has_special :: #force_inline proc "contextless" (t: ^Table_Write, b: []u8) -> bool #no_bounds_check {
	if len(b) >= 16 {
		return has_special_long(t, b)
	}
	for c in b {
		if t.special[c] {
			return true
		}
	}
	return false
}

@(private)
has_special_long :: #force_no_inline proc "contextless" (t: ^Table_Write, b: []u8) -> bool #no_bounds_check {
	for i := 0; i < len(b); i += 16 {
		// The last block ends with `b`, overlapping the one before.
		v := kernel.load16(raw_data(b)[min(i, len(b) - 16):])
		hit := simd.lanes_eq(v, t.probe[0]) | simd.lanes_eq(v, t.probe[1]) | simd.lanes_eq(v, t.probe[2]) | simd.lanes_eq(v, t.probe[3]) | simd.lanes_eq(v, t.probe[4]) | simd.lanes_eq(v, t.probe[5])
		if kernel.any_lane16(hit) {
			return true
		}
	}
	return false
}

// Whether `b`, unquoted, reads under `infer` as a boolean or a number.
@(private)
reads_typed :: proc "contextless" (b: []u8) -> bool {
	return string(b) == "true" || string(b) == "false" || is_json_number(b)
}

// Writes the comments of kind `kind` among `facts` as comment lines, each line of a body under the comment byte, and
// drops the others of kinds in `drop`. With no comment byte the target holds no comment, which `tree_start` counts as
// dropped.
@(private)
put_comments :: proc(t: ^Table_Write, facts: []tape.Fact, kind: tape.Fact_Kind, drop: tape.Facts) {
	w := t.w
	if t.d.comment == 0 {
		return
	}
	for f in facts {
		if f.kind != kind {
			w.dropped += {f.kind} & drop & w.holds
			continue
		}
		LINE_ENDS :: []u8{'\r', '\n'}
		body, _ := comment_body(w.doc, f)
		for {
			line := bytes.index_any(body, LINE_ENDS)
			put_byte(t.out, t.d.comment)
			put(t.out, body[:line] if line >= 0 else body)
			put_line_end(t)
			if line < 0 {
				break
			}
			skip := 2 if body[line] == '\r' && line + 1 < len(body) && body[line + 1] == '\n' else 1
			body = body[line + skip:]
		}
		t.started = true
	}
}
