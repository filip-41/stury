package cbor_tests

import "core:testing"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:testkit"

// The rules a CBOR walk judges: the malformed items of RFC 8949 Appendix F, the encoding rules of sections 4.1 and 4.2,
// the limits on a hostile item, and the keys a map may have.

Case :: struct {
	hex:  string,
	code: string, // "" accepts any fault
}

// Every read of the text of `c`, as `spec`, refuses it with one fault, of rule `c.code`.
expect_refused :: proc(t: ^testing.T, c: Case, spec := cbor.Spec.Cbor, opts := cbor.Options{}, loc := #caller_location) {
	src := hex(c.hex)
	err := cbor.validate(src, spec, opts)
	if !testing.expectf(t, err != nil, "%s is read", c.hex, loc = loc) {
		return
	}
	if c.code != "" {
		testing.expectf(t, code_of(err) == c.code, "%s: want %s, got %s", c.hex, c.code, code_of(err), loc = loc)
	}
	_, berr := cbor.build(src, spec, opts, context.temp_allocator)
	testing.expectf(t, testkit.same_refusal(berr, err), "%s: build %v, validate %v", c.hex, berr, err, loc = loc)
	_, ferr := cbor.find(src, {tape.Name("zz")}, spec, {}, opts, context.temp_allocator)
	testing.expectf(t, testkit.same_refusal(ferr, err), "%s: find %v, validate %v", c.hex, ferr, err, loc = loc)
}

expect_read :: proc(t: ^testing.T, text: string, spec := cbor.Spec.Cbor, opts := cbor.Options{}, loc := #caller_location) {
	err := cbor.validate(hex(text), spec, opts)
	testing.expectf(t, err == nil, "%s: %v", text, err, loc = loc)
}

// Appendix F: items that are not well-formed.
MALFORMED := [?]Case {
	// the head or its argument is cut off
	{"18", ""}, {"19", ""}, {"1a", ""}, {"1b", ""}, {"19 01", ""}, {"1a 01 02 03", ""},
	{"38", ""}, {"58", ""}, {"78", ""}, {"98", ""}, {"b8", ""}, {"d8", ""}, {"f8", ""},
	{"f9 00", ""}, {"fa 00 00 00", ""}, {"fb 00 00 00 00 00 00 00", ""},
	// a string shorter than its length
	{"41", ""}, {"61", ""}, {"5a ff ff ff ff 00", ""}, {"7b 00 00 00 00 00 00 00 05 61", ""},
	// containers missing items
	{"81", ""}, {"82 01", ""}, {"a1", ""}, {"a1 01", ""}, {"a2 01 02 03", ""}, {"c0", ""},
	{"9f", ""}, {"9f 01", ""}, {"bf", ""}, {"bf 01 02", ""}, {"5f", ""}, {"5f 41 01", ""},
	{"7f", ""}, {"7f 61 61", ""},
	// reserved additional information
	{"1c", "reserved_info"}, {"1d", "reserved_info"}, {"1e", "reserved_info"}, {"3c", "reserved_info"},
	{"5c", "reserved_info"}, {"7d", "reserved_info"}, {"9e", "reserved_info"}, {"bc", "reserved_info"},
	{"dc", "reserved_info"}, {"fc", "reserved_info"}, {"fd", "reserved_info"}, {"fe", "reserved_info"},
	// an indefinite length where the major type has none
	{"1f", "reserved_info"}, {"3f", "reserved_info"}, {"df", "reserved_info"},
	// the two-byte simple value below 32
	{"f8 00", "bad_simple"}, {"f8 01", "bad_simple"}, {"f8 18", "bad_simple"}, {"f8 1f", "bad_simple"},
	// a break with nothing to break
	{"ff", "bad_break"}, {"82 01 ff", "bad_break"}, {"a1 ff", ""}, {"c0 ff", ""},
	{"bf 01 ff", "bad_break"}, {"9f ff ff", ""},
	// chunks of the wrong type, nested chunks
	{"5f 61 61 ff", "bad_chunk"}, {"7f 41 61 ff", "bad_chunk"}, {"5f 5f 41 01 ff ff", "bad_chunk"},
	{"7f 7f 61 61 ff ff", "bad_chunk"}, {"5f 01 ff", "bad_chunk"}, {"5f 5f ff ff", "bad_chunk"},
	// bytes after the item
	{"00 00", "trailing"}, {"82 01 02 03", "trailing"}, {"", "no_item"},
}

