package json_tests

import "base:runtime"
import "core:bytes"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:testkit"

// The typed write: a value written by its type's plan reads back as the value, through each option of the plan.

@(private = "file")
Mode :: enum u8 {
	Off,
	On,
	Auto = 5,
}

@(private = "file")
Flags :: bit_set[Mode]

@(private = "file")
Inner :: struct {
	a: int,
	b: string,
}

@(private = "file")
Either :: union {
	int,
	string,
}

@(private = "file")
Kitchen :: struct {
	name:    string,
	count:   i32,
	big:     u64,
	neg:     i8,
	ratio:   f64,
	small:   f32,
	ok:      bool,
	mode:    Mode,
	flags:   Flags,
	list:    []int,
	dyn:     [dynamic]string,
	fixed:   [3]u8,
	inner:   Inner,
	ptr:     ^Inner,
	maybe:   Maybe(int),
	either:  Either,
	table:   map[string]int,
	by_int:  map[int]bool,
	by_mode: map[Mode]string,
	renamed: int `json:"other"`,
	hidden:  int `json:"-"`,
	empty:   string `json:",omitempty"`,
	unset:   Maybe(int) `json:",omitunset"`,
	at:      time.Time,
	nested:  [][]Inner,
}

@(private = "file")
Chain :: struct {
	next: ^Chain,
}

@(private = "file")
marshal_text :: proc(t: ^testing.T, value: ^$T, opts := json.Write_Options{}, plan: ^json.Plan = nil) -> (text: string, ok: bool) {
	bytes, err := json.marshal(value, opts, plan, context.temp_allocator)
	testing.expectf(t, err == nil, "marshal: %v", err)
	return string(bytes), err == nil
}

@(test)
a_marshalled_value_reads_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	context.allocator = context.temp_allocator
	extra := Inner{7, "x\ny"}
	k := Kitchen{
		name = "kitchen \"sink\"", count = -5, big = max(u64), neg = -128, ratio = 0.1, small = 1.5, ok = true, mode = .Auto, flags = {.Off, .Auto},
		list = []int{1, 2, 3}, fixed = {9, 8, 7}, inner = {1, "in"}, ptr = &extra, maybe = 4, either = "s", renamed = 11, hidden = 99,
		at = time.unix(1_700_000_000, 5_000_000), nested = [][]Inner{{{1, "a"}}, {}},
	}
	append(&k.dyn, "p", "q")
	k.table["one"], k.table["two"] = 1, 2
	k.by_int[-3], k.by_int[40] = true, false
	k.by_mode[.On], k.by_mode[.Auto] = "on", "auto"
	plan, perr := json.plan_make(Kitchen)
	testing.expectf(t, perr == nil, "%v", perr)
	for opts in ([?]json.Write_Options{{}, {indent = 2}, {tab = true}, {ascii = true}}) {
		text, ok := marshal_text(t, &k, opts, &plan)
		if !ok {
			return
		}
		back: Kitchen
		err := json.unmarshal(transmute([]u8)text, &back, .Json, {plan = &plan})
		testing.expectf(t, err == nil, "%v: %s", err, text)
		testing.expectf(t, back.name == k.name && back.count == k.count && back.big == k.big && back.neg == k.neg && back.ratio == k.ratio && back.small == k.small, "scalars: %s", text)
		testing.expectf(t, back.ok && back.mode == .Auto && back.flags == k.flags && back.fixed == k.fixed && back.inner == k.inner && back.renamed == 11, "values: %s", text)
		testing.expectf(t, back.hidden == 0 && back.ptr != nil && back.ptr^ == extra && back.maybe == 4 && back.either == "s", "wrappers: %s", text)
		testing.expectf(t, len(back.list) == 3 && back.list[2] == 3 && len(back.dyn) == 2 && back.dyn[1] == "q" && len(back.nested) == 2 && len(back.nested[1]) == 0, "lists: %s", text)
		testing.expectf(t, back.table["two"] == 2 && back.by_int[-3] && !back.by_int[40] && back.by_mode[.On] == "on" && len(back.by_mode) == 2, "maps: %s", text)
		testing.expectf(t, time.diff(back.at, k.at) == 0, "time: %s", text)
		again, _ := marshal_text(t, &back, opts, &plan)
		testing.expectf(t, len(again) == len(text), "a second write differs in length:\n%s\n%s", text, again)
	}
	text, _ := marshal_text(t, &k)
	testing.expectf(t, !contains(text, `"hidden"`) && !contains(text, `"empty"`) && !contains(text, `"unset"`) && contains(text, `"other":11`), "tags: %s", text)
	testing.expectf(t, contains(text, `"flags":["Off","Auto"]`) && contains(text, `"mode":"Auto"`) && contains(text, `"by_int":{`), "enums: %s", text)
}

