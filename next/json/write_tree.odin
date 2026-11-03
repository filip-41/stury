package json

import "base:runtime"
import "core:io"
import "core:slice"
import "core:strconv"
import "core:unicode/utf8"
import spell "../core/spell"
import core "../core"
import write "../core/write"

// The tree writer: the documents the row walk leaves out. It walks the document by its containers, one level of the
// call stack each, and writes each member's comments around it, so it is slow and handles everything: comments, sorted
// keys, shared keys, the spelling of a JSON5 text in JSON, and a partial document. The row walk of `write_document.odin`
// writes every other document and calls nothing of this file.
//
// A comment is a fact of the member's value node. A `Comment` stands before the member, or between its key and its value
// when its bytes follow the key's. A `Comment_Inline` follows the member and its comma. A `Comment_Foot` of a container
// stands on a line of its own before the close, and one of the root that follows the root's close stands after it.

// The deepest container the recursion enters. A document built under a larger `max_depth` is `.Too_Deep` here.
@(private)
TREE_DEPTH :: 4096

@(private)
Tree :: struct {
	doc:     ^core.Document,
	root:    core.Node_Index, // the node written as the text's root
	out:     ^write.Out,
	opts:    core.Write_Options,
	close:   u64, // the byte past `root`, where the document root's feet that follow it begin
	dropped: int, // the facts the target cannot hold
	kind:    core.Typed_Error_Kind, // what stopped the write
	json:    bool, // the document is JSON's, in any spec
	keep:    bool, // facts are written as comments
	respell: bool, // JSON5's spelling of a string and a number is spelled again for JSON
	copy:    bool, // a string is written as it was authored
}

// A member of a `Map` as the tree writer orders them. `name` is the decoded key under `sort_keys`.
@(private)
Pair :: struct {
	key, val: core.Node_Index,
	name:     string,
}

// Whether the row walk cannot write the subtree at `node`. A JSON5 document is the row walk's only when it is written as
// it was authored.
@(private)
document_cold :: proc(doc: ^core.Document, opts: core.Write_Options, own: bool, node: core.Node_Index) -> bool {
	return !own || len(core.subtree_facts(doc, node)) != 0 || opts.sort_keys || doc.shared_keys != 0 || Spec(doc.read.spec) == .Json5
}

// Writes node `node` of `doc` as spec `as`, into an output of `hint` bytes. The count is the facts `as` cannot hold.
@(private)
write_tree :: proc(doc: ^core.Document, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator, as: Spec, node: core.Node_Index, hint: int) -> (text: []u8, dropped: int, err: core.Typed_Error) {
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill, allocator, stream, hint)
	w := Tree{doc = doc, root = node, out = &out, opts = opts, json = doc.spelling == &SPELLING}
	w.keep = w.json && as != .Json
	w.respell = w.json && Spec(doc.read.spec) == .Json5 && as != .Json5
	w.copy = w.json && !w.respell && copies_strings(opts)
	if w.keep {
		root := doc.nodes[node]
		_, w.close = core.scalar_ends(root)
		if root.kind >= .Array {
			w.close = doc.spelling.close_end(doc, node)
		}
	} else {
		w.dropped = len(core.subtree_facts(doc, node))
	}
	if !tree_entry(&w, node, core.NO_NODE, 0, false) {
		write.destroy(&out)
		return nil, 0, {kind = w.kind}
	}
	text, err = write.finish((^write.Out)(rawptr(&out)))
	if err.kind != .None {
		return nil, 0, err
	}
	return text, w.dropped, err
}

