package dsv_tests

import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"

// Reads of a delimited text in pieces, each window starting at the read's `keep`, against reads of the whole text.

// A text of the laws, with the header keys its paths name.
@(private = "file")
Piece_Text :: struct {
	name: string,
	text: string,
	keys: [2]string,
}

// The texts the laws read, each longer than a block or two so that windows end inside its records, its quoted cells
// and its header.
@(private = "file")
piece_texts :: proc() -> []Piece_Text {
	texts := make([dynamic]Piece_Text, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	rows :: proc(b: ^strings.Builder, n: int, row: string, tail := "") -> string {
		for i in 0 ..< n {
			fmt.sbprintf(b, row, i)
		}
		strings.write_string(b, tail)
		return strings.clone(strings.to_string(b^), context.temp_allocator)
	}
	strings.write_string(&b, "name,qty,note\n")
	append(&texts, Piece_Text{"plain", rows(&b, 14, "row%d,12,plain\n"), {"name", "qty"}})
	strings.builder_reset(&b)
	strings.write_string(&b, "name,qty,note\r\n")
	append(&texts, Piece_Text{"quoted", rows(&b, 9, "\"r%d, \"\"q\"\"\",-1.5e3,\"two\r\nlines\"\r\n"), {"name", "note"}})
	strings.builder_reset(&b)
	strings.write_string(&b, "# head\n#more\nname,qty\n")
	append(&texts, Piece_Text{"comments", rows(&b, 10, "# before %d\nr,1\n\n"), {"name", "qty"}})
	strings.builder_reset(&b)
	strings.write_string(&b, "\xEF\xBB\xBFnäme,qty\n")
	append(&texts, Piece_Text{"utf8", rows(&b, 12, "ünï%d,€€€\n"), {"näme", "qty"}})
	strings.builder_reset(&b)
	strings.write_string(&b, "a\tb\tc\n")
	append(&texts, Piece_Text{"tsv", rows(&b, 12, "x\\t%d\\\\\tline\\nend\t\\0\n"), {"a", "c"}})
	strings.builder_reset(&b)
	for c in 0 ..< 30 {
		fmt.sbprintf(&b, "column%d,", c)
	}
	strings.write_string(&b, "last\n")
	append(&texts, Piece_Text{"wide header", rows(&b, 3, "%d,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,x\n"), {"column0", "last"}})
	strings.builder_reset(&b)
	strings.write_string(&b, "a,b\n")
	append(&texts, Piece_Text{"ragged", rows(&b, 10, "%d,2,3,4\n1\n"), {"a", "b"}})
	strings.builder_reset(&b)
	strings.write_string(&b, "a,b\n")
	append(&texts, Piece_Text{"bare quote", rows(&b, 10, "x\"%d,y\"\"z\n"), {"a", "b"}})
	strings.builder_reset(&b)
	strings.write_string(&b, "a,b\n")
	append(&texts, Piece_Text{"bad utf8", rows(&b, 8, "\xC3%d\xFFx,\xE2\x82\n"), {"a", "b"}})
	strings.builder_reset(&b)
	strings.write_string(&b, "a;b,c\n")
	append(&texts, Piece_Text{"semicolons", rows(&b, 12, "%d;\"x;y\",1\n"), {"a", "b,c"}})
	strings.builder_reset(&b)
	strings.write_string(&b, "a,b\n")
	append(&texts, Piece_Text{"open quote", rows(&b, 9, "%d,\"x\n\"\n", "1,\"never closed\n"), {"a", "b"}})
	strings.builder_reset(&b)
	strings.write_string(&b, "a,b\n")
	append(&texts, Piece_Text{"lone cr", rows(&b, 9, "%d,x\n", "1,\r2\n"), {"a", "b"}})
	strings.builder_reset(&b)
	strings.write_string(&b, "a,b\n")
	append(&texts, Piece_Text{"too many", rows(&b, 9, "%d,x\n", "1,2,3\n4,5\n"), {"a", "b"}})
	strings.builder_reset(&b)
	strings.write_string(&b, "a,b,a\n")
	append(&texts, Piece_Text{"repeated header", rows(&b, 9, "%d,x,y\n", "1,\"never closed\n"), {"a", "b"}})
	append(&texts, Piece_Text{"header only", "only,a,header,line,which,runs,past,one,block,of,sixty,four,bytes,long", {"only", "long"}})
	append(&texts, Piece_Text{"empty", "", {"a", ""}})
	append(&texts, Piece_Text{"blank lines", "\n\r\n\n", {"a", ""}})
	append(&texts, Piece_Text{"comment foot", "#c\nname\n#only a foot past the header, held until the text ends\n#and another one", {"name", ""}})
	return texts[:]
}

// The option sets each text is read under.
@(private = "file")
piece_options :: proc() -> []tape.Options {
	return slice.clone(
		[]tape.Options {
			{},
			{format = dsv.Dsv_Options{comment = '#'}},
			{format = dsv.Dsv_Options{no_header = true}},
			{format = dsv.Dsv_Options{infer = true}},
			{dups = .Refuse},
			{tolerate = {.Ragged}},
			{tolerate = {.Bare_Quote}},
			{tolerate = {.Invalid_Utf8}},
			{format = dsv.Dsv_Options{delimiter = ';'}},
			{format = dsv.Dsv_Options{comment = '#', no_header = true, infer = true}, tolerate = {.Ragged, .Bare_Quote, .Invalid_Utf8}},
			{format = dsv.Dsv_Options{comment = '#'}, tolerate = {.Ragged, .Invalid_Utf8}, budget = {steps = 7}},
		},
		context.temp_allocator,
	)
}

// Paths into a text whose header holds `keys`: the root, its first, last and every record, and cells by key or place.
@(private = "file")
piece_paths :: proc(keys: []string, no_header: bool) -> [][]tape.Step {
	paths := make([dynamic][]tape.Step, context.temp_allocator)
	add :: proc(paths: ^[dynamic][]tape.Step, steps: ..tape.Step) {
		append(paths, slice.clone(steps, context.temp_allocator))
	}
	add(&paths)
	add(&paths, tape.Index(0))
	add(&paths, tape.Index(-1))
	add(&paths, tape.All{})
	if no_header {
		add(&paths, tape.Index(1), tape.Index(1))
		add(&paths, tape.All{}, tape.Index(0))
		add(&paths, tape.Index(-2), tape.Index(-1))
		return paths[:]
	}
	for k in keys {
		if k == "" {
			continue
		}
		add(&paths, tape.All{}, tape.Name(k))
		add(&paths, tape.Index(-1), tape.Name(k))
		add(&paths, tape.Index(2), tape.Name(k))
	}
	return paths[:]
}

// Reads `src` in pieces cut in two at the ends and at a sample of bytes from a seeded start, in three at a sample of
// pairs, and in windows of one byte, of a few bytes and of about a block. `-define:ROUNDS` widens the sample until a
// round of 16 reads every cut and every window size.
@(private = "file")
agree_in_pieces :: proc(t: ^testing.T, spec: dsv.Spec, src: []u8, opts: tape.Options, paths: [][]tape.Step, name: string) -> bool {
	reads, f := dsv.reads(spec), dsv.as(spec)
	step := max(1, len(src) / testkit.rounds(8))
	for k := rand.int_max(step); k < len(src); k += step {
		cuts := [1]int{k}
		testkit.pieces_agree(t, reads, f, src, opts, cuts[:], paths, name) or_return
	}
	for k in ([]int{0, len(src)}) {
		cuts := [1]int{k}
		testkit.pieces_agree(t, reads, f, src, opts, cuts[:], paths, name) or_return
	}
	if len(src) >= 8 {
		for _ in 0 ..< testkit.rounds(2) {
			i := rand.int_max(len(src))
			j := i + 1 + rand.int_max(len(src) - i)
			cuts := [2]int{i, j}
			testkit.pieces_agree(t, reads, f, src, opts, cuts[:], paths, name) or_return
		}
	}
	sizes := []int{1, 64, 65} if testkit.ROUNDS < 16 else []int{1, 2, 3, 7, 63, 64, 65, 67, 100}
	for size in sizes {
		testkit.pieces_agree(t, reads, f, src, opts, testkit.cuts_by(len(src), size), paths, name) or_return
	}
	return true
}

// Every text of every spec under every option set, read in pieces cut at a sample of bytes and in windows down to one
// byte: the same verdict and fault, document, answers and scans as the whole reads.
@(test)
pieces_agree_with_whole_reads :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x91ec)
	defer free_all(context.temp_allocator)
	for c in piece_texts() {
		src := transmute([]u8)c.text
		for spec in dsv.Spec {
			for opts in piece_options() {
				d, _ := opts.format.(dsv.Dsv_Options)
				keys := c.keys
				paths := piece_paths(keys[:], d.no_header)
				if !agree_in_pieces(t, spec, src, opts, paths, fmt.tprintf("%s %v %v", c.name, spec, opts)) {
					return
				}
			}
		}
	}
}

