package dsv_tests

import "core:math/rand"
import "core:mem"
import "core:strings"
import "core:testing"
import core "../../core"
import compose "../../core/compose"
import typed "../../core/typed"
import write "../../core/write"
import gen "gen"
import walktest "../../walktest"
import dsv ".."

build :: proc(src: string, $S: dsv.Spec, opts := dsv.Options{}, dups := core.Duplicates.Last) -> (core.Document, core.Error) {
	return core.build(transmute([]u8)src, dsv.as(S, opts), dups)
}

// `build` with the spec chosen at run time.
build_any :: proc(src: string, spec: dsv.Spec, opts := dsv.Options{}, dups := core.Duplicates.Last) -> (core.Document, core.Error) {
	switch spec {
	case .Csv:
		return build(src, .Csv, opts, dups)
	case .Tsv:
		return build(src, .Tsv, opts, dups)
	case .Plain:
		return build(src, .Plain, opts, dups)
	}
	return {}, {kind = .Bad_Value}
}

// The cell `cell` of record `rec`, counting from the first record after the header.
cell_node :: proc(doc: ^core.Document, rec, cell: int) -> core.Node_Index {
	r, _ := core.child_at(doc, core.ROOT, rec)
	c, _ := core.child_at(doc, r, cell)
	return c
}

// A headed text is an `Array` of `Object` records whose first child is the header row, an `Array` of `Key` cells. The
// header's cells are the document's keys, and a cell's node is its record's node plus one plus its column.
@(test)
node_layout :: proc(t: ^testing.T) {
	src := "a,b\n1,2\n"
	doc, err := build(src, .Csv)
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	testing.expect_value(t, len(doc.nodes), 7)
	if len(doc.nodes) != 7 {
		return
	}
	want := []walktest.Node_Want{
		{0, 7, .Array, .Value},
		{0, 3, .Array, .Key},
		{0, 1, .Plain, .Key},
		{2, 1, .Plain, .Key},
		{4, 3, .Object, .Value},
		{4, 1, .Plain, .Value},
		{6, 1, .Plain, .Value},
	}
	if !walktest.expect_nodes(t, &doc, want) {
		return
	}
	testing.expect_value(t, core.header_of(&doc), 1)
	testing.expect_value(t, doc.root_close, u64(len(src)))
	testing.expect_value(t, core.length(&doc, 0), 1)
	testing.expect_value(t, core.length(&doc, 1), 2)
	testing.expect_value(t, core.length(&doc, 4), 2)
	testing.expect_value(t, string(core.span(&doc, 0)), src)
	testing.expect_value(t, string(core.span(&doc, 1)), "a,b\n")
	testing.expect_value(t, string(core.span(&doc, 4)), "1,2\n")
	testing.expect_value(t, string(core.span(&doc, 6)), "2")
	testing.expect(t, core.key_equals(&doc, 3, "b"))
}

// A headed record is an `Object` whose cells `child_at` indexes by column, the root's member 0 is its first record, the
// header row skips no leading key, and a ragged record has no cell past its last. Without a header a record is an
// `Array` of cells.
@(test)
child_at_reader :: proc(t: ^testing.T) {
	doc, err := build("a,b,c\n1,2,3\n", .Csv)
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	rec := core.Node_Index(5)
	for i in 0 ..< 3 {
		v, ok := core.child_at(&doc, rec, i)
		testing.expect(t, ok)
		testing.expect_value(t, v, rec + 1 + core.Node_Index(i))
		s, _ := core.text(&doc, v, nil)
		testing.expect_value(t, s, string([]u8{u8('1' + i)}))
	}
	for i in ([]int{3, -1}) {
		_, ok := core.child_at(&doc, rec, i)
		testing.expect(t, !ok)
	}
	first, has := core.child_at(&doc, 0, 0)
	testing.expect(t, has && first == rec)
	_, has = core.child_at(&doc, 0, 1)
	testing.expect(t, !has)
	for i in 0 ..< 3 {
		key, ok := core.child_at(&doc, core.header_of(&doc), i)
		testing.expect(t, ok && key == core.header_of(&doc) + 1 + core.Node_Index(i))
	}
	_, has = core.child_at(&doc, core.header_of(&doc), 3)
	testing.expect(t, !has)

	ragged, rerr := build("a,b,c\n1,2\n", .Csv, {tolerate = {.Ragged}})
	defer core.destroy(&ragged)
	walktest.expect_nil(t, rerr)
	_, has = core.child_at(&ragged, rec, 1)
	testing.expect(t, has)
	_, has = core.child_at(&ragged, rec, 2)
	testing.expect(t, !has)
	v, ok := core.member(&ragged, rec, "b")
	testing.expect(t, ok && v == rec + 2)

	plain, perr := build("1,2\n3,4\n", .Csv, {no_header = true})
	defer core.destroy(&plain)
	walktest.expect_nil(t, perr)
	r, _ := core.child_at(&plain, 0, 0)
	testing.expect_value(t, plain.nodes[r].kind, core.Kind.Array)
	testing.expect_value(t, core.length(&plain, 0), 2)
	testing.expect_value(t, core.length(&plain, r), 2)
	testing.expect_value(t, cell_node(&plain, 0, 1), r + 2)
	_, has = core.child_at(&plain, r, 2)
	testing.expect(t, !has)
}

