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
// drops it and counts it when the output cannot hold it, and refuses a second fact edit of one node and role. A fact
// no edit names keeps its bytes, in order, unless it is removed with a removed node or lies inside the span a set
// replaces, which is the only removed or replaced case. Its node and role afterwards follow the comments around it and
// are not preserved.

// An `Edit_Op` names the change an edit makes to its node.
Edit_Op :: enum u8 {
	Set, // the node's own bytes become `text`
	Insert, // `text`, with `key` for a member, is inserted into the container at `at`
	Remove, // removes the member the node is, and its key
	Set_Fact, // every fact of the node with `role` becomes `text`
	Remove_Fact, // every fact of the node with `role` is removed
}

// A recorded edit. `node` names a node of the document the list was made with: a value or a key for `Set`, a
// container for `Insert`, a value that is a member of a container for `Remove`, and any node but a key for the fact
// edits, whose `role` says which facts they change. `at` is an insert's position, 0 through the container's length at
// the time the edit was recorded. `role` is a fact edit's role, or `.Key` when an insert is a member or a set's text
// is a decoded key name. `key` is a member insert's decoded name, and `text` is a value's source text, a record, a
// cell, a key's decoded name for a key set, or a fact's body, each copied into the list's allocator.
Edit :: struct {
	node: Node_Index,
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
	edits, _ := make([dynamic]Edit, allocator)
	return {doc = doc, edits = edits, allocator = allocator}
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

// Checks a recorded text as a value. A member's key is a decoded name, so no text is judged as a key.
@(private)
judge :: proc(doc: ^Document, text: string, allocator: runtime.Allocator) -> Document_Error {
	if doc.spelling.edit != nil && doc.spelling.edit.value != nil {
		return doc.spelling.edit.value(doc, transmute([]u8)text, allocator)
	}
	return {}
}

// Returns node `node` of `list`'s document, or `.Bad_Index` when the list has no document or the index is past the
// last node.
@(private)
node_of :: proc(list: ^Edit_List, node: Node_Index) -> (doc: ^Document, n: Node, err: Document_Error) {
	doc = list.doc
	if doc == nil || int(node) >= len(doc.nodes) {
		return doc, {}, {kind = .Bad_Index}
	}
	return doc, doc.nodes[node], {}
}

// Makes `text` the source bytes of node `node`, a value or a key. A key's text is its decoded name, which the commit
// writes in the format's own spelling, a value's text is source text and must read as one value, and in a delimited
// text a cell is no key, so its text is checked as a value. A fact node or a container in a table returns `.Bad_Index`.
// Runs in O(len(text)), checking the text once and copying it once.
set :: proc(list: ^Edit_List, node: Node_Index, text: string) -> Document_Error {
	doc, n, err := node_of(list, node)
	if err.kind != .None {
		return err
	}
	table := table_doc(doc)
	// A record or a table is no single value to write: its cells are edited.
	if n.role > .Key || table && (n.kind == .Array || n.kind == .Map) {
		return {kind = .Bad_Index}
	}
	// A record or a table's cell is no key: only a tree's key node reads as one.
	if n.role == .Key && !table {
		return edit_add(list, node, .Set, .Key, 0, "", text)
	}
	if e := judge(doc, text, list.allocator); e.kind != .None {
		return e
	}
	return edit_add(list, node, .Set, .Value, 0, "", text)
}

// Inserts `text` into the array `container` before its element `at`, or after its last when `at` is its length. A
// delimited text's root accepts a record and a record accepts a cell.
@(private)
insert_value :: proc(list: ^Edit_List, container: Node_Index, at: int, text: string) -> Document_Error {
	return insert_at(list, container, at, "", false, text)
}

// Inserts `key` and `text` as a member of the object `container` before its member `at`, or after its last when
// `at` is its length.
@(private)
insert_member :: proc(list: ^Edit_List, container: Node_Index, at: int, key, text: string) -> Document_Error {
	return insert_at(list, container, at, key, true, text)
}

// `insert` is `insert_value` for an array and `insert_member` for an object.
insert :: proc {
	insert_value,
	insert_member,
}

@(private)
insert_at :: proc(list: ^Edit_List, container: Node_Index, at: int, key: string, member: bool, text: string) -> Document_Error {
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
	if member {
		if doc.spelling.edit.key_text == nil {
			return {kind = .Wrong_Container}
		}
		if e := judge(doc, text, list.allocator); e.kind != .None {
			return e
		}
	} else if doc.spelling.edit != nil && doc.spelling.edit.insert_check != nil {
		if e := doc.spelling.edit.insert_check(doc, container, text, list.allocator); e.kind != .None {
			return e
		}
	} else {
		if e := judge(doc, text, list.allocator); e.kind != .None {
			return e
		}
	}
	return edit_add(list, container, .Insert, .Key if member else .Value, u32(at), key, text)
}

// Appends the removal edit. The commit removes the member with its key and one adjacent separator. A delimited
// text's record is removed with its line end, and a record's cell when the remaining table still reads.
remove :: proc(list: ^Edit_List, node: Node_Index) -> Document_Error {
	_, n, err := node_of(list, node)
	// A key and a delimited text's header row are no member of their own: a key is removed with its value.
	if err.kind != .None || node == ROOT || n.role != .Value {
		return {kind = .Bad_Index}
	}
	return edit_add(list, node, .Remove, .Value, 0, "", "")
}

// Makes `text` the body of every fact of node `node` and `role`. A `Comment_Inline` body holds no LF or CR. A
// `Comment` or `Comment_Foot` body may. Runs in O(len(text)), checking the shape once and copying the text once.
set_fact :: proc(list: ^Edit_List, node: Node_Index, role: Role, text: string) -> Document_Error {
	if e := fact_node(list, node, role, text); e.kind != .None {
		return e
	}
	return edit_add(list, node, .Set_Fact, role, 0, "", text)
}

// Removes every fact of node `node` and `role`, with its source bytes.
remove_fact :: proc(list: ^Edit_List, node: Node_Index, role: Role) -> Document_Error {
	if e := fact_node(list, node, role, ""); e.kind != .None {
		return e
	}
	return edit_add(list, node, .Remove_Fact, role, 0, "", "")
}

// The checks every fact edit makes: the node accepts a fact and the role has a body shape. A role at or below `.Key`
// is refused with `.Bad_Index`, and an unhandled role past `.Key` with `.Bad_Fact`. A commit refuses a second edit of
// one node and role.
@(private)
fact_node :: proc(list: ^Edit_List, node: Node_Index, role: Role, text: string) -> Document_Error {
	_, n, err := node_of(list, node)
	if err.kind != .None || n.role == .Key || role <= .Key {
		return {kind = .Bad_Index}
	}
	#partial switch role {
	case .Comment_Inline:
		if body_lf_cr(transmute([]u8)text) {
			return {kind = .Bad_Fact}
		}
	case .Comment, .Comment_Foot:
	case:
		return {kind = .Bad_Fact}
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
fact_slot :: #force_inline proc(doc: ^Document, node: Node_Index, role: Role, style: Comment_Spelling, all_records_removed: bool) -> bool {
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
// separators the format supplies, in the document's own spec. The caller frees the result with `allocator`. An edit
// that another covers, a second edit of one node, and a second fact edit of one node and role are
// `.Conflicting_Edits` at the byte where the two meet. An insert whose index lies in a removal run moves to the run's
// cut end, so it is no conflict. The result is checked by the format, and a result that reads less strictly than the
// source is `.Bad_Result`. A fact the output cannot hold is dropped with its source bytes. `dropped` counts the source
// facts and fact edits the output cannot hold. A fact that is removed with a removed member or a set's span is not
// counted.
commit :: proc(list: ^Edit_List, allocator := context.allocator) -> (out: []u8, dropped: int, err: Document_Error) {
	if list.doc == nil {
		return nil, 0, {kind = .Bad_Index}
	}
	return commit_as(list, list.doc.read.spec, allocator)
}

// Writes `list`'s edits as spec byte `spec`, for a format's `commit` that offers another spec of its own. `commit`
// passes the document's own spec.
commit_as :: proc(list: ^Edit_List, spec: u8, allocator := context.allocator) -> (out: []u8, dropped: int, err: Document_Error) {
	doc := list.doc
	if doc == nil {
		return nil, 0, {kind = .Bad_Index}
	}
	// A table format writes only the spec it was read as, since another spec would respell every cell. Refuse before
	// any chunk is built or spliced, rather than after the output fails to read.
	if table_doc(doc) && spec != doc.read.spec {
		return nil, 0, {kind = .Bad_Spec}
	}
	chunks, _ := make([dynamic]Chunk, allocator)
	defer delete(chunks)
	text, _ := make([dynamic]u8, allocator)
	defer delete(text)
	if e, conflict := edits_removed(doc, list, allocator); conflict {
		return nil, 0, e
	}
	style, comment_byte := comment_style(doc, spec)
	if e, ok := compose_tree(doc, list, style, comment_byte, &text, &chunks, &dropped, allocator); !ok {
		return nil, 0, e
	}
	if e := order_chunks(&chunks); e.kind != .None {
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
	if spec != doc.read.spec {
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

// Replaces `src[lo:hi]` with `text[from:to]`. `fact` marks a fact's chunk and `remove` one that writes nothing, and
// `rank` orders chunks at one byte.
@(private)
Chunk :: struct {
	lo, hi: u64,
	from:   int,
	to:     int,
	rank:   u8,
	fact:   bool,
	remove: bool,
}

// Returns the first byte of member `v` of `parent`, without the comments it holds: its key's first byte or its own.
// Only an inline-key `Map`'s member has a key node before it. A dsv root's first record follows the header row, whose last cell
// also has role `Key`, and that cell names a column, not the record.
@(private)
value_lo :: proc(doc: ^Document, parent, v: Node_Index) -> u64 {
	if doc.header == 0 && doc.nodes[parent].kind == .Map && doc.nodes[v-1].role == .Key {
		return key_start(doc.nodes[v-1])
	}
	return key_start(doc.nodes[v])
}

// Returns the bytes between container `c`'s brackets, where its members go. A delimited text's empty table is empty
// to its end, and a tree's empty container keeps only its brackets.
@(private)
interior :: proc(doc: ^Document, c: Node_Index) -> (lo, hi: u64) {
	hi = doc.spelling.close_end(doc, c)
	if table_doc(doc) {
		return doc.nodes[c].lo, hi
	}
	return doc.nodes[c].lo + 1, hi - 1
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
fact_write :: proc(doc: ^Document, style: Comment_Spelling, comment_byte: u8, role: Role, body: []u8, line: bool, indent: []u8, lead, new: bool, text: ^[dynamic]u8) -> bool {
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
		push(text, comment_byte) or_return
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

// Returns the indent of the line holding `pos` and whether bytes stand before `pos` on that line.
@(private)
line_shape :: proc(doc: ^Document, pos: u64) -> (indent: []u8, lead: bool) {
	lo, hi := line_of(doc.src, pos, !table_doc(doc))
	return doc.src[lo:hi], hi < pos
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

// Whether a fact body at `pos` can use a line comment. A chunk that inserts at the byte writes after the comment on its
// line, and a replacement or inline fact is written in the block spelling.
@(private)
fact_line :: proc(doc: ^Document, e: Edit, pos: u64, taken: int, inserted: bool) -> bool {
	line := taken == 0 && e.role != .Comment_Inline || pos >= u64(len(doc.src)) || line_end_len(doc.src, pos) > pos
	line = line && !body_line_end(e.text)
	if e.role == .Comment_Inline || taken > 0 {
		line = line && !inserted
	}
	return line
}

// A `Remove_Range` is the node range an edit takes out: a removal's subtree, or a set's replaced value for a fact
// edit below it.
@(private)
Remove_Range :: struct {
	lo: Node_Index,
	hi: Node_Index,
	op: Edit_Op,
}

// A `Remove_Query` names the node an edit writes at, its index in the list, and whether it is a fact edit.
@(private)
Remove_Query :: struct {
	node: Node_Index,
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
			push(&ranges, Remove_Range{lo = e.node, hi = e.node + Node_Index(span), op = e.op}) or_return
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
	removed_hi, set_hi, same_set_hi := Node_Index(0), Node_Index(0), Node_Index(0)
	node := Node_Index(0)
	ri, best, best_node := 0, -1, Node_Index(0)
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

// A `Target` names a node a group of edits works on, a container for an insert or a removed member, with the edit that
// named it. An insert's `at` orders it against the other inserts of its container.
@(private)
Target :: struct {
	node: Node_Index,
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
	stack, _ := make([dynamic]Node_Index, allocator)
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
		for k < len(targets) && targets[k].node == Node_Index(i) {
			parent := NO_NODE
			if len(stack[:]) > 0 {
				parent = stack[:][len(stack[:]) - 1]
			}
			push(groups, Target{node = parent, edit = targets[k].edit, at = targets[k].at}) or_return
			k += 1
		}
		n := doc.nodes[i]
		if n.kind == .Array || n.kind == .Map {
			push(&stack, Node_Index(i)) or_return
		}
	}
	return true
}

// Copies an edit's key and text into one allocation, then appends the edit to the log. A refused append frees the
// copy.
@(private)
edit_add :: proc(list: ^Edit_List, node: Node_Index, op: Edit_Op, role: Role, at: u32, key, text: string) -> Document_Error {
	k, t: []u8
	owned: []u8
	if n := len(key) + len(text); n > 0 {
		fresh, err := make([]u8, n, list.allocator)
		if err != nil {
			return {kind = .No_Memory}
		}
		copy(fresh, transmute([]u8)key)
		copy(fresh[len(key):], transmute([]u8)text)
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
	if _, err := append(d, ..vs); err != nil {
		return 0, false
	}
	return len(vs), true
}
