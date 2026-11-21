package json_tests

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"

Scan_Case :: struct {
	src:     string,
	paths:   [][]tape.Step,
	dups:    tape.Duplicates,
	answers: string, // each answer as `path=value`, a found value as `render_node` writes it, else its outcome
	doc:     string, // the partial document as `render_node` writes it
}

// Writes node `i` of `doc` and its kept subtree, a partial container marked `~`, and returns the node after it.
render_node :: proc(b: ^strings.Builder, doc: ^tape.Document, i: int) -> int {
	n := doc.nodes[i]
	if n.kind <= .Plain {
		text := string(doc.src[n.lo:][:n.n])
		if n.kind == .String && n.spelling & tape.SPELLING_QUOTED != 0 {
			fmt.sbprintf(b, `"%s"`, text)
		} else {
			strings.write_string(b, text)
		}
		return i + 1
	}
	if n.spelling & tape.CONTAINER_PARTIAL != 0 {
		strings.write_byte(b, '~')
	}
	strings.write_byte(b, '[' if n.kind == .Array else '{')
	j := i + 1
	for first := true; j < i + int(n.n); first = false {
		if !first {
			strings.write_byte(b, ',')
		}
		if doc.nodes[j].role == .Key {
			j = render_node(b, doc, j)
			strings.write_byte(b, ':')
		}
		j = render_node(b, doc, j)
	}
	strings.write_byte(b, ']' if n.kind == .Array else '}')
	return j
}

render_answers :: proc(r: ^tape.Partial_Result) -> string {
	b := strings.builder_make(context.temp_allocator)
	for a, i in r.answers {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		fmt.sbprintf(&b, "%d=", a.path)
		if a.outcome == .Found {
			render_node(&b, &r.doc, int(a.node))
		} else {
			fmt.sbprintf(&b, "%v", a.outcome)
		}
	}
	return strings.to_string(b)
}

render_doc :: proc(r: ^tape.Partial_Result) -> string {
	b := strings.builder_make(context.temp_allocator)
	if len(r.doc.nodes) > 0 {
		render_node(&b, &r.doc, 0)
	}
	return strings.to_string(b)
}

// What `scan` keeps and answers with and without `stop_early`, which changes no answer of a text that parses.
expect_scan :: proc(t: ^testing.T, c: Scan_Case, spec := json.Spec.Json, loc := #caller_location) {
	d, derr := tape.demand_of(c.paths)
	testing.expect(t, derr == nil, loc = loc)
	defer tape.destroy(&d)
	for stop in ([]bool{false, true}) {
		r, err := json.scan(transmute([]u8)c.src, &d, spec, {dups = c.dups, stop_early = stop})
		defer tape.destroy(&r)
		answers := render_answers(&r)
		testing.expectf(t, err == nil && answers == c.answers, "%q %v %v stop %v: %q, %v", c.src, c.paths, c.dups, stop, answers, err, loc = loc)
		if !stop {
			doc := render_doc(&r)
			testing.expectf(t, doc == c.doc, "%q %v: doc %q", c.src, c.paths, doc, loc = loc)
		}
	}
}

