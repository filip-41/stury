package write

import "base:intrinsics"
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
@(private = "file")
Open_Container :: struct {
	at:       tape.Node_Index,
	children: u32,
	object:   bool,
}

// The tokens so far.
Token_Tape :: struct {
	seq:    Sequence,
	nodes:  [dynamic]tape.Node,
	texts:  [dynamic]u8,
	counts: [dynamic]tape.Child_Count,
	open:   [dynamic]Open_Container,
}

// Starts `t`. With `framed` any number of root values are taken, and the document is the array of them.
@(require_results)
token_tape_start :: proc(t: ^Token_Tape, framed: bool, max_depth: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	t^ = {}
	if allocator.procedure == nil {
		return .Out_Of_Memory
	}
	t.nodes.allocator, t.texts.allocator, t.counts.allocator, t.open.allocator = allocator, allocator, allocator, allocator
	sequence_start(&t.seq, framed, max_depth, allocator)
	if framed {
		if _, err := append(&t.open, Open_Container{at = 0}); err != nil {
			token_tape_drop(t)
			return err
		}
		if _, err := append(&t.nodes, tape.Node{kind = .Array, role = .Value}); err != nil {
			token_tape_drop(t)
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
// must be UTF-8, and the decimal text of a `.Number`. A token the sequence cannot take is `Refused{index, .Malformed}`,
// a text with no spelling is `Refused{index, .No_Spelling}`, and a refused allocation is `runtime.Allocator_Error`;
// every error leaves `t` as it was.
@(require_results)
token_tape_take :: proc(t: ^Token_Tape, kind: Token_Kind, text: string) -> Error {
	spelling, ok := token_text_ok(kind, text)
	if !ok {
		return Refused{tape.Node_Index(t.seq.taken), .No_Spelling}
	}
	mark := sequence_mark(&t.seq)
	if _, err := sequence_take(&t.seq, kind); err != nil {
		return err
	}
	if err := token_tape_push(t, kind, text, spelling); err != nil {
		sequence_undo(&t.seq, mark)
		return err
	}
	return nil
}

@(private = "file", rodata)
TOKEN_KIND := [Token_Kind]tape.Kind {
	.Object = .Object,
	.Array  = .Array,
	.Key    = .String,
	.String = .String,
	.Number = .Number,
	.True   = .True,
	.False  = .False,
	.Null   = .Null,
	.Close  = .End,
}

// Appends an already-validated token `kind` with `text` and `spelling` to `t`, updating open containers and child
// counts transactionally so an OOM leaves `t` consistent.
@(private, require_results)
token_tape_push :: proc(t: ^Token_Tape, kind: Token_Kind, text: string, spelling: u16 = 0) -> Error {
	if kind == .Close {
		closed := t.open[len(t.open) - 1]
		count := closed.children
		if count >= u32(tape.MAX_CHILDREN) {
			if _, err := append(&t.counts, tape.Child_Count{node = closed.at, count = count}); err != nil {
				return err
			}
		}
		pop(&t.open)
		node := &t.nodes[closed.at]
		node.n = u32(len(t.nodes)) - u32(closed.at)
		node.spelling = u16(min(count, u32(tape.MAX_CHILDREN)))
		return nil
	}
	when size_of(int) > size_of(u32) {
		if len(t.nodes) >= int(tape.NO_NODE) {
			return .Out_Of_Memory
		}
	}
	node := tape.Node{kind = TOKEN_KIND[kind], role = .Key if kind == .Key else .Value, spelling = spelling, lo = u64(len(t.texts))}
	texts_len := len(t.texts)
	if kind == .Key || kind == .String || kind == .Number {
		when size_of(int) > size_of(u32) {
			if len(text) > int(max(u32)) {
				return .Out_Of_Memory
			}
		}
		node.n = u32(len(text))
		append(&t.texts, text) or_return
	}
	nodes_len := len(t.nodes)
	if _, err := append(&t.nodes, node); err != nil {
		(^runtime.Raw_Dynamic_Array)(&t.texts).len = texts_len
		return err
	}
	opens := kind == .Object || kind == .Array
	if opens {
		if _, err := append(&t.open, Open_Container{at = tape.Node_Index(nodes_len), object = kind == .Object}); err != nil {
			(^runtime.Raw_Dynamic_Array)(&t.nodes).len = nodes_len
			(^runtime.Raw_Dynamic_Array)(&t.texts).len = texts_len
			return err
		}
	}
	// A member counts at its key, an element at its value.
	parent := len(t.open) - (2 if opens else 1)
	if parent >= 0 && t.open[parent].object == (kind == .Key) {
		t.open[parent].children += 1
	}
	return nil
}

// Whether `text` is the text a token of `kind` takes: valid UTF-8 for a `.Key` or `.String`, a JSON number's text for a
// `.Number` (returning its packed `tape.Node.spelling` so `tape.number_form` matches parsed documents).
@(private, require_results)
token_text_ok :: proc "contextless" (kind: Token_Kind, text: string) -> (spelling: u16, ok: bool) {
	if kind == .Key || kind == .String {
		return 0, utf8.valid_string(text)
	}
	if kind != .Number {
		return 0, true
	}
	b := transmute([]u8)text
	if len(b) == 0 || (b[0] != '-' && b[0] - '0' >= 10) {
		return 0, false
	}
	p, end := raw_data(b), intrinsics.ptr_offset(raw_data(b), len(b))
	q, sp, err := tape.number_scan(p, end, true, false)
	return u16(sp), err == .None && q == end
}

// Empties a framed `t`, which holds its memory, to take the next tokens as a tape of its own. A document made of it is
// no longer valid. Precondition: `t` was started with `framed == true` (`cap(t.open) >= 1 && cap(t.nodes) >= 1`), so
// the two appends below cannot allocate.
@(private)
token_tape_reset :: proc(t: ^Token_Tape) {
	assert(t.seq.framed && cap(t.open) >= 1 && cap(t.nodes) >= 1)
	clear(&t.nodes)
	clear(&t.texts)
	clear(&t.counts)
	clear(&t.open)
	t.seq.depth, t.seq.has_root, t.seq.taken = 0, false, 0
	append(&t.open, Open_Container{at = 0})
	append(&t.nodes, tape.Node{kind = .Array, role = .Value})
}

// Whether the tokens so far are a whole text: no container open and a root written, or under `framed` any number.
@(require_results)
token_tape_done :: #force_inline proc "contextless" (t: ^Token_Tape) -> bool {
	return sequence_done(&t.seq)
}

// The neutral format of a `Token_Tape` document: decoded UTF-8 strings and strict decimal numbers, with no format
// identity, options, facts or capabilities, so target writers never mistake token input for a native read.
@(private = "file", rodata)
TOKEN_FORMAT := tape.Format {
	name      = "tokens",
	id        = 0,
	options   = .None,
	facts     = {},
	caps      = {},
	dups      = .Last,
	number    = proc "contextless" (src: []u8, t: tape.Node) -> spell.Number {
		n, _ := spell.number_strict(src, t.lo, t.lo + u64(t.n))
		return n
	},
	same_text = proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool {
		return t.n == o.n && string(src[t.lo:][:t.n]) == string(other[o.lo:][:o.n])
	},
	key_hash  = proc "contextless" (src: []u8, t: tape.Token) -> u32 {
		return tape.text_hash(src[t.lo:][:t.n])
	},
}

// The document of the tokens, whose nodes point into the tape under the neutral token format. It holds nothing of its
// own, so it is not destroyed and is valid until the tape is dropped. The tokens must be a whole text.
@(require_results)
token_tape_document :: proc(t: ^Token_Tape) -> (doc: tape.Document, err: runtime.Allocator_Error) {
	if t.seq.framed {
		count := t.open[0].children
		t.nodes[0].n = u32(len(t.nodes))
		t.nodes[0].spelling = u16(min(count, u32(tape.MAX_CHILDREN)))
		if count >= u32(tape.MAX_CHILDREN) {
			if len(t.counts) > 0 && t.counts[0].node == 0 {
				t.counts[0].count = count
			} else if _, err = append(&t.counts, tape.Child_Count{node = 0, count = count}); err != nil {
				return {}, err
			}
		}
	}
	if len(t.counts) > 1 {
		slice.sort_by(t.counts[:], proc(a, b: tape.Child_Count) -> bool { return a.node < b.node })
	}
	return {src = t.texts[:], nodes = t.nodes[:], counts = t.counts[:], format = &TOKEN_FORMAT, allocator = t.nodes.allocator}, nil
}

// Verifies `t` holds a whole sequence and materializes its neutral `tape.Document`.
@(private, require_results)
token_tape_finish :: proc(t: ^Token_Tape) -> (doc: tape.Document, err: Error) {
	if !token_tape_done(t) {
		return {}, Refused{tape.Node_Index(t.seq.taken), .Malformed}
	}
	doc = token_tape_document(t) or_return
	return doc, nil
}

// The token writer of a target that lays out a whole document: the tokens are held in a `Token_Tape`, the whole text
// whether it goes to a sink or a buffer, and the target's `write_out` writes their document at `tape_writer_end`. It
// points into itself, so it is not copied once `tape_writer_start` returns.
Tape_Writer :: struct {
	tokens:    Token_Tape,
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
	defer tape_writer_drop(w)
	doc := token_tape_finish(&w.tokens) or_return
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