// Checks that every container's span reaches its `End` and its length is its member count, over CSV and TSV texts,
// headed and unheaded, with quoted cells, CRLF and a last record with no line end.
@(test)
container_spans :: proc(t: ^testing.T) {
	texts := []string{
		"a,b\n1,2\n",
		"a,b\r\n1,2\r\n3,4",
		"a,b\n1,2",
		"a\n\"x,y\"\n",
		"a\tb\n1\t2\n",
		"1,2\n3,4\n",
		"1\t2\n3\t4",
		"",
		"\n\n",
	}
	for text in texts {
		for no_header in ([]bool{false, true}) {
			check_table(t, text, .Csv, no_header)
			check_table(t, text, .Tsv, no_header)
		}
	}
}

check_table :: proc(t: ^testing.T, text: string, $S: dsv.Spec, no_header: bool) {
	src := transmute([]u8)text
	log := new(walktest.Log)
	defer free(log)
	regs: core.Hook_Regs
	_, fault := dsv.walk(src, 0, S, {no_header = no_header}, log, &regs, walktest.log_hook)
	doc, err := dsv.build(src, S, {no_header = no_header})
	defer core.destroy(&doc)
	if !testing.expectf(t, (fault == nil) == (err == nil), "%q %v %v: walk %v, build %v", text, S, no_header, fault, err) {
		return
	}
	if err == nil {
		walktest.check_containers(t, &doc, log.tokens[:log.n])
	}
}

Number_Want :: enum {
	No,
	Int,
	Float,
}

Cell_Case :: struct {
	src:  string,
	spec: dsv.Spec,
	opts: dsv.Options,
	rec:  int,
	cell: int,
	text: string,
	kind: core.Kind, // what `core.kind` reads
	num:  Number_Want,
}

// Every case reads one cell as text, as a kind and as a number. A text is decoded, a quoted or escaped or ill-formed cell
// is text and no number, an unquoted empty cell is `.Null`, and `infer` reads `true` and `false` as their kinds and a
// JSON number as `.Number`.
@(test)
cell_reads :: proc(t: ^testing.T) {
	infer := dsv.Options{infer = true}
	utf8 := dsv.Options{tolerate = {.Invalid_Utf8}}
	both := dsv.Options{tolerate = {.Invalid_Utf8}, infer = true}
	row := "a,b,c,d,e,f\n,true,false,1.5,007,\"1\"\n"
	for c in ([]Cell_Case{
		{"a,b\n\"x,y\",\"say \"\"hi\"\"\"\n", .Csv, {}, 0, 0, "x,y", .String, .No},
		{"a,b\n\"x,y\",\"say \"\"hi\"\"\"\n", .Csv, {}, 0, 1, "say \"hi\"", .String, .No},
		{"a\tb\nx\\ty\tz\\\\w\n", .Tsv, {}, 0, 0, "x\ty", .String, .No},
		{"a\tb\nx\\ty\tz\\\\w\n", .Tsv, {}, 0, 1, "z\\w", .String, .No},
		{row, .Csv, {}, 0, 0, "", .Null, .No},
		{row, .Csv, {}, 0, 1, "true", .String, .No},
		{"a\tb\n\t1\n", .Tsv, {}, 0, 0, "", .Null, .No},
		{row, .Csv, infer, 0, 0, "", .Null, .No},
		{row, .Csv, infer, 0, 1, "true", .True, .No},
		{row, .Csv, infer, 0, 2, "false", .False, .No},
		{row, .Csv, infer, 0, 3, "1.5", .Number, .Float},
		{row, .Csv, infer, 0, 4, "007", .String, .No},
		{row, .Csv, infer, 0, 5, "1", .String, .No},
		{"a,b\n\"1\",\"x\"\"y\"\n", .Csv, infer, 0, 1, "x\"y", .String, .No},
		{"a\n\"\"\n", .Csv, infer, 0, 0, "", .String, .No},
		{"a\n1\\02\nx\\ty\n", .Tsv, infer, 0, 0, "1\x002", .String, .No},
		{"a\n1\\02\nx\\ty\n", .Tsv, infer, 1, 0, "x\ty", .String, .No},
		{"a\nx\xffy\n", .Csv, utf8, 0, 0, "x\uFFFdy", .String, .No},
		{"a\tb\nx\xffy\tz\n", .Tsv, utf8, 0, 0, "x\uFFFdy", .String, .No},
		{"a,b\n1,\"x\xffy\"\n", .Csv, both, 0, 0, "1", .Number, .Int},
		{"a,b\n1,\"x\xffy\"\n", .Csv, both, 0, 1, "x\uFFFdy", .String, .No},
		{"a\n2\nx\xffy\n", .Tsv, utf8, 0, 0, "2", .String, .Int},
		{"a\n2\nx\xffy\n", .Tsv, utf8, 1, 0, "x\uFFFdy", .String, .No},
		{"1,2,", .Csv, {no_header = true, infer = true}, 0, 2, "", .Null, .No},
		{"a,b\n42,\"7\"\n", .Csv, {}, 0, 0, "42", .String, .Int},
		{"a,b\n42,\"7\"\n", .Csv, {}, 0, 1, "7", .String, .No},
		{"a;b\n1;2,3\n", .Csv, {delimiter = ';'}, 0, 1, "2,3", .String, .No},
		{"a|b\n\"q\"|x\\ty\n", .Plain, {delimiter = '|'}, 0, 0, "\"q\"", .String, .No},
		{"a|b\n\"q\"|x\\ty\n", .Plain, {delimiter = '|'}, 0, 1, "x\\ty", .String, .No},
		{"a,b\nx\\ty,z\n", .Tsv, {delimiter = ','}, 0, 0, "x\ty", .String, .No},
		{"a\"b\n1\"2\n", .Plain, {delimiter = '"'}, 0, 1, "2", .String, .Int},
		{"a,b\n\"x\n#y\",z#w\n", .Csv, {comment = '#'}, 0, 0, "x\n#y", .String, .No},
		{"a,b\n\"x\n#y\",z#w\n", .Csv, {comment = '#'}, 0, 1, "z#w", .String, .No},
	}) {
		doc, err := build_any(c.src, c.spec, c.opts)
		defer core.destroy(&doc)
		if !testing.expectf(t, err == nil, "%q: %v", c.src, err) {
			return
		}
		node := cell_node(&doc, c.rec, c.cell)
		buf: [16]u8
		s, ok := core.text(&doc, node, buf[:])
		n, is_num := core.number(&doc, node)
		testing.expectf(t, ok && s == c.text, "%q %d,%d: text %q, want %q", c.src, c.rec, c.cell, s, c.text)
		testing.expectf(t, core.kind(&doc, node) == c.kind, "%q %d,%d: kind %v, want %v", c.src, c.rec, c.cell, core.kind(&doc, node), c.kind)
		testing.expectf(t, is_num == (c.num != .No) && (!is_num || (c.num == .Int) == (n.kind == .Int)), "%q %d,%d: number %v %v, want %v", c.src, c.rec, c.cell, n, is_num, c.num)
		if c.num == .Float {
			testing.expect_value(t, n.bits, 0x3ff8000000000000)
		}
	}
}

