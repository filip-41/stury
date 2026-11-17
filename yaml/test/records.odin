// `.Entries` records of YAML: the members of a container read in their place and built later, and a stream's window
// that follows them with the anchors, tags and merge keys they read.
package yaml_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import core "../../core"
import records "../../core/records"
import walktest "../../walktest"
import yaml ".."

// `.Entries` gives the members of the container that a path of keys names as the walk reads them, a block member read
// as it does in its place, and a fault ends the records at the byte `validate` gives, after the members before it.
@(test)
entries_are_the_members_of_a_container :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "a: 0\nlogs:\n  - id: 1\n    s: x\n  - [1, 2]\n  - 3\n"
	walktest.expect_entries(t, src, yaml.as(.Yaml_1_2), {"logs"}, "15  {\"id\":1,\"s\":\"x\"}\n34  [1,2]\n45  3\nend")
	walktest.expect_entries(t, src, yaml.as(.Yaml_1_2), nil, "3 a 0\n13 logs [{\"id\":1,\"s\":\"x\"},[1,2],3]\nend")
	walktest.expect_entries(t, src, yaml.as(.Yaml_1_2), {"none"}, "end")
	walktest.expect_framings(t, yaml.CAPABILITIES, yaml.as(.Yaml_1_2))
	bad := "logs:\n  - 1\n  - [2\n"
	fault, _ := walktest.fault_in(yaml.validate(transmute([]u8)string(bad), .Yaml_1_2))
	walktest.expect_entries(t, bad, yaml.as(.Yaml_1_2), {"logs"}, fmt.tprintf("10  1\nfault %d", fault.at))
	other := "f: [1, {a: 2}, [3]]\nm:\n  x: 1\n  y:\n    - 2\n"
	walktest.expect_entries(t, other, yaml.as(.Yaml_1_2), {"f"}, "4  1\n7  {\"a\":2}\n15  [3]\nend")
	walktest.expect_entries(t, other, yaml.as(.Yaml_1_2), {"m"}, "28 x 1\n39 y [2]\nend")
	it := yaml.records_open(transmute([]u8)src, .Yaml_1_2, framing = .Entries, entries = {"logs"})
	testing.expect_value(t, walktest.entries_lines(&it), "15  {\"id\":1,\"s\":\"x\"}\n34  [1,2]\n45  3\nend")
}

// A member under `.Entries` reads in its place, as the build of the whole text reads it: an alias to an anchor of an
// earlier member, and a tag by a handle the directives declare, by a build and by a typed read.
@(test)
entries_read_in_their_place :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	aliased := "l:\n- &a 1\n- *a\n"
	walktest.expect_entries(t, aliased, yaml.as(.Yaml_1_2), {"l"}, "5  1\n12  1\nend")
	testing.expect_value(t, walktest.entries_read(aliased, yaml.as(.Yaml_1_2), {"l"}, int), "1\n1\nend")
	tagged := "%TAG !e! tag:e.com,2000:\n---\nl:\n- !e!x 1\n"
	walktest.expect_entries(t, tagged, yaml.as(.Yaml_1_2), {"l"}, "34  \"1\"\nend")
	testing.expect_value(t, walktest.entries_read(tagged, yaml.as(.Yaml_1_2), {"l"}, string), "1\nend")
}

// A member given before the last builds once later members are read, in memory and while a stream's window holds it:
// an alias to an anchor of an earlier member too.
@(test)
entries_build_after_later_members :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	walktest.expect_entries_built_later(t, "l:\n- &a {x: 1}\n- *a\n- [2, 3]\n- 4\n", yaml.as(.Yaml_1_2), {"l"})
	walktest.expect_entries_built_later(t, "m:\n  a: 1\n  b: {c: d}\n  e: [f]\n", yaml.as(.Yaml_1_2), {"m"})
}

