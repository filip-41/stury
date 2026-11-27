package cbor_tests

import "core:fmt"
import "core:math/big"
import "core:math/rand"
import "core:testing"
import "stury:cbor"
import "stury:testkit"

// The values and the texts of number nodes.

// Numbers read as `spell.Number` reads a decimal of their value.
@(test)
numbers_read_their_values :: proc(t: ^testing.T) {
	testkit.deadline(t)
	f :: proc(v: f64) -> cbor.Number {return {transmute(u64)v, .Float}}
	rows := [?]struct {
		hex:  string,
		want: cbor.Number,
	} {
		{"00", {0, .Int}},
		{"38 63", {transmute(u64)i64(-100), .Int}},
		{"1b ffffffffffffffff", {max(u64), .Uint}},
		{"3b 7fffffffffffffff", {transmute(u64)min(i64), .Int}},
		{"3b ffffffffffffffff", f(-18446744073709551616.0)},
		{"3b 8000000000000000", {0, .Wide}},
		{"3b 7ffffffffffffffe", {transmute(u64)min(i64) + 1, .Int}},
		{"f9 3c00", f(1)},
		{"f9 fc00", {0xfff0000000000000, .Float}},
		{"fa 47c35000", f(100000)},
		{"fb 3ff199999999999a", f(1.1)},
		{"c2 49 010000000000000000", f(18446744073709551616.0)},
		{"c3 49 010000000000000000", {0, .Wide}},
		{"3b fffffffffffffffe", {0, .Wide}},
		{"c2 49 010000000000000001", {0, .Wide}},
		{"c3 48 ffffffffffffffff", f(-18446744073709551616.0)},
		{"c3 48 7fffffffffffffff", {transmute(u64)min(i64), .Int}},
		{"c2 41 05", {5, .Int}},
		{"c2 5f 41 01 41 00 ff", {256, .Int}},
		{"c4 82 21 19 6ab3", {0, .Wide}},
		{"c4 82 20 03", {0, .Wide}},
		{"c4 82 00 18 19", f(25)},
		{"c4 82 21 18 19", f(0.25)},
		{"c4 82 21 18 ff", {0, .Wide}},
		{"c4 82 20 19 0100", {0, .Wide}},
		{"c5 82 19 ffff 01", {0, .Wide}},
		{"c5 82 39 0800 01", {0, .Wide}},
		{"c5 82 20 03", f(1.5)},
		{"c4 82 01 c2 41 05", {0, .Wide}},
	}
	for r in rows {
		doc, err := cbor.build(testkit.hex(r.hex), allocator = context.temp_allocator)
		if !testing.expectf(t, err == nil, "%s: %v", r.hex, err) {
			continue
		}
		n, _ := cbor.node_number(&doc, cbor.ROOT)
		testing.expectf(t, n == r.want, "%s: want %v, got %v", r.hex, r.want, n)
	}
	big := make([dynamic]u8, context.temp_allocator)
	append(&big, 0xc2, 0x59, 0x00, 0x81)
	for _ in 0 ..< 129 {
		append(&big, 0xff)
	}
	doc, _ := cbor.build(big[:], allocator = context.temp_allocator)
	n, _ := cbor.node_number(&doc, cbor.ROOT)
	testing.expect_value(t, n.kind, cbor.Number_Kind.Wide)
}

