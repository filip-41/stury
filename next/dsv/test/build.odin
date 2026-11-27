package dsv_tests

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:lib/core/tape"
import "stury:testkit"

// Writes the value at `at` of `doc` through the readers, as JSON: a table's rows as objects whose keys are the table's.
render_value :: proc(b: ^strings.Builder, doc: ^dsv.Document, at: dsv.Node_Index) {
	r := dsv.Reader{doc = doc}
	n := doc.nodes[at]
	buf: [256]u8
	#partial switch n.kind {
	case .Null:
		strings.write_string(b, "null")
	case .True:
		strings.write_string(b, "true")
	case .False:
		strings.write_string(b, "false")
	case .Number:
		strings.write_string(b, string(dsv.span_bytes(doc, n.lo, n.n)))
	case .String:
		text, _ := dsv.node_text(doc, at, buf[:])
		fmt.sbprintf(b, "%q", text)
	case .Array, .Object:
		c, _, _ := dsv.children(r, at, context.temp_allocator)
		strings.write_byte(b, '[' if n.kind == .Array else '{')
		for first := true; ; first = false {
			key, value, p := dsv.next_child(r, &c)
			if p == .Missing {
				break
			}
			if !first {
				strings.write_byte(b, ',')
			}
			if k, keyed := testkit.member_key(doc, c, key); keyed {
				text, _ := dsv.node_text(doc, k, buf[:])
				fmt.sbprintf(b, "%q:", text)
			}
			render_value(b, doc, value)
		}
		strings.write_byte(b, ']' if n.kind == .Array else '}')
	}
}

render :: proc(doc: ^dsv.Document) -> string {
	b := strings.builder_make(context.temp_allocator)
	if len(doc.nodes) > 0 {
		render_value(&b, doc, dsv.ROOT)
	}
	return strings.to_string(b)
}

Built :: struct {
	text: string,
	spec: dsv.Spec,
	opts: dsv.Dsv_Options,
	tol:  tape.Tolerances,
	want: string,
}

// Texts and the documents their builds read as.
@(rodata)
BUILT := []Built {
	{"a,b\n1,2\n3,4\n", .Csv, {}, {}, `[{"a":"1","b":"2"},{"a":"3","b":"4"}]`},
	{"a,b\r\n1,2", .Csv, {}, {}, `[{"a":"1","b":"2"}]`},
	{"a,b\n", .Csv, {}, {}, `[]`},
	{"", .Csv, {}, {}, `[]`},
	{"\xef\xbb\xbfa\n1\n", .Csv, {}, {}, `[{"a":"1"}]`},
	{"a,b\n,\"\"\n", .Csv, {}, {}, `[{"a":null,"b":""}]`},
	{"\"x\"\"y\",\"p,q\"\n\"a\nb\",c\n", .Csv, {}, {}, `[{"x\"y":"a\nb","p,q":"c"}]`},
	{"1,2\n3,4\n", .Csv, {no_header = true}, {}, `[["1","2"],["3","4"]]`},
	{"a,b,c\n1,2.5e3,true\n-0,x,false\n", .Csv, {infer = true}, {}, `[{"a":1,"b":2.5e3,"c":true},{"a":-0,"b":"x","c":false}]`},
	{"a,b\n01,\"1\"\n", .Csv, {infer = true}, {}, `[{"a":"01","b":"1"}]`},
	{"a\tb\nx\\ty\t\\\\\n", .Tsv, {}, {}, `[{"a":"x\ty","b":"\\"}]`},
	{"a;b\n1;2\n", .Plain, {delimiter = ';'}, {}, `[{"a":"1","b":"2"}]`},
	{"a,b\n1,2,3\n4\n", .Csv, {}, {.Ragged}, `[{"a":"1","b":"2","3":"3"},{"a":"4"}]`},
	{"a,a\n1,2\n", .Csv, {}, {}, `[{"a":"2"}]`},
	{"# c\na,b\n#d\n1,2\n# e\n", .Csv, {comment = '#'}, {}, `[{"a":"1","b":"2"}]`},
	{"a,b\n\xff,2\n", .Csv, {}, {.Invalid_Utf8}, `[{"a":"�","b":"2"}]`},
	{"a\"\tb\xff,c\n1\"\"2,\"q\"\"\xff\"\n", .Csv, {}, {.Bare_Quote, .Invalid_Utf8}, `[{"a\"\tb�":"1\"\"2","c":"q\"�"}]`},
}

@(test)
builds_read_as_tables :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for c in BUILT {
		doc, err := dsv.build(transmute([]u8)c.text, c.spec, {format = c.opts, tolerate = c.tol})
		defer dsv.destroy(&doc)
		if !testing.expectf(t, err == nil, "%q: %v", c.text, err) {
			continue
		}
		got := render(&doc)
		testing.expectf(t, got == c.want, "%q: %s, want %s", c.text, got, c.want)
	}
}


