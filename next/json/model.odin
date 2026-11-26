// Streaming JSON/JSONC/JSON5 model loading (zero intermediate `tape.Document`) and direct-buffer JSON model dumping.
package json

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:simd"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:lib/schema/model"

@(private)
model_has_high16 :: #force_inline proc "contextless" (v: #simd[16]u8) -> bool {
	return kernel.any_lane16(simd.lanes_ge(v, JSON_V(0x80)))
}

@(private)
model_probe_stack :: #force_inline proc "contextless" () {
	hook.probe_stack(READ_STACK)
}

@(private)
model_bad_sink :: proc "contextless" () -> model.Error {
	return tape.Error(tape.Bad_Option{"sink"})
}

// Loads `src`, a JSON/JSONC/JSON5 text of `spec`, directly into `out` according to compiled model `m`
// by streaming tokens over the format walk with zero intermediate `tape.Document` allocation.
@(require_results)
load :: #force_inline proc(
	m: ^model.Model($T), src: []u8, out: ^T, spec := Spec.Json,
	sink: ^model.Sink = nil, opts := model.Load_Opts{}, allocator := context.allocator,
) -> model.Error {
	model_probe_stack()
	if spec > .Json5 { return model.Model_Error{kind = .Bad_Option, want = {text = "spec"}} }
	lax, refuse := opts.budget.steps != 0, opts.dups == .Default || opts.dups == .Refuse
	#partial switch spec {
	case .Json:  return load_as(m, src, out, .Json, lax, refuse, sink, opts, allocator)
	case .Jsonc: return load_as(m, src, out, .Jsonc, lax, refuse, sink, opts, allocator)
	case .Json5: return load_as(m, src, out, .Json5, lax, refuse, sink, opts, allocator)
	}
	return model.Model_Error{kind = .Bad_Option, want = {text = "spec"}}
}

@(private)
load_as :: #force_inline proc(
	m: ^model.Model($T), src: []u8, out: ^T, $S: Spec, lax, refuse: bool, sink: ^model.Sink, opts: model.Load_Opts, allocator: runtime.Allocator,
) -> model.Error {
	if refuse { return load_run(m, src, out, S, true, true, sink, opts, allocator) if lax else load_run(m, src, out, S, false, true, sink, opts, allocator) }
	return load_run(m, src, out, S, true, false, sink, opts, allocator) if lax else load_run(m, src, out, S, false, false, sink, opts, allocator)
}

@(private)
load_run :: #force_no_inline proc(
	m: ^model.Model($T), src: []u8, out: ^T, $S: Spec, $LAX, $REFUSE: bool, sink: ^model.Sink, opts: model.Load_Opts, allocator: runtime.Allocator,
) -> model.Error {
	walk_opts := Options{dups = opts.dups, budget = opts.budget, scratch = opts.scratch}
	build_fb :: proc(src: []u8, opts: Options, a: runtime.Allocator) -> (tape.Document, tape.Error) { return build(src, S, opts, a) }
	when REFUSE {
		walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^model.Refusing_Loader, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
			on :: #force_inline proc "contextless" (h: ^model.Refusing_Loader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) { return model.refusing_loader_hook(h, s, t, number_value) }
			return walk_text(src, S, LAX, opts, h, regs, a, ctx, on)
		}
		return model.load_stream(m, src, &FORMATS[S], out, sink, opts, walk_opts, allocator, model.Refusing_Loader, walk, build_fb)
	} else {
		walk :: #force_inline proc "contextless" (src: []u8, opts: Options, h: ^model.Stream_Loader, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
			on :: #force_inline proc "contextless" (h: ^model.Stream_Loader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) { return model.stream_loader_hook(h, s, t, number_value) }
			return walk_text(src, S, LAX, opts, h, regs, a, ctx, on)
		}
		return model.load_stream(m, src, &FORMATS[S], out, sink, opts, walk_opts, allocator, model.Stream_Loader, walk, build_fb)
	}
}

// ============================================================================
// Direct-buffer JSON model dumping (`json.dump` / `json.dump_to`)
// ============================================================================

