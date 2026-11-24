package json_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// The batch of one record, the form the tests follow the records through.
@(private = "file")
one_validate :: proc(r: ^json.Records) -> (rec: tape.Record, more: bool) {
	out: [1]tape.Record
	return out[0], json.records_validate(r, out[:]) == 1
}

@(private = "file")
one_find :: proc(r: ^json.Records, path: []tape.Step, read := tape.Read_Options{}) -> (rec: tape.Record, answer: tape.Span_Answer, more: bool) {
	out: [1]tape.Record
	answers: [1]tape.Span_Answer
	n := json.records_find(r, path, out[:], answers[:], read)
	return out[0], answers[0], n == 1
}

@(private = "file")
one_scan :: proc(r: ^json.Records, demand: ^tape.Demand, read := tape.Read_Options{}) -> (rec: tape.Record, doc: tape.Document, more: bool) {
	out: [1]tape.Record
	docs: [1]tape.Document
	n := json.records_scan(r, demand, out[:], docs[:], read)
	return out[0], docs[0], n == 1
}

// `err` with the offset it names moved by `by`, as a read in place in a text names what a read of a part of it alone
// names in the part.
@(private = "file")
moved :: proc(err: tape.Error, by: u64) -> tape.Error {
	#partial switch e in err {
	case tape.Fault:
		f := e
		f.at += by
		return f
	case tape.Exceeded:
		x := e
		if x.kind != .Memory {
			x.at += by
		}
		return x
	}
	return err
}

// The spans of the lines of `src` that hold a record: from the first byte that is no white space to the line's end
// less a CR.
@(private = "file")
line_spans :: proc(src: string) -> [][2]u64 {
	spans := make([dynamic][2]u64, context.temp_allocator)
	lo := 0
	for lo < len(src) {
		hi := strings.index_byte(src[lo:], '\n')
		end := len(src) if hi < 0 else lo + hi
		first := lo
		for first < end && strings.index_byte(" \t\r", src[first]) >= 0 {
			first += 1
		}
		cut := end
		if cut > first && src[cut - 1] == '\r' {
			cut -= 1
		}
		if first < end {
			append(&spans, [2]u64{u64(first), u64(cut)})
		}
		lo = end + 1
	}
	return spans[:]
}

// Lines whose records repeat their members' gaps, so that the walk learns them, and lines a walk of the whole text
// reads past, into, or differently from the line alone.
@(private = "file")
RECORD_LINES := []string {
	`{"ts":"2026-10-03T04:03:24.502Z","level":"info","service":"shipping","status":338,"id":"req-04ef1962"}`,
	`{"ts":"2026-10-03T00:44:00.944Z","level":"trace","service":"payments","status":363,"id":"req-6e6aa570"}`,
	`{"ts":"2026-10-03T12:38:18.852Z","level":"warn","service":"inventory","status":200,"id":"req-1"}`,
	`{"ts":"2026-10-03T12:38:18.852Z","level":"warn","service":"inventory","status":200,"id":"req-2"}  `,
	`{"ts":"2026-10-03T12:38:18.852Z","level":"warn","service":"inventory","status":200,"id":"req-3"}` + "\r",
	`{"ts":"2026-10-03T12:38:18.852Z", "level":"warn","service":"inventory","status":200,"id":"req-4"}`,
	`{"ts":"2026-10-03T12:38:18.852Z","level":"warn","service":"inventory","status":201,"id":"req-5"} x`,
	`{"ts":"2026-10-03T12:38:18.852Z","level":"warn","service":"inventory","status":`,
	`202,"id":"req-6"}`,
	`{"ts":"2026-10-03T12:38:18.852Z","level":"warn","service":"inventory","status":203,"id":"req-7"`,
	`}`,
	`{"ts":"2026-10-03T12:38:18.852Z","level":"warn","service":"inventory","status":204,"id":"req-8"}{}`,
	`  [1, 2, {"status": 3}]  `,
	``,
	"  \t ",
	`"text"`,
	`12`,
	`-`,
	`true`,
	`{"status":1,"status":2}`,
	`{"level":"aAb","status":"\t"}`,
	"{\"level\":\"a\tb\",\"status\":5}",
	`{"ts":"2026-10-03T12:38:18.852Z","level":"warn","service":"inventory","status":205,"id":"req-9"} // note`,
	`/* head */ {"status":206}`,
	`{"status":[1,2,],}`,
	`{status:207}`,
	`[[[[[[[[[[{"status":208}]]]]]]]]]]`,
	`{"ts":"2026-10-03T12:38:18.852Z","level":"warn","service":"inventory","status":209,"id":"req-10"}`,
}