@(test)
scan_keeps_what_paths_reach :: proc(t: ^testing.T) {
	A :: tape.All{}
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	I :: proc(i: int) -> tape.Step {return tape.Index(i)}
	cases := []Scan_Case {
		{`{"a":{"b":1,"c":2},"d":3}`, {{N("a"), N("b")}}, .Default, `0=1`, `~{"a":~{"b":1}}`},
		{`{"a":{"b":1,"c":2},"d":3}`, {{N("a")}, {N("a"), N("b")}}, .Default, `0={"b":1,"c":2} 1=1`, `~{"a":{"b":1,"c":2}}`},
		{`[{"id":1,"x":0},{"id":2}]`, {{A, N("id")}}, .Default, `0=1 0=2`, `[~{"id":1},{"id":2}]`},
		{`[{"id":1},{"id":2},{"id":3}]`, {{I(-1), N("id")}}, .Default, `0=3`, `~[{"id":3}]`},
		{`[{"id":1},{"id":2},{"id":3}]`, {{I(-2), N("id")}, {I(0), N("id")}}, .Default, `1=1 0=2`, `[{"id":1},{"id":2},{"id":3}]`},
		{`[1,2,3]`, {{I(1)}}, .Default, `0=2`, `~[2]`},
		{`{"a":1}`, {{N("x")}}, .Default, `0=Missing`, `~{}`},
		{`{"a":{"b":1}}`, {{N("a"), I(0)}}, .Default, `0=Wrong_Kind`, `{"a":~{}}`},
		{`[[1],{"b":[2]}]`, {{A, N("b")}}, .Default, `0=Wrong_Kind 0=[2]`, `[~[],{"b":[2]}]`},
		{`{"a":null}`, {{N("a"), N("b")}, {N("a"), A}}, .Default, `0=Missing 1=Wrong_Kind`, `{"a":null}`},
		{`{"a":1,"a":2}`, {{N("a")}}, .Default, `0=2`, `{"a":1,"a":2}`},
		{`{"a":1,"a":2}`, {{N("a")}}, .First, `0=1`, `~{"a":1}`},
		{`[1,2]`, {}, .Default, ``, ``},
		{`[1,2]`, {{}}, .Default, `0=[1,2]`, `[1,2]`},
		// Elements of mixed kinds under `All`, each object opened as the one before it.
		{`[{"a":1},[2],{"a":3},5,{"b":0},{"a":4},{"a":5}]`, {{A, N("a")}}, .Default, `0=1 0=Wrong_Kind 0=3 0=Wrong_Kind 0=Missing 0=4 0=5`, `[{"a":1},~[],{"a":3},5,~{},{"a":4},{"a":5}]`},
		{`[[{"a":1}],[{"a":2},{"b":3}],{"a":6},[{"a":4}]]`, {{A, A, N("a")}}, .Default, `0=1 0=2 0=Missing 0=Wrong_Kind 0=4`, `[[{"a":1}],[{"a":2},~{}],{"a":6},[{"a":4}]]`},
	}
	for c in cases {
		expect_scan(t, c)
	}
}

// A negative index keeps every element it may take, and the answers of those it does not take go, with an `All` or
// a positive index on the same array.
@(test)
scan_takes_back_what_a_negative_index_passes :: proc(t: ^testing.T) {
	A :: tape.All{}
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	I :: proc(i: int) -> tape.Step {return tape.Index(i)}
	src := `[{"a":1,"b":2},{"a":3},{"b":4},{"a":5,"b":6}]`
	cases := []Scan_Case {
		{src, {{I(-1), N("a")}, {A, N("b")}}, .Default, `1=2 1=Missing 1=4 0=5 1=6`, `[{"a":1,"b":2},{"a":3},{"b":4},{"a":5,"b":6}]`},
		{src, {{I(-3), N("a")}, {I(-2), N("a")}}, .Default, `0=3 1=Missing`, `~[{"a":3},~{}]`},
		{src, {{I(-4), N("b")}, {I(0), N("a")}}, .Default, `1=1 0=2`, `[{"a":1,"b":2},~{},{"b":4},~{"b":6}]`},
		{src, {{I(-5), N("a")}}, .Default, `0=Missing`, `~[]`},
		{`[[1,2],[3]]`, {{I(-1), I(-1)}}, .Default, `0=3`, `~[[3]]`},
		{`[]`, {{I(-1)}}, .Default, `0=Missing`, `[]`},
	}
	for c in cases {
		expect_scan(t, c)
	}
}

