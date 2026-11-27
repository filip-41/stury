package json_tests

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// The next record with its error, as a find with no path gives every record, the form the tests follow the records
// through. A validate keeps only the records that do not read, which the records laws hold to a find's.
@(private = "file")
one_record :: proc(r: ^json.Records) -> (rec: tape.Record, more: bool) {
	rec, _, more = one_find(r, nil)
	return
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
		defer tape.destroy_records(&r)
		for span, i in spans {
			rec, more := one_record(&r)
			line := transmute([]u8)src[span[0]:span[1]]
			want := moved(json.validate(line, spec), span[0])
			testing.expectf(t, more && rec == {span[0], span[1], want, {}}, "%v validate line %d %q: %v %v, want %v", spec, i, line, rec, more, want)
		}
		_, more := one_record(&r)
		testing.expectf(t, !more && r.err == nil && r.index == u64(len(spans)), "%v validate end: %v %v", spec, r.err, r.index)
		for stop in ([]bool{false, true}) {
			tape.destroy_records(&r)
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
				testing.expectf(t, ok && rec == {span[0], span[1], moved(err, span[0]), {}} && answer == alone, "%v find stop %v line %d %q: %v %v, want %v %v", spec, stop, i, line, rec, answer, err, alone)
			}
		}
		tape.destroy_records(&r)
		r = json.records_open(transmute([]u8)src, .Lines, spec)
		for span, i in spans {
			rec, doc, ok := one_scan(&r, &demand)
			line := transmute([]u8)src[span[0]:span[1]]
			alone, err := json.scan(line, &demand, spec)
			got, want := fmt.tprint(testkit.render_answers(&doc), testkit.render_doc(&doc)), fmt.tprint(testkit.render_answers(&alone), testkit.render_doc(&alone))
			testing.expectf(t, ok && rec == {span[0], span[1], moved(err, span[0]), {}} && got == want, "%v scan line %d %q: %v %s, want %v %s", spec, i, line, rec, got, err, want)
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
		// A root of another kind holds no elements.
		want_end := json.Error(json.Bad_Option{"framing"}) if c.src == `{"status":1}` || c.src == `5` else json.validate(src, c.spec)
		r := json.records_open(src, .Elements, c.spec)
		defer tape.destroy_records(&r)
		for e, i in c.elements {
			lo := u64(strings.index(c.src, e))
			rec, more := one_record(&r)
			testing.expectf(t, more && rec == {lo, lo + u64(len(e)), nil, {}}, "%q validate %d: %v %v", c.src, i, rec, more)
		}
		_, more := one_record(&r)
		testing.expectf(t, !more && r.err == want_end, "%q validate end: %v, want %v", c.src, r.err, want_end)
		tape.destroy_records(&r)
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
		tape.destroy_records(&r)
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
	defer tape.destroy_records(&r)
	for span in line_spans(lines) {
		rec, _ := one_record(&r)
		want := moved(json.validate(transmute([]u8)lines[span[0]:span[1]], .Json, opts), span[0])
		testing.expectf(t, rec.err == want, "%q: %v, want %v", lines[span[0]:span[1]], rec.err, want)
	}
	for src in ([]string{`[[1],[2],[3]]`, `[[1],[[2]]]`, `[1,2,3]`, `{"a":[1],"b":[2],"c":[3]}`, `{"a":[1],"b":[[2]]}`, `{"a":1,"b":2,"c":3}`}) {
		opts = {budget = {depth = 2, steps = 3}}
		tape.destroy_records(&r)
		r = json.records_open(transmute([]u8)src, .Elements if src[0] == '[' else .Members, .Json, opts)
		for {
			_, more := one_record(&r)
			if !more {
				break
			}
		}
		want := json.validate(transmute([]u8)src, .Json, opts)
		testing.expectf(t, r.err == want, "%q: %v, want %v", src, r.err, want)
	}
}

