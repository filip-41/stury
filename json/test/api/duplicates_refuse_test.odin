package json_tests

// Refusing repeated keys: `Duplicates.Refuse` on a `Request`, `build`'s `duplicates`, and
// `Duplicates.Refuse`. A key that, decoded, repeats one of its own object's refuses the document with
// `.Duplicate_Key` at the repeat's opening quote. The private suite's `check_refuse` holds generated documents
// to a reference reading of the node rows, these pin the offsets, the big objects and `.Lazy`.

import json "../.."
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

@(private = "file")
dup_verdict_is :: proc(got: Maybe(json.Error), want: Maybe(json.Error)) -> bool {
	g, has_g := got.?
	w, has_w := want.?
	return has_g == has_w && (!has_g || g.kind == w.kind && g.offset == w.offset)
}

// A `Request($Q)` scan of `src` under `.Refuse` gives `want`, and, accepting, the answers and rows `.First`
// gives. `.Lazy` may stop before the repeat, which a `.Strict` scan then finds.
@(private = "file")
expect_refuse_scan :: proc(
	t: ^testing.T,
	src: []byte,
	want: Maybe(json.Error),
	$Q: bit_set[json.Query],
	paths: []json.Path,
	strictness: json.Strictness,
	dialect: json.Dialect,
	loc := #caller_location,
) -> bool {
	req: json.Request(Q)
	defer json.destroy(&req)
	_ = request_of(&req, paths, {strictness = strictness, dialect = dialect, duplicates = .Refuse})
	err := json.scan(src, &req)
	if refusal, refused := err.?; refused && (refusal.kind == .Bad_Option || refusal.kind == .Over_Capacity || refusal.kind == .Bad_Path) {
		testing.expectf(t, false, "%v %v %v: refused %v\n%s", Q, strictness, dialect, refusal, string(src), loc = loc)
		return false
	}
	fault := scan_fault(err)
	ok := dup_verdict_is(fault, want)
	if strictness == .Lazy && dialect == .Json {
		ok = ok || fault == nil
		ok &&= dup_verdict_is(strict_verdict(src, &req), want)
	}
	if !testing.expectf(t, ok, "%v %v %v %v: %v, want %v\n%s", Q, paths, strictness, dialect, fault, want, string(src), loc = loc) {
		return false
	}
	if fault != nil {
		return true
	}
	first: json.Request(Q)
	defer json.destroy(&first)
	_ = request_of(&first, paths, {strictness = strictness, dialect = dialect, duplicates = .First})
	same := json.scan(src, &first) == nil && len(req.answers) == len(first.answers) && len(req.doc.rows) == len(first.doc.rows)
	for a, k in req.answers {
		same &&= k < len(first.answers) && a == first.answers[k]
	}
	for n, k in req.doc.rows {
		same &&= k < len(first.doc.rows) && n.lo == first.doc.rows[k].lo && n.hi == first.doc.rows[k].hi
	}
	return testing.expectf(t, same, "%v %v %v: answers differ from .First's\n%s", Q, strictness, dialect, string(src), loc = loc)
}

// Accepts any member under any name.
@(private = "file")
Dup_Target :: struct {
	a: json.Raw,
	b: any,
}

// `unmarshal` and `check` of `src` into `T` under `.Refuse` give `want`, with the spilled keys in
// `context.allocator`. `.Lazy` may also accept, or refuse at a later repeat when it skipped the first unread.
@(private = "file")
expect_refuse_unmarshal :: proc(
	t: ^testing.T,
	src: []byte,
	want: Maybe(json.Error),
	repeats: []u64,
	$T: typeid,
	loc := #caller_location,
) -> bool {
	want_kind: Maybe(json.Unmarshal_Error_Kind)
	want_at: u64
	if w, has := want.?; has {
		want_kind, want_at = json.Unmarshal_Error_Kind.Duplicate_Key, w.offset
	}
	for dialect in json.Dialect {
		for strictness in ([]json.Strictness{.Strict, .Lazy}) {
			opts := json.Unmarshal_Opts{strictness = strictness, duplicates = .Refuse, dialect = dialect}
			v: T
			got_err := json.unmarshal(src, &v, opts, nil, context.temp_allocator)
			got := um_err(got_err)
			ok := um_kind(got_err) == want_kind && got.offset == want_at
			if strictness == .Lazy && dialect == .Json {
				ok ||= got_err == nil || got.kind == .Duplicate_Key && slice.contains(repeats, got.offset)
			}
			c := um_err(json.unmarshal_check(src, T, opts))
			ok &&= c.kind == got.kind && c.offset == got.offset
			if !testing.expectf(t, ok, "%v %v %v: unmarshal %v at %d, check %v at %d, want %v at %d\n%s", typeid_of(T), strictness, dialect, got.kind, got.offset, c.kind, c.offset, want_kind, want_at, string(src), loc = loc) {
				return false
			}
		}
	}
	return true
}

