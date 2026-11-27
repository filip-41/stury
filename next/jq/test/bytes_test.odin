package jq_tests

import "base:runtime"
import "core:mem/virtual"
import "core:testing"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:msgpack"
import "stury:testkit"

@(test)
jq_native_bytes_cbor_and_msgpack :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// CBOR object:
	// {
	//   "a": h'010203',
	//   "b": h'010203',
	//   "s": "\u0001\u0002\u0003",
	//   "arr": [h'ff', h'0102', h'01', "zz", h'0102'],
	//   "bin": h'deadbeef'
	// }
	cbor_src := [?]u8{
		0xA5,
		0x61, 'a', 0x43, 0x01, 0x02, 0x03,
		0x61, 'b', 0x43, 0x01, 0x02, 0x03,
		0x61, 's', 0x63, 0x01, 0x02, 0x03,
		0x63, 'a', 'r', 'r', 0x85,
			0x41, 0xFF,
			0x42, 0x01, 0x02,
			0x41, 0x01,
			0x62, 'z', 'z',
			0x42, 0x01, 0x02,
		0x63, 'b', 'i', 'n', 0x44, 0xDE, 0xAD, 0xBE, 0xEF,
	}
	cdoc, cerr := cbor.build(cbor_src[:], .Cbor, {}, runtime.heap_allocator())
	testing.expect_value(t, cerr, tape.Error(nil))
	defer tape.destroy(&cdoc)

	// MessagePack equivalent for {"a": bin(010203), "s": "\x01\x02\x03", "bin": bin(deadbeef)}
	mp_src := [?]u8{
		0x83,
		0xA1, 'a', 0xC4, 0x03, 0x01, 0x02, 0x03,
		0xA1, 's', 0xA3, 0x01, 0x02, 0x03,
		0xA3, 'b', 'i', 'n', 0xC4, 0x04, 0xDE, 0xAD, 0xBE, 0xEF,
	}
	mdoc, merr := msgpack.build(mp_src[:], .Msgpack, {}, runtime.heap_allocator())
	testing.expect_value(t, merr, tape.Error(nil))
	defer tape.destroy(&mdoc)

	for doc in ([?]^tape.Document{&cdoc, &mdoc}) {
		// type, scalars, values, strings kind filters
		r := eval_jq(t, `[(.a | type), (.s | type), (.a | length), (.bin | length)]`, {doc = doc})
		testing.expect_value(t, r.end, .Done)
		testing.expect_value(t, r.out, `["bytes","string",3,4]`)

		// Equality: bytes == bytes works, bytes == string is ALWAYS false!
		r2 := eval_jq(t, `[(.a == .a), (.a == .s), (.s == .a), (.a != .s)]`, {doc = doc})
		testing.expect_value(t, r2.end, .Done)
		testing.expect_value(t, r2.out, `[true,false,false,true]`)

		// Kind filters: scalars & values include bytes, strings excludes bytes.
		r3 := eval_jq(t, `[([.a, .s] | map(scalars | type)), ([.a, .s] | map(values | type)), ([.a, .s] | map(strings | type))]`, {doc = doc})
		testing.expect_value(t, r3.end, .Done)
		testing.expect_value(t, r3.out, `[["bytes","string"],["bytes","string"],["string"]]`)

		// JSON output & tojson encode bytes as RFC 4648 base64 strings; @base64 & hex_encode operate on raw bytes.
		r4 := eval_jq(t, `[.bin, (.bin | tojson), (.bin | @base64), (.bin | hex_encode)]`, {doc = doc})
		testing.expect_value(t, r4.end, .Done)
		testing.expect_value(t, r4.out, `["3q2+7w==","\"3q2+7w==\"","3q2+7w==","deadbeef"]`)

		// Concatenation `+` of two bytes preserves `.Bytes`.
		r5 := eval_jq(t, `(.a + .bin) | [type, length, hex_encode]`, {doc = doc})
		testing.expect_value(t, r5.end, .Done)
		testing.expect_value(t, r5.out, `["bytes",7,"010203deadbeef"]`)
	}

	// Native ordering: sort, unique, group_by on mixed strings and bytes.
	rsort := eval_jq(t, `[(.arr | sort | map([type, .])), (.arr | unique | map([type, .])), (.arr | group_by(.) | map(length))]`, {doc = &cdoc})
	testing.expect_value(t, rsort.end, .Done)
	testing.expect_value(
		t,
		rsort.out,
		`[[["string","zz"],["bytes","AQ=="],["bytes","AQI="],["bytes","AQI="],["bytes","/w=="]],` +
		`[["string","zz"],["bytes","AQ=="],["bytes","AQI="],["bytes","/w=="]],` +
		`[1,1,2,1]]`,
	)
}
