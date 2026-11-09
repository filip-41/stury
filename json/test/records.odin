package json_tests

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:math/rand"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import core "../../core"
import host "../../host"
import typed "../../core/typed"
import records "../../core/records"
import json ".."
import walktest "../../walktest"

// Records of every kind, with the separators of each framing between them: blank lines, CRLF, a BOM, a 0x1E in a
// line, values spread over lines and comments.
@(private = "file", rodata)
PIECES := []string {
	`{"a":1,"b":[true,false,null]}`,
	`[1,2.5e3,"x\né"]`,
	`"s"`,
	`-12`,
	`true`,
	`{"k":{"x":[{}]}}`,
	"{\"a\":\n1}",
	"[1,\n2]",
	"\x1e{\"a\":2}",
	"\xef\xbb\xbf[]",
	`{"a":1} // c`,
	`/* c */ [3]`,
	`{"a":1}  x`,
	`12 13`,
	`{a:'x',}`,
	"\"\\ud83d\\ude00\xf0\x9f\x98\x80\"",
	`{"aaaaaaaaaaaaaaaaaaaaaaaa":"𐀀xxxxxxxxxxxxxxxxxxxxxxxxxx","b":[1,2,3,4,5,6,7,8,9,10,11,12,13,14]}`,
	"[\"\\ud800\\udc00\xf0\x9f\x98\x80yyyyyyyyyyyyyyyyyyyyyyyyy\", 123456789012345678901234567890, -0.5e-300, \"\xc3\xa9zzzzzzzzzzzzzzzzzzzzz\"]",
	"/* a long comment that runs and runs and runs */ {\"k\":{\"x\":[\"pppppppppppppppppppppppp\"]}}   ",
	"{a:'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\\nyyyyy', bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb: 0x1234567890abcdef, c: Infinity}",
	"[1, /* comment spread\n over lines */ 2, 33333333333333333333333333333333333333]",
	"{\"a\":\"qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq\\\"qqqqqqqqqqqqqqqqqqqqqq\",\"b\":[[[[[[[[[[1]]]]]]]]]]}  // tail comment here",
	"[1\x0b,2\xc2\xa0]",
	"12\xef\xbb\xbf13",
}

@(private = "file", rodata)
SEPARATORS := []string{"\n", "\r\n", "\n\n", "\n  \t\n", " \n", "\r\n\r\n", "\x0b\n", "\n\xc2\xa0\n", "\xef\xbb\xbf\n", "\x0c", "\xc2\xa0", "\xe2\x80\xa8\n"}

// Object members' keys under `.Entries`, JSON5's among them.
@(private = "file", rodata)
KEYS := []string{`"a":`, `"b\"c" : `, "\"k\"\n:", `a:`, `'q' :`, `/* c */ "x"/* c */:`}

seeded_text :: proc(gen: rand.Generator, framing: core.Framing) -> string {
	b := strings.builder_make(context.temp_allocator)
	if rand.int_max(4, gen) == 0 {
		strings.write_string(&b, "\xef\xbb\xbf")
	}
	n := 1 + rand.int_max(6, gen)
	if framing == .Entries {
		// A root array or object of the pieces, with a trailing comma at times.
		object := rand.int_max(2, gen) == 0
		strings.write_byte(&b, '{' if object else '[')
		for i in 0 ..< n {
			if object {
				strings.write_string(&b, rand.choice(KEYS, gen))
			}
			strings.write_string(&b, rand.choice(PIECES, gen))
			strings.write_string(&b, rand.choice(SEPARATORS, gen))
			if i < n - 1 || rand.int_max(4, gen) == 0 {
				strings.write_byte(&b, ',')
			}
		}
		strings.write_string(&b, "}\n" if object else "]\n")
	}
	for _ in 0 ..< n * int(framing != .Entries) {
		if framing == .Seq {
			strings.write_byte(&b, 0x1e)
		}
		strings.write_string(&b, rand.choice(PIECES, gen))
		strings.write_string(&b, rand.choice(SEPARATORS, gen))
	}
	if rand.int_max(2, gen) == 0 {
		// No line end after the last record.
		strings.pop_byte(&b)
	}
	return strings.to_string(b)
}

@(test)
records_scan_a_stream :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "{\"a\":1}\n{\"b\":2}\n{\"a\":[3]} {\"a\":4\n"
	path, _ := core.parse_path(".a", context.temp_allocator)
	c := Chunked{src = transmute([]u8)src, sizes = {3}, fail_at = -1}
	it := records.open_stream(chunked(&c), json.as(.Json), .Concatenated)
	defer records.close(&it)
	got: [dynamic]string
	defer delete(got)
	for {
		_, doc, err, more := records.scan(&it, path)
		if !more {
			break
		}
		walktest.expect_nil(t, err)
		append(&got, fmt.tprint(doc.answers[0].outcome, string(core.span(&doc, doc.answers[0].node))))
	}
	testing.expect_value(t, fmt.tprint(got[:]), `["Found 1", "Missing ", "Found [3]"]`)
	testing.expect_value(t, string(it.held), " {\"a\":4\n")
}