// Every entry that takes `.Refuse`, on `src`, gives `want`: its first repeat, of `repeats` (`want`'s alone when
// not given).
@(private = "file")
expect_refuse_everywhere :: proc(t: ^testing.T, src: []byte, want: Maybe(json.Error), repeats: []u64 = nil, loc := #caller_location) -> bool {
	repeats := repeats
	if w, has := want.?; has && repeats == nil {
		repeats = {w.offset}
	}
	// A plain name and a column ride the demand matcher, a name then `Any` rides the automaton.
	path_sets := [?][]json.Path{
		{{steps = {json.Name("a")}}},
		{{steps = {json.Any{}, json.Name("b")}}, {steps = {json.Name("é")}}},
		{{steps = {json.Name("a"), json.Any{}}}},
	}
	for paths in path_sets {
		for strictness in json.Strictness {
			expect_refuse_scan(t, src, want, {.Path}, paths, strictness, .Json, loc) or_return
		}
		expect_refuse_scan(t, src, want, {.Path}, paths, .Strict, .Jsonc, loc) or_return
	}
	expect_refuse_scan(t, src, want, {.Dom}, nil, .Strict, .Json, loc) or_return
	expect_refuse_scan(t, src, want, {.Dom}, nil, .Strict, .Jsonc, loc) or_return
	expect_refuse_scan(t, src, want, {.Path, .Nodes}, path_sets[2], .Strict, .Json, loc) or_return
	for dialect in json.Dialect {
		doc, err := json.build(src, {dialect = dialect, duplicates = .Refuse})
		json.destroy(&doc)
		testing.expectf(t, dup_verdict_is(err, want), "build %v: %v, want %v\n%s", dialect, err, want, string(src), loc = loc) or_return
	}
	if len(src) > 0 && src[0] == '{' {
		expect_refuse_unmarshal(t, src, want, repeats, map[string]json.Raw, loc) or_return
		expect_refuse_unmarshal(t, src, want, repeats, Dup_Target, loc) or_return
	}
	return true
}

@(test)
test_refuse_offsets :: proc(t: ^testing.T) {
	when !REFUSE_DUPLICATES {
		return // `.Refuse` is compiled out; test_refuse_compiled_out pins that
	}
	defer free_all(context.temp_allocator)
	Case :: struct {
		src:    string,
		repeat: string, // where the repeat's key starts, "" when there is none
	}
	cases := [?]Case{
		{`{"a":1,"a":2}`, `"a":2`},
		{`{"a":1,"\u0061":2}`, `"\u0061"`},
		{`{"\u0061":1,"a":2}`, `"a":2`},
		{`{"\u0061":1,"\u0061":2}`, `"\u0061":2`},
		{`{"é":1,"\u00e9":2}`, `"\u00e9"`},
		{`{"\ud83d\ude00":1,"😀":2}`, `"😀"`},
		{`{"a\"b":1,"a\u0022b":2}`, `"a\u0022b"`},
		{`{"":1,"":2}`, `"":2`},
		{`{"abcdefghijkl":1,"abcdefghijkm":2,"abcdefghijk\u006c":3}`, `"abcdefghijk\u006c"`},
		{`{"a":{"b":1,"b":2}}`, `"b":2`},
		{`{"a":[{"b":1},{"b":1,"c":{"d":0,"d":1}}]}`, `"d":1`},
		{`{"a":1,"b":{"a":1},"a":2}`, `"a":2`},
		{`{ "a" : 1 , "a" : 2 }`, `"a" : 2`},
		{`[{"x":1},{"x":1,"x":2}]`, `"x":2`},
		// A repeat outranks a fault in its own value, which follows it.
		{`{"a":1,"a":01}`, `"a":01`},
		{`{"a":1,"a" :`, `"a" :`},
		// Not repeats: other depths, sibling objects, other decoded text.
		{`{"x":{"a":1},"a":{"a":1}}`, ``},
		{`[{"a":1},{"a":1}]`, ``},
		{`{"a":1,"A":2,"\u0000":3,"":4}`, ``},
		{`{"1":1,"01":2}`, ``},
		{`{"a":{"a":{"a":{}}},"b":{"a":{"a":{}}}}`, ``},
	}
	for c in cases {
		src := raw(c.src)
		want: Maybe(json.Error)
		if c.repeat != "" {
			want = json.Error{offset = at(c.src, c.repeat), kind = .Duplicate_Key}
		}
		expect_refuse_everywhere(t, src, want)
	}
	// A fault before the repeat is the result, as `validate` gives it: one in an earlier value, or the missing
	// colon after the repeat's key, which the key check follows.
	for text in ([?]string{`{"a":01,"a":1}`, `{"a":1,"a" 2}`}) {
		src := raw(text)
		want := json.validate(src)
		for paths in ([?][]json.Path{{{steps = {json.Name("a")}}}, {{steps = {json.Name("a"), json.Any{}}}}}) {
			expect_refuse_scan(t, src, want, {.Path}, paths, .Strict, .Json)
		}
		_, err := json.build(src, {duplicates = .Refuse})
		testing.expectf(t, dup_verdict_is(err, want), "build %s: %v, want %v", text, err, want)
	}
	// JSONC: comments around the repeat's key.
	jsonc := `{"a":1, /* c */ "a" // d
	: 2}`
	_, err := json.build(raw(jsonc), {dialect = .Jsonc, duplicates = .Refuse})
	testing.expectf(t, dup_verdict_is(err, json.Error{offset = at(jsonc, `"a" //`), kind = .Duplicate_Key}), "jsonc: %v", err)
	// `.Last` keeps a repeat, and `child` reads it.
	doc, berr := json.build(raw(`{"a":1,"a":2}`), {duplicates = .Last})
	testing.expectf(t, berr == nil, ".Last: %v", berr)
	a, _ := json.get_int(&doc, json.child(&doc, json.ROOT, "a"))
	testing.expect_value(t, a, 2)
	json.destroy(&doc)
}