@(test)
malformed_items_are_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in MALFORMED {
		expect_refused(t, c)
	}
}

// Well-formed items that look like malformed ones.
@(test)
well_formed_edges_are_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for text in ([?]string {
			"80", "a0", "40", "60", "5f ff", "7f ff", "9f ff", "bf ff", "5f 40 ff", "7f 60 ff", "c0 74 323031332d30332d32315432303a30343a30305a",
			"d9 d9f7 01", "d9 d9f7 d9 d9f7 01", "f8 20", "f8 ff", "f4", "f5", "f6", "f7", "f0", "e0",
			"bf 41 01 02 ff", "9f 9f ff 9f 01 ff ff",
		}) {
		expect_read(t, text)
	}
}

// Tag 0 takes an RFC 3339 date and time, whose leap second is the last second of 23:59 in UTC.
@(test)
datetime_leap_second_is_judged :: proc(t: ^testing.T) {
	testkit.deadline(t)
	expect_read(t, "c0 74 323031362d31322d33315432333a35393a36305a")
	expect_read(t, "c0 78 19 323031372d30312d30315430303a35393a36302b30313a3030")
	expect_refused(t, {"c0 74 323031362d31322d33315431323a30303a36305a", "bad_tag_content"})
	expect_refused(t, {"c1 61 61", "bad_tag_content"})
	expect_refused(t, {"d8 18 61 61", "bad_tag_content"})
}

// A tag's content in its indefinite form is judged as its definite form is: tag 0 over a text in chunks, and tags 1 and
// 24 over an indefinite array and byte string.
@(test)
tag_contents_are_judged_in_indefinite_form :: proc(t: ^testing.T) {
	testkit.deadline(t)
	expect_read(t, "c0 7f 6b 323031362d31322d333154 69 32333a35393a36305a ff")
	expect_refused(t, {"c0 7f 61 78 ff", "bad_tag_content"})
	expect_refused(t, {"c0 7f 6b 323031362d31322d333154 69 32333a35393a36305a 61 78 ff", "bad_tag_content"})
	expect_refused(t, {"c0 7f ff", "bad_tag_content"})
	expect_refused(t, {"c1 9f ff", "bad_tag_content"})
	expect_read(t, "c1 f9 3c00")
	expect_read(t, "d8 18 5f 41 01 ff")
	expect_refused(t, {"d8 18 7f ff", "bad_tag_content"})
}

// A date-time text of any length is judged the same in chunks as in one string: a long fraction takes digits and an
// offset, and a byte of another kind between them, or an end with none, is refused.
@(test)
long_dates_are_judged_whole_in_chunks :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	judge :: proc(t: ^testing.T, text: []u8, valid: bool, name: string) {
		whole := make([dynamic]u8, context.temp_allocator)
		append(&whole, 0xc0)
		put_head(&whole, 3, u64(len(text)))
		append(&whole, ..text)
		chunked := make([dynamic]u8, context.temp_allocator)
		append(&chunked, 0xc0, 0x7f)
		for rest := text; len(rest) > 0; {
			n := min(len(rest), 37)
			put_head(&chunked, 3, u64(n))
			append(&chunked, ..rest[:n])
			rest = rest[n:]
		}
		append(&chunked, 0xff)
		for spec in cbor.Spec {
			if spec != .Cbor {
				continue
			}
			a, b := cbor.validate(whole[:], spec), cbor.validate(chunked[:], spec)
			testing.expectf(t, (a == nil) == valid && testkit.same_refusal(a, b) || !valid && a != nil && b != nil, "%s: definite %v, chunked %v", name, a, b)
		}
	}
	text := make([dynamic]u8, context.temp_allocator)
	for n in ([]int{1, 8, 11, 12, 13, 20, 31, 32, 33, 39, 40, 41, 100, 5000}) {
		clear(&text)
		append(&text, ..transmute([]u8)string("2013-03-21T20:04:00."))
		for k in 0 ..< n {
			append(&text, u8('0' + k % 10))
		}
		z := len(text)
		append(&text, 'Z')
		judge(t, text[:], true, "Z")
		append(&text, ..transmute([]u8)string("+01:00"))
		judge(t, text[:], false, "Z then an offset")
		resize(&text, z)
		append(&text, ..transmute([]u8)string("+01:00"))
		judge(t, text[:], true, "offset")
		resize(&text, z)
		judge(t, text[:], false, "no offset")
		if n > 12 {
			text[z - 5] = 'x'
			append(&text, 'Z')
			judge(t, text[:], false, "a letter in the fraction")
		}
	}
	judge(t, transmute([]u8)string("2013-03-21T20:04:00Z"), true, "no fraction")
}