// A quoted empty cell and an escaped TSV cell are text in an allocator that frees nothing as in one that frees, and
// `text` fills the caller's buffer or refuses a short one while `text_clone` returns what the caller frees. A read that
// decodes a cell allocates nothing from the document's allocator.
@(test)
text_owned :: proc(t: ^testing.T) {
	doc, err := build("a\n\"\"\nx\\ty\nxy\n", .Tsv)
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	for want, i in ([]string{"\"\"", "x\ty", "xy"}) {
		cell := cell_node(&doc, i, 0)
		_, ok := core.text(&doc, cell, nil)
		testing.expectf(t, ok == (want != "x\ty"), "text(nil) of %q: %v", want, ok)
		buf: [8]u8
		_, ok = core.text(&doc, cell, buf[:1])
		testing.expectf(t, ok == (want != "x\ty"), "text(1 byte) of %q: %v", want, ok)
		s, cok := core.text_clone(&doc, cell, context.temp_allocator)
		testing.expectf(t, cok && s == want, "%q %v", s, cok)
		delete(s, context.temp_allocator)
	}

	quoted, qerr := build("a\n\"\"\n", .Csv)
	defer core.destroy(&quoted)
	walktest.expect_nil(t, qerr)
	arena: mem.Arena
	backing: [64]u8
	mem.arena_init(&arena, backing[:])
	for alloc in ([]mem.Allocator{mem.arena_allocator(&arena), context.allocator}) {
		s, ok := core.text_clone(&quoted, cell_node(&quoted, 0, 0), alloc)
		testing.expectf(t, ok && s == "", "clone: %q %v", s, ok)
		delete(s, alloc)
	}

	long := strings.concatenate({"n\n\"", strings.repeat("1234567890", 10, context.temp_allocator), "\"\n"}, context.temp_allocator)
	big := make([]u8, 1 << 20, context.allocator)
	defer delete(big)
	mem.arena_init(&arena, big)
	rd, rerr := dsv.build(transmute([]u8)long, .Csv, {infer = true}, .Last, mem.arena_allocator(&arena))
	defer core.destroy(&rd)
	walktest.expect_nil(t, rerr)
	before := arena.offset
	_, _ = core.number(&rd, cell_node(&rd, 0, 0))
	_ = core.kind(&rd, cell_node(&rd, 0, 0))
	testing.expect_value(t, arena.offset, before)
}

Key_Case :: struct {
	src:  string,
	spec: dsv.Spec,
	opts: dsv.Options,
	key:  int,
	text: string,
	span: string, // of the key cell, when given
}

// A header cell is a key: its span holds its quotes, its text drops them, `number` refuses it and `core.kind` reads it as
// `.String`. A key whose text starts and ends with one quote byte is compared by its text, an ill-formed byte in it reads
// as U+FFFD, and `key_equals` and `member` agree with `text`.
@(test)
key_reads :: proc(t: ^testing.T) {
	utf8 := dsv.Options{tolerate = {.Invalid_Utf8}}
	for c in ([]Key_Case{
		{"\"a\",\"b\"\n1,2\n", .Csv, {}, 0, "a", "\"a\""},
		{"12.5,7\n1,2\n", .Csv, {infer = true}, 0, "12.5", "12.5"},
		{"\xffh\tb\n1\t2\n", .Tsv, utf8, 0, "\uFFFdh", ""},
		{"a\nx\xffy\n", .Csv, utf8, 0, "a", ""},
		{"'q'\n1\n", .Csv, {}, 0, "'q'", ""},
		{"\"q\"\n1\n", .Tsv, {}, 0, "\"q\"", ""},
		{"'q'\tx\n1\t2\n", .Tsv, {}, 0, "'q'", ""},
		{"\"q\"\tq\n1\t2\n", .Tsv, {}, 0, "\"q\"", ""},
		{"\"q\"\tq\n1\t2\n", .Tsv, {}, 1, "q", ""},
		{"a,,c\n1,2,3\n", .Csv, {}, 1, "", ""},
	}) {
		doc, err := build_any(c.src, c.spec, c.opts)
		defer core.destroy(&doc)
		if !testing.expectf(t, err == nil, "%q: %v", c.src, err) {
			return
		}
		key := core.header_of(&doc) + 1 + core.Node_Index(c.key)
		buf: [16]u8
		s, ok := core.text(&doc, key, buf[:])
		_, is_num := core.number(&doc, key)
		testing.expectf(t, ok && s == c.text, "%q: key text %q want %q", c.src, s, c.text)
		testing.expect(t, core.key_equals(&doc, key, c.text) && doc.nodes[key].role == .Key && !is_num && core.kind(&doc, key) == .String)
		if c.span != "" {
			testing.expect_value(t, string(core.span(&doc, key)), c.span)
		}
		rec, _ := core.child_at(&doc, 0, 0)
		v, found := core.member(&doc, rec, c.text, .First)
		testing.expectf(t, found && v == rec + 1 + core.Node_Index(c.key), "%q: member(%q) -> %v %v", c.src, c.text, v, found)
	}
	doc, _ := build("a\nx\xffy\n", .Csv, {tolerate = {.Invalid_Utf8}})
	defer core.destroy(&doc)
	testing.expect(t, !core.key_equals(&doc, core.header_of(&doc) + 1, "x\uFFFdy"))
}

