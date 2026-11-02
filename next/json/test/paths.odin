package json_tests

import "core:mem"
import "core:strings"
import "core:testing"
import core "../../core"
import json ".."

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
		testing.expect_value(t, e.kind, core.Path_Error_Kind.None)
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
	testing.expect_value(t, e.kind, core.Path_Error_Kind.None)
	testing.expect_value(t, p.optional, bit_set[0 ..< core.MAX_STEPS; u64]{0, 3})
	testing.expect_value(t, len(p.steps), 4)
	core.path_destroy(&p)

	p, e = core.parse_path(" first( .a ) ")
	testing.expect_value(t, e.kind, core.Path_Error_Kind.None)
	testing.expect_value(t, p.limit.?, 1)
	core.path_destroy(&p)

	p, e = core.parse_path("limit( 3 ; .a[] )")
	testing.expect_value(t, e.kind, core.Path_Error_Kind.None)
	testing.expect_value(t, p.limit.?, 3)
	testing.expect_value(t, len(p.steps), 2)
	core.path_destroy(&p)

	p, e = core.parse_path("limit(0; .a)")
	testing.expect_value(t, e.kind, core.Path_Error_Kind.None)
	testing.expect_value(t, p.limit.?, 0)
	core.path_destroy(&p)
}

// Each refused text with the byte it is refused at.
@(test)
parse_path_refused :: proc(t: ^testing.T) {
	Case :: struct {
		text: string,
		at:   u64,
	}
	cases := []Case {
		{"", 0},
		{"a", 0},
		{".a.", 2},
		{".a b", 3},
		{".a..b", 2},
		{".a-b", 2},
		{".[", 1},
		{".[0", 3},
		{".[:]", 1},
		{".[a]", 1},
		{`."a`, 1},
		{`."\x"`, 2},
		{`."\ud83d"`, 2},
		{`."\ude00"`, 2},
		{`.["a"`, 5},
		{".[99999999999999999999]", 1},
		{"first(.a", 8},
		{"limit(-1; .a)", 6},
		{"limit(1 .a)", 8},
		{".a | .b", 3},
		{"..a", 2},
	}
	for c in cases {
		p, e := core.parse_path(c.text)
		defer core.path_destroy(&p)
		testing.expectf(t, e.kind == .Bad_Path && e.at == c.at, "%q: %v", c.text, e)
	}
	long := strings.repeat(".a", core.MAX_STEPS + 1)
	defer delete(long)
	p, e := core.parse_path(long)
	defer core.path_destroy(&p)
	testing.expect_value(t, e.kind, core.Path_Error_Kind.Over_Capacity)
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
		{"/0", {core.Either{"0", 0}}},
		{"/12/a", {core.Either{"12", 12}, core.Name("a")}},
		{"/01", {core.Name("01")}},
		{"/-", {core.Name("-")}},
		{"/99999999999999999999", {core.Name("99999999999999999999")}},
	}
	for c in cases {
		p, e := core.parse_pointer(c.text)
		defer core.path_destroy(&p)
		testing.expect_value(t, e.kind, core.Path_Error_Kind.None)
		testing.expect_value(t, len(p.steps), len(c.steps))
		if len(p.steps) != len(c.steps) {
			continue
		}
		for s, i in c.steps {
			testing.expectf(t, p.steps[i] == s, "%q step %d: %v", c.text, i, p.steps[i])
		}
	}
	Refused :: struct {
		text: string,
		at:   u64,
	}
	refused := []Refused{{"a", 0}, {"/a~", 2}, {"/a~2", 2}}
	for c in refused {
		p, e := core.parse_pointer(c.text)
		defer core.path_destroy(&p)
		testing.expectf(t, e.kind == .Bad_Path && e.at == c.at, "%q: %v", c.text, e)
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
	outcome: core.Answer_Outcome,
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
	F :: core.Answer_Outcome.Found
	M :: core.Answer_Outcome.Missing
	T :: core.Answer_Outcome.Type_Mismatch
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
	}
	for c in cases {
		path, perr := core.parse_path(c.path)
		defer core.path_destroy(&path)
		testing.expect_value(t, perr.kind, core.Path_Error_Kind.None)

		doc, err := json.query(transmute([]u8)c.src, .Json, path, read = c.opts)
		defer core.destroy(&doc)
		testing.expectf(t, err.kind == .None, "%q: %v", c.path, err)
		check_answers(t, c, &doc, doc.answers, "scan")

		full, berr := json.build(transmute([]u8)c.src, .Json)
		defer core.destroy(&full)
		testing.expect_value(t, berr.kind, core.Document_Error_Kind.None)
		answers, qerr := json.query_document(&full, path, c.opts)
		defer delete(answers)
		testing.expect_value(t, qerr.kind, core.Path_Error_Kind.None)
		check_answers(t, c, &full, answers, "query")
	}
}

