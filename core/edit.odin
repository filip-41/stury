package core

import "base:runtime"
import "core:bytes"
import "core:encoding/endian"
import "core:slice"

// A log of edits kept apart from a document, which does not change after its build. A reader sees an edit only after
// the caller commits and builds the output again. Any number of lists may share one document, each with its own edits.
//
// `set`, `insert` and `remove` append an edit, checked when it is recorded, in O(its text). A commit resolves every
// edit to a source range, refuses the colliding ones, and splices the edits into the source. Every byte no edit
// touched stays, and the format's `Edit_Services` supplies the separators.
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
	Set_Fact, // the facts of the node with `role` become the bodies `text` holds
	Remove_Fact, // every fact of the node with `role` is removed
	Reorder, // the container's members take the order `text` holds, as little-endian u32 positions
}

// A recorded edit. `node` names a node of the document the list was made with: a value or a key for `Set`, a container
// for `Insert` and `Reorder`, a value that is a member of a container for `Remove`, and any node but a key for the fact
// edits, whose `role` says which facts they change. `at` is an insert's position, 0 through the container's length at
// the time the edit was recorded. `role` is a fact edit's role, or `.Key` when an insert is a member or a set's text is
// a decoded key name. `key` is a member insert's decoded name, or for a fact set of several bodies their lengths as
// little-endian u32, and `text` is a value's source text, a record, a cell, a key's decoded name for a key set, a fact
// set's bodies one after another, or a reorder's positions, each copied into the list's allocator. A `padded` fact set
// writes one space inside each marker of each body.
Edit :: struct {
	node:   Node_Index,
	op:     Edit_Op,
	role:   Role,
	padded: bool,
	at:     u32,
	key:    []u8,
	text:   []u8,
}

// A log of edits against one document. `edits` holds the recorded edits, grows as edits are recorded, and
// `edit_list_destroy` frees it. `allocator` supplies the log and the edits' copies. The document is borrowed and
// must outlive the list.
Edit_List :: struct {
	doc:       ^Document,
	edits:     [dynamic]Edit,
	allocator: runtime.Allocator,
	// The edit services of the document's format, nil for a format that accepts no edits.
	edit:      ^Edit_Services,
}

// Returns an edit list over `doc`. It allocates nothing until the first edit is recorded.
edit_list_init :: proc(doc: ^Document, allocator := context.allocator) -> Edit_List {
	edits, _ := make([dynamic]Edit, allocator)
	list := Edit_List{doc = doc, edits = edits, allocator = allocator}
	if doc != nil {
		if services := services_of(doc.as); services != nil {
			list.edit = services.edit
		}
	}
	return list
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
	return doc.readers.flat
}

// Checks a recorded text as a value. A member's key is a decoded name, so no text is judged as a key.
@(private)
judge :: proc(doc: ^Document, edit: ^Edit_Services, text: string, allocator: runtime.Allocator) -> Document_Error {
	if edit != nil && edit.value != nil {
		return edit.value(doc, transmute([]u8)text, allocator)
	}
	return {}
}

// Returns node `node` of `list`'s document, or `.Bad_Index` when the list has no document or the index is past the
// last node.
@(private)
node_of :: proc(list: ^Edit_List, node: Node_Index) -> (doc: ^Document, n: Node, err: Document_Error) {
	doc = list.doc
	if doc == nil {
		return doc, {}, {kind = .Bad_Index, reason = .No_Document}
	}
	if int(node) >= len(doc.nodes) {
		return doc, {}, {kind = .Bad_Index, reason = .No_Node}
	}
	return doc, doc.nodes[node], {}
}

// Returns the `Error` of an edit's refusal.
@(private)
refused :: proc(kind: Document_Error_Kind, reason := Edit_Reason.None) -> Error {
	return error_of(Document_Error{kind = kind, reason = reason})
}

// Makes `text` the source bytes of node `node`, a value or a key. A key's text is its decoded name, which the commit
// writes in the format's own spelling, a value's text is source text and must read as one value, and in a flat text a
// key is a member like any other, so its text is checked as a value. A fact node or a flat text's container returns
// `.Bad_Index`.
// Runs in O(len(text)), checking the text once and copying it once.
set :: proc(list: ^Edit_List, node: Node_Index, text: string) -> Error {
	doc, n, err := node_of(list, node)
	if err.kind != .None {
		return error_of(err)
	}
	flat := is_flat(doc)
	if n.role > .Key {
		return refused(.Bad_Index, .Fact_Node)
	}
	if flat && (n.kind == .Array || n.kind == .Object) {
		return refused(.Bad_Index, .Flat_Container)
	}
	if n.role == .Key && !flat {
		return error_of(edit_add(list, node, .Set, .Key, 0, "", text))
	}
	if e := judge(doc, list.edit, text, list.allocator); e.kind != .None {
		return error_of(e)
	}
	return error_of(edit_add(list, node, .Set, .Value, 0, "", text))
}

