package write

import "base:runtime"
import "core:bytes"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"

// The writer of a delimited text, a record a line, whose format gives the rules of its cells: how a cell that holds
// the delimiter, a quote or a line end is spelled, or that it cannot be. A document writes as a table when its value
// is a table a delimited read built, an array whose elements are all objects, under the union of their keys in the
// order they come, or all arrays, or all scalars, a cell a record, with no header, an object as one record, or a scalar
// as one cell.

// Writes value `opts.node` of `doc` as a delimited text whose cells `cells` spells and whose options are `d`, its
// delimiter resolved, for target `target`. Comments on the table and its records are written as comment lines under a
// comment byte. Returns the fact kinds dropped.
@(require_results)
table :: proc(out: ^Out, doc: ^tape.Document, target: ^tape.Format, cells: Cells, d: tape.Dsv_Options, verbatim: bool, opts: Options, allocator: runtime.Allocator) -> (dropped: tape.Facts, err: Error) {
	holds := target.facts if d.comment != 0 else {}
	t := Table_Write{out = out, cells = cells, d = d, native = doc.format.options == .Dsv, whole = .Held not_in doc.flags}
	t.verbatim = verbatim && t.native && t.whole
	t.translate = !t.verbatim && t.native && t.whole && !d.infer
	init_cell_tables(&t.special, &t.lead, &t.probe, cells, d)
	return table_run(&t, doc, holds, opts, opts.sort_keys, allocator)
}