// A clone of a record's document owns its answers, which the reader replaces at the next record, read in memory or
// from a stream.
@(test)
records_scan_clone_owns_answers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "{\"a\":1}\n{\"b\":2}\n"
	path, _ := core.parse_path(".a", context.temp_allocator)
	for streamed in ([]bool{false, true}) {
		c := Chunked{src = transmute([]u8)src, sizes = {3}, fail_at = -1}
		it := records.open_stream(chunked(&c), json.as(.Json)) if streamed else records.open(transmute([]u8)src, json.as(.Json))
		_, doc, _, _ := records.scan(&it, path)
		kept, err := core.clone(&doc)
		testing.expect_value(t, err, nil)
		_, next, _, _ := records.scan(&it, path)
		testing.expect_value(t, next.answers[0].outcome, core.Presence.Missing)
		records.close(&it)
		testing.expect_value(t, len(kept.answers), 1)
		testing.expect_value(t, kept.answers[0].outcome, core.Presence.Found)
		testing.expect_value(t, core.kind(&kept, kept.answers[0].node), core.Kind.Number)
		core.destroy(&kept)
	}
}

// The seeds each property test draws its texts from.
@(private = "file")
SEEDS :: 4

@(test)
records_frame_and_place :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "\xef\xbb\xbf{\"a\":1}\r\n\n  [2]\n\t\n"
	it := records.open(transmute([]u8)src, json.as(.Json))
	defer records.close(&it)
	rec, ok := records.next(&it)
	testing.expect(t, ok && rec.at == 3 && string(rec.text) == `{"a":1}`)
	rec, ok = records.next(&it)
	testing.expect(t, ok && rec.at == 15 && string(rec.text) == "[2]")
	_, ok = records.next(&it)
	testing.expect(t, !ok && it.fault == nil)

	// A refused record is the caller's to see. The next one is read past it.
	faults, _ := records.check(transmute([]u8)string("{\"a\":\n1}\n2"), json.as(.Json), .Lines, context.temp_allocator)
	testing.expect_value(t, len(faults), 2)
	testing.expect_value(t, faults[0], core.Fault{at = 5, rules = &json.RULES, kind = .Truncated})
	testing.expect_value(t, faults[1], core.Fault{at = 7, rules = &json.RULES, kind = .Bad_Char, detail = u8(json.Detail.Trailing)})

	// The members of a root object, keys as written, and a root at the deepest level, whose entries may be no container.
	obj := transmute([]u8)string(`{"a": 1, "b\"c" :[2] , "a":{}}`)
	it3 := records.open(obj, json.as(.Json), .Entries)
	keys := []string{`"a"`, `"b\"c"`, `"a"`}
	values := []string{"1", "[2]", "{}"}
	n := 0
	for r in records.next(&it3) {
		testing.expect(t, string(r.key) == keys[n] && string(r.text) == values[n] && string(obj[r.at:][:len(r.text)]) == values[n])
		n += 1
	}
	testing.expect(t, n == 3 && it3.fault == nil)
	kp, _ := json.plan_make(string)
	defer typed.plan_destroy(&kp)
	name: string
	kerr := json.unmarshal(transmute([]u8)keys[1], .Json, &name, &kp, read = {}, opts = {}, allocator = context.temp_allocator)
	testing.expect(t, kerr == nil && name == `b"c`)
	flat := json.as(.Json)
	flat.max_depth = 1
	faults, _ = records.check(transmute([]u8)string("[1, 2]"), flat, .Entries, context.temp_allocator)
	testing.expect_value(t, len(faults), 0)
	faults, _ = records.check(transmute([]u8)string("[1, [2]]"), flat, .Entries, context.temp_allocator)
	testing.expect(t, len(faults) == 1 && faults[0].kind == .Too_Deep && faults[0].at == 4)
	// Concatenated documents: a number runs on into a letter as one bad token.
	faults, _ = records.check(transmute([]u8)string("1 [2]{}\"s\"3x"), json.as(.Json), .Concatenated, context.temp_allocator)
	testing.expect(t, len(faults) == 1 && faults[0].detail == u8(json.Detail.Trailing) && faults[0].at == 11)
	// So does a scalar into a ',', ':', ']', '}', or a '/' where no comment may start, as jq reads them.
	for text in ([]string{"1,2", "1 true:", "1]", "1}", "1/"}) {
		faults, _ = records.check(transmute([]u8)text, json.as(.Json), .Concatenated, context.temp_allocator)
		testing.expectf(t, len(faults) == 1 && faults[0].detail == u8(json.Detail.Trailing) && faults[0].at == u64(strings.index_any(text[1:], ",:]}/")) + 1, "%q", text)
	}
	faults, _ = records.check(transmute([]u8)string("1/**/2"), json.as(.Jsonc), .Concatenated, context.temp_allocator)
	testing.expect_value(t, len(faults), 0)
	// A trailing comma at the input's end closes nothing, whatever byte lies past the input, and a member's key is a string.
	comma_cut := "[1,]"
	cut := records.open(transmute([]u8)comma_cut[:3], json.as(.Jsonc), .Entries)
	defer records.close(&cut)
	for _ in records.next(&cut) {}
	end_fault, ended := cut.fault.?
	testing.expect(t, ended && end_fault.kind == .Truncated && end_fault.at == 3)
	faults, _ = records.check(transmute([]u8)string("{1:2}"), json.as(.Json), .Entries, context.temp_allocator)
	testing.expect(t, len(faults) == 1 && faults[0].kind == .Bad_Char && faults[0].at == 1)

	// A line of JSON5 whitespace is no record, in JSON it is a refused one.
	ws := transmute([]u8)string("1\n\x0b\n\xc2\xa0\n2")
	for spec in ([]json.Spec{.Json5, .Json}) {
		it4 := records.open(ws, json.as(spec))
		defer records.close(&it4)
		n = 0
		for _ in records.next(&it4) {
			n += 1
		}
		testing.expect_value(t, n, 2 if spec == .Json5 else 4)
	}

	// RFC 7464: text before the first 0x1E is a record of its own, faulty, and the records go on.
	unframed, unframed_err := records.check(transmute([]u8)string(" 1\x1e2\n"), json.as(.Json), .Seq, context.temp_allocator)
	testing.expect_value(t, unframed_err, nil)
	testing.expect(t, len(unframed) == 1 && unframed[0] ==core.Fault{at = 1, rules = &json.RULES, kind = .Bad_Char, detail = u8(json.Detail.Unframed)})
}

