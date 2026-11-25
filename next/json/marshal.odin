package json

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:simd"
import "stury:lib/base/kernel"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"
import "stury:lib/ops/write"

// Typed writes: an Odin value written as a JSON text, which JSONC and JSON5 read too, by the plan a typed read of its
// type is made by, so the names, enums and `-` of the tags are the ones a read takes and `unmarshal` returns the value.
// The plan of a call is made and freed with it when none is given.

// Writes `value`, of a type the plan takes, as a JSON text under `opts` in a buffer from `allocator` that the
// caller owns, with the tokens a `Writer` takes. `plan` is the plan of `T` that `plan_make` made, which a call that
// writes many values of one type makes once, else nil. A `Raw` member or a `time.Time` outside years 0 to 9999 is
// `Bad_Option` naming it, and a value with no JSON spelling, a non-finite float, is `Refused`.
marshal :: proc(value: ^$T, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> (text: []u8, err: Write_Error) {
	if err = check_marshal_opts(opts); err != nil {
		return nil, err
	}
	fj: Fast_Json
	if e := write.out_start(&fj.out, allocator, {}, 0); e != nil {
		return nil, e
	}
	if err = marshal_out(&fj, value, T, opts, plan, allocator); err != nil {
		write.out_drop(&fj.out)
		return nil, err
	}
	return write.out_finish(&fj.out)
}

// `marshal` into `sink`, through a buffer of `write.SINK_BYTES` from `allocator`. On a refusal or a failed sink the
// sink may hold a prefix of the text.
marshal_to :: proc(sink: io.Writer, value: ^$T, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> Write_Error {
	if sink.procedure == nil {
		return tape.Bad_Option{"sink"}
	}
	if err := check_marshal_opts(opts); err != nil {
		return err
	}
	fj: Fast_Json
	if e := write.out_start(&fj.out, allocator, sink, 0); e != nil {
		return e
	}
	if err := marshal_out(&fj, value, T, opts, plan, allocator); err != nil {
		write.out_drop(&fj.out)
		return err
	}
	_, err := write.out_finish(&fj.out)
	return err
}

@(private)
check_marshal_opts :: #force_inline proc "contextless" (opts: Write_Options) -> Write_Error {
	if opts.format != nil {
		return tape.Bad_Option{"format"}
	}
	if opts.grow_header || len(opts.header) > 0 {
		return tape.Bad_Option{"header" if len(opts.header) > 0 else "options"}
	}
	if opts.framing == .Lines && !write.compact(opts) {
		return tape.Bad_Option{"framing"}
	}
	return nil
}

@(private)
Fast_Json :: struct {
	out:   write.Out,
	fill:  u64,
	width: int,
}

#assert(typed.JSON_MEMBER_ROOM <= write.ROOM_MAX)
#assert(typed.JSON_PRETTY_MEMBER_ROOM <= write.ROOM_MAX)
#assert(typed.JSON_PRETTY_CLOSE_ROOM <= write.ROOM_MAX)

@(private)
marshal_out :: proc(fj: ^Fast_Json, value: rawptr, T: typeid, opts: Write_Options, plan: ^Plan, allocator: runtime.Allocator) -> Write_Error {
	if opts.framing == .Seq {
		write.put_byte(&fj.out, RECORD_SEPARATOR)
	}
	fj.fill = u64(0x0909_0909_0909_0909) if opts.tab else u64(0x2020_2020_2020_2020)
	fj.width = 1 if opts.tab else int(opts.indent)
	refusal: typed.Marshal_Refusal
	err: tape.Error
	pretty := !write.compact(opts)
	switch {
	case !pretty && !opts.ascii:
		refusal, err = marshal_mode(fj, value, T, plan, false, false, allocator)
	case pretty && !opts.ascii:
		refusal, err = marshal_mode(fj, value, T, plan, true, false, allocator)
	case !pretty && opts.ascii:
		refusal, err = marshal_mode(fj, value, T, plan, false, true, allocator)
	case:
		refusal, err = marshal_mode(fj, value, T, plan, true, true, allocator)
	}
	if fj.out.err != nil {
		return fj.out.err
	}
	if err != nil {
		if memory, ok := err.(runtime.Allocator_Error); ok {
			return memory
		}
		bad, _ := err.(tape.Bad_Option)
		return bad
	}
	if refusal != .None {
		why := write.Refusal.No_Spelling if refusal == .No_Spelling else write.Refusal.Malformed
		return write.Refused{0, why}
	}
	if opts.framing != .None {
		write.put_byte(&fj.out, '\n')
	}
	return fj.out.err
}

@(private)
marshal_mode :: #force_no_inline proc(fj: ^Fast_Json, value: rawptr, T: typeid, plan: ^Plan, $PRETTY, $ASCII: bool, allocator: runtime.Allocator) -> (typed.Marshal_Refusal, tape.Error) {
	when ASCII {
		return typed.marshal_json(
			value, T, TAG, plan, fj, PRETTY,
			fast_room, fast_cursor, fast_has_err, fast_put_string_ascii, fast_put_line,
			allocator,
		)
	} else {
		return typed.marshal_json(
			value, T, TAG, plan, fj, PRETTY,
			fast_room, fast_cursor, fast_has_err, fast_put_string_utf8, fast_put_line,
			allocator,
		)
	}
}