// Runs `table_rows` on `t` with a freshly started `Tree` and `Doc_Index`, freeing both and `t`'s header slices.
@(private)
table_run :: proc(t: ^Table_Write, doc: ^tape.Document, holds: tape.Facts, opts: Options, sort_keys: bool, allocator: runtime.Allocator) -> (dropped: tape.Facts, err: Error) {
	w: Tree
	tree_start(&w, doc, opts, holds, allocator) or_return
	t.w = &w
	defer t.w = nil
	index := tape.Doc_Index{allocator = allocator}
	w.reader.index = &index
	table_rows(t, sort_keys)
	tape.destroy(&index)
	delete(t.keys_at)
	delete(t.order, allocator)
	dropped = tree_end(&w)
	if w.err == nil {
		w.err = t.out.err
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
	stream:  ^Table_Stream, // the table is written in batches
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
	// The bytes of `special`, each splatted across a block, with `probe[0]` repeated to fill the six.
	probe:   [SPECIAL_MAX]Lanes16,
	keys_at: [dynamic]tape.Node_Index, // the key of each column of the header
	// Under `sort_keys`, the columns in the order of their keys' texts, else nil for their own order.
	order:   []int,
}

// The keys a table's records are written under.
@(private)
Header :: struct {
	keys:      []tape.Node, // of a table with a header, which `tape.table_keys` gives, no nodes of the document
	width:     int, // its keys, or the first array's cells
	node:      tape.Node_Index, // a table with a header, the first object of an array of objects, `NO_NODE` for none
	delimited: bool, // a delimited table's header, whose keys are `keys` and whose rows name cells by place
	scalars:   bool, // the records are scalars, a cell each
}

when size_of(int) == 8 {
	#assert(size_of(Header) == 32)
}

// Writes the table at `w.i`: its comment lines, its header and its records, the columns by their names under
// `sort_keys`.
@(private = "file")
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
	header, objects := table_header(t, root, single)
	// Arrays of cells have no keys to name a header by. Records under keys write with no header line under
	// `no_header`, which reads them back as arrays of cells.
	if !objects && !header.scalars && !t.d.no_header && node.n > 1 {
		w.err = tape.Bad_Option{"no_header"}
		return
	}
	if t.stream != nil && !stream_shape(t, root, header, objects) {
		return
	}
	if header.node != tape.NO_NODE && !(t.stream != nil && t.stream.known) && !header_columns(t, &header, root, single, sort_keys) {
		return
	}
	if t.stream != nil && !stream_names(t, header) {
		return
	}
	lo := node_facts(w, root)
	root_facts := w.facts[lo:w.fact]
	put_comments(t, root_facts, .Comment, ~tape.Facts{.Comment, .Comment_Foot})
	headed := t.stream != nil && t.stream.headed
	if header.node != tape.NO_NODE && !t.d.no_header && !headed && !table_header_line(t, header) {
		return
	}
	if t.stream != nil {
		t.stream.headed = true
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

// The keys of the `Tabular_Ext` table whose row is the object at `at`, false if `at` is not a tabular row.
// Invariant: `Tabular_Ext.tables` is sorted ascending by `node` and each table's span is in `doc.nodes`.
@(private = "file")
row_table_keys :: #force_no_inline proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (keys: []tape.Node, ok: bool) #no_bounds_check {
	if doc.ext == nil {
		return nil, false
	}
	ext, tabular := &doc.ext.format.(tape.Tabular_Ext)
	if !tabular || len(ext.tables) == 0 {
		return nil, false
	}
	lo, hi := 0, len(ext.tables)
	for lo < hi {
		mid := lo + (hi - lo) >> 1
		if ext.tables[mid].node <= at {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {
		return nil, false
	}
	tbl := ext.tables[lo - 1]
	if at <= tbl.node || at >= tbl.node + tape.Node_Index(doc.nodes[tbl.node].n) {
		return nil, false
	}
	return ext.keys[tbl.keys_lo:][:tbl.keys_n], true
}

// The header of the table at `root` and whether its records are objects.
@(private = "file")
table_header :: proc(t: ^Table_Write, root: tape.Node_Index, single: bool) -> (h: Header, objects: bool) {
	w := t.w
	doc := w.doc
	h.node = tape.NO_NODE
	delimited_header :: proc "contextless" (root: tape.Node_Index, keys: []tape.Node) -> (Header, bool) {
		if len(keys) == 0 {
			return {node = tape.NO_NODE, delimited = true}, false
		}
		return {keys = keys, width = len(keys), node = root, delimited = true}, true
	}
	if single {
		if doc.nodes[root].kind == .Object {
			if keys, is_row := row_table_keys(doc, root); is_row {
				return delimited_header(root, keys)
			}
			return {node = root}, true
		}
		return {node = tape.NO_NODE, width = 1, scalars = true}, false
	}
	if keys, is_table := tape.table_keys(doc, root); is_table {
		return delimited_header(root, keys)
	}
	if t.stream != nil && t.stream.known {
		return {node = root, width = len(t.stream.names)}, true
	}
	if doc.nodes[root].n == 1 {
		return h, !t.d.no_header
	}
	#partial switch doc.nodes[root + 1].kind {
	case .Object:
		return {node = root + 1}, true
	case .Array:
		return {node = tape.NO_NODE, width = tape.child_count(doc, root + 1, doc.nodes[root + 1])}, false
	}
	return {node = tape.NO_NODE, width = 1, scalars = true}, false
}

// Lists the key of each column of header `h`, for records that are objects the union of their keys in the order they
// come, and under `sort_keys` the columns in the order of their keys' texts. False with `w.err` set when memory is
// refused.
@(private = "file")
header_columns :: #force_no_inline proc(t: ^Table_Write, h: ^Header, root: tape.Node_Index, single, sort_keys: bool) -> bool {
	w := t.w
	err: runtime.Allocator_Error
	if !h.delimited && !key_union(t, h, root, single) {
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
		s, ok := column_text(t, h^, j)
		if !ok {
			return false
		}
		if n.name, err = strings.clone(s, w.allocator); err != nil {
			w.err = err
			return false
		}
		n.column = j
	}
	slice.stable_sort_by(named, proc(a, b: Named) -> bool { return a.name < b.name })
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
@(private = "file")
key_union :: #force_no_inline proc(t: ^Table_Write, h: ^Header, root: tape.Node_Index, single: bool) -> bool {
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
	if t.stream != nil {
		// A stream's header is its first row's keys.
		end = tape.node_after(doc, first)
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

// Whether string/plain keys `a` and `b` of `doc` are spelled with the same bytes and no escape, so they have one text.
// Invariant: `a` and `b` are valid indices in `doc.nodes`.
@(private = "file")
same_key :: #force_inline proc "contextless" (doc: ^tape.Document, a, b: tape.Node_Index) -> bool #no_bounds_check {
	x, y := doc.nodes[a], doc.nodes[b]
	return x.n == y.n && (x.spelling | y.spelling) & tape.SPELLING_DECODE == 0 && u8(x.kind) - u8(tape.Kind.String) <= 1 && u8(y.kind) - u8(tape.Kind.String) <= 1 && .Held not_in doc.flags && string(doc.src[x.lo:][:x.n]) == string(doc.src[y.lo:][:y.n])
}

// Whether string/plain key `k` of `doc` matches column `j` of the header with no escape.
// Invariant: `k` is a valid index in `doc.nodes` and `0 <= j < len(header)`.
@(private = "file")
same_header_key :: #force_inline proc "contextless" (t: ^Table_Write, doc: ^tape.Document, k: tape.Node_Index, j: int) -> bool #no_bounds_check {
	if t.stream != nil && t.stream.known {
		x := doc.nodes[k]
		return x.spelling & tape.SPELLING_DECODE == 0 && u8(x.kind) - u8(tape.Kind.String) <= 1 && t.whole && string(doc.src[x.lo:][:x.n]) == t.stream.names[j]
	}
	return same_key(doc, k, t.keys_at[j])
}

// The text of the key of column `j` of header `h`.
@(private = "file")
column_text :: proc(t: ^Table_Write, h: Header, j: int) -> (string, bool) {
	if t.stream != nil && t.stream.known {
		return t.stream.names[j], true
	}
	if h.delimited {
		return text_of_token(t.w, h.keys[j])
	}
	return text_of(t.w, t.keys_at[j])
}

// The column written `k`th.
@(private)
column :: #force_inline proc(t: ^Table_Write, k: int) -> int {
	return t.order[k] if t.order != nil else k
}

