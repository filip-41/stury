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

DEBUG_CASES :: #config(DEBUG_CASES, false)

// The message jq prints last for a program that does not compile: its last error's first line.
last_message :: proc(errors: []jq.Compile_Error) -> string {
	located := jq.locate(errors[len(errors) - 1])
	first, _, _ := strings.partition(located, "\n")
	return strings.concatenate({"jq: error: ", first})
}

// Why compiling case `c`'s program gave `errors` and not what jq gives, "" when it did: no error for a program that
// compiles, an error for one that must not, and jq's message where the case has one.
compile_mismatch :: proc(c: Case, errors: []jq.Compile_Error) -> string {
	switch {
	case c.fail == .None && len(errors) > 0:
		return last_message(errors)
	case c.fail != .None && len(errors) == 0:
		return "compiled"
	case c.fail == .Message && last_message(errors) != c.msg:
		return fmt.aprintf("%q, want %q", last_message(errors), c.msg)
	}
	return ""
}

Eval_Options :: struct {
	input_json:        string,
	doc:               ^tape.Document,
	modules:           jq.Modules,
	variables:         []string,
	globals:           []string,
	prepend_env:       bool,
	with_joins:        bool,
	hooks:             ^jq.Hooks,
	steps:             int,
	mem_limit:         u64,
	write_fact:        query.Fact_Writer,
	write_fact_data:   rawptr,
	sep:               string,
	allow_compile_err: bool,
	append_err:        bool,
}

Eval_Result :: struct {
	out:         string,
	end:         jq.Run_End,
	err_kind:    query.Error_Kind,
	err_msg:     string,
	compile_err: string,
	tainted:     bool,
}

// Shared jq evaluator for tests running under a suite arena: compiles `src`, binds any globals and input (from `doc`,
// `input_json`, or null), runs with `opts`, verifies zero heap leaks on `runtime.heap_allocator()`, and joins outputs.
eval_jq :: proc(t: ^testing.T, src: string, opts := Eval_Options{}, loc := #caller_location) -> Eval_Result {
	compile_opts := jq.Compile_Options{modules = opts.modules, variables = opts.variables}
	prog: ^jq.Program
	errors: []jq.Compile_Error
	if opts.with_joins {
		prog, errors = jq.compile_with_joins(src, compile_opts)
	} else {
		prog, errors = jq.compile(src, compile_opts)
	}
	defer jq.destroy_program(prog)
	if len(errors) > 0 {
		msg := last_message(errors)
		if !opts.allow_compile_err {
			testing.expectf(t, false, "compile %q failed: %s", src, msg, loc = loc)
		}
		return {end = .Failed, compile_err = msg}
	}

	h: query.Heap
	query.heap_init(&h, runtime.heap_allocator(), opts.mem_limit)
	defer query.heap_destroy(&h)
	h.write_fact = opts.write_fact
	h.write_fact_data = opts.write_fact_data

	res: Eval_Result
	shown := make([dynamic]string)
	{
		vals: []query.Value
		if len(opts.globals) > 0 || opts.prepend_env {
			base := 2 if opts.prepend_env else 0
			vals = make([]query.Value, base + len(opts.globals))
			for i in 0 ..< base {
				vals[i] = query.NULL
			}
			for text, i in opts.globals {
				v, ok := read_value(&h, text)
				if !testing.expectf(t, ok, "bad global %q", text, loc = loc) {
					return {end = .Failed}
				}
				vals[base + i] = v
			}
		}
		defer for v in vals {
			query.release(&h, v)
		}

		inp := query.NULL
		if opts.doc != nil {
			is: query.Status
			inp, is = query.document_value(&h, opts.doc^, false)
			testing.expect_value(t, is, query.Status.Ok, loc = loc)
		} else if opts.input_json != "" {
			ok: bool
			inp, ok = read_value(&h, opts.input_json)
			if !testing.expectf(t, ok, "bad input %q", opts.input_json, loc = loc) {
				return {end = .Failed}
			}
		}

		default_hooks := jq.Hooks{parse_json = parse_json_hook, markup = xml_markup}
		use_hooks := opts.hooks if opts.hooks != nil else &default_hooks
		run: jq.Run
		jq.run_init(&run, prog, &h, vals, use_hooks, opts.steps)
		outs := Outputs{h = &h}
		res.end = jq.run_value(&run, inp, collect, &outs)
		res.tainted = h.tainted
		for v in outs.vals {
			append(&shown, show(&h, v))
			query.release(&h, v)
		}
		delete(outs.vals)
		if res.end == .Failed {
			e := query.take_error(&h)
			res.err_kind = e.kind
			res.err_msg = jq.error_message(&h, &e)
			if opts.append_err {
				append(&shown, strings.concatenate({"error: ", res.err_msg}))
			}
			query.destroy_error(&h, &e)
		}
		jq.run_destroy(&run)
	}
	testing.expect_value(t, query.heap_live(&h), u64(0), loc = loc)
	sep := opts.sep if opts.sep != "" else "\n"
	res.out = strings.join(shown[:], sep)
	return res
}

run_case_table :: proc(t: ^testing.T, file: string, cases: [][3]string, loc := #caller_location) {
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil, loc = loc)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	for c, i in cases {
		k := Case{file = file, line = i, prog = c[0], input = c[1], want = strings.split(c[2], "\n")}
		testing.expectf(t, run_case(k, true) == .Pass, "%s", c[0], loc = loc)
	}
}

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
