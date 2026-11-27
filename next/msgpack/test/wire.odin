package msgpack_tests

import "core:encoding/endian"
import "core:math"
import "core:testing"
import "stury:msgpack"
import "stury:testkit"

// Exhaustive MessagePack wire-format verification covering every format tag byte 0x00..0xff,
// edge scalars (min/max integers, -0.0, NaN, Inf, UTF-8, invalid UTF-8), binary payloads,
// all container widths (including 65,536 elements), ext types (-128..127), and timestamps (32/64/96).

@(test)
wire_all_format_tags_roundtrip :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// 1. Positive fixint 0x00..0x7f & negative fixint 0xe0..0xff
	for b in 0 ..= 0x7f {
		src := []u8{u8(b)}
		for spec in msgpack.Spec {
			doc, err := msgpack.build(src, spec, allocator = context.temp_allocator)
			testing.expectf(t, err == nil, "pos fixint %x under %v: %v", b, spec, err)
			n, nok := msgpack.node_number(&doc, msgpack.ROOT)
			testing.expect(t, nok && n == msgpack.Number{u64(b), .Int})
		}
	}
	for b in 0xe0 ..= 0xff {
		src := []u8{u8(b)}
		for spec in msgpack.Spec {
			doc, err := msgpack.build(src, spec, allocator = context.temp_allocator)
			testing.expectf(t, err == nil, "neg fixint %x under %v: %v", b, spec, err)
			n, nok := msgpack.node_number(&doc, msgpack.ROOT)
			testing.expect(t, nok && i64(n.bits) == i64(i8(u8(b))))
		}
	}

	// 2. Empty fixarray/fixmap/fixstr + lengths across fix, 8, 16, 32
	for count in 0 ..= 15 {
		arr := make([]u8, 1 + count, context.temp_allocator)
		arr[0] = 0x90 | u8(count)
		testing.expect_value(t, msgpack.validate(arr, .Compact), nil)

		mp := make([]u8, 1 + count * 2, context.temp_allocator)
		mp[0] = 0x80 | u8(count)
		for k in 0 ..< count {
			mp[1 + k * 2] = u8(k)
			mp[2 + k * 2] = 0xc0
		}
		testing.expect_value(t, msgpack.validate(mp, .Compact), nil)
	}
	for slen in 0 ..= 31 {
		s := make([]u8, 1 + slen, context.temp_allocator)
		s[0] = 0xa0 | u8(slen)
		for k in 0 ..< slen {
			s[1 + k] = 'a'
		}
		doc, err := msgpack.build(s, .Compact, allocator = context.temp_allocator)
		testing.expect_value(t, err, nil)
		got, _ := text_of(&doc, msgpack.ROOT)
		testing.expect_value(t, len(got), slen)
	}

	// 3. Single-byte special codes: nil (0xc0), reserved (0xc1 refused), false (0xc2), true (0xc3)
	testing.expect_value(t, dumped([]u8{0xc0}, .Compact), "null")
	testing.expect_value(t, dumped([]u8{0xc2}, .Compact), "false")
	testing.expect_value(t, dumped([]u8{0xc3}, .Compact), "true")
	for spec in msgpack.Spec {
		err := msgpack.validate([]u8{0xc1}, spec)
		testing.expectf(t, testkit.code_of(err) == "reserved_type", "0xc1 under %v: %v", spec, err)
	}

	// 4. All uint*/int* boundary values
	uint_cases := [?]struct {
		hex:  string,
		kind: msgpack.Number_Kind,
		bits: u64,
	}{
		{"cc 80", .Int, 0x80},
		{"cc ff", .Int, 0xff},
		{"cd 0100", .Int, 0x100},
		{"cd ffff", .Int, 0xffff},
		{"ce 00010000", .Int, 0x1_0000},
		{"ce ffffffff", .Int, 0xffff_ffff},
		{"cf 0000000100000000", .Int, 0x1_0000_0000},
		{"cf 7fffffffffffffff", .Int, u64(max(i64))},
		{"cf ffffffffffffffff", .Uint, max(u64)},
	}
	for c in uint_cases {
		doc, err := msgpack.build(testkit.hex(c.hex), .Compact, allocator = context.temp_allocator)
		testing.expectf(t, err == nil, "%s: %v", c.hex, err)
		n, ok := msgpack.node_number(&doc, msgpack.ROOT)
		testing.expectf(t, ok && n.kind == c.kind && n.bits == c.bits, "%s: got %v", c.hex, n)
	}
	int_cases := [?]struct {
		hex: string,
		val: i64,
	}{
		{"d0 df", -33},
		{"d0 80", -128},
		{"d1 ff7f", -129},
		{"d1 8000", -32768},
		{"d2 ffff7fff", -32769},
		{"d2 80000000", -2_147_483_648},
		{"d3 ffffffff7fffffff", -2_147_483_649},
		{"d3 8000000000000000", min(i64)},
	}
	for c in int_cases {
		doc, err := msgpack.build(testkit.hex(c.hex), .Compact, allocator = context.temp_allocator)
		testing.expectf(t, err == nil, "%s: %v", c.hex, err)
		n, ok := msgpack.node_number(&doc, msgpack.ROOT)
		testing.expectf(t, ok && n.kind == .Int && i64(n.bits) == c.val, "%s: got %v", c.hex, n)
	}

	// 5. Float32 (0xca) and Float64 (0xcb): NaN, +Inf, -Inf, -0.0, subnormals, precision-requiring f64
	float_bytes := [?][]u8{
		testkit.hex("ca 80000000"),                   // -0.0 f32
		testkit.hex("ca 7f800000"),                   // +Inf f32
		testkit.hex("ca ff800000"),                   // -Inf f32
		testkit.hex("ca 7fc00000"),                   // qNaN f32
		testkit.hex("ca 00000001"),                   // subnormal f32
		testkit.hex("cb 3ff199999999999a"),          // 1.1 f64
		testkit.hex("cb 7ff0000000000001"),          // signalling/payload NaN f64
		testkit.hex("cb 0000000000000001"),          // subnormal f64
	}
	for fb in float_bytes {
		doc, err := msgpack.build(fb, .Compact, allocator = context.temp_allocator)
		testing.expectf(t, err == nil, "%x under Compact: %v", fb, err)
		n, ok := msgpack.node_number(&doc, msgpack.ROOT)
		testing.expect(t, ok && n.kind == .Float)
	}
	neg_zero_doc, _ := msgpack.build(testkit.hex("ca 80000000"), .Compact, allocator = context.temp_allocator)
	neg_zero_n, _ := msgpack.node_number(&neg_zero_doc, msgpack.ROOT)
	testing.expect(t, math.sign_bit(transmute(f64)neg_zero_n.bits))

	// 6. bin 8/16/32 and str 8/16/32 (including 65,536 bytes)
	for n in ([?]int{0, 255, 256, 65536}) {
		bin := make([dynamic]u8, context.temp_allocator)
		payload := make([]u8, n, context.temp_allocator)
		for i in 0 ..< n {
			payload[i] = u8(i)
		}
		put_bin(&bin, payload)
		doc, err := msgpack.build(bin[:], .Compact, allocator = context.temp_allocator)
		testing.expectf(t, err == nil && len(doc.nodes) == 1 && doc.nodes[0].kind == .Bytes, "bin %d: %v", n, err)
		testing.expect_value(t, string(msgpack.span_bytes(&doc, doc.nodes[0].lo, doc.nodes[0].n)), string(payload))
		out, dropped, werr := msgpack.write(&doc, .Compact, allocator = context.temp_allocator)
		testing.expectf(t, werr == nil && dropped == {} && string(out) == string(bin[:]), "bin %d write mismatch", n)

		str_buf := make([dynamic]u8, context.temp_allocator)
		sdata := make([]u8, n, context.temp_allocator)
		for i in 0 ..< n {
			sdata[i] = 'a' + u8(i % 26)
		}
		put_str(&str_buf, string(sdata))
		sdoc, serr := msgpack.build(str_buf[:], .Compact, allocator = context.temp_allocator)
		testing.expectf(t, serr == nil && sdoc.nodes[0].kind == .String, "str %d: %v", n, serr)
		sout, _, swerr := msgpack.write(&sdoc, .Compact, allocator = context.temp_allocator)
		testing.expectf(t, swerr == nil && string(sout) == string(str_buf[:]), "str %d write mismatch", n)
	}
}

