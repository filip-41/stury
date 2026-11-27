package json

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:simd"
import "core:unicode/utf8"
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
	return marshal_run({}, value, T, opts, plan, allocator)
}

// `marshal` into `sink`, through a buffer of `write.SINK_BYTES` from `allocator`. On a refusal or a failed sink the
// sink may hold a prefix of the text.
marshal_to :: proc(sink: io.Writer, value: ^$T, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> Write_Error {
	if sink.procedure == nil {
		return tape.Bad_Option{"sink"}
	}
	_, err := marshal_run(sink, value, T, opts, plan, allocator)
	return err
}

@(private)
marshal_run :: proc(sink: io.Writer, value: rawptr, T: typeid, opts: Write_Options, plan: ^Plan, allocator: runtime.Allocator) -> (text: []u8, err: Write_Error) {
	if err = check_write_opts(opts); err != nil {
		return nil, err
	}
	fj: Fast_Json
	if e := write.out_start(&fj.out, allocator, sink, 0); e != nil {
		return nil, e
	}
	if err = marshal_out(&fj, value, T, opts, plan, allocator); err != nil {
		write.out_drop(&fj.out)
		return nil, err
	}
	return write.out_finish(&fj.out)
}

@(private)
check_write_opts :: #force_inline proc "contextless" (opts: Write_Options) -> Write_Error {
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
	out:       write.Out,
	line_fill: JSON_V,
	fill:      u64,
	width:     int,
}

#assert(typed.JSON_COMPACT_SLOP <= write.ROOM_MAX)
#assert(typed.JSON_PRETTY_SLOP <= write.ROOM_MAX)
#assert(typed.JSON_MEMBER_ROOM <= write.ROOM_MAX)
#assert(typed.JSON_PRETTY_MEMBER_ROOM <= write.ROOM_MAX)
#assert(typed.JSON_PRETTY_CLOSE_ROOM <= write.ROOM_MAX)

@(private)
marshal_out :: proc(fj: ^Fast_Json, value: rawptr, T: typeid, opts: Write_Options, plan: ^Plan, allocator: runtime.Allocator) -> Write_Error {
	if opts.framing == .Seq {
		write.put_byte(&fj.out, RECORD_SEPARATOR)
	}
	fill_u64 := u64(0x0909_0909_0909_0909) if opts.tab else u64(0x2020_2020_2020_2020)
	fj.fill = fill_u64
	fj.line_fill = transmute(JSON_V)[2]u64{fill_u64, fill_u64}
	fj.width = 1 if opts.tab else int(opts.indent)
	pretty := !write.compact(opts)
	refusal: typed.Marshal_Refusal
	err: tape.Error
	if opts.sort_keys {
		refusal, err = marshal_sort(fj, value, T, plan, pretty, opts.ascii, true, allocator)
	} else {
		refusal, err = marshal_sort(fj, value, T, plan, pretty, opts.ascii, false, allocator)
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
marshal_sort :: #force_inline proc(
	fj: ^Fast_Json, value: rawptr, T: typeid, plan: ^Plan,
	pretty, ascii: bool, $SORT_KEYS: bool, allocator: runtime.Allocator,
) -> (typed.Marshal_Refusal, tape.Error) {
	switch {
	case !pretty && !ascii: return marshal_mode(fj, value, T, plan, false, false, SORT_KEYS, allocator)
	case pretty && !ascii:  return marshal_mode(fj, value, T, plan, true, false, SORT_KEYS, allocator)
	case !pretty && ascii:  return marshal_mode(fj, value, T, plan, false, true, SORT_KEYS, allocator)
	}
	return marshal_mode(fj, value, T, plan, true, true, SORT_KEYS, allocator)
}

@(private)
marshal_mode :: #force_no_inline proc(
	fj: ^Fast_Json,
	value: rawptr,
	T: typeid,
	plan: ^Plan,
	$PRETTY, $ASCII, $SORT_KEYS: bool,
	allocator: runtime.Allocator,
) -> (typed.Marshal_Refusal, tape.Error) {
	when ASCII {
		return typed.marshal_json(
			value, T, TAG, plan, fj, PRETTY, SORT_KEYS,
			fast_buf_state, fast_sync_cursor, fast_grow, fast_has_err,
			fast_put_string_inline, fast_put_string_ascii_sync, fast_put_line,
			allocator,
		)
	} else {
		return typed.marshal_json(
			value, T, TAG, plan, fj, PRETTY, SORT_KEYS,
			fast_buf_state, fast_sync_cursor, fast_grow, fast_has_err,
			fast_put_string_inline, fast_put_string_utf8_sync, fast_put_line,
			allocator,
		)
	}
}

