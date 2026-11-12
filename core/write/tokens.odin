// The token write: a text made call by call, with no type and no document. A nested format (JSON) takes containers, keys
// and values. A flat format (delimited text) takes cells and the end of a record.
package write

import "core:io"
import "../spell"
import core ".."
import "../typed"

// One value of a token write: a string, a byte string, a number by its value or by its text, or `.Null`, `.False` or
// `.True` of the tree. A nil value is `.Null`. A text format writes a byte string as the string of its RFC 4648 base64.
Scalar :: union {
	string,
	typed.Bytes,
	core.Number,
	Number_Literal,
	Tree_Part,
}

// A number by its text, which must be a JSON number, written as it is.
Number_Literal :: struct {
	text: string,
}

// A format's token spelling, which `core.Services.tokens` points at. `tree` is the nested format's punctuation. `value`
// writes one scalar, or one cell of a flat format, and a key is a string. A format with a `line` is flat.
Token_Spelling :: struct {
	tree:   Tree,
	start:  proc(t: ^Tokens, as: core.As) -> core.Typed_Error_Kind, // sets `state` and `out`
	value:  proc(t: ^Tokens, v: Scalar) -> core.Typed_Error_Kind,
	line:   proc(t: ^Tokens) -> core.Typed_Error_Kind, // ends a record
	stop:   proc(t: ^Tokens), // frees `state`
	// Writes a value by a plan the format built as one record, with no frame: a value, or a row with its line end and,
	// for the first, the header. A refusal's kind and path go to `err`, and the kind is returned.
	record: proc(t: ^Tokens, plan: ^typed.Plan, value: rawptr, err: ^core.Typed_Refusal) -> core.Typed_Error_Kind,
	// Lays the text out itself while `state` is set: the container, key and comma punctuation of `tree` is not written,
	// `layout` is called at each step instead, and `value` writes the scalars and the keys, whose separators it writes
	// too. A `state` that stays nil writes `tree` as it is.
	layout: proc(t: ^Tokens, step: Layout_Step) -> core.Typed_Error_Kind,
	// Writes `text` as a comment to `out`. It writes nothing and answers false where the spec `spec` of the format has no
	// comments, and with a nil `out` only says whether it has.
	comment: proc(out: ^Out, spec: u8, text: string) -> bool,
}

// The steps of a laid-out write. `Close` comes after the level is popped, and `Key` before `value` writes the name.
Layout_Step :: enum u8 {
	Open_Object,
	Open_Array,
	Close,
	Key,
}

// A token write's state. It holds `core.MAX_DEPTH` levels with no allocation and is not copied after `tokens_init`. A
// misuse or a failed output is kept in `err`, and every later call returns it and writes nothing.
Tokens :: struct {
	out:    ^Out, // `base`, or the output of a flat format's `state`
	opts:   core.Write_Options,
	spell:  ^Token_Spelling,
	state:  rawptr, // a format's own, set by `start`
	site:   core.Site, // where the text will stand in a document, for a format that indents or styles by place
	base:   Out,
	spill:  [ROOM_MAX]u8,
	object: [core.MAX_DEPTH]bool, // per open level, whether it is an object
	spec:   u8, // the format's spec, as `comment` takes it
	top:    int, // the open levels
	mark:   int, // the output offset where the open record began
	first:  bool, // nothing is written yet in the open container or record
	led:    bool, // a comment has written the comma that the next item owes
	keyed:  bool, // a key is written and its value is owed
	done:   bool, // the root value is whole
	err:    core.Typed_Error_Kind,
}

// Starts a write in the format `as` names, as `opts` says, into a buffer from `allocator` or to `stream`. A format with no
// token writer is `.Unsupported`, and an `as` the format cannot write is its own refusal. The kind is also kept in `t`.
// A format that binds its spelling at compile time gives it as `spell`, and then `as` need hold no services. `site` says
// where the text will stand, which a format's `start` and `value` read from `t.site`: a text that stands at a column,
// in a flow collection or after a key is laid out for that place. The zero site is a whole text.
tokens_init :: proc(t: ^Tokens, as: core.As, opts := core.Write_Options{}, allocator := context.allocator, stream := io.Stream{}, spell: ^Token_Spelling = nil, site := core.Site{}) -> core.Typed_Error_Kind {
	// The spill and the levels are not zeroed: a level is read only below `top`.
	t.opts, t.spell, t.state, t.top, t.mark, t.first, t.keyed, t.done, t.err = opts, nil, nil, 0, 0, true, false, false, .None
	t.spec, t.led, t.site = as.spec, false, site
	init(&t.base, &t.spill, allocator, stream)
	t.out = &t.base
	t.spell = spell
	if t.spell == nil {
		services := core.services_of(as)
		if services == nil || services.tokens == nil {
			return refuse(t, .Unsupported)
		}
		t.spell = (^Token_Spelling)(services.tokens)
	}
	if t.spell.start != nil {
		return refuse(t, t.spell.start(t, as))
	}
	return .None
}

