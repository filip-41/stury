package json_tests

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import scan "../../core/build"
import typed "../../core/typed"
import records "../../core/records"
import json ".."
import walktest "../../walktest"

// Each text with the steps it reads as.
@(test)
parse_path_steps :: proc(t: ^testing.T) {
	Case :: struct {
		text:  string,
		steps: []core.Step,
	}
	cases := []Case {
		{".", {}},
		{" . ", {}},
		{".a", {core.Name("a")}},
		{".a_1.B", {core.Name("a_1"), core.Name("B")}},
		{`."a-b"`, {core.Name("a-b")}},
		{`.["a-b"]`, {core.Name("a-b")}},
		{`.a."b"["c"].["d"]`, {core.Name("a"), core.Name("b"), core.Name("c"), core.Name("d")}},
		{`.""`, {core.Name("")}},
		{`."a\"bé😀\n"`, {core.Name("a\"bé\U0001f600\n")}},
		{`.["é"]`, {core.Name("é")}},
		{".[0]", {core.Index(0)}},
		{".[-1]", {core.Index(-1)}},
		{".a[0][1]", {core.Name("a"), core.Index(0), core.Index(1)}},
		{".a.[0]", {core.Name("a"), core.Index(0)}},
		{".[]", {core.All{}}},
		{".a[].b", {core.Name("a"), core.All{}, core.Name("b")}},
		{".[2:5]", {core.Slice{2, 5}}},
		{".[2:]", {core.Slice{lo = 2}}},
		{".[:5]", {core.Slice{0, 5}}},
		{".[-2:-1]", {core.Slice{-2, -1}}},
		{"..", {core.Descend{}}},
		{"...a", {core.Descend{}, core.Name("a")}},
		{"..[0]", {core.Descend{}, core.Index(0)}},
	}
	for c in cases {
		p, e := core.parse_path(c.text)
		defer core.path_destroy(&p)
		walktest.expect_nil(t, e)
		testing.expect_value(t, len(p.steps), len(c.steps))
		if len(p.steps) != len(c.steps) {
			continue
		}
		for s, i in c.steps {
			testing.expectf(t, p.steps[i] == s, "%q step %d: %v", c.text, i, p.steps[i])
		}
	}
}

// `?`, `first` and `limit` beside the steps they mark.
@(test)
parse_path_marks :: proc(t: ^testing.T) {
	p, e := core.parse_path(".a?.b.c[]??")
	walktest.expect_nil(t, e)
	testing.expect_value(t, p.optional, bit_set[0 ..< core.MAX_STEPS; u64]{0, 3})
	testing.expect_value(t, len(p.steps), 4)
	core.path_destroy(&p)

	p, e = core.parse_path(" first( .a ) ")
	walktest.expect_nil(t, e)
	testing.expect_value(t, p.limit.?, 1)
	core.path_destroy(&p)

	p, e = core.parse_path("limit( 3 ; .a[] )")
	walktest.expect_nil(t, e)
	testing.expect_value(t, p.limit.?, 3)
	testing.expect_value(t, len(p.steps), 2)
	core.path_destroy(&p)

	p, e = core.parse_path("limit(0; .a)")
	walktest.expect_nil(t, e)
	testing.expect_value(t, p.limit.?, 0)
	core.path_destroy(&p)
}

// Each refused text with the byte it is refused at and why.
@(test)
parse_path_refused :: proc(t: ^testing.T) {
	Case :: struct {
		text:   string,
		at:     u64,
		reason: core.Path_Reason,
	}
	cases := []Case {
		{"", 0, .No_Dot},
		{"a", 0, .No_Dot},
		{"/a", 0, .Pointer_Text},
		{".a.", 2, .Bad_Name},
		{".a b", 3, .Trailing},
		{".a..b", 2, .Bad_Name},
		{".a-b", 2, .Trailing},
		{".[", 1, .Unclosed_Bracket},
		{".[0", 3, .Unclosed_Bracket},
		{".[:]", 1, .Bad_Bracket},
		{".[a]", 1, .Bad_Bracket},
		{`."a`, 1, .Unclosed_Quote},
		{`."\x"`, 2, .Bad_Escape},
		{`."\ud83d"`, 2, .Bad_Escape},
		{`."\ude00"`, 2, .Bad_Escape},
		{".\"\xff\"", 2, .Invalid_Utf8},
		{".[\"a\xc3\"]", 4, .Invalid_Utf8},
		{".\"\xed\xa0\x80\"", 2, .Invalid_Utf8},
		{".\"\xe2\x82", 2, .Invalid_Utf8},
		{`.["a"`, 5, .Unclosed_Bracket},
		{".[99999999999999999999]", 1, .Bad_Bracket},
		{"first(.a", 8, .Unclosed_Paren},
		{"limit(-1; .a)", 6, .Bad_Limit},
		{"limit(1 .a)", 8, .No_Semicolon},
		{".a | .b", 3, .Trailing},
		{"..a", 2, .Trailing},
	}
	for c in cases {
		p, e := core.parse_path(c.text)
		defer core.path_destroy(&p)
		testing.expectf(t, walktest.path_of(e).kind == .Bad_Path && walktest.at_of(e) == c.at && walktest.path_of(e).reason == c.reason && walktest.path_of(e).text == c.text, "%q: %v", c.text, e)
	}
	long := strings.repeat(".a", core.MAX_STEPS + 1)
	defer delete(long)
	p, e := core.parse_path(long)
	defer core.path_destroy(&p)
	walktest.expect_kind(t, e, core.Path_Error_Kind.Over_Capacity)
}

