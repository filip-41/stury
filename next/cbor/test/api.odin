package cbor_tests

import "core:testing"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:testkit"

// A program that reads CBOR imports `cbor` alone: validate, build and read a document, find a value with no document,
// scan the values paths reach, read a tag and a bignum, read the records of a sequence, read in pieces and on a runner,
// take the options of the format, and tell a fault from an answer.

// {"name": "stury", "tags": ["a", "b"], "size": 12, "when": 0("2013-03-21T20:04:00Z"), "big": 2(h'010000000000000000')}
@(private = "file")
SRC := []u8 {
	0xa5, 0x64, 'n', 'a', 'm', 'e', 0x65, 's', 't', 'u', 'r', 'y',
	0x64, 't', 'a', 'g', 's', 0x82, 0x61, 'a', 0x61, 'b',
	0x64, 's', 'i', 'z', 'e', 0x0c,
	0x64, 'w', 'h', 'e', 'n', 0xc0, 0x74, '2', '0', '1', '3', '-', '0', '3', '-', '2', '1', 'T', '2', '0', ':', '0', '4', ':', '0', '0', 'Z',
	0x63, 'b', 'i', 'g', 0xc2, 0x49, 0x01, 0, 0, 0, 0, 0, 0, 0, 0,
}

@(test)
cbor_alone_serves_a_program :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, cbor.validate(SRC), nil)
	doc, err := cbor.build(SRC)
	defer cbor.destroy(&doc)
	testing.expect_value(t, err, nil)
	r := cbor.Reader{&doc, nil}
	at, p := cbor.member(r, cbor.ROOT, "name")
	buf: [32]u8
	name, ok := cbor.node_text(&doc, at, buf[:])
	testing.expect(t, p == .Found && ok && name == "stury")
	tags, _ := cbor.member(r, cbor.ROOT, "tags")
	n, _, _ := cbor.length(r, tags, context.allocator)
	testing.expect_value(t, n, 2)
	// A tag is a fact of its value, and a bignum's text is every digit of its value.
	when_at, _ := cbor.member(r, cbor.ROOT, "when")
	big_at, _ := cbor.member(r, cbor.ROOT, "big")
	tag_numbers: [2]u64
	for f in doc.facts {
		number, is_number := cbor.fact_number(&doc, f)
		testing.expect(t, is_number && f.kind == .Tag)
		tag_numbers[0 if f.node == when_at else 1] = number.bits
	}
	testing.expect_value(t, len(doc.facts), 2)
	testing.expect_value(t, tag_numbers, [2]u64{0, 2})
	digits, digits_ok := cbor.node_text(&doc, big_at, buf[:])
	testing.expect(t, digits_ok && digits == "18446744073709551616")
}

@(test)
cbor_alone_finds_and_scans :: proc(t: ^testing.T) {
	testkit.deadline(t)
	buf: [16]u8
	a, ferr := cbor.find(SRC, []cbor.Step{cbor.Name("size")})
	size, is_number := cbor.node_number(cbor.as(.Cbor), SRC, cbor.answer_node(a))
	testing.expect(t, ferr == nil && a.outcome == .Found && is_number && size == cbor.Number{12, .Int})
	d, derr := cbor.demand_of({{cbor.Name("tags"), cbor.Index(-1)}})
	defer cbor.destroy(&d)
	s, serr := cbor.scan(SRC, &d)
	defer cbor.destroy(&s)
	last, lp, has := cbor.answer({&s, nil}, 0, 0)
	text, _ := cbor.node_text(&s, last, buf[:])
	testing.expect(t, derr == nil && serr == nil && has && lp == .Found && text == "b")
}

@(test)
cbor_alone_reads_records_and_pieces :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Three items one after another, the last cut short.
	seq := []u8{0x01, 0x82, 0x02, 0x03, 0x61}
	records := cbor.records_open(seq)
	out: [8]cbor.Record
	testing.expect_value(t, cbor.records_validate(&records, out[:]), 2)
	testing.expect_value(t, out[1].lo, 1)
	_, truncated := records.err.(cbor.Fault)
	testing.expect(t, truncated)
	pieces := cbor.Pieces {
		allocator = context.allocator,
	}
	defer cbor.destroy(&pieces)
	opts := cbor.Options {
		pieces = &pieces,
	}
	for from := 0; from < len(SRC); from += 9 {
		to := min(from + 9, len(SRC))
		pieces.last = to == len(SRC)
		testing.expect_value(t, cbor.validate(SRC[:to], .Cbor, opts), nil)
	}
	testing.expect(t, !pieces.more)
}

@(test)
cbor_alone_builds_on_a_runner_with_a_format_of_its_own :: proc(t: ^testing.T) {
	testkit.deadline(t)
	runner := testkit.serial_runner(3)
	opts := cbor.Options {
		format = cbor.Cbor_Options{},
		runner = &runner,
	}
	items := make([dynamic]u8, context.temp_allocator)
	defer free_all(context.temp_allocator)
	append(&items, 0x9f)
	for k in 0 ..< 200 {
		append(&items, 0x82, 0x18, u8(k), 0x61, 'x')
	}
	append(&items, 0xff)
	doc, err := cbor.build(items[:], .Cbor, opts)
	defer cbor.destroy(&doc)
	testing.expect_value(t, err, nil)
	r := cbor.Reader{&doc, nil}
	n, _, _ := cbor.length(r, cbor.ROOT, context.allocator)
	testing.expect_value(t, n, 200)
}

@(test)
cbor_alone_tells_a_fault_from_an_answer :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// A fault past a line feed byte is placed by its offset, not by a line and column.
	src := []u8{0x82, 0x0a, 0x01, 0x02}
	_, bad := cbor.build(src)
	fault, faulted := bad.(cbor.Fault)
	testing.expect(t, faulted && fault.kind == .Bad_Char && fault.at == 3)
	msg: [64]u8
	testing.expect_value(t, cbor.error_message(msg[:], bad, src), "byte 3: Bytes after the item")
	_, other := cbor.build(src, .Cbor, {format = tape.Dsv_Options{}})
	testing.expect_value(t, other, cbor.Error(cbor.Bad_Option{"format"}))
	_, refused := cbor.find(SRC, []cbor.Step{cbor.Name("size")}, .Cbor, {}, {dups = .Refuse})
	option, is_option := refused.(cbor.Bad_Option)
	testing.expect(t, is_option && option.option == "dups")
}