// Section 4.1: preferred serialization.
@(test)
preferred_serialization_is_judged :: proc(t: ^testing.T) {
	testkit.deadline(t)
	refused := [?]Case {
		{"18 00", "not_preferred"}, {"18 17", "not_preferred"}, {"19 00 ff", "not_preferred"}, {"1a 00 00 ff ff", "not_preferred"},
		{"1b 00 00 00 00 ff ff ff ff", "not_preferred"}, {"38 00", "not_preferred"}, {"58 01 00", "not_preferred"},
		{"98 01 00", "not_preferred"}, {"b8 00", "not_preferred"}, {"d8 12 01", "not_preferred"},
		// a float a narrower float holds exactly
		{"fa 3c 00 00 00", "not_preferred"}, {"fb 3f f0 00 00 00 00 00 00", "not_preferred"},
		{"fb 3f f8 00 00 00 00 00 00", "not_preferred"}, {"fa 7f c0 00 00", ""},
		// an indefinite length
		{"9f 01 ff", "not_preferred"}, {"bf ff", "not_preferred"}, {"5f 41 01 ff", "not_preferred"}, {"7f 61 61 ff", "not_preferred"},
		// a bignum that fits an integer
		{"c2 41 01", "not_preferred"}, {"c2 40", "not_preferred"}, {"c3 41 01", "not_preferred"},
		{"c2 49 00 01 00 00 00 00 00 00 00", "not_preferred"},
	}
	for c in refused {
		expect_refused(t, c, .Preferred)
	}
	for text in ([?]string {
			"00", "17", "18 18", "19 01 00", "1a 00 01 00 00", "1b 00 00 00 01 00 00 00 00", "20", "38 18", "f9 3c 00", "fa 47 c3 50 00",
			"fb 3f f1 99 99 99 99 99 9a", "f9 7e 00", "f9 7c 00", "f9 fc 00", "c2 49 01 00 00 00 00 00 00 00 00",
			"c3 49 01 00 00 00 00 00 00 00 00", "82 01 02", "a1 01 02", "40", "d9 d9f7 01",
		}) {
		expect_read(t, text, .Preferred)
	}
}

// Section 4.2.1 and 4.2.3: map key order, distinct keys and the one NaN.
@(test)
deterministic_encoding_is_judged :: proc(t: ^testing.T) {
	testkit.deadline(t)
	refused := [?]Case {
		{"a2 01 02 00 03", "key_order"}, {"a2 00 01 00 02", "key_order"}, {"a2 61 62 01 61 61 02", "key_order"},
		{"a2 61 61 01 61 61 02", "key_order"}, {"a2 18 18 01 0a 02", "key_order"},
		{"f9 7e 01", "bad_nan"}, {"fa 7f c0 00 00", ""}, {"fb 7f f8 00 00 00 00 00 01", ""},
		{"a1 00 a2 61 62 01 61 61 02", "key_order"},
	}
	for c in refused {
		expect_refused(t, c, .Deterministic)
	}
	for text in ([?]string {
			"a2 00 01 01 02", "a2 0a 01 18 18 02", "a2 61 61 01 61 62 02", "a2 60 01 61 61 02", "a2 20 01 38 63 02", "a2 18 18 00 60 00",
			"f9 7e 00", "a0", "a1 61 61 01", "a2 00 a2 00 01 01 02 01 a1 00 00",
		}) {
		expect_read(t, text, .Deterministic)
	}
	// Bytewise order of the encoded keys differs from length-first order.
	expect_refused(t, {"a2 18 18 00 60 00", "key_order"}, .Length_First)
	expect_read(t, "a2 60 00 18 18 00", .Length_First)
	expect_read(t, "a2 61 61 00 62 61 61 01", .Length_First)
}

// A count that the bytes left cannot hold is refused at its head, whatever the memory it would ask for.
@(test)
counts_larger_than_the_text_are_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := [?]Case {
		{"9b ff ff ff ff ff ff ff ff", "count_too_large"}, {"bb 7f ff ff ff ff ff ff ff", "count_too_large"},
		{"9a ff ff ff ff", "count_too_large"}, {"5b ff ff ff ff ff ff ff ff", "truncated"},
		{"7a 00 10 00 00 61", "truncated"}, {"83 01 02", "count_too_large"},
	}
	for c in cases {
		expect_refused(t, c)
	}
}