@(private)
fast_buf_state :: #force_inline proc "contextless" (fj: ^Fast_Json, slop: int) -> (buf, p, limit: [^]u8) #no_bounds_check {
	out := &fj.out
	return out.buf, out.buf[out.cursor:], out.buf[max(out.size - slop, 0):]
}

@(private)
fast_sync_cursor :: #force_inline proc "contextless" (fj: ^Fast_Json, buf, p: [^]u8) {
	fj.out.cursor = int(intrinsics.ptr_sub(p, buf))
}

@(private, cold)
fast_grow :: #force_no_inline proc(fj: ^Fast_Json, buf, p: [^]u8, need, slop: int) -> ([^]u8, [^]u8, [^]u8) #no_bounds_check {
	fj.out.cursor = int(intrinsics.ptr_sub(p, buf))
	q := write.room(&fj.out, need)
	out := &fj.out
	return out.buf, q, out.buf[max(out.size - slop, 0):]
}

@(private)
fast_has_err :: #force_inline proc "contextless" (fj: ^Fast_Json) -> bool {
	return fj.out.err != nil
}

@(private)
fast_put_line :: #force_inline proc(fj: ^Fast_Json, buf, p, limit: [^]u8, depth, after, slop: int) -> ([^]u8, [^]u8, [^]u8) #no_bounds_check {
	n := depth * fj.width
	if n > typed.JSON_LINE_MAX {
		return fast_put_line_long(fj, buf, p, n, after, slop)
	}
	p[0] = '\n'
	fill := fj.line_fill
	kernel.store16(p[1:], fill)
	if n > 16 {
		for k := 16; k < n; k += 16 {
			kernel.store16(p[1 + k:], fill)
		}
	}
	return buf, p[n + 1:], limit
}

@(private, cold)
fast_put_line_long :: #force_no_inline proc(fj: ^Fast_Json, buf, p: [^]u8, n, after, slop: int) -> ([^]u8, [^]u8, [^]u8) #no_bounds_check {
	fj.out.cursor = int(intrinsics.ptr_sub(p, buf))
	write.line_indent(&fj.out, 1, fj.fill, n)
	q := write.room(&fj.out, max(after, slop))
	out := &fj.out
	return out.buf, q, out.buf[max(out.size - slop, 0):]
}

@(private)
fast_put_string_sync :: #force_inline proc(fj: ^Fast_Json, buf, p: [^]u8, s: string, slop: int, $ASCII: bool) -> ([^]u8, [^]u8, [^]u8, bool) #no_bounds_check {
	fj.out.cursor = int(intrinsics.ptr_sub(p, buf))
	if !put_string_long_fast(&fj.out, s, ASCII) {
		return buf, p, buf, false
	}
	out := &fj.out
	if out.size - out.cursor < slop && out.err == nil {
		_ = write.room(out, slop)
	}
	return out.buf, out.buf[out.cursor:], out.buf[max(out.size - slop, 0):], true
}

@(private)
fast_put_string_utf8_sync :: #force_no_inline proc(fj: ^Fast_Json, buf, p: [^]u8, s: string, slop: int) -> ([^]u8, [^]u8, [^]u8, bool) #no_bounds_check {
	return fast_put_string_sync(fj, buf, p, s, slop, false)
}

@(private)
fast_put_string_ascii_sync :: #force_no_inline proc(fj: ^Fast_Json, buf, p: [^]u8, s: string, slop: int) -> ([^]u8, [^]u8, [^]u8, bool) #no_bounds_check {
	return fast_put_string_sync(fj, buf, p, s, slop, true)
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
JSON_SEGMENT :: 512

@(private)
JSON_SCALAR_WASM :: (ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32) && !intrinsics.has_target_feature("simd128")

// Whether any lane in `v` needs escaping (`< 0x20`, `"`, `\`) or is non-ASCII (`>= 0x80`).
@(private)
json_dirty16 :: #force_inline proc "contextless" (v: JSON_V) -> bool {
	return kernel.any_lane16(kernel.control_or_high16(v, false) | simd.lanes_eq(v, JSON_V('"')) | simd.lanes_eq(v, JSON_V('\\')))
}

