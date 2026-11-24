package json_tests

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

Scan_Case :: struct {
	src:     string,
	paths:   [][]tape.Step,
	dups:    tape.Duplicates,
	answers: string, // each answer as `path=value` by path, a found value as `testkit.render_node` writes it, else its outcome
	doc:     string, // the partial document as `testkit.render_node` writes it
}

// Checks what `scan` keeps and answers with and without `stop_early`, which changes no answer for a text that parses.
// A stopped scan keeps the document `doc` gives, or `stopped` where the read ends before its text does.
expect_scan :: proc(t: ^testing.T, c: Scan_Case, spec := json.Spec.Json, grains: []tape.Grain = nil, stopped := "", loc := #caller_location) {
	d, derr := tape.demand_of(c.paths, grains)
	testing.expect(t, derr == nil, loc = loc)
	defer tape.destroy(&d)
	for stop in ([]bool{false, true}) {
		r, err := json.scan(transmute([]u8)c.src, &d, spec, {stop_early = stop}, {dups = c.dups})
		defer tape.destroy(&r)
		answers := testkit.render_answers(&r)
		testing.expectf(t, err == nil && answers == c.answers, "%q %v %v stop %v: %q, %v", c.src, c.paths, c.dups, stop, answers, err, loc = loc)
		doc := testkit.render_doc(&r)
		want := c.doc if !stop || stopped == "" else stopped
		testing.expectf(t, doc == want, "%q %v stop %v: doc %q, want %q", c.src, c.paths, stop, doc, want, loc = loc)
	}
}