@(test)
parse_pointer_steps :: proc(t: ^testing.T) {
	Case :: struct {
		text:  string,
		steps: []core.Step,
	}
	cases := []Case {
		{"", {}},
		{"/", {core.Name("")}},
		{"/a/b", {core.Name("a"), core.Name("b")}},
		{"/a~1b/m~0n", {core.Name("a/b"), core.Name("m~n")}},
		{"/0", {core.Index_Or_Name{"0", 0}}},
		{"/12/a", {core.Index_Or_Name{"12", 12}, core.Name("a")}},
		{"/01", {core.Name("01")}},
		{"/-", {core.Name("-")}},
		{"/é~1", {core.Name("é/")}},
		{"/99999999999999999999", {core.Index_Or_Name{"99999999999999999999", max(int)}}},
	}
	for c in cases {
		p, e := core.parse_pointer(c.text)
		defer core.path_destroy(&p)
		walktest.expect_nil(t, e)
		testing.expect_value(t, len(p.steps), len(c.steps))
		if len(p.steps) != len(c.steps) {
			continue
		}
		for s, i in c.steps {
			testing.expectf(t, p.steps[i] == s, "%q step %d: %v", c.text, i, p.steps[i])
		}
	}
	Refused :: struct {
		text:   string,
		at:     u64,
		reason: core.Path_Reason,
	}
	refused := []Refused{{"a", 0, .No_Slash}, {"/a~", 2, .Bad_Tilde}, {"/a~2", 2, .Bad_Tilde}, {"/a/b\xff", 4, .Invalid_Utf8}, {"/\xe2\x82", 1, .Invalid_Utf8}}
	for c in refused {
		p, e := core.parse_pointer(c.text)
		defer core.path_destroy(&p)
		testing.expectf(t, walktest.path_of(e).kind == .Bad_Path && walktest.at_of(e) == c.at && walktest.path_of(e).reason == c.reason && walktest.path_of(e).text == c.text, "%q: %v", c.text, e)
	}
}

// A path text, its answers on a source, and the text of each `.Found`, a mismatch's and a miss's owner.
@(private = "file")
Read_Case :: struct {
	src:   string,
	path:  string,
	want:  []Want,
	opts:  core.Path_Options,
}

@(private = "file")
Want :: struct {
	outcome: core.Presence,
	// The `.Found` value's bytes, or the owner's, "" for no node.
	text:    string,
}

@(private = "file")
check_answers :: proc(t: ^testing.T, c: Read_Case, doc: ^core.Document, answers: []core.Answer, label: string) {
	testing.expectf(t, len(answers) == len(c.want), "%s %q on %q: %v", label, c.path, c.src, answers)
	if len(answers) != len(c.want) {
		return
	}
	for a, i in answers {
		w := c.want[i]
		testing.expectf(t, a.outcome == w.outcome, "%s %q on %q #%d: %v", label, c.path, c.src, i, a)
		node := a.node if a.outcome == .Found else a.owner
		if a.outcome != .Found && w.text == "" {
			testing.expectf(t, node == core.NO_NODE, "%s %q on %q #%d: %v", label, c.path, c.src, i, a)
			continue
		}
		testing.expectf(t, string(core.span(doc, node)) == w.text, "%s %q on %q #%d: %q", label, c.path, c.src, i, string(core.span(doc, node)))
	}
}

@(test)
path_reads :: proc(t: ^testing.T) {
	F :: core.Presence.Found
	M :: core.Presence.Missing
	T :: core.Presence.Wrong_Kind
	nested := `{"a":{"b":[1,{"c":2}]},"z":0}`
	cases := []Read_Case {
		{`{"a":1,"b":2}`, ".", {{F, `{"a":1,"b":2}`}}, {}},
		{`{"a":1,"b":2}`, ".a", {{F, "1"}}, {}},
		{`{"a":1,"b":2}`, ".b", {{F, "2"}}, {}},
		{`{"a":1}`, ".b", {{M, `{"a":1}`}}, {}},
		{nested, ".a.b", {{F, `[1,{"c":2}]`}}, {}},
		{nested, ".a.b[1].c", {{F, "2"}}, {}},
		{nested, ".a.b[2]", {{M, `[1,{"c":2}]`}}, {}},
		{nested, ".a.b[]", {{F, "1"}, {F, `{"c":2}`}}, {}},
		{nested, ".a.b[].c", {{T, "1"}, {F, "2"}}, {}},
		{nested, ".a.x.y", {{M, `{"b":[1,{"c":2}]}`}}, {}},
		{nested, ".z.y", {{T, "0"}}, {}},
		{nested, ".z[0]", {{T, "0"}}, {}},
		{nested, ".z[]", {{T, "0"}}, {}},
		{nested, ".a[0]", {{T, `{"b":[1,{"c":2}]}`}}, {}},
		{nested, ".a.x[]", {{T, `{"b":[1,{"c":2}]}`}}, {}},
		{`[]`, ".[]", {}, {}},
		{`[]`, ".[0]", {{M, `[]`}}, {}},
		{`[]`, ".a", {{T, `[]`}}, {}},
		{`{"a":null}`, ".a", {{F, "null"}}, {}},
		{`{"a":null}`, ".a.b", {{M, `{"a":null}`}}, {}},
		{`{"a":null}`, ".a[0]", {{M, `{"a":null}`}}, {}},
		{`{"a":null}`, ".a[]", {{T, "null"}}, {}},
		{`{"a":null}`, ".a.b[]", {{T, "null"}}, {}},
		{`null`, ".a", {{M, "null"}}, {}},
		{`1`, ".", {{F, "1"}}, {}},
		{`[1,2,3]`, "first(.[])", {{F, "1"}}, {}},
		{`[1,2,3]`, "limit(2; .[])", {{F, "1"}, {F, "2"}}, {}},
		{`[1,2,3]`, "limit(0; .[])", {}, {}},
		{`{"a":1,"a":2}`, ".a", {{F, "2"}}, {}},
		{`{"a":1,"a":2}`, ".a", {{F, "1"}}, {dups = core.Duplicates.First}},
		{`{"a":{"b":1},"a":{"c":2}}`, ".a.b", {{M, `{"c":2}`}}, {}},
		{`{"a":[1,2],"a":[3]}`, ".a[]", {{F, "3"}}, {}},
		{`{"a":[1,2],"a":[3]}`, "first(.a[])", {{F, "3"}}, {}},
		{`{"a":[1,2],"a":[3]}`, "first(.a[])", {{F, "1"}}, {dups = core.Duplicates.First}},
		{`[{"a":1},{},2,{"a":3}]`, ".[].a", {{F, "1"}, {M, `{}`}, {T, "2"}, {F, "3"}}, {}},
		{`{"p":1,"q":2}`, ".[]", {{F, "1"}, {F, "2"}}, {}},
		{`{"ab":1}`, ".ab", {{F, "1"}}, {}},
		{`{"ab":1}`, `."ab"`, {{F, "1"}}, {}},
		{`{"\u0061":1}`, ".a", {{F, "1"}}, {}},
		{`[0,1,2,3,4,5,6,7,8]`, ".[]", {{F, "0"}, {F, "1"}, {F, "2"}, {F, "3"}, {F, "4"}, {F, "5"}, {F, "6"}, {F, "7"}, {F, "8"}}, {}},
	}
	for c in cases {
		path, perr := core.parse_path(c.path)
		defer core.path_destroy(&path)
		walktest.expect_nil(t, perr)

		doc, err := json.scan(transmute([]u8)c.src, .Json, path, read = c.opts)
		defer core.destroy(&doc)
		testing.expectf(t, err == nil, "%q: %v", c.path, err)
		check_answers(t, c, &doc, doc.answers, "scan")

		full, berr := core.build(transmute([]u8)c.src, json.as(.Json))
		defer core.destroy(&full)
		walktest.expect_nil(t, berr)
		answers, qerr := json.query(&full, path, {dups = c.opts.dups})
		defer delete(answers)
		walktest.expect_nil(t, qerr)
		check_answers(t, c, &full, answers, "query")
	}
}

