package core

import "base:runtime"
import "core:bytes"
import "core:slice"

// A log of edits kept apart from a document, which does not change after its build. A reader sees an edit only after
// the caller commits and builds the output again. Any number of lists may share one document, each with its own edits.
//
// `set`, `insert` and `remove` append an edit, checked when it is recorded, in O(its text). A commit resolves every
// edit to a source range, refuses the colliding ones, and splices the edits into the source. Every byte no edit
// touched stays, and the format's `Edit_Spelling` supplies the separators.
//
// A fact edit names a node and a role, and a set also a body. The commit writes the body where the role reads it, or
// drops it and counts it when the output cannot hold it. A fact no edit names keeps its bytes, in order, unless it is
// removed with a removed node or lies inside the span a set replaces, which is the only removed or replaced case. Its
// node and role afterwards follow the comments around it and are not preserved.

// An `Edit_Op` names the change an edit makes to its node.
Edit_Op :: enum u8 {
	Set, // the node's own bytes become `text`
	Insert, // `text`, with `key` for a member, is inserted into the container at `at`
	Remove, // removes the member the node is, and its key
	Set_Fact, // every fact of the node with `role` becomes `text`
	Remove_Fact, // every fact of the node with `role` is removed
}

// Holds the `as` value that selects the document's own spec.
SPEC_DEFAULT :: u8(max(u8))

// A recorded edit. `node` names a node of the document the list was made with: a value or a key for `Set`, a
// container for `Insert`, a value that is a member of a container for `Remove`, and any node but a key for the fact
// edits, whose `role` says which facts they change. `at` is an insert's position, 0 through the container's length at
// the time the edit was recorded. `key` is a member insert's name and `text` is the value, a record, a cell or a
// fact's body, each copied into the list's allocator.
Edit :: struct {
	node: u32,
	op:   Edit_Op,
	role: Role,
	at:   u32,
	key:  []u8,
	text: []u8,
}

// A log of edits against one document. `edits` holds the recorded edits, grows as edits are recorded, and
// `edit_list_destroy` frees it. `allocator` supplies the log and the edits' copies. The document is borrowed and
// must outlive the list.
Edit_List :: struct {
	doc:       ^Document,
	edits:     [dynamic]Edit,
	allocator: runtime.Allocator,
}

// Returns an edit list over `doc`. It allocates nothing until the first edit is recorded.
edit_list_init :: proc(doc: ^Document, allocator := context.allocator) -> Edit_List {
	return {doc = doc, allocator = allocator}
}

// Frees every edit's copies and the log, and sets the list to the zero value. The document is the caller's.
edit_list_destroy :: proc(list: ^Edit_List) {
	for e in list.edits {
		// A key and its text share one allocation, with the key first, so freeing the key frees the text.
		if e.key != nil { delete(e.key, list.allocator) } else if e.text != nil { delete(e.text, list.allocator) }
	}
	delete(list.edits)
	list^ = {}
}

// Whether a document's containers hold a table's records and cells rather than a tree's values. A document whose
// edit table has a `record` service holds a table.
@(private)
table_doc :: #force_inline proc(doc: ^Document) -> bool {
	return doc.spelling.edit != nil && doc.spelling.edit.record != nil
}

// Checks a recorded text as a key, a value or a table's cell. For a table's cell, an empty text is the empty cell and
// passes without a read.
@(private)
judge :: proc(doc: ^Document, text: []u8, allocator: runtime.Allocator, key: bool) -> Document_Error {
	if key {
		return doc.spelling.edit.key(doc, text, allocator)
	}
	if !table_doc(doc) {
		return doc.spelling.edit.value(doc, text, allocator)
	}
	if len(text) == 0 {
		return {}
	}
	cells, e := doc.spelling.edit.record(doc, text, allocator)
	if e.kind != .None {
		return e
	}
	return e if cells == 1 else {kind = .Bad_Value}
}

// Returns node `node` of `list`'s document, or `.Bad_Index` when the list has no document or the index is past the
// last node.
@(private)
node_of :: proc(list: ^Edit_List, node: u32) -> (doc: ^Document, n: Node, err: Document_Error) {
	doc = list.doc
	if doc == nil || int(node) >= len(doc.nodes) {
		return doc, {}, {kind = .Bad_Index}
	}
	return doc, doc.nodes[node], {}
}

// Makes `text` the source bytes of node `node`, a value or a key. A key's text must read as one key of the format,
// and in a delimited text a cell is no key, so its text is checked as a value. An `End` node, a fact node, or a
// container in a table returns `.Bad_Index`. Runs in O(len(text)), checking the text once and copying it once.
set :: proc(list: ^Edit_List, node: u32, text: []u8) -> Document_Error {
	doc, n, err := node_of(list, node)
	if err.kind != .None {
		return err
	}
	table := table_doc(doc)
	// A record or a table is no single value to write: its cells are edited.
	if n.kind == .End || n.role > .Key || table && (n.kind == .Array || n.kind == .Map) {
		return {kind = .Bad_Index}
	}
	// A record or a table's cell is no key: only a tree's key node reads as one.
	if e := judge(doc, text, list.allocator, n.role == .Key && !table); e.kind != .None {
		return e
	}
	return edit_add(list, node, .Set, .Value, 0, nil, text)
}

// Inserts `text` into the array `container` before its element `at`, or after its last when `at` is its length. A
// delimited text's root accepts a record and a record accepts a cell.
@(private)
insert_value :: proc(list: ^Edit_List, container: u32, at: int, text: []u8) -> Document_Error {
	return insert_at(list, container, at, nil, text)
}

// Inserts `key` and `text` as a member of the object `container` before its member `at`, or after its last when
// `at` is its length.
@(private)
insert_member :: proc(list: ^Edit_List, container: u32, at: int, key, text: []u8) -> Document_Error {
	return insert_at(list, container, at, key, text)
}

// `insert` is `insert_value` for an array and `insert_member` for an object.
insert :: proc {
	insert_value,
	insert_member,
}

@(private)
insert_at :: proc(list: ^Edit_List, container: u32, at: int, key, text: []u8) -> Document_Error {
	member := key != nil
	doc := list.doc
	if doc == nil || int(container) >= len(doc.nodes) {
		return {kind = .Bad_Index}
	}
	if doc.nodes[container].kind != (Kind.Map if member else .Array) {
		return {kind = .Wrong_Container}
	}
	n_members := length(doc, container)
	if at < 0 || at > n_members {
		return {kind = .Bad_Position}
	}
	table := table_doc(doc)
	if member {
		if e := judge(doc, key, list.allocator, true); e.kind != .None {
			return e
		}
		if e := judge(doc, text, list.allocator, false); e.kind != .None {
			return e
		}
	} else if table && container == ROOT {
		// The root accepts a record of cells, whose count must equal the table's width.
		cells, e := doc.spelling.edit.record(doc, text, list.allocator)
		if e.kind != .None {
			return e
		}
		if w := table_width(doc); w > 0 && cells != w {
			return {kind = .Bad_Width}
		}
	} else {
		if e := judge(doc, text, list.allocator, false); e.kind != .None {
			return e
		}
		// A record's width is its table's, so a cell may join it only while the count stays within the table's width.
		// The record that sets the width may take a cell past it: the header with no data record, or the only record
		// of a headerless table.
		if table && !(n_members + 1 <= table_width(doc) || sole_record(doc, container)) {
			return {kind = .Bad_Width}
		}
	}
	return edit_add(list, container, .Insert, .Value, u32(at), key, text)
}

// Appends the removal edit. The commit removes the member with its key and one adjacent separator. A delimited
// text's record is removed with its line end, and a record's cell when the remaining table still reads.
remove :: proc(list: ^Edit_List, node: u32) -> Document_Error {
	_, n, err := node_of(list, node)
	// A key and a delimited text's header row are no member of their own: a key is removed with its value.
	if err.kind != .None || node == ROOT || n.kind == .End || n.role != .Value {
		return {kind = .Bad_Index}
	}
	return edit_add(list, node, .Remove, .Value, 0, nil, nil)
}

