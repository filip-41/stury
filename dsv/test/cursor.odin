package dsv_tests

import "core:math/rand"
import "core:slice"
import "core:testing"
import core "../../core"
import walktest "../../walktest"
import dsv ".."
import gen "gen"

// A hook that logs every token into `tokens` and stops the walk at every record's `End`.
Record_Stops :: struct {
	tokens: []core.Token,
	n:      int,
}

record_stop_hook :: proc "contextless" (h: ^Record_Stops, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	h.tokens[h.n] = t
	h.n += 1
	return {s.a + 1, s.b, s.c}, .Stop if t.kind == .End else .Next
}

// Walks `src` with a stop at every record's end, resuming each time, and checks that the tokens, the end and the fault
// are those of an unbroken walk.
resumed_agrees :: proc(t: ^testing.T, src: []u8, $S: dsv.Spec, opts: dsv.Options, full: ^walktest.Log) -> bool {
	full^ = {}
	hi, fault := dsv.walk(src, 0, S, opts, full, nil, walktest.log_hook)
	h := Record_Stops{tokens = make([]core.Token, full.n + 1)}
	defer delete(h.tokens)
	keys: [64]core.Token
	cursor := dsv.Cursor{keys = keys[:]}
	regs: core.Hook_Regs
	hi2, fault2 := dsv.walk(src, 0, S, opts, &h, &regs, record_stop_hook, &cursor)
	ends := 0
	for dsv.can_resume(&cursor) {
		ends += 1
		hi2, fault2 = dsv.walk_resume(src, &cursor, S, opts, &h, &regs, record_stop_hook)
	}
	records := 0
	for tok in full.tokens[:full.n] {
		records += int(tok.kind == .End)
	}
	ok := testing.expectf(t, slice.equal(h.tokens[:h.n], full.tokens[:full.n]), "%v %q: %d tokens, want %d", S, src, h.n, full.n)
	// The text's own `End` is a stop that ends the walk.
	if fault == nil && ok {
		ok &&= testing.expectf(t, ends == records - 1 && hi2 == hi && fault2 == nil, "%v %q: %d resumes of %d records, %d %v", S, src, ends, records - 1, hi2, fault2)
	} else {
		ok &&= testing.expectf(t, hi2 == hi && fault2 == fault, "%v %q: %d %v, want %d %v", S, src, hi2, fault2, hi, fault)
	}
	ok &&= testing.expectf(t, regs.a == u64(h.n), "%v %q: registers %d after %d tokens", S, src, regs.a, h.n)
	return ok
}

// A walk stopped at every record and resumed each time gives the tokens of an unbroken walk, for valid and broken
// texts with and without a header, and for texts with comment lines, CR LF line ends and other delimiters.
@(test)
cursor_resumes :: proc(t: ^testing.T) {
	state := rand.create(3)
	context.random_generator = rand.default_random_generator(&state)
	full := new(walktest.Log)
	defer free(full)
	text, broken: [dynamic]u8
	defer delete(text)
	defer delete(broken)
	for round in 0 ..< 100 {
		tsv := round % 4 >= 2
		no_header := round % 8 >= 4
		gen.text(&text, tsv)
		src := text[:]
		if round % 2 == 1 {
			walktest.mutate(&broken, text[:], gen.SHARP)
			src = broken[:]
		}
		ok := resumed_agrees(t, src, .Tsv, {no_header = no_header}, full) if tsv else resumed_agrees(t, src, .Csv, {no_header = no_header}, full)
		if !ok {
			return
		}
	}
	for round in 0 ..< 100 {
		c := gen.pick_case()
		gen.options_text(&text, c)
		opts := dsv.Options{delimiter = c.delim, comment = c.comment, no_header = round % 2 == 1}
		ok: bool
		switch c.spec {
		case .Csv:   ok = resumed_agrees(t, text[:], .Csv, opts, full)
		case .Tsv:   ok = resumed_agrees(t, text[:], .Tsv, opts, full)
		case .Plain: ok = resumed_agrees(t, text[:], .Plain, opts, full)
		}
		if !ok {
			return
		}
	}
}

// A stop on a token that is no record's end, a cursor resumed on another text, and a header wider than the cursor's
// keys are refused.
@(test)
cursor_refuses :: proc(t: ^testing.T) {
	src := transmute([]u8)string("a,b\n1,2\n3,4\n")
	copied := slice.clone(src)
	defer delete(copied)
	h := Record_Stops{tokens = make([]core.Token, 16)}
	defer delete(h.tokens)
	keys: [2]core.Token
	cursor := dsv.Cursor{keys = keys[:]}
	hi, _ := dsv.walk(src, 0, .Csv, {}, &h, nil, record_stop_hook, &cursor)
	testing.expectf(t, dsv.can_resume(&cursor) && hi == 8, "a record's end: %d", hi)
	_, fault := dsv.walk_resume(copied, &cursor, .Csv, {}, &h, nil, record_stop_hook)
	f, faulted := fault.?
	testing.expectf(t, faulted && f.kind == .Bad_Option, "another text: %v", fault)
	hi, fault = dsv.walk_resume(src, &cursor, .Csv, {}, &h, nil, record_stop_hook)
	testing.expectf(t, dsv.can_resume(&cursor) && hi == 12 && fault == nil, "the next record: %d %v", hi, fault)

	stop_at_cell :: proc "contextless" (h: ^Record_Stops, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
		return s, .Stop if t.role == .Value && t.kind == .Plain else .Next
	}
	hi, fault = dsv.walk(src, 0, .Csv, {}, &h, nil, stop_at_cell, &cursor)
	testing.expectf(t, !dsv.can_resume(&cursor) && hi == 5 && fault == nil, "a cell: %d %v", hi, fault)
	_, fault = dsv.walk_resume(src, &cursor, .Csv, {}, &h, nil, stop_at_cell)
	f, faulted = fault.?
	testing.expectf(t, faulted && f.kind == .Bad_Option, "no stop: %v", fault)

	narrow := dsv.Cursor{keys = keys[:1]}
	_, fault = dsv.walk(src, 0, .Csv, {}, &h, nil, record_stop_hook, &narrow)
	f, faulted = fault.?
	testing.expectf(t, faulted && f.kind == .No_Memory, "a wide header: %v", fault)
}
