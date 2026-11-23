package json_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// The document and error of building `src`, checked against `validate`'s answer.
build :: proc(t: ^testing.T, src: string, opts := json.Options{}, spec := json.Spec.Json, loc := #caller_location) -> (tape.Document, tape.Error) {
	doc, err := json.build(transmute([]u8)src, spec, opts)
	testing.expectf(t, fmt.tprint(json.validate(transmute([]u8)src, spec, opts)) == fmt.tprint(err), "validate and build disagree on %q", src, loc = loc)
	return doc, err
}

// A document carries no escape credit in its keys, and a find of a name of another decoded length, which the walk
// rejects by that credit, finds nothing.
@(test)
escaped_keys_carry_no_credit_in_documents :: proc(t: ^testing.T) {
	testkit.deadline(t)
	pad := strings.repeat(" ", 64, context.temp_allocator)
	src := strings.concatenate({`{"a\n":1,"\u00e9x":2,"\ud83d\ude00":3,"\u0041\u0042":4,"plain":5`, pad, `}`}, context.temp_allocator)
	doc, err := build(t, src)
	defer tape.destroy(&doc)
	testing.expect_value(t, err, nil)
	d, _ := tape.demand_of([][]tape.Step{{tape.Name("a\n")}, {tape.Name("AB")}})
	defer tape.destroy(&d)
	scanned, serr := json.scan(transmute([]u8)src, &d)
	defer tape.destroy(&scanned)
	testing.expect_value(t, serr, nil)
	for kept in ([]^tape.Document{&doc, &scanned}) {
		keys := 0
		for node in kept.nodes {
			if node.role == .Key {
				keys += 1
				testing.expect_value(t, tape.without_credit(node.spelling), node.spelling)
			}
		}
		testing.expect(t, keys > 0, "no keys")
	}
	Case :: struct {
		name:  string,
		value: string,
	}
	for c in ([]Case{{"a\n", "1"}, {"éx", "2"}, {"\U0001F600", "3"}, {"AB", "4"}, {"a", ""}, {"é", ""}}) {
		a, ferr := json.find(transmute([]u8)src, {tape.Name(c.name)})
		testing.expect_value(t, ferr, nil)
		got := string(doc.src[a.lo:a.hi]) if a.outcome == .Found else ""
		testing.expectf(t, got == c.value, "find %q gave %q, want %q", c.name, got, c.value)
	}
}

// The suite's `y_` texts build and its `n_` texts are refused. `i_` texts may go either way.
@(test)
suite_accepts_and_refuses :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for f in #load_directory("conformance/JSONTestSuite/test_parsing") {
		doc, err := build(t, string(f.data))
		switch f.name[:2] {
		case "y_":
			testing.expectf(t, err == nil, "%s refused: %v", f.name, err)
		case "n_":
			testing.expectf(t, err != nil, "%s accepted", f.name)
		}
		tape.destroy(&doc)
	}
}

// A document's nodes are in text order. A container's `n` is its subtree's node count and its `spelling` its child
// count, and a key is a node but not a child.
@(test)
nodes_of_a_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := `{"a": [1, "x\n", true], "b": null}`
	doc, err := build(t, src)
	defer tape.destroy(&doc)
	testing.expect_value(t, err, nil)
	Want :: struct {
		text:     string,
		kind:     tape.Kind,
		role:     tape.Role,
		n:        u32,
		spelling: u16,
	}
	want := []Want {
		{"{", .Object, .Value, 8, 2},
		{"a", .String, .Key, 1, tape.SPELLING_QUOTED | tape.SPELLING_ASCII},
		{"[", .Array, .Value, 4, 3},
		{"1", .Number, .Value, 1, tape.number_spelling(0, 1, 0)},
		{`x\n`, .String, .Value, 3, tape.SPELLING_QUOTED | tape.SPELLING_DECODE},
		{"true", .True, .Value, 4, 0},
		{"b", .String, .Key, 1, tape.SPELLING_QUOTED | tape.SPELLING_ASCII},
		{"null", .Null, .Value, 4, 0},
	}
	if !testing.expect_value(t, len(doc.nodes), len(want)) {
		return
	}
	for w, i in want {
		node := doc.nodes[i]
		testing.expectf(t, node.kind == w.kind && node.role == w.role && node.spelling == w.spelling, "node %d: %v", i, node)
		if node.kind < .Array {
			testing.expectf(t, src[node.lo:][:node.n] == w.text && node.n == w.n, "node %d spans %q", i, src[node.lo:][:node.n])
		} else {
			testing.expectf(t, src[node.lo:][:1] == w.text && node.n == w.n, "node %d: %v", i, node)
		}
	}
	testing.expect_value(t, doc.root_close, u64(len(src)))
}