// Makes `text` the body of every fact of node `node` and `role`. A `Comment_Inline` body holds no LF or CR. A
// `Comment` or `Comment_Foot` body may. Runs in O(len(text)), checking the shape once and copying the text once.
set_fact :: proc(list: ^Edit_List, node: u32, role: Role, text: []u8) -> Document_Error {
	if e := fact_node(list, node, role, text); e.kind != .None {
		return e
	}
	return edit_add(list, node, .Set_Fact, role, 0, nil, text)
}

// Removes every fact of node `node` and `role`, with its source bytes.
remove_fact :: proc(list: ^Edit_List, node: u32, role: Role) -> Document_Error {
	if e := fact_node(list, node, role, nil); e.kind != .None {
		return e
	}
	return edit_add(list, node, .Remove_Fact, role, 0, nil, nil)
}

// The checks every fact edit makes: the node accepts a fact, the role has a body shape, and no other edit of the same
// node and role is recorded. A role at or below `.Key` is refused with `.Bad_Index`, and an unhandled role past `.Key`
// with `.Bad_Fact`.
@(private)
fact_node :: proc(list: ^Edit_List, node: u32, role: Role, text: []u8) -> Document_Error {
	_, n, err := node_of(list, node)
	if err.kind != .None || n.role == .Key || role <= .Key || n.kind == .End {
		return {kind = .Bad_Index}
	}
	#partial switch role {
	case .Comment_Inline:
		if body_lf_cr(text) {
			return {kind = .Bad_Fact}
		}
	case .Comment, .Comment_Foot:
	case:
		return {kind = .Bad_Fact}
	}
	for e in list.edits {
		if e.op >= .Set_Fact && e.node == node && e.role == role {
			return {kind = .Conflicting_Edits}
		}
	}
	return {}
}

// Returns how `spec`'s output spells a comment and its marker byte, from the format's `edit.comment`. Returns
// `.None` and 0 for a format with no comment service.
@(private)
comment_style :: #force_inline proc(doc: ^Document, spec: u8) -> (style: Comment_Spelling, b: u8) {
	if edit := doc.spelling.edit; edit != nil && edit.comment != nil {
		return edit.comment(doc, spec)
	}
	return .None, 0
}

// Whether the output can hold a fact of `role` on `node`. A tree writes a foot on a container or the root, whose close
// or text's end it precedes, and on no other node. A delimited text writes a comment on a record, or on the root above
// its first record, and a foot on the root. An output with no marker holds no fact. The role's shape and the body's
// spelling are checked where the fact is written.
@(private)
fact_slot :: #force_inline proc(doc: ^Document, node: u32, role: Role, style: Comment_Spelling, all_records_removed: bool) -> bool {
	if style == .None {
		return false
	}
	n := doc.nodes[node]
	if !table_doc(doc) {
		return role != .Comment_Foot || node == ROOT || n.kind == .Array || n.kind == .Map
	}
	if role == .Comment_Foot {
		return node == ROOT
	}
	// A comment above a header reads on the root only when a record follows it, which resolves it there.
	return role == .Comment && (node == ROOT ? doc.header != 0 && length(doc, ROOT) > 0 && !all_records_removed : n.role == .Value && (n.kind == .Array || n.kind == .Map))
}

// Whether the list removes every record of a delimited text. A record is the only value container of a table, so one
// pass over the edits counts the removals. A root insert keeps a record, and a text with no record is no removal.
@(private)
records_removed :: #force_inline proc(doc: ^Document, list: ^Edit_List) -> bool {
	removed := 0
	for e in list.edits {
		switch e.op {
		case .Insert:
			if e.node == ROOT {
				return false
			}
		case .Remove:
			if e.node == ROOT || int(e.node) >= len(doc.nodes) {
				continue
			}
			n := doc.nodes[e.node]
			if n.role == .Value && (n.kind == .Array || n.kind == .Map) {
				removed += 1
			}
		case .Set, .Set_Fact, .Remove_Fact:
		}
	}
	return removed > 0 && removed == length(doc, ROOT)
}

// Returns the source bytes the edits make: every byte no edit touched, the edits' texts in their places, and the
// separators the format supplies. The caller frees the result with `allocator`. An edit that another covers and a
// second edit of one node are `.Conflicting_Edits` at the byte where the two meet. An insert whose index lies in a
// removal run moves to the run's cut end, so it is no conflict. The result is checked by the format under `as`, and a
// result that reads less strictly than the source is `.Bad_Result`. A spec other than the document's must read
// strictly, since the source almost never reads under it.
// A fact the output cannot hold is dropped with its source bytes. `dropped` counts the source facts and fact edits the
// output cannot hold. A fact that is removed with a removed member or a set's span is not counted.
commit :: proc(list: ^Edit_List, as := SPEC_DEFAULT, allocator := context.allocator) -> (out: []u8, dropped: int, err: Document_Error) {
	doc := list.doc
	if doc == nil {
		return nil, 0, {kind = .Bad_Index}
	}
	spec := doc.spec if as == SPEC_DEFAULT else as
	chunks, _ := make([dynamic]Chunk, allocator)
	defer delete(chunks)
	text, _ := make([dynamic]u8, allocator)
	defer delete(text)
	if e, ok := chunk_edits(doc, list, spec, &text, &chunks, &dropped, allocator); !ok {
		return nil, 0, e
	}
	if e := order_chunks(doc, &chunks); e.kind != .None {
		return nil, 0, e
	}
	out, err = splice(doc, chunks[:], text[:], allocator)
	if err.kind != .None {
		return nil, 0, err
	}
	if e := reads_as_source(doc, out, spec); e.kind != .None {
		delete(out, allocator)
		return nil, 0, e
	}
	return out, dropped, {}
}

// Sorts the chunks and refuses the edits that meet: an insert inside what another edit replaces, two chunks that
// overlap, two edits of one node, and an insert at a zero-width set whose separator is written before its text. Inserts
// inside a removal run are moved to its cut end when the chunks are built, so an insert at the cut's end is no conflict.
@(private)
order_chunks :: proc(doc: ^Document, chunks: ^[dynamic]Chunk) -> Document_Error {
	slice.stable_sort_by(chunks[:], proc(a, b: Chunk) -> bool {
		if a.lo != b.lo {
			return a.lo < b.lo
		}
		// A comment that leads a byte is written before the tree's bytes there, so a head comment stays a head comment.
		// An inline comment at a byte sorts first and stays on the value's line.
		if a.inline != b.inline {
			return a.inline
		}
		// An insert at a byte is written before the bytes there, so it is spliced before what it precedes.
		return a.insert && !b.insert
	})
	at := u64(0)
	prev_lo, prev_hi := u64(0), u64(0)
	have := false
	for i := 0; i < len(chunks); {
		c := chunks[i]
		if c.insert {
			if have && c.lo < at {
				return {kind = .Conflicting_Edits, at = c.lo}
			}
			j := i
			for j < len(chunks) && chunks[j].insert && chunks[j].lo == c.lo {
				j += 1
			}
			// An inline fact after the bytes this insert writes would be on the new member's line, where its own
			// member no longer ends, so the two edits meet.
			if j < len(chunks) && chunks[j].inline && chunks[j].lo > c.lo {
				q := c.lo
				for q < chunks[j].lo && (doc.src[q] == ' ' || doc.src[q] == '\t' || doc.src[q] == '\n' || doc.src[q] == '\r') {
					q += 1
				}
				if q == chunks[j].lo {
					return {kind = .Conflicting_Edits, at = c.lo}
				}
			}
			// An insert at the byte of a set that writes no bytes is two edits at one point, so the set's node cannot
			// be told from the inserted text.
			if j < len(chunks) && !chunks[j].insert && !chunks[j].remove && chunks[j].lo == c.lo && chunks[j].hi == c.lo && c.sep_first {
				return {kind = .Conflicting_Edits, at = c.lo}
			}
			i = j
			continue
		}
		// A fact the output cannot hold inside what another edit writes is removed with that edit's bytes, so its
		// chunk writes nothing.
		if c.fact && c.remove && have && c.hi <= at {
			chunks[i] = Chunk{lo = at, hi = at}
			i += 1
			continue
		}
		// Two edits of one node write the same bytes even when the node is empty, and the bytes of a removal stay
		// empty. Both are found in the sorted chunk walk.
		if have && (c.lo < at || c.lo == prev_lo && c.hi == prev_hi) {
			return {kind = .Conflicting_Edits, at = c.lo}
		}
		at = c.hi
		prev_lo, prev_hi = c.lo, c.hi
		have = true
		i += 1
	}
	return {}
}

