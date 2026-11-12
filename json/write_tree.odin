package json

import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import core "../core"
import write "../core/write"

// The tree writer: the documents the row walk leaves out. It walks the document by its containers, one frame of a stack
// each, and writes each member's comments around it, so it is slow and handles everything: comments, sorted keys, shared
// keys, the spelling of a JSON5 text in JSON, and a partial document. The row walk of `write_document.odin`
// writes every other document and calls nothing of this file.
//
// A comment is a fact of the member's value node. A `Comment` stands before the member, or between its key and its value
// when its bytes follow the key's. A `Comment_Inline` follows the member and its comma. A `Comment_Foot` of a container
// stands on a line of its own before the close, and one of the root that follows the root's close stands after it.

@(private)
Tree_Writer :: struct {
	doc:     ^core.Document,
	root:    core.Node_Index, // the node written as the text's root
	out:     ^write.Out,
	opts:    core.Write_Options,
	close:   u64, // the byte past `root`, where the document root's feet that follow it begin
	dropped: int, // the facts the target cannot hold
	kind:    core.Typed_Error_Kind, // what stopped the write
	json:    bool, // the document is JSON's, in any spec
	keep:    bool, // facts are written as comments
	respell: bool, // a number of JSON5 or of another format is spelled again for JSON, and a JSON5 string
	seps:    bool, // U+2028 and U+2029 end a line comment in the target, JSON5
	copy:    bool, // a string is written as it was authored
	resolve: bool, // a `Plain` cell with bytes is written as `core.kind` reads it, else as text
	at:      int, // the first fact not before the node `node_facts` last answered for
	held:    bool, // the line written last ends in a value, so a comment that follows it there reads as its inline one
}

// A member of an `Object` as the tree writer orders them. `name` is the decoded key under `sort_keys`.
@(private)
Pair :: struct {
	key, val: core.Node_Index,
	name:     string,
}

// Writes node `node` of `doc` as spec `as` into `out`. The count is the facts `as` cannot hold.
@(private)
write_tree :: proc(doc: ^core.Document, opts: core.Write_Options, out: ^write.Out, as: Spec, node: core.Node_Index) -> (dropped: int, kind: core.Typed_Error_Kind) {
	w := Tree_Writer{doc = doc, root = node, out = out, opts = opts, json = doc.readers.format == rules_of}
	w.keep = w.json && as != .Json && !doc.partial
	w.respell = !w.json || Spec(doc.as.spec) == .Json5 && as != .Json5
	w.seps = as == .Json5
	w.copy = w.json && !w.respell && copies_strings(opts)
	w.resolve = doc.readers.resolves != nil && doc.readers.resolves(doc.as)
	if w.keep {
		root := doc.nodes[node]
		_, w.close = core.scalar_ends(root)
		if root.kind >= .Array {
			w.close = doc.readers.close_end(doc, node)
		}
	} else {
		w.dropped = len(core.subtree_facts(doc, node))
	}
	if !tree_walk(&w, node) {
		return 0, w.kind
	}
	return w.dropped, .None
}

// Writes fact `f` with its markers. A line comment ends its line in compact text, since nothing may follow it there.
// `ascii` and `escape_html` respell a comment's characters as they do a string's, as literal text, and so is a U+2028 or
// U+2029 in a line comment that the target ends there. Returns whether it is a line comment.
@(private)
tree_comment :: proc(w: ^Tree_Writer, f: core.Fact) -> (line: bool) {
	text := w.doc.src[f.lo:f.lo + u64(f.n)]
	line = text[1] == '/'
	seps := w.opts.escape_html || line && w.seps
	if w.opts.ascii || seps {
		for r in string(text) {
			if r >= 0x80 && w.opts.ascii || w.opts.escape_html && (r == '<' || r == '>' || r == '&') || seps && (r == 0x2028 || r == 0x2029) {
				w.out.cursor += unit_text(write.room(w.out, 12), u32(r))
			} else {
				encoded, n := utf8.encode_rune(r)
				write.put_text(w.out, string(encoded[:n]))
			}
		}
	} else {
		write.put_text(w.out, string(text))
	}
	if line && !w.opts.pretty {
		write.put_byte(w.out, '\n')
	}
	// A block's LF or CR, which no spelling changes, ends the line too.
	if line || strings.index_any(string(text), "\n\r") >= 0 {
		w.held = false
	}
	return
}

// Ends the line in compact text when it ends in a value, before a comment that is not that value's inline comment.
@(private)
tree_break :: proc(w: ^Tree_Writer) {
	if w.held && !w.opts.pretty {
		write.put_byte(w.out, '\n')
	}
	w.held = false
}