// Options no records read takes end the records before any is read: a path under `.Lines`, `.Seq` or `.Concatenated`,
// and a policy for repeated keys a path read refuses.
@(test)
records_refuse_options_they_cannot_take :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("{\"a\":1}\n")
	for framing in ([]tape.Framing{.Lines, .Seq, .Concatenated}) {
		r := json.records_open(src, framing, path = {tape.Name("a")})
		defer tape.destroy_records(&r)
		_, more := one_record(&r)
		testing.expectf(t, !more && r.err == tape.Error(tape.Bad_Option{"path"}), "%v with path: %v", framing, r.err)
	}
	r := json.records_open(src, opts = {dups = .Refuse})
	defer tape.destroy_records(&r)
	_, _, more := one_find(&r, {tape.Name("a")})
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
		// A root of another kind holds no members.
		want_end := json.Error(json.Bad_Option{"framing"}) if c.src == `[1,2]` || c.src == `5` else json.validate(src, c.spec)
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
			testing.expectf(t, rec.lo == spans[i][0] && rec.hi == spans[i][1] && rec.err == nil, "%q %s %d: %v, want %v", c.src, what, i, rec, spans[i])
			testing.expectf(t, rec.key.role == .Key && string(raw) == m.key && escaped == m.escaped, "%q %s %d key: %q %v, want %q %v", c.src, what, i, raw, escaped, m.key, m.escaped)
		}
		r := json.records_open(src, .Members, c.spec)
		defer tape.destroy_records(&r)
		for m, i in c.members {
			rec, more := one_record(&r)
			testing.expectf(t, more, "%q validate %d: ended with %v", c.src, i, r.err)
			check(t, "validate", c, rec, i, spans, m)
		}
		_, more := one_record(&r)
		testing.expectf(t, !more && r.err == want_end, "%q validate end: %v, want %v", c.src, r.err, want_end)
		tape.destroy_records(&r)
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
		tape.destroy_records(&r)
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
			defer tape.destroy_records(&r)
			for {
				n := json.records_find(&r, nil, out, found)
				append(&recs, ..out[:n])
				if n < size {
					break
				}
			}
			end := r.err
			tape.destroy_records(&r)
			// A validate keeps the records that do not read, in order.
			r = json.records_open(src, c.framing)
			bad := make([dynamic]tape.Record, context.temp_allocator)
			for {
				n := json.records_validate(&r, out)
				append(&bad, ..out[:n])
				if n < size {
					break
				}
			}
			k := 0
			for rec in recs {
				if rec.err != nil {
					testing.expectf(t, k < len(bad) && bad[k] == rec, "%q size %d bad record %d: %v, want %v", c.src, size, k, bad[k] if k < len(bad) else tape.Record{}, rec)
					k += 1
				}
			}
			testing.expectf(t, k == len(bad) && r.err == end && r.index == u64(len(recs)), "%q size %d validate: %d bad records ending %v, want %d ending %v", c.src, size, len(bad), r.err, k, end)
			tape.destroy_records(&r)
			r = json.records_open(src, c.framing)
			for {
				n := json.records_find(&r, path, out, found, {stop_early = true})
				append(&answers, ..found[:n])
				if n < size {
					break
				}
			}
			testing.expectf(t, r.err == end, "%q size %d find end: %v, want %v", c.src, size, r.err, end)
			tape.destroy_records(&r)
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
			defer tape.destroy_records(&r)
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
		defer tape.destroy_records(&r)
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
			defer tape.destroy_records(&r)
			for span, i in spans {
				rec, doc, ok := one_scan(&r, &demand)
				alone, err := json.scan(src[span[0]:span[1]], &demand, .Json, {}, opts)
				if err != nil {
					refused += 1
					_, p, _ := tape.answer({doc = &doc}, 0, 0)
					testing.expectf(t, p == .Missing, "%v %v scan %d: a refused record answers %v", c.framing, opts.budget, i, p)
				}
				testing.expectf(t, ok && rec.lo == span[0] && rec.hi == span[1] && rec.err == moved(err, span[0]), "%v %v scan %d: %v %v, want %v", c.framing, opts.budget, i, rec, ok, err)
				tape.destroy(&doc)
				tape.destroy(&alone)
			}
			_, _, more := one_scan(&r, &demand)
			testing.expectf(t, !more && r.err == nil && refused > 0, "%v %v scan end: %v, %d refused", c.framing, opts.budget, r.err, refused)
			refused = 0
			tape.destroy_records(&r)
			r = json.records_open(src, c.framing, .Json, opts)
			for span, i in spans {
				rec, answer, ok := one_find(&r, ring_path)
				alone, err := json.find(src[span[0]:span[1]], ring_path, .Json, {}, opts)
				if err != nil {
					refused += 1
				} else if alone.outcome != .Missing {
					alone.lo, alone.hi = alone.lo + span[0], alone.hi + span[0]
				}
				testing.expectf(t, ok && rec.lo == span[0] && rec.hi == span[1] && rec.err == moved(err, span[0]) && (err != nil || answer == alone), "%v %v find %d: %v %v, want %v", c.framing, opts.budget, i, rec, ok, err)
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
			defer tape.destroy_records(&r)
			made, err := reads.records(json.as(c.spec), src, c.framing, {}, nil, context.allocator)
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
			testing.expectf(t, n == m && (n > 0 || op == 0) && r.err == made.err && r.index == made.index, "%q op %d: %d records ending %v, want %d ending %v", c.src, op, m, made.err, n, r.err)
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

// Records at a path, over the suites' files and random texts of every grammar, are the children of the container the
// path reaches in the build, each read as the build reads it, and end with the verdict `validate` gives for the text.
@(test)
records_at_a_path_agree_with_the_build :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x7ec0)
	read := 0
	files := corpus_files()
	defer delete(files)
	for file in files {
		read += testkit.records_at_agree(t, json.reads(file.spec), json.as(file.spec), file.data, {}, file.name)
	}
	for f in FLAVORS {
		for _ in 0 ..< testkit.rounds(100) {
			src := random_text(f)
			read += testkit.records_at_agree(t, json.reads(f.spec), json.as(f.spec), src, flavor_options(f), "generated")
		}
	}
	testing.expectf(t, read > 1000, "%d containers read", read)
}

