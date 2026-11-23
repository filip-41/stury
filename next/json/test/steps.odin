package json_tests

import "base:intrinsics"
import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"
import "stury:testkit"

// A walk of a test format, whose tokens a test gives in document order, each container closed by its `End`, for the
// hook `h` from registers `regs`. It answers a hook's actions as a format's walk does.
@(private = "file")
token_walk :: proc(tokens: []tape.Token, h: ^$H, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) {
	end_of :: proc(tokens: []tape.Token, at: int) -> int {
		depth := 0
		for i in at ..< len(tokens) {
			if tokens[i].kind == .End {
				depth -= 1
			} else if tokens[i].kind > .Plain {
				depth += 1
			}
			if depth == 0 {
				return i
			}
		}
		return len(tokens) - 1
	}
	// A hook with `.Rooms` is given a node only while its room has place for it.
	room :: proc(h: ^$T, regs: ^hook.Regs, t: tape.Token) {
		C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(T, hook.PROTOCOL_FIELD), 0)
		when .Rooms in C {
			if t.kind != .End && t.role <= .Key && uintptr(regs.a) == hook.rooms_end(h) {
				grown := hook.rooms_grow(h, regs, t.lo)
				assert(grown)
			}
		}
	}
	for i := 0; i < len(tokens); {
		t := tokens[i]
		a: hook.Action
		room(h, regs, t)
		regs^, a = on(h, regs^, t)
		container := t.kind > .Plain && t.kind != .End
		switch a {
		case .Next, .Grow:
			i += 1
		case .Skip:
			i = end_of(tokens, i) if container else i + 1
		case .Keep, .Keep_Stubs:
			P :: intrinsics.type_field_type(H, hook.PROTOCOL_FIELD)
			when .Keeps in intrinsics.type_polymorphic_record_parameter_value(P, 0) {
				end := end_of(tokens, i)
				K :: intrinsics.type_polymorphic_record_parameter_value(P, 3)
				inner := (^intrinsics.type_polymorphic_record_parameter_value(K, 0))(hook.keeps_inner(h))
				for j in i ..= end {
					room(inner, regs, tokens[j])
					if a == .Keep {
						regs^, _ = hook.keeps_give(h, regs^, tokens[j], false)
					} else {
						regs^, _ = hook.keeps_give(h, regs^, tokens[j], true)
					}
				}
				i = end
			}
		case .Rest, .Stop:
			return
		}
	}
}

// The tokens of `{ab: 1, 12: 2, "12": 3, x: [5, 6]}` in a format whose keys are scalars of any kind: `ab` and `x`
// plain, `12` a number and `"12"` a string.
@(private = "file")
KEYED_SRC :: `{ab: 1, 12: 2, "12": 3, x: [5, 6]}`

@(private = "file")
keyed_tokens :: proc() -> []tape.Token {
	one := tape.number_spelling(0, 1, 0)
	tokens := [?]tape.Token {
		{lo = 0, n = 1, kind = .Object},
		{lo = 1, n = 2, kind = .Plain, role = .Key},
		{lo = 5, n = 1, kind = .Number, spelling = one},
		{lo = 8, n = 2, kind = .Number, role = .Key, spelling = tape.number_spelling(0, 2, 0)},
		{lo = 12, n = 1, kind = .Number, spelling = one},
		{lo = 16, n = 2, kind = .String, role = .Key, spelling = tape.SPELLING_QUOTED},
		{lo = 21, n = 1, kind = .Number, spelling = one},
		{lo = 24, n = 1, kind = .Plain, role = .Key},
		{lo = 27, n = 1, kind = .Array},
		{lo = 28, n = 1, kind = .Number, spelling = one},
		{lo = 31, n = 1, kind = .Number, spelling = one},
		{lo = 32, n = 1, kind = .End},
		{lo = 33, n = 1, kind = .End},
	}
	return slice_clone(tokens[:])
}

