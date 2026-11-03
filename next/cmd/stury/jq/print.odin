package jq

// Values printed as jq 1.8 prints them, token by token into a `write.Out`: its layout and its colours, strings in
// JSON's shortest escapes, a number read or written in the program as its text, and a computed one in the library's
// layout.

import "core:math"
import "../../../core/spell"
import core_pkg "../../../core"
import "../../../core/write"
import json "../../../json"

// jq's colours, as terminal escape sequences, in its order: null, false, true, numbers, strings, arrays, objects,
// keys.
Colors :: [8]string

// How values are printed: the layout and escapes `opts` asks (`pretty`, `indent`, `tab`, `ascii`, `sort_keys`), the
// colours, nil for none, and where a large output is emptied, nil for nowhere.
Layout :: struct {
	opts:   core_pkg.Write_Options,
	colors: ^Colors,
	spill:  ^Spill,
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

// The colour index of a container's punctuation and of a NaN's `null`.
@(private = "file")
OBJECT_COLOR :: int(Kind.Object)

@(private = "file")
Printer :: struct {
	out:   ^write.Out,
	using layout: Layout,
	depth: int,
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
	p := Printer{out, l, depth}
	emit(&p, v)
}

@(private = "file")
emit :: proc(p: ^Printer, v: Value) {
	k := kind(v)
	switch {
	case p.depth > MAX_DEPTH:
		token(p, int(k), "<skipped: too deep>") // what jq prints past its depth limit
	case k == .Null:
		token(p, int(k), "null")
	case k == .False:
		token(p, int(k), "false")
	case k == .True:
		token(p, int(k), "true")
	case k == .Number:
		n, _ := number_of(v)
		paint(p, int(k))
		put_number(p, n)
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
	put_byte(p.out, ':')
	unpaint(p)
	if p.opts.pretty {
		put_byte(p.out, ' ')
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
put_number :: proc(p: ^Printer, n: Number) {
	switch {
	case n.lit != "":
		write.put_text(p.out, n.lit)
	case math.is_nan(n.f):
		token(p, int(Kind.Null), "null")
	case:
		f := math.copy_sign(math.F64_MAX, n.f) if math.is_inf(n.f) else n.f
		p.out.cursor += spell.f64_text(write.room(p.out, spell.F64_ROOM), f)
	}
}

// `s` as jq prints a string, with `opts.ascii` every character past U+007F as `\u` escapes. A jq string is UTF-8, as
// jq makes each string it reads or builds. One that is not prints as `valid_utf8` makes it. The output is a buffer,
// so the cursor goes back over what a refused string wrote.
put_string :: proc(out: ^write.Out, s: string, opts: core_pkg.Write_Options) {
	mark := out.cursor
	if json.put_string(out, s, {ascii = opts.ascii}) == .Bad_Utf8 {
		out.cursor = mark
		json.put_string(out, valid_utf8(s), {ascii = opts.ascii})
	}
}

// The punctuation `c` of a container of kind `k`, painted in its colour when the layout has colours.
write_punct :: proc(out: ^write.Out, l: Layout, k: Kind, c: u8) {
	p := Printer{out, l, 0}
	paint(&p, int(k))
	put_byte(out, c)
	unpaint(&p)
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
	spare: [write.ROOM_MAX]u8
	out: write.Out
	write.init(&out, &spare, allocator)
	write_value(&out, v, l)
	text, _ := write.finish(&out)
	return string(text)
}