// A stream's member given before the last builds as it did when it was given, once the window moved past the reader's
// first position, by a walk from the window's first step: an alias to an anchor before the window's start too. The
// records just after each move look back across it, where a member the window let go is `.Bad_Index`.
@(test)
entries_build_after_the_window_moved :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "l:\n- &a {k: 1}\n")
	for i in 0 ..< 2000 {
		fmt.sbprintf(&b, "- {{id: %d, pad: 0123456789012345678901234567890123456789012345678901234567890123456789}}\n- *a\n", i)
	}
	r: strings.Reader
	it := records.open_stream(strings.to_reader(&r, strings.to_string(b)), yaml.as(.Yaml_1_2), .Entries, {entries = {"l"}})
	defer records.close(&it)
	given := make([dynamic]records.Record, context.temp_allocator)
	then := make([dynamic]string, context.temp_allocator)
	window, since, after, refused := it.src, 0, 0, 0
	for rec in records.next(&it) {
		if raw_data(it.src) != raw_data(window) || len(it.src) != len(window) {
			window, since = it.src, len(given)
		}
		append(&given, rec)
		append(&then, walktest.built_json(&it, rec))
		for k := len(given) - 2; since > 0 && len(given) - since <= 3 && k >= len(given) - 5; k -= 1 {
			doc, err := records.build(&it, given[k], context.temp_allocator)
			core.destroy(&doc)
			if k < since && err != nil {
				refused += int(walktest.expect_kind(t, err, core.Document_Error_Kind.Bad_Index))
				continue
			}
			after += int(k >= since)
			got := walktest.built_json(&it, given[k])
			testing.expectf(t, got == then[k], "record %d after %d: %s, got %s", k, len(given) - 1, then[k], got)
		}
	}
	testing.expectf(t, after > 0 && refused > 0, "%d rebuilt after a move, %d refused across it", after, refused)
	testing.expect_value(t, len(given), 4001)
}

// Reading the records of a sequence ten times as long under `.Entries` holds no more of the reader's memory at its
// peak, so the reader walks the members and holds no tree of the text.
@(test)
entries_hold_no_tree :: proc(t: ^testing.T) {
	walktest.expect_entries_bounded(t, yaml.as(.Yaml_1_2), {"logs"}, "meta: 1\nlogs:\n", "  - id: 7\n    tags: [a, b]\n", "", false)
}

// A stream's window follows the records under `.Entries`, as the input of a stream ten times as long holds no more of
// the reader's memory at its peak: in a block and a flow container, with an anchor each member takes again and an
// alias to it, and with a tag by a handle the directives declare.
@(test)
entries_hold_one_member :: proc(t: ^testing.T) {
	as := yaml.as(.Yaml_1_2)
	text :: "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"
	walktest.expect_entries_bounded(t, as, {"logs"}, "meta: 1\nlogs:\n", "  - id: 7\n    name: " + text + "\n    tags: [a, b]\n", "", true)
	walktest.expect_entries_bounded(t, as, {"logs"}, "logs: [", "{id: 7, name: " + text + "}, ", "1]\n", true)
	walktest.expect_entries_bounded(t, as, {"logs"}, "logs:\n", "- &m {id: 7, name: " + text + "}\n- *m\n", "", true)
	walktest.expect_entries_bounded(t, as, {"logs"}, "%TAG !e! tag:e.com,2000:\n---\nlogs:\n", "- !e!x " + text + "\n", "", true)
	merging := yaml.as(.Yaml_1_2, {merge_keys = true})
	walktest.expect_entries_bounded(t, merging, {"logs"}, "logs:\n", "- <<: {id: 7, name: " + text + "}\n  id: 8\n", "", true)
}

// A stream's window lets go of the bytes before the members held but for the anchored nodes an alias can name, which
// an early anchor aliased by every member and many anchors named throughout leave a few bytes each.
@(test)
entries_hold_anchored_nodes :: proc(t: ^testing.T) {
	as := yaml.as(.Yaml_1_2)
	text :: "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"
	walktest.expect_entries_bounded(t, as, {"logs"}, "defaults: &d {x: 1, y: [2, 3]}\nlogs:\n", "- {id: 7, d: *d, name: " + text + "}\n", "", true)
	walktest.expect_entries_bounded(t, as, {"logs"}, "defaults: &d\n  x: 1\nlogs:\n", "- *d\n- id: 7\n  d: *d\n  name: " + text + "\n", "", true)
	defer free_all(context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "defs:\n")
	for i in 0 ..< 200 {
		fmt.sbprintf(&b, "  a%d: &a%d {{v: %d}}\n", i, i, i)
	}
	strings.write_string(&b, "logs:\n")
	walktest.expect_entries_bounded(t, as, {"logs"}, strings.to_string(b), "- [*a0, *a100, *a199, " + text + "]\n", "", true)
	walktest.expect_entries_bounded(t, as, {"logs"}, "logs:\n", renamed(text), "", true)
}