// The facts of node `i`. A walk in row order reads them from `at` on without a search, and a node before the cursor, as
// a sorted key's is, is searched for.
@(private)
node_facts :: proc(w: ^Tree_Writer, i: core.Node_Index) -> []core.Fact {
	all := w.doc.facts
	if w.at > 0 && all[w.at - 1].node >= i {
		return core.all_facts(w.doc, i)
	}
	lo := w.at
	for lo < len(all) && all[lo].node < i {lo += 1}
	for w.at = lo; w.at < len(all) && all[w.at].node == i; w.at += 1 {}
	return all[lo:w.at]
}

// An open container of the tree walk, the frame of its depth: the member that follows in its `Object` list or among its
// `Array` nodes, and what its close and the comments after it need.
@(private)
Tree_Frame :: struct {
	i:       core.Node_Index,
	facts:   []core.Fact, // the container's, its feet among them
	object:  bool,
	comma:   bool, // a comma follows the container
	list:    [dynamic]Pair, // an `Object`'s members, written from `next` on, its room kept for the next at the depth
	next:    int,
	at, end: core.Node_Index, // an `Array`'s next node and the node past its last
	members: int,
}

// Writes node `node` and everything in it. Each open container is a frame of a stack that grows with the depth, and a
// container past the document's `max_depth`, which its read refuses, is `.Too_Deep`.
@(private)
tree_walk :: proc(w: ^Tree_Writer, node: core.Node_Index) -> bool #no_bounds_check {
	frames: [dynamic]Tree_Frame
	open := 0 // the containers open, each in the frame of its depth
	defer {
		for f in frames {
			tree_free(f.list)
		}
		delete(frames)
	}
	limit := int(w.doc.as.max_depth) if w.doc.as.max_depth != 0 else core.MAX_DEPTH
	i, key, comma := node, core.NO_NODE, false
	for {
		facts := tree_head(w, i, key, open) or_return
		if w.doc.nodes[i].kind < .Array {
			tree_scalar(w, i) or_return
			tree_tail(w, i, open, comma, facts)
		} else {
			if open >= limit {
				w.kind = .Too_Deep
				return false
			}
			if open == len(frames) {
				if _, failed := append(&frames, Tree_Frame{}); failed != nil {
					w.kind = .No_Memory
					return false
				}
			}
			tree_open(w, &frames[open], i, comma, facts) or_return
			open += 1
		}
		for found := false; !found; {
			if open == 0 {
				return true
			}
			top := &frames[open - 1]
			if i, key, comma, found = tree_member(w, top); found {
				write.put_line(w.out, w.opts, open)
			} else {
				open -= 1
				tree_close(w, top, open)
				tree_clear(&top.list)
				tree_tail(w, top.i, open, top.comma, top.facts)
			}
		}
	}
}

@(private)
tree_free :: proc(list: [dynamic]Pair) {
	list := list
	tree_clear(&list)
	delete(list)
}

// Empties `list` and keeps its room.
@(private)
tree_clear :: #force_inline proc(list: ^[dynamic]Pair) {
	for p in list {
		delete(p.name)
	}
	clear(list)
}

// Writes the comments before member `i` of the container at `depth`, its key `key` when it has one, and the comments
// between the key and the value. The root is entered with no key. Returns the member's facts.
@(private)
tree_head :: #force_inline proc(w: ^Tree_Writer, i, key: core.Node_Index, depth: int) -> (facts: []core.Fact, ok: bool) {
	doc := w.doc
	facts = node_facts(w, i) if w.keep else nil
	key_lo := max(u64)
	if key != core.NO_NODE {
		key_lo = core.node_start(doc.nodes[key])
	}
	for f in facts {
		if f.role == .Comment && f.lo < key_lo {
			tree_break(w)
			tree_comment(w, f)
			write.put_line(w.out, w.opts, depth)
		}
	}
	if key != core.NO_NODE {
		w.kind = put_token_string(w.out, doc.src, doc, key, doc.nodes[key], w.opts, w.json, w.copy)
		if w.kind != .None {
			return
		}
		write.put_text(w.out, ": " if w.opts.pretty else ":")
		for f in facts {
			if f.role == .Comment && f.lo > key_lo {
				if tree_comment(w, f) {
					write.put_line(w.out, w.opts, depth)
				} else if w.opts.pretty {
					write.put_byte(w.out, ' ')
				}
			}
		}
	}
	return facts, true
}