// Texts whose 64-byte blocks end at the state each window must carry: inside a quoted cell, between a CR and its LF,
// between the two quotes of a `""`, inside the header, inside a comment line, inside a UTF-8 sequence, after a TSV
// backslash, and at a record's end. Each is read in pieces at every cut and in windows of a few sizes around a block,
// of every size up to a block and a half at `-define:ROUNDS=16`.
@(test)
pieces_carry_each_state_across_a_window :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	// `pad` fills a record of a header `a,b` up to byte `at` of the text, so the text's next bytes start there.
	pad :: proc(at: int) -> string {
		return fmt.tprintf("a,b\n%s,", strings.repeat("x", at - 6, context.temp_allocator))
	}
	Case :: struct {
		name: string,
		spec: dsv.Spec,
		text: string,
		opts: tape.Options,
	}
	cases := []Case {
		{"quoted cell", .Csv, fmt.tprintf("%s\"in a quoted cell, with a\nline end\"\n1,2\n", pad(50)), {}},
		{"cr lf", .Csv, fmt.tprintf("%sy\r\n1,2\r\n", pad(62)), {}},
		{"cr lf in a quote", .Csv, fmt.tprintf("%s\"y\r\nz\"\n1,2\n", pad(61)), {}},
		{"doubled quote", .Csv, fmt.tprintf("%s\"q\"\"r\"\n1,2\n", pad(61)), {}},
		{"closing quote", .Csv, fmt.tprintf("%s\"qq\"\n1,2\n", pad(60)), {}},
		{"header", .Csv, fmt.tprintf("%s,b\n1,2\n", strings.repeat("h", 70, context.temp_allocator)), {}},
		{"quoted header", .Csv, fmt.tprintf("\"%s\",b\n1,2\n", strings.repeat("h", 70, context.temp_allocator)), {}},
		{"comment line", .Csv, fmt.tprintf("a,b\n1,2\n#%s\n3,4\n#foot\n", strings.repeat("c", 80, context.temp_allocator)), {format = dsv.Dsv_Options{comment = '#'}}},
		{"comment utf8", .Csv, "a,b\n1,2\n#€€€€ x\n3,4\n", {format = dsv.Dsv_Options{comment = '#'}}},
		{"comment bad utf8", .Csv, "a,b\n1,2\n#€€ \xe2\x82\n3,4\n", {format = dsv.Dsv_Options{comment = '#'}}},
		{"comment cut utf8", .Csv, "a,b\n1,2\n#€€\xe2\x82", {format = dsv.Dsv_Options{comment = '#'}}},
		{"unclosed quote", .Csv, "a,b\n1,2\n3,\"x\n4,5\r\n5,6\n", {}},
		{"comment quote", .Csv, fmt.tprintf("a,b\n1,2\n#%s\"\n3,4\n", strings.repeat("c", 58, context.temp_allocator)), {format = dsv.Dsv_Options{comment = '#'}}},
		{"utf8", .Csv, fmt.tprintf("%s€uro\n1,2\n", pad(62)), {}},
		{"utf8 lead", .Csv, fmt.tprintf("%s\xF0\x9F\x98\x80\n1,2\n", pad(63)), {}},
		{"bad utf8", .Csv, fmt.tprintf("%s\xE2\x82\n1,2\n", pad(62)), {}},
		{"bad utf8 lax", .Csv, fmt.tprintf("%s\xE2\x82\n1,2\n", pad(62)), {tolerate = {.Invalid_Utf8}}},
		{"backslash", .Tsv, fmt.tprintf("a\tb\n%s\t\\\\\\t\n1\t2\n", strings.repeat("x", 57, context.temp_allocator)), {}},
		{"bad escape", .Tsv, fmt.tprintf("a\tb\n%s\t\\q\n1\t2\n", strings.repeat("x", 58, context.temp_allocator)), {}},
		{"record end", .Csv, fmt.tprintf("%sy\n1,2\n", pad(63)), {}},
		{"lone cr", .Csv, fmt.tprintf("%sy\rz\n", pad(62)), {}},
		{"wide record", .Csv, fmt.tprintf("%sy,z\n", pad(62)), {}},
		{"short record", .Csv, fmt.tprintf("a,b,c\n%sy\n", strings.repeat("x", 58, context.temp_allocator)), {}},
		{"header past the frame", .Csv, fmt.tprintf("a,b%s\n1,2%s\n3,4%s\n", strings.repeat(",k", 140, context.temp_allocator), strings.repeat(",", 140, context.temp_allocator), strings.repeat(",", 140, context.temp_allocator)), {}},
	}
	sizes := make([dynamic]int, context.temp_allocator)
	for size in 1 ..= 100 {
		if testkit.ROUNDS >= 16 || size <= 2 || size == 63 || size == 64 || size == 65 {
			append(&sizes, size)
		}
	}
	for c in cases {
		src := transmute([]u8)c.text
		d, _ := c.opts.format.(dsv.Dsv_Options)
		keys := [2]string{"a", "b"}
		paths := piece_paths(keys[:], d.no_header)
		reads, f := dsv.reads(c.spec), dsv.as(c.spec)
		for k in 0 ..= len(src) {
			cuts := [1]int{k}
			if !testkit.pieces_agree(t, reads, f, src, c.opts, cuts[:], paths, c.name) {
				break
			}
		}
		for size in sizes {
			if !testkit.pieces_agree(t, reads, f, src, c.opts, testkit.cuts_by(len(src), size), paths, c.name) {
				break
			}
		}
	}
}