Dup_Case :: struct {
	src:   string,
	spec:  dsv.Spec,
	opts:  dsv.Options,
	kind:  core.Document_Error_Kind,
	at:    int,
}

// A refusing build reports a repeated header name at the later cell, also when the text has no record or a later record
// faults, and an empty cell repeats like any other. A TSV cell written `\0` and a raw NUL are the same name, and its quotes
// are cell bytes.
@(test)
refuse_duplicates :: proc(t: ^testing.T) {
	dup := core.Document_Error_Kind.Duplicate_Key
	for c in ([]Dup_Case{
		{"a,a\n1,2\n", .Csv, {}, dup, 2},
		{"\"q\"\t\"q\"\n1\t2\n", .Tsv, {}, dup, 4},
		{"a,a\n1,2\n3,\"x\n", .Csv, {}, dup, 2},
		{",\n1,2\n3,\"x\n", .Csv, {}, dup, 1},
		{"a,a\n", .Csv, {}, dup, 2},
		{",", .Csv, {}, dup, 1},
		{"a,", .Csv, {}, .None, 0},
		{"a,,b", .Csv, {}, .None, 0},
		{"\\0\t\x00", .Tsv, {}, dup, 3},
		{"\\0\t\x00\n", .Tsv, {}, dup, 3},
		{"\\0\t\x00\n1\t2\n", .Tsv, {}, dup, 3},
		{"\\0\t\\0\n1\t2\n", .Tsv, {}, dup, 3},
		{"\\0\t\\0", .Tsv, {}, dup, 3},
		{"3,b\n1,2,x\n", .Csv, {tolerate = {.Ragged}}, dup, 0},
	}) {
		doc, err := build_any(c.src, c.spec, c.opts, .Refuse)
		defer core.destroy(&doc)
		if c.kind == .None {
			walktest.expect_nil(t, err)
		} else if walktest.expect_kind(t, err, c.kind) {
			testing.expectf(t, int(walktest.at_of(err)) == c.at && len(doc.nodes) == 0, "%q: %v, want at %d", c.src, err, c.at)
		}
	}
}

// A header of more cells than the key table on the stack holds, or of `MAX_CHILDREN` cells or more, builds, refusing
// duplicates or not. The wide header saturates its row's count and every record's, so the build counts each record's
// cells again. A repeat past 32 keys found before a later fault carries `.No_Memory` when the key table cannot allocate.
@(test)
wide_headers :: proc(t: ^testing.T) {
	line :: proc(b: ^strings.Builder, count: int, cell: proc(b: ^strings.Builder, i: int)) {
		for i in 0 ..< count {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			cell(b, i)
		}
	}
	names :: proc(b: ^strings.Builder, i: int) {
		strings.write_byte(b, 'a' + u8(i / 26))
		strings.write_byte(b, 'a' + u8(i % 26))
	}
	ones :: proc(b: ^strings.Builder, _: int) {
		strings.write_byte(b, '1')
	}
	for count in ([]int{65, 70}) {
		for with_record in ([]bool{false, true}) {
			b := strings.builder_make(context.temp_allocator)
			line(&b, count, names)
			if with_record {
				strings.write_byte(&b, '\n')
				line(&b, count, ones)
			}
			doc, err := build(strings.to_string(b), .Csv, {}, .Refuse)
			testing.expectf(t, err == nil, "%d cells, record %v: %v", count, with_record, err)
			core.destroy(&doc)
		}
	}
	for count in ([]int{int(core.MAX_CHILDREN), int(core.MAX_CHILDREN) + 1}) {
		b := strings.builder_make(context.temp_allocator)
		line(&b, count, proc(b: ^strings.Builder, i: int) {
			strings.write_byte(b, 'a' + u8(i % 26))
		})
		for _ in 0 ..< 2 {
			strings.write_byte(&b, '\n')
			line(&b, count, ones)
		}
		doc, err := build(strings.to_string(b), .Csv)
		defer core.destroy(&doc)
		walktest.expect_nil(t, err)
		testing.expect_value(t, core.length(&doc, core.ROOT), 2)
		for k in 0 ..< 2 {
			rec, ok := core.child_at(&doc, core.ROOT, k)
			testing.expect(t, ok)
			testing.expect_value(t, core.length(&doc, rec), count)
			last, lok := core.child_at(&doc, rec, count - 1)
			testing.expect(t, lok && last == rec + core.Node_Index(count))
		}
	}

	b := strings.builder_make(context.temp_allocator)
	line(&b, 33, proc(b: ^strings.Builder, i: int) {
		strings.write_byte(b, 'a' if i == 32 else 'a' + u8(i) if i < 26 else 'A' + u8(i - 26))
	})
	strings.write_string(&b, "\n\"x")
	// Allocations 0 to 2 are the header's token buffer, the open stack and the node array, and 3 the key table that 33
	// cells need. Every later one fails too, so the build's second try fails as well.
	f := walktest.Failing_Alloc{inner = context.allocator, fail_at = 3, fail_on = true}
	doc, err := dsv.build(transmute([]u8)strings.to_string(b), .Csv, {}, .Refuse, walktest.failing_allocator(&f))
	walktest.expect_kind(t, err, core.Document_Error_Kind.No_Memory)
	core.destroy(&doc)
}