@(private = "file")
contains :: proc(s, sub: string) -> bool {
	for i in 0 ..= len(s) - len(sub) {
		if s[i:][:len(sub)] == sub {
			return true
		}
	}
	return false
}

@(test)
enums_by_value_read_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	context.allocator = context.temp_allocator
	plan, perr := json.plan_make(Mode, {enums = .Int})
	testing.expect(t, perr == nil)
	mode := Mode.Auto
	text, _ := marshal_text(t, &mode, {}, &plan)
	testing.expect_value(t, text, "5")
	back: Mode
	err := json.unmarshal(transmute([]u8)text, &back, .Json, {plan = &plan})
	testing.expect(t, err == nil && back == .Auto)
}

@(test)
a_marshalled_chain_nests_without_recursion :: proc(t: ^testing.T) {
	testkit.deadline(t)
	context.allocator = context.temp_allocator
	head: Chain
	at := &head
	for _ in 0 ..< 4000 {
		at.next = new(Chain)
		at = at.next
	}
	text, ok := marshal_text(t, &head)
	if !ok {
		return
	}
	testing.expect_value(t, len(text), 4001 * len(`{"next":`) + len("null") + 4001)
	deep: Chain
	at = &deep
	for _ in 0 ..< 20000 {
		at.next = new(Chain)
		at = at.next
	}
	_, err := json.marshal(&deep, {}, nil, context.temp_allocator)
	refused, is_refused := err.(write.Refused)
	testing.expectf(t, is_refused && refused.why == .Malformed, "past the depth: %v", err)
}

@(test)
a_value_with_no_json_spelling_is_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	nan := math.nan_f64()
	_, err := json.marshal(&nan, {}, nil, context.temp_allocator)
	refused, ok := err.(write.Refused)
	testing.expectf(t, ok && refused.why == .No_Spelling, "%v", err)
	raw: struct {
		r: json.Raw,
	}
	_, err = json.marshal(&raw, {}, nil, context.temp_allocator)
	bad, is_bad := err.(tape.Bad_Option)
	testing.expectf(t, is_bad && bad.option == "raw", "%v", err)
}

@(private = "file")
High_Enum :: enum u64 {
	Low  = 1,
	High = 1 << 63,
}

@(private = "file")
Wide_Bits :: bit_set[0 ..= 127; u128]

@(private = "file")
Arr_Omit :: struct {
	zeros:   [3]int `json:",omitempty"`,
	nonzero: [3]int `json:",omitempty"`,
}

@(test)
marshal_edge_cases_plan_array_bits_enum_negzero :: proc(t: ^testing.T) {
	testkit.deadline(t)
	context.allocator = context.temp_allocator

	// 1. Mismatched or zero Plan is refused with Bad_Option{"plan"}.
	a := Inner{1, "x"}
	wrong_plan, perr := json.plan_make(Kitchen)
	testing.expect(t, perr == nil)
	_, err := json.marshal(&a, {}, &wrong_plan)
	testing.expect_value(t, err, json.Write_Error(json.Bad_Option{"plan"}))
	zero_plan: json.Plan
	_, err = json.marshal(&a, {}, &zero_plan)
	testing.expect_value(t, err, json.Write_Error(json.Bad_Option{"plan"}))

	// 2. Fixed array `omitempty` inspects ALL elements, not just element 0.
	ao := Arr_Omit{zeros = {0, 0, 0}, nonzero = {0, 1, 0}}
	atext, ok := marshal_text(t, &ao)
	testing.expectf(t, ok && atext == `{"nonzero":[0,1,0]}`, "array omitempty: %s", atext)

	// 3. 128-bit `bit_set` marshals and unmarshals bits past 63.
	wb := Wide_Bits{0, 63, 64, 127}
	wtext, wok := marshal_text(t, &wb)
	testing.expectf(t, wok && wtext == `[0,63,64,127]`, "128-bit bit_set: %s", wtext)
	wb_back: Wide_Bits
	testing.expect(t, json.unmarshal(transmute([]u8)wtext, &wb_back) == nil && wb_back == wb)

	// 4. Unsigned u64 enum >= 2^63 with `.Int` marshals as unsigned, not negative.
	eplan, eerr := json.plan_make(High_Enum, {enums = .Int})
	testing.expect(t, eerr == nil)
	he := High_Enum.High
	htext, hok := marshal_text(t, &he, {}, &eplan)
	testing.expectf(t, hok && htext == "9223372036854775808", "u64 enum: %s", htext)

	// 5. `-0.0` preserves its sign bit and `.0`.
	nz := -0.0
	nztext, nzok := marshal_text(t, &nz)
	testing.expectf(t, nzok && nztext == "-0.0", "neg zero: %s", nztext)
	nz_back: f64
	testing.expect(t, json.unmarshal(transmute([]u8)nztext, &nz_back) == nil && math.sign_bit(nz_back))
}

