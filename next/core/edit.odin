package core

import "base:runtime"
import "core:bytes"
import "core:slice"

// The edit list: a log of edits kept apart from an immutable document. A document does not change after its build,
// and no reader sees an edit until the caller commits and builds the output again in one walk. Any number of lists
// may share one document, each with its own edits.
//
// `set`, `insert` and `remove` append an edit, checked when it is recorded, at O(its text). A commit resolves every
// edit to a source range, refuses the ones that collide, and splices the edits into the source: every byte no edit
// touched stays, and the format's `Edit_Spelling` supplies the separators.

// What an edit does to the node it names.
Edit_Op :: enum u8 {
	Set, // the node's own bytes become `text`
	Insert, // `text`, with `key` for a member, is inserted into the container at `at`
	Remove, // removes the member the node is, and its key
	Set_Fact, // every fact of the node with `role` becomes `text`
	Remove_Fact, // every fact of the node with `role` is removed
}

// A commit's `as` value for the document's own spec.
SPEC_DEFAULT :: u8(max(u8))

// A recorded edit. `node` names a node of the document the list was made with: a value or a key for `Set`, a
// container for `Insert`, a value that is a member of a container for `Remove`, and any node but a key for the fact
// edits, whose `role` says which facts they change. `at` is an insert's position, 0 through the container's length at
// the time the edit was recorded. `key` is a member insert's name and `text` is the value, a record, a cell or a
// fact's body, each a copy the list owns.
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

// Whether a document's containers hold a table's records and cells rather than a tree's values. The edit service
// that reads a record distinguishes the two: a format with no `record` service builds a tree.
@(private)
table_doc :: #force_inline proc(doc: ^Document) -> bool {
	return doc.spelling.edit != nil && doc.spelling.edit.record != nil
}

// Checks a recorded text as a key, a value, or a table's cell. The empty text is the empty cell, which no table
// reads as a record on its own.
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
// and in a delimited text a cell is no key, so its text is checked as a value. A container, an `End` node or a fact
// node returns `.Bad_Index`. Runs in O(len(text)), checking the text once and copying it once.
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
		// A record's width is its table's, so a cell may join it only while the count stays at most the table's
		// width, or when the table holds no other record and follows this one.
		if table && !(n_members + 1 <= table_width(doc) || sole_record(doc, container)) {
			return {kind = .Bad_Width}
		}
	}
	return edit_add(list, container, .Insert, .Value, u32(at), key, text)
}

// Appends the removal edit. The commit removes the member with its key and one adjacent separator. A delimited
// text's record is removed with its line end, and a record's cell when the table still reads.
remove :: proc(list: ^Edit_List, node: u32) -> Document_Error {
	_, n, err := node_of(list, node)
	// A key and a delimited text's header row are no member of their own: a key is removed with its value.
	if err.kind != .None || node == ROOT || n.kind == .End || n.role != .Value {
		return {kind = .Bad_Index}
	}
	return edit_add(list, node, .Remove, .Value, 0, nil, nil)
}

// Makes `text` the body of every fact of node `node` and `role`. A `Comment_Inline` body is one line, and the two
// line roles may hold line ends. The role decides the body's shape. Runs in O(len(text)), checking the shape once
// and copying the text once.
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
// node and role is recorded. A role core does not handle is refused with `.Bad_Fact`, not `.Bad_Index`.
@(private)
fact_node :: proc(list: ^Edit_List, node: u32, role: Role, text: []u8) -> Document_Error {
	_, n, err := node_of(list, node)
	if err.kind != .None || n.role == .Key || role <= .Key || n.kind == .End {
		return {kind = .Bad_Index}
	}
	#partial switch role {
	case .Comment, .Comment_Foot:
	case .Comment_Inline:
		if bytes.index_byte(text, '\n') >= 0 || bytes.index_byte(text, '\r') >= 0 {
			return {kind = .Bad_Fact}
		}
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

// Whether the output can hold a fact of `role` on `node`. An output with no marker holds none. A delimited text
// holds a `Comment_Foot` on the root only and a `Comment` on a record, which is a value that is an `Array` or a
// `Map`. The role's shape and the body's spelling are checked where the fact is written.
@(private)
fact_slot :: #force_inline proc(doc: ^Document, node: u32, role: Role, style: Comment_Spelling) -> bool {
	if style == .None {
		return false
	}
	if !table_doc(doc) {
		return true
	}
	#partial switch role {
	case .Comment_Foot:
		return node == ROOT
	case .Comment:
		if node == ROOT || int(node) >= len(doc.nodes) {
			return false
		}
		n := doc.nodes[node]
		return n.role == .Value && (n.kind == .Array || n.kind == .Map)
	}
	return false
}