// A window that holds the first block and the bytes a sequence may run past it ends the first walk at the block's end:
// the next window starts at the open record's first byte, or at the three bytes before the block where a UTF-8
// sequence into it may begin.
@(test)
pieces_keep_the_open_record :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	text := fmt.tprintf("a,b\n%s,\"quoted, and\nlong\"\n1,2\n", strings.repeat("x", 50, context.temp_allocator))
	src := transmute([]u8)text
	p := dsv.Pieces{allocator = context.allocator}
	defer dsv.destroy(&p)
	testing.expect_value(t, dsv.validate(src[:70], .Csv, {pieces = &p}), nil)
	testing.expect(t, p.more)
	testing.expect_value(t, p.at, 70)
	testing.expect_value(t, p.keep, 4)
	p.from, p.last = p.keep, true
	testing.expect_value(t, dsv.validate(src[p.keep:], .Csv, {pieces = &p}), nil)
	testing.expect(t, !p.more)
	// Past the header, which the walk no longer needs, the window starts where the block's sequence may begin.
	q := dsv.Pieces{allocator = context.allocator}
	defer dsv.destroy(&q)
	plain := strings.repeat("1,2\n", 40, context.temp_allocator)
	testing.expect_value(t, dsv.validate(transmute([]u8)plain[:100], .Csv, {pieces = &q}), nil)
	testing.expect_value(t, q.keep, 61)
}

