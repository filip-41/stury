// The token write: a text made call by call, with no type and no document. A nested format (JSON) takes containers, keys
// and values. A flat format (delimited text) takes cells and the end of a record.
package write

import "core:io"
import core ".."
import "../typed"

// One value of a token write: a string, a number, or `.Null`, `.False` or `.True` of the tree.
Scalar :: union {
	string,
	core.Number,
	Tree_Part,
}

// A format's token spelling, which `core.Spelling.tokens` points at. `tree` is the nested format's punctuation. `value`
// writes one scalar, or one cell of a flat format, and a key is a string. A format with a `line` is flat.
Token_Spelling :: struct {
	tree:   Tree,
	start:  proc(t: ^Tokens, as: core.As) -> core.Typed_Error_Kind, // sets `state` and `out`
	value:  proc(t: ^Tokens, v: Scalar) -> core.Typed_Error_Kind,
	line:   proc(t: ^Tokens) -> core.Typed_Error_Kind, // ends a record
	stop:   proc(t: ^Tokens), // frees `state`
	// Writes a value by a plan the format built as one record, with no frame: a value, or a row with its line end and,
	// for the first, the header. A refusal's kind and path go to `err`, and the kind is returned.
	record: proc(t: ^Tokens, plan: ^typed.Plan, value: rawptr, err: ^core.Typed_Error) -> core.Typed_Error_Kind,
}

// A token write's state. It holds `core.MAX_DEPTH` levels with no allocation and is not copied after `tokens_init`. A
// misuse or a failed output is kept in `err`, and every later call returns it and writes nothing.
Tokens :: struct {
	out:    ^Out, // `base`, or the output of a flat format's `state`
	opts:   core.Write_Options,
	spell:  ^Token_Spelling,
	state:  rawptr, // a format's own, set by `start`
	base:   Out,
	spill:  [ROOM_MAX]u8,
	object: [core.MAX_DEPTH]bool, // per open level, whether it is an object
	top:    int, // the open levels
	mark:   int, // the output offset where the open record began
	first:  bool, // nothing is written yet in the open container or record
	keyed:  bool, // a key is written and its value is owed
	done:   bool, // the root value is whole
	err:    core.Typed_Error_Kind,
}

// Starts a write in the format `as` names, as `opts` says, into a buffer from `allocator` or to `stream`. A format with no
// token writer is `.Unsupported`, and an `as` the format cannot write is its own refusal. The kind is also kept in `t`.
tokens_init :: proc(t: ^Tokens, as: core.As, opts := core.Write_Options{}, allocator := context.allocator, stream := io.Stream{}) -> core.Typed_Error_Kind {
	// The spill and the levels are not zeroed: a level is read only below `top`.
	t.opts, t.spell, t.state, t.top, t.mark, t.first, t.keyed, t.done, t.err = opts, nil, nil, 0, 0, true, false, false, .None
	init(&t.base, &t.spill, allocator, stream)
	t.out = &t.base
	if as.spelling == nil || as.spelling.tokens == nil {
		return refuse(t, .Unsupported)
	}
	t.spell = (^Token_Spelling)(as.spelling.tokens)
	if t.spell.start != nil {
		return refuse(t, t.spell.start(t, as))
	}
	return .None
}

// Ends the text and returns it as `finish` does. A JSON text must be one value with every container closed, and a flat
// text must have no cells waiting for their record's end, else the end is `.Out_Of_Order`.
tokens_finish :: proc(t: ^Tokens) -> (bytes: []u8, err: core.Typed_Error) {
	if t.spell != nil && !(t.first if t.spell.line != nil else t.done) {
		refuse(t, .Out_Of_Order)
	}
	if t.err != .None && t.out.err == .None {
		destroy(t.out)
		err.kind = t.err
	} else {
		bytes, err = finish(t.out)
	}
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
	if t.top == 0 || t.keyed {
		return refuse(t, .Out_Of_Order)
	}
	t.top -= 1
	if !t.first {
		put_line(t.out, t.opts, t.top)
	}
	put_text(t.out, t.spell.tree[.Close_Object if t.object[t.top] else .Close_Array])
	t.first, t.done = false, t.top == 0
	return refuse(t, t.out.err)
}

// Writes a member's name and its colon. Only an object that owes a key takes it.
key :: proc(t: ^Tokens, name: string) -> core.Typed_Error_Kind {
	if !lead(t, .Key) || refuse(t, t.spell.value(t, name)) != .None {
		return t.err
	}
	put_text(t.out, t.spell.tree[.Colon])
	if t.opts.pretty {
		put_text(t.out, t.spell.tree[.After_Colon])
	}
	t.keyed = true
	return refuse(t, t.out.err)
}

// The value calls write a JSON value, or a cell of a flat format. A string that is not UTF-8 is `.Bad_Utf8`, and a float
// that is infinite or not a number is `.Non_Finite`. Null is an empty cell.
value_string :: proc(t: ^Tokens, s: string) -> core.Typed_Error_Kind {return value(t, s)}

value_int :: proc(t: ^Tokens, x: i64) -> core.Typed_Error_Kind {return value(t, core.Number{u64(x), .Int})}

value_uint :: proc(t: ^Tokens, x: u64) -> core.Typed_Error_Kind {return value(t, core.Number{x, .Uint})}

value_float :: proc(t: ^Tokens, x: f64) -> core.Typed_Error_Kind {return value(t, core.Number{transmute(u64)x, .Float})}

value_bool :: proc(t: ^Tokens, b: bool) -> core.Typed_Error_Kind {return value(t, Tree_Part.True if b else .False)}

value_null :: proc(t: ^Tokens) -> core.Typed_Error_Kind {return value(t, Tree_Part.Null)}

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
	put_text(t.out, t.spell.tree[.Open_Object if object else .Open_Array])
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
		if t.top > 0 {
			if !t.first {
				put_text(t.out, t.spell.tree[.Comma])
			}
			put_line(t.out, t.opts, t.top)
		}
		t.first = false
	}
	return t.err == .None
}

// Keeps the first refusal and returns it.
@(private)
refuse :: proc(t: ^Tokens, kind: core.Typed_Error_Kind) -> core.Typed_Error_Kind {
	if t.err == .None {
		t.err = kind
	}
	return t.err
}