// The output must read as strictly as the source. A text that needs a tolerance only the source needed is the edit's
// own defect. A tolerance is accepted only when the output keeps the document's spec, since under another spec the
// source's own reading is no evidence and the output must read strictly. A text that fails even the format's tolerant
// read returns `.Bad_Result`.
@(private)
reads_as_source :: proc(doc: ^Document, out: []u8, spec: u8) -> Document_Error {
	edit := doc.spelling.edit
	if edit == nil || edit.reads == nil {
		return {}
	}
	f, faulted := edit.reads(doc, out, false, spec)
	if !faulted {
		return {}
	}
	if g, still := edit.reads(doc, out, true, spec); still {
		return {kind = .Bad_Result, inner = g}
	}
	if spec != doc.spec {
		return {kind = .Bad_Result, inner = f}
	}
	if _, src_bad := edit.reads(doc, doc.src, false, spec); !src_bad {
		return {kind = .Bad_Result, inner = f}
	}
	return {}
}

// Builds the output in one allocation: the source bytes between chunks, and each chunk's text in its place.
// Returns `.No_Memory` when the allocation is refused.
@(private)
splice :: proc(doc: ^Document, chunks: []Chunk, text: []u8, allocator: runtime.Allocator) -> (out: []u8, err: Document_Error) {
	total := i64(len(doc.src))
	for c in chunks {
		total += i64(c.to-c.from) - i64(c.hi-c.lo)
	}
	raw, aerr := runtime.mem_alloc_non_zeroed(int(total), 1, allocator)
	if aerr != nil {
		return nil, {kind = .No_Memory}
	}
	out = raw[:int(total)]
	w := 0
	at := u64(0)
	for c in chunks {
		if c.lo > at {
			w += copy(out[w:], doc.src[at:c.lo])
		}
		w += copy(out[w:], text[c.from:c.to])
		at = max(at, c.hi)
	}
	copy(out[w:], doc.src[at:])
	return out, {}
}

// Replaces `src[lo:hi]` with `text[from:to]`. With `insert` set the range is empty and the text goes in at `lo`.
// `fact` marks a fact's chunk, which shares no separator with a neighbour's removal, and `inline` marks one written
// after the value it belongs to rather than before the byte it leads.
@(private)
Chunk :: struct {
	lo, hi: u64,
	from:   int,
	to:     int,
	insert:    bool,
	remove:    bool,
	fact:      bool,
	inline:    bool,
	sep_first: bool,
}

// Whether `c` is the delimited text's record that sets the table's width: the only record of a table with no
// header, or the header of a table with no data record. Such a record may change its width.
@(private)
sole_record :: proc(doc: ^Document, c: u32) -> bool {
	if doc.header == c { return length(doc, ROOT) == 0 }
	return doc.header == 0 && length(doc, ROOT) == 1
}

// Returns the cell count every record of a delimited text has: its header's, its first record's, or 0 for an empty
// text.
@(private)
table_width :: proc(doc: ^Document) -> int {
	if doc.header != 0 {
		return length(doc, doc.header)
	}
	it := children(doc, ROOT)
	if rec, ok := child_next(&it); ok {
		return length(doc, rec)
	}
	return 0
}

// Whether the bytes before `pos` end inside a comment, which would swallow what a splice writes there: a comment
// whose spelling ends with no marker runs to the line's end, and a delimited text's line may also start with its
// comment byte and hold no line end.
@(private)
ends_in_comment :: proc(doc: ^Document, v: u32, pos: u64) -> bool {
	if doc.comment != 0 && pos > 0 && pos <= u64(len(doc.src)) {
		if last := doc.src[pos-1]; last != '\n' && last != '\r' {
			lo, _ := line_of(doc.src, pos, !table_doc(doc))
			if doc.src[lo] == doc.comment {
				return true
			}
		}
	}
	for f in all_facts(doc, v) {
		// A tail length of 0 means no closing marker, as a line comment has.
		if f.lo + u64(f.n) == pos && f.spelling >> 8 == 0 {
			return true
		}
	}
	return false
}

// Returns the first byte of member `v` of `parent`, without the comments it holds: its key's first byte or its own.
// Only a `Map`'s member has a key node before it. A dsv root's first record follows the header row, whose last cell
// also has role `Key`, and that cell names a column, not the record.
@(private)
value_lo :: proc(doc: ^Document, parent, v: u32) -> u64 {
	if doc.nodes[parent].kind == .Map && doc.nodes[v-1].role == .Key {
		return key_start(doc.nodes[v-1])
	}
	return key_start(doc.nodes[v])
}

// Returns the first byte of member `v` of `parent`: a comment above it, or its own first byte.
@(private)
entry_lo :: proc(doc: ^Document, parent, v: u32) -> u64 {
	lo := value_lo(doc, parent, v)
	for f in all_facts(doc, v) {
		if f.lo < lo {
			lo = f.lo
		}
	}
	return lo
}

// Returns one past the last byte of member `v`, including the comments after its value. When a fact lies after the
// comma that follows the member, the extent stops at that comma, so the cut removes the separator. With no fact after
// the comma, the next member's cut takes the separator.
@(private)
entry_hi :: proc(doc: ^Document, v: u32) -> u64 {
	hi := key_start(doc.nodes[v]) + u64(len(span(doc, v)))
	at := hi
	for f in all_facts(doc, v) {
		if f.lo < hi {
			continue
		}
		if k := bytes.index_byte(doc.src[at:f.lo], ','); k >= 0 {
			return at + u64(k)
		}
		hi = f.lo + u64(f.n)
		at = hi
	}
	return hi
}

// Returns the first `b` in `src[lo:hi]` that lies in a gap between the facts of `node`, or false when there is none.
// A separator lies between comments, and no comment body holds one.
@(private)
trivia_byte :: proc(doc: ^Document, node: u32, lo, hi: u64, b: u8) -> (u64, bool) {
	from := lo
	for f in all_facts(doc, node) {
		if f.lo >= hi {
			break
		}
		if end := f.lo + u64(f.n); end > from {
			if k := bytes.index_byte(doc.src[from:f.lo], b); k >= 0 {
				return from + u64(k), true
			}
			from = end
		}
	}
	if from < hi {
		if k := bytes.index_byte(doc.src[from:hi], b); k >= 0 {
			return from + u64(k), true
		}
	}
	return 0, false
}

// Returns the bytes between container `c`'s brackets, where its members go. A delimited text's empty table is empty
// to its end, and a tree's empty container keeps only its brackets.
@(private)
interior :: proc(doc: ^Document, c: u32) -> (lo, hi: u64) {
	hi = doc.spelling.close_end(doc, c)
	if table_doc(doc) {
		return doc.nodes[c].lo, hi
	}
	return doc.nodes[c].lo + 1, hi - 1
}

// An `Entry` holds a member of a container as a commit reads it: the value's node, the first byte an insert or a
// removal writes from, and one past the last.
@(private)
Entry :: struct {
	node: u32,
	lo:   u64,
	hi:   u64,
}

