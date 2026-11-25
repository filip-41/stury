package cbor_tests

import "core:fmt"
import "core:slice"
import "core:testing"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:testkit"

// What the reads give: tags as facts, the values of numbers, the policy for repeated keys, the spans of find answers,
// and the hook protocol.

// A tag is a fact of the value after it, in a build and in a scan that keeps facts, and its number is the tag's.
@(test)
tags_are_facts_of_their_values :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := hex("a2 61 61 d9 d9f7 c1 1a 514b67b0 61 62 c2 49 010000000000000000")
	doc, err := cbor.build(src, allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(doc.facts), 3)
	testing.expect(t, doc.present == {.Tag})
	want := [?]struct {
		node: cbor.Node_Index,
		tag:  u64,
	}{{2, 55799}, {2, 1}, {4, 2}}
	for w, i in want {
		f := doc.facts[i]
		n := cbor.fact_number(&doc, f) or_continue
		testing.expectf(t, f.kind == .Tag && f.node == w.node && n.bits == w.tag, "fact %d: %v %v", i, f, n)
	}
	n, _ := cbor.node_number(&doc, 4)
	testing.expect_value(t, n, cbor.Number{transmute(u64)f64(18446744073709551616.0), .Float})
	demand, _ := tape.demand_of([][]tape.Step{{tape.Name("b")}}, facts = true, allocator = context.temp_allocator)
	part, serr := cbor.scan(src, &demand, allocator = context.temp_allocator)
	testing.expect_value(t, serr, nil)
	at, _, _ := cbor.answer({doc = &part}, 0, 0)
	testing.expect_value(t, len(part.facts), 1)
	testing.expect(t, part.facts[0].node == at && part.facts[0].kind == .Tag)
}

// A find answer's span holds the value's item: a string's head before its payload and an indefinite string's break.
@(test)
answers_span_their_items :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := hex("84 63 616263 5f 41 01 ff 9f 01 ff 18 64")
	for c in ([?]struct {
			index:          int,
			lo, hi:         u64,
			head, tail:     u8,
			kind:           cbor.Kind,
		}{{0, 1, 5, 1, 0, .String}, {1, 5, 9, 1, 1, .Bytes}, {2, 9, 12, 0, 0, .Array}, {3, 12, 14, 0, 0, .Number}}) {
		a, err := cbor.find(src, {tape.Index(c.index)})
		testing.expect_value(t, err, nil)
		testing.expectf(t, a.lo == c.lo && a.hi == c.hi && a.head == c.head && a.tail == c.tail && a.kind == c.kind, "%d: %v", c.index, a)
	}
	a, _ := cbor.find(src, {tape.Index(0)})
	node := cbor.answer_node(a)
	buf: [8]u8
	s, _ := cbor.node_text(cbor.as(.Cbor), src, node, buf[:])
	testing.expect_value(t, s, "abc")
}

// A container closes where its last item and its break end, the break of an indefinite container counted.
@(test)
containers_keep_their_style :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := hex("82 9f 01 bf 61 61 80 ff ff a0")
	doc, err := cbor.build(src, allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	ends := [?]struct {
		at:  cbor.Node_Index,
		end: u64,
	}{{0, 10}, {1, 9}, {3, 8}, {5, 7}, {6, 10}}
	for e in ends {
		end, ok := cbor.as(.Cbor).close_end(&doc, e.at)
		testing.expectf(t, ok && end == e.end, "close of %d: %d", e.at, end)
	}
}

// Every read refuses any family's options.
@(test)
reads_refuse_options_they_cannot_take :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := hex("01")
	other := tape.Error(tape.Bad_Option{"format"})
	testing.expect_value(t, cbor.validate(src, .Cbor, {format = tape.Dsv_Options{}}), other)
	_, berr := cbor.build(src, .Cbor, {format = tape.Dsv_Options{}}, context.temp_allocator)
	testing.expect_value(t, berr, other)
	testing.expect_value(t, cbor.records_open(src, .Concatenated, .Cbor, {format = tape.Dsv_Options{}}).err, other)
	_, err := cbor.build(src, .Cbor, {dups = .Refuse}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, cbor.validate(src, .Cbor, {dups = .Refuse}), tape.Error(tape.Bad_Option{"dups"}))
}