// Records of strings and keys of the lengths the readers tell apart, plain ASCII, with a byte past 0x7F first or past
// 64 bytes, and with an escape, and in JSON5 single-quoted strings and unquoted keys too. The last copies lie near the
// text's end.
ascii_text :: proc(spec: json.Spec) -> string {
	long := strings.repeat("abcdefghij", 7, context.temp_allocator)
	cat :: proc(parts: ..string) -> string {
		return strings.concatenate(parts, context.temp_allocator)
	}
	record := cat(`{"a": "b", "`, long[:40], `": "`, long[:40], `", "`, long, `é": "é`, long, `", "x\n": "`, long, `\t", "é": "`, long, `é", "ka": "`, long[:20], `"}`)
	if spec == .Json5 {
		record = cat(`{a: 'b', 'c`, long[:30], `': '`, long, `é', 'é': 'x\'y', "q": [`, record, `]}`)
	}
	text, _ := records(record, ",", record, 3)
	return text
}

// A quoted text has `SPELLING_ASCII` exactly when its bytes are all below 0x80 and hold no escape, in each spec, far
// from the text's end and near it. An unquoted key lacks it.
@(test)
ascii_texts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for spec in json.Spec {
		text := ascii_text(spec)
		doc, err := build(t, text, spec = spec)
		defer tape.destroy(&doc)
		testing.expect_value(t, err, nil)
		ascii, other := 0, 0
		for n in doc.nodes {
			if n.kind != .String {
				continue
			}
			bytes := text[n.lo:][:n.n]
			want := n.spelling & tape.SPELLING_QUOTED != 0 && strings.index_byte(bytes, '\\') < 0
			for c in transmute([]u8)bytes {
				want &&= c < 0x80
			}
			testing.expectf(t, (n.spelling & tape.SPELLING_ASCII != 0) == want, "%v: %v %q, want ASCII %v", spec, n.role, bytes, want)
			ascii += int(want)
			other += int(!want)
		}
		testing.expectf(t, ascii > 20 && other > 20, "%v: %d ASCII texts, %d others", spec, ascii, other)
	}
	free_all(context.temp_allocator)
}

// A text of `count` copies of `record` joined by `sep` in an array, then `last` and `count` more copies, and where
// `last` starts. The copies after `last` keep the walk far from the text's end where it reads `last`.
records :: proc(record, sep, last: string, count: int) -> (text: string, at: int) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[")
	for _ in 0 ..< count {
		strings.write_string(&b, record)
		strings.write_string(&b, sep)
	}
	at = strings.builder_len(b)
	strings.write_string(&b, last)
	for _ in 0 ..< count {
		strings.write_string(&b, sep)
		strings.write_string(&b, record)
	}
	strings.write_string(&b, "]")
	return strings.to_string(b), at
}

// Expects every key node of `doc` to span a quoted string of `text`.
expect_key_spans :: proc(t: ^testing.T, text: string, doc: ^tape.Document, loc := #caller_location) {
	for node in doc.nodes {
		if node.role == .Key {
			testing.expectf(t, text[node.lo - 1] == '"' && text[node.lo + u64(node.n)] == '"', "key span %v", node, loc = loc)
		}
	}
}

