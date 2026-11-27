package cbor_tests

import "core:testing"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:testkit"

// The keys of a map: integers, byte strings and text strings by their text, each kept as the kind it is.

// An integer key reads as its decimal digits, so a `Name` takes it by them in find, scan and the readers.
@(test)
integer_keys_read_as_their_digits :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := testkit.hex("a3 01 61 78 38 63 61 79 1b ffffffffffffffff 61 7a")
	for c in ([?]struct {
			name, want: string,
		}{{"1", "x"}, {"-100", "y"}, {"18446744073709551615", "z"}}) {
		a, err := cbor.find(src, {tape.Name(c.name)})
		testing.expect_value(t, err, nil)
		testing.expectf(t, a.outcome == .Found && string(src[a.lo + u64(a.head):a.hi]) == c.want, "find %s: %v", c.name, a)
		demand, _ := tape.demand_of([][]tape.Step{{tape.Name(c.name)}}, allocator = context.temp_allocator)
		doc, serr := cbor.scan(src, &demand, allocator = context.temp_allocator)
		testing.expect_value(t, serr, nil)
		at, p, _ := cbor.answer({doc = &doc}, 0, 0)
		s, _ := text_of(&doc, at)
		testing.expectf(t, p == .Found && s == c.want, "scan %s: %v %q", c.name, p, s)
	}
	doc, err := cbor.build(src, allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	at, p := cbor.member({doc = &doc}, cbor.ROOT, "-100")
	s, _ := text_of(&doc, at)
	testing.expectf(t, p == .Found && s == "y", "member: %v %q", p, s)
	testing.expect_value(t, doc.nodes[1].kind, cbor.Kind.Number)
	testing.expect_value(t, doc.nodes[1].role, tape.Role.Key)
	key, _ := text_of(&doc, 5)
	testing.expect_value(t, key, "18446744073709551615")
	_, missing := cbor.member({doc = &doc}, cbor.ROOT, "2")
	testing.expect_value(t, missing, cbor.Presence.Missing)
}

// A byte string key reads as the base64 of its payload, whose chunks join first.
@(test)
byte_string_keys_read_as_base64 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := testkit.hex("a3 43 010203 01 5f 41 01 42 0203 ff 02 41 ff 03")
	testing.expect_value(t, dumped(src), `{"AQID":i:1,"AQID":i:2,"/w==":i:3}`)
	a, _ := cbor.find(src, {tape.Name("/w==")})
	testing.expect_value(t, a.outcome, cbor.Presence.Found)
	testing.expect_value(t, src[a.lo], 0x03)
	// Both keys read as `AQID`, so under `.Last` the later is taken, and `.Refuse` refuses the text.
	b, _ := cbor.find(src, {tape.Name("AQID")})
	testing.expect_value(t, src[b.lo], 0x02)
	_, err := cbor.build(src, .Cbor, {dups = .Refuse}, context.temp_allocator)
	testing.expect_value(t, testkit.code_of(err), "duplicate_key")
}

// A key keeps its kind, so an integer key and a text key of the same digits are two keys, which a `Name` takes alike.
@(test)
keys_of_two_kinds_are_two_keys :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := testkit.hex("a2 01 61 78 61 31 61 79")
	doc, err := cbor.build(src, .Cbor, {dups = .Refuse}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(doc.nodes), 5)
	first, _ := cbor.find(src, {tape.Name("1")}, .Cbor, {}, {dups = .First})
	last, _ := cbor.find(src, {tape.Name("1")})
	testing.expect(t, src[first.lo + 1] == 'x' && src[last.lo + 1] == 'y')
}

// The keys of an object are of three kinds that read as one name, an integer, a text and a byte string, and a find and
// the readers take the same member of them under every policy for repeated keys.
@(test)
find_and_member_agree_on_keys_of_two_kinds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	names := []string{"1", "a", "0"}
	for text in ([]string {
			"a2 01 61 61 61 31 61 62",
			"a2 61 31 61 62 01 61 61",
			"a3 01 61 61 61 31 61 62 01 61 63",
			"a4 61 31 61 61 01 61 62 41 31 61 63 61 31 61 64",
			"a1 01 61 61",
		}) {
		for spec in cbor.Spec {
			if !testkit.find_agrees_with_member(t, cbor.reads(spec), cbor.as(spec), testkit.hex(text), names, text) {
				return
			}
		}
	}
	// An object past the readers' small objects, whose keys are looked up by a table.
	big := make([dynamic]u8, context.temp_allocator)
	append(&big, 0xac)
	for k in 0 ..< 12 {
		if k % 2 == 0 {
			append(&big, 0x61, u8('0' + k % 3))
		} else {
			append(&big, u8(k % 3))
		}
		append(&big, 0x18, u8(k))
	}
	testkit.find_agrees_with_member(t, cbor.reads(.Cbor), cbor.as(.Cbor), big[:], []string{"0", "1", "2", "a", "d"}, "twelve pairs")
}