// A partial document's reads: what it kept, what a path looked for, and what nobody asked for.
@(test)
partial_reads :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"keep":1,"a":{"x":[10,20,30],"y":2},"z":3}`)
	path, _ := core.parse_path(".a.x[1]")
	defer core.path_destroy(&path)
	doc, err := json.scan(src, .Json, path)
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	testing.expect_value(t, doc.nodes[core.ROOT].role, core.Role.Partial)
	testing.expect_value(t, core.length(&doc, core.ROOT), 3)
	a, found := core.member_of(&doc, core.ROOT, "a")
	testing.expect_value(t, found, core.Presence.Found)
	_, other := core.member_of(&doc, core.ROOT, "keep")
	testing.expect_value(t, other, core.Presence.Not_Loaded)
	testing.expect_value(t, string(core.span(&doc, a)), `{"x":[10,20,30],"y":2}`)
	x, _ := core.member_of(&doc, a, "x")
	testing.expect_value(t, core.length(&doc, x), 3)
	v, at := core.element_of(&doc, x, 1)
	testing.expect_value(t, at, core.Presence.Found)
	testing.expect_value(t, string(core.span(&doc, v)), "20")
	_, before := core.element_of(&doc, x, 0)
	testing.expect_value(t, before, core.Presence.Not_Loaded)
	_, past := core.element_of(&doc, x, 3)
	testing.expect_value(t, past, core.Presence.Missing)
	testing.expect_value(t, string(core.span(&doc, core.ROOT)), string(src))

	miss, _ := core.parse_path(".a.host")
	defer core.path_destroy(&miss)
	partial, merr := json.scan(src, .Json, miss)
	defer core.destroy(&partial)
	walktest.expect_nil(t, merr)
	owner := partial.answers[0].owner
	_, listed := core.member_of(&partial, owner, "host")
	testing.expect_value(t, listed, core.Presence.Missing)
	_, unlisted := core.member_of(&partial, owner, "y")
	testing.expect_value(t, unlisted, core.Presence.Not_Loaded)

}

@(private = "file")
expect_set :: proc(t: ^testing.T, src, path_text, text, want: string, read := core.Query_Options{}, loc := #caller_location) {
	path, perr := core.parse_path(path_text)
	defer core.path_destroy(&path)
	walktest.expect_nil(t, perr, loc)
	out, err := json.set(transmute([]u8)src, .Json, path, text, read = read)
	defer delete(out)
	walktest.expect_nil(t, err, loc)
	testing.expect_value(t, string(out), want, loc)
}

@(test)
path_set :: proc(t: ^testing.T) {
	expect_set(t, `{"host":"h","port":80}`, ".port", "8080", `{"host":"h","port":8080}`)
	expect_set(t, `{"host":"h"}`, ".port", "8080", `{"host":"h","port":8080}`)
	expect_set(t, `{}`, ".port", "1", `{"port":1}`)
	expect_set(t, `{"a":{"b":{}}}`, ".a.b.c", "1", `{"a":{"b":{"c":1}}}`)
	expect_set(t, `[{"a":1},{"b":2}]`, ".[].a", "0", `[{"a":0},{"b":2,"a":0}]`)
	expect_set(t, `{"a":[1,2,3]}`, ".a[-1]", "0", `{"a":[1,2,0]}`)
	expect_set(t, `{"a":1,"a":2}`, ".a", "3", `{"a":1,"a":3}`)
	expect_set(t, `{"b":{}}`, "...a", "0", `{"b":{"a":0},"a":0}`)
	expect_set(t, `{"a":1,"a":2}`, ".a", "3", `{"a":3,"a":2}`, {dups = .First})
	expect_set(t, `{"a":1,"a":2}`, ".a", "3", `{"a":3,"a":3}`, {dups = .All})
	// Under a limit the first answer of `...a` may be a container that lacks `a`.
	expect_set(t, `{"x":{}}`, "first(...a)", "9", `{"x":{"a":9}}`)
	expect_set(t, `{}`, "limit(1; ...a)", "9", `{"a":9}`)
	// `?` on the last name drops a container that is no object and inserts into one that lacks the name.
	expect_set(t, `{"x":{}}`, ".x.a?", "9", `{"x":{"a":9}}`)
	expect_set(t, `[1,{},{"a":2}]`, ".[].a?", "9", `[1,{"a":9},{"a":9}]`)
	expect_set(t, `{"x":5}`, ".x.a?", "9", `{"x":5}`)
	expect_set(t, `{"a":[1]}`, ".a[1]", "9", `{"a":[1,9]}`)
	refused := [?]string{".a.b", ".x.y", ".a[5]", ".a[]", "...a"}
	for text in refused {
		src := `{"a":1}`
		path, _ := core.parse_path(text)
		defer core.path_destroy(&path)
		out, err := json.set(transmute([]u8)src, .Json, path, "1")
		defer delete(out)
		testing.expectf(t, walktest.document_of(err).kind == .Bad_Index, "%s: %v", text, err)
	}
	bad_text := transmute([]u8)string(`{"a":1}`)
	a, _ := core.parse_path(".a")
	defer core.path_destroy(&a)
	_, verr := json.set(bad_text, .Json, a, "01")
	testing.expect(t, walktest.document_of(verr).kind == .Bad_Value)
	_, perr := core.parse_path(".[")
	walktest.expect_kind(t, perr, core.Path_Error_Kind.Bad_Path)
}

// A set can refuse a repeated key, and its path errors and edit errors render from the same call.
@(test)
path_set_refusals :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"a":1,"a":2}`)
	a, _ := core.parse_path(".a")
	defer core.path_destroy(&a)
	_, dup := json.set(src, .Json, a, "3", read = {dups = .Refuse})
	testing.expect(t, walktest.is_duplicate(dup))
	b := strings.builder_make(context.temp_allocator)
	core.render(strings.to_writer(&b), src, dup)
	testing.expect_value(t, strings.to_string(b), "1:8: Duplicate key")
	strings.builder_reset(&b)
	core.write_code(strings.to_writer(&b), dup)
	testing.expect_value(t, strings.to_string(b), "duplicate_key")

	unset := make([]core.Step, 1, context.temp_allocator)
	_, bad := json.set(src, .Json, core.Path{steps = unset}, "3")
	walktest.expect_kind(t, bad, core.Path_Error_Kind.Bad_Path)
	strings.builder_reset(&b)
	core.render(strings.to_writer(&b), src, bad)
	testing.expect_value(t, strings.to_string(b), "Invalid path: a step is unset")
	strings.builder_reset(&b)
	core.write_code(strings.to_writer(&b), bad)
	testing.expect_value(t, strings.to_string(b), "path.bad_path")

	// A path error points into the path's text, which it holds, and a walk error into the source.
	_, perr := core.parse_path(".a[")
	strings.builder_reset(&b)
	core.render(strings.to_writer(&b), src, perr)
	testing.expect_value(t, strings.to_string(b), "1:3: Invalid path \".a[\": `[` is not closed")
	_, werr := json.scan(transmute([]u8)string(`{"a":!}`), .Json, a)
	strings.builder_reset(&b)
	core.render(strings.to_writer(&b), transmute([]u8)string(`{"a":!}`), werr)
	testing.expect_value(t, strings.to_string(b), "1:6: Expected a value")
}