@(private = "file")
Typed_Piece :: struct {
	a: Maybe(int),
	b: []Maybe(bool),
	k: struct {
		x: []string,
	},
}

// A typed error with its offsets moved by `at`, and its steps as text, which name keys by their bytes.
@(private = "file")
error_text :: proc(e: core.Typed_Error, at: u64) -> string {
	e := e
	if e.kind != .None {
		e.at += at
		if e.kind == .Walk {
			e.inner.at += at
		}
	}
	return fmt.tprint(e)
}

// A reader's memory does not grow with the records it reads, refused ones and decoded keys included, and a collected
// error's decoded name outlives the reads after it.
@(test)
records_read_in_bounded_memory :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Number_Record :: struct {
		a: int,
		b: string,
	}
	body := "{\"\\u0063\":\"q\",\"a\":1,\"b\":\"x\"}\n{\"a\":\"y\",\"b\":2,\"b\":3}\n"
	few := transmute([]u8)strings.repeat(body, 100, context.temp_allocator)
	many := transmute([]u8)strings.repeat(body, 1000, context.temp_allocator)
	maps, _ := json.plan_make(map[string]string, allocator = context.temp_allocator)
	ints, _ := json.plan_make(map[string]int, allocator = context.temp_allocator)
	rows, _ := json.plan_make(Number_Record, allocator = context.temp_allocator)
	for framing in ([]core.Framing{.Lines, .Concatenated}) {
		as := json.as(.Json)
		_ = walktest.expect_bounded_reads(t, few, many, as, &maps, map[string]string, {dups = .First}, framing) &&
		walktest.expect_bounded_reads(t, few, many, as, &ints, map[string]int, {}, framing) &&
		walktest.expect_bounded_reads(t, few, many, as, &rows, Number_Record, {}, framing) &&
		walktest.expect_bounded_reads(t, few, many, as, &rows, Number_Record, {unknown = .Refuse, dups = .Refuse}, framing)
	}
	it := records.open(few, json.as(.Json))
	defer records.close(&it)
	c := typed.Sink{errors = make([dynamic]core.Typed_Error, context.temp_allocator)}
	for {
		v: Number_Record
		_, more := records.read(&it, &v, &rows, {unknown = .Refuse, sink = &c}, context.temp_allocator)
		if !more {
			break
		}
	}
	name, _ := c.errors[0].steps[0].(core.Name)
	testing.expectf(t, len(c.errors) == 100 && name == "c", "%d errors, the first %v", len(c.errors), c.errors[0])
}

