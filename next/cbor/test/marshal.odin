package cbor_tests

import "base:runtime"
import "core:bytes"
import "core:math"
import "core:strings"
import "core:testing"
import "core:time"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:testkit"

// Direct CBOR typed marshal tests across `.Cbor`, `.Preferred`, `.Deterministic`, `.Length_First`, and `sort_keys`.

@(private = "file")
Wide_Enum :: enum u64 {
	Zero = 0,
	High = 1 << 63,
}

@(private = "file")
Wide_Bits :: bit_set[0 ..= 100; u128]

@(private = "file")
Choice :: union {
	i64,
	string,
	[2]f64,
}

@(private = "file")
Deep_Link :: struct {
	next: ^Deep_Link,
}

@(private = "file")
Cbor_Kitchen :: struct {
	z_str:                   string,
	a_empty:                 string,
	clean_thirty_two:        string,
	long_utf8:               string,
	long_field_key_name_over_thirty_two_bytes_long: i64,
	omit_str:                string `cbor:",omitempty"`,
	omit_opt:                Maybe(i64) `cbor:",omitunset"`,
	flag:                    bool,
	wide_b:                  b32,
	nums_i64:                []i64,
	nums_f64:                []f64,
	coords:                  [][2]f64,
	small_f32:               f32,
	bits:                    Wide_Bits,
	choice:                  Choice,
	ptr:                     ^i64,
	renamed:                 i64 `cbor:"r"`,
	hidden:                  i64 `cbor:"-"`,
	when_at:                 time.Time,
	m_str_i64:               map[string]i64,
	m_str_str:               map[string]string,
	m_int_str:               map[int]string,
	m_enum_str:              map[Wide_Enum]string,
	empty_rows:              []struct {
		only: string `cbor:",omitempty"`,
	},
}

// Large struct exceeding `CBOR_INLINE_META` (128) to exercise heap precomputation and OOM cleanup.
@(private = "file")
Many_Fields :: struct {
	f00, f01, f02, f03, f04, f05, f06, f07, f08, f09: i64,
	f10, f11, f12, f13, f14, f15, f16, f17, f18, f19: i64,
	f20, f21, f22, f23, f24, f25, f26, f27, f28, f29: i64,
	f30, f31, f32, f33, f34, f35, f36, f37, f38, f39: i64,
	f40, f41, f42, f43, f44, f45, f46, f47, f48, f49: i64,
	f50, f51, f52, f53, f54, f55, f56, f57, f58, f59: i64,
	f60, f61, f62, f63, f64, f65, f66, f67, f68, f69: string,
}

@(private = "file")
Fixed_Buf :: struct {
	bytes: []u8,
	used:  int,
}

@(private = "file")
fixed_buf_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, align: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	f := (^Fixed_Buf)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		a := max(align, 1)
		base := uintptr(raw_data(f.bytes))
		cur := base + uintptr(f.used)
		aligned := (cur + uintptr(a - 1)) &~ uintptr(a - 1)
		off := int(aligned - base)
		if off + size > len(f.bytes) {
			return nil, .Out_Of_Memory
		}
		f.used = off + size
		return f.bytes[off:off + size], nil
	case .Resize, .Resize_Non_Zeroed:
		a := max(align, 1)
		base := uintptr(raw_data(f.bytes))
		cur := base + uintptr(f.used)
		aligned := (cur + uintptr(a - 1)) &~ uintptr(a - 1)
		off := int(aligned - base)
		if off + size > len(f.bytes) {
			return nil, .Out_Of_Memory
		}
		if old != nil && old_size > 0 {
			runtime.mem_copy_non_overlapping(raw_data(f.bytes[off:]), old, min(old_size, size))
		}
		f.used = off + size
		return f.bytes[off:off + size], nil
	}
	return nil, nil
}