@(private = "file")
record_lines :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	for round in 0 ..< 3 {
		for line, i in RECORD_LINES {
			strings.write_string(&b, line)
			strings.write_string(&b, "\r\n" if (i + round) % 5 == 0 else "\n")
		}
	}
	strings.write_string(&b, RECORD_LINES[0])
	return strings.to_string(b)
}

// Each line's record is judged, found and scanned as a read of the line alone does, with its offsets in the text, and
// a refused record leaves the records going on at the next line.
@(test)
records_read_each_line_as_alone :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := record_lines()
	spans := line_spans(src)
	path := []tape.Step{tape.Name("status")}
	demand, _ := tape.demand_of({path, {tape.Name("level")}})
	defer tape.destroy_demand(&demand)
	for spec in json.Spec {
		r := json.records_open(transmute([]u8)src, .Lines, spec)
		for span, i in spans {
			rec, more := one_validate(&r)
			line := transmute([]u8)src[span[0]:span[1]]
			want := moved(json.validate(line, spec), span[0])
			testing.expectf(t, more && rec == {u64(i), span[0], span[1], want, {}}, "%v validate line %d %q: %v %v, want %v", spec, i, line, rec, more, want)
		}
		_, more := one_validate(&r)
		testing.expectf(t, !more && r.err == nil && r.index == u64(len(spans)), "%v validate end: %v %v", spec, r.err, r.index)
		for stop in ([]bool{false, true}) {
			r = json.records_open(transmute([]u8)src, .Lines, spec)
			for span, i in spans {
				rec, answer, ok := one_find(&r, path, {stop_early = stop})
				line := transmute([]u8)src[span[0]:span[1]]
				alone, err := json.find(line, path, spec, {stop_early = stop})
				if err == nil {
					alone.lo, alone.hi = alone.lo + span[0], alone.hi + span[0]
				} else {
					alone = {outcome = .Missing}
				}
				if alone.outcome == .Missing {
					alone.lo, alone.hi = 0, 0
				}
				testing.expectf(t, ok && rec == {u64(i), span[0], span[1], moved(err, span[0]), {}} && answer == alone, "%v find stop %v line %d %q: %v %v, want %v %v", spec, stop, i, line, rec, answer, err, alone)
			}
		}
		r = json.records_open(transmute([]u8)src, .Lines, spec)
		for span, i in spans {
			rec, doc, ok := one_scan(&r, &demand)
			line := transmute([]u8)src[span[0]:span[1]]
			alone, err := json.scan(line, &demand, spec)
			got, want := fmt.tprint(testkit.render_answers(&doc), testkit.render_doc(&doc)), fmt.tprint(testkit.render_answers(&alone), testkit.render_doc(&alone))
			testing.expectf(t, ok && rec == {u64(i), span[0], span[1], moved(err, span[0]), {}} && got == want, "%v scan line %d %q: %v %s, want %v %s", spec, i, line, rec, got, err, want)
			tape.destroy(&doc)
			tape.destroy(&alone)
		}
	}
}