// A plan of another type is refused the same way under every framing, before any record is read, and ends the records.
@(test)
records_read_checks_the_plan_once :: proc(t: ^testing.T) {
	plan, _ := json.plan_make(Typed_Piece)
	defer typed.plan_destroy(&plan)
	for framing in core.Framing {
		it := records.open(transmute([]u8)string("{\"a\":1}\n{\"a\":2}\n"), json.as(.Json), framing)
		defer records.close(&it)
		v: struct{ a: int }
		err, more := records.read(&it, &v, &plan)
		testing.expectf(t, more && walktest.typed_kind(err) == .Plan_Mismatch && it.pos == core.text_start(it.src, 0), "%v: %v %v", framing, more, err)
		err, more = records.read(&it, &v, &plan)
		testing.expectf(t, !more && err == nil && it.fault != nil, "%v: then %v %v", framing, more, err)
	}
	// With no plan the reader builds one of the type and keeps it.
	it := records.open(transmute([]u8)string("{\"a\":1}\n{\"a\":2}\n"), json.as(.Json))
	defer records.close(&it)
	v: struct{ a: int }
	sum := 0
	for err in records.read(&it, &v, nil) {
		walktest.expect_nil(t, err)
		sum += v.a
	}
	testing.expect_value(t, sum, 3)
}

@(test)
records_build_places_faults :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "{\"a\":[1,2]}\n[1,}\n\xef\xbb\xbf2\n"
	it := records.open(transmute([]u8)src, json.as(.Json))
	defer records.close(&it)
	rec, _ := records.next(&it)
	doc, err := records.build(&it, rec, context.temp_allocator)
	walktest.expect_nil(t, err)
	path, _ := core.parse_path(".a[1]", context.temp_allocator)
	answers, _ := core.query(&doc, path, allocator = context.temp_allocator)
	testing.expect_value(t, len(answers), 1)
	rec, _ = records.next(&it)
	_, err = records.build(&it, rec, context.temp_allocator)
	testing.expect_value(t, walktest.fault_of(err), Maybe(core.Fault)(core.Fault{at = 15, rules = &json.RULES, kind = .Bad_Char, detail = u8(json.Detail.Unmatched_Brace)}))
	rec, _ = records.next(&it)
	_, err = records.build(&it, rec, context.temp_allocator)
	testing.expect_value(t, walktest.fault_of(err), Maybe(core.Fault)(core.Fault{at = 17, rules = &json.RULES, kind = .Bad_Char, detail = u8(json.Detail.Expected_Value)}))
}

// An input that gives at most `sizes[i % len(sizes)]` bytes on its `i`-th read, a random count up to 16 when `sizes`
// is empty, and fails with `.Unknown` once `fail_at` bytes are read.
@(private = "file")
Chunked :: struct {
	src:     []u8,
	sizes:   []int,
	gen:     rand.Generator,
	reads:   int,
	at:      int,
	fail_at: int,
}

@(private = "file")
chunked :: proc(c: ^Chunked) -> io.Reader {
	return {data = c, procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []u8, _: i64, _: io.Seek_From) -> (i64, io.Error) {
		c := (^Chunked)(data)
		if mode != .Read {
			return 0, .Unsupported
		}
		if c.at == c.fail_at {
			return 0, .Unknown
		}
		if c.at == len(c.src) {
			return 0, .EOF
		}
		k := c.sizes[c.reads % len(c.sizes)] if len(c.sizes) > 0 else 1 + rand.int_max(16, c.gen)
		c.reads += 1
		k = min(k, c.fail_at - c.at) if c.fail_at >= 0 else k
		n := copy(p[:min(len(p), k)], c.src[c.at:])
		c.at += n
		return i64(n), nil
	}}
}

@(private = "file")
Got :: struct {
	recs:  [dynamic]records.Record,
	errs:  [dynamic]string,
	fault: Maybe(core.Fault),
	held:  string,
	at:    u64,
}

// Every record of `it` with its built document's error, copied, since a stream's record text is gone at the next call.
@(private = "file")
drain :: proc(it: ^records.Reader) -> (g: Got) {
	g.recs = make([dynamic]records.Record, context.temp_allocator)
	g.errs = make([dynamic]string, context.temp_allocator)
	for rec in records.next(it) {
		_, err := records.build(it, rec, context.temp_allocator)
		text := strings.clone(string(rec.text), context.temp_allocator)
		key := strings.clone(string(rec.key), context.temp_allocator)
		append(&g.recs, records.Record{text = transmute([]u8)text, key = transmute([]u8)key, at = rec.at})
		append(&g.errs, fmt.tprint(err))
	}
	g.fault, g.held, g.at = it.fault, strings.clone(string(it.held), context.temp_allocator), it.held_at
	return
}