// A failed path names its number in the read, and a read past the limits says which one.
@(test)
path_errors_name_the_path :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"a":1}`)
	good, _ := core.parse_path(".a")
	defer core.path_destroy(&good)
	bad := core.Path{steps = []core.Step{core.Descend{}, core.Descend{}}}
	_, e := json.scan(src, .Json, []core.Path{good, good, bad})
	walktest.expect_kind(t, e, core.Path_Error_Kind.Bad_Path)
	testing.expect_value(t, walktest.path_of(e).path, 2)
	_, e = json.scan(src, .Json, []core.Path{bad})
	testing.expect_value(t, walktest.path_of(e).path, 0)
	_, e = json.scan(src, .Json, []core.Path{good, {limit = -1}})
	testing.expect_value(t, walktest.path_of(e).path, 1)
	many: [core.MAX_PATHS + 1]core.Path
	_, e = json.scan(src, .Json, many[:])
	walktest.expect_kind(t, e, core.Path_Error_Kind.Over_Capacity)
	b := strings.builder_make(context.temp_allocator)
	core.render(strings.to_writer(&b), src, e)
	testing.expect(t, strings.contains(strings.to_string(b), "MAX_PATHS"))
}

// `.Refuse` holds in every object of the text with several paths, in a query and in `each_answer`, and `on`
// ends a read by returning false.
@(test)
stream_stops_and_refuses :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"a":1,"b":2,"c":{"x":1,"x":2}}`)
	a, _ := core.parse_path(".a")
	defer core.path_destroy(&a)
	b, _ := core.parse_path(".b")
	defer core.path_destroy(&b)
	paths := [2]core.Path{a, b}
	doc, err := json.scan(src, .Json, paths[:], read = {dups = .Refuse})
	defer core.destroy(&doc)
	walktest.expect_kind(t, err, core.Path_Error_Kind.Duplicate_Key)
	seen := 0
	first_only :: proc(state: rawptr, _: core.Token_Answer) -> bool {
		(^int)(state)^ += 1
		return false
	}
	serr := json.each_answer(src, .Json, paths[:], &seen, first_only, read = {dups = .Refuse})
	walktest.expect_kind(t, serr, core.Path_Error_Kind.Duplicate_Key)
	testing.expect_value(t, seen, 0)
	walktest.expect_nil(t, json.each_answer(src, .Json, paths[:], &seen, first_only))
	testing.expect_value(t, seen, 1)
	// A stop inside containers the path is in leaves them open.
	all_a, _ := core.parse_path(".[].a")
	defer core.path_destroy(&all_a)
	seen = 0
	nested := transmute([]u8)string(`[[1,2],[3]]`)
	walktest.expect_nil(t, json.each_answer(nested, .Json, all_a, &seen, first_only))
	testing.expect_value(t, seen, 1)
}