// A partial container holds its true child count in its `spelling`, and a child kept by position its index. A name
// the container lacks is a missing name, and a stop leaves the open containers partial.
@(test)
scan_records_what_a_partial_document_lacks :: proc(t: ^testing.T) {
	src := `{"x":[10,20,30],"y":{"z":1},"w":2}`
	paths := [][]tape.Step{{tape.Name("x"), tape.Index(2)}, {tape.Name("y"), tape.Name("q")}}
	d, _ := tape.demand_of(paths)
	defer tape.destroy(&d)
	r, err := json.scan(transmute([]u8)src, &d)
	defer tape.destroy(&r)
	testing.expect(t, err == nil)
	testing.expect_value(t, render_doc(&r), `~{"x":~[30],"y":~{}}`)
	testing.expect_value(t, render_answers(&r), `0=30 1=Missing`)
	testing.expect_value(t, len(r.kept), 1)
	testing.expect(t, len(r.kept) == 1 && r.kept[0].index == 2 && r.doc.nodes[r.kept[0].node].lo == 12)
	testing.expect_value(t, len(r.doc.counts), 0)
	testing.expect_value(t, r.doc.nodes[0].spelling, tape.CONTAINER_PARTIAL | 3)
	testing.expect_value(t, len(r.missing), 1)
	if len(r.missing) == 1 {
		m := r.missing[0]
		testing.expect_value(t, string(r.block[m.lo:][:m.n]), "q")
		testing.expect_value(t, r.doc.nodes[m.node].kind, tape.Kind.Object)
	}
	testing.expect(t, r.answers[1].owner == r.missing[0].node)
	testing.expect(t, .Partial in r.doc.flags && .Stopped not_in r.doc.flags)

	first, _ := tape.demand_of([][]tape.Step{{tape.Name("x"), tape.Index(0)}})
	defer tape.destroy(&first)
	s, serr := json.scan(transmute([]u8)src, &first, read = {dups = .First, stop_early = true})
	defer tape.destroy(&s)
	testing.expect(t, serr == nil && .Stopped in s.doc.flags)
	testing.expect_value(t, render_doc(&s), `~{"x":~[10]}`)
	testing.expect_value(t, render_answers(&s), `0=10`)
	testing.expect_value(t, s.doc.root_close, 0)
}

// Any number of paths, keys that need decoding, comments and a path through deep containers.
@(test)
scan_takes_any_paths :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	paths := make([][]tape.Step, 200, context.temp_allocator)
	want := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 200 {
		fmt.sbprintf(&b, `%s"k%d":%d`, "," if i > 0 else "", i, i)
		paths[199 - i] = make([]tape.Step, 1, context.temp_allocator)
		paths[199 - i][0] = tape.Name(fmt.tprintf("k%d", i))
	}
	strings.write_byte(&b, '}')
	for i in 0 ..< 200 {
		fmt.sbprintf(&want, "%s%d=%d", " " if i > 0 else "", 199 - i, i)
	}
	expect_scan(t, {strings.to_string(b), paths, .Default, strings.to_string(want), strings.to_string(b)})

	expect_scan(t, {`{"a":1,"b\n":[2]}`, {{tape.Name("a")}, {tape.Name("b\n"), tape.Index(0)}}, .Default, `0=1 1=2`, `{"a":1,"b\n":[2]}`})
	expect_scan(t, {`/* c */ {"a": [1, /* d */ 2,], // e
"b": 3}`, {{tape.Name("a"), tape.Index(1)}}, .Default, `0=2`, `~{"a":~[2]}`}, .Jsonc)

	deep := strings.builder_make(context.temp_allocator)
	steps := make([]tape.Step, 1500, context.temp_allocator)
	for i in 0 ..< 1500 {
		strings.write_string(&deep, `{"a":0,"n":`)
		steps[i] = tape.Name("n")
	}
	strings.write_string(&deep, "7")
	for _ in 0 ..< 1500 {
		strings.write_byte(&deep, '}')
	}
	d, _ := tape.demand_of([][]tape.Step{steps})
	defer tape.destroy(&d)
	r, err := json.scan(transmute([]u8)strings.to_string(deep), &d)
	defer tape.destroy(&r)
	testing.expect(t, err == nil && len(r.answers) == 1 && r.answers[0].outcome == .Found)
	testing.expect_value(t, len(r.doc.nodes), 2 * 1500 + 1)
}