// A member that anchors a name again, and 50 members whose aliases name it.
@(private = "file")
renamed :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "- &a {{v: 1, pad: %s}}\n", text)
	for _ in 0 ..< 50 {
		fmt.sbprintf(&b, "- {{a: *a, pad: %s}}\n", text)
	}
	return strings.to_string(b)
}

// A stream's member reads and builds as the memory read does once the anchored nodes its aliases name were copied out of
// the window: an alias as a key, to a quoted scalar, to a tagged node and to a block mapping, and with merge keys on.
@(test)
entries_read_anchors_out_of_the_window :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	pad :: "0123456789012345678901234567890123456789012345678901234567890123456789"
	for merging in ([2]bool{false, true}) {
		as := yaml.as(.Yaml_1_2, {merge_keys = merging})
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "d: &d {x: 1, y: [2, 3]}\nk: &k key\ns: &s 'quo''ted'\nt: &t !!str 4\nm: &m\n  a: 1\n  b: [c]\nl:\n")
		for i in 0 ..< 120 {
			fmt.sbprintf(&b, "- {{i: %d, d: *d, *k : 1, s: *s, t: *t, pad: %s}}\n- *m\n- i: %d\n  m: *m\n", i, pad, i)
			if merging {
				fmt.sbprintf(&b, "- <<: *d\n  y: %d\n", i)
			}
		}
		src := strings.to_string(b)
		it := records.open(transmute([]u8)src, as, .Entries, entries = {"l"})
		want := walktest.entries_lines(&it)
		walktest.expect_entries(t, src, as, {"l"}, want)
		trickle := walktest.Chunked{src = transmute([]u8)src, sizes = {64}}
		stream := records.open_stream(walktest.chunked(&trickle), as, .Entries, {entries = {"l"}})
		given := make([dynamic]records.Record, context.temp_allocator)
		then := make([dynamic]string, context.temp_allocator)
		window, since := stream.src, 0
		for rec in records.next(&stream) {
			if raw_data(stream.src) != raw_data(window) || len(stream.src) != len(window) {
				window, since = stream.src, len(given)
			}
			append(&given, rec)
			append(&then, walktest.built_json(&stream, rec))
			for k := len(given) - 2; k >= since && k >= len(given) - 4; k -= 1 {
				got := walktest.built_json(&stream, given[k])
				testing.expectf(t, got == then[k], "merge keys %v: record %d after %d: %s, got %s", merging, k, len(given) - 1, then[k], got)
			}
		}
		testing.expect(t, stream.fault == nil)
		records.close(&stream)
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "k: &k key\nn: &n 1\nm:\n")
	for i in 0 ..< 200 {
		fmt.sbprintf(&b, "  i%d: {{*k : %d, *n : %s}}\n", i, i, pad)
	}
	src := strings.to_string(b)
	as := yaml.as(.Yaml_1_2)
	it := records.open(transmute([]u8)src, as, .Entries, entries = {"m"})
	walktest.expect_entries(t, src, as, {"m"}, walktest.entries_lines(&it))
	// The copies of the anchors a later anchor of their name hid are let go while the window moves.
	strings.builder_reset(&b)
	strings.write_string(&b, "l:\n")
	for _ in 0 ..< 300 {
		strings.write_string(&b, renamed(pad))
	}
	src = strings.to_string(b)
	it = records.open(transmute([]u8)src, as, .Entries, entries = {"l"})
	want := walktest.entries_lines(&it)
	trickle := walktest.Chunked{src = transmute([]u8)src, sizes = {64}}
	stream := records.open_stream(walktest.chunked(&trickle), as, .Entries, {entries = {"l"}})
	testing.expect_value(t, walktest.entries_lines(&stream), want)
}