@(private = "file")
slice_clone :: proc(s: []tape.Token) -> []tape.Token {
	out := make([]tape.Token, len(s), context.temp_allocator)
	copy(out, s)
	return out
}

// A format like JSON whose values cannot be walked again alone.
@(private = "file")
test_format :: proc() -> tape.Format {
	f := json.as(.Json)^
	f.name, f.caps = "test", {}
	return f
}

@(private = "file")
token_build :: proc(src: []u8, format: ^tape.Format, tokens: []tape.Token) -> tape.Document {
	frames: [64]u64
	b: build.Builder
	build.builder_start(&b, src, format, len(tokens), len(tokens), frames[:], context.allocator)
	regs := build.builder_regs(&b)
	token_walk(tokens, &b, &regs, build.builder_hook_kept)
	doc, _ := build.builder_end(&b, regs, u64(len(src)), nil)
	return doc
}

@(private = "file")
token_scan :: proc(src: []u8, format: ^tape.Format, tokens: []tape.Token, d: ^tape.Demand, read: tape.Read_Options) -> (tape.Document, tape.Error) {
	no_rewalk :: proc "contextless" (h: ^build.Scanner, s: ^hook.Regs, lo: u64) -> hook.Walk_Result {
		return hook.walk_result(lo, hook.WALK_NO_MEMORY)
	}
	frames: [64]u64
	room: build.Scan_Room
	h: build.Scanner
	if err := build.scanner_start(&h, src, format, d, read, no_rewalk, 16, 1024, frames[:], &room, context.allocator); err != nil {
		return {}, err
	}
	regs := build.builder_regs(&h.b)
	token_walk(tokens, &h, &regs, build.scanner_hook)
	return build.scanner_end(&h, regs, u64(len(src)), nil)
}

@(private = "file")
token_find :: proc(src: []u8, format: ^tape.Format, tokens: []tape.Token, steps: []tape.Step, read: tape.Read_Options) -> tape.Span_Answer {
	respell :: proc "contextless" (src: []u8, lo, hi: u64) -> u16 {
		return tape.number_spelling(0, hi - lo, 0)
	}
	no_rewalk :: proc "contextless" (h: ^build.Finder, lo: u64) -> hook.Walk_Result {
		return hook.walk_result(lo, hook.WALK_NO_MEMORY)
	}
	room: build.Find_Room
	f: build.Finder
	_ = build.finder_start(&f, src, format, steps, read, respell, no_rewalk, &room, context.allocator)
	defer build.finder_end(&f)
	regs: hook.Regs
	token_walk(tokens, &f, &regs, build.finder_hook)
	return build.finder_answer(&f)
}

// The text of answer `k` of path `path`, or its outcome.
@(private = "file")
answer_text :: proc(doc: ^tape.Document, path, k: int) -> string {
	node, p, ok := tape.answer({doc = doc}, path, k)
	if !ok {
		return "none"
	}
	if p != .Found {
		return "missing" if p == .Missing else "wrong kind"
	}
	b := strings.builder_make(context.temp_allocator)
	render_node(&b, doc, int(node))
	return strings.to_string(b)
}

