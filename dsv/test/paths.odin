package dsv_tests

import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import dsv ".."
import walktest "../../walktest"

@(private = "file")
Read_Case :: struct {
	src:  string,
	path: string,
	want: []string, // the text of each `.Found`, "M" and "T" for the others
}

@(private = "file")
answer_texts :: proc(doc: ^core.Document, answers: []core.Answer) -> []string {
	out := make([]string, len(answers), context.temp_allocator)
	for a, i in answers {
		switch a.outcome {
		case .Found:
			out[i] = strings.trim_right(string(core.span(doc, a.node)), "\r\n")
		case .Missing:
			out[i] = "M"
		case .Wrong_Kind, .Not_Loaded:
			out[i] = "T"
		}
	}
	return out
}

@(test)
path_reads :: proc(t: ^testing.T) {
	headed := "id,name\n1,ann\n2,bob\n"
	cases := []Read_Case {
		{headed, ".[0].name", {"ann"}},
		{headed, ".[1].id", {"2"}},
		{headed, ".[1][1]", {"bob"}},
		{headed, ".[].name", {"ann", "bob"}},
		{headed, ".[][0]", {"1", "2"}},
		{headed, ".[0]", {"1,ann"}},
		{headed, ".[2]", {"M"}},
		{headed, ".[0].age", {"M"}},
		{headed, ".[0][5]", {"M"}},
		{headed, ".[0].name.x", {"T"}},
		{headed, ".name", {"T"}},
		{"a,b\n\"1,2\",3\n", ".[0].a", {`"1,2"`}},
		{"\"a b\",c\n1,2\n", `.[0]."a b"`, {"1"}},
		{"a,b\n1,2\n3\n", ".[1].b", {"M"}},
		{"b,c,b\nx,y,z\n1,2,3\n", "...b", {"T", "T", "T", "z", "T", "T", "T", "3", "T"}},
		{"a,b\n1,2\n3,4\n5,6\n", "...[-2]", {"1", "T", "T", "3,4", "3", "T", "T", "5", "T", "T"}},
	}
	for c in cases {
		path, perr := core.parse_path(c.path)
		defer core.path_destroy(&path)
		walktest.expect_nil(t, perr)
		src := transmute([]u8)c.src
		doc, err := dsv.scan(src, .Csv, path, opts = {tolerate = {.Ragged}})
		defer core.destroy(&doc)
		testing.expectf(t, err == nil, "%q: %v", c.path, err)
		testing.expectf(t, slice_equal(answer_texts(&doc, doc.answers), c.want), "scan %q: %v", c.path, doc.answers)

		full, berr := core.build(src, dsv.as(.Csv, {tolerate = {.Ragged}}))
		defer core.destroy(&full)
		walktest.expect_nil(t, berr)
		answers, qerr := dsv.query(&full, path)
		defer delete(answers)
		walktest.expect_nil(t, qerr)
		testing.expectf(t, slice_equal(answer_texts(&full, answers), c.want), "query %q: %v", c.path, answers)
	}
	free_all(context.temp_allocator)
}

@(private = "file")
slice_equal :: proc(a, b: []string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for s, i in a {
		if s != b[i] {
			return false
		}
	}
	return true
}

// A headerless text has no names, and a kept cell keeps its key in a headed text.
@(test)
path_shapes :: proc(t: ^testing.T) {
	src := transmute([]u8)string("1,2\n3,4\n")
	path, _ := core.parse_path(".[1][1]")
	defer core.path_destroy(&path)
	doc, err := dsv.scan(src, .Csv, path, opts = {no_header = true})
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(core.span(&doc, doc.answers[0].node)), "4")
	testing.expect_value(t, core.length(&doc, core.ROOT), 2)
	record, at := core.element_of(&doc, core.ROOT, 1)
	testing.expect_value(t, at, core.Presence.Found)
	testing.expect_value(t, string(core.span(&doc, record)), "3,4\n")
	_, before := core.element_of(&doc, core.ROOT, 0)
	testing.expect_value(t, before, core.Presence.Not_Loaded)

	named, _ := core.parse_path(".[0].a")
	defer core.path_destroy(&named)
	bare, bad := dsv.scan(src, .Csv, named, opts = {no_header = true})
	defer core.destroy(&bare)
	walktest.expect_nil(t, bad)
	testing.expect_value(t, bare.answers[0].outcome, core.Presence.Wrong_Kind)

	headed := transmute([]u8)string("a,b\n1,2\n")
	h, herr := dsv.scan(headed, .Csv, named)
	defer core.destroy(&h)
	walktest.expect_nil(t, herr)
	rec, _ := core.element_of(&h, core.ROOT, 0)
	v, found := core.member_of(&h, rec, "a")
	testing.expect_value(t, found, core.Presence.Found)
	testing.expect_value(t, string(core.span(&h, v)), "1")
	_, other := core.member_of(&h, rec, "b")
	testing.expect_value(t, other, core.Presence.Not_Loaded)
}