// A member kept by position says nothing of a repeat of its key that a limit cut, and one kept by name does.
@(test)
partial_repeated_keys :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"0":true,"0":null}`)
	cut, _ := core.parse_path("limit(1; .[])")
	defer core.path_destroy(&cut)
	doc, err := json.scan(src, .Json, cut)
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	_, last := core.member_of(&doc, core.ROOT, "0")
	testing.expect_value(t, last, core.Presence.Not_Loaded)
	first, at := core.member_of(&doc, core.ROOT, "0", .First)
	testing.expect_value(t, at, core.Presence.Found)
	testing.expect_value(t, string(core.span(&doc, first)), "true")

	pointer, _ := core.parse_pointer("/0")
	defer core.path_destroy(&pointer)
	named, nerr := json.scan(transmute([]u8)string(`{"0":1,"0":2,"b":3}`), .Json, pointer)
	defer core.destroy(&named)
	walktest.expect_nil(t, nerr)
	v, found := core.member_of(&named, core.ROOT, "0")
	testing.expect_value(t, found, core.Presence.Found)
	testing.expect_value(t, string(core.span(&named, v)), "2")
}

// A `Partial` container's end comes from a walk that takes the text as the read did.
@(test)
partial_tolerated_span :: proc(t: ^testing.T) {
	src := transmute([]u8)string("{\"a\":{\"x\":1,\"y\":\"\xff\"}}")
	path, _ := core.parse_path(".a.x")
	defer core.path_destroy(&path)
	doc, err := json.scan(src, .Json, path, opts = {tolerate = {.Invalid_Utf8}})
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(core.span(&doc, doc.answers[0].owner)), "{\"x\":1,\"y\":\"\xff\"}")
}

// A path of step literals meets the capacity a parsed one does.
@(test)
path_capacity :: proc(t: ^testing.T) {
	steps: [core.MAX_STEPS + 1]core.Step
	for &s in steps {
		s = core.Name("a")
	}
	src := transmute([]u8)string(`1`)
	doc, err := json.scan(src, .Json, core.Path{steps = steps[:core.MAX_STEPS]})
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	_, over := json.scan(src, .Json, core.Path{steps = steps[:]})
	walktest.expect_kind(t, over, core.Path_Error_Kind.Over_Capacity)
}

// A stop leaves what follows the answer unread, so a fault there goes unseen, and without the stop it is seen.
@(test)
stop_early_reads :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"a":1,"b":[1,2],"c":!`)
	path, _ := core.parse_path(".a")
	defer core.path_destroy(&path)
	doc, err := json.scan(src, .Json, path, read = {dups = .First, stop_early = true})
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	testing.expect_value(t, len(doc.answers), 1)
	testing.expect(t, doc.stopped)
	_, rest := core.member_of(&doc, core.ROOT, "b")
	testing.expect_value(t, rest, core.Presence.Not_Loaded)

	_, bad := json.scan(src, .Json, path)
	walktest.expect_kind(t, bad, core.Path_Error_Kind.Walk)

	each, _ := core.parse_path(".a[]")
	defer core.path_destroy(&each)
	late := transmute([]u8)string(`{"a":[1,2],"a":[3]}!`)
	named, nerr := json.scan(late, .Json, each, read = {stop_early = true, dups = core.Duplicates.Last})
	defer core.destroy(&named)
	walktest.expect_nil(t, nerr)
	testing.expect_value(t, len(named.answers), 1)

	_, dup := json.scan(transmute([]u8)string(`{"a":1,"a":2}`), .Json, path, read = {dups = .Refuse})
	walktest.expect_kind(t, dup, core.Path_Error_Kind.Duplicate_Key)
}

@(test)
a_negative_index_past_sixty_four_reads_its_element :: proc(t: ^testing.T) {
	text: [dynamic]u8
	defer delete(text)
	append(&text, '[')
	for i in 0 ..< 200 {
		if i > 0 {
			append(&text, ',')
		}
		append(&text, '1')
	}
	append(&text, ']')
	path := core.Path{steps = []core.Step{core.Index(-150)}}
	doc, err := json.scan(text[:], .Json, path)
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	testing.expect_value(t, len(doc.answers), 1)
	testing.expect_value(t, doc.answers[0].outcome, core.Presence.Found)
}

@(test)
path_refusals :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`[1]`)
	for far in ([?]int{-65, -1_000_000_000}) {
		path := core.Path{steps = []core.Step{core.Index(far)}}
		doc, deep := json.scan(src, .Json, path)
		defer core.destroy(&doc)
		walktest.expect_nil(t, deep)
		testing.expect_value(t, len(doc.answers), 1)
		testing.expect_value(t, doc.answers[0].outcome, core.Presence.Missing)
	}
	twice := core.Path{steps = []core.Step{core.Descend{}, core.Name("a"), core.Descend{}}}
	_, again := json.scan(src, .Json, twice)
	walktest.expect_kind(t, again, core.Path_Error_Kind.Bad_Path)
	many: [65]core.Path
	_, over := json.scan(src, .Json, many[:])
	walktest.expect_kind(t, over, core.Path_Error_Kind.Over_Capacity)
	path, _ := core.parse_path(".[0]")
	defer core.path_destroy(&path)
	doc, _ := json.scan(src, .Json, path)
	defer core.destroy(&doc)
	_, e := json.query(&doc, path)
	walktest.expect_kind(t, e, core.Path_Error_Kind.Unsupported)
}