@(test)
marshal_utf8_escapes_floats_and_framing :: proc(t: ^testing.T) {
	testkit.deadline(t)
	heap_alloc := context.allocator
	context.allocator = context.temp_allocator

	// Invalid UTF-8 refused across short (<16B), mid (16..4000B with clean prefix), long (>4096B), map keys, and struct keys.
	bad_strings := [?]string{
		"\xff",
		"abc\x80def",
		"0123456789abcdef\xff",
		"0123456789abcdef0123456789abcdef\xc3\x28",
		strings.concatenate({strings.repeat("a", 5000), "\xff"}),
	}
	for s in bad_strings {
		val := s
		for opts in ([?]json.Write_Options{{}, {ascii = true}}) {
			_, err := json.marshal(&val, opts)
			r, ok := err.(write.Refused)
			testing.expectf(t, ok && r.why == .No_Spelling, "bad utf8 len=%d opts=%v: %v", len(s), opts, err)
		}
	}
	bad_flat_map: map[string]i64
	bad_flat_map["ok_key_12345"] = 1
	bad_flat_map["bad\xffkey"] = 2
	_, fmerr := json.marshal(&bad_flat_map)
	fmr, fmok := fmerr.(write.Refused)
	testing.expectf(t, fmok && fmr.why == .No_Spelling, "flat map bad utf8 key: %v", fmerr)

	bad_str_map: map[string]string
	bad_str_map["ok"] = "0123456789abcdef\xfe"
	_, smerr := json.marshal(&bad_str_map)
	smr, smok := smerr.(write.Refused)
	testing.expectf(t, smok && smr.why == .No_Spelling, "str map bad utf8 val: %v", smerr)

	// Valid strings with escapes, control chars, DEL (0x7f), 2/3/4-byte UTF-8 across short, mid, and long lengths.
	Tricky_Strings :: struct {
		empty:                      string,
		short_esc:                  string,
		short_utf8:                 string,
		mid_clean_then_esc:         string,
		mid_utf8_astral:            string,
		long_with_utf8_and_escapes: string,
		del_char:                   string,
		very_long_field_name_over_16_bytes: i64,
		escaped_key:                i64 `json:"a\"b\nc"`,
		utf8_key:                   i64 `json:"café"`,
	}
	ts := Tricky_Strings{
		empty                      = "",
		short_esc                  = "a\"b\\c\n\t\x01",
		short_utf8                 = "é日😀",
		mid_clean_then_esc         = "0123456789abcdef0123456789\"\\\r\n\x00\x1f",
		mid_utf8_astral            = "prefix_0123456789_café_東京_🚀🎉_end",
		long_with_utf8_and_escapes = strings.concatenate({strings.repeat("x", 4200), "\"\n", "é😀", strings.repeat("y", 100)}),
		del_char                   = "before\x7fafter",
		very_long_field_name_over_16_bytes = 9_223_372_036_854_775_807,
		escaped_key                = -9_223_372_036_854_775_808,
		utf8_key                   = 42,
	}
	for opts in ([?]json.Write_Options{{}, {indent = 2}, {tab = true}, {ascii = true}, {indent = 2, ascii = true}}) {
		text, ok := marshal_text(t, &ts, opts)
		if !ok {
			return
		}
		// Must round-trip identically through json.unmarshal AND match json.write of the parsed document.
		back: Tricky_Strings
		uerr := json.unmarshal(transmute([]u8)text, &back)
		testing.expectf(t, uerr == nil && back == ts, "roundtrip opts=%v err=%v", opts, uerr)
		doc, berr := json.build(transmute([]u8)text)
		testing.expectf(t, berr == nil, "build opts=%v: %v", opts, berr)
		doc_text, _, werr := json.write(&doc, .Json, opts)
		testing.expectf(t, werr == nil && string(doc_text) == text, "write match opts=%v: werr=%v", opts, werr)
		json.destroy(&doc)
	}

	// Float formatting matches `strconv.write_float(..., 'g', -1, 64, {})` + `.0` across fast-path boundaries.
	floats := [?]f64{
		0.0, -0.0, 0.001, -0.001, 0.0001, 0.00009, 0.1, 0.2, 0.29, 0.3, 1.0, -1.0,
		190.476, 414.941, 456.867, 999999.999, 999999.9999, 1000000.0, -65.61361699999998,
		1e-5, 1e20, math.F64_MAX, math.F64_MIN,
	}
	for fv in floats {
		v := fv
		got, ok := marshal_text(t, &v)
		if !ok {
			continue
		}
		buf: [64]u8
		raw := strconv.write_float(buf[:62], fv, 'g', -1, 64, {})
		has_dot := false
		for c in transmute([]u8)raw {
			if c == '.' || c == 'e' || c == 'E' {
				has_dot = true
				break
			}
		}
		want := raw
		if !has_dot {
			buf[len(raw)], buf[len(raw) + 1] = '.', '0'
			want = string(buf[:len(raw) + 2])
		}
		testing.expectf(t, got == want, "float %v: got %q, want %q", fv, got, want)
	}
	for bad_f in ([?]f64{math.nan_f64(), math.inf_f64(1), math.inf_f64(-1)}) {
		v := bad_f
		_, err := json.marshal(&v)
		r, ok := err.(write.Refused)
		testing.expectf(t, ok && r.why == .No_Spelling, "non-finite f64 %v: %v", bad_f, err)
	}
	bad_f32 := f32(math.inf_f32(-1))
	_, f32err := json.marshal(&bad_f32)
	f32r, f32ok := f32err.(write.Refused)
	testing.expectf(t, f32ok && f32r.why == .No_Spelling, "non-finite f32: %v", f32err)

	// Framing (.Lines, .Seq) and marshal_to sink.
	item := Inner{7, "hi"}
	for framing in ([?]write.Record_Framing{.None, .Lines, .Seq}) {
		got, ok := marshal_text(t, &item, {framing = framing})
		if !ok {
			continue
		}
		want := `{"a":7,"b":"hi"}` if framing == .None else "{\"a\":7,\"b\":\"hi\"}\n" if framing == .Lines else "\x1e{\"a\":7,\"b\":\"hi\"}\n"
		testing.expectf(t, got == want, "framing %v: got %q, want %q", framing, got, want)
		sink: bytes.Buffer
		bytes.buffer_init_allocator(&sink, 0, 0, context.allocator)
		serr := json.marshal_to(bytes.buffer_to_stream(&sink), &item, {framing = framing})
		testing.expectf(t, serr == nil && bytes.buffer_to_string(&sink) == want, "marshal_to %v: %v %q", framing, serr, bytes.buffer_to_string(&sink))
	}

	// Deep pretty indent (> 1024 spaces) exercises `fast_put_line_long`.
	deep_head: Chain
	at := &deep_head
	for _ in 0 ..< 600 {
		at.next = new(Chain)
		at = at.next
	}
	deep_pretty, dpok := marshal_text(t, &deep_head, {indent = 2})
	if dpok {
		doc, berr := json.build(transmute([]u8)deep_pretty)
		testing.expectf(t, berr == nil, "deep pretty build: %v", berr)
		json.destroy(&doc)
	}

	// Failing allocator sweep: zero leaks and zero context.temp_allocator usage.
	context.allocator = heap_alloc
	Sweep_Data :: struct {
		k:    ^Tricky_Strings,
		opts: json.Write_Options,
	}
	sweep_marshal :: proc(data: rawptr, a: runtime.Allocator) {
		d := (^Sweep_Data)(data)
		out, err := json.marshal(d.k, d.opts, nil, a)
		if err == nil {
			delete(out, a)
		} else {
			_ = err.(runtime.Allocator_Error)
		}
	}
	for opts in ([?]json.Write_Options{{}, {indent = 2}, {ascii = true}}) {
		sd := Sweep_Data{&ts, opts}
		s := testkit.sweep_failures(sweep_marshal, &sd)
		testing.expectf(t, s.bad == 0 && s.refused >= 1, "marshal sweep %v: %v", opts, s)
	}
	// Verify zero context.temp_allocator usage on marshal.
	tf := testkit.Failing{backing = context.temp_allocator, fail_at = -1}
	saved_temp := context.temp_allocator
	context.temp_allocator = testkit.failing_allocator(&tf)
	defer context.temp_allocator = saved_temp
	for opts in ([?]json.Write_Options{{}, {indent = 2}, {tab = true}, {ascii = true}}) {
		out, merr := json.marshal(&ts, opts, nil, heap_alloc)
		testing.expectf(t, merr == nil, "no-temp marshal %v: %v", opts, merr)
		delete(out, heap_alloc)
	}
	testing.expect_value(t, tf.count, 0)
}

