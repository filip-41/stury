package cbor_tests

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "stury:cbor"
import stury_json "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// The writer's laws: every item of RFC 8949 Appendix A and of the bench fixtures that the writer can write reads back
// as the same values and tags, in each spec, and a write in pieces is the same item. And the items v1 writes of the
// same values are the items written here.

@(test)
appendix_a_items_write_and_read_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	table, _ := json.parse(transmute([]u8)APPENDIX_A, allocator = context.temp_allocator)
	written := 0
	for row in table.(json.Array) {
		text := row.(json.Object)["hex"].(json.String)
		if text == SIMPLE_24 {
			continue
		}
		doc, err := cbor.build(hex(text), .Cbor, allocator = context.temp_allocator)
		if err != nil {
			continue
		}
		for spec in cbor.Spec {
			item, _, werr := cbor.write(&doc, spec, allocator = context.temp_allocator)
			if werr != nil {
				// A simple value or a number with no spelling in the spec's keys is refused.
				continue
			}
			written += 1
			testing.expectf(t, cbor.validate(item, spec) == nil, "%s under %v: % x", text, spec, item)
			back, berr := cbor.build(item, spec, allocator = context.temp_allocator)
			if !testing.expectf(t, berr == nil, "%s under %v: %v", text, spec, berr) {
				continue
			}
			// A deterministic spec writes a map's members in the order of their keys.
			if spec == .Cbor || spec == .Preferred {
				testkit.values_agree(t, &doc, tape.ROOT, &back, tape.ROOT, {number_values = true, facts = {.Tag}}, text)
			}
		}
	}
	testing.expect(t, written > 200)
}

@(test)
fixture_items_write_and_read_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for name in ([?]string{"citm.cbor", "logs.cbor", "twitter.cbor"}) {
		src, err := os.read_entire_file_from_path(strings.concatenate({FIXTURES, name}, context.temp_allocator), context.temp_allocator)
		if err != nil {
			continue
		}
		doc, derr := cbor.build(src, .Cbor, allocator = context.temp_allocator)
		if !testing.expectf(t, derr == nil, "%s: %v", name, derr) {
			continue
		}
		item, _, werr := cbor.write(&doc, .Preferred, allocator = context.temp_allocator)
		if !testing.expectf(t, werr == nil, "%s: %v", name, werr) {
			continue
		}
		back, berr := cbor.build(item, .Preferred, allocator = context.temp_allocator)
		testing.expectf(t, berr == nil, "%s: %v", name, berr)
		testkit.values_agree(t, &doc, tape.ROOT, &back, tape.ROOT, {number_values = true, facts = {.Tag}}, name)
	}
}

// The fixtures the benches read, where a checkout holds them.
@(private = "file")
FIXTURES :: #directory + "../../../bench/fixtures/"

// The items v1 writes of `{"a":[1,-1,24,256,65536,4294967296,1.5,1e300],"b":"é","c":[true,false,null]}` and of an array
// of three objects, which `stury --to cbor .` of v1 gives.
@(test)
the_items_are_v1s :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := [?]struct {
		json, hex: string,
	}{
		{`{"a":[1,-1,24,256,65536,4294967296,1.5,1e300],"b":"é","c":[true,false,null]}`, "a3 6161 88 01 20 1818 190100 1a00010000 1b0000000100000000 f93e00 fb7e37e43c8800759c 6162 62c3a9 6163 83f5f4f6"},
		{`[{"a":1,"b":"x,y"},{"a":2.5,"b":"q\"r"},{"a":true,"b":null}]`, "83 a2 6161 01 6162 63782c79 a2 6161 f94100 6162 63712272 a2 6161 f5 6162 f6"},
	}
	for c, k in cases {
		doc, err := stury_json.build(transmute([]u8)c.json)
		defer stury_json.destroy(&doc)
		testing.expect(t, err == nil)
		item, _, werr := cbor.write(&doc)
		defer delete(item)
		testing.expectf(t, werr == nil && string(item) == string(hex(c.hex)), "%d: %v % x", k, werr, item)
	}
}

// A write into a sink that takes a few bytes at a time is the item a buffer holds, for any size of piece.
@(test)
a_write_in_pieces_is_the_same_item :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	table, _ := json.parse(transmute([]u8)APPENDIX_A, allocator = context.temp_allocator)
	for row in table.(json.Array) {
		text := row.(json.Object)["hex"].(json.String)
		if text == SIMPLE_24 {
			continue
		}
		doc, err := cbor.build(hex(text), .Cbor, allocator = context.temp_allocator)
		if err != nil {
			continue
		}
		want, _, werr := cbor.write(&doc, .Cbor, allocator = context.temp_allocator)
		if werr != nil {
			continue
		}
		for limit in ([?]int{1, 3, 7}) {
			c: testkit.Chunked
			defer testkit.chunked_destroy(&c)
			_, serr := cbor.write_to(testkit.chunked_sink(&c, limit), &doc)
			testing.expectf(t, serr == nil && string(c.taken[:]) == string(want), "%s in pieces of %d: %v % x", text, limit, serr, c.taken)
			// The tokens of the same document, written into a sink in pieces, are an item that reads as the values.
			w: cbor.Writer
			c2: testkit.Chunked
			defer testkit.chunked_destroy(&c2)
			testing.expect(t, cbor.writer_start(&w, {}, testkit.chunked_sink(&c2, limit), context.temp_allocator) == nil)
			// A float that is no number has no token.
			if cbor.put(&w, &doc) != nil {
				_, _ = cbor.writer_end(&w)
				continue
			}
			_, eerr := cbor.writer_end(&w)
			testing.expectf(t, eerr == nil, "%s: %v", text, eerr)
			_, berr := cbor.build(c2.taken[:], .Cbor, allocator = context.temp_allocator)
			testing.expectf(t, berr == nil, "%s: %v % x", text, berr, c2.taken)
		}
	}
}