// Records at a path take the members of a repeated key as `find` does: the first under `.First`, and the last under
// `.Last`, but for one met once a record was given, which ends the records at its key. `.Group` takes every member in
// document order, and `.All` is refused. A value of another kind than the framing takes is refused, null included, and
// a path the text has no value for holds no records.
@(test)
records_at_a_path_follow_the_policy_for_repeated_keys :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		src:   string,
		path:  []tape.Step,
		dups:  tape.Duplicates,
		want:  []string,
		end:   tape.Error,
	}
	a, ab := []tape.Step{tape.Name("a")}, []tape.Step{tape.Name("a"), tape.Name("b")}
	twice := `{"a":[1],"a":[2,3]}`
	scalar := `{"a":1,"a":[2,3]}`
	empty := `{"a":[],"a":[2]}`
	nested := `{"a":{"b":[1]},"a":{"b":[2,3]}}`
	inner := `{"a":{"b":[1],"b":[2,3]}}`
	framing := tape.Error(tape.Bad_Option{"framing"})
	cases := []Case {
		{twice, a, .First, {"1"}, nil},
		{twice, a, .Last, {"1"}, tape.Fault{at = 9, kind = .Duplicate_Key}},
		{twice, a, .Default, {"1"}, tape.Fault{at = 9, kind = .Duplicate_Key}},
		{twice, a, .Group, {"1", "2", "3"}, nil},
		{twice, a, .All, {}, tape.Bad_Option{"dups"}},
		{scalar, a, .First, {}, framing},
		{scalar, a, .Last, {"2", "3"}, nil},
		{scalar, a, .Group, {}, framing},
		{empty, a, .First, {}, nil},
		{empty, a, .Last, {"2"}, nil},
		{empty, a, .Group, {"2"}, nil},
		{nested, ab, .First, {"1"}, nil},
		{nested, ab, .Last, {"1"}, tape.Fault{at = 15, kind = .Duplicate_Key}},
		{nested, ab, .Group, {"1", "2", "3"}, nil},
		{inner, ab, .First, {"1"}, nil},
		{inner, ab, .Last, {"1"}, tape.Fault{at = 14, kind = .Duplicate_Key}},
		{inner, ab, .Group, {"1", "2", "3"}, nil},
		{`{"a":{"b":1},"a":{"b":[2]}}`, ab, .Last, {"2"}, nil},
		{`{"a":{"b":1},"a":{"c":[2]}}`, ab, .Last, {}, nil},
		{`{"a":{"b":1},"a":{"c":[2]}}`, ab, .First, {}, framing},
		{`{"a":[2],"a":1}`, a, .Last, {"2"}, tape.Fault{at = 9, kind = .Duplicate_Key}},
		{`{"a":1}`, a, .Last, {}, framing},
		{`{"a":null}`, a, .First, {}, framing},
		{`{"a":{}}`, a, .Last, {}, framing},
		{`{"a":1,"b":[2]}`, ab, .Last, {}, nil},
		{`{"b":[1]}`, a, .Last, {}, nil},
		{`[[1],{"a":2}]`, {tape.Index(1)}, .Last, {}, framing},
	}
	for c in cases {
		src := transmute([]u8)c.src
		opts := json.Options{dups = c.dups}
		r := json.records_open(src, .Elements, .Json, opts, c.path)
		defer tape.destroy_records(&r)
		got := make([dynamic]string, context.temp_allocator)
		for {
			rec, more := one_record(&r)
			if !more {
				break
			}
			append(&got, c.src[rec.lo:rec.hi])
		}
		ok := len(got) == len(c.want) && testkit.same_refusal(r.err, c.end)
		for g, i in got {
			ok &&= i < len(c.want) && g == c.want[i]
		}
		testing.expectf(t, ok, "%s %v under %v: %v ending %v, want %v ending %v", c.src, c.path, c.dups, got[:], r.err, c.want, c.end)
		// The records of a policy that takes one member are the elements of the container `find` answers.
		if c.end == nil && len(got) > 0 && c.dups != .Group {
			answer, err := json.find(src, c.path, .Json, {}, opts)
			testing.expectf(t, err == nil && answer.kind == .Array && answer.lo < u64(strings.index(c.src, got[0])) && c.src[answer.hi - 1] == ']', "%s %v under %v: find %v %v", c.src, c.path, c.dups, answer, err)
		}
	}
}

