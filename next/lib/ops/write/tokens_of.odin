package write

import "base:runtime"
import "core:strconv"
import "stury:lib/core/tape"

// The one path from a document to tokens, which a format's token writer takes a record's value, or a document of any
// other format, by: the target's own `token` is called for each token of the value in order, with the facts of the
// document left out, as a token carries none, but for the tags of a target that has them, see `tag`. A byte string is the string of its base64, as the writers that have no
// bytes spell it, and a number the decimal text `number_text` gives.

// Gives the tokens of value `node` of `doc` to `token`, which takes the writer `w`, the kind of the token and its text, and
// returns the error that stops the walk. A value a token cannot spell is `Refused` with its node, as a partial
// container is.
tokens_of :: proc(doc: ^tape.Document, node: tape.Node_Index, w: ^$W, $token: proc(w: ^W, kind: Token_Kind, text: string) -> Error, allocator: runtime.Allocator, tag: proc(w: ^W, name: string) -> Error = nil) -> (err: Error) {
	t: Tree
	if err = tree_start(&t, doc, {node = node}, {}, allocator); err != nil {
		return
	}
	defer tree_end(&t)
	tables := tree_tables(&t)
	tagged := tag != nil && .Tag in doc.present
	for t.err == nil && err == nil {
		s := tree_next(&t, false, true) if tables else tree_next(&t, false, false)
		if s.kind == .Done {
			break
		}
		if s.kind == .Close {
			err = token(w, .Close, "")
			continue
		}
		if s.key != tape.NO_NODE {
			text, ok := text_of(&t, s.key)
			if !ok {
				break
			}
			if t.nodes[s.key].kind > .Plain {
				return Refused{s.key, .No_Spelling}
			}
			if err = token(w, .Key, text); err != nil {
				return
			}
		} else if s.cell {
			text, ok := text_of_token(&t, t.cell)
			if !ok {
				break
			}
			if err = token(w, .Key, text); err != nil {
				return
			}
		}
		n := t.nodes[s.node]
		if tagged && n.kind != .Bytes {
			if err = node_tags(&t, s.node, w, tag); err != nil {
				return
			}
		}
		switch n.kind {
		case .Object:
			err = token(w, .Object, "")
		case .Array:
			err = token(w, .Array, "")
		case .Null:
			err = token(w, .Null, "")
		case .True:
			err = token(w, .True, "")
		case .False:
			err = token(w, .False, "")
		case .Number:
			buf: [NUMBER_ROOM]u8
			text, ok := number_text(&t, s.node, &buf)
			if !ok {
				if t.err == nil {
					t.err = Refused{s.node, .No_Spelling}
				}
				break
			}
			err = token(w, .Number, text)
		case .Bytes:
			text, ok := bytes_base64(&t, s.node)
			if !ok {
				break
			}
			err = token(w, .String, text)
			delete(text, allocator)
		case .String, .Plain:
			text, ok := text_of(&t, s.node)
			if !ok {
				break
			}
			err = token(w, .String, text)
		case .End:
		}
	}
	if err == nil {
		err = t.err
	}
	return
}

// Gives `tag` the tags of node `at`, each a name: a date-time's type a format spells (`datetime`, `date-local`), the text
// of a tag a text holds (`!!timestamp`), or the number of a binary format's tag in decimal.
@(private)
node_tags :: proc(t: ^Tree, at: tape.Node_Index, w: ^$W, tag: proc(w: ^W, name: string) -> Error) -> Error {
	doc := t.doc
	if doc.format.fact_name != nil {
		if name, ok := doc.format.fact_name(doc, at, .Tag); ok {
			return tag(w, name)
		}
	}
	for f in tape.facts_of(doc, at) {
		if f.kind != .Tag || f.n == 0 {
			continue
		}
		if .Binary not_in doc.format.caps {
			tag(w, string(tape.span_bytes(doc, f.lo, f.n))) or_return
			continue
		}
		if n, ok := tape.fact_number(doc, f); ok {
			buf: [20]u8
			tag(w, uint_text(buf[:], n.bits)) or_return
		}
	}
	return nil
}

@(private)
uint_text :: proc(buf: []u8, v: u64) -> string {
	return strconv.write_uint(buf, v, 10)
}