#assert(model.JSON_MEMBER_ROOM <= write.ROOM_MAX)
#assert(model.JSON_PRETTY_MEMBER_ROOM <= write.ROOM_MAX)
#assert(model.JSON_PRETTY_CLOSE_ROOM <= write.ROOM_MAX)

// Dumps `v` according to model `m` directly to JSON bytes owned by `allocator`,
// bypassing `Token_Tape`, `tape.Document`, and per-record arenas with zero double-copy.
@(require_results)
dump :: proc(
	m: ^model.Model($T), v: ^T, opts := model.Dump_Opts{}, wopts := Write_Options{}, sink: ^model.Sink = nil, allocator := context.allocator,
) -> (text: []u8, err: model.Error) {
	if werr := check_marshal_opts(wopts); werr != nil { return nil, werr }
	min_room := model.JSON_PRETTY_CLOSE_ROOM if !write.compact(wopts) else max(512, model.dump_size_hint(m) * 2)
	raw, aerr := runtime.mem_alloc_non_zeroed(min_room, 1, allocator)
	if aerr != nil || raw_data(raw) == nil || len(raw) < min_room { return nil, runtime.Allocator_Error.Out_Of_Memory }
	fj := Fast_Json{out = {buf = raw_data(raw), size = min_room, allocator = allocator}}
	return dump_run(&fj, m, v, opts, wopts, sink, allocator)
}

// Dumps `v` according to model `m` directly as JSON into streaming `io.Writer` `w`.
@(require_results)
dump_to :: proc(
	w: io.Writer, m: ^model.Model($T), v: ^T, opts := model.Dump_Opts{}, wopts := Write_Options{}, sink: ^model.Sink = nil, allocator := context.allocator,
) -> model.Error {
	if w.procedure == nil { return model_bad_sink() }
	if werr := check_marshal_opts(wopts); werr != nil { return werr }
	fj: Fast_Json
	if e := write.out_start(&fj.out, allocator, w, 0); e != nil { return e }
	_, err := dump_run(&fj, m, v, opts, wopts, sink, allocator)
	return err
}

@(private)
dump_run :: proc(fj: ^Fast_Json, m: ^model.Model($T), v: ^T, opts: model.Dump_Opts, wopts: Write_Options, sink: ^model.Sink, allocator: runtime.Allocator) -> ([]u8, model.Error) {
	fj.fill = u64(0x0909_0909_0909_0909) if wopts.tab else u64(0x2020_2020_2020_2020)
	fj.width = 1 if wopts.tab else int(wopts.indent)
	if wopts.framing == .Seq { model_fast_room(fj, 1)[0] = RECORD_SEPARATOR; fj.out.cursor += 1 }
	pretty, err := !write.compact(wopts), model.Error(nil)
	switch {
	case !pretty && !wopts.ascii: err = dump_mode(fj, m, v, opts, sink, false, false, allocator)
	case pretty && !wopts.ascii:  err = dump_mode(fj, m, v, opts, sink, true, false, allocator)
	case !pretty && wopts.ascii:  err = dump_mode(fj, m, v, opts, sink, false, true, allocator)
	case:                         err = dump_mode(fj, m, v, opts, sink, true, true, allocator)
	}
	if fj.out.err != nil { model.error_destroy(err, allocator); write.out_drop(&fj.out); return nil, fj.out.err }
	if err != nil { write.out_drop(&fj.out); return nil, err }
	if wopts.framing != .None { model_fast_room(fj, 1)[0] = '\n'; fj.out.cursor += 1 }
	t, ferr := write.out_finish(&fj.out)
	if ferr != nil { return nil, ferr }
	return t, fj.out.err if fj.out.err != nil else nil
}

@(private)
dump_mode :: #force_no_inline proc(fj: ^Fast_Json, m: ^model.Model($T), v: ^T, opts: model.Dump_Opts, sink: ^model.Sink, $PRETTY, $ASCII: bool, allocator: runtime.Allocator) -> model.Error {
	when ASCII {
		return model.dump_json(m, v, opts, sink, fj, PRETTY, model_fast_room, model_fast_cursor, fast_has_err, model_put_string_ascii, model_fast_put_line, allocator)
	} else {
		return model.dump_json(m, v, opts, sink, fj, PRETTY, model_fast_room, model_fast_cursor, fast_has_err, model_put_string_utf8, model_fast_put_line, allocator)
	}
}