// Nesting is capped by `Budget.depth`, and a tag counts as a level.
@(test)
nesting_is_limited :: proc(t: ^testing.T) {
	testkit.deadline(t)
	nest :: proc(prefix: byte, depth: int) -> []u8 {
		b := make([]u8, depth + 1, context.temp_allocator)
		for i in 0 ..< depth {
			b[i] = prefix
		}
		b[depth] = 0
		return b
	}
	deep :: proc(t: ^testing.T, src: []u8, opts: cbor.Options, loc := #caller_location) {
		err := cbor.validate(src, .Cbor, opts)
		e, ok := err.(tape.Exceeded)
		testing.expectf(t, ok && e.kind == .Depth, "%v", err, loc = loc)
		_, berr := cbor.build(src, .Cbor, opts, context.temp_allocator)
		testing.expectf(t, testkit.same_refusal(berr, err), "build %v", berr, loc = loc)
	}
	testing.expect_value(t, cbor.validate(nest(0x81, 5000), .Cbor), nil)
	deep(t, nest(0x81, 20000), {})
	deep(t, nest(0x81, 20), {budget = {depth = 10}})
	testing.expect_value(t, cbor.validate(nest(0x81, 10), .Cbor, {budget = {depth = 10}}), nil)
	doc, err := cbor.build(nest(0x81, 5000), .Cbor, {}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(doc.nodes), 5001)

	chain := make([dynamic]u8, context.temp_allocator)
	for _ in 0 ..< 20 {
		append(&chain, 0xd9, 0xd9, 0xf7)
	}
	append(&chain, 0)
	deep(t, chain[:], {budget = {depth = 10}})

	maps := make([dynamic]u8, context.temp_allocator)
	for _ in 0 ..< 30 {
		append(&maps, 0xa1, 0x00)
	}
	append(&maps, 0)
	deep(t, maps[:], {budget = {depth = 10}})
}

// A map key is an integer, a text string or a byte string. Any other key has no spelling a path can use.
@(test)
keys_are_scalars :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := [?]Case {
		{"a1 80 01", "bad_key"}, {"a1 a0 01", "bad_key"}, {"a1 f5 01", "bad_key"}, {"a1 f6 01", "bad_key"},
		{"a1 f9 3c 00 01", "bad_key"}, {"a1 c1 01 02", "bad_key"}, {"a1 d9 d9f7 01 02", "bad_key"},
	}
	for c in cases {
		expect_refused(t, c)
	}
	for text in ([?]string {"a1 01 02", "a1 20 02", "a1 41 01 02", "a1 61 61 02", "a1 5f 41 01 ff 02"}) {
		expect_read(t, text)
	}
}

// Section 3.2.2 and RFC 3629: text is UTF-8, unless the caller tolerates it.
@(test)
text_must_be_utf8 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in ([?]Case {{"62 c3 28", "invalid_utf8"}, {"61 80", "invalid_utf8"}, {"63 ed a0 80", "invalid_utf8"}, {"62 c0 80", "invalid_utf8"}, {"7f 61 c3 61 a9 ff", "invalid_utf8"}}) {
		expect_refused(t, c)
	}
	lax := cbor.Options{tolerate = {.Invalid_Utf8}}
	expect_read(t, "62 c3 28", opts = lax)
	doc, err := cbor.build(hex("62 c3 28"), .Cbor, lax)
	testing.expect_value(t, err, nil)
	defer cbor.destroy(&doc)
	testing.expect(t, .Tolerated in doc.flags)
	s, _ := text_of(&doc, cbor.ROOT)
	testing.expect_value(t, s, "�(")
	testing.expect_value(t, dumped(hex("7f 61 c3 62 61 80 ff"), opts = lax), `"�a�"`)
	// A byte string holds any bytes.
	expect_read(t, "42 c3 28")
}

// The chunks of an indefinite string join in order.
@(test)
chunks_join :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, dumped(hex("7f 62 68 69 63 e2 82 ac ff")), `"hi€"`)
	testing.expect_value(t, dumped(hex("a1 7f 61 6b 61 79 ff 01")), `{"ky":i:1}`)
}

