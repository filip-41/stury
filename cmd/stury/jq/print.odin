package jq

// Values printed as jq 1.8 prints them into a `write.Out`: its layout and its colours, strings in JSON's shortest
// escapes, a number read or written in the program as its text, and a computed one in the library's layout. A container
// of an input document is written by the library's document writer where that writes what jq prints, and everything
// else token by token. DEL is written `\u007f`, as jq writes it.

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:math"
import "core:mem"
import "../../../core/spell"
import core_pkg "../../../core"
import "../../../core/write"
import json "../../../json"

// jq's colours, as terminal escape sequences, in its order: null, false, true, numbers, strings, arrays, objects,
// keys.
Colors :: [8]string

// How values are printed: the layout and escapes `opts` asks (`pretty`, `indent`, `tab`, `ascii`, `sort_keys`), the
// colours, nil for none, where a large output is emptied, nil for nowhere, and whether a value read from a text prints
// with its comments, as JSONC. Only an output read whole from a text has its comments: a value a filter builds keeps
// none of its members'.
Layout :: struct {
	opts:     core_pkg.Write_Options,
	colors:   ^Colors,
	spill:    ^Spill,
	comments: bool,
	colon:    string, // the bytes between a member's key and its value, when they are not jq's
}

// A layout's way to empty the output it writes into, once it holds `at` bytes, so a deep value is not held whole.
// `flush` is called only between members, never inside a token.
Spill :: struct {
	at:    int,
	flush: proc(data: rawptr),
	data:  rawptr,
}

@(private = "file")
KEY_COLOR :: 7

// The size from which the library's writer streams a value into the output, its stream buffer's.
@(private = "file")
STREAM_FROM :: 64 << 10

// The size of the stack buffer a small value's text is written into.
@(private = "file")
FRAME_TEXT :: 8 << 10

// The colour index of a container's punctuation and of a NaN's `null`.
@(private = "file")
OBJECT_COLOR :: int(Kind.Object)

@(private = "file")
Printer :: struct {
	out:      ^write.Out,
	using layout: Layout,
	depth:    int,
	streamed: bool, // the library's writer handed the printer bytes
}

// One byte at the output's cursor.
put_byte :: #force_inline proc(out: ^write.Out, b: u8) {
	write.room(out, 1)[0] = b
	out.cursor += 1
}

@(private = "file")
paint :: #force_inline proc(p: ^Printer, color: int) {
	if p.colors != nil {
		write.put_text(p.out, p.colors[color])
	}
}

@(private = "file")
unpaint :: #force_inline proc(p: ^Printer) {
	if p.colors != nil {
		write.put_text(p.out, "\e[0m")
	}
}

@(private = "file")
spill :: #force_inline proc(p: ^Printer) {
	if p.spill != nil && p.out.cursor >= p.spill.at {
		p.spill.flush(p.spill.data)
	}
}

// `v` laid out `depth` levels in. In colour, as jq's jv_dump_term paints it: each value in its kind's colour, reset
// after. A container's punctuation in its colour, reset before each member, and an object's keys in theirs. A NaN is
// a number painting a null.
write_value :: proc(out: ^write.Out, v: Value, l: Layout, depth := 0) {
	p := Printer{out = out, layout = l, depth = depth}
	emit(&p, v)
}