// Each element of the root array is read as its value alone is. A fault ends the records with the fault `validate`
// gives for the text, after the elements before it.
@(test)
records_read_the_root_arrays_elements :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		src:      string,
		spec:     json.Spec,
		elements: []string,
	}
	cases := []Case {
		{` [ 1 , {"status":2} , "x" ,[3]] `, .Json, {"1", `{"status":2}`, `"x"`, "[3]"}},
		{`[]`, .Json, {}},
		{"\xef\xbb\xbf[true]", .Json, {"true"}},
		{`[1,]`, .Json, {"1"}},
		{`[1,]`, .Jsonc, {"1"}},
		{`[1 /* c */, // d` + "\n" + `{"status":2}]`, .Jsonc, {"1", `{"status":2}`}},
		{`[1,2 3]`, .Json, {"1", "2"}},
		{`[1,{"status":`, .Json, {"1"}},
		{`[1] x`, .Json, {"1"}},
		{`[1,[2,]]`, .Json, {"1"}},
		{`{"status":1}`, .Json, {}},
		{`5`, .Json, {}},
		{``, .Json, {}},
		{`[{status:1},'x']`, .Json5, {"{status:1}", "'x'"}},
	}
	path := []tape.Step{tape.Name("status")}
	demand, _ := tape.demand_of({path})
	defer tape.destroy_demand(&demand)
	for c in cases {
		src := transmute([]u8)c.src
		want_end := json.validate(src, c.spec)
		r := json.records_open(src, .Elements, c.spec)
		for e, i in c.elements {
			lo := u64(strings.index(c.src, e))
			rec, more := one_validate(&r)
			testing.expectf(t, more && rec == {u64(i), lo, lo + u64(len(e)), nil, {}}, "%q validate %d: %v %v", c.src, i, rec, more)
		}
		_, more := one_validate(&r)
		testing.expectf(t, !more && r.err == want_end, "%q validate end: %v, want %v", c.src, r.err, want_end)
		r = json.records_open(src, .Elements, c.spec)
		for e, i in c.elements {
			lo := u64(strings.index(c.src, e))
			rec, answer, ok := one_find(&r, path, {stop_early = true})
			alone, _ := json.find(transmute([]u8)e, path, c.spec)
			if alone.outcome != .Missing {
				alone.lo, alone.hi = alone.lo + lo, alone.hi + lo
			}
			testing.expectf(t, ok && rec.err == nil && answer == alone, "%q find %d: %v %v, want %v", c.src, i, rec, answer, alone)
		}
		_, _, more = one_find(&r, path)
		testing.expectf(t, !more && r.err == want_end, "%q find end: %v, want %v", c.src, r.err, want_end)
		r = json.records_open(src, .Elements, c.spec)
		for e, i in c.elements {
			rec, doc, ok := one_scan(&r, &demand)
			alone, _ := json.scan(transmute([]u8)e, &demand, c.spec)
			got, want := testkit.render_answers(&doc), testkit.render_answers(&alone)
			testing.expectf(t, ok && rec.err == nil && got == want, "%q scan %d: %v %s, want %s", c.src, i, rec, got, want)
			tape.destroy(&doc)
			tape.destroy(&alone)
		}
		_, _, more = one_scan(&r, &demand)
		testing.expectf(t, !more && r.err == want_end, "%q scan end: %v, want %v", c.src, r.err, want_end)
	}
}

// The budget's depth and steps hold for each line's record, and under `.Elements` the steps count the whole text, as
// `validate` counts them.
@(test)
records_keep_the_budget :: proc(t: ^testing.T) {
	testkit.deadline(t)
	lines := "[[1]]\n[[[1]]]\n{\"a\":[1],\"b\":[2]}\n"
	opts := json.Options{budget = {depth = 2, steps = 2}}
	r := json.records_open(transmute([]u8)lines, .Lines, .Json, opts)
	for span in line_spans(lines) {
		rec, _ := one_validate(&r)
		want := moved(json.validate(transmute([]u8)lines[span[0]:span[1]], .Json, opts), span[0])
		testing.expectf(t, rec.err == want, "%q: %v, want %v", lines[span[0]:span[1]], rec.err, want)
	}
	for src in ([]string{`[[1],[2],[3]]`, `[[1],[[2]]]`, `[1,2,3]`, `{"a":[1],"b":[2],"c":[3]}`, `{"a":[1],"b":[[2]]}`, `{"a":1,"b":2,"c":3}`}) {
		opts = {budget = {depth = 2, steps = 3}}
		r = json.records_open(transmute([]u8)src, .Elements if src[0] == '[' else .Members, .Json, opts)
		for {
			_, more := one_validate(&r)
			if !more {
				break
			}
		}
		want := json.validate(transmute([]u8)src, .Json, opts)
		testing.expectf(t, r.err == want, "%q: %v, want %v", src, r.err, want)
	}
}

