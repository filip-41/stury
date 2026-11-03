package json

import "base:runtime"
import "core:io"
import core "../core"
import typed "../core/typed"
import write "../core/write"

// JSON's bytes of a tree text.
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
}

// The token write of every JSON spec: a key and a string go through `put_string`.
@(private)
TOKENS := write.Token_Spelling {
	tree  = TREE,
	value = proc(t: ^write.Tokens, v: write.Scalar) -> core.Typed_Error_Kind {
		switch x in v {
		case string:
			return put_string(t.out, x, t.opts)
		case core.Number:
			return write.put_number(t.out, x)
		case write.Tree_Part:
			write.put_text(t.out, t.spell.tree[x])
		}
		return .None
	},
	record = proc(t: ^write.Tokens, plan: ^typed.Plan, value: rawptr, err: ^core.Typed_Error) -> core.Typed_Error_Kind {
		return write.tokens_marshal(t, plan, value, err, TREE, put_plain, put_opted)
	},
	stop = write.tokens_release,
}

@(private)
put_plain :: #force_inline proc(out: ^write.Out, p: [^]u8, s: string, _: ^core.Write_Options) -> core.Typed_Error_Kind {
	return put_short(out, p, s)
}

@(private)
put_opted :: proc(out: ^write.Out, _: [^]u8, s: string, opts: ^core.Write_Options) -> core.Typed_Error_Kind {
	return put_string(out, s, opts^)
}

// The instance of the typed write `plan_make` puts in a plan.
@(private)
marshal_text :: proc(plan: ^typed.Plan, value: rawptr, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator) -> ([]u8, core.Typed_Error) {
	return write.marshal_as(plan, value, opts, stream, allocator, TREE, put_plain, put_opted)
}

// Writes `value` as JSON into new bytes from `allocator`, by a plan built for the call. See `docs/writer.md`. A plan built
// once with `plan_make`, with hooks or options, is written by `write.marshal`, and `write.marshal_stream` writes it to a stream.
marshal :: proc(value: any, opts := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Typed_Error) {
	return write.marshal_once(value, plan_make, opts, allocator)
}