// A step literal that was never set, and a negative limit, are refused where a parsed path would be.
@(test)
path_literals_are_judged :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"a":1}`)
	unset := make([]core.Step, 2, context.temp_allocator)
	unset[0] = core.Name("a")
	_, e := json.scan(src, .Json, core.Path{steps = unset})
	walktest.expect_kind(t, e, core.Path_Error_Kind.Bad_Path)
	_, negative := json.scan(src, .Json, core.Path{limit = -1})
	walktest.expect_kind(t, negative, core.Path_Error_Kind.Bad_Path)
	_, many := json.scan(src, .Json, []core.Path{{}, {limit = -1}})
	walktest.expect_kind(t, many, core.Path_Error_Kind.Bad_Path)
}

@(test)
root_path_owns_nothing :: proc(t: ^testing.T) {
	for text in ([]string{".", " . "}) {
		p, err := core.parse_path(text)
		walktest.expect_nil(t, err)
		testing.expect(t, p.block == nil && p.steps == nil)
	}
	p, _ := core.parse_path("first(.)")
	testing.expect_value(t, p.limit, Maybe(int)(1))
}

// A document owns the names it was told were missing, so the path and its text can go once the read is done.
@(test)
document_outlives_path :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"a":{"x":1}}`)
	text := strings.clone(".a.host", context.temp_allocator)
	path, _ := core.parse_path(text)
	doc, err := json.scan(src, .Json, path)
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	core.path_destroy(&path)
	for &b in transmute([]u8)text {
		b = 'z'
	}
	_, listed := core.member_of(&doc, doc.answers[0].owner, "host")
	testing.expect_value(t, listed, core.Presence.Missing)
	_, other := core.member_of(&doc, doc.answers[0].owner, "zzzz")
	testing.expect_value(t, other, core.Presence.Not_Loaded)
}

// A clone keeps a read's answers and missing names once the original's memory is reused.
@(test)
clone_outlives_document :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"a":{"x":1},"b":[2]}`)
	path, _ := core.parse_path(".a.host")
	defer core.path_destroy(&path)
	backing := make([]u8, 1 << 14)
	defer delete(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	doc, err := json.scan(src, .Json, path, allocator = mem.arena_allocator(&arena))
	walktest.expect_nil(t, err)
	c, cerr := core.clone(&doc)
	defer core.destroy(&c)
	testing.expect_value(t, cerr, nil)
	want := len(doc.nodes)
	for &b in backing {
		b = 0xAA
	}
	testing.expect_value(t, len(c.nodes), want)
	testing.expect_value(t, len(c.answers), 1)
	_, listed := core.member_of(&c, c.answers[0].owner, "host")
	testing.expect_value(t, listed, core.Presence.Missing)
	testing.expect_value(t, core.kind(&c, c.answers[0].owner), core.Kind.Object)
}

// `each_answer` gives the bytes `span` gives for the same value, a string's quotes and a container's brackets included.
@(test)
stream_spans_are_authored :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"a":[["x"]],"b":[1, 2],"c":{"d":null},"e":"A"}`)
	texts := [?]string{".a", ".b", ".c", ".c.d", ".e", ".b[1]"}
	paths: [len(texts)]core.Path
	for text, i in texts {
		paths[i], _ = core.parse_path(text)
	}
	defer for &p in paths {
		core.path_destroy(&p)
	}
	doc, err := json.scan(src, .Json, paths[:])
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	Seen :: struct {
		src:   []u8,
		spans: [8]string,
	}
	seen := Seen{src = src}
	each_answer_span :: proc(state: rawptr, a: core.Token_Answer) -> bool {
		s := (^Seen)(state)
		s.spans[a.path] = string(s.src[a.lo:a.hi])
		return true
	}
	walktest.expect_nil(t, json.each_answer(src, .Json, paths[:], &seen, each_answer_span))
	for a in doc.answers {
		testing.expect_value(t, seen.spans[a.path], string(core.span(&doc, a.node)))
	}
	testing.expect_value(t, seen.spans[0], `[["x"]]`)
	testing.expect_value(t, seen.spans[4], `"A"`)
}

