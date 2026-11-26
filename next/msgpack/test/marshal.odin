package msgpack_tests

import "base:runtime"
import "core:bytes"
import "core:math"
import "core:strings"
import "core:testing"
import "core:time"
import "stury:lib/core/tape"
import "stury:msgpack"
import "stury:testkit"

// Typed `msgpack.marshal`, `marshal_to`, `plan_make`, `unmarshal`, and `msgpack.Raw` tests.

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
Kitchen :: struct {
	z_str:       string,
	a_empty:     string,
	long_utf8:   string,
	omit_str:    string `msgpack:",omitempty"`,
	omit_opt:    Maybe(i64) `msgpack:",omitunset"`,
	flag:        bool,
	nums_i64:    []i64,
	nums_f64:    []f64,
	coords:      [][2]f64,
	small_f32:   f32,
	bits:        Wide_Bits,
	choice:      Choice,
	ptr:         ^i64,
	renamed:     i64 `msgpack:"r"`,
	shared_name: i64 `stury:"shared"`,
	hidden:      i64 `msgpack:"-"`,
	when_at:     time.Time,
	m_str_i64:   map[string]i64,
	m_int_str:   map[int]string,
	m_enum_str:  map[Wide_Enum]string,
}

@(test)
msgpack_marshal_roundtrip_sort_keys_and_sinks :: proc(t: ^testing.T) {
	testkit.deadline(t)
	heap_alloc := context.allocator
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	ptr_v := i64(777)
	v := Kitchen {
		z_str       = "hello",
		a_empty     = "",
		long_utf8   = strings.concatenate({"café_東京_🚀_", strings.repeat("abc", 20)}),
		flag        = true,
		nums_i64    = {0, -1, -32, -33, 127, 128, 255, 256, max(i64), min(i64)},
		nums_f64    = {0.0, -0.0, 0.5, 1.5, 1.1, 100000.0, math.inf_f64(1), math.inf_f64(-1)},
		coords      = {{-1.5, 2.5}, {3.0, -4.0}},
		small_f32   = 1.25,
		bits        = {0, 7, 64, 100},
		choice      = [2]f64{1.25, -2.5},
		ptr         = &ptr_v,
		renamed     = 123,
		shared_name = 456,
		hidden      = 999,
		when_at     = time.unix(1_700_000_000, 123_000_000),
	}
	v.m_str_i64["zz"] = 1
	v.m_str_i64["a"] = -2
	v.m_int_str[256] = "two_five_six"
	v.m_int_str[-1] = "neg"
	v.m_enum_str[.Zero] = "z"
	v.m_enum_str[.High] = "h"

	plan, perr := msgpack.plan_make(Kitchen)
	testing.expectf(t, perr == nil, "plan: %v", perr)
	defer msgpack.plan_destroy(&plan)

	for spec in msgpack.Spec {
		for sort_k in ([?]bool{false, true}) {
			item, err := msgpack.marshal(&v, spec, {sort_keys = sort_k}, &plan)
			testing.expectf(t, err == nil, "marshal %v sort=%v: %v", spec, sort_k, err)
			testing.expectf(t, msgpack.validate(item, spec) == nil, "validate %v sort=%v: %v", spec, sort_k, msgpack.validate(item, spec))

			back: Kitchen
			uerr := msgpack.unmarshal(item, &back, spec, {plan = &plan})
			testing.expectf(t, uerr == nil, "unmarshal %v: %v", spec, uerr)
			testing.expectf(t, back.z_str == v.z_str && back.a_empty == "" && back.long_utf8 == v.long_utf8, "strings %v", spec)
			testing.expectf(t, back.flag && back.renamed == 123 && back.shared_name == 456 && back.hidden == 0, "scalars %v", spec)
			testing.expectf(t, len(back.nums_i64) == len(v.nums_i64) && back.nums_i64[9] == min(i64), "i64 %v", spec)
			testing.expectf(t, len(back.nums_f64) == len(v.nums_f64) && math.sign_bit(back.nums_f64[1]) && back.small_f32 == v.small_f32, "floats %v", spec)
			testing.expectf(t, back.bits == v.bits && back.ptr != nil && back.ptr^ == 777 && time.diff(back.when_at, v.when_at) == 0, "bits/ptr/time %v", spec)
			testing.expectf(t, back.m_str_i64["a"] == -2 && back.m_int_str[256] == "two_five_six" && back.m_enum_str[.High] == "h", "maps %v", spec)

			sink: bytes.Buffer
			bytes.buffer_init_allocator(&sink, 0, 0, heap_alloc)
			defer bytes.buffer_destroy(&sink)
			serr := msgpack.marshal_to(bytes.buffer_to_stream(&sink), &v, spec, {sort_keys = sort_k}, &plan)
			testing.expectf(t, serr == nil && bytes.equal(bytes.buffer_to_bytes(&sink), item), "marshal_to %v mismatch", spec)
		}
	}
}