@(test)
cbor_marshal_specs_roundtrip_and_order :: proc(t: ^testing.T) {
	testkit.deadline(t)
	heap_alloc := context.allocator
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	ptr_v := i64(777)
	v := Cbor_Kitchen{
		z_str            = "hello",
		a_empty          = "",
		clean_thirty_two = "0123456789abcdef0123456789abcdef",
		long_utf8        = strings.concatenate({"café_東京_🚀_", strings.repeat("abc", 30)}),
		long_field_key_name_over_thirty_two_bytes_long = -9876543210,
		flag             = true,
		wide_b           = true,
		nums_i64         = {0, -1, 23, 24, -24, -25, 255, 256, max(i64), min(i64)},
		nums_f64         = {0.0, -0.0, 0.5, 1.5, 1.1, 100000.0, 5.960464477539063e-8, math.inf_f64(1), math.inf_f64(-1)},
		coords           = {{-1.5, 2.5}, {3.0, -4.0}},
		small_f32        = 5.960464477539063e-8,
		bits             = {0, 7, 64, 100},
		choice           = [2]f64{1.25, -2.5},
		ptr              = &ptr_v,
		renamed          = 123,
		hidden           = 999,
		when_at          = time.unix(1_700_000_000, 123_000_000),
		empty_rows       = {{}, {only = "ok"}, {}},
	}
	v.m_str_i64["zz"] = 1
	v.m_str_i64["a"] = -2
	v.m_str_str["bb"] = "val_b"
	v.m_str_str["c"] = "val_longer_than_thirty_two_bytes_here!"
	v.m_int_str[24] = "twenty_four"
	v.m_int_str[0] = "zero"
	v.m_int_str[-1] = "neg"
	v.m_enum_str[.Zero] = "z"
	v.m_enum_str[.High] = "h"

	plan, perr := cbor.plan_make(Cbor_Kitchen)
	testing.expectf(t, perr == nil, "plan: %v", perr)

	for spec in cbor.Spec {
		item, err := cbor.marshal(&v, spec, {}, &plan)
		testing.expectf(t, err == nil, "marshal %v: %v", spec, err)
		testing.expectf(t, cbor.validate(item, spec) == nil, "validate %v: %v", spec, cbor.validate(item, spec))

		back: Cbor_Kitchen
		uerr := cbor.unmarshal(item, &back, spec, {plan = &plan})
		testing.expectf(t, uerr == nil, "unmarshal %v: %v", spec, uerr)
		testing.expectf(t, back.z_str == v.z_str && back.a_empty == "" && back.clean_thirty_two == v.clean_thirty_two, "strings %v", spec)
		testing.expectf(t, back.long_utf8 == v.long_utf8 && back.long_field_key_name_over_thirty_two_bytes_long == -9876543210, "long %v", spec)
		testing.expectf(t, back.flag && bool(back.wide_b) && back.renamed == 123 && back.hidden == 0, "scalars %v", spec)
		testing.expectf(t, len(back.nums_i64) == len(v.nums_i64) && back.nums_i64[9] == min(i64), "i64 slice %v", spec)
		testing.expectf(t, len(back.nums_f64) == len(v.nums_f64) && math.sign_bit(back.nums_f64[1]) && back.small_f32 == v.small_f32, "floats %v", spec)
		testing.expectf(t, back.bits == v.bits && back.ptr != nil && back.ptr^ == 777 && time.diff(back.when_at, v.when_at) == 0, "bits/ptr/time %v", spec)
		testing.expectf(t, len(back.empty_rows) == 3 && back.empty_rows[0].only == "" && back.empty_rows[1].only == "ok", "empty structs %v", spec)
		testing.expectf(t, back.m_str_i64["a"] == -2 && back.m_int_str[24] == "twenty_four" && back.m_enum_str[.High] == "h", "maps %v", spec)

		sink: bytes.Buffer
		bytes.buffer_init_allocator(&sink, 0, 0, context.allocator)
		serr := cbor.marshal_to(bytes.buffer_to_stream(&sink), &v, spec, {}, &plan)
		testing.expectf(t, serr == nil && string(bytes.buffer_to_bytes(&sink)) == string(item), "marshal_to %v mismatch", spec)

		for limit in ([?]int{1, 7, 19}) {
			ch: testkit.Chunked
			defer testkit.chunked_destroy(&ch)
			cerr := cbor.marshal_to(testkit.chunked_sink(&ch, limit), &v, spec, {}, &plan)
			testing.expectf(t, cerr == nil && string(ch.taken[:]) == string(item), "chunked %v %d: %v", spec, limit, cerr)
		}
	}

	// `.Cbor` and `.Preferred` with `sort_keys = true` produce valid definite CBOR without temp_allocator calls.
	tf := testkit.Failing{backing = context.temp_allocator, fail_at = -1}
	saved_temp := context.temp_allocator
	context.temp_allocator = testkit.failing_allocator(&tf)
	defer context.temp_allocator = saved_temp

	fixed_backing := make([]u8, 256 * 1024, heap_alloc)
	defer delete(fixed_backing, heap_alloc)
	fb := Fixed_Buf{bytes = fixed_backing}
	fixed_alloc := runtime.Allocator{fixed_buf_proc, &fb}

	for spec in cbor.Spec {
		for sort_k in ([?]bool{false, true}) {
			fb.used = 0
			out, ferr := cbor.marshal(&v, spec, {sort_keys = sort_k}, &plan, fixed_alloc)
			testing.expectf(t, ferr == nil, "Fixed_Output %v sort=%v: %v", spec, sort_k, ferr)
			testing.expectf(t, cbor.validate(out, spec) == nil, "Fixed_Output validate %v sort=%v", spec, sort_k)
		}
	}
	fb.used = 0
	out_np, ferr_np := cbor.marshal(&v, .Preferred, {}, nil, fixed_alloc)
	testing.expectf(t, ferr_np == nil && cbor.validate(out_np, .Preferred) == nil, "Fixed_Output nil-plan Preferred: %v", ferr_np)
	testing.expect_value(t, tf.count, 0)
}