// A number's text is its exact value in decimal, in a buffer of the room `text_room` gives: a bignum keeps every digit,
// a float reads as its shortest text, a decimal fraction and a bigfloat of a negative exponent as their digits times a
// power of ten, and a bigfloat of another as an integer.
@(test)
numbers_read_as_their_exact_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	rows := [?]struct {
		hex, want: string,
	} {
		{"00", "0"},
		{"38 63", "-100"},
		{"1b ffffffffffffffff", "18446744073709551615"},
		{"3b ffffffffffffffff", "-18446744073709551616"},
		{"c2 49 010000000000000000", "18446744073709551616"},
		{"c3 49 010000000000000000", "-18446744073709551617"},
		{"c2 40", "0"},
		{"c2 5f 41 01 41 00 ff", "256"},
		{"c2 54 ffffffffffffffffffffffffffffffffffffffff", "1461501637330902918203684832716283019655932542975"},
		{"f9 3c00", "1.0"},
		{"f9 0000", "0.0"},
		{"f9 0001", "5.960464477539063e-08"},
		{"f9 3555", "0.333251953125"},
		{"fb 41d452d9ec000000", "1363896240.0"},
		{"fb 41d452d9ec200000", "1363896240.5"},
		{"fb 3ff199999999999a", "1.1"},
		{"fa 47c35000", "100000.0"},
		{"fb 7fefffffffffffff", "1.7976931348623157e+308"},
		{"fb 4415af1d78b58c40", "1e+20"},
		{"f9 7c00", ""},
		{"c4 82 21 19 6ab3", "27315e-2"},
		{"c4 82 01 c3 41 05", "-6e1"},
		{"c5 82 20 03", "15e-1"},
		{"c5 82 02 03", "12"},
		{"c5 82 21 c2 41 01", "25e-2"},
	}
	for r in rows {
		doc, err := cbor.build(testkit.hex(r.hex), allocator = context.temp_allocator)
		if !testing.expectf(t, err == nil, "%s: %v", r.hex, err) {
			continue
		}
		buf := make([]u8, cbor.text_room(&doc, cbor.ROOT), context.temp_allocator)
		text, ok := cbor.node_text(&doc, cbor.ROOT, buf)
		testing.expectf(t, ok && text == r.want, "%s: want %s, got %s %v", r.hex, r.want, text, ok)
		if r.want == "" {
			continue
		}
		short := make([]u8, len(r.want) - 1, context.temp_allocator)
		_, fits := cbor.node_text(&doc, cbor.ROOT, short)
		testing.expectf(t, !fits, "%s: a buffer too short", r.hex)
	}
	// A bigfloat of the largest exponent spelled has its digits, one past it has none.
	last, _ := cbor.build(testkit.hex("c5 82 19 1388 01"), allocator = context.temp_allocator)
	digits := make([]u8, cbor.text_room(&last, cbor.ROOT), context.temp_allocator)
	text, fits := cbor.node_text(&last, cbor.ROOT, digits)
	testing.expect_value(t, len(text), 1506)
	testing.expect(t, fits)
	past, _ := cbor.build(testkit.hex("c5 82 19 1389 01"), allocator = context.temp_allocator)
	testing.expect_value(t, cbor.text_room(&past, cbor.ROOT), 0)
	// A bigfloat's exponent past what the readers spell gives no text.
	doc, _ := cbor.build(testkit.hex("c5 82 19 ffff 01"), allocator = context.temp_allocator)
	buf: [64]u8
	_, ok := cbor.node_text(&doc, cbor.ROOT, buf[:])
	testing.expect(t, !ok)
	// `number_exact` gives a bignum's value where an integer type holds it.
	exact, _ := cbor.build(testkit.hex("c3 48 7fffffffffffffff"), allocator = context.temp_allocator)
	i, _, unsigned, held := cbor.number_exact(&exact, cbor.ROOT)
	testing.expect(t, held && !unsigned && i == min(i64))
}

// A bignum's text is its magnitude's digits whatever its size, up to `BIGNUM_BYTES_MAX` payload bytes, and one past
// that has no room and no text, so a caller allocates nothing for it.
@(test)
bignum_text_is_exact_to_its_cap :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xcb6)
	for size in ([]int{1, 3, 4, 5, 8, 9, 31, 100, 1000, 4097, cbor.BIGNUM_BYTES_MAX}) {
		payload := make([]u8, size, context.temp_allocator)
		for &b in payload {
			b = u8(rand.uint32())
		}
		payload[0] |= 1
		item := make([dynamic]u8, context.temp_allocator)
		append(&item, 0xc2, 0x59, u8(size >> 8), u8(size))
		append(&item, ..payload)
		doc, err := cbor.build(item[:], allocator = context.temp_allocator)
		if !testing.expectf(t, err == nil, "%d bytes: %v", size, err) {
			continue
		}
		reference: big.Int
		defer big.destroy(&reference)
		testing.expect_value(t, big.int_from_bytes_big(&reference, payload), nil)
		want, _ := big.int_itoa_string(&reference, 10, false, context.temp_allocator)
		buf := make([]u8, cbor.text_room(&doc, cbor.ROOT), context.temp_allocator)
		text, ok := cbor.node_text(&doc, cbor.ROOT, buf)
		testing.expectf(t, ok && text == want, "%d bytes: %d digits, want %d", size, len(text), len(want))
		item[0] = 0xc3
		negative, _ := cbor.build(item[:], allocator = context.temp_allocator)
		testing.expect_value(t, big.int_add_digit(&reference, &reference, 1), nil)
		want, _ = big.int_itoa_string(&reference, 10, false, context.temp_allocator)
		text, ok = cbor.node_text(&negative, cbor.ROOT, buf[:cbor.text_room(&negative, cbor.ROOT)])
		testing.expectf(t, ok && text == fmt.tprintf("-%s", want), "%d bytes negative", size)
	}
	past := make([dynamic]u8, context.temp_allocator)
	append(&past, 0xc2, 0x59, u8((cbor.BIGNUM_BYTES_MAX + 1) >> 8), u8((cbor.BIGNUM_BYTES_MAX + 1) & 0xff), 1)
	for _ in 0 ..< cbor.BIGNUM_BYTES_MAX {
		append(&past, 0)
	}
	doc, _ := cbor.build(past[:], allocator = context.temp_allocator)
	testing.expect_value(t, cbor.text_room(&doc, cbor.ROOT), 0)
	buf: [64]u8
	_, ok := cbor.node_text(&doc, cbor.ROOT, buf[:])
	testing.expect(t, !ok)
}
