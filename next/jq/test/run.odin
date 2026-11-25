package jq_tests

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"
import "stury:jq"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/css"
import "stury:lib/query"
import "stury:testkit"
import "stury:xml"

// The corpus run through the library: each program on its input, its outputs equal to the expected ones as jq's
// run-tests compares them, by value, and every block the run took given back.

Outputs :: struct {
	h:    ^query.Heap,
	vals: [dynamic]query.Value,
}

collect :: proc(data: rawptr, v: query.Value, h: ^query.Heap) -> bool {
	o := (^Outputs)(data)
	append(&o.vals, v)
	return len(o.vals) < 10_000
}

// `text` read as one JSON value, or as an XML document when it starts with `<`, or false.
read_value :: proc(h: ^query.Heap, text: string) -> (query.Value, bool) {
	src := transmute([]u8)strings.clone(text)
	doc: tape.Document
	err: tape.Error
	if strings.has_prefix(text, "<") {
		doc, err = xml.build(src, .Xml, {}, context.allocator)
	} else {
		doc, err = json.build(src, .Json, {}, context.allocator)
	}
	if err != nil {
		return query.NULL, false
	}
	v, s := query.document_value(h, doc, true)
	return v, s == .Ok
}

// `v` as compact JSON, in the context allocator.
show :: proc(h: ^query.Heap, v: query.Value) -> string {
	out := make([dynamic]u8)
	if query.write_json(h, &out, v) != .Ok {
		query.clear_error(h)
		return "<unwritable>"
	}
	return string(out[:])
}

Case_Result :: enum u8 {
	Pass,
	Skip,
	Fail,
	Pending, // calls a builtin not built yet
}

DIVERGENCES :: "jq/divergences.tsv"

// The ledger's entries by case, `file:line`, to their kind.
read_divergences :: proc() -> map[string]string {
	out := make(map[string]string)
	data, err := os.read_entire_file_from_path(DIVERGENCES, context.allocator)
	if err != nil {
		return out
	}
	for line in strings.split_lines(string(data)) {
		if line == "" || line[0] == '#' {
			continue
		}
		fields := strings.split(line, "\t")
		if len(fields) >= 2 {
			out[fields[0]] = fields[1]
		}
	}
	return out
}

// The hook `css` reads a document through: XML's attributes.
@(private)
xml_markup :: proc(data: rawptr, doc: ^tape.Document) -> (css.Options, bool) {
	return {attribute = xml.attribute}, doc.format == xml.as(.Xml)
}

@(private)
parse_json_hook :: proc(data: rawptr, src: []u8, budget: tape.Budget, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	return json.build(src, .Json, {budget = budget}, allocator)
}

// The hooks of every case: a clock at 2024-06-01T10:34:56.123Z, and random bytes that count up from 0 over the calls.
@(private)
fixed_now :: proc(data: rawptr) -> f64 {
	return 1717238096.123
}

@(private)
counted_bytes :: proc(data: rawptr, bytes: []u8) {
	calls := (^int)(data)
	for &b in bytes {
		b = u8(calls^)
		calls^ += 1
	}
}

// Runs case `c`, printing why it fails.
run_case :: proc(c: Case, report: bool) -> Case_Result {
	prog, errors := jq.compile(c.prog, {modules = corpus_modules()})
	defer jq.destroy_program(prog)
	if why := compile_mismatch(c, errors); why != "" {
		if report {
			fmt.printfln("%s:%d %s: %s", c.file, c.line, c.prog, why)
		}
		return .Fail
	}
	if c.fail != .None {
		return .Pass
	}
	h: query.Heap
	query.heap_init(&h, runtime.heap_allocator()) // not the suite's arena, which never gives a block back
	defer query.heap_destroy(&h)
	input, ok := read_value(&h, c.input)
	if !ok {
		return .Skip
	}
	run: jq.Run
	calls := 0
	hooks := jq.Hooks{data = &calls, now = fixed_now, random = counted_bytes, markup = xml_markup, parse_json = parse_json_hook}
	jq.run_init(&run, prog, &h, nil, &hooks, 10_000_000)
	outs := Outputs{h = &h}
	end := jq.run_value(&run, input, collect, &outs)
	msg := ""
	if end == .Failed {
		e := query.take_error(&h)
		msg = jq.error_message(&h, &e)
		query.destroy_error(&h, &e)
	}
	jq.run_destroy(&run)
	pending := strings.has_suffix(msg, " is not yet available")
	for v in outs.vals {
		pending ||= strings.contains(show(&h, v), " is not yet available")
	}
	if pending {
		for v in outs.vals {
			query.release(&h, v)
		}
		delete(outs.vals)
		return .Pending
	}
	result := Case_Result.Pass
	if len(outs.vals) != len(c.want) || (end == .Failed) != (c.err != "") && c.file == STRICT_SUITE || c.err != "" && msg != c.err {
		result = .Fail
	}
	for w, i in c.want {
		if i >= len(outs.vals) {
			break
		}
		x, xok := read_value(&h, w)
		if !xok {
			result = .Fail
			continue
		}
		eq, _ := query.equal(&h, outs.vals[i], x)
		// jq writes an infinity as the largest double, the library as null.
		if !eq {
			wide, _ := strings.replace_all(show(&h, x), "-1.7976931348623157e+308", "null")
			wide, _ = strings.replace_all(wide, "1.7976931348623157e+308", "null")
			eq = show(&h, outs.vals[i]) == wide
		}
		query.release(&h, x)
		if !eq {
			result = .Fail
		}
	}
	if result == .Fail && report {
		got := make([dynamic]string)
		for v in outs.vals {
			append(&got, show(&h, v))
		}
		fmt.printfln("%s:%d %s\n    input %s\n    want  %s\n    got   %s%s", c.file, c.line, c.prog, c.input, strings.join(c.want, " | "), strings.join(got[:], " | "), msg != "" ? strings.concatenate({"\n    error ", msg, "\n    want error ", c.err}) : "")
	}
	for v in outs.vals {
		query.release(&h, v)
	}
	delete(outs.vals)
	if live := query.heap_live(&h); live != 0 {
		if report {
			fmt.printfln("%s:%d %s: %d bytes not given back", c.file, c.line, c.prog, live)
		}
		result = .Fail
	}
	return result
}

@(test)
corpus_programs_give_jqs_outputs :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	counts: [Case_Result]int
	ledger := read_divergences()
	testing.expect(t, len(ledger) > 0, DIVERGENCES)
	unexpected, stale := 0, 0
	for name in SUITES {
		for c in read_suite(name) {
			when DEBUG_CASES {
				fmt.eprintln(c.file, c.line, c.prog)
			}
			key := fmt.aprintf("%s:%d", c.file, c.line)
			kind, listed := ledger[key]
			started := time.tick_now()
			result := run_case(c, !listed)
			if took := time.tick_since(started); took > 2 * time.Second {
				fmt.printfln("%s slow: %v", key, took)
			}
			counts[result] += 1
			switch {
			case result == .Fail && !listed:
				unexpected += 1
			case result == .Pass && listed && kind != "pending":
				fmt.printfln("%s: passes, but the ledger lists it", key)
				stale += 1
			}
		}
	}
	fmt.printfln("corpus: %d pass, %d fail (%d in the ledger), %d pending builtins, %d skipped", counts[.Pass], counts[.Fail], counts[.Fail] - unexpected, counts[.Pending], counts[.Skip])
	testing.expect_value(t, unexpected, 0)
	testing.expect_value(t, stale, 0)
}