// Under `.Ragged` a path names a wide record's cell past the header's last by its 1-based position, and a header cell
// of that name repeats it. A path takes the last of a repeated name.
@(test)
path_wide_record :: proc(t: ^testing.T) {
	src := transmute([]u8)string("3,b\n1,2\n4,5,6,7\n")
	ragged := dsv.Options{tolerate = {.Ragged}}
	paths: [3]core.Path
	for p, i in ([]string{`.[1]["4"]`, `.[0]["3"]`, `.[1]["3"]`}) {
		paths[i], _ = core.parse_path(p)
	}
	defer for &p in paths {
		core.path_destroy(&p)
	}
	buf: [8]u8
	want := []string{"7", "1", "6"}
	for i in 0 ..< 3 {
		doc, err := dsv.scan(src, .Csv, paths[i], opts = ragged)
		text, _ := core.text(&doc, doc.answers[0].node, buf[:])
		testing.expectf(t, err == nil && text == want[i], "path %d: %v %q", i, err, text)
		core.destroy(&doc)
	}
	many, err := dsv.scan(src, .Csv, paths[:], opts = ragged)
	defer core.destroy(&many)
	walktest.expect_nil(t, err)
	// The answers of several paths come in the text's order.
	for w, i in ([]string{"1", "6", "7"}) {
		text, _ := core.text(&many, many.answers[i].node, buf[:])
		testing.expectf(t, text == w, "path %d of many: %q", i, text)
	}
	refused, strict := dsv.scan(src, .Csv, paths[0])
	defer core.destroy(&refused)
	walktest.expect_kind(t, strict, core.Path_Error_Kind.Walk)
}

// A `Partial` record's end comes from a walk that takes the text as the read did, and a stop may leave the record's end
// in text no walk judged.
@(test)
path_record_ends :: proc(t: ^testing.T) {
	path, _ := core.parse_path(".[0].a")
	defer core.path_destroy(&path)

	bare := transmute([]u8)string("a,b\n1,x\"y\n2,3\n")
	doc, err := dsv.scan(bare, .Csv, path, opts = {tolerate = {.Bare_Quote}})
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(core.span(&doc, doc.answers[0].owner)), "1,x\"y\n")

	open := transmute([]u8)string("a,b\n1,\"x")
	stopped, serr := dsv.scan(open, .Csv, path, read = {dups = .First, stop_early = true})
	defer core.destroy(&stopped)
	walktest.expect_nil(t, serr)
	testing.expect(t, stopped.stopped)
	testing.expect(t, strings.has_prefix(string(core.span(&stopped, stopped.answers[0].owner)), "1,"))
}

PATH_ROUNDS :: #config(PATH_ROUNDS, 2000)

// The positions a lead or cell step picks of `n`, and whether it answers one missing value.
@(private = "file")
picked :: proc(step: core.Step, n: int) -> (at: []int, missing: bool) {
	list := make([dynamic]int, context.temp_allocator)
	#partial switch x in step {
	case core.All:
		for i in 0 ..< n {
			append(&list, i)
		}
	case core.Index:
		i := int(x) if x >= 0 else n + int(x)
		if i < 0 || i >= n {
			return nil, true
		}
		append(&list, i)
	case core.Slice:
		lo := x.lo if x.lo >= 0 else max(n + x.lo, 0)
		hi := x.hi.? or_else n
		hi = hi if hi >= 0 else n + hi
		for i in lo ..< min(hi, n) {
			append(&list, i)
		}
	}
	return list[:], false
}