// The values records at a path pass are judged under the read's memory budget, as `validate` judges them.
@(test)
records_at_a_path_judge_what_they_pass_within_the_budget :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := strings.concatenate({`{"s":`, strings.repeat("[", 5000, context.temp_allocator), strings.repeat("]", 5000, context.temp_allocator), `,"a":[1,2,3]}`}, context.temp_allocator)
	src := transmute([]u8)text
	opts := json.Options{budget = {memory = 4096}}
	want := json.validate(src, .Json, opts)
	testing.expectf(t, want == tape.Error(tape.Exceeded{at = tape.NO_BYTE, kind = .Memory}), "validate: %v", want)
	r := json.records_open(src, .Elements, .Json, opts, {tape.Name("a")})
	defer tape.destroy_records(&r)
	out: [4]tape.Record
	n := json.records_validate(&r, out[:])
	testing.expectf(t, n == 0 && r.err == want && r.index == 0, "records: %d of %d read, %v", n, r.index, r.err)
}

// A fault early in a window that more bytes follow ends the records there, and the window's caller keeps none of the
// text past it.
@(test)
records_in_pieces_end_at_a_fault_the_window_holds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := strings.concatenate({`{"a":[1,x,`, strings.repeat("2,", 4096, context.temp_allocator)}, context.temp_allocator)
	for framing in ([]tape.Framing{.Elements, .Members}) {
		p := tape.Pieces{allocator = context.allocator}
		defer tape.destroy(&p)
		path := []tape.Step{tape.Name("a")} if framing == .Elements else nil
		r := json.records_open(transmute([]u8)text, framing, .Json, {pieces = &p}, path)
		defer tape.destroy_records(&r)
		out: [4]tape.Record
		n := json.records_validate(&r, out[:])
		f, faulted := r.err.(tape.Fault)
		testing.expectf(t, faulted && f.kind == .Bad_Char && f.at == 8 && !p.more && n == 0, "%v: %d records, %v, more %v keep %v", framing, n, r.err, p.more, p.keep)
	}
}

// A value off the path that the windows cut is passed a child at a time, nested values too, so each window's caller
// keeps only the child its end cuts.
@(test)
records_in_pieces_keep_only_the_child_a_window_cuts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	WINDOW :: 24
	text := strings.concatenate({`{"s":[`, strings.repeat(`[1,{"b":[2,3]}],`, 300, context.temp_allocator), `0],"a":[1,2,3]}`}, context.temp_allocator)
	src := transmute([]u8)text
	p := tape.Pieces{allocator = context.allocator}
	defer tape.destroy(&p)
	r := json.records_open(src[:WINDOW], .Elements, .Json, {pieces = &p}, {tape.Name("a")})
	defer tape.destroy_records(&r)
	out: [4]tape.Record
	records, kept := 0, u64(0)
	for {
		records += json.records_validate(&r, out[:])
		if !p.more {
			break
		}
		kept = max(kept, p.at - p.keep)
		end := min(p.at + WINDOW, u64(len(src)))
		p.from, p.last = p.keep, end == u64(len(src))
		testing.expect_value(t, tape.records_window(&r, src[p.keep:end]), nil)
	}
	testing.expectf(t, r.err == nil && r.index == 3 && records == 0 && kept < WINDOW, "%d records, %v, kept %d", r.index, r.err, kept)
}

