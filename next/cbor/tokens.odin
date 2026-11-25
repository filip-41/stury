package cbor

import "base:runtime"
import "core:io"
import "core:unicode/utf8"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"
import "stury:lib/ops/write"

// The token writer of CBOR: a caller writes one item token by token. A container of unknown length is indefinite
// (RFC 8949 section 3.2.2), so the item is well formed and holds the values, but it is not in preferred form; a
// document's write is, and is the way to deterministic bytes. Numbers are the shortest integer or float that holds
// the text, and an integer past 64 bits a bignum.

// An item being written token by token. It points into itself, so it is not copied once `writer_start` returns.
Writer :: struct {
	out:  write.Out,
	seq:  write.Sequence,
	tags: [MAX_PENDING_TAGS]Text_Tag, // the tags of the next value, in the order given
	held: int,
}

// Starts `w` to write into `sink`, or into a buffer from `allocator` when `sink` has no procedure, which `writer_end`
// returns. `opts` takes nothing a CBOR token writer has no use for: an indent, `ascii`, `node`, `sort_keys`, a framing,
// `grow_header`, `header` and `format` are `Bad_Option`.
writer_start :: proc(w: ^Writer, opts := Write_Options{}, sink := io.Writer{}, allocator := context.allocator) -> Write_Error {
	if opts.indent != 0 || opts.tab || opts.ascii || opts.node != 0 || opts.sort_keys || opts.framing != .None || opts.grow_header || len(opts.header) > 0 || opts.format != nil {
		return tape.Bad_Option{"options"}
	}
	w^ = {}
	write.sequence_start(&w.seq, false, 0, allocator)
	if e := write.out_start(&w.out, allocator, sink, 0); e != nil {
		write.sequence_drop(&w.seq)
		return e
	}
	return nil
}

// The tags of one value `tag` is called for.
@(private)
MAX_PENDING_TAGS :: 4

// Tags the next value, which may be a key, with CBOR tag `number`. The tag is written with the value, and dropped when
// the next token closes a container. More than `MAX_PENDING_TAGS` for one value is `Refused{index, .Malformed}`.
tag :: proc(w: ^Writer, number: u64) -> Write_Error {
	if w.held == len(w.tags) {
		return write.Refused{tape.Node_Index(w.seq.taken), .Malformed}
	}
	w.tags[w.held] = {kind = .Number, number = number}
	w.held += 1
	return nil
}

// String-tag adapter for `write.tokens_of` and `typed.marshal`: accepts decimal tag numbers and named date-time tags.
@(private)
tag_text :: proc(w: ^Writer, name: string) -> Write_Error {
	t, ok := text_tag_of(name)
	if !ok {
		return nil
	}
	if w.held == len(w.tags) {
		return write.Refused{tape.Node_Index(w.seq.taken), .Malformed}
	}
	w.tags[w.held] = t
	w.held += 1
	return nil
}

// Writes the value of `doc`, a document of any format, at `node` as tokens, with its tags that CBOR spells, a
// record's value as `dsv.put` writes one.
put :: proc(w: ^Writer, doc: ^tape.Document, node := tape.ROOT) -> Write_Error {
	return write.tokens_of(doc, node, w, token, w.seq.allocator, tag_text)
}