// Options no records read takes end the records before any is read: a text in pieces framed other than as lines, and
// a concatenated framing, which JSON has no reading of.
@(test)
records_refuse_options_they_cannot_take :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("{\"a\":1}\n")
	pieces: tape.Pieces
	r := json.records_open(src, .Elements, .Json, {pieces = &pieces})
	_, more := one_validate(&r)
	testing.expectf(t, !more && r.err == tape.Error(tape.Bad_Option{"pieces"}), "pieces: %v", r.err)
	r = json.records_open(src, .Concatenated)
	_, more = one_validate(&r)
	testing.expectf(t, !more && r.err == tape.Error(tape.Bad_Option{"framing"}), "concatenated: %v", r.err)
	r = json.records_open(src, opts = {dups = .Refuse})
	_, _, more = one_find(&r, {tape.Name("a")})
	testing.expectf(t, !more && r.err == tape.Error(tape.Bad_Option{"dups"}) && r.index == 0, "refuse: %v", r.err)
}

// Each member of the root object is read as its value alone is, with its key as written and whether it needs decoding.
// A fault ends the records with the fault `validate` gives for the text, after the members before it.
@(test)
records_read_the_root_objects_members :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Member :: struct {
		key:     string,
		escaped: bool,
		value:   string,
	}
	Case :: struct {
		src:     string,
		spec:    json.Spec,
		members: []Member,
	}
	cases := []Case {
		{` { "a" : 1 , "b":{"status":2} , "c" :"x" ,"d":[3]} `, .Json, {{"a", false, "1"}, {"b", false, `{"status":2}`}, {"c", false, `"x"`}, {"d", false, "[3]"}}},
		{`{}`, .Json, {}},
		{"\xef\xbb\xbf{\"k\":true}", .Json, {{"k", false, "true"}}},
		{`{"a\nb":1,"\u0073tatus":{"status":2},"":null,"é":"é"}`, .Json, {{`a\nb`, true, "1"}, {`\u0073tatus`, true, `{"status":2}`}, {``, false, "null"}, {"é", false, `"é"`}}},
		{`{"a":1,"a":2}`, .Json, {{"a", false, "1"}, {"a", false, "2"}}},
		{`{"a":1,}`, .Json, {{"a", false, "1"}}},
		{`{"a":1,}`, .Jsonc, {{"a", false, "1"}}},
		{`{"a" /* c */ : // d` + "\n" + `1 /* e */, /* f */ "b":[2]}`, .Jsonc, {{"a", false, "1"}, {"b", false, "[2]"}}},
		{`{"a":1,"b" 2}`, .Json, {{"a", false, "1"}}},
		{`{"a":1,"b":`, .Json, {{"a", false, "1"}}},
		{`{"a":1,"b"`, .Json, {{"a", false, "1"}}},
		{`{"a":1,3:4}`, .Json, {{"a", false, "1"}}},
		{`{"a":1} x`, .Json, {{"a", false, "1"}}},
		{`{"a":1,"b":[2,]}`, .Json, {{"a", false, "1"}}},
		{`{"a":`, .Json, {}},
		{`{`, .Json, {}},
		{`[1,2]`, .Json, {}},
		{`5`, .Json, {}},
		{``, .Json, {}},
		{`{status:1,'b':'x',$c_1:{status:2},"d\u0041":3,e\u0041:4}`, .Json5, {{"status", false, "1"}, {"b", false, "'x'"}, {"$c_1", false, "{status:2}"}, {`d\u0041`, true, "3"}, {`e\u0041`, true, "4"}}},
		{`{status:1,}`, .Json5, {{"status", false, "1"}}},
		{`{a:1,,}`, .Json5, {{"a", false, "1"}}},
	}
	path := []tape.Step{tape.Name("status")}
	demand, _ := tape.demand_of({path})
	defer tape.destroy_demand(&demand)
	for c in cases {
		src := transmute([]u8)c.src
		want_end := json.validate(src, c.spec)
		at := 0
		spans := make([][2]u64, len(c.members), context.temp_allocator)
		for m, i in c.members {
			k := at + strings.index(c.src[at:], m.key)
			v := k + len(m.key) + strings.index(c.src[k + len(m.key):], m.value)
			spans[i] = {u64(v), u64(v + len(m.value))}
			at = v + len(m.value)
		}
		check :: proc(t: ^testing.T, what: string, c: Case, rec: tape.Record, i: int, spans: [][2]u64, m: Member) {
			raw, escaped := tape.key_raw(transmute([]u8)c.src, rec.key)
			testing.expectf(t, rec.index == u64(i) && rec.lo == spans[i][0] && rec.hi == spans[i][1] && rec.err == nil, "%q %s %d: %v, want %v", c.src, what, i, rec, spans[i])
			testing.expectf(t, rec.key.role == .Key && string(raw) == m.key && escaped == m.escaped, "%q %s %d key: %q %v, want %q %v", c.src, what, i, raw, escaped, m.key, m.escaped)
		}
		r := json.records_open(src, .Members, c.spec)
		for m, i in c.members {
			rec, more := one_validate(&r)
			testing.expectf(t, more, "%q validate %d: ended with %v", c.src, i, r.err)
			check(t, "validate", c, rec, i, spans, m)
		}
		_, more := one_validate(&r)
		testing.expectf(t, !more && r.err == want_end, "%q validate end: %v, want %v", c.src, r.err, want_end)
		r = json.records_open(src, .Members, c.spec)
		for m, i in c.members {
			rec, answer, ok := one_find(&r, path, {stop_early = true})
			alone, _ := json.find(transmute([]u8)m.value, path, c.spec)
			if alone.outcome != .Missing {
				alone.lo, alone.hi = alone.lo + spans[i][0], alone.hi + spans[i][0]
			}
			testing.expectf(t, ok && answer == alone, "%q find %d: %v, want %v", c.src, i, answer, alone)
			check(t, "find", c, rec, i, spans, m)
		}
		_, _, more = one_find(&r, path)
		testing.expectf(t, !more && r.err == want_end, "%q find end: %v, want %v", c.src, r.err, want_end)
		r = json.records_open(src, .Members, c.spec)
		for m, i in c.members {
			rec, doc, ok := one_scan(&r, &demand)
			alone, _ := json.scan(transmute([]u8)m.value, &demand, c.spec)
			got, want := testkit.render_answers(&doc), testkit.render_answers(&alone)
			testing.expectf(t, ok && got == want, "%q scan %d: %s, want %s", c.src, i, got, want)
			check(t, "scan", c, rec, i, spans, m)
			tape.destroy(&doc)
			tape.destroy(&alone)
		}
		_, _, more = one_scan(&r, &demand)
		testing.expectf(t, !more && r.err == want_end, "%q scan end: %v, want %v", c.src, r.err, want_end)
	}
}