// Collects the members of `c` into `out`, in source order.
@(private)
collect_entries :: proc(doc: ^Document, c: u32, out: ^[dynamic]Entry) -> bool {
	clear(out)
	it := children(doc, c)
	for {
		v, ok := child_next(&it)
		if !ok {
			return true
		}
		push(out, Entry{node = v, lo = entry_lo(doc, c, v), hi = entry_hi(doc, v)}) or_return
	}
}

// Writes one insert's bytes and its chunk at `pos`: the member's separator, a table's cell or record separator, on
// the side `side` picks (-1 before, 0 none, 1 after). A leading newline keeps the insert off the line of the comments
// that lead its neighbour. Returns false when the format has no record separator.
@(private)
write_insert :: proc(doc: ^Document, e: Edit, pos: u64, side: int, leading, table: bool, text: ^[dynamic]u8, chunks: ^[dynamic]Chunk) -> bool {
	cell_sep: [1]u8
	sep := doc.spelling.edit.member_sep
	if table && e.node == ROOT {
		if doc.spelling.edit.record_sep == nil {
			return false
		}
		sep = doc.spelling.edit.record_sep(doc)
	} else if table {
		cell_sep[0] = doc.delimiter
		sep = string(cell_sep[:])
	}
	sep_bytes := transmute([]u8)sep
	from := len(text^)
	if side < 0 {
		push_all(text, sep_bytes) or_return
	}
	if e.key != nil {
		push_all(text, e.key) or_return
		push_all(text, transmute([]u8)doc.spelling.edit.key_sep) or_return
	}
	push_all(text, e.text) or_return
	if side > 0 {
		push_all(text, sep_bytes) or_return
	}
	if leading {
		push(text, '\n') or_return
	}
	push(chunks, Chunk{lo = pos, hi = pos, from = from, to = len(text^), insert = true, sep_first = side < 0}) or_return
	return true
}

// Builds the chunk of one insert outside a removal run: the member's bytes and the separators around it. A
// container's first member gets no separator before it, and each later member gets the separator on the side of the
// member it joins. `head_new` says an edit adds a head comment to the member at the insert's place.
@(private)
insert_chunk :: proc(doc: ^Document, e: Edit, entries: []Entry, table, first_empty, head_new: bool, text: ^[dynamic]u8, chunks: ^[dynamic]Chunk) -> bool {
	c := e.node
	n := len(entries)
	side: int // -1 before the member, 0 no separator, 1 after it
	pos: u64
	leading := false
	switch {
	case n > 0 && int(e.at) < n:
		pos = entries[e.at].lo
		// A new member is written before the comments that lead the member at `at`, so those comments stay with that
		// member. A head comment the edit adds to that member gets a line of its own when it does not already lead one.
		leading = pos < value_lo(doc, c, entries[e.at].node)
		if !leading && head_new {
			_, hi := line_of(doc.src, pos, !table_doc(doc))
			leading = hi == pos
		}
		// The separator that joins the member before is written on one side of this member's own comments. The new
		// member gets the separator on the other side, so each pair is joined once.
		side = -1 if int(e.at) > 0 && !table && bytes.index_byte(doc.src[entries[e.at-1].hi:pos], ',') < 0 else 1
	case table && c == ROOT && (n > 0 || doc.header != 0):
		// A delimited text's records are separated by the line end of the record before them, which the last record
		// may not have. A header occupies the place the last record would.
		pos = entries[n-1].hi if n > 0 else doc.spelling.close_end(doc, doc.header)
		side = -1 if pos == 0 || doc.src[pos-1] != '\n' else 1
	case n > 0:
		pos = entries[n-1].hi
		side = -1
		// A trailing comma after the last member already separates the new one, which is written after it. A
		// following inline fact then stays on the last member's line, before the new member.
		if p, comma := comma_after(doc.src, pos); comma {
			pos = p
			side = 1
		}
		// The last member's own comments may be after its separator. The new member is written after them, and no
		// separator is written since one is already there.
		after := pos
		for f in all_facts(doc, entries[n-1].node) {
			if f.lo >= pos {
				after = max(after, f.lo + u64(f.n))
			}
		}
		if after > pos {
			pos = after
			side = 0
		}
		if !table && ends_in_comment(doc, entries[n-1].node, pos) {
			// A line comment ends its line: the new member starts the next one, after the line end the text has.
			pos = line_end_len(doc.src, pos, true)
		}
	case:
		// An empty container writes the member alone, or after a separator another edit put there.
		_, pos = interior(doc, c)
		if table {
			// A text whose last line is a comment with no line end must not swallow the record. The record starts on a
			// new line, and the comment line keeps its own bytes.
			side = -1 if c == ROOT && ends_in_comment(doc, NO_NODE, pos) else 1
		} else if !first_empty {
			side = -1
		}
	}
	return write_insert(doc, e, pos, side, leading && !table, table, text, chunks)
}

// One run of removed members. `first` and `last` are the removed member indices, and `hi` is where the run's cut
// ends, which is where an insert inside the run moves to.
@(private)
Run :: struct {
	first, last: int,
	hi:          u64,
	inserts:     int,
}

// Returns `lo` moved past each space or tab before `hi`.
@(private)
blanks_end :: #force_inline proc(src: []u8, lo, hi: u64) -> u64 {
	p := lo
	for p < hi && (src[p] == ' ' || src[p] == '\t') {
		p += 1
	}
	return p
}

// Returns the first byte of the line holding `pos`, and the line end that ends the line before it. With `unicode`, a
// U+2028 or U+2029 separator is a line end, which only JSON5 reads as one.
@(private)
line_start :: #force_inline proc(src: []u8, pos: u64, unicode: bool) -> (lo, eol: u64, has_eol: bool) {
	lo = pos
	for lo > 0 {
		c := src[lo-1]
		if c == '\n' {
			return lo, lo - 2 if lo >= 2 && src[lo-2] == '\r' else lo - 1, true
		}
		if c == '\r' {
			return lo, lo - 1, true
		}
		if unicode && lo >= 3 && src[lo-3] == 0xE2 && src[lo-2] == 0x80 && c | 1 == 0xA9 {
			return lo, lo - 3, true
		}
		lo -= 1
	}
	return lo, 0, false
}

// Returns the first byte of the line holding `pos`, and the first byte past the whitespace that starts that line.
@(private)
line_of :: #force_inline proc(src: []u8, pos: u64, unicode: bool) -> (lo, indent_hi: u64) {
	lo, _, _ = line_start(src, pos, unicode)
	indent_hi = blanks_end(src, lo, pos)
	return
}

// Whether `body` holds a line end a JSON line comment ends at: LF, CR, or a Unicode line separator. `line_end_len`
// reads the same set.
@(private)
body_line_end :: #force_inline proc(body: []u8) -> bool {
	return bytes.index_byte(body, '\n') >= 0 || bytes.index_byte(body, '\r') >= 0 || bytes.index(body, transmute([]u8)string("\xE2\x80\xA8")) >= 0 || bytes.index(body, transmute([]u8)string("\xE2\x80\xA9")) >= 0
}

// Whether `body` holds LF or CR, the only line ends a delimited text's comment line ends at. U+2028 is a byte in its
// body.
@(private)
body_lf_cr :: #force_inline proc(body: []u8) -> bool {
	return bytes.index_byte(body, '\n') >= 0 || bytes.index_byte(body, '\r') >= 0
}

// Whether the output holds `body` in the spelling `line` picks: a line comment holds no line end, a block comment holds
// no `*/`, and a comment byte's line holds no LF or CR.
@(private)
fact_body_held :: proc(style: Comment_Spelling, body: []u8, line: bool) -> bool {
	switch style {
	case .None:
		return false
	case .Byte:
		return !body_lf_cr(body)
	case .Line:
		if line {
			return !body_line_end(body)
		}
		return bytes.index(body, transmute([]u8)string("*/")) < 0
	}
	return false
}