@(test)
wire_large_65536_containers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// array 32 with 65,536 fixints
	big_arr := make([]u8, 5 + 65536, context.temp_allocator)
	big_arr[0] = 0xdd
	endian.unchecked_put_u32be(big_arr[1:5], 65536)
	for i in 0 ..< 65536 {
		big_arr[5 + i] = u8(i & 0x7f)
	}
	doc, err := msgpack.build(big_arr, .Compact, allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(doc.nodes), 65537)
	n, _, _ := msgpack.length({&doc, nil}, msgpack.ROOT, context.temp_allocator)
	testing.expect_value(t, n, 65536)
	last, lp := msgpack.element({&doc, nil}, msgpack.ROOT, 65535)
	testing.expect(t, lp == .Found)
	num, _ := msgpack.node_number(&doc, last)
	testing.expect_value(t, num, msgpack.Number{127, .Int})

	// map 32 with 65,536 pairs (integer keys 0..65535)
	big_map := make([dynamic]u8, 0, 5 + 65536 * 4, context.temp_allocator)
	h := [5]u8{0xdf, 0, 1, 0, 0}
	append(&big_map, ..h[:])
	for k in 0 ..< 65536 {
		if k <= 0x7f {
			append(&big_map, u8(k))
		} else if k <= 0xff {
			append(&big_map, 0xcc, u8(k))
		} else {
			kh := [3]u8{0xcd, u8(k >> 8), u8(k)}
			append(&big_map, ..kh[:])
		}
		append(&big_map, 0xc3)
	}
	mdoc, merr := msgpack.build(big_map[:], .Compact, allocator = context.temp_allocator)
	testing.expect_value(t, merr, nil)
	mcount, _, _ := msgpack.length({&mdoc, nil}, msgpack.ROOT, context.temp_allocator)
	testing.expect_value(t, mcount, 65536)
	found, fp := msgpack.member({&mdoc, nil}, msgpack.ROOT, "65535")
	testing.expect(t, fp == .Found && mdoc.nodes[found].kind == .True)
}

