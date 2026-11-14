package yaml

// The token write of YAML. Compact text is flow style on one line, and pretty text is block style, laid out by
// `write_block.odin` as the calls arrive. A write that stands at a site of a document is block text at column 0, which
// the edit indents to the site or turns to flow inside a flow collection. A byte string is `!!binary` and its base64.

import "base:runtime"
import "core:io"
import "core:strings"
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
	.Heads        = "",
	.Bytes_Tag    = "!!binary ",
}

// The number spellings of the core schema past JSON's.
@(private)
NUMBER_FORMS :: write.Number_Forms{.Hex, .Octal, .Plus, .Lead_Point, .Bare_Point}

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
			write.put_text(t.out, x.text)
		case write.Tagged_Text:
			if tag := meaning_tag(x.text, x.meaning); tag != "" {
				write.put_text(t.out, tag)
				write.put_byte(t.out, ' ')
				return put_scalar_shaped(t.out, x.text, {flow = true, tagged = true, ascii = t.opts.ascii})
			}
			return put_flow_string(t.out, x.text, t.opts)
		case write.Tree_Part:
			write.put_text(t.out, t.spell.tree[x])
		}
		return .None
	},
	layout = layout_step,
	// A flow text breaks its line where a comment goes. An inline comment on a block collection after a key goes on the
	// key's line. An inline comment that follows one on the same item joins it, and `t.mark` is where the last inline
	// comment that is one line ended.
	comment = proc(t: ^write.Tokens, role: core.Role, text: string) -> core.Typed_Error_Kind {
		if !write.comment_lines_ok(text) {
			return .Unwritable
		}
		one_line := role == .Comment_Inline && strings.index_byte(text, '\n') < 0
		b := (^Block_Writer)(t.state)
		if b != nil && one_line && block_inline_back(b, text) {
			// The comment stands before the collection's items, so nothing joins it at the end.
		} else if tail := t.out.flushed + t.out.cursor - t.mark; one_line && t.mark > t.out.flushed && tail <= 1 {
			t.out.cursor -= tail
			write.put_text(t.out, " " if len(text) > 0 else "")
			write.put_text(t.out, text)
			write.put_text(t.out, "\n" if tail > 0 else "")
		} else if b != nil {
			block_comment(b, role, text)
		} else {
			flow_comment(t, role, text)
		}
		t.mark = 0
		if one_line {
			ended := t.out.cursor > 0 && t.out.buf[t.out.cursor - 1] == '\n'
			t.mark = t.out.flushed + t.out.cursor - (1 if ended else 0)
		}
		return .None
	},
	stop = proc(t: ^write.Tokens) {
		if t.state != nil {
			block_free((^Block_Writer)(t.state))
			t.state = nil
		}
	},
}

// Writes `text` as a `#` comment of `role` in a flow text, which breaks its line there.
@(private)
flow_comment :: proc(t: ^write.Tokens, role: core.Role, text: string) {
	out := t.out
	if out.cursor > 0 && out.buf[out.cursor - 1] == ' ' {
		out.cursor -= 1
	}
	if role == .Comment_Inline {
		write.put_byte(out, ' ')
	} else if t.top > 0 || t.done {
		write.put_byte(out, '\n')
	}
	write.put_comment(out, "#", text, true, 0)
	if !t.done {
		write.put_byte(out, '\n')
	}
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
		return block_string(b, x.text, meaning_tag(x.text, x.meaning))
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
		write.put_text(t.out, x.text)
		block_end_root(b)
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

// Writes `s` as a scalar of a flow collection, in the style the computed strings take.
@(private)
put_flow_string :: proc(out: ^write.Out, s: string, opts: core.Write_Options) -> core.Typed_Error_Kind {
	return put_scalar_shaped(out, s, {flow = true, ascii = opts.ascii})
}

@(private)
put_scalar_shaped :: proc(out: ^write.Out, s: string, place: Place) -> core.Typed_Error_Kind {
	shape, kind := shape_of(s, place)
	if kind != .None {
		return kind
	}
	put_scalar(out, s, shape, place.ascii)
	return .None
}

// The YAML tag that spells meaning `m` of text `s`, a string of another format: `!!binary`, and `!!timestamp` on a
// text YAML reads as a timestamp of that kind. "" for none.
@(private)
meaning_tag :: proc(s: string, m: core.Tag_Meaning) -> string {
	#partial switch m {
	case .Binary:
		return "!!binary"
	case .Datetime, .Local_Datetime, .Local_Date:
		return "!!timestamp" if timestamp_kind(s) == m else ""
	}
	return ""
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