// A window that starts past what the last read keeps, or ends before where it read to, is refused.
@(test)
pieces_refuse_a_window_with_a_gap :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)strings.repeat("a,b\n", 40, context.temp_allocator)
	defer free_all(context.temp_allocator)
	p := dsv.Pieces{allocator = context.allocator}
	defer dsv.destroy(&p)
	testing.expect_value(t, dsv.validate(src[:100], .Csv, {pieces = &p}), nil)
	p.from = p.keep + 1
	err := dsv.validate(src[p.from:120], .Csv, {pieces = &p})
	testing.expect_value(t, err, dsv.Error(dsv.Piece_Gap{keep = p.keep, at = p.at, from = p.keep + 1, to = 120}))
}

// A find and a scan of a long text fed in small windows hold a bounded window, the header's keys copied out once,
// and answer as the whole reads.
@(test)
pieces_answer_a_long_text_in_bounded_windows :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "id,\"name\",note\n")
	for i in 0 ..< 20000 {
		fmt.sbprintf(&b, "%d,\"n%d\",x\n", i, i)
	}
	src := transmute([]u8)strings.to_string(b)
	path := []tape.Step{tape.Index(-1), tape.Name("name")}
	want, werr := dsv.find(src, path)
	testing.expect_value(t, werr, nil)
	seventh := []tape.Step{tape.Index(7), tape.Name("note")}
	paths := [][]tape.Step{path, seventh}
	d, derr := dsv.demand_of(paths)
	defer dsv.destroy(&d)
	testing.expect_value(t, derr, nil)
	whole, serr := dsv.scan(src, &d)
	defer dsv.destroy(&whole)
	testing.expect_value(t, serr, nil)
	WINDOW :: 4096
	{
		p := dsv.Pieces{allocator = context.allocator}
		defer dsv.destroy(&p)
		got: dsv.Span_Answer
		widest := 0
		for end := WINDOW; ; end = min(end + WINDOW, len(src)) {
			p.from, p.last = p.keep, end == len(src)
			widest = max(widest, end - int(p.keep))
			err: dsv.Error
			got, err = dsv.find(src[p.keep:end], path, .Csv, {}, {pieces = &p})
			testing.expect_value(t, err, nil)
			if !p.more {
				break
			}
		}
		testing.expect_value(t, got, want)
		testing.expect_value(t, string(p.text), "\"n19999\"")
		testing.expectf(t, widest <= 2 * WINDOW, "a window of %d bytes", widest)
	}
	{
		p := dsv.Pieces{allocator = context.allocator}
		defer dsv.destroy(&p)
		got: dsv.Document
		defer dsv.destroy(&got)
		widest := 0
		for end := WINDOW; ; end = min(end + WINDOW, len(src)) {
			p.from, p.last = p.keep, end == len(src)
			widest = max(widest, end - int(p.keep))
			err: dsv.Error
			dsv.destroy(&got)
			got, err = dsv.scan(src[p.keep:end], &d, .Csv, {}, {pieces = &p})
			testing.expect_value(t, err, nil)
			if !p.more {
				break
			}
		}
		testing.expect(t, testkit.same_documents(got, whole))
		testing.expectf(t, widest <= 2 * WINDOW, "a window of %d bytes", widest)
	}
}

