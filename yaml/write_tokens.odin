package yaml

// The token write of YAML. Compact text is flow style on one line, and pretty text is block style, laid out by
// `write_block.odin` as the calls arrive. A write that stands at a site of a document is block text at column 0, which
// the edit indents to the site or turns to flow inside a flow collection. A byte string is `!!binary` and its base64.

import "base:runtime"
import "core:io"
import spell "../core/spell"
import core "../core"
import typed "../core/typed"
import write "../core/write"

@(private)
TREE :: write.Tree {
	.Open_Object  = "{",
	.Close_Object = "}",
	.Open_Array   = "[",
	.Close_Array  = "]",
	.Comma        = ", ",
	.Colon        = ": ",
	.After_Colon  = " ",
	.Null         = "null",
	.True         = "true",
	.False        = "false",
	.Point_Zero   = ".0",
	.Inf          = ".inf",
	.Neg_Inf      = "-.inf",
	.Nan          = ".nan",
	.Bytes_Tag    = "!!binary ",
}

@(private, rodata)
TOKENS := write.Token_Spelling {
	tree = TREE,
	start = proc(t: ^write.Tokens, _: core.As) -> core.Typed_Error_Kind {
		if t.site.placed && !t.site.flow || t.opts.pretty && !t.site.placed {
			t.state = block_new(t.out, t.opts)
			return .None if t.state != nil else .No_Memory
		}
		t.opts.pretty = false
		return .None
	},
	value = proc(t: ^write.Tokens, v: write.Scalar) -> core.Typed_Error_Kind {
		b := (^Block_Writer)(t.state)
		if b != nil {
			return block_value(t, b, v)
		}
		switch x in v {
		case string:
			return put_flow_string(t.out, x, t.opts)
		case typed.Bytes:
			return put_bytes(t.out, x)
		case core.Number:
			return write.put_number_as(t.out, x, TREE)
		case write.Number_Literal:
			return put_number_literal(t.out, x)
		case write.Tagged_Text:
			return put_flow_string(t.out, x.text, t.opts)
		case write.Tree_Part:
			write.put_text(t.out, t.spell.tree[x])
		}
		return .None
	},
	layout = layout_step,
	stop = proc(t: ^write.Tokens) {
		if t.state != nil {
			block_free((^Block_Writer)(t.state))
			t.state = nil
		}
	},
}

// Writes scalar `v` as the next item of the block text.
@(private)
block_value :: proc(t: ^write.Tokens, b: ^Block_Writer, v: write.Scalar) -> core.Typed_Error_Kind {
	switch x in v {
	case string:
		if b.key_next {
			b.key_next = false
			return block_key(b, x)
		}
		return block_string(b, x)
	case write.Tagged_Text:
		return block_string(b, x.text)
	case typed.Bytes:
		block_lead(b, false)
		kind := put_bytes(t.out, x)
		block_end_root(b)
		return kind
	case core.Number:
		block_lead(b, false)
		kind := write.put_number_as(t.out, x, TREE)
		block_end_root(b)
		return kind
	case write.Number_Literal:
		block_lead(b, false)
		kind := put_number_literal(t.out, x)
		block_end_root(b)
		return kind
	case write.Tree_Part:
		block_raw(b, t.spell.tree[x])
	}
	return .None
}

@(private)
put_bytes :: proc(out: ^write.Out, b: typed.Bytes) -> core.Typed_Error_Kind {
	stack: [512]u8
	text, ok := write.bytes_text(cast([]u8)b, stack[:])
	if !ok {
		return .No_Memory
	}
	write.put_text(out, "!!binary ")
	put_scalar(out, text, .Plain if len(text) > 0 else .Double, false)
	return .None
}

@(private)
put_number_literal :: proc(out: ^write.Out, n: write.Number_Literal) -> core.Typed_Error_Kind {
	if _, is_number := spell.number_strict(transmute([]u8)n.text, 0, u64(len(n.text))); !is_number {
		return .Bad_Raw
	}
	write.put_text(out, n.text)
	return .None
}

// Writes `s` as a scalar of a flow collection, in the style the computed strings take.
@(private)
put_flow_string :: proc(out: ^write.Out, s: string, opts: core.Write_Options) -> core.Typed_Error_Kind {
	shape, kind := shape_of(s, {flow = true, ascii = opts.ascii})
	if kind != .None {
		return kind
	}
	put_scalar(out, s, shape, opts.ascii)
	return .None
}

@(private)
put_plain :: proc(out: ^write.Out, _: [^]u8, s: string, opts: ^core.Write_Options) -> core.Typed_Error_Kind {
	return put_flow_string(out, s, opts^)
}

// The plan's `marshal`: the typed write makes the value as flow text with a line a member, since it puts a space after a
// colon in pretty text alone, and `block_from_flow` moves that text into the layout `opts` says as it goes to the output.
@(private)
marshal_text :: proc(plan: ^typed.Plan, value: rawptr, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator, omits: ^typed.Omits) -> ([]u8, core.Typed_Refusal) {
	lines := opts
	lines.pretty, lines.indent, lines.tab = true, 0, false
	bytes, err := write.marshal_as(plan, value, lines, {}, allocator, TREE, put_plain, put_plain, omits)
	if err.kind != .None {
		return nil, err
	}
	defer delete(bytes, allocator)
	spill: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spill, allocator, stream)
	kind: core.Typed_Error_Kind
	if opts.pretty {
		b := block_new(&out, opts)
		if b == nil {
			write.destroy(&out)
			return nil, {kind = .No_Memory}
		}
		defer block_free(b)
		kind = block_from_flow(b, string(bytes))
	} else {
		flow_from_lines(&out, string(bytes))
	}
	return write.finish(&out, {kind = kind})
}