// A stream of `src` read in chunks gives the records and faults `src` in memory gives, but for a last record the input
// ends inside, which it holds.
@(private = "file")
expect_window_law :: proc(t: ^testing.T, src: string, framing: core.Framing, spec: json.Spec, sizes: []int, gen: rand.Generator) -> bool {
	mem := records.open(transmute([]u8)src, json.as(spec), framing)
	defer records.close(&mem)
	want := drain(&mem)
	c := Chunked{src = transmute([]u8)src, sizes = sizes, gen = gen, fail_at = -1}
	st := records.open_stream(chunked(&c), json.as(spec), framing)
	defer records.close(&st)
	got := drain(&st)
	n := len(got.recs)
	same := n <= len(want.recs)
	for i in 0 ..< min(n, len(want.recs)) {
		r, w := got.recs[i], want.recs[i]
		same &&= r.at == w.at && string(r.text) == string(w.text) && string(r.key) == string(w.key) && got.errs[i] == want.errs[i]
	}
	end := u64(len(src))
	if len(got.held) == 0 {
		same &&= n == len(want.recs) && got.fault == want.fault
	} else {
		// The held bytes run to the input's end, and in memory they are a record refused as cut off, or that fault.
		cut := core.Fault{at = end, rules = &json.RULES, kind = .Truncated}
		extra := len(want.recs) - n
		same &&= got.fault == nil && got.at + u64(len(got.held)) == end && src[got.at:] == got.held
		same &&= extra == 0 && want.fault == cut || extra == 1 && want.fault == nil && strings.contains(want.errs[n], "Truncated")
	}
	return testing.expectf(t, same && st.cause == nil, "%v %v %v %q: stream %v %v held %q at %d, memory %v %v %v", framing, spec, sizes, src, got.recs[:], got.fault, got.held, got.at, want.recs[:], want.errs[:], want.fault)
}

@(test)
records_stream_as_in_memory :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rand.create(3)
	gen := rand.default_random_generator(&state)
	sizes := [][]int{{1}, {2}, {3}, {7}, {64}, {}}
	// Tokens and gaps longer than a window that cuts them.
	long := []string{"1 /* a comment longer than a window */ 2", "1 // a line comment longer than a window\n2", "[\"a string longer than the window\"]"}
	for src in long {
		for spec in json.Spec {
			for s in sizes {
				if !expect_window_law(t, src, .Concatenated, spec, s, gen) {
					return
				}
			}
		}
	}
	breakers := "x\"}],:\n\r \x1e\x00\\"
	for round in 0 ..< 800 {
		framing := core.Framing(round % 4)
		src := seeded_text(gen, framing)
		if round % 8 >= 4 {
			// A byte that breaks or ends a value, at a random place.
			buf := transmute([]u8)strings.clone(src, context.temp_allocator)
			buf[rand.int_max(len(buf), gen)] = breakers[rand.int_max(len(breakers), gen)]
			src = string(buf)
		}
		for spec in json.Spec {
			for s in sizes {
				if !expect_window_law(t, src, framing, spec, s, gen) {
					return
				}
			}
		}
		free_all(context.temp_allocator)
	}
}

// `records.read` on a stream gives what it gives in memory, with offsets from the input's first byte.
@(test)
records_stream_read :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	plan, perr := json.plan_make(Typed_Piece)
	walktest.expect_nil(t, perr)
	defer typed.plan_destroy(&plan)
	state := rand.create(4)
	gen := rand.default_random_generator(&state)
	for round in 0 ..< 200 {
		framing := core.Framing(round % 4)
		src := seeded_text(gen, framing)
		for spec in json.Spec {
			mem := records.open(transmute([]u8)src, json.as(spec), framing)
			c := Chunked{src = transmute([]u8)src, sizes = {1 + round % 5}, fail_at = -1}
			st := records.open_stream(chunked(&c), json.as(spec), framing)
			ms, ss: typed.Sink
			ms.errors = make([dynamic]core.Typed_Error, context.temp_allocator)
			ss.errors = make([dynamic]core.Typed_Error, context.temp_allocator)
			for {
				v, w: Typed_Piece
				err, more := records.read(&st, &v, &plan, {sink = &ss}, context.temp_allocator)
				werr, wmore := records.read(&mem, &w, &plan, {sink = &ms}, context.temp_allocator)
				if !more {
					// A record the stream holds is the last one memory reads.
					if len(st.held) > 0 && wmore {
						resize(&ms.errors, len(ss.errors))
						_, wmore = records.read(&mem, &w, &plan, {sink = &ms}, context.temp_allocator)
					}
					testing.expectf(t, !wmore && (st.fault == mem.fault || len(st.held) > 0), "%v %v %q: stream ends %v, memory %v %v", framing, spec, src, st.fault, wmore, mem.fault)
					break
				}
				if !testing.expectf(t, wmore && error_text(walktest.typed_of(err), 0) == error_text(walktest.typed_of(werr), 0) && (err != nil || fmt.tprint(v) == fmt.tprint(w)), "%v %v %q: read %v %s, memory %v %s", framing, spec, src, v, error_text(walktest.typed_of(err), 0), w, error_text(walktest.typed_of(werr), 0)) {
					return
				}
			}
			if len(st.held) == 0 {
				testing.expectf(t, fmt.tprint(ss.errors[:]) == fmt.tprint(ms.errors[:]), "%v %v %q: collected %v, memory %v", framing, spec, src, ss.errors[:], ms.errors[:])
			}
			records.close(&mem)
			records.close(&st)
		}
		free_all(context.temp_allocator)
	}
}