@(private = "file")
random_position :: proc(n: int) -> core.Step {
	switch rand.int_max(5) {
	case 0:
		return core.All{}
	case 1:
		return core.Index(rand.int_max(n + 2))
	case 2:
		return core.Index(-1 - rand.int_max(n + 2))
	case 3:
		return core.Slice{lo = rand.int_max(2 * n + 3) - n - 1}
	}
	return core.Slice{rand.int_max(2 * n + 3) - n - 1, rand.int_max(2 * n + 3) - n - 1}
}

@(private = "file")
answers_of :: proc(doc: ^core.Document, answers: []core.Answer, p: int) -> []string {
	mine := make([dynamic]core.Answer, context.temp_allocator)
	for a in answers {
		if int(a.path) == p {
			append(&mine, a)
		}
	}
	return answer_texts(doc, mine[:])
}

@(private = "file")
Stream :: struct {
	src:  []u8,
	want: [dynamic]string,
}

@(private = "file")
on_answer :: proc(state: rawptr, a: core.Token_Answer) -> bool {
	s := (^Stream)(state)
	text := "T"
	switch a.outcome {
	case .Found:
		text = strings.trim_right(string(s.src[a.lo:a.hi]), "\r\n")
	case .Missing:
		text = "M"
	case .Wrong_Kind, .Not_Loaded:
	}
	append(&s.want, fmt.tprintf("%d:%s", a.path, text))
	return true
}

// Scan, stopped scan, query and `each_answer` against the table a round wrote, over the paths a table has, one or several
// in a read.
@(test)
path_model :: proc(t: ^testing.T) {
	NAMES := [?]string{"x", "yy", `"q r"`, `"e""f"`}
	DECODED := [?]string{"x", "yy", "q r", `e"f`}
	for _ in 0 ..< PATH_ROUNDS {
		defer free_all(context.temp_allocator)
		width := rand.int_max(4) + 1
		rows := rand.int_max(4)
		b := strings.builder_make(context.temp_allocator)
		for c in 0 ..< width {
			fmt.sbprint(&b, "," if c > 0 else "", NAMES[c], sep = "")
		}
		strings.write_byte(&b, '\n')
		cells := make([][]string, rows, context.temp_allocator)
		for &row, i in cells {
			row = make([]string, width, context.temp_allocator)
			for &cell, c in row {
				cell = fmt.tprintf("c%d_%d", i, c)
				fmt.sbprint(&b, "," if c > 0 else "", cell, sep = "")
			}
			strings.write_byte(&b, '\n')
		}
		src := transmute([]u8)strings.to_string(b)
		paths := make([]core.Path, rand.int_max(3) + 1, context.temp_allocator)
		wants := make([][dynamic]string, len(paths), context.temp_allocator)
		total := 0
		for &path, p in paths {
			column := rand.int_max(width + 1)
			lead := random_position(rows)
			step := random_position(width)
			if rand.int_max(2) == 0 && column < width {
				step = core.Name(DECODED[column])
			}
			steps := make([]core.Step, 2, context.temp_allocator)
			steps[0], steps[1] = lead, step
			path.steps = steps
			wants[p] = make([dynamic]string, context.temp_allocator)
			records, gone := picked(lead, rows)
			if gone {
				_, every := step.(core.All)
				append(&wants[p], "T" if every else "M")
			}
			for i in records {
				if _, named := step.(core.Name); named {
					append(&wants[p], cells[i][column])
					continue
				}
				at, none := picked(step, width)
				if none {
					append(&wants[p], "M")
				}
				for c in at {
					append(&wants[p], cells[i][c])
				}
			}
			total += len(wants[p])
		}
		doc, err := dsv.scan(src, .Csv, paths)
		testing.expectf(t, err == nil, "%q: %v", string(src), err)
		stopped, serr := dsv.scan(src, .Csv, paths, read = {stop_early = true})
		testing.expectf(t, serr == nil, "%q: %v", string(src), serr)
		full, berr := core.build(src, dsv.as(.Csv))
		walktest.expect_nil(t, berr)
		answers, qerr := dsv.query(&full, paths)
		walktest.expect_nil(t, qerr)
		stream := Stream{src, make([dynamic]string, context.temp_allocator)}
		eerr := dsv.each_answer(src, .Csv, paths, &stream, on_answer)
		walktest.expect_nil(t, eerr)
		testing.expectf(t, len(stream.want) == total, "stream %q %v: %v", string(src), paths, stream.want)
		for want, p in wants {
			tagged := make([dynamic]string, context.temp_allocator)
			for w in want {
				append(&tagged, fmt.tprintf("%d:%s", p, w))
			}
			for w in tagged {
				testing.expectf(t, slice.contains(stream.want[:], w), "stream %q %v: %v want %v", string(src), paths, stream.want, tagged)
			}
			testing.expectf(t, slice_equal(answers_of(&doc, doc.answers, p), want[:]), "scan %q %v: %v want %v", string(src), paths, answers_of(&doc, doc.answers, p), want)
			testing.expectf(t, slice_equal(answers_of(&stopped, stopped.answers, p), want[:]), "stopped %q %v: %v want %v", string(src), paths, answers_of(&stopped, stopped.answers, p), want)
			testing.expectf(t, slice_equal(answers_of(&full, answers, p), want[:]), "query %q %v: %v want %v", string(src), paths, answers_of(&full, answers, p), want)
		}
		delete(answers)
		core.destroy(&doc)
		core.destroy(&stopped)
		core.destroy(&full)
	}
}