@(test)
marshal_sort_keys_fast_paths_and_edges :: proc(t: ^testing.T) {
	testkit.deadline(t)
	heap_alloc := context.allocator
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	Big_Enum :: enum u64 {
		Low  = 1,
		High = 1 << 63,
	}
	Sorted_Inner :: struct {
		zeta:  []f64,
		alpha: [3]i64,
		beta:  string `json:",omitempty"`,
	}
	Sorted_Doc :: struct {
		z_field:                    i64,
		a_field:                    string,
		m_thirty_two_byte_key_name_:  [2]f64,
		b_inner:                    Sorted_Inner,
		empty_all:                  struct {
			x: string `json:",omitempty"`,
			y: Maybe(int) `json:",omitunset"`,
		},
		nested_empty:               []struct {
			k: string `json:",omitempty"`,
		},
		dict_str:                   map[string]string,
		dict_int:                   map[int]string,
		dict_enum:                  map[Big_Enum]i64,
	}

	sd := Sorted_Doc{
		z_field = -42,
		a_field = "0123456789abcdef0123456789abcdef", // exact 32 B clean ASCII
		m_thirty_two_byte_key_name_ = {-123.5, 45.0},
		b_inner = {zeta = {1e-5, 0.25, -0.0, 999999.9999}, alpha = {10, -20, 30}},
		nested_empty = {{}, {k = "live"}, {}},
	}
	sd.dict_str["b"] = "é"
	sd.dict_str["aa"] = "clean_string_over_thirty_two_bytes_long!"
	sd.dict_str["a"] = "x\"y\\z\n"
	sd.dict_int[10] = "ten"
	sd.dict_int[2] = "two"
	sd.dict_int[-1] = "neg"
	sd.dict_enum[.High] = 99
	sd.dict_enum[.Low] = 1

	for opts in ([?]json.Write_Options{
		{sort_keys = true},
		{sort_keys = true, indent = 2},
		{sort_keys = true, tab = true},
		{sort_keys = true, ascii = true},
		{sort_keys = true, indent = 2, ascii = true},
	}) {
		text, ok := marshal_text(t, &sd, opts)
		if !ok {
			continue
		}
		back: Sorted_Doc
		uerr := json.unmarshal(transmute([]u8)text, &back)
		testing.expectf(t, uerr == nil, "sort_keys unmarshal %v: %v\n%s", opts, uerr, text)
		testing.expectf(t, back.z_field == -42 && back.a_field == sd.a_field && len(back.b_inner.zeta) == 4, "sort_keys roundtrip %v", opts)
		testing.expectf(t, back.dict_str["aa"] == sd.dict_str["aa"] && back.dict_enum[.High] == 99 && back.dict_int[2] == "two", "sort_keys maps %v", opts)

		doc, berr := json.build(transmute([]u8)text)
		testing.expectf(t, berr == nil, "sort_keys build %v: %v", opts, berr)
		doc_text, _, werr := json.write(&doc, .Json, opts)
		testing.expectf(t, werr == nil && string(doc_text) == text, "sort_keys matches json.write %v: %v\ngot:  %s\nwant: %s", opts, werr, text, doc_text)
		json.destroy(&doc)
	}

	// `[]f64` and `[]i64` tight loops: empty, mixed, pretty, and NaN refusal mid-slice.
	empty_floats := []f64{}
	ef_text, ef_ok := marshal_text(t, &empty_floats, {indent = 2})
	testing.expect(t, ef_ok && ef_text == "[]")

	bad_slice := []f64{1.0, 2.5, math.nan_f64(), 3.0}
	_, bserr := json.marshal(&bad_slice, {indent = 2})
	bsr, bsok := bserr.(write.Refused)
	testing.expectf(t, bsok && bsr.why == .No_Spelling, "nan mid-slice: %v", bserr)

	// Invalid UTF-8 across inline (<=32), short, boundary (15,16,31,32,33), and multi-segment (512+) offsets.
	for bad_off in ([?]int{0, 1, 14, 15, 16, 17, 30, 31, 32, 33, 511, 512, 513}) {
		buf := make([]u8, max(bad_off + 4, 16))
		for k in 0 ..< len(buf) {
			buf[k] = 'a'
		}
		buf[bad_off] = 0x80
		s := string(buf[:bad_off + 2])
		for opts in ([?]json.Write_Options{{}, {ascii = true}}) {
			_, serr := json.marshal(&s, opts)
			sr, sok := serr.(write.Refused)
			testing.expectf(t, sok && sr.why == .No_Spelling, "bad utf8 @%d opts=%v: %v", bad_off, opts, serr)
		}
	}
	// Truncated lead byte at block boundary 15 followed by ASCII at 16, and exact 16-byte string ending in lead byte.
	for lead_case in ([?]string{"0123456789abcde\xe3x", "0123456789abcde\xe3"}) {
		lc := lead_case
		_, lerr := json.marshal(&lc)
		lr, lok := lerr.(write.Refused)
		testing.expectf(t, lok && lr.why == .No_Spelling, "truncated utf8 %q: %v", lc, lerr)
	}

	// `zmij` edge-case parity against `strconv.write_float` + `.0` for both f64 and f32.
	f64_edges := [?]f64{
		5e-324, 2.2250738585072009e-308, 2.2250738585072014e-308, 1e-4, 9.999999999999999e-5,
		0.5, 0.25, 1e-1, 1e5, 999999.0, 999999.5, 999999.9999999999, 1000000.0, 1e6, 1e23, 1.7976931348623157e308,
	}
	for fv in f64_edges {
		v := fv
		got, gok := marshal_text(t, &v)
		if !gok {
			continue
		}
		buf: [64]u8
		raw := strconv.write_float(buf[:62], fv, 'g', -1, 64, {})
		has_dot := false
		for c in transmute([]u8)raw {
			if c == '.' || c == 'e' || c == 'E' {
				has_dot = true
				break
			}
		}
		want := raw
		if !has_dot {
			buf[len(raw)], buf[len(raw) + 1] = '.', '0'
			want = string(buf[:len(raw) + 2])
		}
		testing.expectf(t, got == want, "zmij f64 %v: got %q, want %q", fv, got, want)
	}
	for f32v in ([?]f32{0.0, -0.0, 1.40129846e-45, 1.1754942e-38, 1e-4, 9.999999e-5, 999999.5, 1e6, 3.4028235e38}) {
		v := f32v
		got, gok := marshal_text(t, &v)
		if !gok {
			continue
		}
		buf: [64]u8
		raw := strconv.write_float(buf[:62], f64(f32v), 'g', -1, 32, {})
		has_dot := false
		for c in transmute([]u8)raw {
			if c == '.' || c == 'e' || c == 'E' {
				has_dot = true
				break
			}
		}
		want := raw
		if !has_dot {
			buf[len(raw)], buf[len(raw) + 1] = '.', '0'
			want = string(buf[:len(raw) + 2])
		}
		testing.expectf(t, got == want, "zmij f32 %v: got %q, want %q", f32v, got, want)
	}

	// Failing-allocator OOM sweep for `sort_keys = true`.
	context.allocator = heap_alloc
	Sort_Sweep :: struct {
		d:    ^Sorted_Doc,
		opts: json.Write_Options,
	}
	sweep_sorted :: proc(data: rawptr, a: runtime.Allocator) {
		ss := (^Sort_Sweep)(data)
		out, err := json.marshal(ss.d, ss.opts, nil, a)
		if err == nil {
			delete(out, a)
		} else {
			_ = err.(runtime.Allocator_Error)
		}
	}
	for opts in ([?]json.Write_Options{{sort_keys = true}, {sort_keys = true, indent = 2}}) {
		ss := Sort_Sweep{&sd, opts}
		sw := testkit.sweep_failures(sweep_sorted, &ss)
		testing.expectf(t, sw.bad == 0 && sw.refused >= 1, "sort_keys sweep %v: %v", opts, sw)
	}
}