@(private)
fast_room :: #force_inline proc(fj: ^Fast_Json, n: int) -> [^]u8 {
	return write.room(&fj.out, n)
}

@(private)
fast_cursor :: #force_inline proc "contextless" (fj: ^Fast_Json) -> ^int {
	return &fj.out.cursor
}

@(private)
fast_has_err :: #force_inline proc "contextless" (fj: ^Fast_Json) -> bool {
	return fj.out.err != nil
}

@(private)
fast_put_line :: #force_inline proc(fj: ^Fast_Json, p: [^]u8, depth: int, after: int) -> [^]u8 #no_bounds_check {
	n := depth * fj.width
	if n > typed.JSON_LINE_MAX {
		return fast_put_line_long(fj, n, after)
	}
	p[0] = '\n'
	fill := fj.fill
	for k := 0; k < n; k += 8 {
		intrinsics.unaligned_store((^u64)(p[1 + k:]), fill)
	}
	fj.out.cursor += n + 1
	return p[n + 1:]
}

@(private, cold)
fast_put_line_long :: #force_no_inline proc(fj: ^Fast_Json, n: int, after: int) -> [^]u8 #no_bounds_check {
	put_line_long(&fj.out, fj.fill, n)
	return write.room(&fj.out, after)
}

@(private)
fast_put_string_utf8 :: #force_inline proc(fj: ^Fast_Json, p: [^]u8, s: string) -> bool {
	return fast_put_string(fj, p, s, false)
}

@(private)
fast_put_string_ascii :: #force_inline proc(fj: ^Fast_Json, p: [^]u8, s: string) -> bool {
	return fast_put_string(fj, p, s, true)
}

@(private)
JSON_V :: #simd[16]u8

@(private)
JSON_PAD :: JSON_V(0x61)

@(private)
JSON_PAD_WORD :: u64(0x6161616161616161)

@(private)
JSON_MID_MAX :: write.ROOM_MAX - 18

@(private)
JSON_SCALAR_WASM :: (ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32) && !intrinsics.has_target_feature("simd128")

// Whether any lane in `v` needs escaping (`< 0x20`, `"`, `\`) or is non-ASCII (`>= 0x80`).
@(private)
json_dirty16 :: #force_inline proc "contextless" (v: JSON_V) -> bool {
	return kernel.any_lane16(kernel.control_or_high16(v, false) | simd.lanes_eq(v, JSON_V('"')) | simd.lanes_eq(v, JSON_V('\\')))
}

// Writes `s` as a JSON string at `p` (caller guarantees >= 18 bytes of room at `fj.out.cursor`).
// Returns false without advancing `cursor` when `s` is not valid UTF-8.
@(private)
fast_put_string :: #force_inline proc(fj: ^Fast_Json, p: [^]u8, s: string, $ASCII: bool) -> bool #no_bounds_check {
	when JSON_SCALAR_WASM {
		return put_string_slow(&fj.out, s, 0, ASCII)
	} else {
		if len(s) < 16 {
			v, live, ok := kernel.head16(raw_data(s), len(s))
			if ok {
				v = simd.select(simd.lanes_ne(live, JSON_V(0)), v, JSON_PAD)
			} else {
				v = json_short_block(raw_data(s), len(s))
			}
			if !json_dirty16(v) {
				p[0] = '"'
				kernel.store16(p[1:], v)
				p[1 + len(s)] = '"'
				fj.out.cursor += len(s) + 2
				return true
			}
		}
		return put_string_mid(&fj.out, s, ASCII)
	}
}