// Writes `kind` with its `text`, as `json.token` takes them. A token the sequence cannot take here is
// `Refused{index, .Malformed}`, and a text with no CBOR spelling, invalid UTF-8 or a number that is no integer past
// 64 bits and no float (or an integer past 4096 digits), `Refused{index, .No_Spelling}`; neither writes a byte, and
// the writer takes the next token.
token :: proc(w: ^Writer, kind: Token_Kind, text := "") -> Write_Error {
	if w.out.err != nil {
		return w.out.err
	}
	index := tape.Node_Index(w.seq.taken)
	number: spell.Number
	is_bignum := false
	switch kind {
	case .Key, .String:
		if !utf8.valid_string(text) {
			return write.Refused{index, .No_Spelling}
		}
	case .Number:
		ok := false
		if write.is_json_number(transmute([]u8)text) {
			number, ok = spell.number_strict(transmute([]u8)text, 0, u64(len(text)))
		}
		if !ok {
			return write.Refused{index, .No_Spelling}
		}
		if number.kind == .Wide || number.kind == .Float && is_integer_text(text) {
			digits := text[1:] if len(text) > 0 && text[0] == '-' else text
			if !is_integer_text(text) || len(digits) == 0 || len(digits) > 4096 {
				return write.Refused{index, .No_Spelling}
			}
			is_bignum = true
		}
	case .Object, .Array, .True, .False, .Null, .Close:
	}
	if _, err := write.sequence_take(&w.seq, kind); err != nil {
		return err
	}
	out := &w.out
	if kind != .Close {
		// Bignum/decimal/bigfloat tags (2..5) are folded into number values in CBOR and never placed on a number token.
		tags := w.tags[:w.held]
		if kind == .Number {
			filtered: [MAX_PENDING_TAGS]Text_Tag
			k := 0
			for t in tags {
				if t.kind == .Number && t.number >= 2 && t.number <= 5 {
					continue
				}
				filtered[k] = t
				k += 1
			}
			put_text_tags(out, filtered[:k], "")
		} else {
			put_text_tags(out, tags, text if kind == .String || kind == .Key else "")
		}
	}
	w.held = 0
	switch kind {
	case .Object: write.put_byte(out, 0xBF)
	case .Array: write.put_byte(out, 0x9F)
	case .Close: write.put_byte(out, 0xFF)
	case .Key, .String:
		put_head(out, 3, u64(len(text)))
		write.put(out, transmute([]u8)text)
	case .True: write.put_byte(out, 0xF5)
	case .False: write.put_byte(out, 0xF4)
	case .Null: write.put_byte(out, 0xF6)
	case .Number:
		switch number.kind {
		case .Int:
			if i64(number.bits) < 0 {
				put_head(out, 1, ~number.bits)
			} else {
				put_head(out, 0, number.bits)
			}
		case .Uint:
			put_head(out, 0, number.bits)
		case .Float:
			if is_bignum {
				put_bignum(out, text)
			} else {
				put_float(out, transmute(f64)number.bits)
			}
		case .Wide:
			put_bignum(out, text)
		}
	}
	return w.out.err
}

// Ends the item, as `json.writer_end` ends a text.
writer_end :: proc(w: ^Writer) -> (item: []u8, err: Write_Error) {
	whole := write.sequence_done(&w.seq)
	taken := w.seq.taken
	write.sequence_drop(&w.seq)
	if !whole {
		write.out_drop(&w.out)
		return nil, write.Refused{tape.Node_Index(taken), .Malformed}
	}
	return write.out_finish(&w.out)
}

// Aborts `w` and frees its buffers without flushing or returning an item. `w` is not used again.
writer_drop :: proc(w: ^Writer) {
	write.sequence_drop(&w.seq)
	write.out_drop(&w.out)
	w^ = {}
}