// A `Name` takes a key of any scalar kind by its text, while kind stays part of a key, so `12` and `"12"` are two keys
// that both read as `12`. Scan and find read the same over a format that cannot walk a value again.
@(test)
names_take_keys_of_every_kind :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := transmute([]u8)string(KEYED_SRC)
	format := test_format()
	tokens := keyed_tokens()
	doc := token_build(src, &format, tokens)
	defer tape.destroy(&doc)
	r := tape.Reader{&doc, nil}
	ab, abp := tape.member(r, tape.ROOT, "ab")
	testing.expect(t, abp == .Found && doc.nodes[ab].lo == 5)
	last, _ := tape.member(r, tape.ROOT, "12", .Last)
	first, _ := tape.member(r, tape.ROOT, "12", .First)
	testing.expect(t, doc.nodes[last].lo == 21 && doc.nodes[first].lo == 12)
	n, np, _ := tape.length(r, tape.ROOT, context.temp_allocator)
	testing.expect_value(t, n, 4)
	testing.expect_value(t, np, tape.Presence.Found)
	group, gp := tape.named(r, tape.ROOT, "12")
	testing.expect_value(t, gp, tape.Presence.Found)
	los := make([dynamic]u64, context.temp_allocator)
	for {
		_, value, p := tape.next_child(r, &group)
		if p != .Found {
			break
		}
		append(&los, doc.nodes[value].lo)
	}
	testing.expect(t, len(los) == 2 && los[0] == 12 && los[1] == 21)
	text, ok := tape.node_text(&doc, doc.nodes[1], nil)
	testing.expect(t, ok && text == "ab")

	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	paths := [][]tape.Step{{N("ab")}, {N("12")}, {N("x"), tape.Index(-1)}, {N("x"), tape.Slice{-2, -1, 0}}}
	d, _ := tape.demand_of(paths)
	defer tape.destroy(&d)
	for stop in ([]bool{false, true}) {
		s, err := token_scan(src, &format, tokens, &d, {dups = .First, stop_early = stop})
		defer tape.destroy(&s)
		testing.expect(t, err == nil)
		testing.expect_value(t, answer_text(&s, 0, 0), "1")
		testing.expect_value(t, answer_text(&s, 1, 0), "2")
		testing.expect_value(t, answer_text(&s, 2, 0), "6")
		testing.expect_value(t, answer_text(&s, 3, 0), "5")
		// The element no step from the end took is not kept.
		x, _ := tape.member({doc = &s}, tape.ROOT, "x", .First)
		testing.expect_value(t, tape.Node_Index(s.nodes[x].n), 3)
	}
	for c in ([]struct {
			steps: []tape.Step,
			dups:  tape.Duplicates,
			text:  string,
		}{{{N("ab")}, .Last, "1"}, {{N("12")}, .First, "2"}, {{N("12")}, .Last, "3"}, {{N("x"), tape.Index(-2)}, .Last, "5"}}) {
		for stop in ([]bool{false, true}) {
			a := token_find(src, &format, tokens, c.steps, {dups = c.dups, stop_early = stop})
			testing.expectf(t, a.outcome == .Found && string(src[a.lo:a.hi]) == c.text, "%v %v: %v", c.steps, c.dups, a)
		}
	}
}

// A scan's answers are in document order, the order of its nodes, though a format's text may hold a later value
// before an earlier one, as a YAML alias or HTML's foster parenting does.
@(test)
scan_answers_by_node :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := transmute([]u8)string(`[ 7 , 9 ]`)
	one := tape.number_spelling(0, 1, 0)
	tokens := []tape.Token{{lo = 0, n = 1, kind = .Array}, {lo = 6, n = 1, kind = .Number, spelling = one}, {lo = 2, n = 1, kind = .Number, spelling = one}, {lo = 8, n = 1, kind = .End}}
	format := test_format()
	d, _ := tape.demand_of([][]tape.Step{{tape.All{}}, {tape.Index(1)}})
	defer tape.destroy(&d)
	s, err := token_scan(src, &format, tokens, &d, {})
	defer tape.destroy(&s)
	testing.expect(t, err == nil)
	testing.expect_value(t, answer_text(&s, 0, 0), "9")
	testing.expect_value(t, answer_text(&s, 0, 1), "7")
	testing.expect_value(t, answer_text(&s, 1, 0), "7")
}