// A build's room for nodes starts small and grows as it fills, and a growth at any node past the first room keeps the
// nodes of a build that never grows. Leading white space sizes the first room, so each pad grows it at other nodes.
@(test)
room_grows_at_any_node :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Text :: struct {
		spec: json.Spec,
		src:  string,
	}
	records := strings.builder_make(context.temp_allocator)
	strings.write_string(&records, "[")
	join_each(&records, 6, ",\n ", "{{\"id\": %[0]d, \"name\": \"n%[0]d\", \"ok\": true, \"tags\": [1, [2, 3]], \"e\": \"\\u00e9\"}}")
	strings.write_string(&records, ",\n")
	join_each(&records, 6, ",", `{{"a":%[0]d,"b":-%[0]d.5,"c":"x"}}`)
	strings.write_string(&records, "]")
	numbers := strings.builder_make(context.temp_allocator)
	strings.write_string(&numbers, "[[0],")
	join_each(&numbers, 40, ",", "[%[0]d,-%[0]d.5],[[7,8]]")
	strings.write_string(&numbers, "]")
	texts := []Text {
		{.Json, strings.to_string(records)},
		{.Json, strings.to_string(numbers)},
		{.Json, `[[[[[[1]]]]],{"a":{"b":{"c":[[],{}]}}},{"x":1,"y":2,"z":3},"s",null]`},
		{.Jsonc, "{\"a\": 1, /* c */ \"b\": [1, 2, // d\n3,], \"c\": {\"d\": null}} // e"},
		{.Json5, `{a: 'x', b: +1, c: [.5, Infinity, 0x10,], 'd': {e: NaN}, "f": [1, 2],}`},
	}
	for x in texts {
		pad := strings.repeat(" ", 16 * len(x.src), context.temp_allocator)
		ref, err := json.build(transmute([]u8)strings.concatenate({pad, x.src}, context.temp_allocator), x.spec)
		defer tape.destroy(&ref)
		if !testing.expectf(t, err == nil, "%v: %v", x.spec, err) {
			continue
		}
		for k in 0 ..= len(ref.nodes) {
			src := strings.concatenate({pad[:16 * k], x.src}, context.temp_allocator)
			guarded: testkit.Guarded
			testkit.guarded_init(&guarded, context.allocator)
			defer testkit.guarded_destroy(&guarded)
			doc, derr := json.build(transmute([]u8)src, x.spec, allocator = testkit.guarded_allocator(&guarded))
			testing.expectf(t, derr == nil && len(doc.nodes) == len(ref.nodes) && len(doc.facts) == len(ref.facts), "%v pad %d: %v", x.spec, k, derr)
			testing.expectf(t, testkit.guarded_check(&guarded), "%v pad %d: a write past a block", x.spec, k)
			for i in 0 ..< min(len(doc.nodes), len(ref.nodes)) {
				a, b := doc.nodes[i], ref.nodes[i]
				a.lo += u64(len(pad) - 16 * k)
				if a != b {
					testing.expectf(t, false, "%v pad %d node %d: %v, want %v", x.spec, k, i, doc.nodes[i], b)
					break
				}
			}
			tape.destroy(&doc)
		}
	}
}

// Writes `count` items to `b` joined by `sep`, each `format` with its number, `first` and up, as argument 0.
join_each :: proc(b: ^strings.Builder, count: int, sep, format: string, first := 0) {
	for i in 0 ..< count {
		if i > 0 {
			strings.write_string(b, sep)
		}
		fmt.sbprintf(b, format, first + i)
	}
}