// `build` honours every `Duplicates` policy: `.Default`, `.Last` and `.All` keep every member, `.First` keeps the
// first member of a repeated key and drops each later one with its subtree, its escaped keys and its comments,
// and `.Refuse` refuses (above). A pruned document is written from its rows, so its text holds no dropped member.
@(test)
test_build_honours_every_duplicates_policy :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := `{"a":1,"b":{"x":[1,2],"x":3,"y":4,"y":{"z":5}},"a":{"c":[6]},"b":7,"y":8}`
	for mode in ([?]json.Duplicates{.Default, .Last, .All}) {
		doc, err := json.build(raw(text), {duplicates = mode})
		testing.expectf(t, err == nil, "%v: %v", mode, err)
		testing.expectf(t, json.child_count(&doc, json.ROOT) == 5 && !doc.pruned, "%v: %d members", mode, json.child_count(&doc, json.ROOT))
		b, _ := json.get_int(&doc, json.child(&doc, json.ROOT, "b"))
		testing.expectf(t, b == 7, "%v: .b is %d", mode, b)
		json.destroy(&doc)
	}
	kept := `{"a":1,"b":{"x":[1,2],"y":4},"y":8}`
	for nested in ([?]bool{false, true}) {
		src, want := text, kept
		if nested {
			src = strings.concatenate({"[", text, ",{\"a\":[", text, "]}]"}, context.temp_allocator)
			want = strings.concatenate({"[", kept, ",{\"a\":[", kept, "]}]"}, context.temp_allocator)
		}
		doc, err := json.build(raw(src), {duplicates = .First})
		testing.expectf(t, err == nil, "nested %v: %v", nested, err)
		out, merr := json.marshal(&doc)
		testing.expectf(t, merr == nil && string(out) == want, "nested %v: %s %v", nested, out, merr)
		delete(out)
		testing.expect(t, doc.distinct_keys && doc.pruned)
		testing.expect_value(t, int(doc.rows[0].subtree_size), len(doc.rows))
		root := json.ROOT if !nested else json.child(&doc, json.ROOT, 0)
		testing.expect_value(t, json.child_count(&doc, root), 3)
		y, _ := json.get_int(&doc, json.child(&doc, json.child(&doc, root, "b"), "y"))
		testing.expect_value(t, y, 4)
		top, _ := json.get_int(&doc, json.child(&doc, root, "y"))
		testing.expect_value(t, top, 8)
		json.destroy(&doc)
	}
	// A dropped member's comments leave with it; the kept ones stay.
	jsonc := "{\"a\": 1, // one\n\"a\": 2 // two\n, \"b\": 3 // three\n}"
	doc, err := json.build(raw(jsonc), {dialect = .Jsonc, duplicates = .First})
	testing.expectf(t, err == nil, "jsonc: %v", err)
	comments: [dynamic]string
	defer delete(comments)
	for f in doc.facts {
		append(&comments, jsonc[f.lo:f.hi])
	}
	testing.expectf(t, slice.equal(comments[:], []string{"// one", "// three"}), "jsonc comments: %v", comments[:])
	testing.expect_value(t, json.child_count(&doc, json.ROOT), 2)
	json.destroy(&doc)

	src := raw(`{"a":1,"a":2}`)
	refusal := json.Error{kind = .Bad_Option}
	line, col := json.error_position(src, refusal)
	testing.expect(t, line == 0 && col == 0)
	rendered := json.render_error(src, refusal)
	defer delete(rendered)
	testing.expect_value(t, rendered, "offset 0: Unsupported option")
}