@(test)
records_seq_rfc7464_semantics :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Empty RS runs are skipped; leading bytes before first RS are `unframed`; top-level numbers without trailing
	// whitespace are `cut_number`; multi-line JSON values inside RS are valid; faults do not stop later records.
	src := "\x1e{\"a\":1}\n\x1e\x1e  \n\x1e{\n\"a\": 2\n}\x1e123\n\x1e456\x1e{\"a\":bad}\x1e{\"a\":3}\n"
	path := []tape.Step{tape.Name("a")}
	demand, _ := tape.demand_of({path})
	defer tape.destroy_demand(&demand)

	for spec in json.Spec {
		r := json.records_open(transmute([]u8)src, .Seq, spec)
		defer tape.destroy_records(&r)
		out: [16]tape.Record
		ans: [16]tape.Span_Answer
		n := json.records_find(&r, path, out[:], ans[:], {stop_early = true})
		testing.expectf(t, n == 6 && r.err == nil && r.index == 6, "%v seq count=%d err=%v idx=%d", spec, n, r.err, r.index)
		testing.expectf(t, out[0].err == nil && ans[0].outcome == .Found, "%v rec0: %v %v", spec, out[0], ans[0])
		testing.expectf(t, out[1].err == nil && ans[1].outcome == .Found, "%v rec1: %v %v", spec, out[1], ans[1])
		testing.expectf(t, out[2].err == nil, "%v rec2 (123\\n): %v", spec, out[2])
		// rec3 is `456` with no whitespace before 0x1E -> cut_number
		f3, ok3 := out[3].err.(tape.Fault)
		testing.expectf(t, ok3 && f3.kind == .Bad_Number && tape.fault_rule(f3).code == "cut_number", "%v rec3: %v", spec, out[3].err)
		// rec4 is `{"a":bad}` -> fault
		testing.expectf(t, out[4].err != nil && ans[4].outcome == .Missing, "%v rec4: %v %v", spec, out[4], ans[4])
		// rec5 is `{"a":3}\n` -> valid after fault
		testing.expectf(t, out[5].err == nil && ans[5].outcome == .Found, "%v rec5: %v %v", spec, out[5], ans[5])

		// Validate returns only the 2 bad records (rec3 and rec4).
		rv := json.records_open(transmute([]u8)src, .Seq, spec)
		defer tape.destroy_records(&rv)
		bad: [8]tape.Record
		nv := json.records_validate(&rv, bad[:])
		testing.expectf(t, nv == 2 && rv.index == 6 && rv.err == nil, "%v seq validate: nv=%d idx=%d err=%v", spec, nv, rv.index, rv.err)
		testing.expectf(t, bad[0] == out[3] && bad[1] == out[4], "%v seq validate mismatch: %v vs %v", spec, bad[:nv], out[3:5])

		// Scan agrees with find.
		rs := json.records_open(transmute([]u8)src, .Seq, spec)
		defer tape.destroy_records(&rs)
		sout: [16]tape.Record
		docs: [16]tape.Document
		ns := json.records_scan(&rs, &demand, sout[:], docs[:])
		testing.expectf(t, ns == 6 && rs.err == nil, "%v seq scan: ns=%d err=%v", spec, ns, rs.err)
		for i in 0 ..< ns {
			testing.expectf(t, sout[i] == out[i], "%v seq scan rec %d: %v vs %v", spec, i, sout[i], out[i])
		}
	}

	// Unframed bytes before first 0x1E -> `unframed`, then framed record succeeds.
	unframed := " {\"x\":1}\x1e{\"x\":2}\n"
	ru := json.records_open(transmute([]u8)unframed, .Seq, .Json)
	defer tape.destroy_records(&ru)
	uout: [4]tape.Record
	uans: [4]tape.Span_Answer
	nu := json.records_find(&ru, {tape.Name("x")}, uout[:], uans[:])
	testing.expectf(t, nu == 2 && ru.err == nil, "unframed: nu=%d err=%v", nu, ru.err)
	fu, oku := uout[0].err.(tape.Fault)
	testing.expectf(t, oku && fu.kind == .Bad_Char && tape.fault_rule(fu).code == "unframed" && fu.at == 1, "unframed err: %v", uout[0].err)
	testing.expectf(t, uout[1].err == nil && uans[1].outcome == .Found, "after unframed: %v %v", uout[1], uans[1])

	// Pieces agreement across chunk sizes for `.Seq`.
	for step in ([]int{1, 3, 7, 19}) {
		p: tape.Pieces
		defer tape.destroy(&p)
		bs := transmute([]u8)src
		p.last = step >= len(bs)
		rp := json.records_open(bs[:min(step, len(bs))], .Seq, .Json, {pieces = &p})
		defer tape.destroy_records(&rp)
		got := make([dynamic]tape.Record, context.temp_allocator)
		for {
			buf: [4]tape.Record
			ans_buf: [4]tape.Span_Answer
			k := json.records_find(&rp, path, buf[:], ans_buf[:])
			for i in 0 ..< k {
				append(&got, buf[i])
			}
			if !p.more {
				break
			}
			p.from = p.keep
			next_to := min(int(p.at) + step, len(bs))
			p.last = next_to == len(bs)
			werr := tape.records_window(&rp, bs[p.from:next_to])
			testing.expectf(t, werr == nil, "seq pieces step=%d window err=%v", step, werr)
		}
		testing.expectf(t, len(got) == 6 && rp.err == nil, "seq pieces step=%d len=%d err=%v", step, len(got), rp.err)
	}
}