// The path a window ends inside: the record being read and, under a header, the key of its cell being read.
@(test)
pieces_name_the_open_path :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	text := fmt.tprintf("id,name\n1,x\n2,%s\n", strings.repeat("y", 100, context.temp_allocator))
	src := transmute([]u8)text
	p := dsv.Pieces{allocator = context.allocator}
	defer dsv.destroy(&p)
	testing.expect_value(t, dsv.validate(src[:90], .Csv, {pieces = &p}), nil)
	testing.expect(t, p.more)
	testing.expect_value(t, len(p.open), 2)
	if len(p.open) == 2 {
		testing.expect_value(t, p.open[0], tape.Step(tape.Index(1)))
		testing.expect_value(t, p.open[1], tape.Step(tape.Name("name")))
	}
}

// The walk of a text in two pieces, cut in its middle, the second window from the first read's `keep`.
@(private = "file")
walk_in_pieces_of :: proc($S: dsv.Spec, $NO_HEADER: bool) -> testkit.Probe_Walk {
	return proc(src: []u8, opts: tape.Options, h: ^testkit.Probe, regs: ^hook.Regs) -> (u64, tape.Error) {
		p := tape.Pieces{allocator = context.allocator}
		defer tape.destroy(&p)
		o := opts
		o.format = dsv.Dsv_Options{no_header = NO_HEADER, comment = '#'}
		o.pieces = &p
		at, err, _ := dsv.walk(src[:len(src) / 2], S, o, h, regs, testkit.probe_hook)
		if err != nil || !p.more {
			return at, err
		}
		p.from, p.last = p.keep, true
		at, err, _ = dsv.walk(src[p.keep:], S, o, h, regs, testkit.probe_hook)
		return at, err
	}
}

