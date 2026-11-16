package core

import "base:runtime"

// Whether `out`, a flat text a commit of `list` made, read as `as` token by token through `walk`, which passes each token
// to `rows_hook`, holds the document the edits make: the source's rows that stay, in order, each with its values that
// stay, named by the header keys the source names them with and holding the text the source value holds or the value a
// set wrote. `known` is false where the list holds an edit this read does not follow, an insert, a rename, a
// reorder or a set of a row, or the table is ragged, and the commit reads `out` whole. Works in the context
// allocator.
reads_rows :: proc(list: ^Edit_List, out: []u8, as: As, walk: proc(src: []u8, as: As, r: ^Row_Read) -> Maybe(Fault)) -> (err: Document_Error, known: bool) {
	r := Row_Read{view = {src = out, as = as}, ctx = context}
	r.a = applied_of(list, ways = false) or_return
	doc := list.doc
	if len(r.a.inserts) + len(r.a.renames) + len(r.a.orders) > 0 || doc.n_tables == 0 || doc.tables_at[0].width == 0 {
		return {}, false
	}
	for x in r.a.sets {
		if doc.nodes[x.node].kind > .Plain {
			return {}, false
		}
	}
	if fault, bad := walk(out, as, &r).?; bad {
		return {kind = .No_Memory} if fault.kind == .No_Memory else {kind = .Bad_Result, inner = fault}, true
	}
	if r.failed || r.depth != 0 {
		return {kind = .Bad_Result, reason = .Reads_Back_Other}, true
	}
	return {}, true
}

// Where `reads_rows` stands in the output: the source row and value the next token reads as.
Row_Read :: struct {
	a:       Applied,
	view:    Token_View, // the output's
	rows:    Child_Iter,
	pairs:   Pair_Iter, // the values of a row that is an `Object`, with their keys
	items:   Child_Iter, // the values of a row that is an `Array`
	keyed:   bool,
	named:   bool, // a key came, and `member` is the value it names
	judged:  bool, // a row has ended, so the keys of every later row are the header's again, as the first row judged them
	member:  Node_Index,
	depth:   int,
	failed:  bool,
	ctx:     runtime.Context,
}

// The hook a format's walk runs `reads_rows` with. It stops the walk at the first token that does not read as edited.
rows_hook :: proc "contextless" (r: ^Row_Read, s: Hook_Regs, t: Token) -> (Hook_Regs, Action) {
	context = r.ctx
	if !row_reads(r, t) {
		r.failed = true
		return s, .Stop
	}
	return s, .Next
}

@(private = "file")
row_reads :: proc(r: ^Row_Read, t: Token) -> bool {
	doc := r.a.doc
	if t.role != .Value && t.role != .Key {
		// A comment is no value, and an edit of one holds no value to read back.
		return true
	}
	if t.kind == .End {
		switch r.depth {
		case 1:
			if _, more := kept_child(r, &r.rows); more {
				return false
			}
		case 2:
			if r.keyed {
				for _, v in doc_pair_next(&r.pairs) {
					if !has(r.a.gone, v) {
						return false
					}
				}
			} else if _, more := kept_child(r, &r.items); more {
				return false
			}
		}
		r.judged ||= r.depth == 2
		r.depth -= 1
		return r.depth >= 0 && !r.named
	}
	if t.kind == .Object || t.kind == .Array {
		switch r.depth {
		case 0:
			if doc.nodes[ROOT].kind != t.kind {
				return false
			}
			r.rows = doc_children(doc, ROOT)
		case 1:
			row := kept_child(r, &r.rows) or_return
			if doc.nodes[row].kind != t.kind || has(r.a.is_set, row) {
				return false
			}
			r.keyed = t.kind == .Object
			r.pairs, r.items = doc_pairs(doc, row), doc_children(doc, row)
		case:
			return false
		}
		r.depth += 1
		return true
	}
	if r.depth != 2 || r.named == (t.role == .Key) && r.keyed {
		return false
	}
	if t.role == .Key {
		if !r.keyed {
			return false
		}
		key, v := kept_pair(r) or_return
		r.member, r.named = v, true
		if r.judged {
			return true
		}
		text := token_text(r.view.readers, &r.view, t, context.allocator) or_return
		return key_equals(doc, key, text)
	}
	text := token_text(r.view.readers, &r.view, t, context.allocator) or_return
	if r.keyed {
		r.named = false
	} else {
		r.member = kept_child(r, &r.items) or_return
	}
	if has(r.a.is_set, r.member) {
		read := Document{view = r.view, nodes = []Node{t}}
		return equal(set_of(&r.a, r.member), Node_Ref{&read, ROOT}, read_plain = true)
	}
	want, ok := token_text(doc.readers, &doc.view, doc.nodes[r.member], context.allocator)
	return ok && want == text
}

// The next node `it` gives that no edit removes.
@(private = "file")
kept_child :: proc(r: ^Row_Read, it: ^Child_Iter) -> (Node_Index, bool) {
	for v in doc_child_next(it) {
		if !has(r.a.gone, v) {
			return v, true
		}
	}
	return NO_NODE, false
}

// The next key and value of the row that no edit removes.
@(private = "file")
kept_pair :: proc(r: ^Row_Read) -> (key, v: Node_Index, ok: bool) {
	for k, x in doc_pair_next(&r.pairs) {
		if !has(r.a.gone, x) {
			return k, x, true
		}
	}
	return NO_NODE, NO_NODE, false
}