// A record of the wrong width fails the build with `.Walk` and a `Bad_Width` fault in `inner`, which `render` names.
@(test)
errors :: proc(t: ^testing.T) {
	doc, err := build("a,b\n1,2,3\n", .Csv)
	walktest.expect_kind(t, err, core.Document_Error_Kind.Walk)
	fault, _ := walktest.fault_of(err).?
	testing.expect_value(t, fault.kind, core.Fault_Kind.Bad_Width)
	testing.expect_value(t, fault.at, 7)
	testing.expect_value(t, len(doc.nodes), 0)
	b := strings.builder_make(context.temp_allocator)
	core.render(strings.to_writer(&b), transmute([]u8)string("a,b\n1,2,3\n"), err)
	testing.expect_value(t, strings.to_string(b), "2:4: Record has more fields than the first record")

	_, err = build("a,b\n1\n", .Csv)
	walktest.expect_kind(t, err, core.Document_Error_Kind.Walk)
	fault, _ = walktest.fault_of(err).?
	testing.expect_value(t, fault.kind, core.Fault_Kind.Bad_Width)
}

// `number` refuses a container and a key, and `text` and `key_equals` give no text or false for a container.
@(test)
readers_refuse_containers :: proc(t: ^testing.T) {
	doc, err := build(",,\n,,\n", .Csv, {no_header = true})
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	rec, _ := core.child_at(&doc, 0, 0)
	for node in ([]core.Node_Index{0, rec}) {
		_, is_num := core.number(&doc, node)
		_, is_int := core.int_value(&doc, node)
		_, has_text := core.text(&doc, node, nil)
		testing.expect(t, !is_num && !is_int && !has_text)
	}
}

Member_Case :: struct {
	src:   string,
	opts:  dsv.Options,
	name:  string,
	first: int, // the column `.First` returns, 1-based
	last:  int,
	count: int, // what `members_named` yields
}

// With repeated names `.First` returns the first column and `.Last` the last, and `members_named` returns every one. A
// wide record's third column and a header cell named `"3"` share a name, and an empty header cell names its column.
@(test)
duplicate_names :: proc(t: ^testing.T) {
	ragged := dsv.Options{tolerate = {.Ragged}}
	for c in ([]Member_Case{
		{"a,a\n1,2\n", {}, "a", 1, 2, 2},
		{"3,b\n1,2,x\n", ragged, "3", 1, 3, 2},
		{"a,,c\n1,2,3\n", {}, "", 2, 2, 1},
		{"a,b,c\n1,2\n", ragged, "b", 2, 2, 1},
		{"a,b,c\n1,2\n", ragged, "c", 0, 0, 0},
		{"a,b\n1,2,3,4\n5\n", ragged, "4", 4, 4, 1},
	}) {
		doc, err := build(c.src, .Csv, c.opts)
		defer core.destroy(&doc)
		walktest.expect_nil(t, err)
		rec, _ := core.child_at(&doc, 0, 0)
		v, ok := core.member(&doc, rec, c.name, .First)
		testing.expectf(t, ok == (c.first != 0) && (!ok || v == rec + core.Node_Index(c.first)), "%q %q first: %v %v", c.src, c.name, v, ok)
		v, ok = core.member(&doc, rec, c.name, .Last)
		testing.expectf(t, ok == (c.last != 0) && (!ok || v == rec + core.Node_Index(c.last)), "%q %q last: %v %v", c.src, c.name, v, ok)
		n := 0
		it := core.members_named(&doc, rec, c.name)
		for _, more := core.member_next(&it); more; _, more = core.member_next(&it) {
			n += 1
		}
		testing.expectf(t, n == c.count, "%q %q: %d members, want %d", c.src, c.name, n, c.count)
	}
	doc, _ := build("a,b\n1,2,3,4\n5\n", .Csv, {tolerate = {.Ragged}})
	defer core.destroy(&doc)
	buf: [8]u8
	text, _ := core.text(&doc, core.header_of(&doc) + 3, buf[:])
	testing.expect_value(t, text, "3")
	testing.expect_value(t, core.length(&doc, cell_node(&doc, 0, 0) - 1), 4)
}

Shape_Case :: struct {
	src:     string,
	opts:    dsv.Options,
	keys:    core.Node_Index, // `shared_keys`
	records: int,
	span:    string, // of the root, when given
}

