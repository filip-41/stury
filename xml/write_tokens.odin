package xml

// The token write and `marshal` of XML, both by the element write of `write_elements.odin`. The typed write makes a
// value in a tree of JSON's punctuation, which `marshal` reads as it gives it to the element write. A pretty token write
// to a stream is `.Unsupported`, since the text is laid out only once it is whole.

import "base:runtime"
import "core:io"
import "core:strings"
import spell "../core/spell"
import core "../core"
import typed "../core/typed"
import write "../core/write"

// Starts a token write, as `write.tokens_init` does with `as(spec)`. The calls give a value as `write` takes a node.
tokens_init :: proc {tokens_init_bound, tokens_init_chosen}

@(private)
tokens_init_bound :: proc(t: ^write.Tokens, $S: Spec, opts := core.Write_Options{}, allocator := context.allocator, stream := io.Stream{}) -> core.Typed_Error_Kind {
	return write.tokens_init(t, bound_as(S), opts, allocator, stream, &TOKENS)
}

@(private)
tokens_init_chosen :: #force_inline proc(t: ^write.Tokens, spec: Spec, opts := core.Write_Options{}, allocator := context.allocator, stream := io.Stream{}) -> core.Typed_Error_Kind {
	return write.tokens_init(t, as(spec), opts, allocator, stream)
}

// The parts of the tree the typed write spells: JSON's punctuation and words, and a string as `put_marked` marks it.
@(private)
TREE :: write.Tree {
	.Open_Object  = "{",
	.Close_Object = "}",
	.Open_Array   = "[",
	.Close_Array  = "]",
	.Comma        = ",",
	.Colon        = ":",
	.After_Colon  = " ",
	.Null         = "null",
	.True         = "true",
	.False        = "false",
	.Point_Zero   = ".0",
	.Inf          = "",
	.Neg_Inf      = "",
	.Nan          = "",
	.Heads        = "",
	.Bytes_Tag    = "",
}

@(private, rodata)
TOKENS := write.Token_Spelling {
	tree = TREE,
	start = proc(t: ^write.Tokens, _: core.As) -> core.Typed_Error_Kind {
		if t.opts.pretty && t.out.stream.procedure != nil {
			return .Unsupported
		}
		e, failed := new(Elements, t.base.allocator)
		if failed != nil {
			return .No_Memory
		}
		context.allocator = t.base.allocator
		elements_init(e, t.out, t.opts)
		t.state = e
		return .None
	},
	value = proc(t: ^write.Tokens, v: write.Scalar) -> core.Typed_Error_Kind {
		e := (^Elements)(t.state)
		if e.key_next {
			e.key_next = false
			return el_key(e, v.(string))
		}
		switch x in v {
		case string:
			return el_value(e, x)
		case write.Tagged_Text:
			return el_value(e, x.text)
		case typed.Bytes:
			stack: [512]u8
			text, ok := write.bytes_text(cast([]u8)x, stack[:])
			return el_value(e, text) if ok else .No_Memory
		case core.Number:
			digits: [64]u8
			n := write.number_text_as(raw_data(digits[:]), x, TREE) or_return
			return el_value(e, string(digits[:n]))
		case write.Number_Literal:
			if _, is_number := spell.number_strict(transmute([]u8)x.text, 0, u64(len(x.text))); !is_number {
				return .Bad_Raw
			}
			return el_value(e, x.text)
		case write.Tree_Part:
			tree := TREE
			return el_value(e, tree[x], x == .Null)
		}
		return .None
	},
	layout = proc(t: ^write.Tokens, step: write.Layout_Step) -> core.Typed_Error_Kind {
		e := (^Elements)(t.state)
		switch step {
		case .Open_Object, .Open_Array:
			return el_open(e, step == .Open_Object)
		case .Close:
			return el_close(e)
		case .Key:
			e.key_next = true
		}
		return .None
	},
	stop = proc(t: ^write.Tokens) {
		if e := (^Elements)(t.state); e != nil {
			delete(e.names)
			free(e, t.base.allocator)
			t.state = nil
		}
	},
	end = proc(t: ^write.Tokens, bytes: []u8) -> ([]u8, core.Typed_Refusal) {
		if !t.opts.pretty {
			return bytes, {}
		}
		defer delete(bytes, t.base.allocator)
		return lay_out(bytes, t.opts, {}, t.base.allocator)
	},
}

// The typed write's string: a quote, the bytes and a NUL, which no string XML can spell holds.
@(private)
put_marked :: proc(out: ^write.Out, _: [^]u8, s: string, _: ^core.Write_Options) -> core.Typed_Error_Kind {
	if strings.index_byte(s, 0) >= 0 {
		return .Unwritable
	}
	write.put_byte(out, '"')
	write.put_text(out, s)
	write.put_byte(out, 0)
	return .None
}

// The plan's `marshal`: the typed write makes the value in `TREE`, which is read as it is given to an element write.
@(private)
marshal_text :: proc(plan: ^typed.Plan, value: rawptr, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator, omits: ^typed.Omits) -> ([]u8, core.Typed_Refusal) {
	flat := opts
	flat.pretty, flat.sort_keys = false, false
	tree, err := write.marshal_as(plan, value, flat, {}, context.allocator, TREE, put_marked, put_marked, omits)
	if err.kind != .None {
		return nil, err
	}
	defer delete(tree)
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	if opts.pretty {
		write.init(&out, &spill)
	} else {
		write.init(&out, &spill, allocator, stream)
	}
	e: Elements
	elements_init(&e, &out, opts)
	return elements_finish(&e, from_tree(&e, string(tree)), opts, stream, allocator)
}

// Gives the text the typed write made in `TREE` to the element write `e`.
@(private)
from_tree :: proc(e: ^Elements, s: string) -> core.Typed_Error_Kind {
	for i := 0; i < len(s); {
		switch s[i] {
		case '{', '[':
			el_open(e, s[i] == '{') or_return
		case '}', ']':
			el_close(e) or_return
		case ',':
		case '"':
			end := i + 1 + strings.index_byte(s[i + 1:], 0)
			text := s[i + 1:end]
			i = end
			if i + 1 < len(s) && s[i + 1] == ':' {
				i += 1
				el_key(e, text) or_return
			} else {
				el_value(e, text) or_return
			}
		case:
			end := i
			for end < len(s) && s[end] != ',' && s[end] != '}' && s[end] != ']' {
				end += 1
			}
			el_value(e, s[i:end], s[i:end] == "null") or_return
			i = end
			continue
		}
		i += 1
	}
	return .None
}
