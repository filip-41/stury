// The reads of a TOML text: the document a build gives, its node readers, a find, a scan and the records.
package toml_tests

import "core:math"
import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:toml"

@(test)
a_build_places_members_by_path :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, dumped("[a.b]\nx = 1\n[a]\ny = 2\n[a.b.c]\nz = 3\n"), `{"a":{"b":{"x":1,"c":{"z":3}},"y":2}}`)
	testing.expect_value(t, dumped("[[l]]\nn = 1\n[l.sub]\ns = 'a'\n[[l]]\nn = 2\n[[l.k]]\n"), `{"l":[{"n":1,"sub":{"s":"a"}},{"n":2,"k":[{}]}]}`)
	testing.expect_value(t, dumped("a.b.c = 1\na.d = {e = [1, {f = 2}]}\n"), `{"a":{"b":{"c":1},"d":{"e":[1,{"f":2}]}}}`)
	testing.expect_value(t, dumped(""), `{}`)
	testing.expect_value(t, dumped("a = 1\na = 2\n"), "duplicate_key")
}

@(test)
strings_read_as_their_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, dumped("a = \"x\\ty\\u00e9\\U0001F600\"\nb = 'c:\\d'\n\"k\\n\" = 1\n'l\\' = 2\n"), "{\"a\":\"x\\ty\u00e9\U0001F600\",\"b\":\"c:\\\\d\",\"k\\n\":1,\"l\\\\\":2}")
	testing.expect_value(t, dumped("a = \"\"\"\nline\\\n   next\"\"\"\nb = '''\r\nraw\\'''\nc = \"\"\"q\"\"\"\"\"\n"), `{"a":"linenext","b":"raw\\","c":"q\"\""}`)
	testing.expect_value(t, dumped("a = \"\\e\\x41\"\n", .Toml_1_1), "{\"a\":\"\\eA\"}")
}

@(test)
numbers_read_as_their_value :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, dumped("a = 0xff\nb = 0o17\nc = 0b101\nd = 1_000\ne = +3\nf = -0\ng = -9223372036854775808\nh = 0o7\n"), `{"a":255,"b":15,"c":5,"d":1000,"e":3,"f":0,"g":-9223372036854775808,"h":7}`)
	testing.expect_value(t, dumped("a = 1.5\nb = -2e3\nc = 6.626_070e-34\nd = +inf\ne = -inf\nf = nan\n"), `{"a":1.5,"b":-2000,"c":6.62607e-34,"d":+Inf,"e":-Inf,"f":nan}`)
	doc, err := toml.build(transmute([]u8)string("a = -inf\nb = 1e2\n"))
	defer toml.destroy(&doc)
	expect_nil(t, err)
	n, _ := toml.node_number(&doc, 2)
	testing.expect(t, n.kind == .Float && math.is_inf(transmute(f64)n.bits, -1))
	form, _ := toml.number_form(&doc, 4)
	testing.expect(t, form.exponent && form.int_digits == 1)
	wide, werr := toml.build(transmute([]u8)string("a = 1e400\nb = -1_0e400\n"))
	defer toml.destroy(&wide)
	expect_nil(t, werr)
	for at in ([]tape.Node_Index{2, 4}) {
		w, _ := toml.node_number(&wide, at)
		testing.expect(t, w.kind == .Wide)
	}
}

@(test)
date_times_are_strings_of_their_type :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, dumped("a = 1979-05-27T07:32:00Z\nb = 1979-05-27 07:32:00.999\nc = 1979-05-27\nd = 07:32:00\ne = 1979-05-27T00:32:00-07:00\n"), `{"a":dt:1979-05-27T07:32:00Z,"b":dt:1979-05-27 07:32:00.999,"c":dt:1979-05-27,"d":dt:07:32:00,"e":dt:1979-05-27T00:32:00-07:00}`)
	testing.expect_value(t, dumped("a = 07:32\n", .Toml_1_1), `{"a":dt:07:32}`)
	testing.expect_value(t, dumped("a = 07:32\n", .Toml_1_0), "bad_datetime")
}