// Writes a fact body with the markers `style` gives: `//body` when `line` says a line comment ends here, else
// `/*body*/`. A fact that leads its line (`lead`) starts on a line of its own with the line's indent. A new head or
// foot fact (`new`) also ends its line, and a replaced or inline one adds no trailing line end.
@(private)
fact_write :: proc(doc: ^Document, style: Comment_Spelling, role: Role, body: []u8, line: bool, indent: []u8, lead, new: bool, text: ^[dynamic]u8) -> bool {
	if lead {
		push(text, '\n') or_return
		push_all(text, indent) or_return
	}
	if role == .Comment_Inline {
		push(text, ' ') or_return
	}
	switch style {
	case .Line:
		push_all(text, transmute([]u8)string("/*" if !line else "//")) or_return
		push_all(text, body) or_return
		if !line {
			push_all(text, transmute([]u8)string("*/")) or_return
		}
	case .Byte:
		push(text, doc.comment) or_return
		push_all(text, body) or_return
	case .None:
		return false
	}
	if new {
		push(text, '\n') or_return
		push_all(text, indent) or_return
	}
	return true
}

// Builds the chunks of every source fact the output cannot hold and of every fact edit. A source fact the output cannot
// hold is removed with its bytes and counted, unless a set writes over its bytes, where it is removed with the set and is
// not counted. A source fact the output can hold stays where its bytes are: a removal takes it, a set takes the bytes inside
// its span, and an insert beside it leaves it.
@(private)
fact_chunks :: proc(doc: ^Document, list: ^Edit_List, style: Comment_Spelling, text: ^[dynamic]u8, chunks: ^[dynamic]Chunk, dropped: ^int, all_records_removed: bool, allocator: runtime.Allocator) -> bool {
	Span :: struct {
		lo, hi: u64,
	}
	keys, _ := make([dynamic]u64, 0, 8, allocator)
	defer delete(keys)
	spans, _ := make([dynamic]Span, 0, 8, allocator)
	defer delete(spans)
	for x in list.edits {
		switch x.op {
		case .Set_Fact, .Remove_Fact:
			push(&keys, u64(x.node) << 8 | u64(x.role)) or_return
		case .Set:
			if int(x.node) < len(doc.nodes) {
				lo := key_start(doc.nodes[x.node])
				push(&spans, Span{lo = lo, hi = lo + u64(len(span(doc, x.node)))}) or_return
			}
		case .Insert, .Remove:
		}
	}
	slice.sort(keys[:])
	slice.sort_by(spans[:], proc(a, b: Span) -> bool { return a.lo < b.lo })
	for i in 1 ..< len(spans[:]) {
		spans[i].hi = max(spans[i].hi, spans[i-1].hi)
	}
	for f in doc.facts {
		_, named := slice.binary_search(keys[:], u64(f.node) << 8 | u64(f.role))
		written := false
		if len(spans[:]) > 0 {
			i, _ := slice.binary_search_by(spans[:], f.lo, proc(s: Span, lo: u64) -> slice.Ordering {
				return .Less if s.lo <= lo else .Greater
			})
			written = i > 0 && spans[i-1].hi >= f.lo + u64(f.n)
		}
		// A fact inside a set's span is removed with the set, and a named fact is the edit's.
		if written || named {
			continue
		}
		slot := fact_slot(doc, f.node, f.role, style, all_records_removed)
		// An unnamed root comment above a header reads as the root's foot when every record is removed, so the output
		// holds it and keeps its bytes.
		if !slot && f.role == .Comment && f.node == ROOT && doc.header != 0 && all_records_removed {
			slot = true
		}
		if !slot {
			push(chunks, Chunk{lo = f.lo, hi = f.lo + u64(f.n), remove = true, fact = true}) or_return
			dropped^ += 1
		}
	}
	for e in list.edits {
		if e.op >= .Set_Fact {
			fact_edit_chunks(doc, list, style, e, text, chunks, dropped, all_records_removed) or_return
		}
	}
	return true
}

// Returns the indent of the line holding `pos` and whether bytes stand before `pos` on that line.
@(private)
line_shape :: proc(doc: ^Document, pos: u64) -> (indent: []u8, lead: bool) {
	lo, hi := line_of(doc.src, pos, !table_doc(doc))
	return doc.src[lo:hi], hi < pos
}

// Removes the facts of `e.node` and `e.role`, except the first when a set will replace it. Returns the first fact's
// span and how many old facts the edit names.
@(private)
fact_take_old :: proc(doc: ^Document, e: Edit, slot: bool, chunks: ^[dynamic]Chunk) -> (first_lo, first_hi: u64, taken: int, ok: bool) {
	for f in all_facts(doc, e.node) {
		if f.role != e.role {
			continue
		}
		if taken == 0 {
			first_lo, first_hi = f.lo, f.lo + u64(f.n)
		}
		if taken > 0 || e.op == .Remove_Fact || !slot {
			push(chunks, Chunk{lo = f.lo, hi = f.lo + u64(f.n), remove = true, fact = true}) or_return
		}
		taken += 1
	}
	return first_lo, first_hi, taken, true
}

// Returns the byte after a comma that follows `pos` over blanks, or `pos` and false.
@(private)
comma_after :: proc(src: []u8, pos: u64) -> (u64, bool) {
	p := blanks_end(src, pos, u64(len(src)))
	if p < u64(len(src)) && src[p] == ',' {
		return p + 1, true
	}
	return pos, false
}

// Returns the byte a fact body is written at: the first old fact's end when the edit replaces one, else after the
// value and comma on its line, else before the byte the role leads.
@(private)
fact_place :: proc(doc: ^Document, e: Edit, taken: int, first_hi: u64, chunks: ^[dynamic]Chunk) -> u64 {
	if taken > 0 {
		return first_hi
	}
	if e.role == .Comment_Inline {
		pos := key_start(doc.nodes[e.node]) + u64(len(span(doc, e.node)))
		after, comma := comma_after(doc.src, pos)
		if comma {
			for c in chunks^ {
				if c.remove && !c.fact && after > c.lo && after <= c.hi {
					return pos
				}
			}
			pos = after
		}
		return pos
	}
	if e.role == .Comment_Foot {
		if e.node == ROOT {
			return u64(len(doc.src))
		}
		_, pos := interior(doc, e.node)
		return pos
	}
	pos := key_start(doc.nodes[e.node])
	if table_doc(doc) && e.node == ROOT {
		pos = text_start(doc.src, 0)
	} else if !table_doc(doc) && e.node > 0 && doc.nodes[e.node-1].role == .Key && doc.nodes[e.node-1].kind <= .Plain {
		pos = key_start(doc.nodes[e.node-1])
	}
	return pos
}

// Whether a fact body at `pos` can use a line comment. A chunk that inserts at the byte writes after the comment on its
// line, and a replacement or inline fact is written in the block spelling.
@(private)
fact_line :: proc(doc: ^Document, e: Edit, pos: u64, taken: int, inserted: bool) -> bool {
	line := taken == 0 && e.role != .Comment_Inline || pos >= u64(len(doc.src)) || line_end_len(doc.src, pos, true) > pos
	line = line && !body_line_end(e.text)
	if e.role == .Comment_Inline || taken > 0 {
		line = line && !inserted
	}
	return line
}

// Whether a line end before `pos` is left by the removal chunks. At the text's start there is no line end to keep.
@(private)
line_end_survives :: proc(doc: ^Document, chunks: ^[dynamic]Chunk, pos: u64) -> bool {
	_, eol, has_eol := line_start(doc.src, pos, !table_doc(doc))
	if !has_eol {
		return true
	}
	for c in chunks^ {
		if c.remove && !c.fact && eol >= c.lo && eol < c.hi {
			return false
		}
	}
	return true
}

