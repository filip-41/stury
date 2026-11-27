package spell_tests

import "base:intrinsics"
import "core:testing"
import "stury:lib/base/spell"
import "stury:testkit"

// `entity_named` resolves XML predefined entities, multi-codepoint HTML5 entities, digit-bearing names, and first/last
// and shortest/longest boundary entries to their exact UTF-8 byte sequences.
@(test)
entity_named_known_entries :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := []struct {
		name: string,
		want: string,
	}{
		// All 5 XML 1.0 predefined entities.
		{"amp", "&"},
		{"lt", "<"},
		{"gt", ">"},
		{"quot", "\""},
		{"apos", "'"},
		// HTML5 uppercase counterparts for the 4 legacy XML names.
		{"AMP", "&"},
		{"LT", "<"},
		{"GT", ">"},
		{"QUOT", "\""},
		// Common XHTML/HTML5 references including legacy semicolon-optional names.
		{"nbsp", "\xc2\xa0"},
		{"copy", "\xc2\xa9"},
		{"COPY", "\xc2\xa9"},
		{"eacute", "\xc3\xa9"},
		// Multi-codepoint HTML5 entities (2-byte ASCII pair, 5-byte, and max 6-byte UTF-8 values).
		{"fjlig", "fj"},
		{"NotEqualTilde", "\xe2\x89\x82\xcc\xb8"},
		{"ngeqq", "\xe2\x89\xa7\xcc\xb8"},
		{"acE", "\xe2\x88\xbe\xcc\xb3"},
		{"NotSubset", "\xe2\x8a\x82\xe2\x83\x92"},
		{"NotSuperset", "\xe2\x8a\x83\xe2\x83\x92"},
		{"ThickSpace", "\xe2\x81\x9f\xe2\x80\x8a"},
		// Boundary entries: lexicographically first/last, shortest, longest (31 bytes), astral 4-byte UTF-8, digits.
		{"AElig", "\xc3\x86"},
		{"zwnj", "\xe2\x80\x8c"},
		{"DD", "\xe2\x85\x85"},
		{"CounterClockwiseContourIntegral", "\xe2\x88\xb3"},
		{"zopf", "\xf0\x9d\x95\xab"},
		{"frac12", "\xc2\xbd"},
		{"blk14", "\xe2\x96\x91"},
		{"emsp13", "\xe2\x80\x84"},
	}
	for c in cases {
		got, ok := spell.entity_named(transmute([]u8)c.name)
		testing.expectf(t, ok && string(got) == c.want, "%q: got (%q, %v), want (%q, true)", c.name, string(got), ok, c.want)
	}
}

// `entity_named` distinguishes case-sensitive spellings and prefix-sharing names without conflating prefixes or
// extensions.
@(test)
entity_named_case_and_prefixes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	valid := []struct {
		name: string,
		want: string,
	}{
		// Case-sensitive triples / pairs with distinct code points.
		{"lt", "<"},
		{"Lt", "\xe2\x89\xaa"},
		{"LT", "<"},
		{"gt", ">"},
		{"Gt", "\xe2\x89\xab"},
		{"GT", ">"},
		{"not", "\xc2\xac"},
		{"Not", "\xe2\xab\xac"},
		{"AElig", "\xc3\x86"},
		{"aelig", "\xc3\xa6"},
		// Valid prefix/extension pairs in the trie.
		{"Cap", "\xe2\x8b\x92"},
		{"CapitalDifferentialD", "\xe2\x85\x85"},
		{"Colon", "\xe2\x88\xb7"},
		{"Colone", "\xe2\xa9\xb4"},
		{"DD", "\xe2\x85\x85"},
		{"DDotrahd", "\xe2\xa4\x91"},
		{"Dot", "\xc2\xa8"},
		{"DotDot", "\xe2\x83\x9c"},
		{"DotEqual", "\xe2\x89\x90"},
		{"notin", "\xe2\x88\x89"},
		{"NotExists", "\xe2\x88\x84"},
	}
	for c in valid {
		got, ok := spell.entity_named(transmute([]u8)c.name)
		testing.expectf(t, ok && string(got) == c.want, "%q: got (%q, %v), want (%q, true)", c.name, string(got), ok, c.want)
	}

	// Wrong case, non-terminal prefixes, and overlong extensions must fail.
	invalid := []string{
		"APOS",
		"Amp",
		"Nbsp",
		"eAcute",
		"a",
		"am",
		"No",
		"NotEqualTild",
		"CounterClockwiseContourIntegra",
		"ampp",
		"lt2",
		"nbspp",
		"NotEqualTildeX",
		"CounterClockwiseContourIntegralX",
	}
	for name in invalid {
		got, ok := spell.entity_named(transmute([]u8)name)
		testing.expectf(t, !ok && got == nil, "%q: got (%q, %v), want (nil, false)", name, string(got), ok)
	}
}