@(test)
cbor_marshal_order_edges_errors_and_oom :: proc(t: ^testing.T) {
	testkit.deadline(t)
	heap_alloc := context.allocator
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// Verify `.Deterministic` vs `.Length_First` key ordering on mixed struct/map keys.
	// Encoded CBOR key lengths: "a" -> 2 B (0x61,'a'); "bb" -> 3 B (0x62,'b','b'); "1234..." (>24B) -> head 2B + len.
	Mix :: struct {
		bb: int,
		a:  int,
		ccc_very_long_key_above_twenty_three_bytes: int,
	}
	mx := Mix{bb = 1, a = 2, ccc_very_long_key_above_twenty_three_bytes = 3}
	for spec in ([?]cbor.Spec{.Deterministic, .Length_First}) {
		out, err := cbor.marshal(&mx, spec)
		testing.expectf(t, err == nil && cbor.validate(out, spec) == nil, "Mix %v: %v", spec, err)
		testing.expect(t, len(out) > 4 && out[0] == 0xA3 && out[1] == 0x61 && out[2] == 'a')
	}

	// NaN normalizes to canonical half-float `f9 7e 00` across `.Preferred`, `.Deterministic`, `.Length_First`.
	nan_v := math.nan_f64()
	for spec in ([?]cbor.Spec{.Preferred, .Deterministic, .Length_First}) {
		nout, nerr := cbor.marshal(&nan_v, spec)
		testing.expectf(t, nerr == nil && len(nout) == 3 && nout[0] == 0xF9 && nout[1] == 0x7E && nout[2] == 0x00, "nan %v: %v % x", spec, nerr, nout)
		testing.expect_value(t, cbor.validate(nout, spec), nil)
	}

	// Invalid UTF-8 in value string or map key is refused as `.No_Spelling`.
	bad_bytes := [3]u8{'o', 'k', 0x80}
	bad_s := string(bad_bytes[:])
	for spec in cbor.Spec {
		_, berr := cbor.marshal(&bad_s, spec)
		r, rok := berr.(cbor.Refused)
		testing.expectf(t, rok && r.why == .No_Spelling, "bad utf8 val %v: %v", spec, berr)
	}
	bad_map := make(map[string]i64)
	bad_map[bad_s] = 1
	for spec in cbor.Spec {
		_, merr := cbor.marshal(&bad_map, spec)
		r, rok := merr.(cbor.Refused)
		testing.expectf(t, rok && r.why == .No_Spelling, "bad utf8 key %v: %v", spec, merr)
	}

	// Bad options and bad call arguments refused cleanly.
	good := i64(1)
	_, bad_opt1 := cbor.marshal(&good, .Cbor, {indent = 2})
	testing.expect(t, bad_opt1 != nil)
	_, bad_opt2 := cbor.marshal(&good, cbor.Spec(99))
	testing.expect(t, bad_opt2 != nil)
	_, bad_nil := cbor.marshal((^i64)(nil))
	testing.expect(t, bad_nil != nil)
	testing.expect(t, cbor.marshal_to({}, &good) != nil)

	other_plan, _ := cbor.plan_make(Mix)
	_, wrong_plan := cbor.marshal(&good, .Cbor, {}, &other_plan)
	testing.expect(t, wrong_plan != nil)

	// Depth past `tape.DEFAULT_DEPTH` (10,000) is refused as `.Malformed`.
	deep_head: Deep_Link
	cur := &deep_head
	for _ in 0 ..< tape.DEFAULT_DEPTH + 10 {
		cur.next = new(Deep_Link)
		cur = cur.next
	}
	_, derr := cbor.marshal(&deep_head, .Preferred)
	dr, dok := derr.(cbor.Refused)
	testing.expectf(t, dok && dr.why == .Malformed, "deep: %v", derr)

	// >64 field struct + OOM sweep across specs (tests heap fallback cleanup for krefs/spans/sidx).
	mf := Many_Fields{f00 = 1, f33 = 33, f69 = "end_longer_than_thirty_two_characters_to_hit_sync_path"}
	context.allocator = heap_alloc
	Cbor_Sweep :: struct {
		mf:   ^Many_Fields,
		spec: cbor.Spec,
		sort: bool,
	}
	sweep_cbor :: proc(data: rawptr, a: runtime.Allocator) {
		cs := (^Cbor_Sweep)(data)
		out, err := cbor.marshal(cs.mf, cs.spec, {sort_keys = cs.sort}, nil, a)
		if err == nil {
			delete(out, a)
		} else {
			_ = err.(runtime.Allocator_Error)
		}
	}
	for spec in ([?]cbor.Spec{.Cbor, .Preferred, .Deterministic, .Length_First}) {
		cs := Cbor_Sweep{&mf, spec, spec >= .Deterministic}
		sw := testkit.sweep_failures(sweep_cbor, &cs)
		testing.expectf(t, sw.bad == 0 && sw.refused >= 1, "cbor sweep %v: %v", spec, sw)
	}
}