@(test)
scan_keeps_what_paths_reach :: proc(t: ^testing.T) {
	testkit.deadline(t)
	A :: tape.All{}
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	I :: proc(i: int) -> tape.Step {return tape.Index(i)}
	cases := []Scan_Case {
		{`{"a":{"b":1,"c":2},"d":3}`, {{N("a"), N("b")}}, .Default, `0=1`, `~{"a":~{"b":1}}`},
		{`{"a":{"b":1,"c":2},"d":3}`, {{N("a")}, {N("a"), N("b")}}, .Default, `0={"b":1,"c":2} 1=1`, `~{"a":{"b":1,"c":2}}`},
		{`[{"id":1,"x":0},{"id":2}]`, {{A, N("id")}}, .Default, `0=1 0=2`, `[~{"id":1},{"id":2}]`},
		{`[{"id":1},{"id":2},{"id":3}]`, {{I(-1), N("id")}}, .Default, `0=3`, `~[{"id":3}]`},
		{`[{"id":1},{"id":2},{"id":3}]`, {{I(-2), N("id")}, {I(0), N("id")}}, .Default, `0=2 1=1`, `[{"id":1},{"id":2},{"id":3}]`},
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
	testkit.deadline(t)
	A :: tape.All{}
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	I :: proc(i: int) -> tape.Step {return tape.Index(i)}
	src := `[{"a":1,"b":2},{"a":3},{"b":4},{"a":5,"b":6}]`
	cases := []Scan_Case {
		{src, {{I(-1), N("a")}, {A, N("b")}}, .Default, `0=5 1=2 1=Missing 1=4 1=6`, `[{"a":1,"b":2},{"a":3},{"b":4},{"a":5,"b":6}]`},
		{src, {{I(-3), N("a")}, {I(-2), N("a")}}, .Default, `0=3 1=Missing`, `~[{"a":3},~{}]`},
		{src, {{I(-4), N("b")}, {I(0), N("a")}}, .Default, `0=2 1=1`, `[{"a":1,"b":2},~{},{"b":4},~{"b":6}]`},
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
	testkit.deadline(t)
	src := `{"x":[10,20,30],"y":{"z":1},"w":2}`
	paths := [][]tape.Step{{tape.Name("x"), tape.Index(2)}, {tape.Name("y"), tape.Name("q")}}
	d, _ := tape.demand_of(paths)
	defer tape.destroy(&d)
	r, err := json.scan(transmute([]u8)src, &d)
	defer tape.destroy(&r)
	testing.expect(t, err == nil)
	testing.expect_value(t, testkit.render_doc(&r), `~{"x":~[30],"y":~{}}`)
	testing.expect_value(t, testkit.render_answers(&r), `0=30 1=Missing`)
	x := r.partial
	testing.expect_value(t, len(x.kept), 1)
	testing.expect(t, len(x.kept) == 1 && x.kept[0].index == 2 && r.nodes[x.kept[0].node].lo == 12)
	testing.expect_value(t, len(r.counts), 0)
	testing.expect_value(t, r.nodes[0].spelling, tape.CONTAINER_PARTIAL | 3)
	testing.expect_value(t, len(x.missing), 1)
	if len(x.missing) == 1 {
		m := x.missing[0]
		testing.expect_value(t, string(x.names[m.lo:][:m.n]), "q")
		testing.expect_value(t, r.nodes[m.node].kind, tape.Kind.Object)
		at, p, _ := tape.answer({doc = &r}, 1, 0)
		testing.expect(t, p == .Missing && at == m.node)
	}
	testing.expect(t, .Stopped not_in r.flags)

	first, _ := tape.demand_of([][]tape.Step{{tape.Name("x"), tape.Index(0)}})
	defer tape.destroy(&first)
	s, serr := json.scan(transmute([]u8)src, &first, read = {stop_early = true}, opts = {dups = .First})
	defer tape.destroy(&s)
	testing.expect(t, serr == nil && .Stopped in s.flags)
	testing.expect_value(t, testkit.render_doc(&s), `~{"x":~[10]}`)
	testing.expect_value(t, testkit.render_answers(&s), `0=10`)
	testing.expect_value(t, s.root_close, 0)
}

// Any number of paths, keys that need decoding, comments and a path through deep containers.
@(test)
scan_takes_any_paths :: proc(t: ^testing.T) {
	testkit.deadline(t)
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
	for p in 0 ..< 200 {
		fmt.sbprintf(&want, "%s%d=%d", " " if p > 0 else "", p, 199 - p)
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
	_, p, _ := tape.answer({doc = &r}, 0, 0)
	testing.expect(t, err == nil && len(r.partial.answers) == 1 && p == .Found)
	testing.expect_value(t, len(r.nodes), 2 * 1500 + 1)
}

// A container of more children than a node's `spelling` holds keeps its true count, kept whole or partial, and a
// replayed element that ends the read leaves its array partial with its true count.
@(test)
scan_counts_wide_containers :: proc(t: ^testing.T) {
	testkit.deadline(t)
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
	answers := testkit.render_answers(&r)
	testing.expect_value(t, answers[len(answers) - 3:], `1=5`)
	counts := make(map[tape.Node_Index]u32, context.temp_allocator)
	for c, i in r.counts {
		counts[c.node] = c.count
		testing.expect(t, i == 0 || r.counts[i - 1].node < c.node)
	}
	a, _, _ := tape.answer({doc = &r}, 0, 0)
	testing.expect_value(t, r.nodes[a].spelling, tape.MAX_CHILDREN)
	testing.expect_value(t, counts[a], N)
	bn, _ := tape.member({doc = &r}, tape.ROOT, "b")
	testing.expect_value(t, r.nodes[bn].spelling, tape.CONTAINER_PARTIAL | tape.MAX_CHILDREN)
	testing.expect_value(t, counts[bn], N)
	testing.expect_value(t, len(r.counts), 2)

	last, _ := tape.demand_of([][]tape.Step{{tape.Name("a"), tape.Index(-1)}})
	defer tape.destroy(&last)
	s, serr := json.scan(src, &last, read = {stop_early = true}, opts = {dups = .First})
	defer tape.destroy(&s)
	testing.expect(t, serr == nil && .Stopped in s.flags)
	testing.expect_value(t, testkit.render_answers(&s), `0=69999`)
	testing.expect_value(t, testkit.render_doc(&s), `~{"a":~[69999]}`)
	testing.expect(t, len(s.counts) == 1 && s.counts[0].count == N)
	testing.expect_value(t, s.nodes[0].spelling, tape.CONTAINER_PARTIAL | tape.MAX_CHILDREN)
}

// Every container whose count saturates keeps its true count, in a build and in a scan keeping them whole, nested or
// side by side.
@(test)
counts_every_wide_container :: proc(t: ^testing.T) {
	testkit.deadline(t)
	N :: 40_000
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"a":[[`)
	join_each(&b, N, ",", "%[0]d")
	strings.write_string(&b, `],[`)
	join_each(&b, N + 1, ",", "%[0]d")
	strings.write_string(&b, `]`)
	for _ in 0 ..< N {
		strings.write_string(&b, `,0`)
	}
	strings.write_string(&b, `]}`)
	src := transmute([]u8)strings.to_string(b)
	check :: proc(t: ^testing.T, doc: ^tape.Document, what: string) {
		x := tape.Reader{doc = doc}
		a, _ := tape.member(x, tape.ROOT, "a")
		first, _ := tape.element(x, a, 0)
		second, _ := tape.element(x, a, 1)
		wants := [3]int{N + 2, N, N + 1}
		for at, i in ([3]tape.Node_Index{a, first, second}) {
			n, p, _ := tape.length(x, at, context.temp_allocator)
			testing.expectf(t, p == .Found && n == wants[i], "%s %d: %d %v", what, i, n, p)
		}
		testing.expectf(t, len(doc.counts) == 3, "%s: %v", what, len(doc.counts))
		for c, i in doc.counts {
			testing.expect(t, i == 0 || doc.counts[i - 1].node < c.node)
		}
	}
	doc, err := json.build(src)
	defer tape.destroy(&doc)
	testing.expect(t, err == nil)
	check(t, &doc, "build")
	d, _ := tape.demand_of([][]tape.Step{{tape.Name("a")}})
	defer tape.destroy(&d)
	r, serr := json.scan(src, &d)
	defer tape.destroy(&r)
	testing.expect(t, serr == nil)
	check(t, &r, "scan")
}

// An allocator that records the size of each live block, counts the frees and resizes that name another size than the
// block has, and keeps the most bytes live at once.
Sized :: struct {
	backing:  runtime.Allocator,
	sizes:    map[rawptr]int,
	live:     int,
	peak:     int,
	mismatch: int,
}

sized_allocator :: proc(s: ^Sized) -> runtime.Allocator {
	return {data = s, procedure = proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
		s := (^Sized)(data)
		forget :: proc(s: ^Sized, old_memory: rawptr, old_size: int) {
			if old_memory == nil {
				return
			}
			have, known := s.sizes[old_memory]
			if !known || old_size != 0 && old_size != have {
				s.mismatch += 1
			}
			s.live -= have
			delete_key(&s.sizes, old_memory)
		}
		switch mode {
		case .Alloc, .Alloc_Non_Zeroed:
			r, err := s.backing.procedure(s.backing.data, mode, size, alignment, old_memory, old_size, loc)
			if err == nil && size > 0 {
				s.sizes[raw_data(r)] = size
				s.live += size
				s.peak = max(s.peak, s.live)
			}
			return r, err
		case .Free:
			forget(s, old_memory, old_size)
		case .Resize, .Resize_Non_Zeroed:
			forget(s, old_memory, old_size)
			r, err := s.backing.procedure(s.backing.data, mode, size, alignment, old_memory, old_size, loc)
			if err == nil && size > 0 {
				s.sizes[raw_data(r)] = size
				s.live += size
				s.peak = max(s.peak, s.live)
			}
			return r, err
		case .Free_All:
			return nil, .Mode_Not_Implemented
		case .Query_Features, .Query_Info:
		}
		return s.backing.procedure(s.backing.data, mode, size, alignment, old_memory, old_size, loc)
	}}
}

sized_init :: proc(s: ^Sized) {
	s^ = {backing = context.allocator}
	s.sizes = make(map[rawptr]int, s.backing)
}

sized_destroy :: proc(s: ^Sized) {
	delete(s.sizes)
}

// A demand of more edges and paths than a scan keeps in its own room is read and freed under blocks that are given
// back at the size they were taken.
@(test)
scan_frees_what_it_allocates_at_the_size_it_took :: proc(t: ^testing.T) {
	testkit.deadline(t)
	PATHS :: 40
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_byte(&b, '{')
	paths := make([][]tape.Step, PATHS, context.temp_allocator)
	for i in 0 ..< PATHS {
		key := fmt.aprintf("key%d", i, allocator = context.temp_allocator)
		fmt.sbprintf(&b, `%s"%s":{{"v":%d}}`, "," if i > 0 else "", key, i)
		paths[i] = make([]tape.Step, 2, context.temp_allocator)
		paths[i][0], paths[i][1] = tape.Name(key), tape.Name("v")
	}
	strings.write_byte(&b, '}')
	src := transmute([]u8)strings.to_string(b)

	s: Sized
	sized_init(&s)
	defer sized_destroy(&s)
	allocator := sized_allocator(&s)
	d, derr := tape.demand_of(paths, allocator = allocator)
	testing.expect(t, derr == nil)
	testing.expectf(t, len(d.edges) > 32 && len(d.paths) > 32, "%d edges, %d paths", len(d.edges), len(d.paths))
	for stop in ([]bool{false, true}) {
		r, err := json.scan(src, &d, read = {stop_early = stop}, allocator = allocator)
		testing.expect(t, err == nil)
		testing.expect_value(t, len(r.partial.answers), PATHS)
		tape.destroy(&r)
	}
	tape.destroy(&d)
	testing.expect_value(t, s.mismatch, 0)
	testing.expect_value(t, s.live, 0)
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
// index keeps, with and without per-path limits.
@(test)
scan_frees_what_a_refused_allocation_leaves :: proc(t: ^testing.T) {
	testkit.deadline(t)
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

	// Each path's first two answers as well, a limit the scan counts.
	twos := make([]int, len(paths), context.temp_allocator)
	for &l in twos {
		l = 2
	}
	for limits in ([][]int{nil, twos}) {
		d, _ := tape.demand_of(paths[:], limits = limits)
		want, _ := json.scan(text, &d)
		want_answers := testkit.render_answers(&want)
		tape.destroy(&want)
		tape.destroy(&d)

		for left := 0; ; left += 1 {
			f := Failing{backing = context.allocator, left = left}
			allocator := failing_allocator(&f)
			fd, derr := tape.demand_of(paths[:], limits = limits, allocator = allocator)
			r: tape.Document
			err := tape.Error(derr) if derr != nil else nil
			if derr == nil {
				r, err = json.scan(text, &fd, allocator = allocator)
				if err == nil {
					testing.expect_value(t, testkit.render_answers(&r), want_answers)
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
}

// A container kept whole in a spec with comments keeps its values and no comment, as the rest of a partial document.
@(test)
scan_keeps_values_of_every_spec :: proc(t: ^testing.T) {
	testkit.deadline(t)
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
	testkit.deadline(t)
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
	testing.expect(t, err == nil && len(r.partial.answers) == 4)
	testing.expect_value(t, len(r.nodes), 1 + 4 * 1500)
}

// A grain keeps less of a container than its whole: its members with each container value one unread node, its count,
// or only its node. A scalar, null and an answer that is no value are as under `.Whole`.
@(test)
scan_keeps_a_grain_at_a_path_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	A :: tape.All{}
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	I :: proc(i: int) -> tape.Step {return tape.Index(i)}
	src := `{"a":{"b":1,"c":[2,3]},"d":[4,{"e":5}],"n":null,"s":"x"}`
	Grain_Case :: struct {
		c:      Scan_Case,
		grains: []tape.Grain,
	}
	cases := []Grain_Case {
		{{src, {{N("a")}}, .Default, `0={"b":1,"c":~[]}`, `~{"a":{"b":1,"c":~[]}}`}, {.Keys}},
		{{src, {{N("d")}}, .Default, `0=~[]`, `~{"d":~[]}`}, {.Keys}},
		{{src, {{N("a")}}, .Default, `0=~{}`, `~{"a":~{}}`}, {.Exists}},
		{{src, {{N("d")}}, .Default, `0=~[]`, `~{"d":~[]}`}, {.Exists}},
		{{src, {{N("s")}, {N("n")}, {N("x")}}, .Default, `0="x" 1=null 2=Missing`, `~{"n":null,"s":"x"}`}, {.Keys, .Exists, .Exists}},
		{{src, {{N("a"), N("b"), N("z")}}, .Default, `0=Wrong_Kind`, `~{"a":~{"b":1}}`}, {.Keys}},
		{{src, {{N("a")}, {N("a"), N("c"), I(0)}}, .Default, `0={"b":1,"c":~[2]} 1=2`, `~{"a":{"b":1,"c":~[2]}}`}, {.Keys}},
		{{src, {{N("a")}, {N("a")}}, .Default, `0={"b":1,"c":[2,3]} 1={"b":1,"c":[2,3]}`, `~{"a":{"b":1,"c":[2,3]}}`}, {.Keys}},
		{{src, {{N("a")}, {N("a"), A}}, .Default, `0={"b":1,"c":~[]} 1=1 1=~[]`, `~{"a":{"b":1,"c":~[]}}`}, {.Keys, .Exists}},
		{{src, {{N("d"), A}}, .Default, `0=4 0={"e":5}`, `~{"d":[4,{"e":5}]}`}, {.Keys}},
		{{`[{"a":1},{"b":2,"c":3},{}]`, {{A}}, .Default, `0={"a":1} 0={"b":2,"c":3} 0={}`, `[{"a":1},{"b":2,"c":3},{}]`}, {.Keys}},
		{{`{"a":{"x":1,"x":2},"b":0}`, {{N("a")}, {N("a"), N("x")}}, .Default, `0={"x":1,"x":2} 1=2`, `~{"a":{"x":1,"x":2}}`}, {.Keys}},
		{{`{"a":{"x":1,"x":2},"b":0}`, {{N("a")}, {N("a"), N("x")}}, .First, `0={"x":1,"x":2} 1=1`, `~{"a":{"x":1,"x":2}}`}, {.Keys}},
		{{`[]`, {{}}, .Default, `0=[]`, `[]`}, {.Keys}},
	}
	for c in cases {
		expect_scan(t, c.c, grains = c.grains)
	}
	// Under `.First` the read ends at the first member's value, with the object it is in not closed.
	expect_scan(t, {`{"a":{"x":1,"x":2}}`, {{N("a")}}, .First, `0={"x":1,"x":2}`, `{"a":{"x":1,"x":2}}`}, grains = {.Keys}, stopped = `~{"a":{"x":1,"x":2}}`)
	expect_scan(t, {"{a: {'b': 1, c: [2,],}, // d\n}", {{N("a")}}, .Default, `0={"b":1,c:~[]}`, `{a:{"b":1,c:~[]}}`}, .Json5, {.Keys})
	expect_scan(t, {"{\"a\": {\"b\": 1, /* x */ \"c\": 2,}}", {{N("a")}}, .Default, `0={"b":1,"c":2}`, `{"a":{"b":1,"c":2}}`}, .Jsonc, {.Keys})
}

// A limit on a step stops its keeping and not its count, and a slice takes elements by place from either end.
@(test)
scan_cuts_steps_by_limits_and_slices :: proc(t: ^testing.T) {
	testkit.deadline(t)
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	L :: proc(n: i32) -> tape.Step {return tape.All{n}}
	S :: proc(lo: i32, hi: Maybe(i32), limit: i32 = 0) -> tape.Step {return tape.Slice{lo, hi, limit}}
	nums := `[0,1,2,3,4]`
	recs := `[{"a":0},{"a":1},{"a":2},{"b":3},{"a":4}]`
	cases := []Scan_Case {
		{nums, {{L(1)}}, .Default, `0=0`, `~[0]`},
		{nums, {{L(2)}, {L(9)}}, .Default, `0=0 0=1 1=0 1=1 1=2 1=3 1=4`, `[0,1,2,3,4]`},
		{nums, {{S(1, 3)}}, .Default, `0=1 0=2`, `~[1,2]`},
		{nums, {{S(1, nil)}}, .Default, `0=1 0=2 0=3 0=4`, `~[1,2,3,4]`},
		{nums, {{S(1, nil, 2)}}, .Default, `0=1 0=2`, `~[1,2]`},
		{nums, {{S(-2, nil)}}, .Default, `0=3 0=4`, `~[3,4]`},
		{nums, {{S(-3, -1)}}, .Default, `0=2 0=3`, `~[2,3]`},
		{nums, {{S(-3, nil, 1)}}, .Default, `0=2`, `~[2]`},
		{nums, {{S(-9, 2)}}, .Default, `0=0 0=1`, `~[0,1]`},
		{nums, {{S(1, -2)}}, .Default, `0=1 0=2`, `~[1,2,3,4]`},
		{nums, {{S(0, -1, 2)}}, .Default, `0=0 0=1`, `~[0,1]`},
		{nums, {{S(3, 1)}, {S(9, nil)}}, .Default, ``, `~[]`},
		{nums, {{S(-1, -2)}}, .Default, ``, `~[]`},
		{nums, {{S(-2, nil)}, {S(0, 1)}}, .Default, `0=3 0=4 1=0`, `[0,1,2,3,4]`},
		{recs, {{S(-2, nil), N("a")}}, .Default, `0=Missing 0=4`, `~[~{},{"a":4}]`},
		{recs, {{S(1, nil, 2), N("a")}}, .Default, `0=1 0=2`, `~[{"a":1},{"a":2}]`},
		{recs, {{L(1), N("a")}, {}}, .Default, `0=0 1=[{"a":0},{"a":1},{"a":2},{"b":3},{"a":4}]`, recs},
		{`[[1,2,3],[4,5]]`, {{tape.All{}, L(1)}}, .Default, `0=1 0=4`, `[~[1],~[4]]`},
		{`[[1,2,3],[4,5]]`, {{L(1), tape.All{}}}, .Default, `0=1 0=2 0=3`, `~[[1,2,3]]`},
		{`[[1,2,3],[4,5]]`, {{tape.All{}, S(-1, nil)}}, .Default, `0=3 0=5`, `[~[3],~[5]]`},
		{`{"a":1,"b":2}`, {{L(1)}}, .First, `0=1`, `~{"a":1}`},
		{`{"a":1,"b":2}`, {{L(1)}}, .Default, `0=1 0=2`, `{"a":1,"b":2}`},
		{`{"a":{"x":1}}`, {{N("a"), S(0, 1)}, {N("b"), S(0, 1)}, {N("a"), S(0, 1), N("c")}}, .Default, `0=Wrong_Kind 1=Missing 2=Wrong_Kind`, `{"a":~{}}`},
		{`{"a":null}`, {{N("a"), S(0, 1)}, {N("a"), S(0, 1), N("c")}}, .Default, `0=Missing 1=Missing`, `{"a":null}`},
	}
	for c in cases {
		expect_scan(t, c)
	}
	expect_scan(t, {"[1, /* x */ 2, 3,]", {{S(-2, nil)}}, .Default, `0=2 0=3`, `~[2,3]`}, .Jsonc)
	expect_scan(t, {"[1, 2, 3,]", {{L(2)}}, .Default, `0=1 0=2`, `~[1,2]`}, .Json5)
	expect_scan(t, {`{"x":[1,2,3]}`, {{N("x"), L(1)}, {N("x")}}, .Default, `0=1 1=~[1]`, `{"x":~[1]}`}, grains = {.Whole, .Keys})
}

// A stop at a cut keeps checking the text past it, unless `stop_early` ends the walk there.
@(test)
scan_judges_the_text_past_a_cut :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(`[1,2,x`)
	d, _ := tape.demand_of([][]tape.Step{{tape.All{1}}})
	defer tape.destroy(&d)
	_, err := json.scan(src, &d)
	fault, refused := err.(tape.Fault)
	testing.expectf(t, refused && fault.kind == .Bad_Char && fault.at == 5, "%v", err)
	faults := [?]struct {
		src:  string,
		kind: tape.Fault_Kind,
		at:   u64,
	}{{`[1,2,`, .Truncated, 5}, {`[1,2`, .Truncated, 4}, {`[1,2,x]`, .Bad_Char, 5}, {`[1,2,"a\q"]`, .Bad_Escape, 8}}
	for c in faults {
		_, cerr := json.scan(transmute([]u8)c.src, &d)
		cfault, crefused := cerr.(tape.Fault)
		testing.expectf(t, crefused && cfault.kind == c.kind && cfault.at == c.at, "%q: %v", c.src, cerr)
	}
	r, serr := json.scan(src, &d, read = {stop_early = true})
	defer tape.destroy(&r)
	testing.expect(t, serr == nil && .Stopped in r.flags)
	testing.expect_value(t, testkit.render_answers(&r), `0=1`)
	counted, _ := tape.demand_of([][]tape.Step{{tape.All{1}}, {}}, {.Whole, .Keys})
	defer tape.destroy(&counted)
	c, cerr := json.scan(transmute([]u8)string(`[1,2,3]`), &counted, read = {stop_early = true})
	defer tape.destroy(&c)
	testing.expect(t, cerr == nil)
	testing.expect_value(t, testkit.render_answers(&c), `0=1 1=~[1]`)
	n, p, _ := tape.length({doc = &c}, tape.ROOT, context.temp_allocator)
	testing.expect(t, n == 3 && p == .Found)
}

// Texts that break past the part `limited_paths` settle in under `.First`, the arrays for the paths from the root and
// the objects for the path through `a`.
LIMITED_TEXTS :: []string {
	`[1,2,x`,
	`[1,2,`,
	`[1,2`,
	`[1,2,x]`,
	`[1,2,"a\q"]`,
	`[1,[2,x]]`,
	`[1,{"a":tru}]`,
	`[1,[[[[x]]]]]`,
	`[1,{"b":`,
	`[1,2]x`,
	`[1]x`,
	`[1,2] 3`,
	`[1,2]]`,
	`[1,2,"\udc00"]`,
	`{"a":[1,2,x],"b":1}`,
	`{"a":[1,[x]]}`,
	`{"a":[1],"b":x}`,
	`{"a":[1]}}`,
}

// Paths a limit settles in `LIMITED_TEXTS`, the last by its path's limit of 1.
limited_paths := [][]tape.Step{{tape.All{1}}, {tape.Slice{0, nil, 1}}, {tape.Name("a"), tape.All{1}}, {tape.All{}}}

// The limit of each of `limited_paths`.
limited_limits := []int{0, 0, 0, 1}

// The demand of path `i` of `limited_paths`.
limited_demand :: proc(i: int) -> tape.Demand {
	d, err := tape.demand_of(limited_paths[i:][:1], nil, limited_limits[i:][:1])
	assert(err == nil)
	return d
}

// A limit stops what a scan and a find keep, not what they judge: past the part the limit settles every byte is judged
// as `validate` judges it, and the scan keeps no more than a stopped one. Only `stop_early` ends the walk, with
// `.Stopped`.
@(test)
limited_reads_judge_the_text_past_the_limit :: proc(t: ^testing.T) {
	testkit.deadline(t)
	read := tape.Read_Options{}
	stop := tape.Read_Options{stop_early = true}
	first := json.Options{dups = .First}
	for src in LIMITED_TEXTS {
		text := transmute([]u8)src
		want := json.validate(text)
		testing.expectf(t, want != nil, "%q", src)
		for path, i in limited_paths {
			d := limited_demand(i)
			defer tape.destroy(&d)
			r, err := json.scan(text, &d, read = read, opts = first)
			tape.destroy(&r)
			testing.expectf(t, err == want, "%q scan %v: %v, validate %v", src, path, err, want)
			settles := (src[0] == '{') == (len(path) == 2)
			s, serr := json.scan(text, &d, read = stop, opts = first)
			testing.expectf(t, !settles || serr == nil && .Stopped in s.flags, "%q scan %v stop: %v %v", src, path, serr, s.flags)
			tape.destroy(&s)
			if limited_limits[i] == 0 {
				_, ferr := json.find(text, path, read = read, opts = first)
				testing.expectf(t, ferr == want, "%q find %v: %v, validate %v", src, path, ferr, want)
				a, aerr := json.find(text, path, read = stop, opts = first)
				testing.expectf(t, !settles || aerr == nil && a.outcome == .Found, "%q find %v stop: %v %v", src, path, a, aerr)
			}
		}
	}
	for f in #load_directory("conformance/JSONTestSuite/test_parsing") {
		want := json.validate(f.data)
		for _, i in limited_paths {
			d := limited_demand(i)
			defer tape.destroy(&d)
			r, err := json.scan(f.data, &d, read = read, opts = first)
			tape.destroy(&r)
			testing.expectf(t, err == want, "%s scan %v: %v, validate %v", f.name, limited_paths[i], err, want)
		}
	}
	for src in ([]string{`[1,2,3]`, `[1,[2,3],{"a":4}]`, `{"a":[1,[2]],"b":[3]}`, `{"a":[[1],2],"a":[3]}`}) {
		for path, i in limited_paths {
			d := limited_demand(i)
			defer tape.destroy(&d)
			r, err := json.scan(transmute([]u8)src, &d, read = read, opts = first)
			defer tape.destroy(&r)
			s, serr := json.scan(transmute([]u8)src, &d, read = stop, opts = first)
			defer tape.destroy(&s)
			testing.expectf(t, err == nil && serr == nil && .Stopped not_in r.flags, "%q %v: %v %v %v", src, path, err, serr, r.flags)
			same := len(r.nodes) == len(s.nodes) && testkit.render_doc(&r) == testkit.render_doc(&s) && testkit.render_answers(&r) == testkit.render_answers(&s)
			testing.expectf(t, same, "%q %v: keeps %q %q, stopped %q %q", src, path, testkit.render_doc(&r), testkit.render_answers(&r), testkit.render_doc(&s), testkit.render_answers(&s))
		}
	}
}

// A path `[All{limit = n}, All{}]` takes the first `n` children of the root whatever they are, those the next step
// cannot enter as the wrong kind, and gives the second step's answers of them only.
@(test)
scan_limit_of_an_all_counts_every_child :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := [?]struct {
		src, answers: string,
	}{{`[[],"ab",[1]]`, `0=Wrong_Kind`}, {`[[1],null,[1,2]]`, `0=1 0=Wrong_Kind`}, {`[[],5,[1,2]]`, `0=Wrong_Kind`}}
	d, _ := tape.demand_of([][]tape.Step{{tape.All{2}, tape.All{}}})
	defer tape.destroy(&d)
	for c in cases {
		r, err := json.scan(transmute([]u8)c.src, &d)
		defer tape.destroy(&r)
		testing.expectf(t, err == nil && testkit.render_answers(&r) == c.answers, "%s: %q, want %q, %v", c.src, testkit.render_answers(&r), c.answers, err)
	}
}

// Every element a read kept of a partial array is found by its place.
@(test)
scan_lists_every_kept_element :: proc(t: ^testing.T) {
	testkit.deadline(t)
	d, _ := tape.demand_of([][]tape.Step{{tape.All{2}, tape.All{}}})
	defer tape.destroy(&d)
	for src in ([]string{`[[],[],5]`, `[[1],[2],[3]]`, `[[],[1],"x"]`}) {
		r, err := json.scan(transmute([]u8)src, &d)
		defer tape.destroy(&r)
		testing.expect(t, err == nil)
		for i in 0 ..< 2 {
			_, p := tape.element({doc = &r}, tape.ROOT, i)
			testing.expectf(t, p == .Found, "%s: element %d is %v", src, i, p)
		}
	}
}

// A path from the end that reaches back further than the text is long holds no more than the text has, so a read in a
// small memory budget answers it, and a stopped scan leaves the counts it did not finish unknown.
@(test)
reads_from_the_end_hold_no_more_than_the_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	opts := json.Options{budget = {memory = 1 << 16}}
	src := transmute([]u8)string(`[1,[2,3],4]`)
	for steps in ([][]tape.Step{{tape.Index(-100_000_000)}, {tape.Slice{-100_000_000, nil, 0}}, {tape.Slice{0, -100_000_000, 0}}, {tape.Index(-100_000_000), tape.Index(0)}}) {
		d, derr := tape.demand_of({steps})
		defer tape.destroy(&d)
		testing.expect(t, derr == nil)
		r, err := json.scan(src, &d, opts = opts)
		testing.expectf(t, err == nil, "scan %v: %v", steps, err)
		tape.destroy(&r)
		a, ferr := json.find(src, steps, opts = opts)
		testing.expectf(t, ferr == nil, "find %v: %v %v", steps, a, ferr)
	}
}

// A scan that stopped inside a container does not know its count, and one that read it to its close does. A partial
// object's count is never known, as a member it left out may repeat a key.
@(test)
stopped_scans_leave_counts_unknown :: proc(t: ^testing.T) {
	testkit.deadline(t)
	N :: proc(s: string) -> tape.Step {return tape.Name(s)}
	I :: proc(i: int) -> tape.Step {return tape.Index(i)}
	Case :: struct {
		src:     string,
		path:    []tape.Step,
		stopped: []int, // each container node's length, -1 for one not known
		whole:   []int,
	}
	cases := []Case {
		{`[1,2,3]`, {I(0)}, {-1}, {3}},
		{`[[1,2],[3]]`, {I(0), I(0)}, {-1, -1}, {2, 2}},
		{`{"a":1,"b":2}`, {N("a")}, {-1}, {-1}},
		{`[[1,2],[3]]`, {I(1), I(0)}, {-1, -1}, {2, 1}},
		{`[[1,2],[3]]`, {I(0)}, {-1, 2}, {2, 2}},
		{`[[1,2],[3]]`, {I(-1)}, {2, 1}, {2, 1}},
	}
	for c in cases {
		d, _ := tape.demand_of({c.path})
		defer tape.destroy(&d)
		for stop in ([]bool{false, true}) {
			r, err := json.scan(transmute([]u8)c.src, &d, read = {stop_early = stop})
			defer tape.destroy(&r)
			testing.expectf(t, err == nil, "%s: %v", c.src, err)
			want := c.stopped if stop else c.whole
			containers := 0
			for node, i in r.nodes {
				if node.kind < .Array {
					continue
				}
				n, p, _ := tape.length({doc = &r}, tape.Node_Index(i), context.temp_allocator)
				testing.expectf(t, containers < len(want) && (want[containers] < 0 && p != .Found || want[containers] >= 0 && p == .Found && n == want[containers]), "%s %v stop %v: container %d has length %d %v, want %v", c.src, c.path, stop, containers, n, p, want)
				containers += 1
			}
			testing.expectf(t, containers == len(want), "%s %v stop %v: %d containers", c.src, c.path, stop, containers)
		}
	}
}

// A scan of no paths under `stop_early` reads no more than the first token, and so checks no more of the text, while
// one without it checks the whole text.
@(test)
scan_of_no_paths_stops_at_once :: proc(t: ^testing.T) {
	testkit.deadline(t)
	d, derr := tape.demand_of({})
	defer tape.destroy(&d)
	testing.expect(t, derr == nil)
	for src in ([]string{`[1,x`, `{"a":1,`, `[1,2,3]`}) {
		stopped, serr := json.scan(transmute([]u8)src, &d, read = {stop_early = true})
		testing.expectf(t, serr == nil && .Stopped in stopped.flags && len(stopped.nodes) <= 1, "%q stop: %v %v", src, serr, stopped.flags)
		tape.destroy(&stopped)
		whole, werr := json.scan(transmute([]u8)src, &d)
		testing.expectf(t, (werr != nil) == (src != `[1,2,3]`) && .Stopped not_in whole.flags, "%q: %v %v", src, werr, whole.flags)
		tape.destroy(&whole)
	}
}

// A scan counts each container it opens or keeps once in `Budget.steps`.
@(test)
scan_counts_each_container_once_in_steps :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(`{"a":[1,[2]],"b":{"c":[]}}`)
	d, derr := tape.demand_of({{tape.Name("a")}})
	defer tape.destroy(&d)
	testing.expect(t, derr == nil)
	for steps in u64(1) ..= 8 {
		r, err := json.scan(src, &d, opts = {budget = {steps = steps}})
		tape.destroy(&r)
		_, exceeded := err.(tape.Exceeded)
		testing.expectf(t, exceeded == (steps < 5), "steps %d: %v", steps, err)
	}
}

// A read whose room grows past twice its size, to what the rest of the text makes at the rate so far, grows by doubling
// when that block is refused, and gives the document of a read that is refused nothing.
@(test)
room_doubles_when_its_growth_is_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Doubling :: struct {
		backing: runtime.Allocator,
		refused: int,
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[")
	join_each(&b, 3000, ",", `{{"a":%[0]d,"b":[%[0]d]}}`)
	strings.write_string(&b, "]")
	src := transmute([]u8)strings.to_string(b)
	d, _ := tape.demand_of([][]tape.Step{{tape.All{}}})
	defer tape.destroy(&d)
	ref, err := json.build(src)
	defer tape.destroy(&ref)
	kept, serr := json.scan(src, &d)
	defer tape.destroy(&kept)
	testing.expect(t, err == nil && serr == nil)
	doubling := Doubling{backing = context.allocator}
	a := runtime.Allocator{data = &doubling, procedure = proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
		d := (^Doubling)(data)
		if (mode == .Resize || mode == .Resize_Non_Zeroed) && old_memory != nil && size > 2 * old_size {
			d.refused += 1
			return nil, .Out_Of_Memory
		}
		return d.backing.procedure(d.backing.data, mode, size, alignment, old_memory, old_size, loc)
	}}
	doc, berr := json.build(src, allocator = a)
	defer tape.destroy(&doc)
	testing.expectf(t, berr == nil && testkit.render_doc(&doc) == testkit.render_doc(&ref), "build: %v", berr)
	r, rerr := json.scan(src, &d, allocator = a)
	defer tape.destroy(&r)
	testing.expectf(t, rerr == nil && testkit.render_doc(&r) == testkit.render_doc(&kept) && len(r.partial.answers) == 3000, "scan: %v", rerr)
	testing.expectf(t, doubling.refused >= 2, "%d growths refused", doubling.refused)
}

// A scan that a memory budget lets read is read under any larger one: the room of nodes grows by at most half of what the
// budget leaves, so the lists the scan keeps beside it find space.
@(test)
scans_that_fit_a_memory_budget_fit_a_larger_one :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	join_each(&b, 70, ",", "%[0]d")
	strings.write_byte(&b, ']')
	src := transmute([]u8)strings.to_string(b)
	for steps in ([][]tape.Step{{tape.Descend{}, tape.Name("a")}, {tape.Index(-3)}, {tape.Slice{-5, nil, 0}}}) {
		d, derr := tape.demand_of({steps})
		defer tape.destroy(&d)
		testing.expect(t, derr == nil)
		fits := false
		for memory in 1 ..= u64(4000) {
			r, err := json.scan(src, &d, opts = {budget = {memory = memory}})
			tape.destroy(&r)
			if !testing.expectf(t, err == nil || !fits, "%v: fits %d bytes and not %d", steps, memory - 1, memory) {
				break
			}
			fits ||= err == nil
		}
		testing.expectf(t, fits, "%v fits no budget up to 4000 bytes", steps)
	}
}
