package write

import "base:runtime"
import "core:strconv"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// The token-writer protocol shared by streaming and buffered writers:
// - `Sequence` checks the grammar order a caller writes values in one token at a time (a container opens, holds its
//   members' keys with a value after each, or its elements, and closes; one root value, or any number under framing).
// - `tokens_of` walks any built `tape.Document` into a format's token writer, omitting document facts except tags for
//   targets that carry them, spelling byte strings as base64 `.String` and numbers via `number_text`.

// The tokens of a value, as `tape.Token_Kind` names them.
Token_Kind :: tape.Token_Kind

// The levels a sequence holds in itself. Past them its stack comes from the writer's allocator.
@(private = "file")
TOKEN_LEVELS :: 64
#assert(TOKEN_LEVELS > 0, "the stack doubles as it grows")

@(private = "file")
Level_Flag :: enum u8 {
	Object,
	Filled, // the container holds a member or element
	Key,    // an object's key waits for its value
}

@(private = "file")
Level_Flags :: bit_set[Level_Flag; u8]

// What the layout of a token depends on.
Place :: struct {
	depth:  int, // containers open around it, a close's own not counted
	first:  bool, // the first member or element of its container
	object: bool, // inside an object, and for a close the container it closes is one
	value:  bool, // the value of the key before it
	root:   bool, // at the top level
	empty:  bool, // a close of a container that holds nothing
}

// The state of a token sequence. It points into itself, so it is not copied once started.
Sequence :: struct {
	levels:    [^]Level_Flags,
	held:      int,
	depth:     int,
	taken:     int, // the tokens taken, which a refusal names
	max_depth: int,
	allocator: runtime.Allocator,
	framed:    bool, // any number of root values
	has_root:  bool, // at least one root value has been taken
	inline:    [TOKEN_LEVELS]Level_Flags,
}

when size_of(int) == 8 {
	#assert(size_of(Sequence) == 128)
}

// Snapshot of `Sequence` state before `sequence_take`, for rolling back when a caller's own push hits OOM.
@(private)
Sequence_Mark :: struct {
	depth:    int,
	top:      Level_Flags,
	has_root: bool,
}

// Starts `s`, which is to hold at most `max_depth` open containers (`tape.DEFAULT_DEPTH` for `<= 0`).
sequence_start :: proc(s: ^Sequence, framed: bool, max_depth: int, allocator: runtime.Allocator) {
	s^ = {framed = framed, max_depth = max_depth if max_depth > 0 else tape.DEFAULT_DEPTH, allocator = allocator, held = TOKEN_LEVELS}
	s.levels = &s.inline[0]
}

// Frees what `s` grew past its own levels.
sequence_drop :: proc(s: ^Sequence) {
	free_stack(s.levels, s.held, TOKEN_LEVELS, s.allocator)
	s.levels, s.held = nil, 0
}

// Whether the tokens so far are a whole text: no container open, and either a root was written or `s.framed`.
@(require_results)
sequence_done :: proc "contextless" (s: ^Sequence) -> bool {
	return s.depth == 0 && (s.has_root || s.framed)
}

@(private, require_results)
sequence_mark :: #force_inline proc "contextless" (s: ^Sequence) -> Sequence_Mark {
	top: Level_Flags
	if s.depth > 0 {
		top = s.levels[s.depth - 1]
	}
	return {depth = s.depth, top = top, has_root = s.has_root}
}

@(private, cold)
sequence_undo :: #force_no_inline proc "contextless" (s: ^Sequence, m: Sequence_Mark) {
	s.depth = m.depth
	s.has_root = m.has_root
	s.taken -= 1
	if m.depth > 0 {
		s.levels[m.depth - 1] = m.top
	}
}

// Takes token `kind`. A token this place cannot hold is `Refused{index, .Malformed}` and a failed stack growth is
// `runtime.Allocator_Error`; either leaves `s` as it was.
@(require_results)
sequence_take :: proc(s: ^Sequence, kind: Token_Kind) -> (p: Place, err: Error) {
	malformed := Refused{tape.Node_Index(s.taken), .Malformed}
	p = {depth = s.depth, root = s.depth == 0}
	top: ^Level_Flags
	if s.depth > 0 {
		top = &s.levels[s.depth - 1]
		p.object, p.first = .Object in top^, .Filled not_in top^
	}
	switch kind {
	case .Close:
		if s.depth == 0 || .Key in top^ {
			return {}, malformed
		}
		s.depth -= 1
		p = {depth = s.depth, root = s.depth == 0, empty = p.first, object = p.object}
		s.taken += 1
		return p, nil
	case .Key:
		if top == nil || !p.object || .Key in top^ {
			return {}, malformed
		}
		top^ += {.Key}
		s.taken += 1
		return p, nil
	case .Object, .Array, .String, .Number, .True, .False, .Null:
	}
	switch {
	case top == nil:
		if s.has_root && !s.framed {
			return {}, malformed
		}
	case p.object:
		if .Key not_in top^ {
			return {}, malformed
		}
		p.value = true
	}
	opens := kind == .Object || kind == .Array
	if opens && s.depth >= s.max_depth {
		return {}, malformed
	}
	if opens && s.depth == s.held && !grow_stack(&s.levels, &s.held, TOKEN_LEVELS, s.allocator, &err) {
		return {}, err
	}
	if top != nil {
		// Reload `top` because `grow_stack` above may have reallocated `s.levels`.
		top = &s.levels[s.depth - 1]
		top^ = (top^ - {.Key}) + {.Filled}
	} else {
		s.has_root = true
	}
	if opens {
		s.levels[s.depth] = {.Object} if kind == .Object else {}
		s.depth += 1
	}
	s.taken += 1
	return p, nil
}