// Builds the chunks of one fact edit. The facts the edit names are removed, and a set writes its body where the role
// reads it, or drops it and counts it. A body the output cannot spell is dropped too. The facts are read once.
@(private)
fact_edit_chunks :: proc(doc: ^Document, list: ^Edit_List, style: Comment_Spelling, e: Edit, text: ^[dynamic]u8, chunks: ^[dynamic]Chunk, dropped: ^int, all_records_removed: bool) -> bool {
	slot := fact_slot(doc, e.node, e.role, style, all_records_removed)
	first_lo, first_hi, taken, ok := fact_take_old(doc, e, slot, chunks)
	if !ok {
		return false
	}
	if e.op == .Remove_Fact || !slot {
		if !slot && e.op == .Set_Fact {
			// The old facts are the edit's to take, and the new body has no place to stand.
			dropped^ += 1
		}
		return true
	}
	pos := fact_place(doc, e, taken, first_hi, chunks)
	inserted, tree_insert, insert_here := false, false, false
	for c in chunks^ {
		if c.insert {
			if c.lo == pos {
				inserted = true
				tree_insert ||= !c.fact
			}
			if c.lo == first_lo {
				insert_here ||= !c.fact
			}
		}
	}
	line := fact_line(doc, e, pos, taken, inserted)
	if !fact_body_held(style, e.text, line) {
		if taken > 0 {
			push(chunks, Chunk{lo = first_lo, hi = first_hi, remove = true, fact = true}) or_return
		}
		dropped^ += 1
		return true
	}
	from := len(text^)
	if taken > 0 {
		// A head or foot that the source held mid-line gets a line of its own, so its role survives the bytes another
		// edit may remove before it.
		indent, lead := line_shape(doc, first_lo)
		lead = lead && e.role != .Comment_Inline
		if style == .Byte {
			indent, lead = nil, false
		} else if e.role != .Comment_Inline {
			lead = lead || insert_here || !line_end_survives(doc, chunks, first_lo)
		}
		fact_write(doc, style, e.role, e.text, line, indent, lead, false, text) or_return
		push(chunks, Chunk{lo = first_lo, hi = first_hi, from = from, to = len(text^), fact = true}) or_return
		return true
	}
	inline := e.role == .Comment_Inline
	if inline {
		fact_write(doc, style, e.role, e.text, line, nil, false, false, text) or_return
	} else {
		indent, lead := line_shape(doc, pos)
		if style == .Byte {
			lo, _ := line_of(doc.src, pos, false)
			indent, lead = nil, pos != text_start(doc.src, 0) && lo < pos
		}
		// An insert at the same byte writes before the fact, and a cut may take the line end before it, so a head or
		// foot needs a line end to stay on its own line and keep the role the edit names.
		lead = lead || tree_insert || !line_end_survives(doc, chunks, pos)
		fact_write(doc, style, e.role, e.text, line, indent, lead, true, text) or_return
	}
	push(chunks, Chunk{lo = pos, hi = pos, from = from, to = len(text^), insert = true, fact = true, inline = inline}) or_return
	return true
}

// A `Remove_Range` is the node range an edit takes out: a removal's subtree, or a set's replaced value for a fact
// edit below it.
@(private)
Remove_Range :: struct {
	lo: u32,
	hi: u32,
	op: Edit_Op,
}

// A `Remove_Query` names the node an edit writes at, its index in the list, and whether it is a fact edit.
@(private)
Remove_Query :: struct {
	node: u32,
	edit: int,
	fact: bool,
}

// Returns the conflict when an edit writes inside a subtree another edit removes, or a fact edit names a node below a
// set's node. The ranges and queries are sorted once and swept, so the check is O(n log n). A range covers a node when
// `lo <= node < hi`, so the greatest `hi` seen with `lo <= node` decides it. A removal includes its own node. A set on
// the fact's own node is not below it, so a set at the query's node is held back one node.
@(private)
edits_removed :: proc(doc: ^Document, list: ^Edit_List, allocator: runtime.Allocator) -> (err: Document_Error, conflict: bool) {
	err = {kind = .No_Memory}
	ranges, _ := make([dynamic]Remove_Range, 0, len(list.edits), allocator)
	defer delete(ranges)
	queries, _ := make([dynamic]Remove_Query, 0, len(list.edits), allocator)
	defer delete(queries)
	for e, i in list.edits {
		if int(e.node) >= len(doc.nodes) {
			continue
		}
		switch e.op {
		case .Remove, .Set:
			n := doc.nodes[e.node]
			span := n.n if n.kind == .Array || n.kind == .Map else 1
			push(&ranges, Remove_Range{lo = e.node, hi = e.node + span, op = e.op}) or_return
			if e.op == .Set {
				push(&queries, Remove_Query{node = e.node, edit = i}) or_return
			}
		case .Insert:
			push(&queries, Remove_Query{node = e.node, edit = i}) or_return
		case .Set_Fact, .Remove_Fact:
			push(&queries, Remove_Query{node = e.node, edit = i, fact = true}) or_return
		}
	}
	slice.sort_by(ranges[:], proc(a, b: Remove_Range) -> bool { return a.lo < b.lo })
	slice.sort_by(queries[:], proc(a, b: Remove_Query) -> bool { return a.node < b.node })
	removed_hi, set_hi, same_set_hi := u32(0), u32(0), u32(0)
	node := u32(0)
	ri, best, best_node := 0, -1, u32(0)
	for q in queries {
		if q.node != node {
			node = q.node
			set_hi = max(set_hi, same_set_hi)
			same_set_hi = 0
		}
		for ri < len(ranges) && ranges[ri].lo <= q.node {
			r := ranges[ri]
			ri += 1
			switch {
			case r.op == .Remove:
				removed_hi = max(removed_hi, r.hi)
			case r.lo == q.node:
				same_set_hi = max(same_set_hi, r.hi)
			case:
				set_hi = max(set_hi, r.hi)
			}
		}
		bad := removed_hi > q.node || q.fact && set_hi > q.node
		if bad && (best < 0 || q.edit < best) {
			best = q.edit
			best_node = q.node
		}
	}
	if best >= 0 {
		return {kind = .Conflicting_Edits, at = key_start(doc.nodes[best_node])}, true
	}
	return {}, false
}

// Builds the chunks of every insert and remove, then of every fact the output cannot hold and every fact edit.
@(private)
chunk_edits :: proc(doc: ^Document, list: ^Edit_List, spec: u8, text: ^[dynamic]u8, chunks: ^[dynamic]Chunk, dropped: ^int, allocator: runtime.Allocator) -> (err: Document_Error, ok: bool) {
	err = {kind = .No_Memory}
	if e, bad := edits_removed(doc, list, allocator); bad {
		return e, false
	}
	style, _ := comment_style(doc, spec)
	if e, good := tree_chunks(doc, list, text, chunks, allocator); !good {
		return e, false
	}
	all_records_removed := table_doc(doc) && records_removed(doc, list)
	fact_chunks(doc, list, style, text, chunks, dropped, all_records_removed, allocator) or_return
	return {}, true
}

// Collects every insert and remove target under its container, and writes every set's chunk. A set that empties a
// table cell also joins the targets for the width check.
@(private)
tree_targets :: proc(doc: ^Document, list: ^Edit_List, text: ^[dynamic]u8, chunks: ^[dynamic]Chunk, table: bool, groups, targets: ^[dynamic]Target, allocator: runtime.Allocator) -> (err: Document_Error, ok: bool) {
	err = {kind = .No_Memory}
	for e, i in list.edits {
		switch e.op {
		case .Insert:
			push(groups, Target{node = e.node, edit = i, at = e.at}) or_return
		case .Remove:
			push(targets, Target{node = e.node, edit = i}) or_return
		case .Set:
			// A set replaces the node's own bytes, apart from the comments around it.
			from := len(text^)
			push_all(text, e.text) or_return
			lo := key_start(doc.nodes[e.node])
			push(chunks, Chunk{lo = lo, hi = lo + u64(len(span(doc, e.node))), from = from, to = len(text^)}) or_return
			// A cell set to nothing that the removals leave as the record's only cell would read as no record.
			if len(e.text) == 0 && table {
				push(targets, Target{node = e.node, edit = i}) or_return
			}
		case .Set_Fact, .Remove_Fact:
		}
	}
	parents_of(doc, targets[:], groups, allocator) or_return
	slice.stable_sort_by(groups[:], proc(a, b: Target) -> bool {
		if a.node != b.node {
			return a.node < b.node
		}
		return a.at < b.at
	})
	return {}, true
}