@(private = "file")
emit :: proc(p: ^Printer, v: Value) {
	k := kind(v)
	switch {
	case p.depth > MAX_DEPTH:
		token(p, int(k), "<skipped: too deep>") // what jq prints past its depth limit
	case (k >= .Array || p.comments && p.depth == 0) && write_node(p, v):
	case k <= .True:
		token(p, int(k), "null" if k == .Null else ("true" if k == .True else "false"))
	case k == .Number:
		paint(p, int(k))
		put_number(p, plain(v))
		unpaint(p)
	case k == .String:
		s, _ := string_of(v)
		paint(p, int(k))
		put_string(p.out, s, p.opts)
		unpaint(p)
	case is_empty(v):
		paint(p, int(k))
		write.put_text(p.out, "[]" if k == .Array else "{}")
		unpaint(p)
	case k == .Array:
		open(p, k, '[')
		it := iterate(v)
		i := 0
		for _, m in next_member(&it) {
			element(p, k, i)
			emit(p, m)
			i += 1
		}
		close(p, k, ']')
	case:
		open(p, k, '{')
		i := 0
		if p.opts.sort_keys && is_wide(v) {
			for m in sorted_members(v) {
				member(p, m.key, m.val, i)
				i += 1
			}
		} else if p.opts.sort_keys {
			for key in sorted_keys(v) {
				m, _ := object_get(v, key)
				member(p, key, m, i)
				i += 1
			}
		} else {
			it := iterate(v)
			for key, m in next_member(&it) {
				member(p, key, m, i)
				i += 1
			}
		}
		close(p, k, '}')
	}
}

// Writes `v` by the library's document writer and returns true, when it is a container of an input JSON document that
// the writer prints as jq does: with no colours, with no line indented by the printer's own depth, with no object in it
// that repeats a key, and with no level past jq's depth. A string is spelled again in JSON's shortest escapes, as jq
// spells it.
@(private = "file")
write_node :: proc(p: ^Printer, v: Value) -> bool {
	r, is_ref := v.(Ref)
	if !is_ref || p.colors != nil || p.opts.pretty && p.depth > 0 || len(p.colon) > 0 || r.doc.readers.format != json.as(.Json).readers.format ||
	   p.depth + max(int(r.doc.as.max_depth), core_pkg.MAX_DEPTH) > MAX_DEPTH || repeats_key(r) {
		return false
	}
	opts := p.opts
	opts.respell_strings, opts.escape_del = true, true
	as := json.as(.Jsonc if p.comments && p.depth == 0 else .Json)
	heap := runtime.heap_allocator()
	// A value shorter than the library's stream buffer is written whole and copied, which takes one allocation of its
	// size where a stream takes one of the buffer's.
	if size := len(core_pkg.span(r.doc, r.node)); size < STREAM_FROM {
		// The writer's buffer is the value's size and a room. A value that fits the frame buffer with that is written
		// in it, and a pretty layout that outgrows it is written again on the heap.
		frame: [FRAME_TEXT]u8 = ---
		arena: mem.Arena
		mem.arena_init(&arena, frame[:])
		on_heap := size + write.ROOM_MAX > FRAME_TEXT
		text, _, err := core_pkg.write(r.doc, opts, as, r.node, heap if on_heap else mem.arena_allocator(&arena))
		if !on_heap && err != nil {
			on_heap = true
			text, _, err = core_pkg.write(r.doc, opts, as, r.node, heap)
		}
		defer if on_heap {
			delete(text, heap)
		}
		write.put_text(p.out, string(text))
		spill(p)
		return err == nil
	}
	p.streamed = false
	to_out := io.Stream {
		data = p,
		procedure = proc(data: rawptr, mode: io.Stream_Mode, b: []byte, _: i64, _: io.Seek_From) -> (i64, io.Error) {
			if mode != .Write {
				return 0, .Unsupported
			}
			p := (^Printer)(data)
			p.streamed = true
			write.put_text(p.out, string(b))
			spill(p)
			return i64(len(b)), .None
		},
	}
	_, err := core_pkg.write_stream(to_out, r.doc, opts, as, r.node, heap)
	// Only an allocation fails, and the printer walks the value when the writer handed it nothing.
	return err == nil || p.streamed
}

// `text` in the colour `color`.
@(private = "file")
token :: proc(p: ^Printer, color: int, text: string) {
	paint(p, color)
	write.put_text(p.out, text)
	unpaint(p)
}

@(private = "file")
open :: proc(p: ^Printer, k: Kind, bracket: u8) {
	paint(p, int(k))
	put_byte(p.out, bracket)
	p.depth += 1
}