// An input that ends at any byte inside its last record holds that record's bytes and ends with no fault.
@(test)
records_stream_holds_a_cut_record :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	last := `{"k":["xé",-1.5e3,true,null]}`
	heads := [3]string{"1\n[2]\n", "\x1e1\n\x1e[2]\n\x1e", "1 [2] "}
	for head, i in heads {
		framing := core.Framing(i)
		src := strings.concatenate({head, last}, context.temp_allocator)
		for k in len(head) + 1 ..< len(src) {
			c := Chunked{src = transmute([]u8)src[:k], sizes = {3}, fail_at = -1}
			it := records.open_stream(chunked(&c), json.as(.Json), framing)
			n := 0
			for _ in records.next(&it) {
				n += 1
			}
			// The held bytes start past the last whole record, which under `.Concatenated` is before the gap.
			from := len(head) - int(framing == .Concatenated)
			testing.expectf(t, n == 2 && it.fault == nil && it.held_at == u64(from) && string(it.held) == src[from:k], "%v cut at %d: %d records, %v, held %q at %d", framing, k, n, it.fault, it.held, it.held_at)
			records.close(&it)
		}
		// A whole last record with no end byte is a record.
		c := Chunked{src = transmute([]u8)src, sizes = {3}, fail_at = -1}
		it := records.open_stream(chunked(&c), json.as(.Json), framing)
		n := 0
		for _ in records.next(&it) {
			n += 1
		}
		testing.expectf(t, n == 3 && it.fault == nil && len(it.held) == 0, "%v whole: %d records, %v", framing, n, it.fault)
		records.close(&it)
	}
}

@(test)
records_stream_limits_and_failures :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := strings.concatenate({"1\n22\n\"", strings.repeat("a", 100, context.temp_allocator), "\"\n4\n"}, context.temp_allocator)
	for limit in ([]int{32, 200}) {
		c := Chunked{src = transmute([]u8)src, sizes = {7}, fail_at = -1}
		it := records.open_stream(chunked(&c), json.as(.Json), .Lines, {max_bytes = limit})
		n := 0
		for _ in records.next(&it) {
			n += 1
		}
		if limit == 32 {
			testing.expectf(t, n == 2 && it.fault == core.Fault{at = 5, rules = &records.RULES, kind = .Too_Wide, detail = 1}, "%d records, %v", n, it.fault)
		} else {
			testing.expectf(t, n == 4 && it.fault == nil, "%d records, %v", n, it.fault)
		}
		records.close(&it)
	}

	// A failing input ends the records it gave whole and holds the bytes past them. Under `.Concatenated` a record is
	// whole once a byte past it is read.
	for framing in ([]core.Framing{.Lines, .Concatenated, .Entries}) {
		text := "[1,22,333,4444,55555,666666]" if framing == .Entries else "1\n22\n333\n4444\n55555\n666666\n"
		c := Chunked{src = transmute([]u8)text, sizes = {2}, fail_at = 24}
		it := records.open_stream(chunked(&c), json.as(.Json), framing)
		got := make([dynamic]string, context.temp_allocator)
		for rec in records.next(&it) {
			append(&got, strings.clone(string(rec.text), context.temp_allocator))
		}
		want: []string
		held := text[:24]
		#partial switch framing {
		case .Lines:
			want, held = {"1", "22", "333", "4444", "55555"}, text[20:24]
		case .Concatenated:
			want, held = {"1", "22", "333", "4444", "55555"}, text[19:24]
		}
		testing.expectf(t, fmt.tprint(got[:]) == fmt.tprint(want) && it.fault == nil && it.cause == .Unknown && string(it.held) == held, "%v: %v, %v %v, held %q", framing, got[:], it.fault, it.cause, it.held)
		records.close(&it)
	}
}