@(test)
wire_ext_and_timestamps :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Fixext 1/2/4/8/16 and Ext 8/16/32 across signed ext type range (-128..127 excluding -1).
	ext_cases := [?]struct {
		raw:      []u8,
		ext_type: i8,
		pay_len:  int,
	}{
		{[]u8{0xd4, 0x00, 0xaa}, 0, 1},
		{[]u8{0xd5, 0x7f, 0x11, 0x22}, 127, 2},
		{[]u8{0xd6, 0x80, 1, 2, 3, 4}, -128, 4},
		{[]u8{0xd7, 0xfe, 1, 2, 3, 4, 5, 6, 7, 8}, -2, 8},
		{[]u8{0xd8, 10, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}, 10, 16},
		{[]u8{0xc7, 0, 5}, 5, 0},
		{[]u8{0xc7, 3, 42, 0xde, 0xad, 0xbe}, 42, 3},
	}
	for c in ext_cases {
		doc, err := msgpack.build(c.raw, .Compact, allocator = context.temp_allocator)
		testing.expectf(t, err == nil && doc.nodes[0].kind == .Bytes, "%x: %v", c.raw, err)
		testing.expect_value(t, len(doc.facts), 1)
		fnum, ok := msgpack.fact_number(&doc, doc.facts[0])
		testing.expectf(t, ok && fnum.kind == .Int && i8(i64(fnum.bits)) == c.ext_type, "%x tag = %v", c.raw, fnum)
		testing.expect_value(t, len(msgpack.span_bytes(&doc, doc.nodes[0].lo, doc.nodes[0].n)), c.pay_len)
		out, dropped, werr := msgpack.write(&doc, .Compact, allocator = context.temp_allocator)
		testing.expectf(t, werr == nil && dropped == {} && string(out) == string(c.raw), "%x write = %x", c.raw, out)
	}

	// Valid MessagePack Timestamps: 32-bit, 64-bit, 96-bit (including pre-epoch negative and extreme 64-bit year).
	ts_cases := [?]struct {
		hex:  string,
		want: string,
	}{
		{"d6 ff 00000000", "1970-01-01T00:00:00Z"},
		{"d6 ff 514b67b0", "2013-03-21T20:04:00Z"},
		{"d6 ff ffffffff", "2106-02-07T06:28:15Z"},
		{"d7 ff 00000004 514b67b0", "2013-03-21T20:04:00.000000001Z"},
		{"d7 ff ee6b27ff ffffffff", "2514-05-30T01:53:03.999999999Z"},
		{"c7 0c ff 075bcd15 ffffffffffffffff", "1969-12-31T23:59:59.123456789Z"}, // -1 sec + 0.123456789ns
		{"c7 0c ff 00000000 fffffffffffea077", "1969-12-30T23:00:07Z"},
		{"c7 0c ff 00000000 fffffff1868b8400", "0000-01-01T00:00:00Z"},
		{"c7 0c ff 00000000 0000003afff4417f", "9999-12-31T23:59:59Z"},
		{"c7 0c ff 00000000 0000003afff44180", "+10000-01-01T00:00:00Z"},
		{"c7 0c ff 00000000 fffffff1868b83ff", "-0001-12-31T23:59:59Z"},
	}
	for c in ts_cases {
		src := testkit.hex(c.hex)
		doc, err := msgpack.build(src, .Compact, allocator = context.temp_allocator)
		testing.expectf(t, err == nil && doc.nodes[0].kind == .String, "%s: %v", c.hex, err)
		got, gok := text_of(&doc, msgpack.ROOT)
		testing.expectf(t, gok && got == c.want, "%s: got %q want %q", c.hex, got, c.want)
		name, has_name := msgpack.fact_name(&doc, msgpack.ROOT, .Tag)
		testing.expect(t, has_name && name == "datetime")
		a, ferr := msgpack.find(src, nil, .Compact)
		testing.expect(t, ferr == nil && a.lo == 0 && a.hi == u64(len(src)))
		out, dropped, werr := msgpack.write(&doc, .Compact, allocator = context.temp_allocator)
		testing.expectf(t, werr == nil && dropped == {} && string(out) == string(src), "%s roundtrip = %x", c.hex, out)
	}
}