// `each_answer` gives the bytes `span` gives for the same value, a quoted cell's quotes and a record's line end included.
@(test)
stream_spans_are_authored :: proc(t: ^testing.T) {
	src := transmute([]u8)string("a,b\n\"x,y\",2\n3,\"\"\"q\"\"\"\n")
	texts := [?]string{".[0].a", ".[0]", ".[0].b", ".[1][1]", ".[1]"}
	paths: [len(texts)]core.Path
	for text, i in texts {
		paths[i], _ = core.parse_path(text)
	}
	defer for &p in paths {
		core.path_destroy(&p)
	}
	doc, err := dsv.scan(src, .Csv, paths[:])
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
	walktest.expect_nil(t, dsv.each_answer(src, .Csv, paths[:], &seen, each_answer_span))
	for a in doc.answers {
		testing.expect_value(t, seen.spans[a.path], string(core.span(&doc, a.node)))
	}
	testing.expect_value(t, seen.spans[0], "\"x,y\"")
	testing.expect_value(t, seen.spans[3], "\"\"\"q\"\"\"")
}

// A path scan of a text with a header takes the header's cells from its allocator, never from `context`'s: one path,
// several and a stream answer with the context's allocators panicking, leave nothing allocated, and every allocation
// refused is `.No_Memory`.
@(test)
scan_allocates_from_its_allocator :: proc(t: ^testing.T) {
	src := transmute([]u8)string("a,b\n1,2\n3,4\n")
	one, _ := core.parse_path(".[1].a")
	defer core.path_destroy(&one)
	two, _ := core.parse_path(".[0].b")
	defer core.path_destroy(&two)
	paths := []core.Path{one, two}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	refused := walktest.Failing_Alloc{inner = context.allocator, fail_all = true}
	context.allocator = mem.panic_allocator()
	context.temp_allocator = mem.panic_allocator()

	doc, err := dsv.scan(src, .Csv, one, allocator = alloc)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(core.span(&doc, doc.answers[0].node)), "3")
	core.destroy(&doc)
	doc, err = dsv.scan(src, .Csv, paths, allocator = alloc)
	walktest.expect_nil(t, err)
	testing.expect_value(t, len(doc.answers), 2)
	core.destroy(&doc)
	found := 0
	count :: proc(state: rawptr, a: core.Token_Answer) -> bool {
		(^int)(state)^ += int(a.outcome == .Found)
		return true
	}
	walktest.expect_nil(t, dsv.each_answer(src, .Csv, paths, &found, count, allocator = alloc))
	testing.expect_value(t, found, 2)
	testing.expect_value(t, len(track.allocation_map), 0)

	_, err = dsv.scan(src, .Csv, paths, allocator = walktest.failing_allocator(&refused))
	walktest.expect_kind(t, err, core.Path_Error_Kind.No_Memory)
}

