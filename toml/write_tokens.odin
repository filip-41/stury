package toml

// The token write of TOML. TOML fixes an order the calls cannot know, since a table's keys stand before the sections of
// its tables, so the calls write the value as an inline table behind `r = `, and `end` reads that back and lays it out
// as `write_document.odin` does. A write that stands at a site of a document is the inline text as it is. Null is a word
// TOML has no reading for, so a write that holds one is `.Unwritable`, and a write to a stream is `.Unsupported`, since
// `end` has the whole text to lay out only in a buffer.

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
	.Comma        = ",",
	.Colon        = "=",
	.After_Colon  = " ",
	.Null         = "null",
	.True         = "true",
	.False        = "false",
	.Point_Zero   = ".0",
	.Inf          = "inf",
	.Neg_Inf      = "-inf",
	.Nan          = "nan",
	.Heads        = "",
	.Bytes_Tag    = "",
}

// The number spellings of TOML past JSON's.
@(private)
NUMBER_FORMS :: write.Number_Forms{.Hex, .Octal, .Binary, .Plus}

@(private, rodata)
TOKENS := write.Token_Spelling {
	tree = TREE,
	// A whole text is written behind a key that `end` puts at `mark`, after the root's comments, and lays out. `state`
	// records it.
	start = proc(t: ^write.Tokens, _: core.As) -> core.Typed_Error_Kind {
		// The text is laid out once it is whole, and a stream has taken its bytes by then.
		if t.out.stream.procedure != nil {
			return .Unsupported
		}
		// An inline table is one line, and the layout of the document is the writer's own, so the calls never indent.
		t.opts.pretty = false
		if !t.site.placed {
			t.state = rawptr(&TOKENS)
		}
		return .None
	},
	value = proc(t: ^write.Tokens, v: write.Scalar) -> core.Typed_Error_Kind {
		switch x in v {
		case string:
			return put_basic(t.out, x, t.opts)
		case typed.Bytes:
			stack: [512]u8
			text, ok := write.bytes_text(cast([]u8)x, stack[:])
			return put_basic(t.out, text, t.opts) if ok else .No_Memory
		case core.Number:
			return write.put_number_as(t.out, x, TREE)
		case write.Number_Literal:
			write.put_text(t.out, x.text)
		case write.Tagged_Text:
			// A tag that is no TOML type leaves a string, and so does another format's datetime that no TOML one spells.
			tag := DATETIME_TAGS[x.meaning] if x.meaning != .Own else x.tag
			if tag != "" && tag_datetime(tag) == .Own || x.meaning != .Own && text_datetime(x.text) != x.meaning {
				return put_basic(t.out, x.text, t.opts)
			}
			return put_datetime(t.out, x.text, tag)
		case write.Tree_Part:
			write.put_text(t.out, t.spell.tree[x])
		}
		return .None
	},
	end = proc(t: ^write.Tokens, bytes: []u8) -> ([]u8, core.Typed_Refusal) {
		if t.state == nil {
			if t.site.placed {
				return inline_text(bytes, t.base.allocator)
			}
			return bytes, {}
		}
		return lay_out_text(bytes, t.mark, t.opts, {}, t.base.allocator)
	},
	// A comment is TOML 1.1's, which an inline table holds on lines of its own, and `end` reads it back as 1.1. An
	// inline comment that follows one on the same item joins it.
	comment = proc(t: ^write.Tokens, role: core.Role, text: string) -> core.Typed_Error_Kind {
		if !write.comment_lines_ok(text) {
			return .Unwritable
		}
		if role == .Comment_Inline && strings.index_byte(text, '\n') < 0 && ends_inline_comment(t.out) {
			t.out.cursor -= 1
			write.put_text(t.out, " " if len(text) > 0 else "")
			write.put_text(t.out, text)
			write.put_byte(t.out, '\n')
			return .None
		}
		write.put_byte(t.out, ' ' if role == .Comment_Inline else '\n')
		write.put_comment(t.out, "#", text, true, 0)
		write.put_byte(t.out, '\n')
		if t.top == 0 && role == .Comment {
			t.mark = t.out.cursor
		}
		return .None
	},
}

// Whether the text written so far ends with an inline comment. Only a comment ends a line in the calls' text, whose
// strings are basic, and a line that holds a value before its comment is an inline one.
@(private)
ends_inline_comment :: proc(out: ^write.Out) -> bool {
	written := string(out.buf[:out.cursor])
	if !strings.has_suffix(written, "\n") {
		return false
	}
	start := strings.last_index_byte(written[:len(written) - 1], '\n')
	if start < 0 && out.flushed > 0 {
		return false
	}
	return !strings.has_prefix(written[start + 1:], "#")
}

@(private)
put_plain :: proc(out: ^write.Out, _: [^]u8, s: string, opts: ^core.Write_Options) -> core.Typed_Error_Kind {
	return put_basic(out, s, opts^)
}

// The plan's `marshal`: the value as an inline table, laid out as a document. A value that is no table is
// `.Unsupported`.
@(private)
marshal_text :: proc(plan: ^typed.Plan, value: rawptr, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator, omits: ^typed.Omits) -> ([]u8, core.Typed_Refusal) {
	bytes, err := write.marshal_as(plan, value, opts, {}, allocator, TREE, put_plain, put_plain, omits)
	if err.kind != .None {
		return nil, err
	}
	return lay_out_text(bytes, 0, opts, stream, allocator)
}

// The value `bytes` holds, spelled as the inline value the document writer puts in a line: bare keys, a space inside
// the braces and after each comma.
@(private)
inline_text :: proc(bytes: []u8, allocator: runtime.Allocator) -> ([]u8, core.Typed_Refusal) {
	keyed, made := keyed_text(bytes, 0, allocator)
	if !made {
		return nil, {kind = .No_Memory}
	}
	defer delete(keyed, allocator)
	doc, berr := build_text(keyed, bound_as(.Toml_1_0), context.allocator)
	defer core.destroy(&doc)
	if berr.kind != .None {
		return nil, {kind = .Unwritable if berr.kind == .Walk else .No_Memory}
	}
	it := core.pairs(&doc, core.ROOT)
	_, value, found := core.pair_next(&it)
	if !found {
		return nil, {kind = .Unwritable}
	}
	spill: [write.ROOM_MAX]u8 = ---
	l := Layout{doc = &doc, own = true}
	l.arena.backing_allocator = context.allocator
	defer runtime.arena_destroy(&l.arena)
	l.path.allocator = runtime.arena_allocator(&l.arena)
	write.init(&l.out, &spill, allocator)
	kind := put_inline(&l, value)
	return write.finish(&l.out, {kind = kind})
}
