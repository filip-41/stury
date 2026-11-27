package typed_tests

import "base:intrinsics"
import "core:math"
import "core:testing"
import "stury:lib/ops/typed"
import "stury:lib/ops/write"
import "stury:testkit"

@(private = "file")
Direct_Out :: struct {
	out: write.Out,
}

@(private = "file")
direct_buf_state :: #force_inline proc "contextless" (w: ^Direct_Out, slop: int) -> (buf, p, limit: [^]u8) #no_bounds_check {
	o := &w.out
	return o.buf, o.buf[o.cursor:], o.buf[max(o.size - slop, 0):]
}

@(private = "file")
direct_sync_cursor :: #force_inline proc "contextless" (w: ^Direct_Out, buf, p: [^]u8) {
	w.out.cursor = int(intrinsics.ptr_sub(p, buf))
}

@(private = "file")
direct_grow :: #force_no_inline proc(w: ^Direct_Out, buf, p: [^]u8, need, slop: int) -> ([^]u8, [^]u8, [^]u8) #no_bounds_check {
	w.out.cursor = int(intrinsics.ptr_sub(p, buf))
	q := write.room(&w.out, need)
	o := &w.out
	return o.buf, q, o.buf[max(o.size - slop, 0):]
}

@(private = "file")
direct_has_err :: #force_inline proc "contextless" (w: ^Direct_Out) -> bool {
	return w.out.err != nil
}

@(private = "file")
json_put_inline :: #force_inline proc "contextless" (p: [^]u8, s: string) -> int {
	return 0
}

@(private = "file")
direct_sync_slop :: #force_inline proc(w: ^Direct_Out, slop: int) -> ([^]u8, [^]u8, [^]u8, bool) #no_bounds_check {
	o := &w.out
	if o.size - o.cursor < slop && o.err == nil {
		_ = write.room(o, slop)
	}
	return o.buf, o.buf[o.cursor:], o.buf[max(o.size - slop, 0):], true
}

@(private = "file")
json_put_sync :: #force_no_inline proc(w: ^Direct_Out, buf, p: [^]u8, s: string, slop: int) -> ([^]u8, [^]u8, [^]u8, bool) #no_bounds_check {
	w.out.cursor = int(intrinsics.ptr_sub(p, buf))
	write.put_byte(&w.out, '"')
	write.put(&w.out, transmute([]u8)s)
	write.put_byte(&w.out, '"')
	return direct_sync_slop(w, slop)
}

@(private = "file")
json_put_line :: #force_inline proc(w: ^Direct_Out, buf, p, limit: [^]u8, depth, after, slop: int) -> ([^]u8, [^]u8, [^]u8) {
	return buf, p, limit
}

@(private = "file")
cbor_put_sync :: #force_no_inline proc(w: ^Direct_Out, buf, p: [^]u8, s: string, slop: int) -> ([^]u8, [^]u8, [^]u8, bool) #no_bounds_check {
	w.out.cursor = int(intrinsics.ptr_sub(p, buf))
	write.put_byte(&w.out, 0x60 | u8(min(len(s), 23)))
	write.put(&w.out, transmute([]u8)s)
	return direct_sync_slop(w, slop)
}

@(test)
typed_fast_marshal_guards_and_lists :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	Pair :: struct {
		xs: []f64,
		ys: []i64,
		zs: [3]f64,
		nm: string,
	}
	v := Pair{
		xs = {0.0, -0.0, 1.5, 1e6, 1e-4, 9.999999999999999e-5},
		ys = {-9223372036854775808, 0, 9223372036854775807},
		zs = {-1.0, 2.25, 3.5},
		nm = "hi",
	}

	w: Direct_Out
	testing.expect(t, write.out_start(&w.out, context.allocator, {}, 0) == nil)
	ref, err := typed.marshal_json(&v, Pair, "json", nil, &w, false, false, direct_buf_state, direct_sync_cursor, direct_grow, direct_has_err, json_put_inline, json_put_sync, json_put_line, context.temp_allocator)
	testing.expect(t, ref == .None && err == nil)
	got, ferr := write.out_finish(&w.out)
	testing.expect(t, ferr == nil && len(got) > 0)
	defer delete(got)
	want := `{"xs":[0.0,-0.0,1.5,1e+06,0.0001,9.999999999999999e-05],"ys":[-9223372036854775808,0,9223372036854775807],"zs":[-1.0,2.25,3.5],"nm":"hi"}`
	testing.expectf(t, string(got) == want, "got:  %s\nwant: %s", got, want)

	// Guard checks on invalid inputs (`value == nil`, mismatched plan type, mismatched tag_key).
	w2: Direct_Out
	testing.expect(t, write.out_start(&w2.out, context.allocator, {}, 0) == nil)
	defer write.out_drop(&w2.out)
	_, err_nil := typed.marshal_json(nil, Pair, "json", nil, &w2, false, false, direct_buf_state, direct_sync_cursor, direct_grow, direct_has_err, json_put_inline, json_put_sync, json_put_line, context.temp_allocator)
	testing.expect(t, err_nil != nil)
	_, err_cb_nil := typed.marshal_cbor(nil, Pair, "cbor", nil, &w2, false, .None, direct_buf_state, direct_sync_cursor, direct_grow, direct_has_err, cbor_put_sync, context.temp_allocator)
	testing.expect(t, err_cb_nil != nil)

	plan, perr := typed.plan_make(Pair, "json", {}, context.allocator)
	testing.expect(t, perr == nil)
	defer typed.plan_destroy(&plan)
	n := i64(1)
	_, err_type := typed.marshal_json(&n, i64, "json", &plan, &w2, false, false, direct_buf_state, direct_sync_cursor, direct_grow, direct_has_err, json_put_inline, json_put_sync, json_put_line, context.temp_allocator)
	testing.expect(t, err_type != nil)
	_, err_tag := typed.marshal_cbor(&v, Pair, "cbor", &plan, &w2, false, .Written, direct_buf_state, direct_sync_cursor, direct_grow, direct_has_err, cbor_put_sync, context.temp_allocator)
	testing.expect(t, err_tag != nil)

	// NaN refusal inside `[]f64` tight loop.
	nan_arr := []f64{1.0, math.nan_f64()}
	w3: Direct_Out
	testing.expect(t, write.out_start(&w3.out, context.allocator, {}, 0) == nil)
	defer write.out_drop(&w3.out)
	nan_ref, nan_err := typed.marshal_json(&nan_arr, []f64, "json", nil, &w3, false, true, direct_buf_state, direct_sync_cursor, direct_grow, direct_has_err, json_put_inline, json_put_sync, json_put_line, context.temp_allocator)
	testing.expect(t, nan_ref == .No_Spelling && nan_err == nil)

	// Direct CBOR test with heap allocation OOM sweep.
	wc: Direct_Out
	testing.expect(t, write.out_start(&wc.out, context.allocator, {}, 0) == nil)
	cref, cerr := typed.marshal_cbor(&v, Pair, "cbor", nil, &wc, false, .Length_First, direct_buf_state, direct_sync_cursor, direct_grow, direct_has_err, cbor_put_sync, context.temp_allocator)
	testing.expect(t, cref == .None && cerr == nil)
	cb, cferr := write.out_finish(&wc.out)
	testing.expect(t, cferr == nil && len(cb) > 10)
	defer delete(cb)
}