// A path's limit keeps its first answers in document order, as jq's `first(f)` and `limit(n; f)` read, across nested
// steps, which a step's own limit cannot. With `stop_early` the walk ends once every path is settled.
@(test)
scan_keeps_a_paths_first_answers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	A :: tape.All{}
	Case :: struct {
		src:     string,
		steps:   []tape.Step,
		limit:   int,
		dups:    tape.Duplicates,
		answers: []string,
		stopped: bool, // with `stop_early`, the walk stops
	}
	cases := []Case {
		{`{"a":[{"b":[]},{"b":[7]},{"b":[8,9]}]}`, {N("a"), A, N("b"), A}, 1, .Default, {"7"}, true},
		{`{"a":[{"b":[]},{"b":[7]},{"b":[8,9]}]}`, {N("a"), A, N("b"), A}, 2, .Default, {"7", "8"}, true},
		{`{"a":[{"b":[]},{"b":[7]},{"b":[8,9]}]}`, {N("a"), A, N("b"), A}, 9, .Default, {"7", "8", "9"}, false},
		// Under `.Last` a later member takes back an answer, so the path settles only at its object's close.
		{`{"a":1,"a":2,"b":3}`, {N("a")}, 1, .Last, {"2"}, true},
		{`[{"a":1,"a":2},{"a":3}]`, {A, N("a")}, 1, .Last, {"2"}, true},
		{`[{"a":1,"a":2},{"a":3}]`, {A, N("a")}, 2, .Group, {"1", "2"}, true},
		// A step from the end takes back what an element it passes gave, so the limit counts only what stays.
		{`[[1],[2],[3]]`, {tape.Index(-2), A}, 1, .First, {"2"}, false},
		{`[1,2,3,4]`, {tape.Slice{-3, nil, 0}}, 2, .First, {"2", "3"}, false},
	}
	for c in cases {
		d, _ := tape.demand_of([][]tape.Step{c.steps}, nil, []int{c.limit})
		defer tape.destroy(&d)
		for stop in ([]bool{false, true}) {
			s, err := json.scan(transmute([]u8)c.src, &d, .Json, {dups = c.dups, stop_early = stop})
			defer tape.destroy(&s)
			got := make([dynamic]string, context.temp_allocator)
			for k := 0; ; k += 1 {
				text := answer_text(&s, 0, k)
				if text == "none" {
					break
				}
				append(&got, text)
			}
			ok := err == nil && len(got) == len(c.answers) && (!stop || !c.stopped || .Stopped in s.flags)
			for a, i in c.answers {
				ok &&= i < len(got) && got[i] == a
			}
			testing.expectf(t, ok, "%s %v limit %d %v stop %v: %v %v %v", c.src, c.steps, c.limit, c.dups, stop, got[:], s.flags, err)
		}
	}
}

// Under `.Group` a `Name` takes every member of its key in document order, a find the first that gives an answer.
@(test)
group_takes_every_member_of_a_key :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	src := transmute([]u8)string(`{"a":1,"b":2,"a":{"x":3},"a":{"x":4}}`)
	d, _ := tape.demand_of([][]tape.Step{{N("a")}, {N("a"), N("x")}})
	defer tape.destroy(&d)
	for stop in ([]bool{false, true}) {
		s, err := json.scan(src, &d, .Json, {dups = .Group, stop_early = stop})
		defer tape.destroy(&s)
		testing.expect(t, err == nil)
		testing.expect_value(t, answer_text(&s, 0, 0), "1")
		testing.expect_value(t, answer_text(&s, 0, 2), `{"x":4}`)
		testing.expect_value(t, answer_text(&s, 1, 0), "wrong kind")
		testing.expect_value(t, answer_text(&s, 1, 1), "3")
		testing.expect_value(t, answer_text(&s, 1, 2), "4")
		a, _ := json.find(src, {N("a"), N("x")}, .Json, {dups = .Group, stop_early = stop})
		testing.expect_value(t, a.outcome, tape.Presence.Wrong_Kind)
		b, _ := json.find(src, {N("a"), tape.All{}}, .Json, {dups = .Group, stop_early = stop})
		testing.expect(t, b.outcome == .Wrong_Kind)
	}
	doc, _ := json.build(src)
	defer tape.destroy(&doc)
	c, p := tape.named({doc = &doc}, tape.ROOT, "a")
	n := 0
	for p == .Found {
		_, _, vp := tape.next_child({doc = &doc}, &c)
		if vp != .Found {
			break
		}
		n += 1
	}
	testing.expect_value(t, n, 3)
	_, missing := tape.named({doc = &doc}, tape.ROOT, "zz")
	testing.expect_value(t, missing, tape.Presence.Missing)
}