@(private)
table_refuse :: #force_inline proc "contextless" (w: ^Tree, at: tape.Node_Index, why: Refusal) -> bool {
	w.err = Refused{at, why}
	return false
}

// The header's keys as a record, false with `w.err` set for one the spec cannot hold.
@(private = "file")
table_header_line :: #force_no_inline proc(t: ^Table_Write, h: Header) -> bool {
	w := t.w
	doc := w.doc
	if h.width == 0 {
		return table_refuse(w, h.node, .No_Spelling)
	}
	t.keys = kept_cells(t, h, h.width)
	defer t.keys = 0
	written := 0
	for c in 0 ..< h.width {
		j := column(t, c)
		if h.delimited && tape.column_dropped(doc, h.keys, j, h.width) {
			continue
		}
		if written > 0 {
			put_byte(t.out, t.d.delimiter)
		}
		s, ok := column_text(t, h, j)
		at := h.node if h.delimited || t.stream != nil && t.stream.known else t.keys_at[j]
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
@(private = "file")
kept_cells :: proc(t: ^Table_Write, h: Header, cells: int) -> (n: int) {
	if !h.delimited || h.node == tape.NO_NODE {
		return cells
	}
	for j in 0 ..< cells {
		n += int(!tape.column_dropped(t.w.doc, h.keys, j, cells))
	}
	return
}

// Writes a short ragged delimited row (`count < h.width`) aligned to the header's columns under `sort_keys` and `dups`.
@(private = "file")
table_record_short_row :: #force_no_inline proc(t: ^Table_Write, at: tape.Node_Index, h: Header, count: int) -> bool {
	w := t.w
	doc := w.doc
	kept := kept_cells(t, h, h.width)
	if kept == 0 {
		return table_refuse(w, at, .No_Spelling)
	}
	dups_last := is_tabular_dups_last(doc, kept, h.width)
	written := 0
	for c in 0 ..< h.width {
		j := column(t, c)
		if tape.column_dropped(doc, h.keys, j, h.width) {
			continue
		}
		cell := tape.NO_NODE
		if j < count {
			cell = at + 1 + tape.Node_Index(j)
		} else if dups_last {
			name := text_of_token(w, h.keys[j]) or_return
			if val, p := tape.member(w.reader, at, name); p == .Found {
				cell = val
			}
		}
		if kept == 1 && (cell == tape.NO_NODE || doc.nodes[cell].kind == .Null) {
			return table_refuse(w, at, .No_Spelling)
		}
		if written > 0 {
			put_byte(t.out, t.d.delimiter)
		}
		if cell == tape.NO_NODE {
			w.dropped += {.Absent}
		} else if !put_record_cell(t, cell, written) {
			return false
		}
		written += 1
	}
	return true
}