// Makes `text` the value of the member of `obj` named `name`: a set of the member the document holds, or an insert after
// `obj`'s last member when it has none. `dups` picks the member of a repeated key, and `.All` sets each.
set_member :: proc(list: ^Edit_List, obj: Node_Index, name, text: string, dups := Duplicates.Last) -> Error {
	doc := list.doc
	if doc == nil {
		return refused(.Bad_Index, .No_Document)
	}
	if dups == .All && int(obj) < len(doc.nodes) && doc.nodes[obj].kind == .Object {
		found := false
		it := members_named(doc, obj, name)
		for v in member_next(&it) {
			found = true
			if e := set(list, v, text); e != nil {
				return e
			}
		}
		if found {
			return nil
		}
	}
	v, presence := member_of(doc, obj, name, dups)
	switch presence {
	case .Found:
		return set(list, v, text)
	case .Missing:
		return insert_member(list, obj, length(doc, obj), name, text)
	case .Wrong_Kind:
		return refused(.Bad_Index, .Not_Object)
	case .Not_Loaded:
	}
	return refused(.Bad_Index, .Not_Loaded)
}

// Inserts `text` into the array `container` before its element `at`, or after its last when `at` is its length.
@(private)
insert_value :: proc(list: ^Edit_List, container: Node_Index, at: int, text: string) -> Error {
	return insert_at(list, container, at, "", false, text)
}

// Inserts `key` and `text` as a member of the object `container` before its member `at`, or after its last when
// `at` is its length.
@(private)
insert_member :: proc(list: ^Edit_List, container: Node_Index, at: int, key, text: string) -> Error {
	return insert_at(list, container, at, key, true, text)
}

// `insert` is `insert_value` for an array and `insert_member` for an object.
insert :: proc {
	insert_value,
	insert_member,
}

@(private)
insert_at :: proc(list: ^Edit_List, container: Node_Index, at: int, key: string, member: bool, text: string) -> Error {
	doc := list.doc
	if doc == nil {
		return refused(.Bad_Index, .No_Document)
	}
	if int(container) >= len(doc.nodes) {
		return refused(.Bad_Index, .No_Node)
	}
	if doc.nodes[container].kind != (Kind.Object if member else .Array) {
		return refused(.Wrong_Container)
	}
	n_members := length(doc, container)
	if at < 0 || at > n_members {
		return refused(.Bad_Position)
	}
	if member && list.edit.key_text == nil {
		return refused(.Wrong_Container)
	}
	e: Document_Error
	if !member && list.edit != nil && list.edit.insert_check != nil {
		e = list.edit.insert_check(doc, container, text, list.allocator)
	} else {
		e = judge(doc, list.edit, text, list.allocator)
	}
	if e.kind != .None {
		return error_of(e)
	}
	return error_of(edit_add(list, container, .Insert, .Key if member else .Value, u32(at), key, text))
}

// Appends the removal edit. The commit removes the member with its key and one adjacent separator. A delimited
// text's record is removed with its line end, and a header cell or a record's cell by the format's column rules.
remove :: proc(list: ^Edit_List, node: Node_Index) -> Error {
	doc, n, err := node_of(list, node)
	// A key is removed with its value and a header row is no member of its own, but a flat text's key is a cell.
	flat_key := n.role == .Key && is_flat(doc) && n.kind != .Array
	switch {
	case err.kind != .None:
		return error_of(err)
	case node == ROOT:
		return refused(.Bad_Index, .Root)
	case n.role > .Key:
		return refused(.Bad_Index, .Fact_Node)
	case n.role == .Key && !flat_key:
		return refused(.Bad_Index, .Key_Node)
	}
	return error_of(edit_add(list, node, .Remove, .Value, 0, "", ""))
}