// The records come out the same whatever the size of the batches they are read in, the end of the records included.
@(test)
records_read_alike_in_any_batch_size :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		src:     string,
		framing: tape.Framing,
	}
	lines := record_lines()
	cases := []Case {
		{lines, .Lines},
		{`[1, {"status":2}, "x", [3], {"status":5,"level":"a"}, 7, {"status":8}, 9, [{"status":10}], 11,]`, .Elements},
		{`{"a":1, "b":{"status":2}, "c":"x", "d":[3], "e":{"status":5,"level":"a"}, "f":7, "g":{"status":8}, "h":9} x`, .Members},
	}
	path := []tape.Step{tape.Name("status")}
	demand, _ := tape.demand_of({path, {tape.Name("level")}})
	defer tape.destroy_demand(&demand)
	for c in cases {
		src := transmute([]u8)c.src
		want_recs := make([dynamic]tape.Record, context.temp_allocator)
		want_answers := make([dynamic]tape.Span_Answer, context.temp_allocator)
		want_docs := make([dynamic]string, context.temp_allocator)
		for size in ([]int{1, 2, 3, 7, 100}) {
			recs := make([dynamic]tape.Record, context.temp_allocator)
			answers := make([dynamic]tape.Span_Answer, context.temp_allocator)
			docs := make([dynamic]string, context.temp_allocator)
			out := make([]tape.Record, size, context.temp_allocator)
			found := make([]tape.Span_Answer, size, context.temp_allocator)
			scanned := make([]tape.Document, size, context.temp_allocator)
			r := json.records_open(src, c.framing)
			for {
				n := json.records_validate(&r, out)
				append(&recs, ..out[:n])
				if n < size {
					break
				}
			}
			end := r.err
			r = json.records_open(src, c.framing)
			for {
				n := json.records_find(&r, path, out, found, {stop_early = true})
				append(&answers, ..found[:n])
				if n < size {
					break
				}
			}
			testing.expectf(t, r.err == end, "%q size %d find end: %v, want %v", c.src, size, r.err, end)
			r = json.records_open(src, c.framing)
			for {
				n := json.records_scan(&r, &demand, out, scanned)
				for &doc in scanned[:n] {
					append(&docs, fmt.tprint(testkit.render_answers(&doc), testkit.render_doc(&doc)))
					tape.destroy(&doc)
				}
				if n < size {
					break
				}
			}
			testing.expectf(t, r.err == end, "%q size %d scan end: %v, want %v", c.src, size, r.err, end)
			if size == 1 {
				want_recs, want_answers, want_docs = recs, answers, docs
				continue
			}
			testing.expectf(t, len(recs) == len(want_recs) && len(want_recs) > 0, "%q size %d: %d records, want %d", c.src, size, len(recs), len(want_recs))
			for rec, i in recs {
				if i < len(want_recs) {
					testing.expectf(t, rec == want_recs[i] && answers[i] == want_answers[i] && docs[i] == want_docs[i], "%q size %d record %d: %v %v %s, want %v %v %s", c.src, size, i, rec, answers[i], docs[i], want_recs[i], want_answers[i], want_docs[i])
				}
			}
		}
	}
}