// A record that breaks where the records before it taught the walk a member gap is refused at the byte that breaks
// it, compact or pretty printed.
@(test)
learned_gaps_judge_every_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		record, last: string,
		at:           int, // the fault's offset in `last`, -1 for a record that reads
		kind:         tape.Fault_Kind,
	}
	cases := []Case {
		{`{"id":1,"name":"a"}`, `{"id":1"name":"a"}`, 7, .Bad_Char},
		{`{"id":1,"name":"a"}`, `{"id":1,"name""a"}`, 14, .Bad_Char},
		{`{"id":1,"name":"a"}`, `{,"id":1,"name":"a"}`, 1, .Bad_Char},
		{`{"id":1,"name":"a"}`, `{"id":1,,"name":"a"}`, 8, .Bad_Char},
		{`{"id":1,"name":"a"}`, "{\"id\":1,\"na\x01e\":\"a\"}", 11, .Bad_Char},
		{`{"id":1,"name":"a"}`, `{"id":1,"name":}`, 15, .Bad_Char},
		{`{"id":1,"name":"a"}`, `{"id":1,"name": "a"}`, -1, .None},
		{`{"id":1,"name":"a"}`, `{"id":1,"nbme":"a"}`, -1, .None},
		{`{"id":1,"name":"a"}`, `{"id":1,"name":"a","x":2}`, -1, .None},
		{`{"id":1,"name":"a"}`, `{"name":"a","id":1}`, -1, .None},
		{"{\n  \"id\": 1,\n  \"name\": \"a\"\n}", "{\n  \"id\": 1\n  \"name\": \"a\"\n}", 14, .Bad_Char},
		{"{\n  \"id\": 1,\n  \"name\": \"a\"\n}", "{\n  \"id\": 1,\n  \"name\" \"a\"\n}", 22, .Bad_Char},
		{"{\n  \"id\": 1,\n  \"name\": \"a\"\n}", "{\n  \"id\": 1,\n   \"name\": \"a\"\n}", -1, .None},
		{`{"id":1,"name":"a","ok":true}`, `{"id":01,"name":"a","ok":true}`, 7, .Bad_Number},
		{`{"id":1,"name":"a","ok":true}`, `{"id":-,"name":"a","ok":true}`, 7, .Bad_Number},
		{`{"id":1,"name":"a","ok":true}`, `{"id":1.,"name":"a","ok":true}`, 8, .Bad_Number},
		{`{"id":1,"name":"a","ok":true}`, `{"id":1e,"name":"a","ok":true}`, 8, .Bad_Number},
		{`{"id":1,"name":"a","ok":true}`, "{\"id\":1,\"name\":\"a\x01\",\"ok\":true}", 17, .Bad_Char},
		{`{"id":1,"name":"a","ok":true}`, `{"id":1,"name":"a\q","ok":true}`, 18, .Bad_Escape},
		{`{"id":1,"name":"a","ok":true}`, `{"id":1,"name":"a","ok":tru}`, 27, .Bad_Char},
		{`{"id":1,"name":"a","ok":true}`, `{"id":1,"name":"a","ok":nulle}`, 28, .Bad_Char},
		{`{"id":1,"name":"a","ok":true}`, `{"id":1,"name":"a","ok":true]`, 28, .Bad_Char},
		{`{"id":1,"name":"a","ok":true}`, `{"id":-1.5e3,"name":"a\nb","ok":false}`, -1, .None},
		{`{"id":1,"name":"a","ok":true}`, `{"id":"1","name":2,"ok":null}`, -1, .None},
		{`{"id":1,"name":"a","ok":true}`, `{"id":[1],"name":{"a":1},"ok":true}`, -1, .None},
	}
	for c in cases {
		for sep in ([]string{",", ",\n"}) {
			text, at := records(c.record, sep, c.last, 4)
			doc, err := build(t, text)
			if c.at < 0 {
				testing.expectf(t, err == nil, "%q after its records: %v", c.last, err)
				expect_key_spans(t, text, &doc)
			} else {
				f, faulted := err.(tape.Fault)
				testing.expectf(t, faulted && f.kind == c.kind && f.at == u64(at + c.at), "%q after its records: %v, want %v at %d", c.last, err, c.kind, at + c.at)
			}
			tape.destroy(&doc)
		}
	}
}