// Ends the text and returns it as `finish` does. A JSON text must be one value with every container closed, and a flat
// text must have no cells waiting for their record's end, else the end is `.Out_Of_Order`.
tokens_finish :: proc(t: ^Tokens) -> (bytes: []u8, err: core.Typed_Refusal) {
	if t.spell != nil && !(t.first if t.spell.line != nil else t.done) {
		refuse(t, .Out_Of_Order)
	}
	bytes, err = finish(t.out, {kind = t.err if t.out.err == .None else .None})
	if t.spell != nil && t.spell.stop != nil {
		t.spell.stop(t)
	}
	return
}

open_object :: proc(t: ^Tokens) -> core.Typed_Error_Kind {return open(t, true)}

open_array :: proc(t: ^Tokens) -> core.Typed_Error_Kind {return open(t, false)}

// Closes the innermost container. A close with none open, or between a key and its value, is `.Out_Of_Order`.
close :: proc(t: ^Tokens) -> core.Typed_Error_Kind {
	if t.err != .None || t.spell.line != nil {
		return refuse(t, .Unsupported)
	}
	if t.top == 0 || t.keyed || t.led {
		return refuse(t, .Out_Of_Order)
	}
	t.top -= 1
	if laid(t) {
		refuse(t, t.spell.layout(t, .Close))
	} else {
		if !t.first {
			put_line(t.out, t.opts, t.top)
		}
		put_text(t.out, t.spell.tree[.Close_Object if t.object[t.top] else .Close_Array])
	}
	t.first, t.done = false, t.top == 0
	return refuse(t, t.out.err)
}

// Writes a member's name and its colon. Only an object that owes a key takes it.
key :: proc(t: ^Tokens, name: string) -> core.Typed_Error_Kind {
	if !lead(t, .Key) {
		return t.err
	}
	if laid(t) {
		refuse(t, t.spell.layout(t, .Key))
	}
	if refuse(t, t.spell.value(t, name)) != .None {
		return t.err
	}
	if !laid(t) {
		put_text(t.out, t.spell.tree[.Colon])
		if t.opts.pretty {
			put_text(t.out, t.spell.tree[.After_Colon])
		}
	}
	t.keyed = true
	return refuse(t, t.out.err)
}

// Writes `text` as a comment before the next key, value or container where the format has comments, and drops it where it
// has none. A comment between a key and its value or before a close is `.Out_Of_Order`.
comment :: proc(t: ^Tokens, text: string) -> core.Typed_Error_Kind {
	if t.err != .None || t.spell.line != nil || t.spell.comment == nil || !t.spell.comment(nil, t.spec, text) {
		return t.err
	}
	if t.keyed || t.top == 0 && t.done {
		return refuse(t, .Out_Of_Order)
	}
	if t.top > 0 {
		if !t.first && !t.led {
			put_text(t.out, t.spell.tree[.Comma])
		}
		put_line(t.out, t.opts, t.top)
	}
	t.spell.comment(t.out, t.spec, text)
	t.led = !t.first
	return refuse(t, t.out.err)
}

// The value calls write a JSON value, or a cell of a flat format. A string that is not UTF-8 is `.Invalid_Utf8`, and a float
// that is infinite or not a number is `.Non_Finite`. Null is an empty cell.
value_string :: proc(t: ^Tokens, s: string) -> core.Typed_Error_Kind {return value(t, s)}

value_int :: proc(t: ^Tokens, x: i64) -> core.Typed_Error_Kind {return value(t, core.Number{u64(x), .Int})}

value_uint :: proc(t: ^Tokens, x: u64) -> core.Typed_Error_Kind {return value(t, core.Number{x, .Uint})}

value_float :: proc(t: ^Tokens, x: f64) -> core.Typed_Error_Kind {return value(t, core.Number{transmute(u64)x, .Float})}

value_bool :: proc(t: ^Tokens, b: bool) -> core.Typed_Error_Kind {return value(t, Tree_Part.True if b else .False)}

value_null :: proc(t: ^Tokens) -> core.Typed_Error_Kind {return value(t, Tree_Part.Null)}

