package core

import "base:runtime"
import "core:bytes"

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

// Whether a document is flat: its text has no brackets, so a container has no bytes of its own, and its root's members
// are lines the format composes itself. A flat format writes the spec it was read as, since another
// spec would respell every member.
is_flat :: #force_inline proc(doc: ^Document) -> bool {
	return doc.spelling.edit != nil && doc.spelling.edit.flat
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
// writes in the format's own spelling, a value's text is source text and must read as one value, and in a flat text a
// key is a member like any other, so its text is checked as a value. A fact node or a flat text's container returns
// `.Bad_Index`.
// Runs in O(len(text)), checking the text once and copying it once.
set :: proc(list: ^Edit_List, node: Node_Index, text: string) -> Document_Error {
	doc, n, err := node_of(list, node)
	if err.kind != .None {
		return err
	}
	flat := is_flat(doc)
	if n.role > .Key || flat && (n.kind == .Array || n.kind == .Map) {
		return {kind = .Bad_Index}
	}
	if n.role == .Key && !flat {
		return edit_add(list, node, .Set, .Key, 0, "", text)
	}
	if e := judge(doc, text, list.allocator); e.kind != .None {
		return e
	}
	return edit_add(list, node, .Set, .Value, 0, "", text)
}

// Makes `text` the value of the member of `obj` named `name`: a set of the member the document holds, or an insert after
// `obj`'s last member when it has none. `dups` picks the member of a repeated key.
set_member :: proc(list: ^Edit_List, obj: Node_Index, name, text: string, dups := Duplicates.Last) -> Document_Error {
	doc := list.doc
	if doc == nil {
		return {kind = .Bad_Index}
	}
	v, presence := member_of(doc, obj, name, dups)
	switch presence {
	case .Found:
		return set(list, v, text)
	case .Missing:
		return insert_member(list, obj, length(doc, obj), name, text)
	case .Wrong_Kind, .Not_Loaded:
	}
	return {kind = .Bad_Index}
}

// Inserts `text` into the array `container` before its element `at`, or after its last when `at` is its length.
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
	if member && doc.spelling.edit.key_text == nil {
		return {kind = .Wrong_Container}
	}
	e: Document_Error
	if !member && doc.spelling.edit != nil && doc.spelling.edit.insert_check != nil {
		e = doc.spelling.edit.insert_check(doc, container, text, list.allocator)
	} else {
		e = judge(doc, text, list.allocator)
	}
	if e.kind != .None {
		return e
	}
	return edit_add(list, container, .Insert, .Key if member else .Value, u32(at), key, text)
}

// Appends the removal edit. The commit removes the member with its key and one adjacent separator. A delimited
// text's record is removed with its line end, and a header cell or a record's cell by the format's column rules.
remove :: proc(list: ^Edit_List, node: Node_Index) -> Document_Error {
	doc, n, err := node_of(list, node)
	// A key is removed with its value and a header row is no member of its own, but a flat text's key is a cell.
	flat_key := n.role == .Key && is_flat(doc) && n.kind != .Array
	if err.kind != .None || node == ROOT || n.role != .Value && !flat_key {
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
		if has_line_end(transmute([]u8)text) {
			return {kind = .Bad_Fact}
		}
	case .Comment, .Comment_Foot:
	case:
		return {kind = .Bad_Fact}
	}
	return {}
}

// Returns the source bytes `list`'s edits make, in the document's own spec, through the format's commit. The caller frees
// the result with `allocator`. An edit that another covers, a second edit of one node, and a second fact edit of one node
// and role are `.Conflicting_Edits` at the byte where the two meet. A result that reads less strictly than the source is
// `.Bad_Result`. `dropped` counts the source facts and fact edits the output cannot hold.
commit :: proc(list: ^Edit_List, allocator := context.allocator) -> (out: []u8, dropped: int, err: Document_Error) {
	if list.doc == nil || list.doc.spelling == nil || list.doc.spelling.edit == nil {
		return nil, 0, {kind = .Bad_Index}
	}
	return list.doc.spelling.edit.commit(list, list.doc.as.spec, allocator)
}

// Whether `body` holds LF or CR, the only line ends a delimited text's comment line ends at. U+2028 is a byte in its
// body.
has_line_end :: #force_inline proc(body: []u8) -> bool {
	return bytes.index_byte(body, '\n') >= 0 || bytes.index_byte(body, '\r') >= 0
}

// Copies an edit's key and text into one allocation, then appends the edit to the log. A refused append frees the
// copy.
@(private)
edit_add :: proc(list: ^Edit_List, node: Node_Index, op: Edit_Op, role: Role, at: u32, key, text: string) -> Document_Error {
	k, t, fresh: []u8
	if n := len(key) + len(text); n > 0 {
		err: runtime.Allocator_Error
		if fresh, err = make([]u8, n, list.allocator); err != nil {
			return {kind = .No_Memory}
		}
		copy(fresh, transmute([]u8)key)
		copy(fresh[len(key):], transmute([]u8)text)
		if len(key) > 0 {
			k = fresh[:len(key)]
		}
		if len(text) > 0 {
			t = fresh[len(key):]
		}
	}
	if _, err := append(&list.edits, Edit{node = node, op = op, role = role, at = at, key = k, text = t}); err != nil {
		delete(fresh, list.allocator)
		return {kind = .No_Memory}
	}
	return {}
}

