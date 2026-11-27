package msgpack_tests

import "core:testing"
import "stury:lib/core/tape"
import "stury:msgpack"
import "stury:testkit"

// Standalone caller tests importing `stury:msgpack` alone: validate, build, find, scan, facts
// (ext and timestamp), records, pieces, parallel runner builds, and fault reporting.

// {"name": "stury", "tags": ["a", "b"], "size": 12, "when": ts(1363896240), "raw": ext(42, 0xdeadbeef)}
@(private = "file")
SRC := []u8 {
	0x85,
	0xa4, 'n', 'a', 'm', 'e', 0xa5, 's', 't', 'u', 'r', 'y',
	0xa4, 't', 'a', 'g', 's', 0x92, 0xa1, 'a', 0xa1, 'b',
	0xa4, 's', 'i', 'z', 'e', 0x0c,
	0xa4, 'w', 'h', 'e', 'n', 0xd6, 0xff, 0x51, 0x4b, 0x67, 0xb0,
	0xa3, 'r', 'a', 'w', 0xd6, 42, 0xde, 0xad, 0xbe, 0xef,
}

@(test)
msgpack_alone_serves_a_program :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, msgpack.validate(SRC), nil)
	doc, err := msgpack.build(SRC)
	defer msgpack.destroy(&doc)
	testing.expect_value(t, err, nil)

	r := msgpack.Reader{&doc, nil}
	at, p := msgpack.member(r, msgpack.ROOT, "name")
	buf: [48]u8
	name, ok := msgpack.node_text(&doc, at, buf[:])
	testing.expect(t, p == .Found && ok && name == "stury")

	tags, _ := msgpack.member(r, msgpack.ROOT, "tags")
	n, _, _ := msgpack.length(r, tags, context.allocator)
	testing.expect_value(t, n, 2)

	when_at, _ := msgpack.member(r, msgpack.ROOT, "when")
	raw_at, _ := msgpack.member(r, msgpack.ROOT, "raw")
	ts_text, ts_ok := msgpack.node_text(&doc, when_at, buf[:])
	testing.expectf(t, ts_ok && ts_text == "2013-03-21T20:04:00Z", "when = %q (%v)", ts_text, ts_ok)
	dt_name, dt_named := msgpack.fact_name(&doc, when_at, .Tag)
	testing.expect(t, dt_named && dt_name == "datetime")
	raw_bytes := msgpack.span_bytes(&doc, doc.nodes[raw_at].lo, doc.nodes[raw_at].n)
	testing.expect_value(t, string(raw_bytes), "\xde\xad\xbe\xef")

	testing.expect_value(t, len(doc.facts), 2)
	tag_vals: [2]i64
	for f in doc.facts {
		num, is_num := msgpack.fact_number(&doc, f)
		testing.expect(t, is_num && f.kind == .Tag)
		tag_vals[0 if f.node == when_at else 1] = i64(num.bits)
	}
	testing.expect_value(t, tag_vals, [2]i64{-1, 42})
}

@(test)
msgpack_alone_finds_and_scans :: proc(t: ^testing.T) {
	testkit.deadline(t)
	buf: [16]u8
	a, ferr := msgpack.find(SRC, []msgpack.Step{msgpack.Name("size")})
	size, is_number := msgpack.node_number(msgpack.as(.Msgpack), SRC, msgpack.answer_node(a))
	testing.expect(t, ferr == nil && a.outcome == .Found && is_number && size == msgpack.Number{12, .Int})

	d, derr := msgpack.demand_of({{msgpack.Name("tags"), msgpack.Index(-1)}})
	defer msgpack.destroy(&d)
	s, serr := msgpack.scan(SRC, &d)
	defer msgpack.destroy(&s)
	last, lp, has := msgpack.answer({&s, nil}, 0, 0)
	text, _ := msgpack.node_text(&s, last, buf[:])
	testing.expect(t, derr == nil && serr == nil && has && lp == .Found && text == "b")
}

@(test)
msgpack_alone_reads_records_and_pieces :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Three items concatenated, last cut short.
	seq := []u8{0x01, 0x92, 0x02, 0x03, 0xa1}
	records := msgpack.records_open(seq)
	out: [8]msgpack.Record
	testing.expect_value(t, msgpack.records_validate(&records, out[:]), 0)
	testing.expect_value(t, records.index, 2)
	_, truncated := records.err.(msgpack.Fault)
	testing.expect(t, truncated)

	pieces := msgpack.Pieces{allocator = context.allocator}
	defer msgpack.destroy(&pieces)
	opts := msgpack.Options{pieces = &pieces}
	for from := 0; from < len(SRC); from += 9 {
		to := min(from + 9, len(SRC))
		pieces.last = to == len(SRC)
		testing.expect_value(t, msgpack.validate(SRC[:to], .Msgpack, opts), nil)
	}
	testing.expect(t, !pieces.more)
}

@(test)
msgpack_alone_builds_on_a_runner :: proc(t: ^testing.T) {
	testkit.deadline(t)
	runner := testkit.serial_runner(3)
	opts := msgpack.Options{runner = &runner}
	items := make([dynamic]u8, context.temp_allocator)
	defer free_all(context.temp_allocator)
	append(&items, 0xdc, 0x00, 200)
	for k in 0 ..< 200 {
		append(&items, 0x92, 0xcc, u8(k), 0xa1, 'x')
	}
	doc, err := msgpack.build(items[:], .Msgpack, opts)
	defer msgpack.destroy(&doc)
	testing.expect_value(t, err, nil)
	r := msgpack.Reader{&doc, nil}
	n, _, _ := msgpack.length(r, msgpack.ROOT, context.allocator)
	testing.expect_value(t, n, 200)
}

@(test)
msgpack_alone_tells_a_fault_from_an_answer :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := []u8{0x92, 0x0a, 0x01, 0x02}
	_, bad := msgpack.build(src)
	fault, faulted := bad.(msgpack.Fault)
	testing.expect(t, faulted && fault.kind == .Bad_Char && fault.at == 3)
	msg: [64]u8
	testing.expect_value(t, msgpack.error_message(msg[:], bad, src), "byte 3: Trailing bytes after the item")
	_, other := msgpack.build(src, .Msgpack, {format = tape.Dsv_Options{}})
	testing.expect_value(t, other, msgpack.Error(msgpack.Bad_Option{"format"}))
	_, refused := msgpack.find(SRC, []msgpack.Step{msgpack.Name("size")}, .Msgpack, {}, {dups = .Refuse})
	option, is_option := refused.(msgpack.Bad_Option)
	testing.expect(t, is_option && option.option == "dups")
}