// Collects one container's inserts and removals, checks its table width, and sorts the removal indices.
@(private)
container_cuts :: proc(doc: ^Document, list: ^Edit_List, groups: []Target, first, last: int, table: bool, entries: ^[dynamic]Entry, cuts, inserts: ^[dynamic]int) -> (err: Document_Error, ok: bool) {
	err = {kind = .No_Memory}
	collect_entries(doc, groups[first].node, entries) or_return
	empty_cell := false
	clear(cuts)
	clear(inserts)
	for k in first ..< last {
		e := list.edits[groups[k].edit]
		switch e.op {
		case .Insert:
			push(inserts, k) or_return
		case .Remove:
			p := entry_at(entries[:], e.node)
			if p < 0 {
				return {kind = .Bad_Index}, false
			}
			push(cuts, p) or_return
		case .Set:
			empty_cell = true
		case .Set_Fact, .Remove_Fact:
		}
	}
	if empty_cell && len(entries[:]) - len(cuts[:]) <= 1 {
		return {kind = .Bad_Width}, false
	}
	slice.sort_by(cuts[:], proc(a, b: int) -> bool { return a < b })
	if table && groups[first].node != ROOT && len(cuts[:]) > 0 {
		if e, good := table_cut_check(doc, groups[first].node, entries[:], cuts[:]); !good {
			return e, false
		}
	}
	return {}, true
}

// Builds the removal chunks of one container, merging adjacent removals into runs and recording each run's cut end.
@(private)
container_cut_chunks :: proc(doc: ^Document, c: u32, entries: []Entry, cuts: []int, table: bool, runs: ^[dynamic]Run, chunks: ^[dynamic]Chunk) -> (err: Document_Error, ok: bool) {
	err = {kind = .No_Memory}
	clear(runs)
	for k := 0; k < len(cuts); {
		a := cuts[k]
		b := a
		for k + 1 < len(cuts) && cuts[k+1] == b + 1 {
			k += 1
			b = cuts[k]
		}
		k += 1
		lo, hi, good := run_cut(doc, c, entries, a, b, table, chunks)
		if !good {
			return {}, false
		}
		push(chunks, Chunk{lo = lo, hi = hi, remove = true}) or_return
		push(runs, Run{first = a, last = b, hi = hi}) or_return
	}
	return {}, true
}

// Writes one container's inserts. An insert inside a removal run moves to the run's cut end, and its separator follows
// the survivors.
@(private)
place_inserts :: proc(doc: ^Document, list: ^Edit_List, groups: []Target, inserts: []int, entries: []Entry, runs: []Run, comment_nodes: []u32, table: bool, c: u32, text: ^[dynamic]u8, chunks: ^[dynamic]Chunk) -> bool {
	placed := 0
	for k in inserts {
		e := list.edits[groups[k].edit]
		at := int(e.at)
		lo, _ := slice.binary_search_by(runs, at, proc(r: Run, at: int) -> slice.Ordering {
			return .Less if r.first <= at else .Greater
		})
		run := -1
		if lo > 0 && at <= runs[lo-1].last + 1 {
			run = lo - 1
		}
		if run < 0 {
			head_new := false
			if at < len(entries) {
				_, head_new = slice.binary_search(comment_nodes, entries[at].node)
			}
			insert_chunk(doc, e, entries, table, placed == 0, head_new, text, chunks) or_return
			placed += 1
			continue
		}
		r := &runs[run]
		side := 1
		if r.last + 1 >= len(entries) {
			side = 0 if r.inserts == 0 else -1
			if (!table || c != ROOT) && r.first > 0 {
				side = -1
			}
			// A comment line at the cut's end needs a line of its own, and each record written before it ends with a
			// line end. A record separator is a line end. A delimited comment line starts with the comment byte after a
			// line end, so the byte at the cut's end is a comment exactly then.
			if table && c == ROOT && doc.comment != 0 && r.hi < u64(len(doc.src)) && doc.src[r.hi] == doc.comment &&
			   r.hi > 0 && doc.src[r.hi-1] == '\n' {
				side = 1
			}
		}
		if !write_insert(doc, e, r.hi, side, false, table, text, chunks) {
			return false
		}
		r.inserts += 1
	}
	return true
}

// Builds the chunks of every insert, remove and set, grouped by container. Each container's members are read once. A
// run of removed members is one cut, and an insert whose position is in that run moves to the cut's end.
@(private)
tree_chunks :: proc(doc: ^Document, list: ^Edit_List, text: ^[dynamic]u8, chunks: ^[dynamic]Chunk, allocator: runtime.Allocator) -> (err: Document_Error, ok: bool) {
	table := table_doc(doc)
	targets, _ := make([dynamic]Target, allocator)
	defer delete(targets)
	groups, _ := make([dynamic]Target, allocator)
	defer delete(groups)
	if e, good := tree_targets(doc, list, text, chunks, table, &groups, &targets, allocator); !good {
		return e, false
	}
	entries, _ := make([dynamic]Entry, allocator)
	defer delete(entries)
	cuts, _ := make([dynamic]int, allocator)
	defer delete(cuts)
	inserts, _ := make([dynamic]int, allocator)
	defer delete(inserts)
	runs, _ := make([dynamic]Run, allocator)
	defer delete(runs)
	comment_nodes, _ := make([dynamic]u32, 0, 8, allocator)
	defer delete(comment_nodes)
	for e in list.edits {
		if e.op == .Set_Fact && e.role == .Comment {
			push(&comment_nodes, e.node) or_return
		}
	}
	slice.sort(comment_nodes[:])
	for i := 0; i < len(groups[:]); {
		c := groups[:][i].node
		j := i
		for j < len(groups[:]) && groups[:][j].node == c {
			j += 1
		}
		if c == NO_NODE {
			return {kind = .Bad_Index}, false
		}
		if e, good := container_cuts(doc, list, groups[:], i, j, table, &entries, &cuts, &inserts); !good {
			return e, false
		}
		if e, good := container_cut_chunks(doc, c, entries[:], cuts[:], table, &runs, chunks); !good {
			return e, false
		}
		if !place_inserts(doc, list, groups[:], inserts[:], entries[:], runs[:], comment_nodes[:], table, c, text, chunks) {
			return {kind = .No_Memory}, false
		}
		i = j
	}
	return {}, true
}

// Returns the cut of a run that has a member after it. The separator that joins the member before may be after the
// run's own comments, and the next member's own comments come before its separator.
@(private)
cut_with_next :: proc(doc: ^Document, c: u32, entries: []Entry, a, b: int, chunks: ^[dynamic]Chunk) -> (lo, hi: u64, ok: bool) {
	next := entries[b+1]
	lo, hi = entries[a].lo, next.lo
	if comma, found := trivia_byte(doc, entries[a].node, lo, value_lo(doc, c, entries[a].node), ','); found {
		// The run's first member has a head fact before the separator comma. The fact goes with the member, and the
		// comma stays to join the member before the run to the one after it.
		if lo < comma {
			if _, good := push(chunks, Chunk{lo = lo, hi = comma, remove = true}); !good {
				return 0, 0, false
			}
		}
		lo = comma + 1
	}
	if comma, found := trivia_byte(doc, next.node, next.lo, value_lo(doc, c, next.node), ','); found {
		if !cut_byte(chunks, comma) {
			return 0, 0, false
		}
	}
	// A member before the run keeps its bytes on the run's first line, and the next member's head comment keeps its
	// own, so the cut stops before the line end that ends it.
	if a > 0 && next.lo < value_lo(doc, c, next.node) {
		q := next.lo
		for q > lo && (doc.src[q-1] == ' ' || doc.src[q-1] == '\t') {
			q -= 1
		}
		lead_end := q
		if ls, eol, has_eol := line_start(doc.src, q, !table_doc(doc)); has_eol && ls == q {
			lead_end = eol
		}
		if lead_end > lo {
			hi = lead_end
			// The separator on the comment's line is removed with the run, so the member before it stays joined to
			// the member after.
			if comma, found := trivia_byte(doc, next.node, hi, next.lo, ','); found {
				if !cut_byte(chunks, comma) {
					return 0, 0, false
				}
			}
		}
	}
	return lo, hi, true
}

