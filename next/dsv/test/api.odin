package dsv_tests

import "core:testing"
import "stury:dsv"
import "stury:testkit"

// A program that reads a delimited text imports `dsv` alone: validate, build and read cells by key and by place, find a
// cell with no document, scan the cells paths reach, read the records, read in pieces and on a runner, take the options
// of the format, and tell a fault from an answer.

@(private = "file")
SRC :: "name,qty\nbolt,12\n# note\n\"a,b\",3\n"

@(private = "file")
OPTS :: dsv.Options {
	format = dsv.Dsv_Options{comment = '#'},
}

@(test)
dsv_alone_serves_a_program :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(SRC)
	testing.expect_value(t, dsv.validate(src, .Csv, OPTS), nil)
	doc, err := dsv.build(src, .Csv, OPTS)
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	r := dsv.Reader{&doc, nil}
	buf: [16]u8
	n, _, _ := dsv.length(r, dsv.ROOT, context.allocator)
	testing.expect_value(t, n, 2)
	row, _ := dsv.element(r, dsv.ROOT, 1)
	cell, p := dsv.member(r, row, "name")
	text, ok := dsv.node_text(&doc, cell, buf[:])
	testing.expect(t, p == .Found && ok && text == "a,b")
	wrong, wp := dsv.element(r, row, 1)
	testing.expect(t, wp == .Wrong_Kind && wrong == dsv.NO_NODE)
	qty, _ := dsv.member(r, row, "qty")
	qty_text, _ := dsv.node_text(&doc, qty, buf[:])
	testing.expect_value(t, qty_text, "3")
}

@(test)
dsv_alone_finds_and_scans :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(SRC)
	inferred := dsv.Options {
		format = dsv.Dsv_Options{comment = '#', infer = true},
	}
	a, ferr := dsv.find(src, []dsv.Step{dsv.Index(0), dsv.Name("qty")}, .Csv, {}, inferred)
	size, is_number := dsv.node_number(dsv.as(.Csv), src, dsv.answer_node(a))
	testing.expect(t, ferr == nil && a.outcome == .Found && is_number && size == dsv.Number{12, .Int})
	d, derr := dsv.demand_of({{dsv.Index(-1), dsv.Name("name")}})
	defer dsv.destroy(&d)
	s, serr := dsv.scan(src, &d, .Csv, {stop_early = true}, OPTS)
	defer dsv.destroy(&s)
	buf: [16]u8
	last, lp, has := dsv.answer({&s, nil}, 0, 0)
	text, _ := dsv.node_text(&s, last, buf[:])
	testing.expect(t, derr == nil && serr == nil && has && lp == .Found && text == "a,b")
}

@(test)
dsv_alone_reads_records_and_pieces :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(SRC)
	records := dsv.records_open(src, .Lines, .Csv, OPTS)
	out: [8]dsv.Record
	testing.expect_value(t, dsv.records_validate(&records, out[:]), 2)
	testing.expect_value(t, records.err, nil)
	pieces := dsv.Pieces {
		allocator = context.allocator,
	}
	defer dsv.destroy(&pieces)
	opts := OPTS
	opts.pieces = &pieces
	for from := 0; from < len(src); from += 7 {
		to := min(from + 7, len(src))
		pieces.last = to == len(src)
		testing.expect_value(t, dsv.validate(src[:to], .Csv, opts), nil)
	}
	testing.expect(t, !pieces.more)
}

@(test)
dsv_alone_builds_on_a_runner_with_a_format_of_its_own :: proc(t: ^testing.T) {
	testkit.deadline(t)
	runner := dsv.Runner {
		threads = 3,
		start = proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) {},
		finish = proc(data: rawptr) {},
	}
	src := transmute([]u8)string("; c\na|b\nc|d\ne|f\n")
	opts := dsv.Options {
		format = dsv.Dsv_Options{delimiter = '|', comment = ';', no_header = true},
		runner = &runner,
	}
	doc, err := dsv.build(src, .Plain, opts)
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	r := dsv.Reader{&doc, nil}
	row, _ := dsv.element(r, dsv.ROOT, 1)
	cell, p := dsv.element(r, row, 1)
	buf: [8]u8
	text, _ := dsv.node_text(&doc, cell, buf[:])
	testing.expect(t, p == .Found && text == "d")
}

@(test)
dsv_alone_tells_a_fault_from_an_answer :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a,b\n\"x,1\n")
	_, bad := dsv.build(src)
	fault, faulted := bad.(dsv.Fault)
	testing.expect(t, faulted && fault.kind == .Truncated && fault.at == 4)
	msg: [64]u8
	testing.expect_value(t, dsv.error_message(msg[:], bad, src), "2:1: Unfinished quoted field")
	_, refused := dsv.build(src, .Csv, {format = dsv.Dsv_Options{delimiter = '"'}})
	option, is_option := refused.(dsv.Bad_Option)
	testing.expect(t, is_option && option.option == "delimiter")
}