// A header-only text keeps its header row and no record, a text with no record has no header and one root node, and a
// comment line is no record, also before the header and at the text's end.
@(test)
document_shapes :: proc(t: ^testing.T) {
	comment := dsv.Options{comment = '#'}
	for c in ([]Shape_Case{
		{"a,b\n", {}, 1, 0, "a,b\n"},
		{"", {}, 0, 0, ""},
		{"\n\n", {}, 0, 0, "\n\n"},
		{"\r\n", {}, 0, 0, "\r\n"},
		{"# a,b\n# another\n\na,b\n1,2\n# tail\n", comment, 1, 1, ""},
		{"# head\na,b\n1,2\n# no line end", comment, 1, 1, ""},
		{"\xef\xbb\xbfa,b\r\n1,2\r\n3,4", {}, 1, 2, "\xef\xbb\xbfa,b\r\n1,2\r\n3,4"},
	}) {
		doc, err := build(c.src, .Csv, c.opts)
		defer core.destroy(&doc)
		testing.expectf(t, err == nil && core.header_of(&doc) == c.keys && core.length(&doc, 0) == c.records, "%q: %v, header %d, %d records", c.src, err, core.header_of(&doc), core.length(&doc, 0))
		if c.keys == 0 {
			testing.expect_value(t, len(doc.nodes), 1)
		}
		if c.span != "" || c.src == "" {
			testing.expect_value(t, string(core.span(&doc, 0)), c.span)
		}
	}
	doc, _ := build("a,b\n", .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, string(core.span(&doc, 1)), "a,b\n")
	testing.expect_value(t, core.length(&doc, core.header_of(&doc)), 2)

	// With a BOM, CRLF and no final line end, a header row and each record span their source bytes after the BOM.
	bom, _ := build("\xef\xbb\xbfa,b\r\n1,2\r\n3,4", .Csv)
	defer core.destroy(&bom)
	testing.expect_value(t, string(core.span(&bom, core.header_of(&bom))), "a,b\r\n")
	testing.expect_value(t, bom.nodes[0].spelling, u16(2))
	for rec, i in ([]string{"1,2\r\n", "3,4"}) {
		node, _ := core.child_at(&bom, 0, i)
		testing.expect_value(t, string(core.span(&bom, node)), rec)
		v, ok := core.member(&bom, node, "b")
		testing.expect(t, ok && v == node + 2)
	}
}

// For every column of 100 generated CSV and TSV texts, `key_equals` and `member` find the key's own text. The private
// suite runs the same law on 1000 texts.
@(test)
generated_keys_agree :: proc(t: ^testing.T) {
	state := rand.create(3)
	context.random_generator = rand.default_random_generator(&state)
	text: [dynamic]u8
	defer delete(text)
	for round in 0 ..< 100 {
		tsv := round % 2 == 1
		gen.text(&text, tsv)
		no_header := round % 3 == 0
		doc, err := build_any(string(text[:]), .Tsv if tsv else .Csv, {no_header = no_header})
		if err != nil {
			core.destroy(&doc)
			continue
		}
		// Each header cell's text is found by `key_equals`, and `member` returns a cell of the record whose header cell
		// decodes to that text, at or before this column.
		root: if !no_header && core.header_of(&doc) != 0 {
			col := 0
			it := core.children(&doc, core.header_of(&doc))
			for {
				key, more := core.child_next(&it)
				if !more {
					break
				}
				buf: [256]u8
				kt, kok := core.text(&doc, key, buf[:])
				if !testing.expectf(t, kok, "round %d: key text failed", round) {
					break root
				}
				if !testing.expectf(t, core.key_equals(&doc, key, kt), "round %d: key_equals disagrees with text for %q", round, kt) {
					break root
				}
				recs := core.children(&doc, 0)
				for {
					rec, has_rec := core.child_next(&recs)
					if !has_rec {
						break
					}
					if col >= core.length(&doc, rec) {
						continue
					}
					mv, mok := core.member(&doc, rec, kt, .First)
					// A repeated name returns the first column, whose header cell decodes to the same text.
					ok := mok && mv > rec && mv <= rec + 1 + core.Node_Index(col) && core.key_equals(&doc, core.header_of(&doc) + 1 + (mv - rec - 1), kt)
					if !testing.expectf(t, ok, "round %d: member %q -> %v %v, column %d of record %d", round, kt, mv, mok, col, rec) {
						break root
					}
				}
				col += 1
			}
		}
		core.destroy(&doc)
		free_all(context.temp_allocator)
	}
}

// `dsv.commit` writes the document's own spec and refuses another one before it splices.
@(test)
commit_refuses_another_spec :: proc(t: ^testing.T) {
	doc, err := build("a\nx\\ty\n", .Tsv)
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	walktest.expect_nil(t, write.set(&list, cell_node(&doc, 0, 0), typed.Raw("z")))
	out, _, cerr := compose.commit(&list)
	testing.expectf(t, cerr == nil && string(out) == "a\nz\n", "commit: %v %q", cerr, out)
	delete(out)
	_, _, bad := compose.commit(&list, dsv.as(.Csv))
	walktest.expect_kind(t, bad, core.Document_Error_Kind.Bad_Spec)
}

// A bad option is refused by `validate` and `build` for each spec: CSV refuses a quote as delimiter or comment, CR, LF or
// a non-ASCII byte as either, and a comment equal to the delimiter. TSV refuses a backslash as delimiter or comment and
// `t`, `n`, `r` or `0` as delimiter. Plain refuses CR, LF and a non-ASCII byte, and a comment equal to the delimiter.
@(test)
bad_options :: proc(t: ^testing.T) {
	for opts in ([]dsv.Options{
		{delimiter = '"'},
		{comment = '"'},
		{delimiter = '\n'},
		{delimiter = '\r'},
		{delimiter = 0x80},
		{delimiter = ';', comment = ';'},
		{comment = 0x80},
	}) {
		check_bad_option(t, opts, .Csv)
	}
	for opts in ([]dsv.Options{{delimiter = '\n'}, {delimiter = '\r'}, {delimiter = 0x80}, {delimiter = ';', comment = ';'}}) {
		check_bad_option(t, opts, .Plain)
	}
	for opts in ([]dsv.Options{{delimiter = '\\'}, {delimiter = 't'}, {delimiter = 'n'}, {delimiter = 'r'}, {delimiter = '0'}, {comment = '\\'}, {delimiter = '\n'}}) {
		check_bad_option(t, opts, .Tsv)
	}
}