// The message of a fault names its rule and its place, a byte offset in a binary text.
@(test)
faults_have_messages :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := hex("82 01 61 80")
	err := cbor.validate(src, .Cbor)
	buf: [64]u8
	testing.expect_value(t, tape.error_message(buf[:], err, src, cbor.as(.Cbor)), "byte 3: Text string is not UTF-8 byte 0x80")
	testing.expect_value(t, tape.error_message(buf[:], cbor.validate(hex("ff"), .Cbor), hex("ff"), cbor.as(.Cbor)), "byte 0: Break outside an indefinite item")
	lines := hex("0a 0a 61 80")
	testing.expect_value(t, tape.error_message(buf[:], tape.Exceeded{at = 3, kind = .Depth}, lines, cbor.as(.Deterministic)), "byte 3: Exceeds the depth limit")
	// A message that names no format places the fault by line and column, as in a text format.
	testing.expect_value(t, tape.error_message(buf[:], err, src), "1:4: Text string is not UTF-8 byte 0x80")
}

// The depth limit is judged before a head's shortest form and its count, and a key that repeats its predecessor is a
// duplicate key where the build refuses repeats and out of order otherwise.
@(test)
limits_and_repeats_come_first :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for text in ([]string{"81 98 01 00", "81 9f ff", "81 99 ffff 00", "81 bf ff"}) {
		for spec in ([]cbor.Spec{.Preferred, .Deterministic, .Length_First}) {
			err := cbor.validate(hex(text), spec, {budget = {depth = 1}})
			testing.expectf(t, code_of(err) == "exceeded Depth", "%s as %v: %s", text, spec, code_of(err))
		}
	}
	for spec in ([]cbor.Spec{.Preferred, .Deterministic, .Length_First}) {
		testing.expect_value(t, code_of(cbor.validate(hex("c0 7f 61 78 ff"), spec)), "not_preferred")
		testing.expect_value(t, code_of(cbor.validate(hex("c0 ff"), spec)), "bad_tag_content")
	}
	for spec in ([]cbor.Spec{.Deterministic, .Length_First}) {
		err := cbor.validate(hex("a2 00 01 00 02"), spec)
		testing.expectf(t, code_of(err) == "key_order", "%v: %s", spec, code_of(err))
		_, err = cbor.build(hex("a2 00 01 00 02"), spec, {dups = .Refuse}, context.temp_allocator)
		testing.expectf(t, code_of(err) == "duplicate_key", "%v refusing repeats: %s", spec, code_of(err))
		err = cbor.validate(hex("a2 01 01 00 02"), spec)
		testing.expectf(t, code_of(err) == "key_order", "%v: %s", spec, code_of(err))
	}
}

// A find that ends once its answer is known judges every byte it reads: it refuses with the fault validate gives, or
// ends before the fault, and every well-formed text it reads whole.
@(test)
early_finds_judge_the_bytes_they_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
	paths := [][]tape.Step{{tape.Name("a")}, {tape.Index(0)}, {tape.Index(1)}, {tape.Index(0), tape.Index(0)}}
	for c in MALFORMED {
		src := hex(c.hex)
		for spec in cbor.Spec {
			want := cbor.validate(src, spec)
			for path in paths {
				_, err := cbor.find(src, path, spec, {stop_early = true})
				testing.expectf(t, err == nil || testkit.same_refusal(err, want), "%s as %v, %v: %v against %v", c.hex, spec, path, err, want)
			}
		}
	}
}

// Under `.Refuse` a repeated key before a fault of the walk comes first, as the first fault in the text wins, whether
// its object is closed or open at the fault. Under another policy the walk's fault is the error.
@(test)
a_repeat_before_a_fault_comes_first :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		text, refusing, other: string,
	} {
		{"a2 61 61 01 61 61 02 00", "duplicate_key", "trailing"},
		{"a3 61 61 01 61 61 02 61 62 f8 00", "duplicate_key", "bad_simple"},
		{"82 a2 61 61 01 61 61 02 ff", "duplicate_key", "bad_break"},
		{"a2 61 61 01 61 61 f8 00", "duplicate_key", "bad_simple"},
		{"a1 61 61 01 00", "trailing", "trailing"},
	}
	for c in cases {
		_, err := cbor.build(hex(c.text), .Cbor, {dups = .Refuse}, context.temp_allocator)
		testing.expectf(t, code_of(err) == c.refusing, "%s refusing repeats: %s", c.text, code_of(err))
		_, err = cbor.build(hex(c.text), .Cbor, {dups = .Last}, context.temp_allocator)
		testing.expectf(t, code_of(err) == c.other, "%s: %s", c.text, code_of(err))
	}
}
