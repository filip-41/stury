package dsv_tests

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import dsv ".."

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
		case .Type_Mismatch:
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
	}
	for c in cases {
		path, perr := core.parse_path(c.path)
		defer core.path_destroy(&path)
		testing.expect_value(t, perr.kind, core.Path_Error_Kind.None)
		src := transmute([]u8)c.src
		doc, err := dsv.query(src, .Csv, path, {tolerate = {.Ragged}})
		defer core.destroy(&doc)
		testing.expectf(t, err.kind == .None, "%q: %v", c.path, err)
		testing.expectf(t, slice_equal(answer_texts(&doc, doc.answers), c.want), "scan %q: %v", c.path, doc.answers)

		full, berr := dsv.build(src, .Csv, {tolerate = {.Ragged}})
		defer core.destroy(&full)
		testing.expect_value(t, berr.kind, core.Document_Error_Kind.None)
		answers, qerr := dsv.query_document(&full, path)
		defer delete(answers)
		testing.expect_value(t, qerr.kind, core.Path_Error_Kind.None)
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
	doc, err := dsv.query(src, .Csv, path, {no_header = true})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Path_Error_Kind.None)
	testing.expect_value(t, string(core.span(&doc, doc.answers[0].node)), "4")
	testing.expect_value(t, core.length(&doc, core.ROOT), 2)
	record, at := core.element_of(&doc, core.ROOT, 1)
	testing.expect_value(t, at, core.Presence.Found)
	testing.expect_value(t, string(core.span(&doc, record)), "3,4\n")
	_, before := core.element_of(&doc, core.ROOT, 0)
	testing.expect_value(t, before, core.Presence.Not_Loaded)

	named, _ := core.parse_path(".[0].a")
	defer core.path_destroy(&named)
	bare, bad := dsv.query(src, .Csv, named, {no_header = true})
	defer core.destroy(&bare)
	testing.expect_value(t, bad.kind, core.Path_Error_Kind.None)
	testing.expect_value(t, bare.answers[0].outcome, core.Answer_Outcome.Type_Mismatch)

	headed := transmute([]u8)string("a,b\n1,2\n")
	h, herr := dsv.query(headed, .Csv, named)
	defer core.destroy(&h)
	testing.expect_value(t, herr.kind, core.Path_Error_Kind.None)
	rec, _ := core.element_of(&h, core.ROOT, 0)
	v, found := core.member_of(&h, rec, "a")
	testing.expect_value(t, found, core.Presence.Found)
	testing.expect_value(t, string(core.span(&h, v)), "1")
	_, other := core.member_of(&h, rec, "b")
	testing.expect_value(t, other, core.Presence.Not_Loaded)
}

// A `Partial` record's end comes from a walk that takes the text as the read did, and a stop may leave the record's end
// in text no walk judged.
@(test)
path_record_ends :: proc(t: ^testing.T) {
	path, _ := core.parse_path(".[0].a")
	defer core.path_destroy(&path)

	bare := transmute([]u8)string("a,b\n1,x\"y\n2,3\n")
	doc, err := dsv.query(bare, .Csv, path, {tolerate = {.Bare_Quote}})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Path_Error_Kind.None)
	testing.expect_value(t, string(core.span(&doc, doc.answers[0].owner)), "1,x\"y\n")

	open := transmute([]u8)string("a,b\n1,\"x")
	stopped, serr := dsv.query(open, .Csv, path, read = {stop_early = true})
	defer core.destroy(&stopped)
	testing.expect_value(t, serr.kind, core.Path_Error_Kind.None)
	testing.expect(t, stopped.stopped)
	testing.expect(t, strings.has_prefix(string(core.span(&stopped, stopped.answers[0].owner)), "1,"))
}

PATH_ROUNDS :: #config(PATH_ROUNDS, 2000)
PATH_FIXTURES :: #config(PATH_FIXTURES, "")

// Scan against query on a directory's CSV files, at records and cells sampled from each.
@(test)
path_fixtures :: proc(t: ^testing.T) {
	if PATH_FIXTURES == "" {
		return
	}
	entries, err := os.read_all_directory_by_path(PATH_FIXTURES, context.allocator)
	testing.expect_value(t, err, nil)
	defer os.file_info_slice_delete(entries, context.allocator)
	for entry in entries {
		if !strings.has_suffix(entry.name, ".csv") {
			continue
		}
		src, rerr := os.read_entire_file_from_path(entry.fullpath, context.allocator)
		testing.expect_value(t, rerr, nil)
		defer delete(src)
		full, berr := dsv.build(src, .Csv)
		defer core.destroy(&full)
		testing.expect_value(t, berr.kind, core.Document_Error_Kind.None)
		for _ in 0 ..< 12 {
			defer free_all(context.temp_allocator)
			column := rand.int_max(core.length(&full, 1) if core.length(&full, core.ROOT) > 0 else 1)
			lead := core.Step(core.All{}) if rand.int_max(3) == 0 else core.Step(core.Index(rand.int_max(core.length(&full, core.ROOT) + 1)))
			path := core.Path{steps = []core.Step{lead, core.Index(column)}}
			doc, qerr := dsv.query(src, .Csv, path)
			defer core.destroy(&doc)
			testing.expect_value(t, qerr.kind, core.Path_Error_Kind.None)
			answers, derr := dsv.query_document(&full, path)
			defer delete(answers)
			testing.expect_value(t, derr.kind, core.Path_Error_Kind.None)
			testing.expectf(t, slice_equal(answer_texts(&doc, doc.answers), answer_texts(&full, answers)), "%s %v", entry.name, path.steps)
		}
	}
}

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
		text = strings.trim_right(string(s.src[a.token.lo:a.hi]), "\r\n")
	case .Missing:
		text = "M"
	case .Type_Mismatch:
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
		doc, err := dsv.query(src, .Csv, paths)
		testing.expectf(t, err.kind == .None, "%q: %v", string(src), err)
		stopped, serr := dsv.query(src, .Csv, paths, read = {stop_early = true})
		testing.expectf(t, serr.kind == .None, "%q: %v", string(src), serr)
		full, berr := dsv.build(src, .Csv)
		testing.expect_value(t, berr.kind, core.Document_Error_Kind.None)
		answers, qerr := dsv.query_document(&full, paths)
		testing.expect_value(t, qerr.kind, core.Path_Error_Kind.None)
		stream := Stream{src, make([dynamic]string, context.temp_allocator)}
		eerr := dsv.each_answer(src, .Csv, paths, &stream, on_answer)
		testing.expect_value(t, eerr.kind, core.Path_Error_Kind.None)
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
		out, err := dsv.set(src, .Csv, c[0], c[1], opts)
		defer delete(out)
		testing.expectf(t, err == nil, "%s: %v", c[0], err)
		testing.expect_value(t, string(out), c[2])
	}
}