@(private)
check_bad_option :: proc(t: ^testing.T, opts: dsv.Options, $S: dsv.Spec) {
	src := transmute([]u8)string("a,b\n1,2\n")
	if f, is_bad := walktest.fault_of(dsv.validate(src, S, opts)).?; testing.expectf(t, is_bad && f.kind == .Bad_Option && f.at == 0, "%v %v: validate %v", S, opts, f) {
		// A bad option is in `AT_NO_BYTE`, so it names no byte.
		testing.expect(t, f.kind in core.AT_NO_BYTE)
	}
	doc, err := dsv.build(src, S, opts)
	fault, _ := walktest.fault_of(err).?
	testing.expectf(t, fault.kind == .Bad_Option, "%v %v: build %v", S, opts, err)
	testing.expect_value(t, len(doc.nodes), 0)
}

// `build` writes the header's cells through the walk's key buffer, and the walk emits no token for the header row
// itself. Its cells' `Key` tokens start at bytes 0 and 2. The document stores the delimiter and comment byte it was built
// with, which an edit writes and judges by, and each spec has its own default delimiter.
@(test)
caller_key_buffer :: proc(t: ^testing.T) {
	src := transmute([]u8)string("a,b\n1,2\n")
	doc, err := dsv.build(src, .Csv)
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	testing.expect_value(t, core.header_of(&doc), core.Node_Index(1))
	testing.expect_value(t, doc.nodes[2], core.Node{0, 1, .Plain, .Key, 0})
	testing.expect_value(t, doc.nodes[3], core.Node{2, 1, .Plain, .Key, 0})
	log := new(walktest.Log)
	defer free(log)
	regs: core.Hook_Regs
	_, fault := dsv.walk(src, 0, .Csv, {}, log, &regs, walktest.log_hook)
	testing.expect(t, fault == nil)
	for tok in log.tokens[:log.n] {
		if tok.role == .Key {
			testing.expectf(t, tok.lo == 0 || tok.lo == 2, "key %v", tok)
		}
	}
	for c in ([]struct {
		spec: dsv.Spec,
		opts: dsv.Options,
		want: [2]u8,
	}{
		{.Plain, {delimiter = '|', comment = '#'}, {'|', '#'}},
		{.Csv, {}, {',', 0}},
		{.Tsv, {}, {'\t', 0}},
	}) {
		d, derr := build_any("a\n", c.spec, c.opts)
		defer core.destroy(&d)
		walktest.expect_nil(t, derr)
		testing.expect_value(t, d.as.opts[0], c.want[0])
		testing.expect_value(t, d.as.opts[1], c.want[1])
	}
}

// A headed record yields member key and value pairs through `pairs` and `pair_next` from the shared header row. A ragged
// record stops at its last cell, and a header-only document and a headerless record yield none.
@(test)
pairs_iteration :: proc(t: ^testing.T) {
	count :: proc(doc: ^core.Document, node: core.Node_Index) -> (n: int, first: [2]core.Node_Index) {
		it := core.pairs(doc, node)
		for k, v in core.pair_next(&it) {
			if n == 0 {
				first = {k, v}
			}
			n += 1
		}
		return
	}
	doc, _ := build("a,b\n1,2\n3,4\n", .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, core.kind(&doc, 4), core.Kind.Object)
	n, first := count(&doc, 4)
	testing.expect(t, n == 2 && first == {2, 5})
	n, _ = count(&doc, 7)
	testing.expect_value(t, n, 2)

	ragged, _ := build("a,b,c\n1\n", .Csv, {tolerate = {.Ragged}})
	defer core.destroy(&ragged)
	n, first = count(&ragged, 5)
	testing.expect(t, n == 1 && first == {2, 6})

	only, _ := build("a,b,c\n", .Csv)
	defer core.destroy(&only)
	for node in ([]core.Node_Index{core.header_of(&only), core.ROOT}) {
		n, _ = count(&only, node)
		testing.expect_value(t, n, 0)
	}

	headless, _ := build("1,2\n3,4\n", .Csv, {no_header = true})
	defer core.destroy(&headless)
	testing.expect_value(t, core.kind(&headless, 1), core.Kind.Array)
	n, _ = count(&headless, 1)
	testing.expect_value(t, n, 0)
}

// A text fits an arena of its nodes and a small stack, reading past its first reservation and past a refused growth.
@(test)
smallest_arena :: proc(t: ^testing.T) {
	texts := [?]string{
		strings.concatenate({"a,b\n", strings.repeat("1,2\n", 5000, context.temp_allocator)}, context.temp_allocator),
		strings.concatenate({"a,b,c,d\n", strings.repeat(",,,\n", 5000, context.temp_allocator)}, context.temp_allocator),
	}
	for src in texts {
		first, err := dsv.build(transmute([]u8)src, .Csv)
		defer core.destroy(&first)
		walktest.expect_nil(t, err)
		need := len(first.nodes) * size_of(core.Node) + 512
		backing := make([]u8, need, context.allocator)
		defer delete(backing)
		arena: mem.Arena
		mem.arena_init(&arena, backing)
		doc, derr := dsv.build(transmute([]u8)src, .Csv, {}, .Last, mem.arena_allocator(&arena))
		defer core.destroy(&doc)
		testing.expectf(t, derr == nil, "%d bytes: %v", need, derr)
		testing.expect_value(t, len(doc.nodes), len(first.nodes))
	}
}