// Before member `i`: the comma after the one before in the container's colour, the colour reset, the line break.
@(private = "file")
element :: proc(p: ^Printer, k: Kind, i: int) {
	spill(p)
	if i > 0 {
		paint(p, int(k))
		put_byte(p.out, ',')
	}
	unpaint(p)
	write.put_line(p.out, p.opts, p.depth)
}

@(private = "file")
member :: proc(p: ^Printer, key: string, v: Value, i: int) {
	element(p, .Object, i)
	paint(p, KEY_COLOR)
	put_string(p.out, key, p.opts)
	unpaint(p)
	paint(p, OBJECT_COLOR)
	if len(p.colon) > 0 {
		write.put_text(p.out, p.colon)
		unpaint(p)
	} else {
		put_byte(p.out, ':')
		unpaint(p)
		if p.opts.pretty {
			put_byte(p.out, ' ')
		}
	}
	emit(p, v)
}

@(private = "file")
close :: proc(p: ^Printer, k: Kind, bracket: u8) {
	spill(p)
	p.depth -= 1
	write.put_line(p.out, p.opts, p.depth)
	paint(p, int(k))
	put_byte(p.out, bracket)
	unpaint(p)
}

// A number as its literal, or computed: a NaN as `null` in the null colour inside the number's, an infinity as the
// largest finite number of its sign.
@(private = "file")
put_number :: proc(p: ^Printer, v: Value) {
	f: f64
	#partial switch n in v {
	case ^Number_Text:
		write.put_text(p.out, n.text)
		return
	case Ref:
		room: [core_pkg.HEX_ROOM]u8 = ---
		lit, double, is_literal := node_literal(n.doc, n.node, room[:])
		if is_literal {
			write.put_text(p.out, lit)
			return
		}
		f = double
	case f64:
		f = n
	case:
		return
	}
	if math.is_nan(f) {
		token(p, int(Kind.Null), "null")
		return
	}
	f = math.copy_sign(math.F64_MAX, f) if math.is_inf(f) else f
	p.out.cursor += spell.f64_text(write.room(p.out, spell.F64_ROOM), f)
}

// `s` as jq prints a string, with `opts.ascii` every character past U+007F as `\u` escapes. A jq string is UTF-8, as
// jq makes each string it reads or builds. One that is not prints as `valid_utf8` makes it. The output is a buffer,
// so the cursor goes back over what a refused string wrote.
put_string :: proc(out: ^write.Out, s: string, opts: core_pkg.Write_Options) {
	mark := out.cursor
	if json.put_string(out, s, {ascii = opts.ascii, escape_del = true}) == .Invalid_Utf8 {
		put_valid(out, s, opts, mark)
	}
}

@(private = "file", cold)
put_valid :: #force_no_inline proc(out: ^write.Out, s: string, opts: core_pkg.Write_Options, mark: int) {
	out.cursor = mark
	json.put_string(out, valid_utf8(s), {ascii = opts.ascii, escape_del = true})
}

// The text `tostring` and string interpolation give a value: a string as itself, anything else as
// compact JSON.
text_of :: proc(v: Value) -> string {
	if s, is_str := string_of(v); is_str {
		return s
	}
	return to_json(v)
}

// `v` printed with layout `l` into a string from `allocator`.
to_json :: proc(v: Value, l := Layout{}, allocator := context.allocator) -> string {
	spare: [write.ROOM_MAX]u8 = ---
	out: write.Out
	write.init(&out, &spare, allocator)
	write_value(&out, v, l)
	size := out.size
	text, _ := write.finish(&out)
	// The buffer holds at least a ROOM_MAX, so a short text gives the rest back, as the arena's last allocation.
	if 0 < len(text) && len(text) < size {
		text, _ = runtime.non_zero_mem_resize(raw_data(text), size, len(text), 1, allocator)
	}
	return string(text)
}