// A reader opened at a byte of the input, on the text in memory or on a stream of the text past that byte, gives the
// records from that byte with offsets from the input's first byte.
@(test)
records_open_at_an_offset :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Case :: struct {
		src:     string,
		framing: core.Framing,
		at:      u64,
	}
	cases := []Case{{"1\n[2]\n\xef\xbb\xbf3\n4", .Lines, 2}, {"x\x1e1\x1e2", .Seq, 1}, {"1 [2] 3x", .Concatenated, 1}, {"xx [1, {}]", .Entries, 2}, {"xx [1, }", .Entries, 2}}
	for c in cases {
		// The text past `at` read alone, with its offsets moved by `at`. None of these starts with a BOM.
		past := records.open(transmute([]u8)c.src[c.at:], json.as(.Json), c.framing)
		want := drain(&past)
		records.close(&past)
		for &r in want.recs {
			r.at += c.at
		}
		fault := want.fault
		if f, bad := fault.?; bad {
			f.at += c.at
			fault = f
		}
		mem := records.open(transmute([]u8)c.src, json.as(.Json), c.framing, c.at)
		from := drain(&mem)
		records.close(&mem)
		ch := Chunked{src = transmute([]u8)c.src[c.at:], sizes = {2}, fail_at = -1}
		st := records.open_stream(chunked(&ch), json.as(.Json), c.framing, at = c.at)
		streamed := drain(&st)
		records.close(&st)
		testing.expectf(t, fmt.tprint(from.recs[:]) == fmt.tprint(want.recs[:]) && from.fault == fault, "%q at %d: %v %v, want %v %v", c.src, c.at, from.recs[:], from.fault, want.recs[:], fault)
		testing.expectf(t, fmt.tprint(streamed.recs[:]) == fmt.tprint(want.recs[:]) && streamed.fault == fault, "%q stream at %d: %v %v, want %v %v", c.src, c.at, streamed.recs[:], streamed.fault, want.recs[:], fault)
	}
}

// `next_window` gives windows of whole records that hold every record `next` gives.
@(test)
records_next_window :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rand.create(5)
	gen := rand.default_random_generator(&state)
	for round in 0 ..< 300 {
		framing := core.Framing(round % 3)
		src := seeded_text(gen, framing)
		mem := records.open(transmute([]u8)src, json.as(.Json), framing)
		want := drain(&mem)
		records.close(&mem)
		c := Chunked{src = transmute([]u8)src, sizes = {1 + round % 9}, fail_at = -1}
		st := records.open_stream(chunked(&c), json.as(.Json), framing)
		n := 0
		end := u64(0)
		for window, base in records.next_window(&st) {
			if !testing.expectf(t, base >= end && src[base:][:len(window)] == string(window), "%v %q: window %q at %d", framing, src, window, base) {
				return
			}
			end = base + u64(len(window))
			for r in want.recs {
				n += int(r.at >= base && r.at + u64(len(r.text)) <= end)
			}
		}
		held := u64(len(st.held))
		testing.expectf(t, n == len(want.recs) - int(held > 0 && want.fault == nil) && end + held <= u64(len(src)), "%v %q: windows hold %d records of %d", framing, src, n, len(want.recs))
		records.close(&st)
		free_all(context.temp_allocator)
	}
}

// `blank` says a text holds no document exactly when its documents, read one after another, are none and end with no
// fault.
@(test)
records_none_when_blank :: proc(t: ^testing.T) {
	texts := []string{"", " \n\t\r", "\xef\xbb\xbf", "\xef\xbb\xbf ", "\v", "\f", "\u00a0", "\ufeff", "\u2028", "\u2029", " \v\u00a0\u2028 ", "// c\n", "/* c */ ", "/* c", "/", "// c\n\v", "1", " x", "\xef\xbb"}
	for spec in json.Spec {
		for text in texts {
			it := records.open(transmute([]u8)text, json.as(spec), .Concatenated)
			_, some := records.next(&it)
			none := !some && it.fault == nil
			records.close(&it)
			blank := json.blank(transmute([]u8)text, spec)
			testing.expectf(t, blank == none, "%v %q: blank %v, records none %v", spec, text, blank, none)
		}
	}
}

@(private = "file")
Seq_Piece :: struct {
	k:      int,
	faults: [dynamic]Maybe(core.Fault),
}

@(private = "file")
Seq_Pieces :: struct {
	lock:   sync.Mutex,
	plan:   ^typed.Plan,
	pieces: [dynamic]Seq_Piece,
}