// Every spec's spelling table has the read services and a flat edit table with `commit` and `interior`.
@(test)
spelling_complete :: proc(t: ^testing.T) {
	for spec in dsv.Spec {
		doc, err := build_any("a\n", spec)
		defer core.destroy(&doc)
		s := doc.readers
		walktest.expect_nil(t, err)
		testing.expect(t, s.text != nil && s.key_equals != nil && s.number != nil && s.resolve != nil && s.resolves != nil && s.close_end != nil && s.format != nil)
		testing.expect(t, s.flat && s.services != nil && s.services.build != nil && s.services.validate != nil)
		testing.expect(t, s.services.edit != nil && s.services.edit.interior != nil)
	}
}

// `child_at` of the root agrees with a walk over its children for every position and one past the last, and the table
// says the width the rows have.
expect_rows_by_position :: proc(t: ^testing.T, src: string, opts: dsv.Options, width: u32, rows: int) {
	doc, err := build(src, .Csv, opts)
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	table, has := core.table_of(&doc, core.ROOT)
	testing.expectf(t, has && table.width == width, "%q: table %v, width %d wanted", src, table, width)
	testing.expectf(t, core.length(&doc, core.ROOT) == rows, "%q: %d rows", src, core.length(&doc, core.ROOT))
	it := core.children(&doc, core.ROOT)
	for k in 0 ..< rows + 1 {
		want, more := core.child_next(&it)
		got, found := core.child_at(&doc, core.ROOT, k)
		testing.expectf(t, found == more && (!found || got == want), "%q: row %d is %d, %v, a walk gives %d, %v", src, k, got, found, want, more)
	}
}

@(test)
table_rows :: proc(t: ^testing.T) {
	expect_rows_by_position(t, "a,b\n1,2\n3,4\n5,6\n", {}, 2, 3)
	expect_rows_by_position(t, "a\n1\n2\n3\n", {}, 1, 3)
	expect_rows_by_position(t, "a,b\n", {}, 0, 0)
	expect_rows_by_position(t, "", {}, 0, 0)
	expect_rows_by_position(t, "1,2\n3,4\n", {no_header = true}, 2, 2)
	expect_rows_by_position(t, "a,b\n1\n2,3,4\n5,6\n", {tolerate = {.Ragged}}, 0, 3)
	expect_rows_by_position(t, "1\n2,3\n", {no_header = true, tolerate = {.Ragged}}, 0, 2)
}

// A table is the root's only, and JSON has none.
@(test)
table_of_node :: proc(t: ^testing.T) {
	doc, _ := build("a,b\n1,2\n", .Csv)
	defer core.destroy(&doc)
	table, has := core.table_of(&doc, core.ROOT)
	testing.expect(t, has && table.header == 1 && table.first_row == 4 && table.width == 2)
	_, has = core.table_of(&doc, 4)
	testing.expect(t, !has)
}

// A build with `infer` stores the kind `Readers.resolve` gives a cell of the same text, for every spelling of a cell
// that is or is not a number, `true` or `false`. A quoted cell, a doubled quote among them, is a string whatever it
// holds.
@(test)
leaf_kinds_match_resolve :: proc(t: ^testing.T) {
	cells := [?]string{
		"0", "-0", "1", "-12", "1.5", "-1.5e3", "1E+2", "123456789012345678901234567890", "0.000001",
		"01", "1.", ".5", "+1", "-", "1e", "1e+", "0x10", "1_0", " 1", "1 ", "NaN", "Infinity",
		"true", "false", "True", "truex", "tru", "f", "t",
		"abc", "é", "\"1\"", "\"1\"\"2\"", "\"\"\"1\"\"\"", "\"true\"", "\"1.5\"", "\"a\"\"b\"",
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "c\n")
	for c in cells {
		strings.write_string(&b, c)
		strings.write_byte(&b, '\n')
	}
	src := strings.to_string(b)
	doc, err := build(src, .Csv, {infer = true})
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	testing.expect_value(t, core.length(&doc, core.ROOT), len(cells))
	for c, i in cells {
		cell := cell_node(&doc, i, 0)
		stored := core.kind(&doc, cell)
		saved := doc.nodes[cell]
		doc.nodes[cell].kind = .Plain
		resolved := core.kind(&doc, cell)
		doc.nodes[cell] = saved
		testing.expectf(t, stored == resolved, "%q: stored %v, resolved %v", c, stored, resolved)
		testing.expectf(t, (saved.kind == .Plain) == (stored == .String || stored == .Null), "%q: node kind %v for %v", c, saved.kind, stored)
		if c[0] == '"' {
			testing.expectf(t, stored == .String && saved.kind == .Plain, "%q: %v", c, stored)
		}
	}
	// A number node's digit counts are the ones JSON's walk gives it.
	number := doc.nodes[cell_node(&doc, 5, 0)]
	int_digits, frac_digits := core.number_digit_counts(number.spelling)
	testing.expectf(t, number.kind == .Number && int_digits == 1 && frac_digits == 1 && number.spelling & core.NUMBER_EXP != 0, "-1.5e3: %v", number)
	big := doc.nodes[cell_node(&doc, 7, 0)]
	int_digits, frac_digits = core.number_digit_counts(big.spelling)
	testing.expectf(t, big.kind == .Number && int_digits == 30 && frac_digits == 0, "30 digits: %v", big)
}

// Without `infer` no cell is stored as anything but `.Plain`.
@(test)
leaf_kinds_off :: proc(t: ^testing.T) {
	doc, err := build("a,b,c\n1,true,x\n", .Csv)
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	for c in 0 ..< 3 {
		testing.expect_value(t, doc.nodes[cell_node(&doc, 0, c)].kind, core.Kind.Plain)
	}
}