// The tags on a node are its facts in the order they were written, the last the nearest, each with its number whole up
// to the largest a head holds.
@(test)
tag_facts_give_the_tag_numbers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := [?]struct {
		text: string,
		tags: []u64,
	} {
		{"c0 74 323031332d30332d32315432303a30343a30305a", {0}},
		{"d9 03ec 6a 323031332d30332d3231", {1004}},
		{"d9 03ec c1 1a 514b67b0", {1004, 1}},
		{"1b ffffffffffffffff", {}},
		{"db ffffffffffffffff 01", {max(u64)}},
	}
	for c in cases {
		doc, err := cbor.build(hex(c.text))
		defer cbor.destroy(&doc)
		if !testing.expectf(t, err == nil, "%s: %v", c.text, err) {
			continue
		}
		got := make([dynamic]u64, context.temp_allocator)
		for f in doc.facts {
			if f.node == cbor.ROOT && f.kind == .Tag {
				n, _ := tape.fact_number(&doc, f)
				append(&got, n.bits)
			}
		}
		testing.expectf(t, slice.equal(got[:], c.tags), "%s: %v, want %v", c.text, got[:], c.tags)
	}
}

// A path read answers from the item without building what it passes: the answer is the value at the path, whatever
// precedes it, and a passed value that is ill-formed still faults.
@(test)
skipping_reads_the_answer :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := hex("a3 61 62 82 01 02 61 61 a1 01 f5 61 63 7f 61 78 ff")
	path := []tape.Step{tape.Name("a"), tape.Name("1")}
	answer, err := cbor.find(src, path, allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, answer.outcome, tape.Presence.Found)
	testing.expect_value(t, answer.kind, cbor.Kind.True)
	demand, _ := tape.demand_of([][]tape.Step{path}, allocator = context.temp_allocator)
	doc, serr := cbor.scan(src, &demand, allocator = context.temp_allocator)
	testing.expect_value(t, serr, nil)
	testing.expect(t, len(doc.nodes) < 8, "the passed values are not nodes")

	tail := hex("82 01 ff")
	early, early_err := cbor.find(tail, {tape.Index(0)}, .Cbor, {stop_early = true})
	testing.expect_value(t, early_err, nil)
	testing.expect_value(t, early.outcome, tape.Presence.Found)
	_, whole_err := cbor.find(tail, {tape.Index(0)})
	testing.expect(t, whole_err != nil, "without stop_early the bytes past the answer are judged")

	bad := hex("a2 61 62 61 c3 61 61 01")
	_, bad_err := cbor.find(bad, {tape.Name("a")})
	testing.expect(t, bad_err != nil)
	_, cut_err := cbor.find(bad[:3], {tape.Name("b")}, .Cbor, {stop_early = true})
	testing.expect(t, cut_err != nil)
}

// An indefinite string of one short chunk reads as the same string in two chunks, in bytes, in ASCII and in text that is
// not, whether thirty more bytes follow it or the text ends at its break.
@(test)
one_chunk_strings_read_as_chunked_ones :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for major in ([]u8{2, 3}) {
		for content in ([]string{"", "a", "stury", "0123456789abcdef", "0123456789abcdefghijklm", "0123456789abcdefghijklmn", "h\u00e9llo", "\u20ac\u20ac\u20ac\u20ac\u20ac\u20ac\u20ac\u20ac"}) {
			for padded in ([]bool{false, true}) {
				name := fmt.tprintf("major %d, %q, padded %v", major, content, padded)
				read :: proc(major: u8, content: string, chunks: int, padded: bool) -> []u8 {
					text := make([dynamic]u8, context.temp_allocator)
					append(&text, 0x98, 31 if padded else 1)
					append(&text, major << 5 | 31)
					for _ in 1 ..< chunks {
						append(&text, major << 5 | 0)
					}
					if len(content) < 24 {
						append(&text, major << 5 | u8(len(content)))
					} else {
						append(&text, major << 5 | 24, u8(len(content)))
					}
					append(&text, content)
					append(&text, 0xff)
					for _ in 0 ..< (30 if padded else 0) {
						append(&text, 0x00)
					}
					return text[:]
				}
				doc, err := cbor.build(read(major, content, 1, padded), allocator = context.temp_allocator)
				ref, rerr := cbor.build(read(major, content, 2, padded), allocator = context.temp_allocator)
				testing.expectf(t, err == nil && rerr == nil, "%s: %v %v", name, err, rerr)
				if err != nil || rerr != nil {
					continue
				}
				testing.expectf(t, doc.nodes[1].kind == ref.nodes[1].kind && doc.nodes[1].n + 1 == ref.nodes[1].n, "%s: %v %v", name, doc.nodes[1], ref.nodes[1])
				got, ok := text_of(&doc, 1)
				want, wok := text_of(&ref, 1)
				testing.expectf(t, ok && wok && got == want, "%s: %q against %q", name, got, want)
			}
		}
	}
}