// A finder and a scanner kept from record to record read each record as a read of it alone does, after records that
// left rings grown, answers made, and paths settled or not.
@(test)
records_reset_their_readers_between_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	long := strings.builder_make(context.temp_allocator)
	strings.write_string(&long, `{"a":[`)
	for i in 0 ..< 200 {
		fmt.sbprintf(&long, `%s{"b":%d}`, "," if i > 0 else "", i)
	}
	strings.write_string(&long, `]}`)
	lines := []string {
		`{"a":[1,2,3,{"b":4}]}`,
		strings.to_string(long),
		`{"a":[{"b":1},{"b":2}],"c":1}`,
		`{"a":[]}`,
		`{"a":5}`,
		`{"a":[{"b":1},{"c":2},{"b":3}]}`,
		`[1,2]`,
		`{"a":[1,2,3,4,5,6,7,8,9,10]}`,
		`{"a":[1,2,`,
		strings.to_string(long),
		`{"a":[9,8]}`,
		`{"a":[{"b":1}]}  x`,
		`{"a":{"b":1}} `,
	}
	for line in lines {
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	src := transmute([]u8)strings.to_string(b)
	paths := [][]tape.Step {
		{tape.Name("a"), tape.Index(-1)},
		{tape.Name("a"), tape.Index(-150)},
		{tape.Name("a"), tape.Index(2)},
		{tape.Name("a"), tape.Slice{lo = -2}},
		{tape.Name("a"), tape.All{}, tape.Name("b")},
		{tape.Name("a")},
	}
	spans := line_spans(string(src))
	for path in paths {
		demand, _ := tape.demand_of({path, {tape.Name("c")}})
		defer tape.destroy_demand(&demand)
		for stop in ([]bool{false, true}) {
			r := json.records_open(src)
			for span, i in spans {
				rec, answer, ok := one_find(&r, path, {stop_early = stop})
				line := src[span[0]:span[1]]
				alone, err := json.find(line, path, .Json, {stop_early = stop})
				if err == nil {
					alone.lo, alone.hi = alone.lo + span[0], alone.hi + span[0]
				} else {
					alone = {outcome = .Missing}
				}
				if alone.outcome == .Missing {
					alone.lo, alone.hi = 0, 0
				}
				testing.expectf(t, ok && rec.err == moved(err, span[0]) && answer == alone, "%v find stop %v line %d: %v %v, want %v %v", path, stop, i, rec, answer, err, alone)
			}
		}
		r := json.records_open(src)
		for span, i in spans {
			rec, doc, ok := one_scan(&r, &demand)
			alone, err := json.scan(src[span[0]:span[1]], &demand, .Json)
			got, want := fmt.tprint(testkit.render_answers(&doc), testkit.render_doc(&doc)), fmt.tprint(testkit.render_answers(&alone), testkit.render_doc(&alone))
			testing.expectf(t, ok && rec.err == moved(err, span[0]) && got == want, "%v scan line %d: %v %s, want %v %s", path, i, rec, got, err, want)
			tape.destroy(&doc)
			tape.destroy(&alone)
		}
	}
}