// Returns the cut of a run at the end of its container. A fact of the member before that comes after the separator
// stays, so the cut starts after that fact's line. The removed members' own facts after their trailing separator are
// removed as separate chunks.
@(private)
cut_before :: proc(doc: ^Document, c: u32, entries: []Entry, a, b: int, chunks: ^[dynamic]Chunk) -> (lo, hi: u64, ok: bool) {
	prev := entries[a-1]
	lo, hi = prev.hi, entries[b].hi
	for f in all_facts(doc, prev.node) {
		if f.lo < prev.hi || f.lo >= entries[a].lo {
			continue
		}
		if lo < f.lo {
			if _, good := push(chunks, Chunk{lo = lo, hi = f.lo, remove = true}); !good {
				return 0, 0, false
			}
		}
		lo = f.lo + u64(f.n)
	}
	// A member's inline fact lies after the comma that follows its value, so `entry_hi` stops at that comma and the
	// fact is outside the run's one cut. It is the member's own fact and goes with the member. The comma and the line
	// end stay, so the output still reads.
	for f in all_facts(doc, entries[b].node) {
		if f.lo < hi {
			continue
		}
		if _, good := push(chunks, Chunk{lo = f.lo, hi = f.lo + u64(f.n), remove = true}); !good {
			return 0, 0, false
		}
	}
	// A line comment just before the run would extend over what follows, so the cut keeps its line end.
	if e := line_end_len(doc.src, lo, true); e > lo && e <= hi {
		lo = e
	}
	return lo, hi, true
}

// Returns the cut of a run that empties its container. The foot stays before the close, and a separator after the foot
// joined it to a member that is gone.
@(private)
cut_all :: proc(doc: ^Document, c: u32, entries: []Entry, chunks: ^[dynamic]Chunk) -> (lo, hi: u64, ok: bool) {
	lo, hi = interior(doc, c)
	close := hi
	for f in all_facts(doc, c) {
		if f.role != .Comment_Foot || f.lo <= lo || f.lo >= close {
			continue
		}
		hi = f.lo
		if comma, found := trivia_byte(doc, c, f.lo + u64(f.n), close, ','); found {
			if !cut_byte(chunks, comma) {
				return 0, 0, false
			}
		}
		break
	}
	return lo, hi, true
}

// Returns the source range a run of removed members `a` through `b` writes over. A member after the run gives the
// separator to the cut. Otherwise the separator before the run is removed with it, and an emptied container keeps its
// brackets and its foot.
@(private)
run_cut :: proc(doc: ^Document, c: u32, entries: []Entry, a, b: int, table: bool, chunks: ^[dynamic]Chunk) -> (lo, hi: u64, ok: bool) {
	switch {
	case table && c == ROOT:
		// A record's extent starts at its own comments, so they are removed with the record.
		lo, hi = entries[a].lo, entries[b].hi
	case b + 1 < len(entries):
		return cut_with_next(doc, c, entries, a, b, chunks)
	case a > 0:
		return cut_before(doc, c, entries, a, b, chunks)
	case:
		return cut_all(doc, c, entries, chunks)
	}
	return lo, hi, true
}

// Checks the removals a delimited text's record needs: it keeps a cell that reads, and its width keeps a value the
// table can follow.
@(private)
table_cut_check :: proc(doc: ^Document, c: u32, entries: []Entry, cuts: []int) -> (Document_Error, bool) {
	l := len(entries)
	if len(cuts) >= l || l >= table_width(doc) && !sole_record(doc, c) {
		return {kind = .Bad_Width}, false
	}
	// A record of one cell that reads as none is refused, since an empty line is no record.
	if len(cuts) == l - 1 {
		left := 0
		for left < len(cuts) && cuts[left] == left {
			left += 1
		}
		if entries[left].hi == entries[left].lo {
			return {kind = .Bad_Width}, false
		}
	}
	return {}, true
}

// Returns the position of member node `node` among `entries`, or -1 when it is absent.
@(private)
entry_at :: proc(entries: []Entry, node: u32) -> int {
	i, found := slice.binary_search_by(entries, node, proc(e: Entry, n: u32) -> slice.Ordering {
		return slice.cmp(e.node, n)
	})
	return i if found else -1
}

// A `Target` names a node a group of edits works on, a container for an insert or a removed member, with the edit that
// named it. An insert's `at` orders it against the other inserts of its container.
@(private)
Target :: struct {
	node: u32,
	edit: int,
	at:   u32,
}

// Fills `groups` with the parent of each target within the document's node range, in one preorder pass: the targets
// are sorted and the open containers are kept on a stack, so no node array is built. The root as a target has parent
// `NO_NODE`, and a target past the last node is not added.
@(private)
parents_of :: proc(doc: ^Document, targets: []Target, groups: ^[dynamic]Target, allocator: runtime.Allocator) -> bool {
	if len(targets) == 0 {
		return true
	}
	slice.sort_by(targets, proc(a, b: Target) -> bool { return a.node < b.node })
	stack, _ := make([dynamic]u32, allocator)
	defer delete(stack)
	k := 0
	for i in 0 ..< len(doc.nodes) {
		for len(stack[:]) > 0 {
			top := stack[:][len(stack[:]) - 1]
			if u64(top) + u64(doc.nodes[top].n) > u64(i) {
				break
			}
			pop(&stack)
		}
		for k < len(targets) && targets[k].node == u32(i) {
			parent := NO_NODE
			if len(stack[:]) > 0 {
				parent = stack[:][len(stack[:]) - 1]
			}
			push(groups, Target{node = parent, edit = targets[k].edit, at = targets[k].at}) or_return
			k += 1
		}
		n := doc.nodes[i]
		if n.kind == .Array || n.kind == .Map {
			push(&stack, u32(i)) or_return
		}
	}
	return true
}

// Copies an edit's key and text into one allocation, then appends the edit to the log. A refused append frees the
// copy.
@(private)
edit_add :: proc(list: ^Edit_List, node: u32, op: Edit_Op, role: Role, at: u32, key, text: []u8) -> Document_Error {
	k, t: []u8
	owned: []u8
	if n := len(key) + len(text); n > 0 {
		fresh, err := make([]u8, n, list.allocator)
		if err != nil {
			return {kind = .No_Memory}
		}
		copy(fresh, key)
		copy(fresh[len(key):], text)
		owned = fresh
		if len(key) > 0 {
			k = fresh[:len(key)]
		}
		if len(text) > 0 {
			t = fresh[len(key):]
		}
	}
	if _, err := append(&list.edits, Edit{node = node, op = op, role = role, at = at, key = k, text = t}); err != nil {
		if owned != nil {
			delete(owned, list.allocator)
		}
		return {kind = .No_Memory}
	}
	return {}
}

// Pushes the removal of the single byte at `pos`.
@(private)
cut_byte :: proc(chunks: ^[dynamic]Chunk, pos: u64) -> bool {
	_, good := push(chunks, Chunk{lo = pos, hi = pos + 1, remove = true})
	return good
}

@(private)
push :: proc(d: ^[dynamic]$T, v: T) -> (int, bool) {
	count, err := append(d, v)
	return count, err == nil
}

@(private)
push_all :: proc(d: ^[dynamic]$T, vs: []T) -> (count: int, ok: bool) {
	for v in vs {
		if _, good := push(d, v); !good {
			return 0, false
		}
	}
	return len(vs), true
}