// Writes the record at `at` under header `h`, false with `w.err` set for one that is no record of the table.
@(private = "file")
table_record :: proc(t: ^Table_Write, at: tape.Node_Index, h: Header) -> bool {
	w := t.w
	doc := w.doc
	node := doc.nodes[at]
	switch {
	case h.scalars && node.kind <= .Plain:
		// A null cell alone on its line would read back as no record.
		if node.kind == .Null {
			return table_refuse(w, at, .No_Spelling)
		}
		if !put_record_cell(t, at, 0) {
			return false
		}
	case h.delimited || node.kind == .Array && h.node == tape.NO_NODE && !h.scalars:
		// A delimited row, or an array of cells, written by place.
		count := int(node.n) - 1
		if !h.delimited && (node.kind != .Array || tape.child_count(doc, at, node) != h.width) {
			return table_refuse(w, at, .Row_Keys)
		}
		if h.delimited && h.node != tape.NO_NODE && count < h.width {
			if !table_record_short_row(t, at, h, count) {
				return false
			}
			break
		}
		kept := kept_cells(t, h, count)
		if kept == 0 {
			return table_refuse(w, at, .No_Spelling)
		}
		if kept == 1 {
			sole := at + 1
			if count > 1 && h.delimited && h.node != tape.NO_NODE {
				for j in 0 ..< count {
					if !tape.column_dropped(doc, h.keys, j, count) {
						sole = at + 1 + tape.Node_Index(j)
						break
					}
				}
			}
			if doc.nodes[sole].kind == .Null {
				return table_refuse(w, at, .No_Spelling)
			}
		}
		if (t.verbatim || t.translate) && t.order == nil && kept == count {
			if !put_verbatim_cells(t, at + 1, count) {
				return false
			}
			break
		}
		written := 0
		for c in 0 ..< count {
			j := t.order[c] if t.order != nil && count == h.width else c
			if h.delimited && h.node != tape.NO_NODE && tape.column_dropped(doc, h.keys, j, count) {
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
			return table_refuse(w, at, .No_Spelling)
		}
		// A record with the header's keys in its order takes its values by place.
		if t.order == nil && int(node.n) == 2 * h.width + 1 {
			k := at + 1
			for j in 0 ..< h.width {
				if doc.nodes[k + 1].kind > .Plain || !same_header_key(t, doc, k, j) {
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
						return table_refuse(w, at, .No_Spelling)
					}
					if !put_record_cell(t, value, j) {
						return false
					}
				}
				break
			}
		}
		found := 0
		for j in 0 ..< h.width {
			if j > 0 {
				put_byte(t.out, t.d.delimiter)
			}
			name := column_text(t, h, column(t, j)) or_return
			value, p := tape.member(w.reader, at, name)
			if p == .Missing && h.width > 1 {
				w.dropped += {.Absent}
				continue
			}
			if p != .Found || h.width == 1 && doc.nodes[value].kind == .Null {
				return table_refuse(w, at, .No_Spelling)
			}
			found += 1
			if !put_record_cell(t, value, j) {
				return false
			}
		}
		// A stream's header is its first row's, so a key it lacks has no column, and a key repeated has none for its second.
		if t.stream != nil && found < tape.child_count(doc, at, node) {
			return table_refuse(w, at, .Row_Keys)
		}
	case:
		return table_refuse(w, at, .Not_A_Table)
	}
	put_line_end(t)
	t.started = true
	return true
}

// Writes the comments of kind `kind` among `facts` as comment lines, each line of a body under the comment byte, and
// drops the others of kinds in `drop`. With no comment byte the target holds no comment, which `tree_start` counts as
// dropped.
@(private = "file")
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