// A build keeps every member of a repeated key by default, one under `.First` or `.Last` with its value's nodes and
// facts gone, and fails at the second key under `.Refuse`.
@(test)
build_takes_repeated_keys_by_policy :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := `{"a":1, /* one */ "b":[2,{"a":0,"a":5}], "a":{"c":3} /* two */, "a":4}`
	Case :: struct {
		dups: tape.Duplicates,
		doc:  string,
	}
	for c in ([]Case{{.Default, `{"a":1,"b":[2,{"a":0,"a":5}],"a":{"c":3},"a":4}`}, {.All, `{"a":1,"b":[2,{"a":0,"a":5}],"a":{"c":3},"a":4}`}, {.Group, `{"a":1,"b":[2,{"a":0,"a":5}],"a":{"c":3},"a":4}`}, {.First, `{"a":1,"b":[2,{"a":0}]}`}, {.Last, `{"b":[2,{"a":5}],"a":4}`}}) {
		doc, err := json.build(transmute([]u8)src, .Jsonc, {dups = c.dups})
		defer tape.destroy(&doc)
		testing.expectf(t, err == nil && render_doc(&doc) == c.doc, "%v: %s %v", c.dups, render_doc(&doc), err)
		n, _, _ := tape.length({doc = &doc}, tape.ROOT, context.temp_allocator)
		testing.expect_value(t, n, 2)
		// Each comment stays with its value, and goes with it.
		comments := 0
		for f in doc.facts {
			testing.expect(t, int(f.node) < len(doc.nodes))
			comments += 1
		}
		testing.expectf(t, comments == (1 if c.dups == .First else 0 if c.dups == .Last else 2), "%v: %v", c.dups, doc.facts)
	}
	_, err := json.build(transmute([]u8)src, .Jsonc, {dups = .Refuse})
	kind, at := fault_of(err)
	testing.expect_value(t, kind, tape.Fault_Kind.Duplicate_Key)
	testing.expect_value(t, at, u64(strings.index(src, `"a":5`)))
	once, ok := json.build(transmute([]u8)string(`{"a":1,"b":{"a":2}}`), .Json, {dups = .Refuse})
	defer tape.destroy(&once)
	testing.expect(t, ok == nil)
}

// A scan whose demand asks for facts keeps the comments of the nodes it keeps, as a build gives them.
@(test)
scan_keeps_facts_of_kept_nodes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	src := transmute([]u8)string("// head\n{\"a\": /* before a */ 1, // after a\n \"b\": [1, /* in b */ 2], /* before c */ \"c\": {\"x\": 1 /* x */}, \"d\": 4 // after d\n /* foot */}")
	doc, _ := json.build(src, .Jsonc)
	defer tape.destroy(&doc)
	for paths in ([][][]tape.Step{{{N("a")}}, {{N("c")}}, {{N("b"), tape.Index(1)}}, {{N("d")}}, {{N("a")}, {N("c"), N("x")}}, {{}}}) {
		d, _ := tape.demand_of(paths, nil, nil, true)
		defer tape.destroy(&d)
		for stop in ([]bool{false, true}) {
			s, err := json.scan(src, &d, .Jsonc, {stop_early = stop})
			defer tape.destroy(&s)
			testing.expect(t, err == nil)
			agree_facts(t, &doc, &s, string(src))
		}
	}
	d, _ := tape.demand_of([][]tape.Step{{N("a")}}, nil, nil, true)
	defer tape.destroy(&d)
	s, _ := json.scan(src, &d, .Jsonc)
	defer tape.destroy(&s)
	testing.expect_value(t, len(s.facts), 4)
	plain, _ := tape.demand_of([][]tape.Step{{N("a")}})
	defer tape.destroy(&plain)
	p, _ := json.scan(src, &plain, .Jsonc)
	defer tape.destroy(&p)
	testing.expect_value(t, len(p.facts), 0)
}