// A container of more children than a node's `spelling` holds keeps its true count, kept whole or partial, and a
// replayed element that ends the read leaves its array partial with its true count.
@(test)
scan_counts_wide_containers :: proc(t: ^testing.T) {
	N :: 70_000
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"a":[`)
	for i in 0 ..< N {
		fmt.sbprintf(&b, "%s%d", "," if i > 0 else "", i)
	}
	strings.write_string(&b, `],"b":[`)
	for i in 0 ..< N {
		fmt.sbprintf(&b, "%s%d", "," if i > 0 else "", i)
	}
	strings.write_string(&b, `]}`)
	src := transmute([]u8)strings.to_string(b)
	paths := [][]tape.Step{{tape.Name("a")}, {tape.Name("b"), tape.Index(5)}}
	d, _ := tape.demand_of(paths)
	defer tape.destroy(&d)
	r, err := json.scan(src, &d)
	defer tape.destroy(&r)
	testing.expect(t, err == nil)
	answers := render_answers(&r)
	testing.expect_value(t, answers[len(answers) - 3:], `1=5`)
	counts := make(map[tape.Node_Index]u32, context.temp_allocator)
	for c, i in r.doc.counts {
		counts[c.node] = c.count
		testing.expect(t, i == 0 || r.doc.counts[i - 1].node < c.node)
	}
	a := r.answers[0].node
	testing.expect_value(t, r.doc.nodes[a].spelling, tape.MAX_CHILDREN)
	testing.expect_value(t, counts[a], N)
	bn := r.answers[1].owner
	testing.expect_value(t, r.doc.nodes[bn].spelling, tape.CONTAINER_PARTIAL | tape.MAX_CHILDREN)
	testing.expect_value(t, counts[bn], N)
	testing.expect_value(t, len(r.doc.counts), 2)

	last, _ := tape.demand_of([][]tape.Step{{tape.Name("a"), tape.Index(-1)}})
	defer tape.destroy(&last)
	s, serr := json.scan(src, &last, read = {dups = .First, stop_early = true})
	defer tape.destroy(&s)
	testing.expect(t, serr == nil && .Stopped in s.doc.flags)
	testing.expect_value(t, render_answers(&s), `0=69999`)
	testing.expect_value(t, render_doc(&s), `~{"a":~[69999]}`)
	testing.expect(t, len(s.doc.counts) == 1 && s.doc.counts[0].count == N)
	testing.expect_value(t, s.doc.nodes[0].spelling, tape.CONTAINER_PARTIAL | 1)
}

// An allocator that refuses every allocation after its first `left`, and counts the blocks it gave that are live.
Failing :: struct {
	backing: runtime.Allocator,
	left:    int,
	live:    int,
}

failing_allocator :: proc(f: ^Failing) -> runtime.Allocator {
	return {data = f, procedure = proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
		f := (^Failing)(data)
		switch mode {
		case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
			if f.left == 0 {
				return nil, .Out_Of_Memory
			}
			f.left -= 1
			fresh := old_memory == nil || mode == .Alloc || mode == .Alloc_Non_Zeroed
			r, err := f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, loc)
			if err == nil && fresh {
				f.live += 1
			}
			return r, err
		case .Free:
			if old_memory != nil {
				f.live -= 1
			}
		case .Free_All:
			return nil, .Mode_Not_Implemented
		case .Query_Features, .Query_Info:
		}
		return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, loc)
	}}
}

// A refused allocation anywhere in `demand_of` or `scan` is its error, with nothing left allocated, over a demand past
// the room's marks, lists past the room, a node room that grows, a replaying array and the ring of an array a negative
// index keeps.
@(test)
scan_frees_what_a_refused_allocation_leaves :: proc(t: ^testing.T) {
	src := strings.builder_make(context.temp_allocator)
	strings.write_string(&src, `{"r":[`)
	for i in 0 ..< 24 {
		strings.write_string(&src, "," if i > 0 else "")
		strings.write_byte(&src, '{')
		for k in 0 ..< 36 {
			fmt.sbprintf(&src, `%s"k%d":%d`, "," if k > 0 else "", k, i)
		}
		strings.write_byte(&src, '}')
	}
	strings.write_string(&src, `],"q":[{"id":1},{"id":2},{"id":3}]}`)
	text := transmute([]u8)strings.to_string(src)
	paths := make([dynamic][]tape.Step, context.temp_allocator)
	for k in 0 ..< 36 {
		append(&paths, []tape.Step{tape.Name("r"), tape.All{}, tape.Name(fmt.tprintf("k%d", k))})
	}
	append(&paths, []tape.Step{tape.Name("r"), tape.Index(-1), tape.Name("k0")})
	append(&paths, []tape.Step{tape.Name("r"), tape.All{}, tape.Name("none")})
	append(&paths, []tape.Step{tape.Name("q"), tape.Index(-2), tape.Name("id")})

	d, _ := tape.demand_of(paths[:])
	want, _ := json.scan(text, &d)
	want_answers := render_answers(&want)
	tape.destroy(&want)
	tape.destroy(&d)

	for left := 0; ; left += 1 {
		f := Failing{backing = context.allocator, left = left}
		allocator := failing_allocator(&f)
		fd, derr := tape.demand_of(paths[:], allocator)
		r: tape.Partial_Result
		err := tape.Error(derr) if derr != nil else nil
		if derr == nil {
			r, err = json.scan(text, &fd, allocator = allocator)
			if err == nil {
				testing.expect_value(t, render_answers(&r), want_answers)
				tape.destroy(&r)
			}
			tape.destroy(&fd)
		}
		testing.expectf(t, f.live == 0, "%d blocks live after %d allocations", f.live, left)
		if err == nil {
			testing.expect(t, left > 8)
			break
		}
		testing.expectf(t, err == runtime.Allocator_Error.Out_Of_Memory, "%d allocations: %v", left, err)
		if left > 10_000 || f.live != 0 {
			break
		}
	}
}

// A container kept whole in a spec with comments keeps its values and no comment, as the rest of a partial document.
@(test)
scan_keeps_values_of_every_spec :: proc(t: ^testing.T) {
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	I :: proc(i: int) -> tape.Step {return tape.Index(i)}
	expect_scan(t, {`{"a":[1,/*c*/2],"b":0}`, {{N("a")}}, .Default, `0=[1,2]`, `~{"a":[1,2]}`}, .Jsonc)
	expect_scan(t, {"{a:[1, // c\n 2,], b:0}", {{N("a")}}, .Default, `0=[1,2]`, `~{a:[1,2]}`}, .Json5)
	expect_scan(t, {`{a:1, 'b':+2, c:[.5,],}`, {{N("b")}, {N("c"), I(0)}}, .Default, `0=+2 1=.5`, `~{"b":+2,c:[.5]}`}, .Json5)
}

// An index past any array reads as missing, and containers kept whole past the walk's first levels grow the stacks
// once.
@(test)
path_reads_take_any_index_and_depth :: proc(t: ^testing.T) {
	far := tape.Index(min(int))
	expect_scan(t, {`[1,2]`, {{far}}, .Default, `0=Missing`, `~[]`})
	expect_scan(t, {`[{"a":1}]`, {{far, tape.Name("a")}}, .Default, `0=Missing`, `~[]`})
	for steps in ([][]tape.Step{{far}, {far, tape.Name("a")}}) {
		a, err := json.find(transmute([]u8)string(`[{"a":1},2]`), steps)
		testing.expectf(t, err == nil && a.outcome == .Missing, "%v: %v %v", steps, a, err)
	}

	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for i in 0 ..< 4 {
		strings.write_string(&b, "," if i > 0 else "")
		for _ in 0 ..< 1500 {
			strings.write_byte(&b, '[')
		}
		for _ in 0 ..< 1500 {
			strings.write_byte(&b, ']')
		}
	}
	strings.write_byte(&b, ']')
	d, _ := tape.demand_of([][]tape.Step{{tape.All{}}})
	defer tape.destroy(&d)
	r, err := json.scan(transmute([]u8)strings.to_string(b), &d)
	defer tape.destroy(&r)
	testing.expect(t, err == nil && len(r.answers) == 4)
	testing.expect_value(t, len(r.doc.nodes), 1 + 4 * 1500)
}