// Keys that never repeat retire their row of gaps, and the array holding them reads on without gaps. Records after
// them still read, and a broken one is still refused where it breaks. The wide object is the array's second, as the
// first object at a place learns nothing.
@(test)
gaps_stop_on_keys_that_never_repeat :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `[{"k0":0},{`)
	join_each(&b, 3000, ",", `"k%[0]d":%[0]d`)
	strings.write_string(&b, `},`)
	tail, at := records(`{"id":1,"name":"a"}`, ",", `{"id":1"name":"a"}`, 8)
	strings.write_string(&b, tail[1:])
	text := strings.to_string(b)
	offset := len(text) - len(tail) + 1
	doc, err := build(t, text)
	f, faulted := err.(tape.Fault)
	testing.expectf(t, faulted && f.kind == .Bad_Char && f.at == u64(offset + at - 1 + 7), "%v", err)
	tape.destroy(&doc)
	good, _ := records(`{"id":1,"name":"a"}`, ",", `{"id":2,"name":"b"}`, 8)
	doc, err = build(t, strings.concatenate({text[:offset], good[1:]}, context.temp_allocator))
	testing.expect_value(t, err, nil)
	tape.destroy(&doc)
}

// A text nesting past `Budget.depth` is refused at the bracket past the limit.
@(test)
depth_limit :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for depth in ([]int{9, 10, 2000}) {
		text := strings.concatenate({strings.repeat("[", 10, context.temp_allocator), strings.repeat("]", 10, context.temp_allocator)}, context.temp_allocator)
		doc, err := build(t, text, {budget = {depth = u32(depth)}})
		if depth < 10 {
			e, exceeded := err.(tape.Exceeded)
			testing.expectf(t, exceeded && e.kind == .Depth && e.at == u64(depth), "depth %d: %v", depth, err)
		} else {
			testing.expectf(t, err == nil, "depth %d: %v", depth, err)
		}
		tape.destroy(&doc)
	}
	// Around the builder's frame stack and the default limit, arrays and objects. A deeper `Budget.depth` reads past the
	// default, the walk's levels on the heap.
	for depth in ([]int{1024, 1025, tape.DEFAULT_DEPTH, tape.DEFAULT_DEPTH + 1}) {
		for open, i in ([]string{"[", `{"a":`}) {
			close := "]" if i == 0 else "}"
			text := strings.concatenate({strings.repeat(open, depth, context.temp_allocator), "0", strings.repeat(close, depth, context.temp_allocator)}, context.temp_allocator)
			for limit in ([]u32{0, 2 * tape.DEFAULT_DEPTH}) {
				doc, err := build(t, text, {budget = {depth = limit}})
				if depth > tape.DEFAULT_DEPTH && limit == 0 {
					e, exceeded := err.(tape.Exceeded)
					testing.expectf(t, exceeded && e.kind == .Depth && e.at == u64(tape.DEFAULT_DEPTH * len(open)), "%s depth %d: %v", open, depth, err)
				} else {
					testing.expectf(t, err == nil && len(doc.nodes) == depth * (1 + i) + 1, "%s depth %d: %v", open, depth, err)
				}
				tape.destroy(&doc)
				_, ferr := json.find(transmute([]u8)text, {tape.Name("b")}, opts = {budget = {depth = limit}})
				testing.expectf(t, fmt.tprint(ferr) == fmt.tprint(err), "find %s depth %d: %v", open, depth, ferr)
				verr := json.validate(transmute([]u8)text, opts = {budget = {depth = limit}})
				testing.expectf(t, fmt.tprint(verr) == fmt.tprint(err), "validate %s depth %d: %v", open, depth, verr)
			}
		}
	}
}

// Mixed pretty-printed outer objects and compact inner objects preserve exact node spans and indentation tracking.
@(test)
mixed_pretty_and_compact_gaps :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[\n")
	join_each(&b, 16, ",\n", "  {{\n    \"id\": %[0]d,\n    \"meta\": {{\"a\":1,\"b\":2,\"c\":3}},\n    \"tail\": true\n  }}")
	strings.write_string(&b, "\n]")
	text := strings.to_string(b)
	doc, err := build(t, text)
	defer tape.destroy(&doc)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(doc.nodes), 1 + 16 * 13)
	expect_key_spans(t, text, &doc)
}