// Writes the comma after member `i` of the container at `depth`, and the comments that follow it.
@(private)
tree_tail :: #force_inline proc(w: ^Tree_Writer, i: core.Node_Index, depth: int, comma: bool, facts: []core.Fact) {
	if comma {
		write.put_byte(w.out, ',')
	}
	after_line := false
	for f in facts {
		root_foot := i == w.root && f.role == .Comment_Foot && f.lo >= w.close
		if f.role != .Comment_Inline && !root_foot {
			continue
		}
		if root_foot {
			tree_break(w)
		}
		if root_foot || after_line {
			write.put_line(w.out, w.opts, depth)
		} else if w.opts.pretty {
			write.put_byte(w.out, ' ')
		}
		after_line = tree_comment(w, f)
	}
	if i == w.root && after_line && w.opts.pretty {
		write.put_byte(w.out, '\n')
	}
}

// Fills the empty `list` with the members of the `Object` at `i`, in the order they are written.
@(private)
tree_pairs :: proc(w: ^Tree_Writer, i: core.Node_Index, list: ^[dynamic]Pair) -> bool {
	it := core.pairs(w.doc, i)
	for key, val in core.pair_next(&it) {
		name: string
		if w.opts.sort_keys {
			name = core.text_clone(w.doc, key) or_return
		}
		if _, failed := append(list, Pair{key, val, name}); failed != nil {
			delete(name)
			return false
		}
	}
	if w.opts.sort_keys {
		slice.stable_sort_by(list[:], proc(a, b: Pair) -> bool {return a.name < b.name})
	}
	return true
}

// Writes the scalar at `i`. A delimited text's cell is what `core.kind` reads it as.
@(private)
tree_scalar :: #force_inline proc(w: ^Tree_Writer, i: core.Node_Index) -> bool {
	doc := w.doc
	t := doc.nodes[i]
	w.held = true
	if w.respell && t.kind == .Number && t.spelling & core.NUMBER_KIND_MASK != 0 && doc.readers.number_text == nil {
		w.kind = write.put_decimal(w.out, string(doc.src[t.lo:t.lo + u64(t.n)]), t.spelling)
		return w.kind == .None
	}
	cell := t
	cell.kind = doc.readers.resolve(doc, i) if t.kind == .Plain && (w.resolve || t.n == 0) else t.kind
	w.kind = put_token(w.out, doc.src, doc, i, cell, w.opts, w.json, w.copy)
	return w.kind == .None
}

// Writes the open bracket of the container at `i` and fills its frame `f`, whose list is empty.
@(private)
tree_open :: proc(w: ^Tree_Writer, f: ^Tree_Frame, i: core.Node_Index, comma: bool, facts: []core.Fact) -> bool {
	t := w.doc.nodes[i]
	f.i, f.facts, f.object, f.comma, f.next, f.members = i, facts, t.kind == .Object, comma, 0, 0
	f.at, f.end = i + 1, i + core.Node_Index(t.n)
	write.put_byte(w.out, '{' if f.object else '[')
	w.held = false
	if f.object && !tree_pairs(w, i, &f.list) {
		w.kind = .No_Memory
		return false
	}
	return true
}

// The member of the container of `f` that is written next, with its key and whether a comma follows it.
@(private)
tree_member :: #force_inline proc(w: ^Tree_Writer, f: ^Tree_Frame) -> (i, key: core.Node_Index, comma, found: bool) #no_bounds_check {
	doc := w.doc
	if f.object {
		if f.next == len(f.list) {
			return
		}
		p := f.list[f.next]
		f.next += 1
		f.members += 1
		return p.val, p.key, f.next < len(f.list), true
	}
	for f.at < f.end {
		at := f.at
		f.at += core.Node_Index(doc.nodes[at].n) if doc.nodes[at].kind >= .Array else 1
		if at != core.header_of(doc) {
			f.members += 1
			return at, core.NO_NODE, f.at < f.end, true
		}
	}
	return
}

// Writes the feet of the container of `f` at `depth`, which are among its facts, and its close bracket.
@(private)
tree_close :: proc(w: ^Tree_Writer, f: ^Tree_Frame, depth: int) {
	feet := false
	if w.keep {
		for c in f.facts {
			if c.role == .Comment_Foot && (f.i != w.root || c.lo < w.close) {
				tree_break(w)
				write.put_line(w.out, w.opts, depth + 1)
				tree_comment(w, c)
				feet = true
			}
		}
	}
	if f.members > 0 || feet {
		write.put_line(w.out, w.opts, depth)
	}
	write.put_byte(w.out, '}' if f.object else ']')
	w.held = true
}
