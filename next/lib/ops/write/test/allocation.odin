package write_tests

import "base:runtime"
import "core:bytes"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:json"
import "stury:testkit"

// A write under an allocator that refuses an allocation gives its text or the refusal and keeps no block, and a
// write that succeeds leaves the temporary allocator alone.

@(private = "file")
Allocation_Case :: struct {
	src:      string,
	from:     json.Spec,
	tolerate: json.Tolerances,
	to:       json.Spec,
	opts:     json.Write_Options,
}

@(private = "file")
Allocation_Run :: struct {
	doc:  ^json.Document,
	to:   json.Spec,
	opts: json.Write_Options,
	sink: bool,
}

@(private = "file")
sweep_one :: proc(data: rawptr, a: runtime.Allocator) {
	r := (^Allocation_Run)(data)
	if r.sink {
		taken: bytes.Buffer
		bytes.buffer_init_allocator(&taken, 0, 0, context.allocator)
		defer bytes.buffer_destroy(&taken)
		_, err := json.write_to(bytes.buffer_to_stream(&taken), r.doc, r.to, r.opts, a)
		if err != nil {
			_ = err.(runtime.Allocator_Error)
		}
		return
	}
	text, _, err := json.write(r.doc, r.to, r.opts, a)
	if err == nil {
		delete(text, a)
	} else {
		_ = err.(runtime.Allocator_Error)
	}
}

// Documents of each route, spec and layout: every allocation of the write may be refused, into a buffer and into a
// sink, and what was allocated is freed.
@(test)
allocation_writes_under_failing_allocators :: proc(t: ^testing.T) {
	testkit.deadline(t)
	deep := strings.concatenate({strings.repeat("[", 2000, context.temp_allocator), strings.repeat("]", 2000, context.temp_allocator)}, context.temp_allocator)
	wide := strings.concatenate({`{"`, strings.repeat("k", 5000, context.temp_allocator), `":"`, strings.repeat(`xé`, 5000, context.temp_allocator), `"}`}, context.temp_allocator)
	plain := `{"b":1,"a":[2,{"d":3,"c":"é"}]}`
	cases := [?]Allocation_Case {
		{plain, .Json, {}, .Json, {}},
		{plain, .Json, {}, .Json, {indent = 2}},
		{plain, .Json, {}, .Json5, {tab = true}},
		{plain, .Jsonc, {}, .Json, {}},
		{`{"aA":["é\/",1e400]}`, .Json, {}, .Json, {}},
		{`{"aA":["é\/",1e400]}`, .Json, {}, .Jsonc, {indent = 3}},
		{"// head\n{\"b\":1, /* in */ \"a\":[2] // tail\n}\n", .Jsonc, {}, .Jsonc, {}},
		{"// head\n{\"b\":1, /* in */ \"a\":[2] // tail\n}\n", .Jsonc, {}, .Json5, {indent = 2}},
		{"{a: 0x123456789abcdef0123456789, b: 'x', c: .5}", .Json5, {}, .Json, {}},
		{"{a: 0x123456789abcdef0123456789, b: 'x', c: .5}", .Json5, {}, .Json5, {indent = 2}},
		{"[\"a\xff\", {\"k\xff\": 1}]", .Json, {.Invalid_Utf8}, .Json, {}},
		{`["\ud800", 1]`, .Json, {.Lone_Surrogate}, .Json, {indent = 2}},
		{"[NaN, -Infinity]", .Json5, {}, .Json5, {}},
		{deep, .Json, {}, .Json, {}},
		{deep, .Json, {}, .Json, {indent = 2}},
		{wide, .Json, {}, .Json, {}},
		{wide, .Json, {}, .Json, {indent = 2}},
	}
	for c in cases {
		doc, err := json.build(transmute([]u8)c.src, c.from, {tolerate = c.tolerate})
		defer json.destroy(&doc)
		if !testing.expectf(t, err == nil, "%.60q: %v", c.src, err) {
			continue
		}
		for sink in ([]bool{false, true}) {
			run := Allocation_Run{&doc, c.to, c.opts, sink}
			s := testkit.sweep_failures(sweep_one, &run)
			testing.expectf(t, s.bad == 0 && s.refused >= 1, "%.60q as %v to %v %v, a sink %v: %v", c.src, c.from, c.to, c.opts, sink, s)
		}
	}
}

// A write that succeeds leaves nothing on the temporary allocator, which a caller may never free.
@(test)
allocation_writes_keep_off_the_temporary_allocator :: proc(t: ^testing.T) {
	testkit.deadline(t)
	texts := [?]string{`{"a":[1,2,{"b":"\u00e9\n"}],"c":null}`, "// c\n[1, /* d */ 2]", "{a: 0xff, 'b': [.5, +1]}"}
	docs: [len(texts)]json.Document
	for text, k in texts {
		err: json.Error
		docs[k], err = json.build(transmute([]u8)text, json.Spec(k))
		testing.expect_value(t, err, nil)
	}
	defer for &doc in docs {
		json.destroy(&doc)
	}
	table, terr := dsv.build(transmute([]u8)string("a,b\n1,\"x y\"\n2,3\n"))
	defer dsv.destroy(&table)
	testing.expect_value(t, terr, nil)
	objects, oerr := json.build(transmute([]u8)string(`[{"a":1},{"a":2}]`))
	defer json.destroy(&objects)
	testing.expect_value(t, oerr, nil)
	f := testkit.Failing{backing = context.temp_allocator, fail_at = -1}
	context.temp_allocator = testkit.failing_allocator(&f)
	for &doc in docs {
		for spec in json.Spec {
			for opts in ([?]json.Write_Options{{}, {indent = 2}, {tab = true}}) {
				out, _, werr := json.write(&doc, spec, opts)
				delete(out)
				testing.expect_value(t, werr, nil)
				taken: bytes.Buffer
				_, serr := json.write_to(bytes.buffer_to_stream(&taken), &doc, spec, opts)
				bytes.buffer_destroy(&taken)
				testing.expect_value(t, serr, nil)
			}
		}
	}
	for spec in dsv.Spec {
		text, _, werr := dsv.write(&table, spec)
		delete(text)
		testing.expect_value(t, werr, nil)
	}
	text, _, werr := dsv.write(&objects)
	delete(text)
	testing.expect_value(t, werr, nil)
	testing.expect_value(t, f.count, 0)
}