// A record the read refuses for its budget or its memory ends with that error as a read of it alone does, and the
// records go on after it, under `.Elements` and `.Members` as under `.Lines`.
@(test)
records_go_on_after_a_record_the_budget_refuses :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"a":[`)
	for i in 0 ..< 70 {
		fmt.sbprintf(&b, "%s%d", "," if i > 0 else "", i)
	}
	strings.write_string(&b, `]}`)
	big := strings.to_string(b)
	values := []string{big, `{"a":2}`, big, `{"a":3}`}
	Case :: struct {
		framing: tape.Framing,
		src:     string,
	}
	cases := []Case {
		{.Elements, strings.concatenate({"[", strings.join(values, ", ", context.temp_allocator), "]"}, context.temp_allocator)},
		{.Members, strings.concatenate({`{"k0":`, strings.join(values, `, "k":`, context.temp_allocator), "}"}, context.temp_allocator)},
		{.Lines, strings.join(values, "\n", context.temp_allocator)},
	}
	scan_path := []tape.Step{tape.Name("a")}
	ring_path := []tape.Step{tape.Name("a"), tape.Index(-65)}
	demand, _ := tape.demand_of({scan_path})
	defer tape.destroy_demand(&demand)
	limits := []json.Options{{budget = {nodes = 10}}, {budget = {memory = 1200}}}
	for c in cases {
		src := transmute([]u8)c.src
		for opts in limits {
			spans := make([dynamic][2]u64, context.temp_allocator)
			at := 0
			for v in values {
				lo := at + strings.index(c.src[at:], v)
				append(&spans, [2]u64{u64(lo), u64(lo + len(v))})
				at = lo + len(v)
			}
			refused := 0
			r := json.records_open(src, c.framing, .Json, opts)
			for span, i in spans {
				rec, doc, ok := one_scan(&r, &demand)
				alone, err := json.scan(src[span[0]:span[1]], &demand, .Json, {}, opts)
				if err != nil {
					refused += 1
					_, p, _ := tape.answer({doc = &doc}, 0, 0)
					testing.expectf(t, p == .Missing, "%v %v scan %d: a refused record answers %v", c.framing, opts.budget, i, p)
				}
				testing.expectf(t, ok && rec.index == u64(i) && rec.lo == span[0] && rec.hi == span[1] && rec.err == moved(err, span[0]), "%v %v scan %d: %v %v, want %v", c.framing, opts.budget, i, rec, ok, err)
				tape.destroy(&doc)
				tape.destroy(&alone)
			}
			_, _, more := one_scan(&r, &demand)
			testing.expectf(t, !more && r.err == nil && refused > 0, "%v %v scan end: %v, %d refused", c.framing, opts.budget, r.err, refused)
			refused = 0
			r = json.records_open(src, c.framing, .Json, opts)
			for span, i in spans {
				rec, answer, ok := one_find(&r, ring_path)
				alone, err := json.find(src[span[0]:span[1]], ring_path, .Json, {}, opts)
				if err != nil {
					refused += 1
				} else if alone.outcome != .Missing {
					alone.lo, alone.hi = alone.lo + span[0], alone.hi + span[0]
				}
				testing.expectf(t, ok && rec.index == u64(i) && rec.lo == span[0] && rec.hi == span[1] && rec.err == moved(err, span[0]) && (err != nil || answer == alone), "%v %v find %d: %v %v, want %v", c.framing, opts.budget, i, rec, ok, err)
			}
			_, _, more = one_find(&r, ring_path)
			testing.expectf(t, !more && r.err == nil, "%v %v find end: %v", c.framing, opts.budget, r.err)
		}
	}
}

// The records a caller picking the format at run time makes through `tape.Reads` read as `records_open`'s do.
@(test)
records_read_alike_through_the_format_handle :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		src:     string,
		framing: tape.Framing,
		spec:    json.Spec,
	}
	cases := []Case {
		{record_lines(), .Lines, .Json},
		{`[1, {"status":2}, "x", [3], {"status":5,"level":"a"}, 7,]`, .Elements, .Jsonc},
		{`{"a":1, b:{"status":2}, "c":[3]} x`, .Members, .Json5},
	}
	path := []tape.Step{tape.Name("status")}
	demand, _ := tape.demand_of({path, {tape.Name("level")}})
	defer tape.destroy_demand(&demand)
	for c in cases {
		src := transmute([]u8)c.src
		reads := json.reads(c.spec)
		out, want: [64]tape.Record
		found, want_found: [64]tape.Span_Answer
		docs, want_docs: [64]tape.Document
		for op in 0 ..< 3 {
			r := json.records_open(src, c.framing, c.spec)
			made, err := reads.records(json.as(c.spec), src, c.framing, {}, context.allocator)
			testing.expectf(t, err == nil, "%q: %v", c.src, err)
			n, m: int
			switch op {
			case 0:
				n, m = json.records_validate(&r, want[:]), tape.records_validate(made, out[:])
			case 1:
				n, m = json.records_find(&r, path, want[:], want_found[:]), tape.records_find(made, path, out[:], found[:])
			case 2:
				n, m = json.records_scan(&r, &demand, want[:], want_docs[:]), tape.records_scan(made, &demand, out[:], docs[:])
			}
			testing.expectf(t, n == m && n > 0 && r.err == made.err, "%q op %d: %d records ending %v, want %d ending %v", c.src, op, m, made.err, n, r.err)
			for i in 0 ..< min(n, m) {
				testing.expectf(t, out[i] == want[i] && found[i] == want_found[i], "%q op %d record %d: %v %v, want %v %v", c.src, op, i, out[i], found[i], want[i], want_found[i])
				if op == 2 {
					testing.expectf(t, testkit.render_doc(&docs[i]) == testkit.render_doc(&want_docs[i]), "%q record %d: %s, want %s", c.src, i, testkit.render_doc(&docs[i]), testkit.render_doc(&want_docs[i]))
					tape.destroy(&docs[i])
					tape.destroy(&want_docs[i])
				}
			}
			tape.destroy_records(made)
		}
	}
}

// Each record of a text answers as the text of that record alone does, for its verdict, each path found and the scan of
// them, whole and in windows of several sizes.
@(test)
records_answer_as_their_own_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := transmute([]u8)record_lines()
	paths := [][]tape.Step{{tape.Name("status")}, {tape.Name("level")}, {tape.Name("id")}, {tape.Index(0)}, {tape.All{}}, {tape.Name("zz")}}
	for spec in json.Spec {
		for cuts in ([][]int{nil, {len(src) / 2}, {1, 2, 3}, testkit.cuts_by(len(src), 7), testkit.cuts_by(len(src), 64), testkit.cuts_by(len(src), 500)}) {
			run := testkit.Piece_Run{src, json.reads(spec), json.as(spec), {}, cuts}
			if !testkit.records_alone_agree(t, run, {}, paths, "lines") {
				return
			}
		}
	}
}