// Repeating wide objects, more than `GAP_ROWS` distinct object places, and polymorphic or broken record boundaries.
@(test)
wide_and_polymorphic_gaps :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// 45 keys repeated across 11 records.
	wb := strings.builder_make(context.temp_allocator)
	strings.write_string(&wb, "{")
	join_each(&wb, 45, ",", "\"k%[0]d\":%[0]d")
	strings.write_string(&wb, "}")
	rec := strings.to_string(wb)
	wide_text, _ := records(rec, ",", rec, 5)
	doc, err := build(t, wide_text)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(doc.nodes), 1 + 11 * (1 + 2 * 45))
	expect_key_spans(t, wide_text, &doc)
	tape.destroy(&doc)

	// Over 64 distinct nested object rows share the last row, including polymorphic elements. The records hold
	// objects at 106 places, which their repeats match.
	rb := strings.builder_make(context.temp_allocator)
	strings.write_string(&rb, "{")
	join_each(&rb, 21, ",", `"a%[0]d":{{"b0":{{}},"b1":{{"v":%[0]d}},"b2":{{}},"b3":{{"v":%[0]d}}}}`)
	strings.write_string(&rb, "}")
	pb := strings.builder_make(context.temp_allocator)
	strings.write_string(&pb, "[")
	for _ in 0 ..< 6 {
		strings.write_string(&pb, strings.to_string(rb))
		strings.write_string(&pb, ",")
	}
	for i in 0 ..< 3 {
		strings.write_string(&pb, `{"rows":[`)
		join_each(&pb, 80, ",", `{{"f%[0]d":{{"v":%[0]d}}}}`)
		strings.write_string(&pb, `]},{"rows":[{"f0":[{"v":1},{"v":2}]},{"f0":{"v":3}}]}`)
		strings.write_string(&pb, "," if i < 2 else "]")
	}
	poly_text := strings.to_string(pb)
	pdoc, perr := build(t, poly_text)
	testing.expect_value(t, perr, nil)
	expect_key_spans(t, poly_text, &pdoc)
	tape.destroy(&pdoc)

	// Record-boundary faults after learned records.
	Bad_Case :: struct {
		last: string,
		at:   int,
		kind: tape.Fault_Kind,
	}
	bads := []Bad_Case {
		{`{"id":1,"name":"a"}{"id":2,"name":"b"}`, 19, .Bad_Char},
		{`{"id":1,"name":"a"},`, 20, .Bad_Char},
		{`{"id":1,"name":"a"},}`, 20, .Bad_Char},
		{`{"id":1,"name":"a"},:{"id":2,"name":"b"}`, 20, .Bad_Char},
		{`{"id":1,"name":"a"},{"id":2,"name":1}`, -1, .None},
	}
	for bc in bads {
		text, at := records(`{"id":1,"name":"a"}`, ",", bc.last, 6)
		bdoc, berr := build(t, text)
		if bc.kind == .None {
			testing.expectf(t, berr == nil, "%q: got %v", bc.last, berr)
			expect_key_spans(t, text, &bdoc)
		} else {
			f, faulted := berr.(tape.Fault)
			testing.expectf(t, faulted && f.kind == bc.kind && f.at == u64(at + bc.at), "%q: got %v, want %v at %d", bc.last, berr, bc.kind, at + bc.at)
		}
		tape.destroy(&bdoc)
	}
	// Truncation right after a learned record-boundary key prefix.
	head, _ := records(`{"id":1,"name":"a"}`, ",", `{"id":2,"name":"b"}`, 6)
	trunc := head[:len(head) - 10]
	tdoc, terr := build(t, trunc)
	tf, tfaulted := terr.(tape.Fault)
	testing.expectf(t, tfaulted && tf.kind == .Truncated, "truncated record: got %v", terr)
	tape.destroy(&tdoc)

	// Pretty record array, nested record arrays, object-in-object with identical keys, and polymorphic shrink/grow.
	pb2 := strings.builder_make(context.temp_allocator)
	strings.write_string(&pb2, "[\n")
	join_each(&pb2, 8, ",\n", "  {{\n    \"id\": %[0]d,\n    \"ok\": true\n  }}")
	strings.write_string(&pb2, ",\n  {\n    \"id\": 9\n  },\n  {\n    \"id\": 10,\n    \"ok\": false,\n    \"extra\": 1\n  }\n]")
	pretty_text := strings.to_string(pb2)
	pdoc2, perr2 := build(t, pretty_text)
	testing.expect_value(t, perr2, nil)
	expect_key_spans(t, pretty_text, &pdoc2)
	tape.destroy(&pdoc2)

	nb := strings.builder_make(context.temp_allocator)
	strings.write_string(&nb, `{"outer":{"a":{"id":1},"b":{"id":2}},"grid":[[`)
	join_each(&nb, 8, ",", `{{"id":%[0]d}}`)
	strings.write_string(&nb, `],[`)
	join_each(&nb, 8, ",", `{{"id":%[0]d}}`, 10)
	strings.write_string(&nb, `]]}`)
	nested_text := strings.to_string(nb)
	ndoc, nerr := build(t, nested_text)
	testing.expect_value(t, nerr, nil)
	expect_key_spans(t, nested_text, &ndoc)
	tape.destroy(&ndoc)

	// Uniform object arrays preserve every container's child count, subtree size, key span, and root close.
	long_recs := strings.builder_make(context.temp_allocator)
	strings.write_string(&long_recs, "[")
	join_each(&long_recs, 12, ",", `{{"id":"v%[0]d"}}`)
	strings.write_string(&long_recs, "]")
	long_text := strings.to_string(long_recs)
	ldoc, lerr := build(t, long_text)
	defer tape.destroy(&ldoc)
	testing.expect_value(t, lerr, nil)
	testing.expect_value(t, ldoc.nodes[0].n, u32(1 + 12 * 3))
	testing.expect_value(t, ldoc.nodes[0].spelling, u16(12))
	testing.expect_value(t, ldoc.root_close, u64(len(long_text)))
	for i in 0 ..< 12 {
		obj := ldoc.nodes[1 + i * 3]
		key := ldoc.nodes[2 + i * 3]
		val := ldoc.nodes[3 + i * 3]
		testing.expectf(t, obj.kind == .Object && obj.n == 3 && obj.spelling == 1, "obj %d: %v", i, obj)
		testing.expectf(t, key.role == .Key && long_text[key.lo:][:key.n] == "id" && long_text[key.lo - 1] == '"' && long_text[key.lo + u64(key.n)] == '"', "key %d: %v", i, key)
		testing.expectf(t, val.kind == .String && long_text[val.lo] == 'v', "val %d: %v", i, val)
	}
}