// A header wider than a 16-bit column number names its cells by key slots, so the build stays linear.
@(test)
builds_name_cells_of_a_very_wide_header :: proc(t: ^testing.T) {
	testkit.deadline(t)
	COLUMNS :: 70_000
	head := strings.builder_make()
	row := strings.builder_make()
	defer strings.builder_destroy(&head)
	defer strings.builder_destroy(&row)
	for c in 0 ..< COLUMNS {
		sep := "," if c > 0 else ""
		fmt.sbprintf(&head, "%sc%d", sep, c)
		fmt.sbprintf(&row, "%sv%d", sep, c)
	}
	text := fmt.aprintf("%s\n%s\n", strings.to_string(head), strings.to_string(row))
	defer delete(text)
	doc, err := dsv.build(transmute([]u8)text)
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	r := dsv.Reader{doc = &doc}
	rec, _ := dsv.element(r, dsv.ROOT, 0)
	for c in ([]int{0, 65_533, 65_534, 65_535, 65_536, COLUMNS - 1}) {
		v, p := dsv.member(r, rec, fmt.tprintf("c%d", c))
		buf: [16]u8
		got, _ := dsv.node_text(&doc, v, buf[:])
		testing.expectf(t, p == .Found && got == fmt.tprintf("v%d", c), "column %d: %v %q", c, p, got)
	}
	_, p := dsv.member(r, rec, "c70000")
	testing.expect_value(t, p, tape.Presence.Missing)
}

// A build's nodes are the root value's subtree alone. A reader gives rows and cells from the subtree and keys from the
// table's, which are no nodes.
@(test)
builds_keep_the_header_in_the_table :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for c in ([]struct {
		text: string,
		tol:  tape.Tolerances,
	} {
		{"a,b\n1,2\n3,4\n", {}},
		{"a,b\n", {}},
		{"a,b\n1,2,3\n4\n", {.Ragged}},
		{"a,a,b,c,d,e,f,g,h,i\n1,2,3,4,5,6,7,8,9,10\n", {}},
	}) {
		src := transmute([]u8)c.text
		doc, err := dsv.build(src, .Csv, {tolerate = c.tol})
		defer dsv.destroy(&doc)
		if !testing.expectf(t, err == nil, "%q: %v", c.text, err) {
			continue
		}
		root := dsv.Node_Index(doc.nodes[0].n)
		testing.expectf(t, int(root) == len(doc.nodes), "%q: %d nodes past a root of %d", c.text, len(doc.nodes), root)
		keys, is_table := tape.table_keys(&doc, dsv.ROOT)
		testing.expectf(t, is_table && len(keys) > 0 && keys[0].role == .Key, "%q: keys %v", c.text, keys)
		r := dsv.Reader{doc = &doc}
		rows, _, _ := dsv.children(r, dsv.ROOT, context.temp_allocator)
		for {
			_, row, p := dsv.next_child(r, &rows)
			if p == .Missing {
				break
			}
			testing.expectf(t, row < root, "%q: row %d is past the root's subtree", c.text, row)
			cells, _, _ := dsv.children(r, row, context.temp_allocator)
			for {
				key, cell, q := dsv.next_child(r, &cells)
				if q == .Missing {
					break
				}
				testing.expectf(t, cell < root && key == dsv.NO_NODE && slice.contains(keys, tape.cell_key(r, cells)), "%q: cell %d key %d", c.text, cell, key)
			}
		}
	}
	doc, err := dsv.build(transmute([]u8)string("1,2\n"), .Csv, {format = dsv.Dsv_Options{no_header = true}})
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, int(doc.nodes[0].n), len(doc.nodes))
	_, is_table := tape.table_keys(&doc, dsv.ROOT)
	testing.expect(t, is_table)
}