@(private)
model_fast_room :: #force_inline proc(fj: ^Fast_Json, n: int) -> [^]u8 {
	return write.room(&fj.out, n)
}

@(private)
model_fast_cursor :: #force_inline proc "contextless" (fj: ^Fast_Json) -> ^int {
	return &fj.out.cursor
}

@(private)
model_fast_put_line :: #force_inline proc(fj: ^Fast_Json, p: [^]u8, depth: int, after: int) -> [^]u8 #no_bounds_check {
	n := depth * fj.width
	if n > model.JSON_LINE_MAX {
		return model_fast_put_line_long(fj, n, after)
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
model_fast_put_line_long :: #force_no_inline proc(fj: ^Fast_Json, n: int, after: int) -> [^]u8 #no_bounds_check {
	put_line_long(&fj.out, fj.fill, n)
	return write.room(&fj.out, after)
}

@(private)
model_put_string_utf8 :: #force_inline proc(fj: ^Fast_Json, p: [^]u8, s: string) -> bool {
	return model_put_string(fj, p, s, false)
}

@(private)
model_put_string_ascii :: #force_inline proc(fj: ^Fast_Json, p: [^]u8, s: string) -> bool {
	return model_put_string(fj, p, s, true)
}

@(private)
model_put_string :: #force_inline proc(fj: ^Fast_Json, p: [^]u8, s: string, $ASCII: bool) -> bool #no_bounds_check {
	when JSON_SCALAR_WASM {
		return put_string_slow(&fj.out, s, 0, ASCII)
	} else {
		n := len(s)
		if n < 16 {
			v, live, ok := kernel.head16(raw_data(s), n)
			if ok {
				v = simd.select(simd.lanes_ne(live, JSON_V(0)), v, JSON_PAD)
			} else {
				v = json_short_block(raw_data(s), n)
			}
			if !json_dirty16(v) {
				p[0] = '"'
				kernel.store16(p[1:], v)
				p[1 + n] = '"'
				fj.out.cursor += n + 2
				return true
			}
		} else if n <= 32 {
			// Caller guarantees `JSON_LEAF_ROOM` (64 B) at `p`: two overlapping 16-byte SIMD ops handle 16..32 B inline.
			src := raw_data(s)
			v0 := kernel.load16(src)
			v1 := kernel.load16(src[n - 16:])
			if !json_dirty16(v0) && !json_dirty16(v1) {
				p[0] = '"'
				kernel.store16(p[1:], v0)
				kernel.store16(p[1 + n - 16:], v1)
				p[1 + n] = '"'
				fj.out.cursor += n + 2
				return true
			}
		}
		return model_put_string_long(fj, s, ASCII)
	}
}