// A dsv record reads by position and by name, and a cell reads as neither.
@(test)
presence_of_records :: proc(t: ^testing.T) {
	src := transmute([]u8)string("a,b\n1,2\n")
	full, _ := core.build(src, dsv.as(.Csv))
	defer core.destroy(&full)
	record, _ := core.element_of(&full, core.ROOT, 0)
	cell, at := core.element_of(&full, record, 1)
	testing.expect_value(t, at, core.Presence.Found)
	testing.expect_value(t, string(core.span(&full, cell)), "2")
	_, by_name := core.member_of(&full, cell, "a")
	testing.expect_value(t, by_name, core.Presence.Wrong_Kind)
	_, by_position := core.element_of(&full, cell, 0)
	testing.expect_value(t, by_position, core.Presence.Wrong_Kind)

	path, _ := core.parse_path(".[0].b")
	defer core.path_destroy(&path)
	doc, _ := dsv.scan(src, .Csv, path)
	defer core.destroy(&doc)
	partial, _ := core.element_of(&doc, core.ROOT, 0)
	_, kept := core.element_of(&doc, partial, 1)
	testing.expect(t, kept != .Wrong_Kind)
}

@(test)
path_set :: proc(t: ^testing.T) {
	src := transmute([]u8)string("a,b\n1,2\n# kept\n3,4\n")
	opts := dsv.Options{comment = '#'}
	cases := [?][3]string {
		{".[1].b", "9", "a,b\n1,2\n# kept\n3,9\n"},
		{".[-1][0]", "9", "a,b\n1,2\n# kept\n9,4\n"},
		{".[1].c", "9", "a,b,c\n1,2,\n# kept\n3,4,9\n"},
	}
	for c in cases {
		path, _ := core.parse_path(c[0])
		defer core.path_destroy(&path)
		out, err := dsv.set(src, .Csv, path, typed.Raw(c[1]), opts = opts)
		defer delete(out)
		testing.expectf(t, err == nil, "%s: %v", c[0], err)
		testing.expect_value(t, string(out), c[2])
	}
}

// The walks that count a text after a refused reservation and that read one record alone for several paths read each
// spec's text as a full read does.
@(test)
cold_walks_each_spec :: proc(t: ^testing.T) {
	first, _ := core.parse_path(".[0].a")
	other, _ := core.parse_path(".[1].b")
	defer core.path_destroy(&first)
	defer core.path_destroy(&other)
	paths := [2]core.Path{first, other}
	for spec in dsv.Spec {
		defer free_all(context.temp_allocator)
		sep := "\t" if spec == .Tsv else ","
		row := strings.concatenate({"1", sep, "2\n"}, context.temp_allocator)
		src := strings.concatenate({"a", sep, "b\n", strings.repeat(row, 3000, context.temp_allocator)}, context.temp_allocator)
		whole, werr := dsv.build(transmute([]u8)src, spec)
		walktest.expect_nil(t, werr)
		backing := make([]u8, len(whole.nodes) * size_of(core.Node) + 512)
		arena: mem.Arena
		mem.arena_init(&arena, backing)
		small, serr := dsv.build(transmute([]u8)src, spec, {}, .Last, mem.arena_allocator(&arena))
		walktest.expect_nil(t, serr)
		testing.expect_value(t, len(small.nodes), len(whole.nodes))
		core.destroy(&small)
		delete(backing)
		core.destroy(&whole)

		many, merr := dsv.scan(transmute([]u8)src, spec, paths[:])
		walktest.expect_nil(t, merr)
		if testing.expect_value(t, len(many.answers), 2) {
			for a in many.answers {
				testing.expect_value(t, string(core.span(&many, a.owner)), row)
			}
		}
		core.destroy(&many)
	}
}