// Every walk in pieces keeps the hook protocol: actions at every token, room and level growth, and `Budget.steps`.
@(test)
walks_in_pieces_keep_the_hook_protocol :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	texts := []string {
		"a,b\n1,2\n#c\n\"x\"\"y\",\n3,\"long cell that runs past the first block of the text, and on\"\n#foot\n",
		"a,b\r\n1,2\r\n3,4\r\n5,6\r\n7,8\r\n9,10\r\n11,12\r\n13,14\r\n15,16\r\n17,18\r\n19,20\r\n21,22",
		"#head\nheader,which,is,long,enough,to,end,past,a,block,of,sixty,four\n1,2,3,4,5,6,7,8,9,10,11,12,13\n",
	}
	testkit.hook_protocol(t, walk_in_pieces_of(.Csv, false), texts)
	testkit.hook_protocol(t, walk_in_pieces_of(.Csv, true), texts)
	testkit.hook_protocol(t, walk_in_pieces_of(.Tsv, false), {"a\tb\n1\t\\t\n2\t3\n4\t5\n6\t7\n8\t9\n10\t11\n12\t13\n14\t15\n16\t17\n18\t19\n"})
	testkit.hook_protocol(t, walk_in_pieces_of(.Plain, false), {"a,b\n1,2\n3,4\n5,6\n7,8\n9,10\n11,12\n13,14\n15,16\n17,18\n19,20\n21,22\n23,24"})
}

// A build in pieces gives the document so far: the rows read whole, the row the window ends inside with its cells so
// far, under the header, as the readers read them.
@(test)
builds_in_pieces_give_the_table_so_far :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	text := fmt.tprintf("id,name\n1,a\n2,%s,x\n", strings.repeat("b", 80, context.temp_allocator))
	src := transmute([]u8)text
	Case :: struct {
		opts: tape.Options,
		want: string,
	}
	for c in ([]Case {
			{{}, `[{"id":"1","name":"a"},{"id":"2"}]`},
			{{tolerate = {.Ragged}}, `[{"id":"1","name":"a"},{"id":"2"}]`},
			{{format = dsv.Dsv_Options{no_header = true}}, `[["id","name"],["1","a"],["2"]]`},
		}) {
		p := dsv.Pieces{so_far = true, allocator = context.allocator}
		defer dsv.destroy(&p)
		opts := c.opts
		opts.pieces = &p
		doc, err := dsv.build(src[:90], .Csv, opts)
		defer dsv.destroy(&doc)
		testing.expectf(t, err == nil && p.more && .Cut in doc.flags, "%v: %v", c.opts, err)
		testing.expectf(t, render(&doc) == c.want, "%v: %s", c.opts, render(&doc))
	}
}