@(test)
records_concatenated_and_skip_quarantine :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Concatenated values: self-delimiting + whitespace separated + comments in JSONC.
	src := `{"a":1}{"a":2} [3] "hi" 42 true false null`
	r := json.records_open(transmute([]u8)src, .Concatenated, .Json)
	defer tape.destroy_records(&r)
	out: [16]tape.Record
	ans: [16]tape.Span_Answer
	n := json.records_find(&r, {tape.Name("a")}, out[:], ans[:])
	testing.expectf(t, n == 8 && r.err == nil, "concat n=%d err=%v", n, r.err)
	testing.expectf(t, string(src[out[0].lo:out[0].hi]) == `{"a":1}` && ans[0].outcome == .Found, "c0")
	testing.expectf(t, string(src[out[1].lo:out[1].hi]) == `{"a":2}` && ans[1].outcome == .Found, "c1")
	testing.expectf(t, string(src[out[4].lo:out[4].hi]) == `42`, "c4")
	testing.expectf(t, string(src[out[7].lo:out[7].hi]) == `null`, "c7")

	// `runs_on`: `1x` and `1,2` fault at the offending byte rather than yielding `1`.
	for bad_src in ([]string{"1x", "1,2", "truefalse", "1/2"}) {
		rb := json.records_open(transmute([]u8)bad_src, .Concatenated, .Json)
		defer tape.destroy_records(&rb)
		bout: [4]tape.Record
		bans: [4]tape.Span_Answer
		nb := json.records_find(&rb, nil, bout[:], bans[:])
		f, is_f := rb.err.(tape.Fault)
		testing.expectf(t, nb == 0 && is_f && tape.fault_rule(f).code == "trailing", "%q: nb=%d err=%v", bad_src, nb, rb.err)
	}

	// `records_skip` on `.Concatenated` resumes at next line (and on fault's own line when fault starts a fresh line).
	dirty := "{\"a\":1}\n{bad}\n{\"a\":2}\n123\n{\"a\":3}\n"
	rs := json.records_open(transmute([]u8)dirty, .Concatenated, .Json)
	defer tape.destroy_records(&rs)
	rs.skip_bad = true
	vbad: [8]tape.Record
	nv := json.records_validate(&rs, vbad[:])
	testing.expectf(t, nv == 1 && rs.err == nil && rs.index == 5, "concat skip_bad validate: nv=%d idx=%d err=%v", nv, rs.index, rs.err)
	testing.expectf(t, string(dirty[vbad[0].lo:vbad[0].hi]) == "{bad}", "skipped text=%q", dirty[vbad[0].lo:vbad[0].hi])

	// Quarantine sink on `.Lines`, `.Seq`, and `.Concatenated` yields ONLY valid records in `out`/`answers`.
	for tc in ([]struct{ text: string, framing: tape.Framing }{
		{"{\"a\":1}\n{bad}\n{\"a\":2}\n", .Lines},
		{"\x1e{\"a\":1}\n\x1e{bad}\n\x1e{\"a\":2}\n", .Seq},
		{"{\"a\":1}\n{bad}\n{\"a\":2}\n", .Concatenated},
	}) {
		q := make([dynamic]tape.Bad_Record)
		defer delete(q)
		rq := json.records_open(transmute([]u8)tc.text, tc.framing, .Json)
		defer tape.destroy_records(&rq)
		rq.quarantine = &q
		qout: [8]tape.Record
		qans: [8]tape.Span_Answer
		nq := json.records_find(&rq, {tape.Name("a")}, qout[:], qans[:])
		testing.expectf(t, nq == 2 && len(q) == 1 && rq.err == nil, "%v quarantine: nq=%d bad=%d err=%v", tc.framing, nq, len(q), rq.err)
		testing.expectf(t, qout[0].err == nil && qout[1].err == nil && qans[0].outcome == .Found && qans[1].outcome == .Found, "%v valid outputs", tc.framing)
		testing.expectf(t, strings.trim_space(string(q[0].text)) == "{bad}" && q[0].err != nil, "%v bad entry: %q %v", tc.framing, q[0].text, q[0].err)
	}

	// `records_skip` returns false on `.Elements` (non-resumable framing).
	re := json.records_open(transmute([]u8)string("[1, bad, 2]"), .Elements, .Json)
	defer tape.destroy_records(&re)
	eout: [4]tape.Record
	_ = json.records_validate(&re, eout[:])
	_, skipped := tape.records_skip(&re)
	testing.expectf(t, !skipped && re.err != nil, "elements must not skip")
}