// Whether `Duplicates.Refuse` is compiled in; the tests of its refusals run only where it is.
REFUSE_DUPLICATES :: #config(REFUSE_DUPLICATES, true)

// Built without the key-checking walks (`-define:REFUSE_DUPLICATES=false`, `make test-modes`), `.Refuse` is
// refused before any byte is read: `scan` and `build` as `.Bad_Option`. `unmarshal`
// keeps it.
@(test)
test_refuse_compiled_out :: proc(t: ^testing.T) {
	when !REFUSE_DUPLICATES {
		src := raw(`{"a":1,"a":2}`)
		req: json.Request({.Path})
		_ = request_of(&req, {{steps = []json.Step{json.Name("a")}}}, {duplicates = .Refuse})
		request_refused(t, json.scan(src, &req), .Bad_Option)
		testing.expect_value(t, len(req.answers), 0)
		json.destroy(&req)
		for dialect in json.Dialect {
			doc, err := json.build(src, {dialect = dialect, duplicates = .Refuse})
			testing.expectf(t, err == json.Error{kind = .Bad_Option}, "%v: %v", dialect, err)
			testing.expect_value(t, len(doc.rows), 0)
		}
		defer free_all(context.temp_allocator)
		v: map[string]int
		uerr, refused := json.unmarshal(src, &v, {duplicates = .Refuse}, nil, context.temp_allocator).?
		testing.expect(t, refused && uerr.kind == .Duplicate_Key)
	}
}

// Objects past the key set's scratch, alone, nested and side by side, at every size the table doubles through.
@(test)
test_refuse_big_objects :: proc(t: ^testing.T) {
	when !REFUSE_DUPLICATES {
		return // `.Refuse` is compiled out; test_refuse_compiled_out pins that
	}
	defer free_all(context.temp_allocator)
	for n in ([?]int{63, 64, 65, 129, 1001, 5000}) {
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '{')
		for k in 0 ..< n {
			fmt.sbprintf(&b, `%s"k%d":%d`, "," if k > 0 else "", k, k)
		}
		whole := strings.clone(strings.to_string(b), context.temp_allocator)
		expect_refuse_everywhere(t, raw(strings.concatenate({whole, "}"}, context.temp_allocator)), nil)
		repeat := fmt.tprintf(`,"\u006b%d":0}`, n / 2)
		src := strings.concatenate({whole, repeat}, context.temp_allocator)
		expect_refuse_everywhere(t, raw(src), json.Error{offset = u64(len(whole) + 1), kind = .Duplicate_Key})
	}
	// A 100 x 100 grid: every row reuses the same names, past the scratch while its parent holds 100 more, and
	// forgets them at its close, a repeat in the last row is found.
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	for r in 0 ..< 100 {
		fmt.sbprintf(&b, `%s"r%d":{{`, "," if r > 0 else "", r)
		for k in 0 ..< 100 {
			fmt.sbprintf(&b, `%s"k%d":0`, "," if k > 0 else "", k)
		}
		strings.write_byte(&b, '}')
	}
	grid := strings.to_string(b)
	expect_refuse_everywhere(t, raw(strings.concatenate({grid, "}"}, context.temp_allocator)), nil)
	bad := strings.concatenate({grid[:len(grid) - 1], `,"k7":1}}`}, context.temp_allocator)
	expect_refuse_everywhere(t, raw(bad), json.Error{offset = u64(len(grid)), kind = .Duplicate_Key})
}

// `.Lazy` reads as under `.First` and may stop before a repeat: the stop is no result, and a `.Strict` scan
// finds it. A repeat before the answer settles is read and refused.
@(test)
test_refuse_under_lazy :: proc(t: ^testing.T) {
	when !REFUSE_DUPLICATES {
		return // `.Refuse` is compiled out; test_refuse_compiled_out pins that
	}
	defer free_all(context.temp_allocator)
	src := `{"a":1,"b":{"x":1,"x":2}}`
	req: json.Request({.Path})
	defer json.destroy(&req)
	_ = request_of(&req, {{steps = {json.Name("a")}}}, {strictness = .Lazy, duplicates = .Refuse})
	testing.expect_value(t, json.scan(raw(src), &req), nil)
	testing.expect(t, req.state.stop != nil, "the walk stops at the settled answer")
	testing.expect_value(t, answer_texts(req.answers[:], src), `1`)
	whole := strict_verdict(raw(src), &req)
	testing.expect(t, dup_verdict_is(whole, json.Error{offset = at(src, `"x":2`), kind = .Duplicate_Key}))

	early := `{"b":{"x":1,"x":2},"a":1}`
	testing.expect(t, dup_verdict_is(scan_fault(json.scan(raw(early), &req)), json.Error{offset = at(early, `"x":2`), kind = .Duplicate_Key}))
}