// Branchless JSON escape table: low bytes hold the escaped ASCII sequence, high byte holds its length (1, 2, or 6).
@(private, rodata)
MODEL_ESC_SEQ := [256]u64le{
	0x060030303030755c, 0x060031303030755c, 0x060032303030755c, 0x060033303030755c, 0x060034303030755c, 0x060035303030755c, 0x060036303030755c, 0x060037303030755c,
	0x020000000000625c, 0x020000000000745c, 0x0200000000006e5c, 0x060062303030755c, 0x020000000000665c, 0x020000000000725c, 0x060065303030755c, 0x060066303030755c,
	0x060030313030755c, 0x060031313030755c, 0x060032313030755c, 0x060033313030755c, 0x060034313030755c, 0x060035313030755c, 0x060036313030755c, 0x060037313030755c,
	0x060038313030755c, 0x060039313030755c, 0x060061313030755c, 0x060062313030755c, 0x060063313030755c, 0x060064313030755c, 0x060065313030755c, 0x060066313030755c,
	0x0100000000000020, 0x0100000000000021, 0x020000000000225c, 0x0100000000000023, 0x0100000000000024, 0x0100000000000025, 0x0100000000000026, 0x0100000000000027,
	0x0100000000000028, 0x0100000000000029, 0x010000000000002a, 0x010000000000002b, 0x010000000000002c, 0x010000000000002d, 0x010000000000002e, 0x010000000000002f,
	0x0100000000000030, 0x0100000000000031, 0x0100000000000032, 0x0100000000000033, 0x0100000000000034, 0x0100000000000035, 0x0100000000000036, 0x0100000000000037,
	0x0100000000000038, 0x0100000000000039, 0x010000000000003a, 0x010000000000003b, 0x010000000000003c, 0x010000000000003d, 0x010000000000003e, 0x010000000000003f,
	0x0100000000000040, 0x0100000000000041, 0x0100000000000042, 0x0100000000000043, 0x0100000000000044, 0x0100000000000045, 0x0100000000000046, 0x0100000000000047,
	0x0100000000000048, 0x0100000000000049, 0x010000000000004a, 0x010000000000004b, 0x010000000000004c, 0x010000000000004d, 0x010000000000004e, 0x010000000000004f,
	0x0100000000000050, 0x0100000000000051, 0x0100000000000052, 0x0100000000000053, 0x0100000000000054, 0x0100000000000055, 0x0100000000000056, 0x0100000000000057,
	0x0100000000000058, 0x0100000000000059, 0x010000000000005a, 0x010000000000005b, 0x0200000000005c5c, 0x010000000000005d, 0x010000000000005e, 0x010000000000005f,
	0x0100000000000060, 0x0100000000000061, 0x0100000000000062, 0x0100000000000063, 0x0100000000000064, 0x0100000000000065, 0x0100000000000066, 0x0100000000000067,
	0x0100000000000068, 0x0100000000000069, 0x010000000000006a, 0x010000000000006b, 0x010000000000006c, 0x010000000000006d, 0x010000000000006e, 0x010000000000006f,
	0x0100000000000070, 0x0100000000000071, 0x0100000000000072, 0x0100000000000073, 0x0100000000000074, 0x0100000000000075, 0x0100000000000076, 0x0100000000000077,
	0x0100000000000078, 0x0100000000000079, 0x010000000000007a, 0x010000000000007b, 0x010000000000007c, 0x010000000000007d, 0x010000000000007e, 0x010000000000007f,
	0x0100000000000080, 0x0100000000000081, 0x0100000000000082, 0x0100000000000083, 0x0100000000000084, 0x0100000000000085, 0x0100000000000086, 0x0100000000000087,
	0x0100000000000088, 0x0100000000000089, 0x010000000000008a, 0x010000000000008b, 0x010000000000008c, 0x010000000000008d, 0x010000000000008e, 0x010000000000008f,
	0x0100000000000090, 0x0100000000000091, 0x0100000000000092, 0x0100000000000093, 0x0100000000000094, 0x0100000000000095, 0x0100000000000096, 0x0100000000000097,
	0x0100000000000098, 0x0100000000000099, 0x010000000000009a, 0x010000000000009b, 0x010000000000009c, 0x010000000000009d, 0x010000000000009e, 0x010000000000009f,
	0x01000000000000a0, 0x01000000000000a1, 0x01000000000000a2, 0x01000000000000a3, 0x01000000000000a4, 0x01000000000000a5, 0x01000000000000a6, 0x01000000000000a7,
	0x01000000000000a8, 0x01000000000000a9, 0x01000000000000aa, 0x01000000000000ab, 0x01000000000000ac, 0x01000000000000ad, 0x01000000000000ae, 0x01000000000000af,
	0x01000000000000b0, 0x01000000000000b1, 0x01000000000000b2, 0x01000000000000b3, 0x01000000000000b4, 0x01000000000000b5, 0x01000000000000b6, 0x01000000000000b7,
	0x01000000000000b8, 0x01000000000000b9, 0x01000000000000ba, 0x01000000000000bb, 0x01000000000000bc, 0x01000000000000bd, 0x01000000000000be, 0x01000000000000bf,
	0x01000000000000c0, 0x01000000000000c1, 0x01000000000000c2, 0x01000000000000c3, 0x01000000000000c4, 0x01000000000000c5, 0x01000000000000c6, 0x01000000000000c7,
	0x01000000000000c8, 0x01000000000000c9, 0x01000000000000ca, 0x01000000000000cb, 0x01000000000000cc, 0x01000000000000cd, 0x01000000000000ce, 0x01000000000000cf,
	0x01000000000000d0, 0x01000000000000d1, 0x01000000000000d2, 0x01000000000000d3, 0x01000000000000d4, 0x01000000000000d5, 0x01000000000000d6, 0x01000000000000d7,
	0x01000000000000d8, 0x01000000000000d9, 0x01000000000000da, 0x01000000000000db, 0x01000000000000dc, 0x01000000000000dd, 0x01000000000000de, 0x01000000000000df,
	0x01000000000000e0, 0x01000000000000e1, 0x01000000000000e2, 0x01000000000000e3, 0x01000000000000e4, 0x01000000000000e5, 0x01000000000000e6, 0x01000000000000e7,
	0x01000000000000e8, 0x01000000000000e9, 0x01000000000000ea, 0x01000000000000eb, 0x01000000000000ec, 0x01000000000000ed, 0x01000000000000ee, 0x01000000000000ef,
	0x01000000000000f0, 0x01000000000000f1, 0x01000000000000f2, 0x01000000000000f3, 0x01000000000000f4, 0x01000000000000f5, 0x01000000000000f6, 0x01000000000000f7,
	0x01000000000000f8, 0x01000000000000f9, 0x01000000000000fa, 0x01000000000000fb, 0x01000000000000fc, 0x01000000000000fd, 0x01000000000000fe, 0x01000000000000ff,
}