@(test)
records_max_bytes_limit :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Whole-text max_bytes: first record fits (8 bytes), second exceeds (20 bytes) -> Too_Wide (`records.too_long`).
	src := "{\"a\":1}\n{\"a\":\"0123456789abcdef\"}\n{\"a\":2}\n"
	r := json.records_open(transmute([]u8)src, .Lines, .Json)
	defer tape.destroy_records(&r)
	r.max_bytes = 12
	out: [8]tape.Record
	ans: [8]tape.Span_Answer
	n := json.records_find(&r, {tape.Name("a")}, out[:], ans[:])
	f, is_f := r.err.(tape.Fault)
	testing.expectf(t, n == 1 && is_f && f.kind == .Too_Wide && tape.fault_rule(f).code == "too_long", "max_bytes whole: n=%d err=%v", n, r.err)

	// Streaming pieces max_bytes: unbounded record without newline triggers Too_Wide once unread window > max_bytes.
	stream := fmt.tprintf("{{\"a\":1}}\n%s", strings.repeat("x", 64, context.temp_allocator))
	bs := transmute([]u8)stream
	p: tape.Pieces
	defer tape.destroy(&p)
	rp := json.records_open(bs[:16], .Lines, .Json, {pieces = &p})
	defer tape.destroy_records(&rp)
	rp.max_bytes = 24
	k1 := json.records_find(&rp, {tape.Name("a")}, out[:], ans[:])
	testing.expectf(t, k1 == 1 && rp.err == nil && p.more, "stream rec1: k1=%d err=%v more=%v", k1, rp.err, p.more)
	// Feed window holding 40 unread bytes (> 24) still with no newline.
	p.from = p.keep
	p.last = false
	_ = tape.records_window(&rp, bs[p.from:p.from + 40])
	k2 := json.records_find(&rp, {tape.Name("a")}, out[:], ans[:])
	f2, is_f2 := rp.err.(tape.Fault)
	testing.expectf(t, k2 == 0 && is_f2 && f2.kind == .Too_Wide && tape.fault_rule(f2).code == "too_long" && !p.more, "stream too_long: k2=%d err=%v more=%v", k2, rp.err, p.more)
}