// A read making more nodes than `Budget.nodes` is refused at the first node past it, kept whole in a scan or not, and
// a room that grows keeps every node.
@(test)
node_limit :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := transmute([]u8)string(`{"a":[1,2,3],"b":4}`)
	for most in ([]u32{0, 7, 8}) {
		doc, err := json.build(text, .Json, {budget = {nodes = most}})
		if most == 7 {
			e, exceeded := err.(tape.Exceeded)
			testing.expectf(t, exceeded && e.kind == .Nodes && e.at == 17, "nodes %d: %v", most, err)
		} else {
			testing.expectf(t, err == nil && len(doc.nodes) == 8, "nodes %d: %v", most, err)
		}
		tape.destroy(&doc)
	}
	commented := transmute([]u8)string(`{"a":1 /*c*/}`)
	for most in ([]u32{2, 3}) {
		doc, err := json.build(commented, .Jsonc, {budget = {nodes = most}})
		if most == 2 {
			e, exceeded := err.(tape.Exceeded)
			testing.expectf(t, exceeded && e.kind == .Nodes && e.at == 5, "jsonc nodes %d: %v", most, err)
		} else {
			testing.expectf(t, err == nil && len(doc.nodes) == 3 && len(doc.facts) == 1, "jsonc nodes %d: %v", most, err)
		}
		tape.destroy(&doc)
	}
	d, _ := tape.demand_of([][]tape.Step{{tape.Name("a")}})
	defer tape.destroy(&d)
	r, err := json.scan(text, &d, opts = {budget = {nodes = 4}})
	e, exceeded := err.(tape.Exceeded)
	testing.expectf(t, exceeded && e.kind == .Nodes && e.at == 8, "%v", err)
	tape.destroy(&r)

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"a":[`)
	join_each(&b, 5000, ",", "%[0]d")
	strings.write_string(&b, `]}`)
	big := strings.to_string(b)
	doc, berr := build(t, big)
	testing.expect(t, berr == nil && len(doc.nodes) == 5003 && doc.nodes[2].n == 5001)
	tape.destroy(&doc)
	r, err = json.scan(transmute([]u8)big, &d)
	testing.expect(t, err == nil && len(r.nodes) == 5003 && len(r.partial.answers) == 1)
	tape.destroy(&r)
}

// A read whose blocks would hold more than `Budget.memory` bytes is refused as `Exceeded`, with what it held freed, and
// one within it gives a document of the caller's allocator.
@(test)
memory_limit :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"a":[`)
	join_each(&b, 5000, ",", "%[0]d")
	strings.write_string(&b, `],"b":`)
	for _ in 0 ..< 2000 {
		strings.write_byte(&b, '[')
	}
	for _ in 0 ..< 2000 {
		strings.write_byte(&b, ']')
	}
	strings.write_string(&b, `}`)
	text := transmute([]u8)strings.to_string(b)
	d, _ := tape.demand_of([][]tape.Step{{tape.Name("a"), tape.Index(-3)}})
	defer tape.destroy(&d)
	path := []tape.Step{tape.Name("a"), tape.Index(-3000)}

	exceeded :: proc(err: tape.Error) -> bool {
		e, ok := err.(tape.Exceeded)
		return ok && e.kind == .Memory && e.at == tape.NO_BYTE
	}
	for memory in ([]u64{1, 1024, 4096}) {
		opts := json.Options{budget = {memory = memory}}
		doc, err := json.build(text, .Json, opts)
		testing.expectf(t, exceeded(err) && len(doc.nodes) == 0, "build %d: %v", memory, err)
		r, serr := json.scan(text, &d, opts = opts)
		testing.expectf(t, exceeded(serr) && len(r.nodes) == 0, "scan %d: %v", memory, serr)
		_, ferr := json.find(text, path, opts = opts)
		testing.expectf(t, exceeded(ferr), "find %d: %v", memory, ferr)
		verr := json.validate(text, opts = opts)
		testing.expectf(t, exceeded(verr), "validate %d: %v", memory, verr)
	}
	opts := json.Options{budget = {memory = 1 << 30}}
	doc, err := json.build(text, .Json, opts)
	testing.expectf(t, err == nil && doc.allocator == context.allocator && len(doc.nodes) == 5003 + 2001, "build: %v", err)
	tape.destroy(&doc)
	r, serr := json.scan(text, &d, opts = opts)
	answer, p, _ := tape.answer({doc = &r}, 0, 0)
	testing.expectf(t, serr == nil && r.allocator == context.allocator && p == .Found && text[r.nodes[answer].lo] == '4', "scan: %v", serr)
	tape.destroy(&r)
	found, ferr := json.find(text, path, opts = opts)
	testing.expectf(t, ferr == nil && found.outcome == .Found && text[found.lo] == '2', "find: %v %v", ferr, found)
	testing.expect(t, json.validate(text, opts = opts) == nil)
}
