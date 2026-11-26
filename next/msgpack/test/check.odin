package msgpack_tests

import "core:testing"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"
import "stury:msgpack"
import "stury:testkit"

// Streaming `msgpack.check` vs `check.check_document(msgpack.build)` parity across `.Msgpack` and `.Compact`.

@(test)
test_msgpack_check_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)
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

	// {"id": 42, "tag": "go", "ok": true}
	valid_bytes := []u8 {
		0x83,
		0xa2, 'i', 'd', 0x2a,
		0xa3, 't', 'a', 'g', 0xa2, 'g', 'o',
		0xa2, 'o', 'k', 0xc3,
	}
	// {"id": -1, "tag": "go", "ok": true}
	bad_min_bytes := []u8 {
		0x83,
		0xa2, 'i', 'd', 0xff,
		0xa3, 't', 'a', 'g', 0xa2, 'g', 'o',
		0xa2, 'o', 'k', 0xc3,
	}
	// {"id": 5, "tag": "x", "ok": false}
	bad_len_bytes := []u8 {
		0x83,
		0xa2, 'i', 'd', 0x05,
		0xa3, 't', 'a', 'g', 0xa1, 'x',
		0xa2, 'o', 'k', 0xc2,
	}

	Case :: struct {
		bytes: []u8,
		valid: bool,
	}
	cases := [?]Case {
		{valid_bytes, true},
		{bad_min_bytes, false},
		{bad_len_bytes, false},
	}

	for c in cases {
		for spec in msgpack.Spec {
			r_s := msgpack.check(c.bytes, &plan, spec)
			defer check.result_destroy(&r_s)
			testing.expectf(t, r_s.valid == c.valid, "msgpack stream %v: got %v want %v", spec, r_s.valid, c.valid)

			sink_s: check.Sink
			check.sink_init(&sink_s)
			defer check.sink_destroy(&sink_s)
			r_ss := msgpack.check(c.bytes, &plan, spec, {}, &sink_s)
			defer check.result_destroy(&r_ss)
			testing.expect_value(t, r_ss.valid, c.valid)

			doc, berr := msgpack.build(c.bytes, spec)
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

	// Refused duplicate keys & bad spec option check.
	dup := []u8{0x83, 0xa2, 'i', 'd', 0x01, 0xa2, 'i', 'd', 0x02, 0xa3, 't', 'a', 'g', 0xa2, 'g', 'o', 0xa2, 'o', 'k', 0xc3}
	r_dup := msgpack.check(dup, &plan, .Compact, {dups = .Refuse})
	defer check.result_destroy(&r_dup)
	testing.expect(t, !r_dup.valid)

	r_bad_spec := msgpack.check(valid_bytes, &plan, msgpack.Spec(99))
	defer check.result_destroy(&r_bad_spec)
	testing.expect(t, !r_bad_spec.valid && r_bad_spec.err.kind == .Bad_Option)
}