// Returns the source bytes the edits make: every byte no edit touched, the edits' texts in their places, and the
// separators the format supplies. The caller frees the result with `allocator`. An edit that another edit covers, a
// second edit of one node, and an insert at or inside a removal's range return `.Conflicting_Edits` at the byte
// where the two meet. The format checks the result under `as`. A text that fails even the tolerant read returns
// `.Bad_Result`. A text that reads only with tolerance is accepted only when `as` is the document's spec and the
// source also fails the strict read. Under another spec the source's reading is no evidence, so the output must
// read strictly. A fact `as` cannot hold is dropped with its source bytes, and `dropped` counts the facts left out.
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

	slice.stable_sort_by(chunks[:], proc(a, b: Chunk) -> bool {
		if a.lo != b.lo {
			return a.lo < b.lo
		}
		// An insert at a byte comes before the bytes there, so it is spliced before what it precedes.
		return a.insert && !b.insert
	})
	at := u64(0)
	prev_lo, prev_hi := u64(0), u64(0)
	have := false
	cuts := false
	for i := 0; i < len(chunks); {
		c := chunks[i]
		if !c.insert {
			// Two edits of one node write the same bytes even when the node is empty, and the bytes of a removal
			// stay empty. Both are found in the sorted chunk walk.
			if have && (c.lo < at || c.lo == prev_lo && c.hi == prev_hi) {
				return nil, 0, {kind = .Conflicting_Edits, at = c.lo}
			}
			at = c.hi
			prev_lo, prev_hi = c.lo, c.hi
			have = true
			cuts = c.remove
			i += 1
			continue
		}
		// An insert inside what another edit replaces conflicts, and so does one at or inside a removal's range: the
		// separator the insert counted on is removed with the range.
		p := c.lo
		if have && c.fact && cuts && p < at {
			// A fact on the member after a removed run was at a line start the removal covers: it goes after the
			// run, on a line of its own.
			from := len(text)
			push(&text, '\n')
			push_all(&text, text[c.from:c.to])
			c.lo, c.hi = at, at
			c.from, c.to = from, len(text)
			chunks[i] = c
			p = at
		}
		if have && (p < at || cuts && p == at && !c.fact) {
			return nil, 0, {kind = .Conflicting_Edits, at = p}
		}
		j := i
		for j < len(chunks) && chunks[j].insert && chunks[j].lo == p {
			j += 1
		}
		// An edit that replaces no byte there conflicts too, as a set of an empty cell does.
		if j < len(chunks) && chunks[j].lo == p && (chunks[j].remove || chunks[j].hi == p) {
			return nil, 0, {kind = .Conflicting_Edits, at = p}
		}
		i = j
	}

	out, err = splice(doc, chunks[:], text[:], allocator)
	if err.kind != .None {
		return nil, 0, err
	}
	// The output must read as strictly as the source. A text that needs a tolerance only the source needed is the
	// edit's own defect. A tolerance is accepted only when the output keeps the document's spec, since under another
	// spec the source's own reading is no evidence and the output must read strictly. A text that fails even the
	// format's tolerant read returns `.Bad_Result`.
	if edit := doc.spelling.edit; edit != nil && edit.reads != nil {
		if f, faulted := edit.reads(doc, out, false, spec); faulted {
			if g, still := edit.reads(doc, out, true, spec); still {
				delete(out, allocator)
				return nil, 0, {kind = .Bad_Result, inner = g}
			}
			if spec != doc.spec {
				delete(out, allocator)
				return nil, 0, {kind = .Bad_Result, inner = f}
			}
			if _, src_bad := edit.reads(doc, doc.src, false, spec); !src_bad {
				delete(out, allocator)
				return nil, 0, {kind = .Bad_Result, inner = f}
			}
		}
	}
	return out, dropped, {}
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
// `remove` marks a chunk that writes no text. `fact` marks a fact's insert, which may lie at a removed run's edge
// where another insert would conflict.
@(private)
Chunk :: struct {
	lo, hi: u64,
	from:   int,
	to:     int,
	insert: bool,
	remove: bool,
	fact:   bool,
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

// Whether the bytes before `pos` end inside a comment, which would swallow what a splice writes there. A fact whose
// `spelling` gives no tail marker runs to the line's end, and a delimited text's line may also start with its
// comment byte and hold no line end.
@(private)
ends_in_comment :: proc(doc: ^Document, v: u32, pos: u64) -> bool {
	if doc.comment != 0 && pos > 0 && pos <= u64(len(doc.src)) {
		if last := doc.src[pos-1]; last != '\n' && last != '\r' {
			lo, _ := line_of(doc.src, pos)
			if doc.src[lo] == doc.comment {
				return true
			}
		}
	}
	for f in all_facts(doc, v) {
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
	// A delimited text's comment line is no part of a record: the line stays when the record is removed.
	if !table_doc(doc) {
		for f in all_facts(doc, v) {
			if f.lo < lo {
				lo = f.lo
			}
		}
	}
	return lo
}

// Returns one past the last byte of member `v`, including the comments after its value. A comment after the comma
// that follows the member is no part of it: the member's extent stops at that comma, so a cut removes the
// separator.
@(private)
entry_hi :: proc(doc: ^Document, v: u32) -> u64 {
	hi := key_start(doc.nodes[v]) + u64(len(span(doc, v)))
	if table_doc(doc) {
		return hi
	}
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

// A member of a container as a commit reads it: the value's node, the first byte an insert or a removal writes from,
// and one past the last.
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

// Builds the chunk of one insert: the member's bytes and the separators around it. A container's first member gets
// no separator before it, and each later member gets the separator on the side of the member it joins.
@(private)
insert_chunk :: proc(doc: ^Document, e: Edit, entries: []Entry, table, first_empty: bool, text: ^[dynamic]u8, chunks: ^[dynamic]Chunk) -> bool {
	c := e.node
	n := len(entries)
	// A table's cell separator is the document's `delimiter`, so a text read with `;` writes `;`. The byte is built
	// here so the chunks copy one byte.
	cell_sep: [1]u8
	sep := doc.spelling.edit.member_sep
	if table && c == ROOT {
		if doc.spelling.edit.record_sep == nil {
			return false
		}
		sep = doc.spelling.edit.record_sep(doc)
	} else if table {
		cell_sep[0] = doc.delimiter
		sep = string(cell_sep[:])
	}
	side: int // -1 before the member, 0 alone, 1 after it
	pos: u64
	leading := false
	switch {
	case n > 0 && int(e.at) < n:
		pos = entries[e.at].lo
		// A new member goes before the comments that lead its member, so those comments stay with that member. A
		// delimited text's comment lines are not in its record's extent, so they are read here.
		if table {
			// A headed text's first record's comments come after its header row. A line above the header is no
			// record's leading comment, so the insert stays after the header.
			hdr_end := u64(0)
			if c == ROOT && doc.header != 0 {
				hdr_end = doc.spelling.close_end(doc, doc.header)
			}
			for f in all_facts(doc, entries[e.at].node) {
				if f.role == .Comment && f.lo >= hdr_end && f.lo < pos {
					pos = f.lo
					leading = true
				}
			}
		} else {
			leading = pos < value_lo(doc, c, entries[e.at].node)
		}
		// The separator that joins the member before lies on one side of this member's own comments. The new member
		// gets the separator on the other side, so each pair is joined once.
		side = -1 if int(e.at) > 0 && !table && bytes.index_byte(doc.src[entries[e.at-1].hi:pos], ',') < 0 else 1
	case table && c == ROOT && (n > 0 || doc.header != 0):
		// A delimited text's records are separated by the line end of the record before them, which the last record
		// may not have. A header occupies the place the last record would.
		pos = entries[n-1].hi if n > 0 else doc.spelling.close_end(doc, doc.header)
		side = -1 if pos == 0 || doc.src[pos-1] != '\n' else 1
	case n > 0:
		pos = entries[n-1].hi
		if !table {
			// A trailing comma is the separator the new member needs: the member goes before the close, after that
			// comma and any comment on it, so no other separator is written.
			_, close := interior(doc, c)
			if _, found := trivia_byte(doc, entries[n-1].node, pos, close, ','); found {
				pos = close
				side = 0
				break
			}
			if ends_in_comment(doc, entries[n-1].node, pos) {
				// A line comment ends its line, so the new member starts the next one, after the line end the text
				// has.
				pos = line_end_len(doc.src, pos, true)
			}
			side = -1
			break
		}
		side = -1
	case:
		// An empty container writes the member alone, or after a separator another edit put there.
		_, pos = interior(doc, c)
		if table {
			// A text whose last line is a comment with no line end must not swallow the record: the record starts
			// on a new line, and the comment line keeps its own bytes.
			side = -1 if c == ROOT && ends_in_comment(doc, NO_NODE, pos) else 1
		} else if !first_empty {
			side = -1
		}
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
	// A tree member's insert before leading comments gets a line of its own, so those comments stay on their
	// member and keep the role the walk gave them. A record's separator ends its line already.
	if leading && !table {
		push(text, '\n') or_return
	}
	push(chunks, Chunk{lo = pos, hi = pos, from = from, to = len(text^), insert = true}) or_return
	return true
}

// Whether `list` holds a fact edit of `node` and `role`, so a source fact of that node and role is replaced or
// removed by the edit.
@(private)
fact_named :: proc(list: ^Edit_List, node: u32, role: Role) -> bool {
	for e in list.edits {
		if e.op >= .Set_Fact && e.node == node && e.role == role {
			return true
		}
	}
	return false
}

// Whether `body` holds a line end: LF, CR, or a Unicode line separator. `line_end_len` reads all three, so no role
// needs its own test.
@(private)
body_line_end :: #force_inline proc(body: []u8) -> bool {
	for i in 0 ..< len(body) {
		if line_end_len(body, u64(i), true) > u64(i) {
			return true
		}
	}
	return false
}

// Whether a comment spelled `style` can hold `body`. A line comment holds no line end, a block comment holds a line
// end but no `*/`, and a comment byte's line holds no line end.
@(private)
fact_body_held :: proc(style: Comment_Spelling, body: []u8) -> bool {
	switch style {
	case .None:
		return false
	case .Byte:
		return !body_line_end(body)
	case .Line:
		if !body_line_end(body) {
			return true
		}
		for i in 0 ..< max(0, len(body) - 1) {
			if body[i] == '*' && body[i+1] == '/' {
				return false
			}
		}
		return true
	}
	return false
}

// Builds the chunks of every fact edit and of every source fact the output cannot hold. Such a fact is dropped with
// its source bytes, and `dropped` counts it.
@(private)
fact_chunks :: proc(doc: ^Document, list: ^Edit_List, style: Comment_Spelling, text: ^[dynamic]u8, chunks: ^[dynamic]Chunk, dropped: ^int) -> bool {
	// A new first record gets the comment line above a header row. That line cannot stay with the old first
	// record, so it is dropped and counted rather than moved onto the new one.
	header_insert := false
	for e in list.edits {
		if e.op == .Insert && e.node == ROOT && e.at == 0 {
			header_insert = true
		}
	}
	for f in doc.facts {
		if fact_named(list, f.node, f.role) {
			continue
		}
		if header_insert && table_doc(doc) && doc.header != 0 && f.role == .Comment && f.lo < doc.nodes[doc.header].lo {
			push(chunks, Chunk{lo = f.lo, hi = f.lo + u64(f.n), remove = true}) or_return
			dropped^ += 1
			continue
		}
		if !fact_slot(doc, f.node, f.role, style) || f.role == .Comment_Foot && !foot_still_last(doc, list, f.node) {
			push(chunks, Chunk{lo = f.lo, hi = f.lo + u64(f.n), remove = true}) or_return
			dropped^ += 1
		}
	}
	for e in list.edits {
		if e.op >= .Set_Fact {
			fact_edit_chunks(doc, list, style, e, text, chunks, dropped) or_return
		}
	}
	return true
}

@(private)
fact_edit_chunks :: proc(doc: ^Document, list: ^Edit_List, style: Comment_Spelling, e: Edit, text: ^[dynamic]u8, chunks: ^[dynamic]Chunk, dropped: ^int) -> bool {
	facts := all_facts(doc, e.node)
	slot := fact_slot(doc, e.node, e.role, style)
	if e.role == .Comment_Foot && !foot_still_last(doc, list, e.node) {
		slot = false
	}
	if e.op == .Remove_Fact || !slot {
		// A removal the output cannot hold removes its source facts with it, and a set the output cannot hold
		// counts even when no source fact was there.
		taken := 0
		for f in facts {
			if f.role != e.role {
				continue
			}
			push(chunks, Chunk{lo = f.lo, hi = f.lo + u64(f.n), remove = true}) or_return
			taken += 1
		}
		if !slot {
			dropped^ += taken
			dropped^ += 1 if e.op == .Set_Fact && taken == 0 else 0
		}
		return true
	}
	if !fact_body_held(style, e.text) {
		// The output cannot hold the body in either spelling, so the fact is dropped, and so are the source facts
		// it replaces.
		taken := 0
		for f in facts {
			if f.role != e.role {
				continue
			}
			push(chunks, Chunk{lo = f.lo, hi = f.lo + u64(f.n), remove = true}) or_return
			taken += 1
		}
		dropped^ += max(taken, 1)
		return true
	}
	from := len(text^)
	taken := 0
	for f in facts {
		if f.role != e.role {
			continue
		}
		if taken == 0 {
			hi := f.lo + u64(f.n)
			tail := hi >= u64(len(doc.src)) || doc.src[hi] != '\n' && doc.src[hi] != '\r'
			fact_append(doc, style, e.role, e.text, nil, false, tail, text) or_return
			push(chunks, Chunk{lo = f.lo, hi = hi, from = from, to = len(text^)}) or_return
		} else {
			push(chunks, Chunk{lo = f.lo, hi = f.lo + u64(f.n), remove = true}) or_return
		}
		taken += 1
	}
	if taken > 0 {
		return true
	}
	pos, indent, lead, ok := fact_pos(doc, style, e.node, e.role)
	if !ok {
		dropped^ += 1
		return true
	}
	from = len(text^)
	tail := pos >= u64(len(doc.src)) || doc.src[pos] != '\n' && doc.src[pos] != '\r'
	fact_append(doc, style, e.role, e.text, indent, lead, tail, text) or_return
	push(chunks, Chunk{lo = pos, hi = pos, from = from, to = len(text^), insert = true, fact = true}) or_return
	return true
}

// Returns the first byte at or past `pos` that is no whitespace and no fact of `node`: the separator or close after
// a value.
@(private)
next_trivia :: proc(doc: ^Document, node: u32, pos: u64) -> u64 {
	q := pos
	facts := all_facts(doc, node)
	k := 0
	for k < len(facts) && facts[k].lo + u64(facts[k].n) <= q {
		k += 1
	}
	for q < u64(len(doc.src)) {
		if k < len(facts) && facts[k].lo == q {
			q += u64(facts[k].n)
			k += 1
			continue
		}
		c := doc.src[q]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f' {
			q += 1
			continue
		}
		if c == 0xE2 && q + 2 < u64(len(doc.src)) && doc.src[q+1] == 0x80 && doc.src[q+2] | 1 == 0xA9 {
			q += 3
			continue
		}
		break
	}
	return q
}

// Returns the first byte of the line holding `pos` and the first byte past the whitespace that starts that line.
// `ends_in_comment` and `fact_pos` both use it.
@(private)
line_of :: #force_inline proc(src: []u8, pos: u64) -> (lo, indent_hi: u64) {
	lo = pos
	for lo > 0 && src[lo-1] != '\n' && src[lo-1] != '\r' {
		lo -= 1
	}
	indent_hi = lo
	for indent_hi < pos && (src[indent_hi] == ' ' || src[indent_hi] == '\t') {
		indent_hi += 1
	}
	return
}

// Whether a foot on `node` is still on a last member after this list's inserts. An insert into an enclosing
// container may make that member not last, and a foot has no other place, so the commit drops it.
@(private)
foot_still_last :: proc(doc: ^Document, list: ^Edit_List, node: u32) -> bool {
	if table_doc(doc) || node == ROOT || int(node) >= len(doc.nodes) {
		return true
	}
	for e in list.edits {
		if e.op != .Insert || int(e.node) >= len(doc.nodes) {
			continue
		}
		n := doc.nodes[e.node]
		if (n.kind == .Array || n.kind == .Map) && e.node < node && node < e.node + n.n {
			return false
		}
	}
	return true
}

// Returns where a new fact of `role` goes, the indent its line gets, and whether a line end must precede it, or
// false when the output cannot hold it there. A head comment goes above its node's line, an inline one after the
// value's separator, and a foot one after the last value of a container or inside an empty one. A delimited text's
// comment line starts the record's line, and its foot goes after the last record.
@(private)
fact_pos :: proc(doc: ^Document, style: Comment_Spelling, node: u32, role: Role) -> (pos: u64, indent: []u8, lead: bool, ok: bool) {
	n := doc.nodes[node]
	#partial switch role {
	case .Comment:
		p := key_start(n)
		// A delimited text's header cell before a record is no key of the record.
		if !table_doc(doc) && node > 0 && doc.nodes[node-1].role == .Key && doc.nodes[node-1].kind <= .Plain {
			p = key_start(doc.nodes[node-1])
		}
		lo, hi := line_of(doc.src, p)
		// A byte-order mark remains the text's first byte.
		if lo == 0 && p >= text_start(doc.src, 0) {
			lo = text_start(doc.src, 0)
		}
		// A line start inside a block comment is no place for a line comment, so the fact goes after that comment.
		for f in doc.facts {
			if f.lo < lo && lo < f.lo + u64(f.n) && f.spelling >> 8 == 2 {
				return f.lo + u64(f.n), nil, true, true
			}
		}
		if style == .Byte {
			return lo, nil, false, true
		}
		// Something before the node on its line, as an open bracket is, puts the comment after it, on a line of its
		// own. Otherwise the comment gets the line's indent.
		if hi < p {
			return p, nil, true, true
		}
		return lo, doc.src[lo:hi], false, true
	case .Comment_Inline:
		hi := key_start(n) + u64(len(span(doc, node)))
		q := hi
		for q < u64(len(doc.src)) && (doc.src[q] == ' ' || doc.src[q] == '\t') {
			q += 1
		}
		// The comment goes after the separator on the value's line, so the separator keeps its line.
		if q < u64(len(doc.src)) && doc.src[q] == ',' {
			hi = q + 1
		}
		return hi, nil, false, true
	case .Comment_Foot:
		if table_doc(doc) {
			// A delimited text's foot belongs to the root alone, after its last record.
			if node != ROOT {
				return 0, nil, false, false
			}
			hi := u64(len(doc.src))
			return hi, nil, hi > 0 && doc.src[hi-1] != '\n' && doc.src[hi-1] != '\r', true
		}
		if (n.kind == .Array || n.kind == .Map) && length(doc, node) == 0 {
			lo, _ := interior(doc, node)
			return lo, nil, false, true
		}
		hi := key_start(n) + u64(len(span(doc, node)))
		// A value with a separator after it, on its line or a later one, is not the last value of its container.
		if q := next_trivia(doc, node, hi); q < u64(len(doc.src)) && doc.src[q] == ',' {
			return 0, nil, false, false
		}
		// The foot goes after the value's line, before the close. No fact's body is a place for one, and a line end
		// inside a block comment is no line end of the value.
		q := hi
		for q < u64(len(doc.src)) {
			skipped := false
			for f in doc.facts {
				if f.lo <= q && q < f.lo + u64(f.n) {
					q = f.lo + u64(f.n)
					skipped = true
					break
				}
			}
			if skipped {
				continue
			}
			switch doc.src[q] {
			case '\n', '\r':
				return line_end_len(doc.src, q, true), nil, false, true
			case ']', '}':
				return q, nil, true, true
			}
			if end := line_end_len(doc.src, q, true); end > q {
				return end, nil, false, true
			}
			q += 1
		}
		return q, nil, q > 0 && doc.src[q-1] != '\n' && doc.src[q-1] != '\r', true
	case:
		return 0, nil, false, false
	}
}