// A header that repeats a key gives a row's first or last cell of it by the build's policy, the last at its last place,
// as an object does. Under the other policies the row lists a repeated key once, at its first place with its last cell,
// and counts it once. `.Refuse` faults at the repeat's first byte.
@(test)
builds_take_repeated_keys_by_policy :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := transmute([]u8)string("a,b,\"a\"\n1,2,3\n")
	for c in ([]struct {
			dups: tape.Duplicates,
			want: string,
		}{{.Default, `[{"a":"3","b":"2"}]`}, {.Last, `[{"b":"2","a":"3"}]`}, {.First, `[{"a":"1","b":"2"}]`}, {.All, `[{"a":"3","b":"2"}]`}}) {
		doc, err := dsv.build(src, .Csv, {dups = c.dups})
		testing.expectf(t, err == nil && render(&doc) == c.want, "%v: %s %v", c.dups, render(&doc), err)
		row, _ := dsv.element({doc = &doc}, dsv.ROOT, 0)
		length, _, _ := dsv.length({doc = &doc}, row, context.temp_allocator)
		testing.expectf(t, length == 2, "%v: a row of length %d", c.dups, length)
		dsv.destroy(&doc)
	}
	_, err := dsv.build(src, .Csv, {dups = .Refuse})
	f, faulted := err.(tape.Fault)
	testing.expectf(t, faulted && f.kind == .Duplicate_Key && f.at == 4, "refuse: %v", err)
	// A header wide enough for key slots finds its keys by hash.
	wide := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 40 {
		fmt.sbprintf(&wide, "%sk%d", "," if i > 0 else "", i)
	}
	strings.write_string(&wide, ",k7\n")
	for i in 0 ..< 41 {
		fmt.sbprintf(&wide, "%s%d", "," if i > 0 else "", i)
	}
	strings.write_byte(&wide, '\n')
	doc, werr := dsv.build(transmute([]u8)strings.to_string(wide))
	defer dsv.destroy(&doc)
	row, _ := dsv.element({doc = &doc}, dsv.ROOT, 0)
	expected := [3]string{"0", "39", "40"}
	for name, want in ([]string{"k0", "k39", "k7"}) {
		v, p := dsv.member({doc = &doc}, row, name)
		testing.expectf(t, werr == nil && p == .Found, "%s: %v %v", name, p, werr)
		if p == .Found {
			text := string(dsv.span_bytes(&doc, doc.nodes[v].lo, doc.nodes[v].n))
			expect := expected[want]
			testing.expectf(t, text == expect, "%s: %s, want %s", name, text, expect)
		}
	}
	_, p := dsv.member({doc = &doc}, row, "k40")
	testing.expect_value(t, p, dsv.Presence.Missing)
}

// Comment lines are facts of the record after them, and the root's foot past the last. Those before the header are
// the root's.
@(test)
builds_keep_comment_lines_as_facts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Read :: struct {
		src:       string,
		comment:   u8,
		no_header: bool,
		node:      tape.Node_Index,
		kind:      tape.Fact_Kind,
		body:      string,
	}
	for c in ([]Read {
			{"a,b\n#head\n1,2\n", '#', false, 1, .Comment, "head"},
			{"a,b\n1,2\n#foot\n", '#', false, dsv.ROOT, .Comment_Foot, "foot"},
			{"#top\na,b\n1,2\n", '#', false, dsv.ROOT, .Comment, "top"},
			{"a,b\n1,2\n#end", '#', false, dsv.ROOT, .Comment_Foot, "end"},
			{"//hello\na,b\n1,2\n", '/', false, dsv.ROOT, .Comment, "/hello"},
			{"\xEF\xBB\xBF#c\na,b\n1,2\n", '#', false, dsv.ROOT, .Comment, "c"},
			{"#c\r\n1,2\n", '#', true, 1, .Comment, "c"},
			{"#only\n\n", '#', false, dsv.ROOT, .Comment_Foot, "only"},
			{"#top\na,b\n", '#', false, dsv.ROOT, .Comment_Foot, "top"},
			{"#a\n\"x\n#y\"\n", '#', false, dsv.ROOT, .Comment_Foot, "a"},
			{"#a\n\"x\r\n#y\"\n", '#', false, dsv.ROOT, .Comment_Foot, "a"},
		}) {
		src := transmute([]u8)c.src
		doc, err := dsv.build(src, .Csv, {format = dsv.Dsv_Options{comment = c.comment, no_header = c.no_header}})
		defer dsv.destroy(&doc)
		if !testing.expectf(t, err == nil && len(doc.facts) == 1, "%q: %v %v", c.src, err, doc.facts) {
			continue
		}
		f := doc.facts[0]
		testing.expectf(t, f.node == c.node && f.kind == c.kind && string(src[f.lo + 1:f.lo + u64(f.n)]) == c.body, "%q: %v", c.src, f)
	}
}

// A byte order mark past the text's first byte is a byte of its cell.
@(test)
builds_keep_a_byte_order_mark_past_the_first_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := dsv.build(transmute([]u8)string("a,b\n\xef\xbb\xbfx,y\n"))
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	cell := cell_at(&doc, 0, 0)
	text, _ := text_of(&doc, cell)
	testing.expect_value(t, text, "\xef\xbb\xbfx")
}

Dup_Case :: struct {
	src:  string,
	spec: dsv.Spec,
	tol:  tape.Tolerances,
	at:   u64,
	ok:   bool, // the text builds
}