@(private)
model_put_esc16 :: #force_inline proc "contextless" (dst: [^]u8, v: JSON_V) -> int #no_bounds_check {
	pos := 0
	blk := transmute([16]u8)v
	for c in blk {
		seq := MODEL_ESC_SEQ[c]
		intrinsics.unaligned_store((^u64le)(dst[pos:]), seq)
		pos += int(seq >> 56)
	}
	return pos
}

@(private)
model_put_tail :: #force_inline proc(dst: [^]u8, src: [^]u8, b: []u8, i, n: int, utf8_ok: ^bool) -> (int, bool) #no_bounds_check {
	pos := 0
	for j := i; j < n; j += 1 {
		c := src[j]
		if !utf8_ok^ && c >= 0x80 {
			if !kernel.utf8_valid(b[j:]) { return 0, false }
			utf8_ok^ = true
		}
		seq := MODEL_ESC_SEQ[c]
		intrinsics.unaligned_store((^u64le)(dst[pos:]), seq)
		pos += int(seq >> 56)
	}
	dst[pos] = '"'
	return pos + 1, true
}

// Fast copy + escape for strings > 32 B or containing escapes/UTF-8.
// Reuses `put_string_slow` for ASCII/long/tight-room fallbacks while keeping the fast in-buffer branchless SIMD path.
@(private)
model_put_string_long :: #force_no_inline proc(fj: ^Fast_Json, s: string, $ASCII: bool) -> bool #no_bounds_check {
	n := len(s)
	out := &fj.out
	src := raw_data(s)
	i := 0
	when !JSON_SCALAR_WASM {
		if n >= 16 && n <= JSON_MID_MAX && src[0] < 0x80 {
			p := write.room(out, n + 18)
			clean := true
			for ; i + 16 < n; i += 16 {
				v := kernel.load16(src[i:])
				if json_dirty16(v) { clean = false; break }
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
		if n <= JSON_MID_MAX && (n - i) * 6 + 16 <= out.size - (out.cursor + 1 + i) {
			b := transmute([]u8)s
			write.room(out, 1)[0] = '"'
			out.cursor += 1 + i
			utf8_ok := false
			p := out.buf[out.cursor:]
			pos := 0
			for ; i + 16 <= n; i += 16 {
				v := kernel.load16(src[i:])
				if !utf8_ok && model_has_high16(v) {
					if !kernel.utf8_valid(b[i:]) { return false }
					utf8_ok = true
				}
				if !json_dirty16(v) { kernel.store16(p[pos:], v); pos += 16 } else { pos += model_put_esc16(p[pos:], v) }
			}
			tail, ok := model_put_tail(p[pos:], src, b, i, n, &utf8_ok)
			if !ok { return false }
			out.cursor += pos + tail
			return true
		}
	}
	return put_string_slow(out, s, i, ASCII)
}
