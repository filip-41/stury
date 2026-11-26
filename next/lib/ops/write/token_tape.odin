package write

import "base:runtime"
import "core:io"
import "core:slice"
import "core:unicode/utf8"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// The tokens of a target that lays out a whole document, which a token writer cannot write as they come: TOML puts a
// table's own keys before its tables, XML's element is a member of an object, and a table's header is the first row's
// keys or every row's. A `Token_Tape` holds the tokens as the nodes of a document, which the target's own `write` then
// writes, so a target needs no second layout for tokens. The order is judged as a `Sequence` judges it.

// A node's text lies in `texts`, and an open container's place and children so far in `open`.
@(private)
Open_Container :: struct {
	at:       tape.Node_Index,
	children: u32,
	object:   bool,
}

// The tokens so far.
Token_Tape :: struct {
	seq:       Sequence,
	nodes:     [dynamic]tape.Node,
	texts:     [dynamic]u8,
	counts:    [dynamic]tape.Child_Count,
	open:      [dynamic]Open_Container,
	framed:    bool, // every root value is an element of a root array the tape makes
	allocator: runtime.Allocator,
}

// Starts `t`. With `framed` any number of root values are taken, and the document is the array of them.
token_tape_start :: proc(t: ^Token_Tape, framed: bool, max_depth: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	t^ = {framed = framed, allocator = allocator}
	t.nodes.allocator, t.texts.allocator, t.counts.allocator, t.open.allocator = allocator, allocator, allocator, allocator
	sequence_start(&t.seq, framed, max_depth, allocator)
	if framed {
		if _, err := append(&t.open, Open_Container{at = 0}); err != nil {
			return err
		}
		if _, err := append(&t.nodes, tape.Node{kind = .Array, role = .Value}); err != nil {
			return err
		}
	}
	return nil
}

// Frees what `t` holds. A document `token_tape_document` made of it is no longer valid.
token_tape_drop :: proc(t: ^Token_Tape) {
	sequence_drop(&t.seq)
	delete(t.nodes)
	delete(t.texts)
	delete(t.counts)
	delete(t.open)
	t^ = {}
}

// Takes token `kind` with its `text`, as `sequence_take` judges it: the decoded text of a `.Key` or `.String`, which
// must be UTF-8, and the decimal text of a `.Number`. A token the sequence cannot take is `Refused{index, .Malformed}`
// and leaves `t` as it was, and a text with no spelling is `Refused{index, .No_Spelling}`.
token_tape_take :: proc(t: ^Token_Tape, kind: Token_Kind, text: string) -> Error {
	if !token_text_ok(kind, text) {
		return Refused{tape.Node_Index(t.seq.taken), .No_Spelling}
	}
	if _, err := sequence_take(&t.seq, kind); err != nil {
		return err
	}
	return token_tape_push(t, kind, text)
}

// Appends an already-validated token `kind` with `text` to `t`, updating open containers and child counts.
@(private)
token_tape_push :: proc(t: ^Token_Tape, kind: Token_Kind, text: string) -> Error {
	if kind == .Close {
		closed := pop(&t.open)
		count := closed.children
		node := &t.nodes[closed.at]
		node.n = u32(len(t.nodes)) - u32(closed.at)
		node.spelling = u16(min(count, u32(tape.MAX_CHILDREN)))
		if count >= u32(tape.MAX_CHILDREN) {
			if _, err := append(&t.counts, tape.Child_Count{node = closed.at, count = count}); err != nil {
				return err
			}
		}
		return nil
	}
	// A member counts at its key, an element at its value.
	if len(t.open) > 0 && t.open[len(t.open) - 1].object == (kind == .Key) {
		t.open[len(t.open) - 1].children += 1
	}
	node := tape.Node{lo = u64(len(t.texts)), role = .Key if kind == .Key else .Value}
	switch kind {
	case .Key, .String:
		node.kind = .String
		node.n = u32(len(text))
		append(&t.texts, text) or_return
	case .Number:
		node.kind = .Number
		node.n = u32(len(text))
		append(&t.texts, text) or_return
	case .True:
		node.kind = .True
	case .False:
		node.kind = .False
	case .Null:
		node.kind = .Null
	case .Object:
		node.kind = .Object
	case .Array:
		node.kind = .Array
	case .Close:
	}
	if kind == .Object || kind == .Array {
		append(&t.open, Open_Container{at = tape.Node_Index(len(t.nodes)), object = kind == .Object}) or_return
	}
	if _, err := append(&t.nodes, node); err != nil {
		return err
	}
	return nil
}

// Whether `text` is the text a token of `kind` takes: valid UTF-8 for a `.Key` or `.String`, a JSON number's text for a
// `.Number`.
@(private)
token_text_ok :: proc "contextless" (kind: Token_Kind, text: string) -> bool {
	if kind == .Key || kind == .String {
		return utf8.valid_string(text)
	}
	return kind != .Number || is_json_number(transmute([]u8)text)
}