// A partial document's reads: what it kept, what a path looked for, and what nobody asked for.
@(test)
partial_reads :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"keep":1,"a":{"x":[10,20,30],"y":2},"z":3}`)
	path, _ := core.parse_path(".a.x[1]")
	defer core.path_destroy(&path)
	doc, err := json.query(src, .Json, path)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Path_Error_Kind.None)
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
	partial, merr := json.query(src, .Json, miss)
	defer core.destroy(&partial)
	testing.expect_value(t, merr.kind, core.Path_Error_Kind.None)
	owner := partial.answers[0].owner
	_, listed := core.member_of(&partial, owner, "host")
	testing.expect_value(t, listed, core.Presence.Missing)
	_, unlisted := core.member_of(&partial, owner, "y")
	testing.expect_value(t, unlisted, core.Presence.Not_Loaded)

	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	_, _, cerr := core.commit(&list)
	testing.expect_value(t, cerr.kind, core.Document_Error_Kind.Bad_Index)
}

// A member kept by position says nothing of a repeat of its key that a limit cut, and one kept by name does.
@(test)
partial_repeated_keys :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"0":true,"0":null}`)
	cut, _ := core.parse_path("limit(1; .[])")
	defer core.path_destroy(&cut)
	doc, err := json.query(src, .Json, cut)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Path_Error_Kind.None)
	_, last := core.member_of(&doc, core.ROOT, "0")
	testing.expect_value(t, last, core.Presence.Not_Loaded)
	first, at := core.member_of(&doc, core.ROOT, "0", .First)
	testing.expect_value(t, at, core.Presence.Found)
	testing.expect_value(t, string(core.span(&doc, first)), "true")

	pointer, _ := core.parse_pointer("/0")
	defer core.path_destroy(&pointer)
	named, nerr := json.query(transmute([]u8)string(`{"0":1,"0":2,"b":3}`), .Json, pointer)
	defer core.destroy(&named)
	testing.expect_value(t, nerr.kind, core.Path_Error_Kind.None)
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
	doc, err := json.query(src, .Json, path, {tolerate = {.Invalid_Utf8}})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Path_Error_Kind.None)
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
	doc, err := json.query(src, .Json, core.Path{steps = steps[:core.MAX_STEPS]})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Path_Error_Kind.None)
	_, over := json.query(src, .Json, core.Path{steps = steps[:]})
	testing.expect_value(t, over.kind, core.Path_Error_Kind.Over_Capacity)
}

// A stop leaves what follows the answer unread, so a fault there goes unseen, and without the stop it is seen.
@(test)
stop_early_reads :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`{"a":1,"b":[1,2],"c":!`)
	path, _ := core.parse_path(".a")
	defer core.path_destroy(&path)
	doc, err := json.query(src, .Json, path, read = {stop_early = true})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Path_Error_Kind.None)
	testing.expect_value(t, len(doc.answers), 1)
	testing.expect(t, doc.stopped)
	_, rest := core.member_of(&doc, core.ROOT, "b")
	testing.expect_value(t, rest, core.Presence.Not_Loaded)

	_, bad := json.query(src, .Json, path)
	testing.expect_value(t, bad.kind, core.Path_Error_Kind.Walk)

	each, _ := core.parse_path(".a[]")
	defer core.path_destroy(&each)
	late := transmute([]u8)string(`{"a":[1,2],"a":[3]}!`)
	named, nerr := json.query(late, .Json, each, read = {stop_early = true, dups = core.Duplicates.Last})
	defer core.destroy(&named)
	testing.expect_value(t, nerr.kind, core.Path_Error_Kind.None)
	testing.expect_value(t, len(named.answers), 1)

	_, dup := json.query(transmute([]u8)string(`{"a":1,"a":2}`), .Json, path, read = {refuse_duplicates = true})
	testing.expect_value(t, dup.kind, core.Path_Error_Kind.Duplicate_Key)
}

@(test)
path_refusals :: proc(t: ^testing.T) {
	src := transmute([]u8)string(`[1]`)
	for text in ([]string{".[-1]", ".[0:1]", "..", ".a?"}) {
		path, _ := core.parse_path(text)
		defer core.path_destroy(&path)
		_, e := json.query(src, .Json, path)
		testing.expectf(t, e.kind == .Unsupported, "%q: %v", text, e)
	}
	path, _ := core.parse_path(".[0]")
	defer core.path_destroy(&path)
	doc, _ := json.query(src, .Json, path)
	defer core.destroy(&doc)
	_, e := json.query_document(&doc, path)
	testing.expect_value(t, e.kind, core.Path_Error_Kind.Unsupported)
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
		testing.expect_value(t, perr.kind, core.Path_Error_Kind.None)
		doc, answer, err := json.find(src, .Json, path)
		defer core.destroy(&doc)
		testing.expect_value(t, err.kind, core.Path_Error_Kind.None)
		a, some := answer.?
		testing.expect(t, some && a.outcome == .Found)
		testing.expect_value(t, string(core.span(&doc, a.node)), c.want)
	}
}

// An arena that refuses the node bound a kept value's walk reserves by still gets its answer, through the scan's hook.
@(test)
query_kept_value_in_small_arena :: proc(t: ^testing.T) {
	src := strings.concatenate({`{"a":[1,{"b":2}],"pad":"`, strings.repeat("x", 1 << 16, context.temp_allocator), `"}`}, context.temp_allocator)
	path, perr := core.parse_path(".a", context.temp_allocator)
	testing.expect(t, perr.kind == .None)
	buf: [8192]u8
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	doc, err := json.query(transmute([]u8)src, .Json, path, allocator = mem.arena_allocator(&arena))
	testing.expect(t, err.kind == .None)
	testing.expect(t, len(doc.answers) == 1 && doc.answers[0].outcome == .Found)
	testing.expect(t, string(core.span(&doc, doc.answers[0].node)) == `[1,{"b":2}]`)
}