@(test)
comments_are_facts_of_their_values :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("# head\n\na = 1 # one\n[t]\n# above\nb = [\n  1,\n  # last\n]\n")
	doc, err := toml.build(src)
	defer toml.destroy(&doc)
	expect_nil(t, err)
	Want :: struct {
		kind: tape.Fact_Kind,
		node: tape.Node_Index,
		text: string,
	}
	want := []Want{{.Comment, 0, "# head"}, {.Comment_Inline, 2, "# one"}, {.Comment, 6, "# above"}, {.Comment_Foot, 6, "# last"}}
	if testing.expect_value(t, len(doc.facts), len(want)) {
		for f, i in doc.facts {
			testing.expectf(t, f.kind == want[i].kind && f.node == want[i].node && string(toml.span_bytes(&doc, f.lo, f.n)) == want[i].text, "fact %d: %v", i, f)
		}
	}
}

// The comment above a header that defines a table other headers made is the table's, in a build and in a scan that
// keeps facts.
@(test)
comments_above_a_late_header_are_its_tables :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("[a.b]\n[c]\nx = 1\n# head of a\n[a]\n[d]\ny = 1\n")
	doc, err := toml.build(src)
	defer toml.destroy(&doc)
	expect_nil(t, err)
	a, _ := toml.member({&doc, nil}, toml.ROOT, "a")
	d, _ := tape.demand_of({{tape.Name("a")}}, facts = true)
	defer tape.destroy(&d)
	scan, serr := toml.scan(src, &d)
	defer toml.destroy(&scan)
	expect_nil(t, serr)
	kept, _, _ := toml.answer({&scan, nil}, 0, 0)
	for got, i in ([]^tape.Document{&doc, &scan}) {
		at := a if i == 0 else kept
		if testing.expectf(t, len(got.facts) == 1, "%d: %v", i, got.facts) {
			f := got.facts[0]
			testing.expectf(t, f.kind == .Comment && f.node == at && string(toml.span_bytes(got, f.lo, f.n)) == "# head of a", "%d: %v", i, f)
		}
	}
}

// A find answers the value a build holds at its path, its span with the quotes around a string, and a table no bracket
// closes from its body, or the next key part of the path that made it, to its last value.
@(test)
a_find_answers_as_the_build :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("[a.b]\nx = 'v'\n[a]\ny = [1, {z = 2}]\n[c]\np . 'q'.r = 1\n")
	Case :: struct {
		path:  []tape.Step,
		lo:    u64,
		hi:    u64,
		found: tape.Presence,
	}
	for c in ([]Case {
		{{tape.Name("a"), tape.Name("b"), tape.Name("x")}, 10, 13, .Found},
		{{tape.Name("a"), tape.Name("y"), tape.Index(1), tape.Name("z")}, 31, 32, .Found},
		{{tape.Name("a"), tape.Name("y")}, 22, 34, .Found},
		{{tape.Name("a"), tape.Name("b")}, 5, 13, .Found},
		{{tape.Name("a"), tape.Name("q")}, 0, 0, .Missing},
		{{tape.Name("a"), tape.Index(0)}, 3, 34, .Wrong_Kind},
		{{tape.Name("c"), tape.Name("p")}, 43, 52, .Found},
		{{tape.Name("c"), tape.Name("p"), tape.Name("q")}, 47, 52, .Found},
	}) {
		for stop in ([]bool{false, true}) {
			a, err := toml.find(src, c.path, read = {stop_early = stop})
			expect_nil(t, err)
			testing.expectf(t, a.outcome == c.found && (c.found == .Missing || a.lo == c.lo && a.hi == c.hi), "%v stop %v: %v", c.path, stop, a)
		}
	}
}