// A cell past the header is a key with no bytes, named by its position, which a scan of the whole text and a scan in
// pieces read alike: its text is the position, it has no bytes as written, and a path names its cell by it.
@(test)
columns_past_the_header_are_named_by_their_place :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	text := fmt.tprintf("a\n%s\n1,2,3\n", strings.repeat("x", 80, context.temp_allocator))
	src := transmute([]u8)text
	opts := tape.Options{tolerate = {.Ragged}}
	path := []tape.Step{tape.Index(1), tape.Name("3")}
	a, err := dsv.find(src, path, .Csv, {}, opts)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(src[a.lo:a.hi]), "3")
	row := []tape.Step{tape.Index(1)}
	paths := [][]tape.Step{row}
	d, _ := dsv.demand_of(paths)
	defer dsv.destroy(&d)
	whole, _ := dsv.scan(src, &d, .Csv, {}, opts)
	defer dsv.destroy(&whole)
	p := dsv.Pieces{allocator = context.allocator}
	defer dsv.destroy(&p)
	held: dsv.Document
	defer dsv.destroy(&held)
	for end := 40; ; end = min(end + 40, len(src)) {
		p.from, p.last = p.keep, end == len(src)
		dsv.destroy(&held)
		held, err = dsv.scan(src[p.keep:end], &d, .Csv, {}, {tolerate = {.Ragged}, pieces = &p})
		testing.expect_value(t, err, nil)
		if !p.more {
			break
		}
	}
	testing.expect(t, .Held in held.flags)
	for doc in ([]^dsv.Document{&whole, &held}) {
		// The row's nodes end with the key of its third cell and the cell.
		key := dsv.Node_Index(len(doc.nodes) - 2)
		buf: [16]u8
		name, ok := dsv.node_text(doc, key, buf[:])
		raw, escaped := dsv.key_raw(doc, key)
		testing.expectf(t, ok && name == "3" && len(raw) == 0 && escaped, "%v: %q %q", doc.flags, name, raw)
	}
}

// Under `.Refuse` a repeated header name faults as it does in a whole read, at every cut, also when the header ends in
// the same walk as the first fault of a later record.
@(test)
pieces_refuse_a_repeated_header_name_before_a_later_fault :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	texts := []string{"a,a\n1\n", "a,a\n1,2\n3\n4,5\n", "a,b,a\n1,2,3\n\"x\n4\n"}
	opts := tape.Options{dups = .Refuse}
	paths := [][]tape.Step{{tape.All{}, tape.Name("a")}, {tape.Index(0)}}
	for csv in texts {
		for spec in dsv.Spec {
			text := csv
			if spec == .Tsv {
				text, _ = strings.replace_all(csv, ",", "\t", context.temp_allocator)
			}
			src := transmute([]u8)text
			reads, f := dsv.reads(spec), dsv.as(spec)
			whole, werr := dsv.build(src, spec, opts)
			tape.destroy(&whole)
			fault, _ := werr.(tape.Fault)
			testing.expectf(t, fault.kind == .Duplicate_Key, "%q %v: whole %v", text, spec, werr)
			for k in 0 ..= len(src) {
				cuts := [1]int{k}
				if !testkit.pieces_agree(t, reads, f, src, opts, cuts[:], paths, text) {
					return
				}
			}
		}
	}
}

// A text fed in windows of a block is handed to the reads once and a little over: each window starts at what the last
// read kept, the open record and the bytes a sequence at a block's end may run into, so no window restarts the text.
@(test)
pieces_hand_a_text_over_once :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "id,name,note\n")
	for i in 0 ..< 400 {
		fmt.sbprintf(&b, "%d,\"n%d\",\"two\nlines\"\n", i, i)
	}
	src := transmute([]u8)strings.to_string(b)
	WINDOW :: 64
	for spec in ([]dsv.Spec{.Csv}) {
		p := dsv.Pieces{allocator = context.allocator}
		defer dsv.destroy(&p)
		handed, windows := 0, 0
		for end := WINDOW; ; end += WINDOW {
			p.from, p.last = p.keep, end >= len(src)
			window := src[p.from:min(end, len(src))]
			handed += len(window)
			windows += 1
			testing.expect_value(t, dsv.validate(window, spec, {pieces = &p}), nil)
			if p.last || !p.more {
				break
			}
		}
		testing.expectf(t, handed <= len(src) + windows * 2 * PIECE_BYTES_KEPT, "%v: %d bytes handed over for a text of %d, in %d windows", spec, handed, len(src), windows)
	}
}

// The most a window may hold again from the last: the open record, here a line and a half, and the bytes a sequence at a
// block's end may run into.
@(private = "file")
PIECE_BYTES_KEPT :: 64
