package cbor

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "stury:lib/base/kernel"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"
import "stury:lib/ops/write"

// Typed writes: `value` written directly as CBOR by the plan a typed read of its type is made by, bypassing
// token sequences, intermediate documents and decimal number round-trips. Its plan is the one `plan_make` of this
// package makes, or nil to make one for the call. Under `.Cbor` (without `opts.sort_keys`), containers use indefinite
// encoding (`0xBF`/`0x9F`..`0xFF`); under `.Preferred`, `.Deterministic`, and `.Length_First` (or `opts.sort_keys`),
// containers use definite lengths, preferred narrowest numbers, and canonical/sorted keys as the spec requires.
marshal :: proc(value: ^$T, spec := Spec.Cbor, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> (item: []u8, err: Write_Error) {
	if err = check_marshal_opts(spec, opts); err != nil {
		return nil, err
	}
	fc: Fast_Cbor
	if e := write.out_start(&fc.out, allocator, {}, 0); e != nil {
		return nil, e
	}
	if err = marshal_out(&fc, value, T, spec, opts, plan, allocator); err != nil {
		write.out_drop(&fc.out)
		return nil, err
	}
	return write.out_finish(&fc.out)
}

// `marshal` into `sink`, through a buffer of `write.SINK_BYTES` from `allocator`. On a refusal or a failed sink the
// sink may hold a prefix of the item.
marshal_to :: proc(sink: io.Writer, value: ^$T, spec := Spec.Cbor, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> Write_Error {
	if sink.procedure == nil {
		return tape.Bad_Option{"sink"}
	}
	if err := check_marshal_opts(spec, opts); err != nil {
		return err
	}
	fc: Fast_Cbor
	if e := write.out_start(&fc.out, allocator, sink, 0); e != nil {
		return e
	}
	if err := marshal_out(&fc, value, T, spec, opts, plan, allocator); err != nil {
		write.out_drop(&fc.out)
		return err
	}
	_, err := write.out_finish(&fc.out)
	return err
}

@(private)
check_marshal_opts :: #force_inline proc "contextless" (spec: Spec, opts: Write_Options) -> Write_Error {
	if u8(spec) > u8(max(Spec)) {
		return tape.Bad_Option{"spec"}
	}
	if opts.format != nil || opts.indent != 0 || opts.tab || opts.ascii || opts.node != 0 || opts.framing != .None || opts.grow_header || len(opts.header) > 0 {
		opt := "format" if opts.format != nil else "header" if len(opts.header) > 0 || opts.grow_header else "options"
		return tape.Bad_Option{opt}
	}
	return nil
}

@(private)
Fast_Cbor :: struct {
	out: write.Out,
}

#assert(typed.CBOR_SLOP <= write.ROOM_MAX)

@(private)
marshal_out :: proc(fc: ^Fast_Cbor, value: rawptr, T: typeid, spec: Spec, opts: Write_Options, plan: ^Plan, allocator: runtime.Allocator) -> Write_Error {
	refusal: typed.Marshal_Refusal
	err: tape.Error
	switch {
	case spec == .Cbor && !opts.sort_keys:
		refusal, err = cbor_marshal_mode(fc, value, T, plan, true, .None, allocator)
	case spec == .Preferred && !opts.sort_keys:
		refusal, err = cbor_marshal_mode(fc, value, T, plan, false, .None, allocator)
	case spec == .Deterministic:
		refusal, err = cbor_marshal_mode(fc, value, T, plan, false, .Written, allocator)
	case spec == .Length_First:
		refusal, err = cbor_marshal_mode(fc, value, T, plan, false, .Length_First, allocator)
	case:
		refusal, err = cbor_marshal_mode(fc, value, T, plan, false, .Text, allocator)
	}
	if fc.out.err != nil {
		return fc.out.err
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
	return fc.out.err
}

@(private)
cbor_marshal_mode :: #force_no_inline proc(
	fc: ^Fast_Cbor,
	value: rawptr,
	T: typeid,
	plan: ^Plan,
	$INDEFINITE: bool,
	$KEY_ORDER: typed.Cbor_Key_Order,
	allocator: runtime.Allocator,
) -> (typed.Marshal_Refusal, tape.Error) {
	return typed.marshal_cbor(
		value, T, TAG, plan, fc, INDEFINITE, KEY_ORDER,
		cbor_buf_state, cbor_sync_cursor, cbor_grow, cbor_has_err,
		cbor_put_string_sync,
		allocator,
	)
}

@(private)
cbor_buf_state :: #force_inline proc "contextless" (fc: ^Fast_Cbor, slop: int) -> (buf, p, limit: [^]u8) #no_bounds_check {
	out := &fc.out
	return out.buf, out.buf[out.cursor:], out.buf[max(out.size - slop, 0):]
}

@(private)
cbor_sync_cursor :: #force_inline proc "contextless" (fc: ^Fast_Cbor, buf, p: [^]u8) {
	fc.out.cursor = int(intrinsics.ptr_sub(p, buf))
}

@(private, cold)
cbor_grow :: #force_no_inline proc(fc: ^Fast_Cbor, buf, p: [^]u8, need, slop: int) -> ([^]u8, [^]u8, [^]u8) #no_bounds_check {
	fc.out.cursor = int(intrinsics.ptr_sub(p, buf))
	q := write.room(&fc.out, need)
	out := &fc.out
	return out.buf, q, out.buf[max(out.size - slop, 0):]
}

@(private)
cbor_has_err :: #force_inline proc "contextless" (fc: ^Fast_Cbor) -> bool {
	return fc.out.err != nil
}

@(private)
cbor_put_string_sync :: #force_no_inline proc(fc: ^Fast_Cbor, buf, p: [^]u8, s: string, slop: int) -> ([^]u8, [^]u8, [^]u8, bool) #no_bounds_check {
	fc.out.cursor = int(intrinsics.ptr_sub(p, buf))
	if !kernel.utf8_valid(transmute([]u8)s) {
		return buf, p, buf, false
	}
	put_head(&fc.out, 3, u64(len(s)))
	write.put(&fc.out, transmute([]u8)s)
	out := &fc.out
	if out.size - out.cursor < slop && out.err == nil {
		_ = write.room(out, slop)
	}
	return out.buf, out.buf[out.cursor:], out.buf[max(out.size - slop, 0):], true
}