// Under `stop_early` a find reads statements only as far as its answer needs, so a fault past the answer's container is
// not judged, while a read to the end refuses the text.
@(test)
a_find_that_stops_early_reads_to_its_answer :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("[[logs]]\nid = 1\n[[logs]]\nid = 2\n[[logs]]\nid = ]\n")
	path := []tape.Step{tape.Name("logs"), tape.Index(0), tape.Name("id")}
	a, err := toml.find(src, path, read = {stop_early = true}, opts = {dups = .First})
	expect_nil(t, err)
	testing.expect_value(t, a.outcome, tape.Presence.Found)
	_, err = toml.find(src, path)
	testing.expect_value(t, testkit.code_of(err), "expected_value")
	d, _ := tape.demand_of({path})
	defer tape.destroy(&d)
	doc, serr := toml.scan(src, &d, read = {stop_early = true}, opts = {dups = .First})
	defer toml.destroy(&doc)
	expect_nil(t, serr)
	testing.expect(t, .Stopped in doc.flags)
}

@(test)
reads_refuse_options_they_do_not_take :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a = 1\n")
	testing.expect_value(t, testkit.code_of(toml.validate(src, opts = {format = tape.Dsv_Options{}})), "bad option format")
	_, err := toml.build(src, opts = {format = tape.Cbor_Options{}})
	testing.expect_value(t, testkit.code_of(err), "bad option format")
	_, err = toml.scan(src, nil, opts = {dups = .All})
	testing.expect_value(t, testkit.code_of(err), "bad option dups")
}

@(test)
the_text_is_one_record :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a = 1\n[t]\nb = [1, 2]\n")
	r := toml.records_open(src)
	defer toml.destroy(&r)
	out: [4]tape.Record
	every: [4]tape.Span_Answer
	n := toml.records_find(&r, nil, out[:], every[:])
	testing.expect_value(t, n, 1)
	testing.expect(t, out[0].lo == 0 && out[0].hi == u64(len(src)) && out[0].err == nil && r.err == nil)
	v := toml.records_open(src)
	defer toml.destroy(&v)
	testing.expect(t, toml.records_validate(&v, out[:]) == 0 && v.index == 1 && v.err == nil)
	bad := transmute([]u8)string("a = 1\na = 2\n")
	b := toml.records_open(bad)
	testing.expect_value(t, toml.records_validate(&b, out[:]), 0)
	testing.expect_value(t, testkit.code_of(b.err), "duplicate_key")
	marked := toml.records_open(transmute([]u8)string("\xef\xbb\xbfa = 1\n"))
	testing.expect_value(t, toml.records_find(&marked, nil, out[:], every[:]), 1)
	testing.expect(t, out[0].lo == 3 && out[0].hi == 9 && out[0].err == nil)
	empty := toml.records_open(nil)
	testing.expect_value(t, toml.records_validate(&empty, out[:]), 0)
	for framing in ([]tape.Framing{.Lines, .Elements}) {
		x := toml.records_open(src, framing)
		testing.expect_value(t, toml.records_validate(&x, out[:]), 0)
		testing.expect_value(t, testkit.code_of(x.err), "bad option framing")
	}
}

@(test)
the_root_members_are_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a = 'x'\n[t]\nb = [1, 2]\n[u.v]\nc = 3\n[t.w]\nd = 4\n")
	r := toml.records_open(src, .Members)
	defer toml.destroy(&r)
	out: [4]tape.Record
	answers: [4]tape.Span_Answer
	n := toml.records_find(&r, {tape.Name("b"), tape.Index(1)}, out[:], answers[:])
	expect_nil(t, r.err)
	if !testing.expect_value(t, n, 3) {
		return
	}
	keys := [3]string{"a", "t", "u"}
	for rec, i in out[:n] {
		testing.expectf(t, string(src[rec.key.lo:][:rec.key.n]) == keys[i] && rec.err == nil, "record %d: %v", i, rec)
	}
	testing.expect(t, out[0].lo == 4 && out[0].hi == 7)
	testing.expect(t, answers[0].outcome == .Wrong_Kind && answers[1].outcome == .Found && answers[2].outcome == .Missing)
	testing.expect_value(t, string(src[answers[1].lo:answers[1].hi]), "2")
	bad := toml.records_open(transmute([]u8)string("a = 1\n[a]\n"), .Members)
	defer toml.destroy(&bad)
	testing.expect_value(t, toml.records_validate(&bad, out[:]), 0)
	testing.expect_value(t, testkit.code_of(bad.err), "duplicate_key")
}