// Writes fact `f` with its markers. A line comment ends its line in compact text, since nothing may follow it there.
// `ascii` and `escape_html` respell a comment's characters as they do a string's, as literal text. Returns whether it is a
// line comment.
@(private)
tree_comment :: proc(w: ^Tree, f: core.Fact) -> (line: bool) {
	text := w.doc.src[f.lo:f.lo + u64(f.n)]
	line = text[1] == '/'
	if w.opts.ascii || w.opts.escape_html {
		for r in string(text) {
			if r >= 0x80 && w.opts.ascii || w.opts.escape_html && (r == '<' || r == '>' || r == '&' || r == 0x2028 || r == 0x2029) {
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
	return
}

// Writes member `i` of the container at `depth`: the comments before it, its key `key` when it has one, its value, its
// comma, and the comments that follow. The root is entered with no key.
@(private)
tree_entry :: proc(w: ^Tree, i, key: core.Node_Index, depth: int, comma: bool) -> bool {
	doc := w.doc
	facts := core.all_facts(doc, i) if w.keep else nil
	key_lo := max(u64)
	if key != core.NO_NODE {
		key_lo = core.node_start(doc.nodes[key])
	}
	for f in facts {
		if f.role == .Comment && f.lo < key_lo {
			tree_comment(w, f)
			write.put_line(w.out, w.opts, depth)
		}
	}
	if key != core.NO_NODE {
		tree_string(w, key) or_return
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
	tree_value(w, i, depth) or_return
	if comma {
		write.put_byte(w.out, ',')
	}
	after_line := false
	for f in facts {
		root_foot := i == w.root && f.role == .Comment_Foot && f.lo >= w.close
		if f.role != .Comment_Inline && !root_foot {
			continue
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
	return true
}

// The members of the `Map` at `i`, in the order they are written.
@(private)
tree_pairs :: proc(w: ^Tree, i: core.Node_Index) -> (list: [dynamic]Pair, ok: bool) {
	it := core.pairs(w.doc, i)
	for key, val in core.pair_next(&it) {
		name: string
		if w.opts.sort_keys {
			name = core.text_clone(w.doc, key) or_return
		}
		if _, failed := append(&list, Pair{key, val, name}); failed != nil {
			delete(name)
			return
		}
	}
	if w.opts.sort_keys {
		slice.stable_sort_by(list[:], proc(a, b: Pair) -> bool {return a.name < b.name})
	}
	return list, true
}

// Writes the value at `i`: a scalar, or a container with its members and its feet.
@(private)
tree_value :: proc(w: ^Tree, i: core.Node_Index, depth: int) -> bool {
	doc := w.doc
	t := doc.nodes[i]
	if t.kind < .Array {
		return tree_scalar(w, i, t)
	}
	if depth >= TREE_DEPTH {
		w.kind = .Too_Deep
		return false
	}
	map_ := t.kind == .Map
	write.put_byte(w.out, '{' if map_ else '[')
	members := 0
	if map_ {
		list, ok := tree_pairs(w, i)
		defer {
			for p in list {
				delete(p.name)
			}
			delete(list)
		}
		if !ok {
			w.kind = .Out_Of_Memory
			return false
		}
		for p, k in list {
			write.put_line(w.out, w.opts, depth + 1)
			tree_entry(w, p.val, p.key, depth + 1, k + 1 < len(list)) or_return
		}
		members = len(list)
	} else {
		end := i + core.Node_Index(t.n)
		for at := i + 1; at < end; {
			step := core.Node_Index(1)
			if doc.nodes[at].kind >= .Array {
				step = core.Node_Index(doc.nodes[at].n)
			}
			if at == doc.shared_keys {
				at += step
				continue
			}
			write.put_line(w.out, w.opts, depth + 1)
			tree_entry(w, at, core.NO_NODE, depth + 1, at + step < end) or_return
			at += step
			members += 1
		}
	}
	feet := false
	if w.keep {
		for f in core.all_facts(doc, i) {
			if f.role == .Comment_Foot && (i != w.root || f.lo < w.close) {
				write.put_line(w.out, w.opts, depth + 1)
				tree_comment(w, f)
				feet = true
			}
		}
	}
	if members > 0 || feet {
		write.put_line(w.out, w.opts, depth)
	}
	write.put_byte(w.out, '}' if map_ else ']')
	return true
}

// Writes scalar `i`. A delimited text's cell is a string, or with `infer` what `core.resolve` reads it as.
@(private)
tree_scalar :: proc(w: ^Tree, i: core.Node_Index, t: core.Token) -> bool {
	if w.respell && t.kind == .Number {
		return tree_number(w, t)
	}
	cell := t
	if cell.kind == .Plain && w.opts.infer {
		cell.kind = core.resolve(w.doc, i, {infer = true})
	}
	w.kind = put_token(w.out, w.doc.src, w.doc, i, cell, w.opts, w.json, w.copy)
	return w.kind == .None
}

// Writes the string or key at `i`.
@(private)
tree_string :: proc(w: ^Tree, i: core.Node_Index) -> bool {
	w.kind = put_token_string(w.out, w.doc.src, w.doc, i, w.doc.nodes[i], w.opts, w.json, w.copy)
	return w.kind == .None
}

// Writes a JSON5 number as JSON spells it.
@(private)
tree_number :: proc(w: ^Tree, t: core.Token) -> bool {
	lit := string(w.doc.src[t.lo:t.lo + u64(t.n)])
	p := 1 if lit[0] == '+' || lit[0] == '-' else 0
	switch number_spelling_of(t.spelling) {
	case .Json:
		write.put_text(w.out, lit)
	case .Decimal:
		if lit[0] == '-' {
			write.put_byte(w.out, '-')
		}
		if lit[p] == '.' {
			write.put_byte(w.out, '0')
		}
		for k in p ..< len(lit) {
			if lit[k] != '.' || k + 1 < len(lit) && lit[k + 1] - '0' < 10 {
				write.put_byte(w.out, lit[k])
			}
		}
	case .Hex:
		if lit[0] == '-' {
			write.put_byte(w.out, '-')
		}
		if !put_hex_decimal(w.out, lit[p + 2:]) {
			w.kind = .Out_Of_Memory
			return false
		}
	case .Infinity, .Nan:
		w.kind = .Non_Finite
		return false
	}
	return true
}

// Writes the hex digits `hex` as the exact decimal integer they spell, at any length, kept in base 10^9 words with the
// least significant first. Returns false when the words cannot be held.
@(private)
put_hex_decimal :: proc(out: ^write.Out, hex: string) -> bool {
	BASE :: 1_000_000_000
	words, failed := make([dynamic]u32, 0, len(hex) / 7 + 1)
	if failed != nil {
		return false
	}
	defer delete(words)
	for c in transmute([]u8)hex {
		carry := u64(spell.HEX_NIBBLE[c])
		for &w in words {
			x := u64(w) * 16 + carry
			w, carry = u32(x % BASE), x / BASE
		}
		if carry > 0 {
			if _, no_word := append(&words, u32(carry)); no_word != nil {
				return false
			}
		}
	}
	if len(words) == 0 {
		write.put_byte(out, '0')
		return true
	}
	buf: [16]u8
	write.put_text(out, strconv.write_uint(buf[:], u64(words[len(words) - 1]), 10))
	#reverse for w in words[:len(words) - 1] {
		s := strconv.write_uint(buf[:], u64(w), 10)
		for _ in len(s) ..< 9 {
			write.put_byte(out, '0')
		}
		write.put_text(out, s)
	}
	return true
}