// Gives the tokens of value `node` of `doc` to `token`, which takes the writer `w`, the kind of the token and its text,
// and returns the error that stops the walk. A value a token cannot spell is `Refused` with its node, as a partial
// container is.
@(require_results)
tokens_of :: proc(
	doc: ^tape.Document,
	node: tape.Node_Index,
	w: ^$W,
	$token: proc(w: ^W, kind: Token_Kind, text: string) -> Error,
	allocator: runtime.Allocator,
	tag: proc(w: ^W, name: string) -> Error = nil,
) -> (err: Error) {
	t: Tree
	if err = tree_start(&t, doc, {node = node}, {}, allocator); err != nil {
		return
	}
	defer tree_end(&t)
	tables := tree_tables(&t)
	tagged := tag != nil && .Tag in doc.present
	for err == nil {
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
				return no_spelling(&t, s.key)
			}
			if err = token(w, .Key, text); err != nil {
				return
			}
		} else if s.cell {
			text, ok := text_of_token(&t, t.cell)
			if !ok {
				return no_spelling(&t, s.node)
			}
			if err = token(w, .Key, text); err != nil {
				return
			}
		}
		n := t.nodes[s.node]
		// Byte strings emit as base64 `.String`, so raw-bytes tags (CBOR tag 24, MessagePack ext) do not apply.
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
			buf: [NUMBER_ROOM]u8 = ---
			text, ok := number_text(&t, s.node, &buf)
			if !ok {
				return no_spelling(&t, s.node)
			}
			err = token(w, .Number, text)
		case .Bytes:
			text, ok := bytes_base64(&t, s.node)
			if !ok {
				return no_spelling(&t, s.node)
			}
			err = token(w, .String, text)
			delete(text, allocator)
		case .String, .Plain:
			text, ok := text_of(&t, s.node)
			if !ok {
				return no_spelling(&t, s.node)
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

@(private = "file", cold, require_results)
no_spelling :: #force_no_inline proc "contextless" (t: ^Tree, at: tape.Node_Index) -> Error {
	if t.err != nil {
		return t.err
	}
	return Refused{at, .No_Spelling}
}

// Gives `tag` the tags of node `at`, each a name: a date-time's type a format spells (`datetime`, `date-local`), the text
// of a tag a text holds (`!!timestamp`), or the number of a binary format's tag in decimal.
@(private = "file", cold, require_results)
node_tags :: #force_no_inline proc(t: ^Tree, at: tape.Node_Index, w: ^$W, tag: proc(w: ^W, name: string) -> Error) -> Error {
	doc := t.doc
	// Monotonic linear advance keeps `t.fact` synced across the walk instead of binary-searching `doc.facts` per node.
	lo := node_facts(t, at)
	// Return immediately when `fact_name` resolves a spelled tag (e.g. MessagePack Timestamp `ext -1` carries both
	// `spelled_fact == "datetime"` and a raw `.Tag` fact in `doc.facts`).
	if name, ok := tape.fact_name(doc, at, .Tag); ok {
		return tag(w, name)
	}
	for f in t.facts[lo:t.fact] {
		if f.kind != .Tag || f.n == 0 {
			continue
		}
		if doc.format == nil || .Binary not_in doc.format.caps {
			tag(w, string(tape.span_bytes(doc, f.lo, f.n))) or_return
			continue
		}
		if n, ok := tape.fact_number(doc, f); ok {
			buf: [20]u8 = ---
			tag(w, tag_number_text(buf[:], n)) or_return
		}
	}
	return nil
}

@(private = "file")
tag_number_text :: proc(buf: []u8, n: spell.Number) -> string {
	if n.kind == .Int {
		return strconv.write_int(buf, i64(n.bits), 10)
	}
	return strconv.write_uint(buf, n.bits, 10)
}