// A read says a value of the wrong kind, as the path does, and a stopped read says its counts are partial.
@(test)
presence_of_wrong_kinds :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"s":5,"a":[1,2,3],"n":null}`)
	full, _ := core.build(src, json.as(.Json))
	defer core.destroy(&full)
	s, _ := core.member_of(&full, core.ROOT, "s")
	a, _ := core.member_of(&full, core.ROOT, "a")
	n, _ := core.member_of(&full, core.ROOT, "n")
	_, scalar := core.member_of(&full, s, "x")
	testing.expect_value(t, scalar, core.Presence.Wrong_Kind)
	_, array := core.member_of(&full, a, "x")
	testing.expect_value(t, array, core.Presence.Wrong_Kind)
	_, null := core.member_of(&full, n, "x")
	testing.expect_value(t, null, core.Presence.Missing)
	_, map_at := core.element_of(&full, core.ROOT, 0)
	testing.expect_value(t, map_at, core.Presence.Wrong_Kind)
	_, scalar_at := core.element_of(&full, s, 0)
	testing.expect_value(t, scalar_at, core.Presence.Wrong_Kind)
	_, null_at := core.element_of(&full, n, 0)
	testing.expect_value(t, null_at, core.Presence.Missing)
	_, past := core.element_of(&full, a, 3)
	testing.expect_value(t, past, core.Presence.Missing)

	path, _ := core.parse_path(".a[0]")
	defer core.path_destroy(&path)
	doc, _ := json.scan(src, .Json, path, read = {dups = .First, stop_early = true})
	defer core.destroy(&doc)
	open, _ := core.member_of(&doc, core.ROOT, "a")
	n_read, exact := core.length_exact(&doc, open)
	testing.expect_value(t, n_read, 1)
	testing.expect(t, !exact)
	_, whole := core.length_exact(&full, a)
	testing.expect(t, whole)
}

@(test)
pointer_reads :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"0":"key","a":[10,20],"b/c":1}`)
	Case :: struct {
		text: string,
		want: string,
	}
	cases := []Case{{"/0", `"key"`}, {"/a/1", "20"}, {"/b~1c", "1"}}
	for c in cases {
		path, perr := core.parse_pointer(c.text)
		defer core.path_destroy(&path)
		walktest.expect_nil(t, perr)
		doc, answer, err := json.find(src, .Json, path)
		defer core.destroy(&doc)
		walktest.expect_nil(t, err)
		testing.expect_value(t, answer.outcome, core.Presence.Found)
		testing.expect_value(t, string(core.span(&doc, answer.node)), c.want)
	}
}

// A pointer's index past an `int` is past the end of an array, as a smaller one is, and still names a member.
@(test)
pointer_index_past_int :: proc(t: ^testing.T) {
	path, perr := core.parse_pointer("/a/99999999999999999999")
	defer core.path_destroy(&path)
	walktest.expect_nil(t, perr)
	Case :: struct {
		src:     string,
		outcome: core.Presence,
	}
	for c in ([]Case{{`{"a":[1,2]}`, .Missing}, {`{"a":{"99999999999999999999":3}}`, .Found}}) {
		doc, err := json.scan(transmute([]u8)c.src, .Json, path)
		defer core.destroy(&doc)
		walktest.expect_nil(t, err)
		testing.expectf(t, len(doc.answers) == 1 && doc.answers[0].outcome == c.outcome, "%s: %v", c.src, doc.answers)
		full, _ := core.build(transmute([]u8)c.src, json.as(.Json))
		defer core.destroy(&full)
		answers, qerr := json.query(&full, path)
		defer delete(answers)
		walktest.expect_nil(t, qerr)
		testing.expectf(t, len(answers) == 1 && answers[0].outcome == c.outcome, "%s: %v", c.src, answers)
	}
}

// An arena that refuses the node bound a kept value's walk reserves by still gets its answer, through the scan's hook.
@(test)
query_kept_value_in_small_arena :: proc(t: ^testing.T) {
	src := strings.concatenate({`{"a":[1,{"b":2}],"pad":"`, strings.repeat("x", 1 << 16, context.temp_allocator), `"}`}, context.temp_allocator)
	path, perr := core.parse_path(".a", context.temp_allocator)
	testing.expect(t, perr == nil)
	buf: [8192]u8
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	doc, err := json.scan(transmute([]u8)src, .Json, path, allocator = mem.arena_allocator(&arena))
	testing.expect(t, err == nil)
	testing.expect(t, len(doc.answers) == 1 && doc.answers[0].outcome == .Found)
	testing.expect(t, string(core.span(&doc, doc.answers[0].node)) == `[1,{"b":2}]`)
}

// A member matched by name has no `Kept_Child`, with one path and with several, so `member_of` does not take it for one
// kept by position.
@(test)
either_by_name_has_no_position :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"0":1,"b":2}`)
	either, e := core.parse_pointer("/0")
	defer core.path_destroy(&either)
	walktest.expect_nil(t, e)
	b, be := core.parse_path(".b")
	defer core.path_destroy(&b)
	walktest.expect_nil(t, be)
	one, oerr := json.scan(src, .Json, either)
	defer core.destroy(&one)
	walktest.expect_nil(t, oerr)
	testing.expect_value(t, len(one.kept), 0)
	paths := [?]core.Path{either, b}
	many, merr := json.scan(src, .Json, paths[:])
	defer core.destroy(&many)
	walktest.expect_nil(t, merr)
	testing.expect_value(t, len(many.kept), 0)
}

// The read options come straight after the paths in every entry, and `each_answer` takes one path as `scan` does.
@(test)
read_options_follow_paths :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"a":1,"a":2}`)
	path, _ := core.parse_path(".a")
	defer core.path_destroy(&path)
	doc, err := json.scan(src, .Json, path, read = {dups = .First})
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(core.span(&doc, doc.answers[0].node)), "1")
	found, answer, ferr := json.find(src, .Json, path, read = {dups = .First})
	defer core.destroy(&found)
	walktest.expect_nil(t, ferr)
	testing.expect_value(t, string(core.span(&found, answer.node)), "1")
	seen: string
	on :: proc(state: rawptr, a: core.Token_Answer) -> bool {
		(^string)(state)^ = "got"
		return true
	}
	walktest.expect_nil(t, json.each_answer(src, .Json, path, &seen, on, read = {dups = .First}))
	testing.expect_value(t, seen, "got")
}