@(private = "file")
Seq_Target :: struct {
	a: Maybe(int),
}

// The walk faults of a piece's reads, which the target's type refuses none of in the texts read.
@(private = "file")
read_seq_piece :: proc(g: ^Seq_Pieces, piece: ^records.Reader, k: int) -> bool {
	p := Seq_Piece{k = k, faults = make([dynamic]Maybe(core.Fault), runtime.heap_allocator())}
	for {
		v: Seq_Target
		err, more := records.read(piece, &v, g.plan)
		if !more {
			break
		}
		append(&p.faults, walktest.fault_of(err))
	}
	sync.guard(&g.lock)
	append(&g.pieces, p)
	return true
}

// A collecting read's framing and walk faults go to the read's allocator when `errors` has none.
@(test)
records_seq_faults_collect_with_the_reads_allocator :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	plan, _ := json.plan_make(Seq_Target)
	defer typed.plan_destroy(&plan)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	for src in ([]string{" 1\x1e{}", "\x1e3", "\x1e{\"a\":\n"}) {
		sink: typed.Sink
		it := records.open(transmute([]u8)src, json.as(.Json), .Seq)
		for {
			v: Seq_Target
			_, more := records.read(&it, &v, &plan, {sink = &sink}, mem.tracking_allocator(&track))
			if !more {
				break
			}
		}
		records.close(&it)
		testing.expect_value(t, len(sink.errors), 1)
		testing.expect(t, sink.errors.allocator.data == &track, src)
		delete(sink.errors)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// Under `.Seq` a read and a scan frame the records as `build` does and give its faults, which are the faults `check`
// gives, on one thread and in the pieces of `each`.
@(test)
records_seq_reads_frame_as_build :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	plan, _ := json.plan_make(Seq_Target)
	defer typed.plan_destroy(&plan)
	path, _ := core.parse_path(".a", context.temp_allocator)
	pool: host.Pool
	host.pool_init(&pool, 2)
	defer host.pool_destroy(&pool)
	bad :: proc(at: u64, kind: core.Fault_Kind, detail := json.Detail(0)) -> Maybe(core.Fault) {
		return core.Fault{at = at, rules = &json.RULES, kind = kind, detail = u8(detail)}
	}
	Case :: struct {
		src:  string,
		want: []Maybe(core.Fault),
	}
	cases := []Case {
		{"\x1e{}{}", {bad(3, .Bad_Char, .Trailing)}},
		{"\x1e3", {bad(2, .Bad_Number, .Cut_Number)}},
		{" 1\x1e{}", {bad(1, .Bad_Char, .Unframed), nil}},
		{"\x1e{\"a\":1}[2]\n\x1e{}", {bad(8, .Bad_Char, .Trailing), nil}},
		{"\x1e{} 7\x1e{\"a\":1}{}", {bad(4, .Bad_Char, .Trailing), bad(13, .Bad_Char, .Trailing)}},
	}
	as := json.as(.Json)
	for c in cases {
		src := transmute([]u8)c.src
		ways: [4][dynamic]Maybe(core.Fault)
		it := records.open(src, as, .Seq)
		for rec in records.next(&it) {
			doc, err := records.build(&it, rec)
			append(&ways[0], walktest.fault_of(err))
			core.destroy(&doc)
		}
		records.close(&it)
		it = records.open(src, as, .Seq)
		for {
			v: Seq_Target
			err, more := records.read(&it, &v, &plan)
			if !more {
				break
			}
			append(&ways[1], walktest.fault_of(err))
		}
		records.close(&it)
		it = records.open(src, as, .Seq)
		for {
			_, _, err, more := records.scan(&it, path)
			if !more {
				break
			}
			append(&ways[2], walktest.fault_of(err))
		}
		records.close(&it)
		g := Seq_Pieces{plan = &plan}
		records.each(src, as, .Seq, read_seq_piece, &g, &pool.runner)
		slice.sort_by(g.pieces[:], proc(a, b: Seq_Piece) -> bool { return a.k < b.k })
		for p in g.pieces {
			append(&ways[3], ..p.faults[:])
			delete(p.faults)
		}
		delete(g.pieces)
		for way, i in ways {
			testing.expectf(t, slice.equal(way[:], c.want), "%q way %d: %v, want %v", c.src, i, way[:], c.want)
			delete(way)
		}
		checked, _ := records.check(src, as, .Seq, context.temp_allocator)
		want := make([dynamic]core.Fault, context.temp_allocator)
		for f in c.want {
			if x, faulted := f.?; faulted {
				append(&want, x)
			}
		}
		testing.expectf(t, slice.equal(checked, want[:]), "%q check: %v, want %v", c.src, checked, want[:])
	}
}