// The records at a path are the members of the table or the elements of the array it reaches, each as the build
// reads it, and a path to no such container holds none.
@(test)
records_at_a_path_are_the_children_of_the_container :: proc(t: ^testing.T) {
	testkit.deadline(t)
	texts := []string {
		"a = 'x'\n[t]\nb = [1, [2, 3], {c = 4}]\n[u.v]\nc = 3\n[t.w]\nd = 4\n",
		"[[p]]\nq = 1\n[[p]]\nq = [5, 6]\nr.s = 'z'\n[[p.n]]\nm = true\n",
		"x = { y = { z = [[], [1], { w = 2 }] } }\nk = 1979-05-27T07:32:00Z\n",
		"a = 1\na = 2\n",
	}
	read: int
	for text in texts {
		for spec in toml.Spec {
			read += testkit.records_at_agree(t, toml.reads(spec), toml.as(spec), transmute([]u8)text, {}, text)
		}
	}
	testing.expect(t, read > 0)
}

// Records at a path under `Budget.steps` end with the verdict `validate` gives, which counts the containers outside the
// one the path reaches too.
@(test)
records_at_a_path_keep_the_steps_budget :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a = [{b = 1}, [2]]\n[t]\nc = [3, [4, {d = 5}]]\n[u.v]\nw = {x = [6]}\n")
	path := []toml.Step{toml.Name("t"), toml.Name("c")}
	over := 0
	for steps in 1 ..= 12 {
		opts := toml.Options{budget = {steps = u64(steps)}}
		want := toml.validate(src, opts = opts)
		r := toml.records_open(src, .Elements, opts = opts, path = path)
		defer toml.destroy(&r)
		out: [4]tape.Record
		for toml.records_validate(&r, out[:]) == len(out) {}
		_, past := want.(tape.Exceeded)
		over += int(past)
		testing.expectf(t, r.err == want, "%d steps: records end with %v, validate %v", steps, r.err, want)
	}
	testing.expect(t, over > 0 && over < 12)
}

// Records take `.Refuse` as every TOML read does, as a repeated key is a fault whatever the policy.
@(test)
records_take_the_refuse_policy :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a = 1\n[t]\nb = 2\n")
	for framing in ([]tape.Framing{.Concatenated, .Members}) {
		out: [4]tape.Record
		answers: [4]tape.Span_Answer
		docs: [4]tape.Document
		d, _ := tape.demand_of({{tape.Name("b")}})
		defer tape.destroy(&d)
		v := toml.records_open(src, framing, opts = {dups = .Refuse})
		defer toml.destroy(&v)
		f := toml.records_open(src, framing, opts = {dups = .Refuse})
		defer toml.destroy(&f)
		s := toml.records_open(src, framing, opts = {dups = .Refuse})
		defer tape.destroy_records(&s)
		want := 1 if framing == .Concatenated else 2
		testing.expect_value(t, toml.records_validate(&v, out[:]), 0)
		testing.expect_value(t, v.index, u64(want))
		testing.expect_value(t, toml.records_find(&f, {tape.Name("b")}, out[:], answers[:]), want)
		n := toml.records_scan(&s, &d, out[:], docs[:])
		testing.expect_value(t, n, want)
		for &doc in docs[:n] {
			tape.destroy(&doc)
		}
		testing.expect(t, v.err == nil && f.err == nil && s.err == nil)
	}
}

// A build of a text that holds a node per byte or close to it fits the bound its nodes are reserved by.
@(test)
dense_texts_fit_the_node_bound :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for text in ([]string{"a.b.c.d.e.f.g=1", "[a.b.c.d]\n[a.b.c.e]", "a=[[],[],[[]]]", "a={}\nb={}", "[[a]]\n[[a]]\n[[a]]"}) {
		doc, err := toml.build(transmute([]u8)text, opts = {budget = {nodes = u32(len(text)) + 1}})
		expect_nil(t, err)
		testing.expectf(t, len(doc.nodes) <= len(text) + 1, "%q: %d nodes", text, len(doc.nodes))
		toml.destroy(&doc)
	}
}