// A refused allocation anywhere in a many-path read, of text or of a built document, is `.No_Memory` and frees what the
// read took.
@(test)
many_path_reads_survive_refused_allocations :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"a":[1,2,{"a":3}],"b":4}`)
	a, _ := core.parse_path("...a")
	defer core.path_destroy(&a)
	b, _ := core.parse_path(".a[-1]")
	defer core.path_destroy(&b)
	paths := [?]core.Path{a, b}
	built, berr := core.build(src, json.as(.Json))
	defer core.destroy(&built)
	walktest.expect_nil(t, berr)
	for hold in ([?]bool{false, true}) {
		for at := 0; at < 24; at += 1 {
			f := walktest.Failing_Alloc{inner = context.allocator, fail_at = at, fail_on = hold}
			alloc := walktest.failing_allocator(&f)
			doc, err := json.scan(src, .Json, paths[:], allocator = alloc)
			testing.expectf(t, err == nil || walktest.is_oom(err), "scan fail_at %d: %v", at, err)
			core.destroy(&doc)
			f = {inner = context.allocator, fail_at = at, fail_on = hold}
			answers, qerr := json.query(&built, paths[:], allocator = alloc)
			testing.expectf(t, qerr == nil || walktest.is_oom(qerr), "query fail_at %d: %v", at, qerr)
			delete(answers, alloc)
		}
	}
}

// Several paths: a `..` read below the depth of its steps, answers at one place in path order, and a repeated key
// under a `..`. Each answer reads as its path and its value's text, or `-` for no value.
@(test)
many_path_reads :: proc(t: ^testing.T) {
	Case :: struct {
		src:   string,
		paths: [2]string,
		want:  []string,
	}
	cases := []Case {
		{`[[[[[{"c":2}]]]]]`, {"...c", ".z"}, {"0 -", "1 -", "0 -", "0 -", "0 -", "0 -", "0 2", "0 -"}},
		{`{"a":1}`, {".a.b", ".a"}, {"0 -", "1 1"}},
		{`{"x":{"a":1,"a":2}}`, {"...a", ".z"}, {"0 -", "0 2", "0 -", "0 -", "1 -"}},
	}
	for c in cases {
		paths: [2]core.Path
		for text, i in c.paths {
			paths[i], _ = core.parse_path(text)
		}
		doc, err := json.scan(transmute([]u8)c.src, .Json, paths[:])
		walktest.expect_nil(t, err)
		got := make([dynamic]string, context.temp_allocator)
		for a in doc.answers {
			append(&got, fmt.tprintf("%d %s", a.path, string(core.span(&doc, a.node)) if a.outcome == .Found else "-"))
		}
		testing.expectf(t, slice.equal(got[:], c.want), "%q %v: %v", c.src, c.paths, got)
		core.destroy(&doc)
		for &path in paths {
			core.path_destroy(&path)
		}
	}
}

// A limit counts the members a path ends in, not the containers a `..` reads before them.
@(test)
path_set_limit_counts_members :: proc(t: ^testing.T) {
	src := `{"aaaaaaaaaaaaaaaaaaaaaaaac":{ "a":12} }`
	path := core.Path{steps = {core.Descend{}, core.Name("a")}, limit = 1}
	full, _ := core.build(transmute([]u8)src, json.as(.Json))
	defer core.destroy(&full)
	list := json.edit_list_init(&full, .Json)
	defer core.edit_list_destroy(&list)
	got, err := scan.set_answers(&list, path, "0")
	defer delete(got)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(got), `{"aaaaaaaaaaaaaaaaaaaaaaaac":{ "a":0} }`)
}

// Under a raised `max_depth` every read of a text nested past `MAX_DEPTH` grows its stacks with the nesting: a build,
// a query of the document, a typed read and a write of it, a scan that descends, keeps a value or streams, and a scan
// of each record.
@(test)
deep_reads_grow_their_stacks :: proc(t: ^testing.T) {
	n := 3 * core.MAX_DEPTH
	text := strings.concatenate({strings.repeat("[", n, context.temp_allocator), strings.repeat("]", n, context.temp_allocator)}, context.temp_allocator)
	src := transmute([]u8)text
	as := json.as(.Json, {max_depth = max(u32)})
	descend, _ := core.parse_path("..[0]", context.temp_allocator)
	first, _ := core.parse_path("[0]", context.temp_allocator)
	doc, berr := core.build(src, as)
	defer core.destroy(&doc)
	if !walktest.expect_nil(t, berr) {
		return
	}
	answers, qerr := scan.query(&doc, []core.Path{descend})
	testing.expect_value(t, qerr.kind, core.Path_Error_Kind.None)
	testing.expect_value(t, len(answers), n)
	delete(answers)
	v: any
	walktest.expect_nil(t, typed.unmarshal(&doc, core.ROOT, &v, nil, {}, context.temp_allocator))
	out, _, werr := core.write(&doc, allocator = context.temp_allocator)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, string(out), text)
	deep, derr := scan.scan(src, as, []core.Path{descend})
	walktest.expect_nil(t, derr)
	testing.expect_value(t, len(deep.answers), n)
	core.destroy(&deep)
	kept, kerr := scan.scan(src, as, first)
	walktest.expect_nil(t, kerr)
	testing.expect_value(t, len(kept.nodes), n)
	core.destroy(&kept)
	count := 0
	on :: proc(state: rawptr, a: core.Token_Answer) -> bool {
		(^int)(state)^ += 1
		return true
	}
	walktest.expect_nil(t, scan.each_answer(src, as, []core.Path{descend}, &count, on))
	testing.expect_value(t, count, n)
	lines := strings.concatenate({"[1]\n", text, "\n", text, "\n"}, context.temp_allocator)
	it := records.open(transmute([]u8)lines, as)
	defer records.close(&it)
	nodes: [dynamic]int
	defer delete(nodes)
	for {
		_, rec, err, more := records.scan(&it, first)
		if !more {
			break
		}
		walktest.expect_nil(t, err)
		append(&nodes, len(rec.nodes))
	}
	testing.expect_value(t, fmt.tprint(nodes[:]), fmt.tprint([]int{2, n, n}))
}