// A build that refuses repeated keys faults at the later header cell, also when the text has no record or a later
// record faults, and an empty cell repeats like any other. A TSV cell written `\0` and a raw NUL are the same name, and a
// TSV cell's quotes are cell bytes.
@(test)
builds_refuse_a_repeated_header_name_at_the_later_cell :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in ([]Dup_Case {
			{"a,a\n1,2\n", .Csv, {}, 2, false},
			{"\"q\"\t\"q\"\n1\t2\n", .Tsv, {}, 4, false},
			{"a,a\n", .Csv, {}, 2, false},
			{",", .Csv, {}, 1, false},
			{"a,", .Csv, {}, 0, true},
			{"a,,b", .Csv, {}, 0, true},
			{"\\0\t\x00", .Tsv, {}, 3, false},
			{"\\0\t\x00\n", .Tsv, {}, 3, false},
			{"\\0\t\x00\n1\t2\n", .Tsv, {}, 3, false},
			{"\\0\t\\0\n1\t2\n", .Tsv, {}, 3, false},
			{"\\0\t\\0", .Tsv, {}, 3, false},
			{"a,a,3\n1,2,3,4\n", .Csv, {.Ragged}, 2, false},
			{"a,3\n1,2,3\n", .Csv, {.Ragged}, 0, true},
			{"a,2\n1,2,3,4\n", .Csv, {.Ragged}, 0, true},
		}) {
		doc, err := dsv.build(transmute([]u8)c.src, c.spec, {dups = .Refuse, tolerate = c.tol})
		defer dsv.destroy(&doc)
		if c.ok {
			testing.expectf(t, err == nil, "%q: %v", c.src, err)
			continue
		}
		fault, faulted := err.(tape.Fault)
		testing.expectf(t, faulted && fault.kind == .Duplicate_Key && fault.at == c.at && len(doc.nodes) == 0, "%q: %v, want a repeat at %d", c.src, err, c.at)
	}
}

// A column a ragged record names by its place is a position, not a text of the header's: it never repeats a header name
// under `.Refuse`, which refuses no text for it. A lookup of that name reads as `.Default` does a repeated name, at the
// last, so it finds the column named by its place.
@(test)
builds_name_columns_past_the_header_by_place_under_refuse :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := dsv.build(transmute([]u8)string("a,3\n1,2,3\n"), .Csv, {dups = .Refuse, tolerate = {.Ragged}})
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	row, _ := dsv.element({doc = &doc}, dsv.ROOT, 0)
	cell, found := dsv.member({doc = &doc}, row, "3")
	text, _ := text_of(&doc, cell)
	testing.expect_value(t, found, dsv.Presence.Found)
	testing.expect_value(t, text, "3")
}

// A repeated header name is the first fault of a text, whatever fault a later record has.
@(test)
builds_refuse_a_repeated_header_name_before_a_later_fault :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in ([]struct {
			src: string,
			at:  u64,
		}{{"a,a\n1,2\n3,\"x\n", 2}, {",\n1,2\n3,\"x\n", 1}}) {
		doc, err := dsv.build(transmute([]u8)c.src, .Csv, {dups = .Refuse})
		defer dsv.destroy(&doc)
		fault, faulted := err.(tape.Fault)
		testing.expectf(t, faulted && fault.kind == .Duplicate_Key && fault.at == c.at, "%q: %v, want a repeat at %d", c.src, err, c.at)
	}
}

// A table builds into an arena that holds its nodes and little more, past a first room the arena refuses. Its child
// counts are reserved before its nodes, as its first room is past `tape.MAX_CHILDREN` nodes, and hold all it needs. A
// room whose counts grow later places them past its nodes, which the arena then cannot grow in place.
@(test)
builds_fit_the_smallest_arena :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := transmute([]u8)strings.concatenate({"a,b\n", strings.repeat("1,2\n", 5000, context.temp_allocator)}, context.temp_allocator)
	first, err := dsv.build(src)
	defer dsv.destroy(&first)
	testing.expect_value(t, err, nil)
	need := len(first.nodes) * size_of(tape.Node) + ARENA_SLACK
	backing := make([]u8, need)
	defer delete(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	doc, derr := dsv.build(src, .Csv, {}, mem.arena_allocator(&arena))
	testing.expectf(t, derr == nil, "%d bytes: %v", need, derr)
	testing.expect_value(t, len(doc.nodes), len(first.nodes))
}

// The bytes past its nodes a table's build takes from an arena: the room its last growth left unused, its table, the
// child counts reserved for the most nodes its text may make, and the arena's alignment.
@(private = "file")
ARENA_SLACK :: 960 + 64 + size_of(tape.Doc_Ext)