// Typed writes: `value` written by the plan a typed read of its type is made by, as `json.marshal` writes a text. Its
// plan is the one `plan_make` of this package makes, or nil to make one for the call. Under `.Preferred`,
// `.Deterministic` and `.Length_First` (or `opts.sort_keys`), containers are emitted with definite lengths and keys
// sorted as the spec requires.
marshal :: proc(value: ^$T, spec := Spec.Cbor, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> (item: []u8, err: Write_Error) {
	return marshal_out(value, T, spec, opts, plan, {}, allocator)
}

// `marshal` into `sink`, through a buffer of `write.SINK_BYTES` from `allocator`. On a refusal or a failed sink the
// sink may hold a prefix of the item.
marshal_to :: proc(sink: io.Writer, value: ^$T, spec := Spec.Cbor, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> Write_Error {
	if sink.procedure == nil {
		return tape.Bad_Option{"sink"}
	}
	_, err := marshal_out(value, T, spec, opts, plan, sink, allocator)
	return err
}

// Token tape with pending named tags (for `time.Time`), used when marshalling to definite/sorted CBOR specs.
@(private)
Tagged_Tape :: struct {
	tokens:  write.Token_Tape,
	facts:   [dynamic]tape.Fact,
	pending: [MAX_PENDING_TAGS]string,
	held:    int,
}

@(private)
tagged_tape_tag :: proc(tt: ^Tagged_Tape, name: string) -> Write_Error {
	if tt.held == len(tt.pending) {
		return write.Refused{tape.Node_Index(tt.tokens.seq.taken), .Malformed}
	}
	tt.pending[tt.held] = name
	tt.held += 1
	return nil
}

@(private)
tagged_tape_token :: proc(tt: ^Tagged_Tape, kind: Token_Kind, text: string) -> Write_Error {
	if tt.held > 0 && kind != .Close {
		node := tape.Node_Index(len(tt.tokens.nodes))
		for name in tt.pending[:tt.held] {
			lo := u64(len(tt.tokens.texts))
			append(&tt.tokens.texts, name) or_return
			if _, err := append(&tt.facts, tape.Fact{node = node, kind = .Tag, lo = lo, n = u32(len(name))}); err != nil {
				return err
			}
		}
	}
	tt.held = 0
	return write.token_tape_take(&tt.tokens, kind, text)
}

@(private)
marshal_error :: proc(werr: Write_Error, err: tape.Error) -> Write_Error {
	if werr != nil {
		return werr
	}
	if err != nil {
		if memory, ok := err.(runtime.Allocator_Error); ok {
			return memory
		}
		bad, _ := err.(tape.Bad_Option)
		return bad
	}
	return nil
}

@(private)
marshal_out :: proc(value: rawptr, T: typeid, spec: Spec, opts: Write_Options, plan: ^Plan, sink: io.Writer, allocator: runtime.Allocator) -> (item: []u8, err: Write_Error) {
	if u8(spec) > u8(max(Spec)) {
		return nil, tape.Bad_Option{"spec"}
	}
	if opts.format != nil || opts.indent != 0 || opts.tab || opts.ascii || opts.node != 0 || opts.framing != .None || opts.grow_header || len(opts.header) > 0 {
		opt := "format" if opts.format != nil else "header" if len(opts.header) > 0 || opts.grow_header else "options"
		return nil, tape.Bad_Option{opt}
	}
	if spec == .Cbor && !opts.sort_keys {
		w: Writer
		if err = writer_start(&w, opts, sink, allocator); err != nil {
			return nil, err
		}
		werr, terr := typed.marshal(value, T, TAG, plan, &w, token, allocator, tag_text)
		if err = marshal_error(werr, terr); err != nil {
			writer_drop(&w)
			return nil, err
		}
		return writer_end(&w)
	}
	tt: Tagged_Tape
	tt.facts.allocator = allocator
	if e := write.token_tape_start(&tt.tokens, false, 0, allocator); e != nil {
		write.token_tape_drop(&tt.tokens)
		return nil, e
	}
	defer {
		write.token_tape_drop(&tt.tokens)
		delete(tt.facts)
	}
	werr, terr := typed.marshal(value, T, TAG, plan, &tt, tagged_tape_token, allocator, tagged_tape_tag)
	if err = marshal_error(werr, terr); err != nil {
		return nil, err
	}
	if !write.token_tape_done(&tt.tokens) {
		return nil, write.Refused{tape.Node_Index(tt.tokens.seq.taken), .Malformed}
	}
	doc, derr := write.token_tape_document(&tt.tokens)
	if derr != nil {
		return nil, derr
	}
	if len(tt.facts) > 0 {
		doc.facts = tt.facts[:]
		doc.present = {.Tag}
	}
	if sink.procedure != nil {
		_, err = write.to_sink(sink, &doc, u8(spec), opts, allocator, write_out)
		return nil, err
	}
	item, _, err = write.to_buffer(&doc, u8(spec), opts, allocator, write_out)
	return
}