// A byte string, written as the format spells one: a text format writes the string of its base64, see `bytes_text`.
value_bytes :: proc(t: ^Tokens, b: []u8) -> core.Typed_Error_Kind {return value(t, typed.Bytes(b))}

// Ends the record of a flat format with the layout's line end. A JSON write is `.Unsupported`, and a record that wrote
// no byte is `.Unwritable` as `marshal` refuses it.
end_record :: proc(t: ^Tokens) -> core.Typed_Error_Kind {
	if t.err != .None || t.spell.line == nil {
		return refuse(t, .Unsupported)
	}
	if kind := t.spell.line(t); kind != .None {
		return refuse(t, kind)
	}
	t.first, t.mark = true, t.out.flushed + t.out.cursor
	return refuse(t, t.out.err)
}

@(private)
Item :: enum {
	Scalar,
	Key,
	Container,
}

@(private)
open :: proc(t: ^Tokens, object: bool) -> core.Typed_Error_Kind {
	if !lead(t, .Container) {
		return t.err
	}
	if laid(t) {
		refuse(t, t.spell.layout(t, .Open_Object if object else .Open_Array))
	} else {
		put_text(t.out, t.spell.tree[.Open_Object if object else .Open_Array])
	}
	t.object[t.top] = object
	t.top += 1
	t.first = true
	return refuse(t, t.out.err)
}

@(private)
value :: proc(t: ^Tokens, v: Scalar) -> core.Typed_Error_Kind {
	if !lead(t, .Scalar) {
		return t.err
	}
	refuse(t, t.spell.value(t, v))
	t.first, t.done = false, t.top == 0
	return refuse(t, t.out.err)
}

// Checks that an item may come next and writes what goes before it: the comma, and in pretty text the line. Returns false
// with the refusal in `t.err`. A flat format takes only cells, and its `value` writes their separators.
@(private)
lead :: proc(t: ^Tokens, item: Item) -> bool {
	if t.err != .None {
		return false
	}
	if t.spell.line != nil {
		return item == .Scalar || refuse(t, .Unsupported) == .None
	}
	object := t.top > 0 && t.object[t.top - 1]
	switch {
	case item == .Key && (!object || t.keyed), item != .Key && object != t.keyed, t.top == 0 && t.done:
		refuse(t, .Out_Of_Order)
	case item == .Container && t.top == core.MAX_DEPTH:
		refuse(t, .Too_Deep)
	case t.keyed:
		t.keyed = false
	case:
		if t.top > 0 && !laid(t) {
			if !t.first && !t.led {
				put_text(t.out, t.spell.tree[.Comma])
			}
			put_line(t.out, t.opts, t.top)
		}
		t.first, t.led = false, false
	}
	return t.err == .None
}

// Whether the format lays the text out itself.
@(private)
laid :: #force_inline proc "contextless" (t: ^Tokens) -> bool {
	return t.state != nil && t.spell.layout != nil
}

// Keeps the first refusal and returns it.
@(private)
refuse :: proc(t: ^Tokens, kind: core.Typed_Error_Kind) -> core.Typed_Error_Kind {
	if t.err == .None {
		t.err = kind
	}
	return t.err
}

// Returns the RFC 4648 base64 text of `b`, in `stack` when it fits and else in `context.temp_allocator`, with false when
// that is refused.
bytes_text :: proc(b: []u8, stack: []u8) -> (text: string, ok: bool) {
	n := spell.base64_len(len(b))
	buf := stack
	if n > len(stack) {
		made, err := make([]u8, n, context.temp_allocator)
		if err != nil {
			return "", false
		}
		buf = made
	}
	return string(buf[:spell.base64_put(buf, b)]), true
}

// Returns the decimal digits of number `node` as its format spells them, in `stack` when they fit and else in
// `context.temp_allocator`, with false when the node is no number or an allocation is refused.
node_number_text :: proc(doc: ^core.Document, node: core.Node_Index, stack: []u8) -> (text: string, ok: bool) {
	if s, fit := core.doc_number_text(doc, node, stack); fit {
		return s, true
	}
	if core.kind(doc, node) != .Number {
		return "", false
	}
	for room := 4 * len(stack); room <= NUMBER_TEXT_MAX; room *= 2 {
		buf, err := make([]u8, room, context.temp_allocator)
		if err != nil {
			return "", false
		}
		if s, fit := core.doc_number_text(doc, node, buf); fit {
			return s, true
		}
	}
	return "", false
}

@(private)
NUMBER_TEXT_MAX :: 1 << 26
