package json

import "base:runtime"
import "core:io"
import "core:strings"
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
	.Point_Zero   = "",
	.Inf          = "",
	.Neg_Inf      = "",
	.Nan          = "",
	.Heads        = "",
	.Bytes_Tag    = "",
}

// The token write of every JSON spec: a key and a string go through `put_string`.
@(private, rodata)
TOKENS := write.Token_Spelling {
	tree  = TREE,
	value = proc(t: ^write.Tokens, v: write.Scalar) -> core.Typed_Error_Kind {
		switch x in v {
		case string:
			return put_string(t.out, x, t.opts)
		case typed.Bytes:
			stack: [512]u8
			text, ok := write.bytes_text(cast([]u8)x, stack[:])
			return put_string(t.out, text, t.opts) if ok else .No_Memory
		case core.Number:
			return write.put_number(t.out, x)
		case write.Number_Literal:
			write.put_text(t.out, x.text)
		case write.Tagged_Text:
			return put_string(t.out, x.text, t.opts)
		case write.Tree_Part:
			write.put_text(t.out, t.spell.tree[x])
		}
		return .None
	},
	record = proc(t: ^write.Tokens, plan: ^typed.Plan, value: rawptr, err: ^core.Typed_Refusal) -> core.Typed_Error_Kind {
		return write.tokens_marshal(t, plan, value, err, TREE, put_plain, put_opted)
	},
	stop = write.tokens_release,
	comment = proc(out: ^write.Out, spec: u8, text: string) -> bool {
		if Spec(spec) == .Json {
			return false
		}
		if out != nil {
			write.put_text(out, "/* ")
			// A `*/` in the text would end the comment, so a space splits it.
			rest := text
			for {
				end := strings.index(rest, "*/")
				if end < 0 {
					write.put_text(out, rest)
					break
				}
				write.put_text(out, rest[:end + 1])
				write.put_text(out, " ")
				rest = rest[end + 1:]
			}
			write.put_text(out, " */")
		}
		return true
	},
}

@(private)
put_plain :: #force_inline proc(out: ^write.Out, p: [^]u8, s: string, _: ^core.Write_Options) -> core.Typed_Error_Kind {
	return put_short(out, p, s, false)
}

@(private)
put_opted :: proc(out: ^write.Out, _: [^]u8, s: string, opts: ^core.Write_Options) -> core.Typed_Error_Kind {
	return put_string(out, s, opts^)
}

// The instance of the typed write `plan_make` puts in a plan.
@(private)
marshal_text :: proc(plan: ^typed.Plan, value: rawptr, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator, omits: ^typed.Omits) -> ([]u8, core.Typed_Refusal) {
	return write.marshal_as(plan, value, opts, stream, allocator, TREE, put_plain, put_opted, omits)
}

// Writes `value` as JSON into new bytes from `allocator`, as `write` says. See `docs/writer.md`. The form with no plan
// builds and frees one for the call, and a plan built once with `plan_make`, with hooks or options, is the form for many
// writes. `write.marshal_stream` writes by a plan to a stream.
marshal :: proc {marshal_once, write.marshal}

@(private)
marshal_once :: proc(value: any, spec := Spec.Json, opts := Options{}, write := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Error) {
	nothing: any
	v := typed.marshal_target(value, &nothing)
	plan, refusal := plan_written(v.id, spec, opts, {}, nil, context.allocator)
	return typed.marshal_planned(&plan, refusal, v.data, write, allocator)
}

// A value spelled as JSON text for an edit: the colon is the document's own when it shows one.
edit_spell :: proc(doc: ^core.Document, v: core.Value, opts: core.Write_Options, colon: string, _: bool, _: u64, allocator: runtime.Allocator) -> ([]u8, core.Error) {
	text, err := write.write_laid(v, doc.as, opts, colon, &TOKENS, allocator)
	return text, core.error_of(err)
}