// Writes strings of 16..JSON_MID_MAX bytes in 16-byte SIMD blocks under one reservation while clean ASCII; falls back
// to `put_string_slow` on the first escape or non-ASCII byte, keeping the copied clean prefix.
@(private)
put_string_mid :: #force_no_inline proc(out: ^write.Out, s: string, $ASCII: bool) -> bool #no_bounds_check {
	n := len(s)
	if n < 16 || n > JSON_MID_MAX {
		return put_string_slow(out, s, 0, ASCII)
	}
	src := raw_data(s)
	p := write.room(out, n + 18)
	i := 0
	for ; i + 16 < n; i += 16 {
		v := kernel.load16(src[i:])
		if json_dirty16(v) {
			return put_string_slow(out, s, i, ASCII)
		}
		kernel.store16(p[1 + i:], v)
	}
	v := kernel.load16(src[n - 16:])
	if json_dirty16(v) {
		return put_string_slow(out, s, i, ASCII)
	}
	kernel.store16(p[1 + n - 16:], v)
	p[0], p[1 + n] = '"', '"'
	out.cursor += n + 2
	return true
}

// Loads `n` (< 16) bytes from `src` strictly within `[0, n)` and pads remaining lanes with `'a'`.
@(private)
json_short_block :: #force_inline proc "contextless" (src: [^]u8, n: int) -> JSON_V #no_bounds_check {
	low, high := JSON_PAD_WORD, JSON_PAD_WORD
	switch {
	case n > 8:
		low = u64(intrinsics.unaligned_load((^u64le)(src)))
		last := u64(intrinsics.unaligned_load((^u64le)(src[n - 8:])))
		high = last >> (8 * u64(16 - n)) | JSON_PAD_WORD << (8 * u64(n - 8))
	case n == 8:
		low = u64(intrinsics.unaligned_load((^u64le)(src)))
	case n >= 4:
		first := u64(intrinsics.unaligned_load((^u32le)(src)))
		last := u64(intrinsics.unaligned_load((^u32le)(src[n - 4:])))
		low = first | last << (8 * u64(n - 4)) | JSON_PAD_WORD << (8 * u64(n))
	case n > 0:
		mid := n / 2
		low = u64(src[0]) | u64(src[mid]) << (8 * u64(mid)) | u64(src[n - 1]) << (8 * u64(n - 1)) | JSON_PAD_WORD << (8 * u64(n))
	}
	return transmute(JSON_V)[2]u64{low, high}
}

// Validates UTF-8 of `s[i0:]` and writes the string, reusing the clean ASCII prefix `s[:i0]` already copied past
// `out.cursor` when `i0 > 0`.
@(private, cold)
put_string_slow :: #force_no_inline proc(out: ^write.Out, s: string, i0: int, $ASCII: bool) -> bool #no_bounds_check {
	b := transmute([]u8)s
	if !kernel.utf8_valid(b[i0:]) {
		return false
	}
	if i0 > 0 {
		write.room(out, 1)[0] = '"'
		out.cursor += 1 + i0
	} else {
		write.put_byte(out, '"')
	}
	when ASCII {
		put_ascii_body(out, s[i0:])
	} else {
		put_escaped_body(out, b[i0:])
	}
	write.put_byte(out, '"')
	return true
}

@(private)
put_escaped_body :: proc(out: ^write.Out, b: []u8) #no_bounds_check {
	run, i := 0, 0
	for {
		i = escape_from(b, i, 0)
		if i >= len(b) {
			break
		}
		write.put(out, b[run:i])
		out.cursor += escape_into(write.room(out, 6), b[i])
		i += 1
		run = i
	}
	write.put(out, b[run:])
}

@(private)
put_ascii_body :: proc(out: ^write.Out, s: string) #no_bounds_check {
	b := transmute([]u8)s
	run, i := 0, 0
	for {
		i = escape_from(b, i, ASCII_BYTES)
		if i >= len(b) {
			break
		}
		write.put(out, b[run:i])
		p := write.room(out, 12)
		if b[i] < 0x80 {
			out.cursor += escape_into(p, b[i])
			i += 1
		} else {
			c := b[i]
			switch {
			case c < 0xE0:
				out.cursor += u_escape(p, u32(c & 0x1F) << 6 | u32(b[i + 1] & 0x3F))
				i += 2
			case c < 0xF0:
				out.cursor += u_escape(p, u32(c & 0x0F) << 12 | u32(b[i + 1] & 0x3F) << 6 | u32(b[i + 2] & 0x3F))
				i += 3
			case:
				r := rune(u32(c & 0x07) << 18 | u32(b[i + 1] & 0x3F) << 12 | u32(b[i + 2] & 0x3F) << 6 | u32(b[i + 3] & 0x3F))
				out.cursor += rune_units(p, r)
				i += 4
			}
		}
		run = i
	}
	write.put(out, b[run:])
}