// Writes a fact body as the output spells it: `//body` for a line comment, `/*body*/` for a body holding a line
// end, or the document's comment byte before `body` on its own line. `tail` adds the line end a line marker needs to
// stop at, and is false when the text already has one there.
@(private)
fact_append :: proc(doc: ^Document, style: Comment_Spelling, role: Role, body: []u8, indent: []u8, lead, tail: bool, text: ^[dynamic]u8) -> bool {
	if lead {
		push(text, '\n') or_return
	}
	push_all(text, indent) or_return
	if role == .Comment_Inline {
		push(text, ' ') or_return
	}
	switch style {
	case .Line:
		if body_line_end(body) {
			push_all(text, transmute([]u8)string("/*")) or_return
			push_all(text, body) or_return
			push_all(text, transmute([]u8)string("*/")) or_return
			return true
		}
		push_all(text, transmute([]u8)string("//")) or_return
		push_all(text, body) or_return
	case .Byte:
		push(text, doc.comment) or_return
		push_all(text, body) or_return
	case .None:
		return false
	}
	if tail {
		push(text, '\n') or_return
	}
	return true
}

// Builds the chunks of every insert and remove, grouped by container. Each container's members are read once, so a
// commit is O(len(src)), and a run of removed members is one cut. Fact edits are spliced apart from the tree's: each
// removes the source bytes of the facts it names, and a new fact is placed by the role's own rule.
@(private)
chunk_edits :: proc(doc: ^Document, list: ^Edit_List, spec: u8, text: ^[dynamic]u8, chunks: ^[dynamic]Chunk, dropped: ^int, allocator: runtime.Allocator) -> (err: Document_Error, ok: bool) {
	err = {kind = .No_Memory}
	table := table_doc(doc)
	style, _ := comment_style(doc, spec)
	targets, _ := make([dynamic]Target, allocator)
	defer delete(targets)
	groups, _ := make([dynamic]Target, allocator)
	defer delete(groups)
	for e, i in list.edits {
		switch e.op {
		case .Insert:
			push(&groups, Target{node = e.node, edit = i}) or_return
		case .Remove:
			push(&targets, Target{node = e.node, edit = i}) or_return
		case .Set:
			// A set replaces the node's own bytes, apart from the comments around it.
			from := len(text^)
			push_all(text, e.text) or_return
			lo := key_start(doc.nodes[e.node])
			push(chunks, Chunk{lo = lo, hi = lo + u64(len(span(doc, e.node))), from = from, to = len(text^)}) or_return
			// A cell set to nothing that the removals leave as the record's only cell would read as no record.
			if len(e.text) == 0 && table {
				push(&targets, Target{node = e.node, edit = i}) or_return
			}
		case .Set_Fact, .Remove_Fact:
		}
	}
	parents_of(doc, targets[:], &groups, allocator) or_return
	slice.stable_sort_by(groups[:], proc(a, b: Target) -> bool { return a.node < b.node })
	entries, _ := make([dynamic]Entry, allocator)
	defer delete(entries)
	cuts, _ := make([dynamic]int, allocator)
	defer delete(cuts)
	for i := 0; i < len(groups[:]); {
		c := groups[:][i].node
		j := i
		for j < len(groups[:]) && groups[:][j].node == c {
			j += 1
		}
		if c == NO_NODE {
			return {kind = .Bad_Index}, false
		}
		collect_entries(doc, c, &entries) or_return
		// An empty container writes its first member alone, so a second member there gets the separator before it.
		placed := 0
		empty_cell := false
		clear(&cuts)
		for k in i ..< j {
			e := list.edits[groups[:][k].edit]
			switch e.op {
			case .Insert:
				insert_chunk(doc, e, entries[:], table, placed == 0, text, chunks) or_return
				placed += 1
			case .Remove:
				p := entry_at(entries[:], e.node)
				if p < 0 {
					return {kind = .Bad_Index}, false
				}
				push(&cuts, p) or_return
			case .Set:
				empty_cell = true
			case .Set_Fact, .Remove_Fact:
			}
		}
		if empty_cell && len(entries[:]) - len(cuts[:]) <= 1 {
			return {kind = .Bad_Width}, false
		}
		slice.sort_by(cuts[:], proc(a, b: int) -> bool { return a < b })
		if table && c != ROOT && len(cuts[:]) > 0 {
			if e, good := table_cut_check(doc, c, entries[:], cuts[:]); !good {
				return e, false
			}
		}
		for k := 0; k < len(cuts[:]); {
			a := cuts[:][k]
			b := a
			for k + 1 < len(cuts[:]) && cuts[:][k+1] == b + 1 {
				k += 1
				b = cuts[:][k]
			}
			k += 1
			// A run of removed members includes the separator after it when a member follows, else the separator
			// before it. A container whose every member is removed keeps only its brackets.
			lo, hi: u64
			drop_head := false
			switch {
			case table && c == ROOT:
				// A record's extent is its own line end and no comment line. A comment before or after the run is
				// no part of any record, so the cut covers exactly the records and leaves every comment line, with
				// its line end, where it was.
				lo, hi = entries[:][a].lo, entries[:][b].hi
			case b + 1 < len(entries[:]):
				next := entries[:][b+1]
				lo, hi = entries[:][a].lo, next.lo
				// A removal joins the bytes after the run to the bytes before it, which can turn a leading comment
				// into an inline one. Such comments are dropped and counted rather than moved to another value.
				drop_head = next.lo < value_lo(doc, c, next.node)
				// A separator that joins the member before may lie after the run's own comments. It stays with the
				// run, so the member before joins the member after.
				if comma, found := trivia_byte(doc, entries[:][a].node, lo, value_lo(doc, c, entries[:][a].node), ','); found {
					lo = comma + 1
				}
				// The next member's own comments come before its separator, so the cut stops before them and removes
				// the separator on its own.
				if comma, found := trivia_byte(doc, next.node, next.lo, value_lo(doc, c, next.node), ','); found {
					push(chunks, Chunk{lo = comma, hi = comma + 1, remove = true}) or_return
				}
			case a > 0:
				prev := entries[:][a-1]
				lo, hi = prev.hi, entries[:][b].hi
				// A comment of the member before that comes after the separator stays, so the cut removes the
				// separator alone and starts after that comment's line.
				for f in all_facts(doc, prev.node) {
					if f.lo < prev.hi || f.lo >= entries[:][a].lo {
						continue
					}
					if lo < f.lo {
						push(chunks, Chunk{lo = lo, hi = f.lo, remove = true}) or_return
					}
					lo = f.lo + u64(f.n)
				}
				// A line comment just before the run would swallow what follows, so its line end stays.
				if e := line_end_len(doc.src, lo, true); e > lo && e <= hi {
					lo = e
				}
			case table && c == ROOT && doc.header != 0:
				// A headed table's header is the record before the first data record, and it stays.
				lo, hi = doc.spelling.close_end(doc, doc.header), entries[:][b].hi
			case:
				lo, hi = interior(doc, c)
			}
			push(chunks, Chunk{lo = lo, hi = hi, remove = true}) or_return
			if drop_head {
				for f in all_facts(doc, entries[:][b+1].node) {
					if f.role != .Comment || f.lo >= value_lo(doc, c, entries[:][b+1].node) {
						continue
					}
					push(chunks, Chunk{lo = f.lo, hi = f.lo + u64(f.n), remove = true}) or_return
					dropped^ += 1
				}
			}
		}
		i = j
	}
	// Facts are added last, so an insert at a byte goes before the leading comments of the member there, and the
	// member and its comments keep their order.
	fact_chunks(doc, list, style, text, chunks, dropped) or_return
	return {}, true
}

// Checks the removals a delimited text's record needs: it keeps a cell that reads, and its width stays one the
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

// A node a group of edits names, a container for an insert or a removed member, with the edit that named it.
@(private)
Target :: struct {
	node: u32,
	edit: int,
}

// Fills `groups` with each target's parent, in one preorder pass: the targets are sorted and the open containers
// are kept on a stack, so no node array is built. A target the root holds, or no node at all, has parent `NO_NODE`.
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
			push(groups, Target{node = parent, edit = targets[k].edit}) or_return
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