// Writes `s` directly at `p` (caller guarantees >= 64 B free) when clean ASCII <= 32 B; returns bytes written (> 0) or 0 to delegate.
@(private)
fast_put_string_inline :: #force_inline proc "contextless" (p: [^]u8, s: string) -> int #no_bounds_check {
	when JSON_SCALAR_WASM {
		return 0
	} else {
		n := len(s)
		if n == 0 {
			p[0], p[1] = '"', '"'
			return 2
		}
		src := raw_data(s)
		if n < 16 {
			v, live, ok := kernel.head16(src, n)
			if ok {
				v = simd.select(simd.lanes_ne(live, JSON_V(0)), v, JSON_PAD)
			} else {
				v = json_short_block(src, n)
			}
			if !json_dirty16(v) {
				p[0] = '"'
				kernel.store16(p[1:], v)
				p[1 + n] = '"'
				return n + 2
			}
		} else if n <= 32 {
			v0 := kernel.load16(src)
			v1 := kernel.load16(src[n - 16:])
			d0 := kernel.control_or_high16(v0, false) | simd.lanes_eq(v0, JSON_V('"')) | simd.lanes_eq(v0, JSON_V('\\'))
			d1 := kernel.control_or_high16(v1, false) | simd.lanes_eq(v1, JSON_V('"')) | simd.lanes_eq(v1, JSON_V('\\'))
			if !kernel.any_lane16(d0 | d1) {
				p[0] = '"'
				kernel.store16(p[1:], v0)
				kernel.store16(p[1 + n - 16:], v1)
				p[1 + n] = '"'
				return n + 2
			}
		}
		return 0
	}
}

// Writes strings > 32 B cleanly via 16-byte SIMD copies while pure ASCII; falls back to `put_string_mixed` (UTF-8)
// or `put_string_slow` (ASCII / scalar WASM / big-endian), reusing any clean prefix already copied.
@(private)
put_string_long_fast :: #force_no_inline proc(out: ^write.Out, s: string, $ASCII: bool) -> bool #no_bounds_check {
	i := 0
	when !JSON_SCALAR_WASM {
		n := len(s)
		src := raw_data(s)
		if n >= 16 && n <= JSON_MID_MAX && src[0] < 0x80 {
			p := write.room(out, n + 18)
			clean := true
			for ; i + 16 < n; i += 16 {
				v := kernel.load16(src[i:])
				if json_dirty16(v) {
					clean = false
					break
				}
				kernel.store16(p[1 + i:], v)
			}
			if clean {
				v := kernel.load16(src[n - 16:])
				if !json_dirty16(v) {
					kernel.store16(p[1 + n - 16:], v)
					p[0], p[1 + n] = '"', '"'
					out.cursor += n + 2
					return true
				}
			}
		}
	}
	when !ASCII && !JSON_SCALAR_WASM && ODIN_ENDIAN == .Little {
		return put_string_mixed(out, s, i)
	} else {
		return put_string_slow(out, s, i, ASCII)
	}
}

when !JSON_SCALAR_WASM && ODIN_ENDIAN == .Little {
	// Writes escaped and/or non-ASCII strings in 16-byte SIMD blocks using `MODEL_ESC_SEQ`, validating UTF-8 inline
	// via `kernel.utf8_window` on already-loaded vectors with no second scan pass.
	@(private, enable_target_feature = STATE_FEATURES)
	put_string_mixed :: #force_no_inline proc(out: ^write.Out, s: string, i0: int) -> bool #no_bounds_check {
		n := len(s)
		src := raw_data(s)
		if i0 > 0 {
			// Caller (`put_string_long_fast`) already reserved `n + 18` bytes and copied `src[:i0]` at `out.buf[out.cursor + 1:]`.
			out.buf[out.cursor] = '"'
			out.cursor += 1 + i0
		}
		prev, bad: JSON_V
		high := false
		for i := i0; i < n; {
			if out.err != nil {
				return true
			}
			end := min(i + JSON_SEGMENT, n)
			base := write.room(out, 6 * (end - i + 16) + 18)
			o := 0
			if i == 0 {
				base[0] = '"'
				o = 1
			}
			for i < end {
				left := n - i
				v := kernel.load16(src[i:]) if left >= 16 else json_short_block(src[i:], left)
				take := min(left, 16)
				h := !kernel.is_ascii16(v)
				if h || high {
					bad |= kernel.utf8_window(prev, v)
				}
				prev, high = v, h
				esc := simd.lanes_lt(v, JSON_V(0x20)) | simd.lanes_eq(v, JSON_V('"')) | simd.lanes_eq(v, JSON_V('\\'))
				if kernel.any_lane16(esc) {
					o = model_put_esc16(base[o:], v) + o - (16 - take)
				} else {
					kernel.store16(base[o:], v)
					o += take
				}
				i += take
			}
			if end == n {
				if high {
					bad |= kernel.utf8_window(prev, JSON_PAD)
				}
				if !kernel.all_zero(bad) {
					return false
				}
				base[o] = '"'
				o += 1
			}
			out.cursor += o
		}
		return true
	}
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
			r, size := utf8.decode_rune(b[i:])
			out.cursor += rune_units(p, r)
			i += size
		}
		run = i
	}
	write.put(out, b[run:])
}