// An escaped key and its plain spelling are one key by one relation, the format's `key_hash` with `same_keys`, in a
// small object and a wide one, read with and without an index, and in a build's policy.
@(test)
escaped_keys_are_one_key_on_every_route :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	f := json.as(.Json)
	escaped := transmute([]u8)string(`"\u0062"`)
	testing.expect_value(t, f.key_hash(escaped, {lo = 1, n = 6, kind = .String, spelling = tape.SPELLING_DECODE}),
		tape.text_hash(transmute([]u8)string("b")))
	for fill in ([]int{0, 12}) {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"b":1`)
		for i in 0 ..< fill {
			fmt.sbprintf(&b, `,"p%d":0`, i)
		}
		strings.write_string(&b, `,"\u0062":2}`)
		src := transmute([]u8)strings.to_string(b)
		doc, err := json.build(src)
		defer tape.destroy(&doc)
		testing.expect(t, err == nil)
		x := tape.index_of(&doc, context.allocator)
		defer tape.destroy_index(&x)
		for r in ([]tape.Reader{{&doc, nil}, {&doc, &x}}) {
			n, _, _ := tape.length(r, tape.ROOT, context.temp_allocator)
			testing.expectf(t, n == fill + 1, "%d members, index %v: length %d", fill, r.index != nil, n)
			for dups in ([]tape.Duplicates{.First, .Last}) {
				value, p := tape.member(r, tape.ROOT, "b", dups)
				want := "1" if dups == .First else "2"
				got := string(doc.src[doc.nodes[value].lo:][:doc.nodes[value].n]) if p == .Found else ""
				testing.expectf(t, got == want, "%d members, index %v, %v: %q", fill, r.index != nil, dups, got)
			}
		}
		for dups in ([]tape.Duplicates{.First, .Last}) {
			once, berr := json.build(src, .Json, {dups = dups})
			defer tape.destroy(&once)
			n, _, _ := tape.length({doc = &once}, tape.ROOT, context.temp_allocator)
			testing.expectf(t, berr == nil && n == fill + 1 && len(once.nodes) == 2 * fill + 3, "%d members, %v: %s",
				fill, dups, render_doc(&once))
		}
		_, rerr := json.build(src, .Json, {dups = .Refuse})
		kind, at := fault_of(rerr)
		testing.expectf(t, kind == .Duplicate_Key && at == u64(strings.index(string(src), `"\u0062"`)), "%d members: %v",
			fill, rerr)
	}
}

// The children of a partial array read past one it did not keep, each in its place.
@(test)
children_read_past_a_hole :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	d, _ := tape.demand_of([][]tape.Step{{tape.Index(0)}, {tape.Index(2)}})
	defer tape.destroy(&d)
	s, err := json.scan(transmute([]u8)string(`[10,20,30]`), &d)
	defer tape.destroy(&s)
	testing.expect(t, err == nil)
	c, _, _ := tape.children({doc = &s}, tape.ROOT, context.temp_allocator)
	defer tape.destroy_children(&c)
	want := []string{"10", "", "30"}
	for w in want {
		_, value, p := tape.next_child({doc = &s}, &c)
		got := string(s.src[s.nodes[value].lo:][:s.nodes[value].n]) if p == .Found else ""
		testing.expectf(t, p == (.Found if w != "" else .Not_Loaded) && got == w, "%v %q, want %q", p, got, w)
	}
	_, _, p := tape.next_child({doc = &s}, &c)
	testing.expect_value(t, p, tape.Presence.Missing)
}
