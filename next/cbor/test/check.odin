// Streaming `cbor.check` vs `check.check_document(cbor.build)` parity across CBOR binary encodings.
package cbor_tests

import "core:testing"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"
import "stury:testkit"

@(test)
test_cbor_check_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Schema: {id: integer >= 1, tag: string minLength 2, ok: boolean}
	d: rules.Description
	d.allocator = context.allocator
	defer rules.description_destroy(&d)

	id_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Integer}, rules = {minimum = "1"}, array = -1, object = -1})
	tag_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.String}, rules = {min_length = 2}, array = -1, object = -1})
	ok_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Bool}, array = -1, object = -1})
	false_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {}, array = -1, object = -1})

	members := make([]rules.Member, 3)
	members[0] = {name = "id", node = id_n, required = true}
	members[1] = {name = "tag", node = tag_n, required = true}
	members[2] = {name = "ok", node = ok_n, required = true}
	append(&d.objects, rules.Object{members = members, additional = false_n, keys = rules.NONE})

	root := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = 0})
	d.root = root

	plan, cerr := check.compile(&d)
	testing.expect_value(t, cerr.kind, check.Error_Kind.None)
	defer check.plan_destroy(&plan)

	// Valid CBOR map: {"id": 42, "tag": "go", "ok": true}
	// A3 62 "id" 18 2A 63 "tag" 62 "go" 62 "ok" F5
	valid_bytes := [?]u8{
		0xA3,
		0x62, 'i', 'd', 0x18, 0x2A,
		0x63, 't', 'a', 'g', 0x62, 'g', 'o',
		0x62, 'o', 'k', 0xF5,
	}
	// Invalid CBOR map: {"id": -1, "tag": "go", "ok": true} (0x20 == -1)
	bad_min_bytes := [?]u8{
		0xA3,
		0x62, 'i', 'd', 0x20,
		0x63, 't', 'a', 'g', 0x62, 'g', 'o',
		0x62, 'o', 'k', 0xF5,
	}
	// Invalid CBOR map: {"id": 5, "tag": "x", "ok": false} (minLength 2 fail)
	bad_len_bytes := [?]u8{
		0xA3,
		0x62, 'i', 'd', 0x05,
		0x63, 't', 'a', 'g', 0x61, 'x',
		0x62, 'o', 'k', 0xF4,
	}

	Case :: struct {
		bytes: []u8,
		valid: bool,
	}
	cases := [?]Case{
		{valid_bytes[:], true},
		{bad_min_bytes[:], false},
		{bad_len_bytes[:], false},
	}

	for c in cases {
		for spec in ([?]cbor.Spec{.Cbor, .Preferred}) {
			r_s := cbor.check(c.bytes, &plan, spec)
			defer check.result_destroy(&r_s)
			testing.expectf(t, r_s.valid == c.valid, "cbor stream %v: got %v want %v", spec, r_s.valid, c.valid)

			sink_s: check.Sink
			check.sink_init(&sink_s)
			defer check.sink_destroy(&sink_s)
			r_ss := cbor.check(c.bytes, &plan, spec, {}, &sink_s)
			defer check.result_destroy(&r_ss)
			testing.expect_value(t, r_ss.valid, c.valid)

			doc, berr := cbor.build(c.bytes, spec)
			testing.expect_value(t, berr, nil)
			defer tape.destroy(&doc)

			r_d := check.check_document(&doc, &plan)
			defer check.result_destroy(&r_d)
			testing.expect_value(t, r_d.valid, c.valid)

			sink_d: check.Sink
			check.sink_init(&sink_d)
			defer check.sink_destroy(&sink_d)
			r_ds := check.check_document(&doc, &plan, {}, &sink_d)
			defer check.result_destroy(&r_ds)
			testing.expect_value(t, r_ds.valid, c.valid)
			testing.expect_value(t, len(sink_s.entries), len(sink_d.entries))
		}
	}
}