@(test)
json_spine_finds_bulk_array :: proc(t: ^testing.T) {
	testkit.deadline(t)
	big := strings.repeat("1,", 3000, context.temp_allocator)
	// Root array
	at, levels, ok := json.spine(transmute([]u8)string("[1,2,3]"))
	testing.expectf(t, ok && at == 0 && levels == 0, "root: %v %v %v", at, levels, ok)
	// Nested spine past small side members
	nested := fmt.tprintf(`{{"meta":{{"v":1}},"items":[%s0]}}`, big)
	at, levels, ok = json.spine(transmute([]u8)nested)
	testing.expectf(t, ok && levels == 1 && nested[at] == '[', "nested: at=%d levels=%d ok=%v", at, levels, ok)
	// Small array inside object (< SIDE_BYTES) has no spine
	_, _, ok = json.spine(transmute([]u8)string(`{"a":[1]}`))
	testing.expectf(t, !ok, "small nested should not be spine")
	// Scalar root has no spine
	_, _, ok = json.spine(transmute([]u8)string(`42`))
	testing.expectf(t, !ok, "scalar should not be spine")
	// JSONC with comments
	commented := fmt.tprintf(`/* hdr */ {{"k":"v", /* c */ "rows":[%s0]}}`, big)
	at, levels, ok = json.spine(transmute([]u8)commented, .Jsonc)
	testing.expectf(t, ok && levels == 1 && commented[at] == '[', "jsonc spine: %v %v %v", at, levels, ok)
}

// Verifies runtime-selected `spec` and `lax` (`len(path) < 8` fast path vs `len(path) >= 8` `frame_init`) in `records_open`.
@(test)
perf4_records_dynamic_spec_and_path_lengths :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	line_src := "{\"k\":\"v1\"}\n{\"k\":\"v2\"}\n"
	short_path := [2]tape.Step{tape.Name("wrap"), tape.Name("items")}
	long_path := [9]tape.Step{
		tape.Name("a"), tape.Name("b"), tape.Name("c"), tape.Name("d"),
		tape.Name("e"), tape.Name("f"), tape.Name("g"), tape.Name("h"), tape.Name("k"),
	}
	nested_elem := `[{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":{"k":1}}}}}}}}},{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":{"k":2}}}}}}}}}]`
	nested_long_elem := `{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":{"k":[10,20]}}}}}}}}}`

	for spec in ([]json.Spec{.Json, .Jsonc, .Json5}) {
		for max_depth in ([]u32{0, 32}) {
			opts := json.Options{budget = {depth = max_depth}}
			// Validate with runtime `spec` and `opts`.
			rv := json.records_open(transmute([]u8)line_src, .Lines, spec, opts)
			defer tape.destroy_records(&rv)
			out: [4]tape.Record
			n := json.records_validate(&rv, out[:])
			testing.expectf(t, n == 0 && rv.index == 2 && rv.err == nil, "spec=%v depth=%d validate n=%d idx=%d err=%v", spec, max_depth, n, rv.index, rv.err)

			// `.Elements` with `len(path) < 8` (`2` steps, hitting the no-`frame_init` fast path).
			elem_src := `{"wrap":{"items":[{"k":"a"},{"k":"b"}]}}`
			re := json.records_open(transmute([]u8)elem_src, .Elements, spec, opts, short_path[:])
			defer tape.destroy_records(&re)
			eout: [4]tape.Record
			eans: [4]tape.Span_Answer
			ne := json.records_find(&re, []tape.Step{tape.Name("k")}, eout[:], eans[:])
			testing.expectf(t, ne == 2 && re.err == nil && eans[0].outcome == .Found && eans[1].outcome == .Found, "short path elements spec=%v: ne=%d err=%v", spec, ne, re.err)

			// `.Elements` with `len(path) >= 8` (hitting `build.frame_init`) via `records_scan`.
			dem, derr := tape.demand_of({{}})
			defer tape.destroy_demand(&dem)
			testing.expect_value(t, derr, nil)
			rl := json.records_open(transmute([]u8)nested_long_elem, .Elements, spec, opts, long_path[:])
			defer tape.destroy_records(&rl)
			sout: [4]tape.Record
			sdocs: [4]tape.Document
			ns := json.records_scan(&rl, &dem, sout[:], sdocs[:])
			testing.expectf(t, ns == 2 && rl.err == nil, "long path elements scan spec=%v: ns=%d err=%v", spec, ns, rl.err)

			// Root `.Elements` with `records_find` traversing a 9-step path inside each record.
			rlong := json.records_open(transmute([]u8)nested_elem, .Elements, spec, opts)
			defer tape.destroy_records(&rlong)
			lout: [4]tape.Record
			lans: [4]tape.Span_Answer
			nl := json.records_find(&rlong, long_path[:], lout[:], lans[:])
			testing.expectf(t, nl == 2 && lans[0].outcome == .Found && lans[1].outcome == .Found, "long path find spec=%v nl=%d", spec, nl)
		}
	}
}
