package msgpack_tests

import "core:testing"
import "stury:lib/core/tape"
import "stury:msgpack"
import "stury:testkit"

// Map keys in MessagePack: integers, UTF-8 text strings, and binary blobs, preserving distinct types.

@(test)
integer_keys_read_as_their_digits :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := hex("83 01 a1 78 d0 9c a1 79 cf ffffffffffffffff a1 7a")
	for c in ([?]struct {
		name, want: string,
	}{{"1", "x"}, {"-100", "y"}, {"18446744073709551615", "z"}}) {
		a, err := msgpack.find(src, {tape.Name(c.name)})
		testing.expect_value(t, err, nil)
		testing.expectf(t, a.outcome == .Found && string(src[a.lo + u64(a.head):a.hi]) == c.want, "find %s: %v", c.name, a)
		demand, _ := tape.demand_of({{tape.Name(c.name)}}, allocator = context.temp_allocator)
		doc, serr := msgpack.scan(src, &demand, allocator = context.temp_allocator)
		testing.expect_value(t, serr, nil)
		at, p, _ := msgpack.answer({doc = &doc}, 0, 0)
		s, _ := text_of(&doc, at)
		testing.expectf(t, p == .Found && s == c.want, "scan %s: %v %q", c.name, p, s)
	}
	doc, err := msgpack.build(src, allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	at, p := msgpack.member({doc = &doc}, msgpack.ROOT, "-100")
	s, _ := text_of(&doc, at)
	testing.expectf(t, p == .Found && s == "y", "member: %v %q", p, s)
	testing.expect_value(t, doc.nodes[1].kind, msgpack.Kind.Number)
	testing.expect_value(t, doc.nodes[1].role, tape.Role.Key)
	_, missing := msgpack.member({doc = &doc}, msgpack.ROOT, "2")
	testing.expect_value(t, missing, msgpack.Presence.Missing)
}

@(test)
bin_keys_read_as_base64 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := hex("82 c4 03 010203 01 c4 01 ff 03")
	testing.expect_value(t, dumped(src), `{"AQID":i:1,"/w==":i:3}`)
	a, _ := msgpack.find(src, {tape.Name("/w==")})
	testing.expect_value(t, a.outcome, msgpack.Presence.Found)
	testing.expect_value(t, src[a.lo], 0x03)

	dup_bin := hex("82 c4 03 010203 01 c4 03 010203 02")
	_, err := msgpack.build(dup_bin, .Msgpack, {dups = .Refuse}, context.temp_allocator)
	testing.expect_value(t, testkit.code_of(err), "duplicate_key")
}

@(test)
keys_of_two_kinds_are_two_keys :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Key 1 (fixint) and "1" (fixstr) are distinct keys.
	src := hex("82 01 a1 78 a1 31 a1 79")
	doc, err := msgpack.build(src, .Msgpack, {dups = .Refuse}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(doc.nodes), 5)
	first, _ := msgpack.find(src, {tape.Name("1")}, .Msgpack, {}, {dups = .First})
	last, _ := msgpack.find(src, {tape.Name("1")})
	testing.expect(t, src[first.lo + 1] == 'x' && src[last.lo + 1] == 'y')
}

@(test)
find_and_member_agree_on_keys_of_two_kinds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	names := []string{"1", "a", "0"}
	for text in ([]string {
		"82 01 a1 61 a1 31 a1 62",
		"82 a1 31 a1 62 01 a1 61",
		"83 01 a1 61 a1 31 a1 62 01 a1 63",
		"84 a1 31 a1 61 01 a1 62 c4 01 31 a1 63 a1 31 a1 64",
		"81 01 a1 61",
	}) {
		for spec in msgpack.Spec {
			if !testkit.find_agrees_with_member(t, msgpack.reads(spec), msgpack.as(spec), hex(text), names, text) {
				return
			}
		}
	}
	big := make([dynamic]u8, context.temp_allocator)
	append(&big, 0x8c)
	for k in 0 ..< 12 {
		if k % 2 == 0 {
			append(&big, 0xa1, u8('0' + k % 3))
		} else {
			append(&big, u8(k % 3))
		}
		append(&big, u8(k))
	}
	testkit.find_agrees_with_member(t, msgpack.reads(.Msgpack), msgpack.as(.Msgpack), big[:], []string{"0", "1", "2", "a", "d"}, "twelve pairs")
}