// Under merge keys a stream's member merges what its `<<` names as the whole text does while the window moves, and so
// does a container of the records, whose earlier keys the window let go.
@(test)
entries_merge_keys_across_window_moves :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	as := yaml.as(.Yaml_1_2, {merge_keys = true})
	walktest.expect_entries(t, "base: &b {x: 1, y: 2}\nl:\n- <<: *b\n  y: 3\n- {<<: [*b, {w: 0}], z: 4}\n- k: 1\n  <<: {k: 2, m: 3}\n", as, {"l"}, "27  {\"y\":3,\"x\":1}\n43  {\"z\":4,\"x\":1,\"y\":2,\"w\":0}\n70  {\"k\":1,\"m\":3}\nend")
	walktest.expect_entries(t, "m:\n  alpha: 1\n  beta: [2]\n  <<: {alpha: 9, zeta: 1}\n", as, {"m"}, "12 alpha 1\n22 beta [2]\n49 zeta 1\nend")
}

// A stream's member reads as the whole text reads it while the window moves under it: an alias to an anchor of an
// earlier member, after the name was taken again too, a tag by a handle a `%TAG` directive declares or redefines, a
// repeated key, block and flow members, and scalars that end only at a line past them.
@(test)
entries_read_across_window_moves :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	as := yaml.as(.Yaml_1_2)
	walktest.expect_entries(t, "l:\n- &a 1\n- x\n- {k: &b [2, 3]}\n- *a\n- &a 4\n- {y: 1, z: *b}\n- *a\n", as, {"l"}, "5  1\n12  \"x\"\n16  {\"k\":[2,3]}\n33  1\n38  4\n45  {\"y\":1,\"z\":[2,3]}\n61  4\nend")
	walktest.expect_entries(t, "%TAG !e! tag:e.com,2000:\n%TAG !! tag:e.com:\n---\nl:\n- !e!x 1\n- !!int 2\n- 3\n", as, {"l"}, "53  \"1\"\n62  \"2\"\n72  3\nend")
	walktest.expect_entries(t, "l:\n- {a: 1, a: 2}\n- 1: a\n  0x1: b\n- k: [1]\n  k: [2]\n", as, {"l"}, "5  {\"a\":1,\"a\":2}\n20  {\"1\":\"a\",\"0x1\":\"b\"}\n36  {\"k\":[1],\"k\":[2]}\nend")
	walktest.expect_entries(t, "l: [1, {a: [2, 3]}, \"q\", 'r', [ ], b c\n  d]\n", as, {"l"}, "4  1\n7  {\"a\":[2,3]}\n20  \"q\"\n25  \"r\"\n30  []\n35  \"b c d\"\nend")
	walktest.expect_entries(t, "l:\n- |\n  text\n  more\n- >-\n  folded\n  line\n- a\n  b\n- - 1\n  - 2\n- k: v\n  m:\n    n: 1\n# end\n", as, {"l"}, "5  \"text\\nmore\\n\"\n23  \"folded line\"\n44  \"a b\"\n52  [1,2]\n64  {\"k\":\"v\",\"m\":{\"n\":1}}\nend")
	for size in 1 ..= 3 {
		b := strings.builder_make(context.temp_allocator)
		want := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "l:\n- &keep k\n")
		strings.write_string(&want, "5  \"k\"\n")
		for i in 0 ..< 40 {
			fmt.sbprintf(&want, "%d  %d\n%d  %d\n", len(b.buf) + 2, i, len(b.buf) + len(fmt.tprintf("- &a %d\n", i)) + 2, i)
			fmt.sbprintf(&b, "- &a %d\n- *a\n", i)
		}
		fmt.sbprintf(&want, "%d  \"k\"\nend", len(b.buf) + 2)
		strings.write_string(&b, "- *keep\n")
		trickle := walktest.Chunked{src = b.buf[:], sizes = {size}}
		it := records.open_stream(walktest.chunked(&trickle), as, .Entries, {entries = {"l"}})
		testing.expect_value(t, walktest.entries_lines(&it), strings.to_string(want))
	}
}