// Puts the members of the container `container` in `order`. Entry `i` below the container's length is its member `i`,
// and `length + k` its `k`th insert, in the order of the inserts' `at` and then of their recording. A member the order
// leaves out is one a removal edit names. Each member keeps its bytes and the comments that go with it, an edit inside
// it still applies, and the gaps between members stay in their places, so the container keeps its separators, lines
// and indent. The commit checks that the order names each surviving member and each insert once.
reorder :: proc(list: ^Edit_List, container: Node_Index, order: []u32) -> Error {
	_, n, err := node_of(list, container)
	switch {
	case err.kind != .None:
		return error_of(err)
	case n.kind != .Array && n.kind != .Object:
		return refused(.Wrong_Container)
	}
	return error_of(edit_add(list, container, .Reorder, .Value, 0, "", string(slice.to_bytes(order))))
}

// Makes `text` the body of the facts of node `node` and `role`, which it replaces. A `Comment_Inline` body holds no LF
// or CR. A `Comment` or `Comment_Foot` body may. A `padded` body is written with one space inside each marker, `// text`
// and `/* text */`, the way a comment's text is read without them. Runs in O(len(text)), checking the shape once and
// copying the text once.
set_fact :: proc(list: ^Edit_List, node: Node_Index, role: Role, text: string, padded := false) -> Error {
	if e := fact_node(list, node, role, text); e.kind != .None {
		return error_of(e)
	}
	return error_of(edit_add(list, node, .Set_Fact, role, 0, "", text, padded))
}

// Makes `texts`, in order, the bodies of the facts of node `node` and `role`, which they replace, as `set_fact` makes
// one: the first takes the place of the first fact, and each other follows on a line of its own, or on the value's line
// for an inline fact. No texts removes the facts, as `remove_fact` does.
set_facts :: proc(list: ^Edit_List, node: Node_Index, role: Role, texts: []string, padded := false) -> Error {
	switch len(texts) {
	case 0:
		return remove_fact(list, node, role)
	case 1:
		return set_fact(list, node, role, texts[0], padded)
	}
	size := 4 * len(texts)
	for t in texts {
		if e := fact_node(list, node, role, t); e.kind != .None {
			return error_of(e)
		}
		size += len(t)
	}
	// The lengths and the bodies share one allocation, the lengths first, as an edit's key and text do.
	fresh, err := make([]u8, size, list.allocator)
	if err != nil {
		return err
	}
	at := 4 * len(texts)
	for t, i in texts {
		endian.unchecked_put_u32le(fresh[4 * i:], u32(len(t)))
		at += copy(fresh[at:], t)
	}
	e := Edit{node = node, op = .Set_Fact, role = role, padded = padded, key = fresh[:4 * len(texts)], text = fresh[4 * len(texts):]}
	if _, aerr := append(&list.edits, e); aerr != nil {
		delete(fresh, list.allocator)
		return aerr
	}
	return nil
}

// Removes every fact of node `node` and `role`, with its source bytes.
remove_fact :: proc(list: ^Edit_List, node: Node_Index, role: Role) -> Error {
	if e := fact_node(list, node, role, ""); e.kind != .None {
		return error_of(e)
	}
	return error_of(edit_add(list, node, .Remove_Fact, role, 0, "", ""))
}

// The checks every fact edit makes: the node accepts a fact and the role has a body shape. A role at or below `.Key`
// is refused with `.Bad_Index`, and an unhandled role past `.Key` with `.Bad_Fact`. A commit refuses a second edit of
// one node and role.
@(private)
fact_node :: proc(list: ^Edit_List, node: Node_Index, role: Role, text: string) -> Document_Error {
	_, n, err := node_of(list, node)
	switch {
	case err.kind != .None:
		return err
	case n.role == .Key:
		return {kind = .Bad_Index, reason = .Key_Node}
	case role <= .Key:
		return {kind = .Bad_Index, reason = .Not_Fact_Role}
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

// Whether `body` holds LF or CR, the only line ends a delimited text's comment line ends at. U+2028 is a byte in its
// body.
has_line_end :: #force_inline proc(body: []u8) -> bool {
	return bytes.index_byte(body, '\n') >= 0 || bytes.index_byte(body, '\r') >= 0
}

// Copies an edit's key and text into one allocation, then appends the edit to the log. A refused append frees the
// copy.
@(private)
edit_add :: proc(list: ^Edit_List, node: Node_Index, op: Edit_Op, role: Role, at: u32, key, text: string, padded := false) -> Document_Error {
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
	if _, err := append(&list.edits, Edit{node = node, op = op, role = role, padded = padded, at = at, key = k, text = t}); err != nil {
		delete(fresh, list.allocator)
		return {kind = .No_Memory}
	}
	return {}
}

