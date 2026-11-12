package xml

// The token write and `marshal` of XML, both by the element write of `write_elements.odin`. `marshal` writes the value
// `write.marshal_markup` reads back. A pretty token write to a stream is `.Unsupported`, since the text is laid out only
// once it is whole.

import "base:runtime"
import "core:io"
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

@(private, rodata)
TOKENS := write.Token_Spelling {
	tree = write.MARKUP_TREE,
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
		stack: [512]u8
		text, null := write.token_scalar_text(v, stack[:]) or_return
		return el_value(e, text, null)
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

// The plan's `marshal`, by the element write.
@(private)
marshal_text :: proc(plan: ^typed.Plan, value: rawptr, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator, omits: ^typed.Omits) -> ([]u8, core.Typed_Refusal) {
	return write.marshal_markup(plan, value, opts, stream, allocator, omits, value_write)
}