// Empties a framed `t`, which holds its memory, to take the next tokens as a tape of its own. A document made of it is
// no longer valid.
@(private)
token_tape_reset :: proc(t: ^Token_Tape) {
	clear(&t.nodes)
	clear(&t.texts)
	clear(&t.counts)
	clear(&t.open)
	t.seq.depth, t.seq.roots, t.seq.taken = 0, 0, 0
	append(&t.open, Open_Container{at = 0})
	append(&t.nodes, tape.Node{kind = .Array, role = .Value})
}

// Whether the tokens so far are a whole text: no container open and a root written, or under `framed` any number.
token_tape_done :: proc "contextless" (t: ^Token_Tape) -> bool {
	return sequence_done(&t.seq) || t.framed && t.seq.depth == 0
}

// The neutral format of a `Token_Tape` document: decoded UTF-8 strings and strict decimal numbers, with no format
// identity, options, facts or capabilities, so target writers never mistake token input for a native read.
@(private, rodata)
TOKEN_FORMAT := tape.Format {
	name      = "tokens",
	id        = 0,
	options   = .None,
	facts     = {},
	caps      = {},
	dups      = .Last,
	number    = token_number,
	same_text = token_same_text,
	key_hash  = token_key_hash,
}

@(private)
token_number :: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number {
	n, _ := spell.number_strict(src, t.lo, t.lo + u64(t.n))
	return n
}

@(private)
token_same_text :: proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool {
	return t.n == o.n && string(src[t.lo:][:t.n]) == string(other[o.lo:][:o.n])
}

@(private)
token_key_hash :: proc "contextless" (src: []u8, t: tape.Token) -> u32 {
	return tape.text_hash(src[t.lo:][:t.n])
}

// The document of the tokens, whose nodes point into the tape under the neutral token format. It holds nothing of its
// own, so it is not destroyed and is valid until the tape is dropped. The tokens must be a whole text.
token_tape_document :: proc(t: ^Token_Tape) -> (doc: tape.Document, err: runtime.Allocator_Error) {
	if t.framed {
		count := t.open[0].children
		t.nodes[0].n = u32(len(t.nodes))
		t.nodes[0].spelling = u16(min(count, u32(tape.MAX_CHILDREN)))
		if count >= u32(tape.MAX_CHILDREN) {
			if _, err = append(&t.counts, tape.Child_Count{node = 0, count = count}); err != nil {
				return {}, err
			}
		}
	}
	slice.sort_by(t.counts[:], proc(a, b: tape.Child_Count) -> bool {return a.node < b.node})
	return {src = t.texts[:], nodes = t.nodes[:], counts = t.counts[:], format = &TOKEN_FORMAT, allocator = t.allocator}, nil
}

// The token writer of a target that lays out a whole document: the tokens are held in a `Token_Tape`, the whole text
// whether it goes to a sink or a buffer, and the target's `write_out` writes their document at `tape_writer_end`. It
// points into itself, so it is not copied once `tape_writer_start` returns.
Tape_Writer :: struct {
	tokens:    Token_Tape,
	// Facts of the tokens' nodes in node order, which the caller owns and may set before `tape_writer_end`.
	facts:     []tape.Fact,
	write_out: Write_Out,
	opts:      Options,
	sink:      io.Writer,
	allocator: runtime.Allocator,
	spec:      u8,
}

// Starts `w` to write a text of `spec` under `opts` by `write_out` into `sink`, or into a buffer from `allocator` when
// `sink` has no procedure. The target judges `spec` and `opts` first. Tokens hold no node to start at, so `opts.node`
// is `Bad_Option{"node"}`.
@(require_results)
tape_writer_start :: proc(w: ^Tape_Writer, spec: u8, opts: Options, sink: io.Writer, allocator: runtime.Allocator, write_out: Write_Out) -> Error {
	if opts.node != tape.ROOT {
		return tape.Bad_Option{"node"}
	}
	w^ = {write_out = write_out, opts = opts, sink = sink, allocator = allocator, spec = spec}
	token_tape_start(&w.tokens, false, 0, allocator) or_return
	return nil
}

// Ends `w` and writes its text: the bytes of a buffer writer, which the caller owns and frees with `w`'s allocator, or
// none for a sink writer. A text that is no whole sequence is `Refused{index, .Malformed}`, and a refusal of
// `write_out` names a node of the tokens' document. `w`'s tokens are freed, and `w` is not used again.
@(require_results)
tape_writer_end :: proc(w: ^Tape_Writer) -> (text: []u8, err: Error) {
	defer token_tape_drop(&w.tokens)
	if !token_tape_done(&w.tokens) {
		return nil, Refused{tape.Node_Index(w.tokens.seq.taken), .Malformed}
	}
	doc := token_tape_document(&w.tokens) or_return
	doc.facts = w.facts
	for f in w.facts {
		doc.present += {f.kind}
	}
	if w.sink.procedure != nil {
		_, err = to_sink(w.sink, &doc, w.spec, w.opts, w.allocator, w.write_out)
		return nil, err
	}
	text, _, err = to_buffer(&doc, w.spec, w.opts, w.allocator, w.write_out)
	return
}

// Frees what `w` holds without writing text. `w` is not used again.
tape_writer_drop :: proc(w: ^Tape_Writer) {
	token_tape_drop(&w.tokens)
	w^ = {}
}