@(test)
msgpack_marshal_errors_deep_and_oom :: proc(t: ^testing.T) {
	testkit.deadline(t)
	heap_alloc := context.allocator
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// Invalid UTF-8 refused as `.No_Spelling`
	bad_bytes := [3]u8{'o', 'k', 0x80}
	bad_s := string(bad_bytes[:])
	_, berr := msgpack.marshal(&bad_s)
	r, rok := berr.(msgpack.Refused)
	testing.expectf(t, rok && r.why == .No_Spelling, "bad utf8: %v", berr)

	// Invalid spec / options / nil value / empty sink
	good := i64(1)
	_, bad_opt := msgpack.marshal(&good, .Msgpack, {indent = 2})
	testing.expect(t, bad_opt != nil)
	_, bad_spec := msgpack.marshal(&good, msgpack.Spec(99))
	testing.expect(t, bad_spec != nil)
	_, bad_nil := msgpack.marshal((^i64)(nil))
	testing.expect(t, bad_nil != nil)
	testing.expect(t, msgpack.marshal_to({}, &good) != nil)

	other_plan, _ := msgpack.plan_make(Kitchen)
	defer msgpack.plan_destroy(&other_plan)
	_, wrong_plan := msgpack.marshal(&good, .Msgpack, {}, &other_plan)
	testing.expect(t, wrong_plan != nil)

	// Deep nesting past DEFAULT_DEPTH refused without stack overflow
	deep_head: Deep_Link
	cur := &deep_head
	for _ in 0 ..< tape.DEFAULT_DEPTH + 10 {
		cur.next = new(Deep_Link)
		cur = cur.next
	}
	_, derr := msgpack.marshal(&deep_head, .Compact)
	dr, dok := derr.(msgpack.Refused)
	testing.expectf(t, dok && dr.why == .Malformed, "deep: %v", derr)

	// `msgpack.Raw` typed read preserves raw bytes and rejects malformed inner items
	Raw_Holder :: struct {
		raw: msgpack.Raw,
	}
	rsrc := hex("81 a3 726177 92 01 d6 ff 514b67b0")
	rh: Raw_Holder
	testing.expect_value(t, msgpack.unmarshal(rsrc, &rh, allocator = context.temp_allocator), nil)
	testing.expect_value(t, string(rh.raw), string(hex("92 01 d6 ff 514b67b0")))

	bad_raw := hex("81 a3 726177 c1")
	rh_bad: Raw_Holder
	testing.expect(t, msgpack.unmarshal(bad_raw, &rh_bad, allocator = context.temp_allocator) != nil)

	// OOM sweep across marshal (with flat struct when `plan == nil` and with precompiled plan on `Kitchen`)
	context.allocator = heap_alloc
	Flat_Record :: struct {
		a, b, c, d, e, f, g, h: i64,
		name:                   string,
	}
	fr := Flat_Record{a = 1, b = -2, c = 300, name = "ok"}
	Sweep_Flat :: struct {
		v: ^Flat_Record,
	}
	run_marshal_flat :: proc(data: rawptr, a: runtime.Allocator) {
		s := (^Sweep_Flat)(data)
		out, err := msgpack.marshal(s.v, .Compact, {sort_keys = true}, nil, a)
		if err == nil {
			delete(out, a)
		} else {
			_ = err.(runtime.Allocator_Error)
		}
	}
	sw := testkit.sweep_failures(run_marshal_flat, &Sweep_Flat{&fr})
	testing.expectf(t, sw.bad == 0 && sw.refused >= 1, "marshal flat OOM sweep: %v", sw)

	kplan, _ := msgpack.plan_make(Kitchen, {}, heap_alloc)
	defer msgpack.plan_destroy(&kplan)
	kv := Kitchen{z_str = "abc", nums_i64 = {1, 2, 3}}
	Sweep_Kit :: struct {
		v:    ^Kitchen,
		plan: ^msgpack.Plan,
	}
	run_marshal_kit :: proc(data: rawptr, a: runtime.Allocator) {
		s := (^Sweep_Kit)(data)
		out, err := msgpack.marshal(s.v, .Compact, {sort_keys = true}, s.plan, a)
		if err == nil {
			delete(out, a)
		} else {
			_ = err.(runtime.Allocator_Error)
		}
	}
	swk := testkit.sweep_failures(run_marshal_kit, &Sweep_Kit{&kv, &kplan})
	testing.expectf(t, swk.bad == 0 && swk.refused >= 1, "marshal Kitchen OOM sweep: %v", swk)
}