// `entity_named` rejects empty, nil, semicolon-bearing, malformed, NUL-containing, very long, and non-ASCII inputs.
@(test)
entity_named_rejects_malformed_and_non_ascii :: proc(t: ^testing.T) {
	testkit.deadline(t)
	if got, ok := spell.entity_named(nil); ok || got != nil {
		testing.expectf(t, false, "nil: got (%q, %v), want (nil, false)", string(got), ok)
	}

	invalid := []string{
		"",
		";",
		"amp;",
		"nbsp;",
		"&amp",
		"&amp;",
		"#65",
		"#x41",
		" amp",
		"amp ",
		"\x00",
		"\x00amp",
		"amp\x00",
		"am\x00p",
		"\x7f",
		"bogus",
		"nonexistent",
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	}
	for name in invalid {
		got, ok := spell.entity_named(transmute([]u8)name)
		testing.expectf(t, !ok && got == nil, "%q: got (%q, %v), want (nil, false)", name, string(got), ok)
	}

	// Very long input sharing a valid max-length prefix terminates cleanly without matching.
	long_buf: [256]u8
	prefix := "CounterClockwiseContourIntegral"
	copy(long_buf[:], prefix)
	for i in len(prefix) ..< len(long_buf) {
		long_buf[i] = 'a'
	}
	got, ok := spell.entity_named(long_buf[:])
	testing.expectf(t, !ok && got == nil, "long prefix: got (%q, %v), want (nil, false)", string(got), ok)

	// Every non-ASCII byte (0x80..0xFF) is rejected alone, mid-prefix, and immediately after a valid name.
	for b in 0x80 ..= 0xFF {
		alone := [1]u8{u8(b)}
		if t0, ok0 := spell.entity_named(alone[:]); ok0 || t0 != nil {
			testing.expectf(t, false, "alone 0x%02x: got (%q, %v), want (nil, false)", b, string(t0), ok0)
			return
		}
		mid := [3]u8{'a', 'm', u8(b)}
		if t1, ok1 := spell.entity_named(mid[:]); ok1 || t1 != nil {
			testing.expectf(t, false, "mid 0x%02x: got (%q, %v), want (nil, false)", b, string(t1), ok1)
			return
		}
		tail := [4]u8{'a', 'm', 'p', u8(b)}
		if t2, ok2 := spell.entity_named(tail[:]); ok2 || t2 != nil {
			testing.expectf(t, false, "tail 0x%02x: got (%q, %v), want (nil, false)", b, string(t2), ok2)
			return
		}
	}
}

// `entity_prefix` returns the longest HTML5 named reference starting at `p` (with or without `;`), backtracking past
// non-terminal prefixes, and returns `(nil, p)` on no match, empty range, or non-ASCII lead bytes.
@(test)
entity_prefix_longest_and_non_matches :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Match :: struct {
		input: string,
		want:  string,
		used:  int,
	}
	matches := []Match{
		{"amp;rest", "&", 4},
		{"amprest", "&", 3},
		{"amp", "&", 3},
		{"AMP;", "&", 4},
		{"copy=1", "\xc2\xa9", 4},
		{"copy;1", "\xc2\xa9", 5},
		{"notin;", "\xe2\x88\x89", 6},
		// `not` is a legacy semicolon-less entity while `noti` is a non-terminal prefix of `notin;`.
		{"noti", "\xc2\xac", 3},
		{"notin", "\xc2\xac", 3},
		{"notit;", "\xc2\xac", 3},
		{"NotEqualTilde;x", "\xe2\x89\x82\xcc\xb8", 14},
		{"amp\xc3\xa9", "&", 3},
	}
	for c in matches {
		b := transmute([]u8)c.input
		p := raw_data(b)
		text, q := spell.entity_prefix(p, p[len(b):])
		used := int(intrinsics.ptr_sub(q, p))
		testing.expectf(t, string(text) == c.want && used == c.used, "%q: got (%q, %d), want (%q, %d)", c.input, string(text), used, c.want, c.used)
	}

	misses := []string{"", ";", "am", "apos", "NotEqualTilde", "bogus;", "\x80amp;", "\xff"}
	for s in misses {
		b := transmute([]u8)s
		p := raw_data(b)
		text, q := spell.entity_prefix(p, p[len(b):])
		testing.expectf(t, text == nil && q == p, "%q: got (%q, +%d), want (nil, +0)", s, string(text), int(intrinsics.ptr_sub(q, p)))
	}
}
