// The document built from a YAML text: the core schema's types, the number forms, tags, aliases, the
// facts and the documents of a stream as records.
package yaml_tests

import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import core "../../core"
import host "../../host"
import "../../core/records"
import walktest "../../walktest"
import yaml ".."

@(private)
build :: proc(text: string) -> (core.Document, core.Error) {
	return core.build(transmute([]u8)text, yaml.as(.Yaml_1_2))
}

// Whether `err` is a fault of the text with the rule `detail`.
@(private)
faults_with :: proc(err: core.Error, detail: yaml.Detail) -> bool {
	fault, is_fault := err.(core.Fault)
	return is_fault && fault.detail == u8(detail)
}

@(private)
kind_at :: proc(doc: ^core.Document, key: string) -> core.Kind {
	i, _ := core.member(doc, core.ROOT, key)
	return core.kind(doc, i)
}

@(test)
plain_scalars_take_the_core_schema :: proc(t: ^testing.T) {
	doc, err := build("n: ~\nt: True\nf: FALSE\ni: -12\nx: 0x1F\no: 0o17\nd: 1.5e3\ninf: -.inf\nnan: .NaN\ns: yes\nq: \"1\"\nz: 1_000\n")
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	want := [?]struct {
		key:  string,
		kind: core.Kind,
	}{{"n", .Null}, {"t", .True}, {"f", .False}, {"i", .Number}, {"x", .Number}, {"o", .Number}, {"d", .Number}, {"inf", .Number}, {"nan", .Number}, {"s", .String}, {"q", .String}, {"z", .String}}
	for w in want {
		testing.expectf(t, kind_at(&doc, w.key) == w.kind, "%s reads as %v, got %v", w.key, w.kind, kind_at(&doc, w.key))
	}
}

@(test)
number_forms_read_their_value :: proc(t: ^testing.T) {
	doc, _ := build("a: 0x1F\nb: 0o17\nc: 007\nd: .5\ne: +3\nf: -0.25\n")
	defer core.destroy(&doc)
	want := [?]struct {
		key:   string,
		value: f64,
	}{{"a", 31}, {"b", 15}, {"c", 7}, {"d", 0.5}, {"e", 3}, {"f", -0.25}}
	for w in want {
		i, _ := core.member(&doc, core.ROOT, w.key)
		got, ok := core.float_value(&doc, i)
		testing.expectf(t, ok && got == w.value, "%s is %v, got %v", w.key, w.value, got)
	}
}

@(test)
tags_force_or_spare_the_type :: proc(t: ^testing.T) {
	doc, _ := build("a: !!str 12\nb: !!int \"12\"\nc: !!float 3\nd: !local 5\ne: !!null null\nf: !<tag:yaml.org,2002:bool> 'true'\n")
	defer core.destroy(&doc)
	want := [?]struct {
		key:  string,
		kind: core.Kind,
	}{{"a", .String}, {"b", .Number}, {"c", .Number}, {"d", .String}, {"e", .Null}, {"f", .True}}
	for w in want {
		testing.expectf(t, kind_at(&doc, w.key) == w.kind, "%s reads as %v, got %v", w.key, w.kind, kind_at(&doc, w.key))
	}
	i, _ := core.member(&doc, core.ROOT, "a")
	tag, ok := core.fact_value(&doc, i, .Tag)
	testing.expect(t, ok && tag.text == "!!str")
	b, _ := core.member(&doc, core.ROOT, "b")
	value, _ := core.int_value(&doc, b)
	testing.expect_value(t, value, 12)
}

@(test)
a_text_its_core_tag_does_not_hold_is_a_fault :: proc(t: ^testing.T) {
	for text in ([?]string{"a: !!bool yes\n", "a: !!int 1.5\n", "a: !!null 0\n", "- !!float \"x\"\n"}) {
		fault := yaml.validate(transmute([]u8)text, .Yaml_1_2)
		testing.expectf(t, faults_with(fault, .Tag_Mismatch), "%q: %v", text, fault)
	}
	testing.expect(t, yaml.validate(transmute([]u8)string("a: !!float 1\nb: !!str yes\nc: !x 1.5\n"), .Yaml_1_2) == nil)
}

@(test)
a_tag_directive_names_what_a_handle_means :: proc(t: ^testing.T) {
	doc, err := build("%TAG !! tag:example.com,2000:\n---\na: !!int x\n")
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	testing.expect_value(t, kind_at(&doc, "a"), core.Kind.String)
	core_doc, _ := build("%TAG !c! tag:yaml.org,2002:\n---\na: !c!int '7'\n")
	defer core.destroy(&core_doc)
	testing.expect_value(t, kind_at(&core_doc, "a"), core.Kind.Number)
}

@(test)
a_key_with_a_tag_does_not_tag_its_value :: proc(t: ^testing.T) {
	doc, _ := build("!!str 1: !!int 47\n")
	defer core.destroy(&doc)
	testing.expect_value(t, kind_at(&doc, "1"), core.Kind.Number)
}

@(test)
aliases_repeat_their_anchor :: proc(t: ^testing.T) {
	doc, err := build("a: &x [1, 2]\nb: *x\n")
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	i, _ := core.member(&doc, core.ROOT, "b")
	testing.expect_value(t, core.length(&doc, i), 2)
}

@(test)
aliases_build_more_nodes_and_depth_than_the_text_holds :: proc(t: ^testing.T) {
	deep_aliases_build(t)
}

// `b` nests the 600 levels of `x` under 600 of its own, past `core.MAX_DEPTH`, and `d` holds `y`'s 101 nodes 64 times,
// past any bound on the text's bytes.
@(private)
deep_aliases_build :: proc(t: ^testing.T) {
	deep := strings.concatenate({strings.repeat("[", 600, context.temp_allocator), "7", strings.repeat("]", 600, context.temp_allocator)}, context.temp_allocator)
	outer := strings.repeat("[", 600, context.temp_allocator)
	close := strings.repeat("]", 600, context.temp_allocator)
	ones := strings.repeat("1, ", 99, context.temp_allocator)
	ys := strings.repeat("*y, ", 63, context.temp_allocator)
	text := strings.concatenate({"a: &x ", deep, "\nb: ", outer, "*x", close, "\nc: &y [", ones, "1]\nd: [", ys, "*y]\n"}, context.temp_allocator)
	doc, err := build(text)
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	testing.expect_value(t, len(doc.nodes), 1 + (1 + 601) + (1 + 600 + 601) + (1 + 101) + (1 + 1 + 64 * 101))
	i, _ := core.member(&doc, core.ROOT, "b")
	for _ in 0 ..< 1200 {
		i, _ = core.child_at(&doc, i, 0)
	}
	value, ok := core.int_value(&doc, i)
	testing.expect(t, ok && value == 7)
	d, _ := core.member(&doc, core.ROOT, "d")
	testing.expect_value(t, core.length(&doc, d), 64)
}

@(test)
a_collection_as_a_key_is_refused :: proc(t: ^testing.T) {
	_, err := build("? [a]\n: b\n")
	testing.expect(t, faults_with(err, .Complex_Key))
}

@(test)
a_stream_is_one_document_to_build_and_many_to_read :: proc(t: ^testing.T) {
	text := "a: 1\n---\n- b\n...\n# end\n--- c\n"
	_, err := build(text)
	testing.expect(t, faults_with(err, .Extra_Document))
	_, err = build("# nothing\n")
	testing.expect(t, faults_with(err, .No_Document))

	it := records.open(transmute([]u8)text, yaml.as(.Yaml_1_2), .Concatenated)
	defer records.close(&it)
	count := 0
	for _ in records.next(&it) {
		count += 1
	}
	testing.expect_value(t, count, 3)
	testing.expect(t, it.fault == nil)
}

@(test)
a_stream_judged_on_threads_gives_the_serial_fault :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	pools: [3]host.Pool
	for w, i in ([?]int{1, 2, 6}) {
		host.pool_init(&pools[i], w)
	}
	defer for &p in pools {
		host.pool_destroy(&p)
	}
	docs := [?]string{"a: 1\n", "--- [x, y]\n", "...\n", "# c\n", "%TAG !e! tag:e.com,2000:\n--- !e!k v\n", "---\n- \"q\n  ---x\"\n", "--- |\n  ---\n", "--- {a: 1, a: 2}\n", "---\nb: *n\n", "--- 'open\n", "---\n  - x\n - y\n"}
	for first in 0 ..< len(docs) {
		for bad in 0 ..< len(docs) {
			b := make([dynamic]u8, context.temp_allocator)
			append(&b, docs[first])
			for k in 0 ..< 12 {
				append(&b, docs[(k * 5 + first) % 5 if k != 9 else bad])
			}
			text := b[:]
			whole := yaml.validate(text, .Yaml_1_2)
			serial, _ := records.check(text, yaml.as(.Yaml_1_2), .Concatenated, context.temp_allocator)
			for &pool in pools {
				got, _ := records.check(text, yaml.as(.Yaml_1_2), .Concatenated, context.temp_allocator, &pool.runner)
				testing.expectf(t, slice.equal(got, serial), "%q at width %d: %v, want %v", string(text), pool.runner.threads + 1, got, serial)
				v := records.validate_parallel(text, yaml.as(.Yaml_1_2), &pool.runner)
				testing.expectf(t, v == walktest.fault_of(whole), "%q at width %d: %v, want %v", string(text), pool.runner.threads + 1, v, whole)
			}
		}
	}
}

// The records each piece of a stream read, the bytes it was given, and whether a fault ended them.
@(private = "file")
Gathered :: struct {
	lock:    sync.Mutex,
	pieces:  map[int][dynamic]records.Record,
	spans:   map[int][2]u64,
	faulted: map[int]bool,
}

// A piece's thread has its own temp allocator, so the records go to the test's under the lock.
@(private = "file")
gather :: proc(g: ^Gathered, it: ^records.Reader, k: int) -> bool {
	got: [32]records.Record
	n := 0
	span := [2]u64{it.pos, it.to if it.to != 0 else u64(len(it.src))}
	for rec in records.next(it) {
		got[n] = rec
		n += 1
	}
	sync.guard(&g.lock)
	kept := make([dynamic]records.Record, g.pieces.allocator)
	append(&kept, ..got[:n])
	g.pieces[k] = kept
	g.spans[k] = span
	g.faulted[k] = it.fault != nil
	return true
}

@(test)
a_stream_read_in_pieces_gives_the_serial_records :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	pools: [3]host.Pool
	for w, i in ([?]int{1, 2, 6}) {
		host.pool_init(&pools[i], w)
	}
	defer for &p in pools {
		host.pool_destroy(&p)
	}
	fill := [?]string{"a: 1\n", "--- [x, y]\n", "...\n", "# c\n\n", "...\n# c\n%YAML 1.2\n# d\n--- z\n...\n", "--- |\n  ---\n  ...\n", "---\n...\n...\n"}
	docs := [?]string{"%TAG !e! tag:e.com,2000:\n--- !e!k v\n", "---\n- \"q\n  ---x\"\n", "--- {a: 1, a: 2}\n", "---\nb: *n\n", "--- 'open\n", "---\n  - x\n - y\n", "...\r%TAG !e! tag:e.com,2000:\r--- !e!k v\n", "--- \"q\n---\n\"\n", "--- |\n%x\n---\n"}
	as := yaml.as(.Yaml_1_2)
	// The texts the pieces read past their first piece.
	several := 0
	for first in 0 ..< len(fill) {
		for odd in 0 ..< len(docs) {
			b := make([dynamic]u8, context.temp_allocator)
			for k in 0 ..< 14 {
				append(&b, fill[(k * 3 + first) % len(fill)] if k != 8 else docs[odd])
			}
			text := b[:]
			serial := make([dynamic]records.Record, context.temp_allocator)
			it := records.open(text, as, .Concatenated, 0, context.temp_allocator)
			for rec in records.next(&it) {
				append(&serial, rec)
			}
			for &pool in pools {
				g := Gathered{pieces = make(map[int][dynamic]records.Record, context.temp_allocator), spans = make(map[int][2]u64, context.temp_allocator), faulted = make(map[int]bool, context.temp_allocator)}
				fault := records.each(text, as, .Concatenated, gather, &g, &pool.runner)
				got := make([dynamic]records.Record, context.temp_allocator)
				// Each piece's text starts where the one before it ends, as a caller that writes the pieces in order
				// takes it.
				tiled, end := true, u64(0)
				for k in 0 ..= len(text) {
					if piece, read := g.pieces[k]; read {
						tiled &&= g.spans[k][0] == end
						end = g.spans[k][1]
						append(&got, ..piece[:])
						if g.faulted[k] {
							break
						}
					}
				}
				same := len(got) == len(serial)
				for rec, i in got {
					same = same && rec.at == serial[i].at && string(rec.text) == string(serial[i].text)
				}
				several += int(len(g.spans) > 1)
				testing.expectf(t, same && tiled && walktest.fault_of(fault) == it.fault, "%q at width %d: %v %v %v, want %v %v", string(text), pool.runner.threads + 1, got[:], g.spans, fault, serial[:], it.fault)
			}
			records.close(&it)
		}
	}
	testing.expectf(t, several > 0 || RECORDS_SLICE > 1024, "no text was read in more than one piece")
}

// The bytes of a slice as `core/records` cuts a text into pieces. The texts above are shorter than two slices of the
// default, so they are read in pieces only under a test build's smaller slice.
@(private = "file")
RECORDS_SLICE :: #config(RECORDS_SLICE, 64 * 1024)

@(test)
unmarshal_reads_the_core_schema_into_a_value :: proc(t: ^testing.T) {
	Server :: struct {
		name:  string,
		port:  int,
		ratio: f64,
		tags:  []string,
		on:    bool,
		home:  Maybe(string),
	}
	text := "name: web\nport: 0x1F\nratio: .5\ntags: &t [a, 'b']\non: true\nhome: ~\nalso: *t\n"
	s: Server
	err := yaml.unmarshal(transmute([]u8)text, .Yaml_1_2, &s)
	defer {
		delete(s.name)
		for tag in s.tags {
			delete(tag)
		}
		delete(s.tags)
	}
	walktest.expect_nil(t, err)
	testing.expect_value(t, s.name, "web")
	testing.expect_value(t, s.port, 31)
	testing.expect_value(t, s.ratio, 0.5)
	testing.expect(t, len(s.tags) == 2 && s.tags[0] == "a" && s.tags[1] == "b")
	testing.expect_value(t, s.on, true)
	testing.expect(t, s.home == nil)
	bad: Server
	walktest.expect_kind(t, yaml.unmarshal(transmute([]u8)string("port: yes\n"), .Yaml_1_2, &bad), core.Typed_Error_Kind.Wrong_Kind)
}

// A core tag gives a quoted or block scalar its type for the typed read as it does for the document.
@(test)
unmarshal_reads_a_tagged_scalar_as_its_tag_types_it :: proc(t: ^testing.T) {
	Tagged :: struct {
		n:    int,
		hex:  int,
		f:    f64,
		b:    int,
		text: string,
	}
	text := "n: !!int \"12\"\nhex: !!int '0x1F'\nf: !!float \"-1.5\"\nb: !!int |-\n  7\ntext: !!str 12\n"
	v: Tagged
	err := yaml.unmarshal(transmute([]u8)text, .Yaml_1_2, &v)
	defer delete(v.text)
	walktest.expect_nil(t, err)
	testing.expect_value(t, v.n, 12)
	testing.expect_value(t, v.hex, 31)
	testing.expect_value(t, v.f, -1.5)
	testing.expect_value(t, v.b, 7)
	testing.expect_value(t, v.text, "12")
	plain: Tagged
	walktest.expect_kind(t, yaml.unmarshal(transmute([]u8)string("n: \"12\"\n"), .Yaml_1_2, &plain), core.Typed_Error_Kind.Wrong_Kind)
}

@(test)
merge_keys_add_what_the_host_lacks :: proc(t: ^testing.T) {
	text := "base: &b {a: 1, b: 2}\nmore: &m {b: 3, c: 4}\nhost:\n  <<: [*b, *m]\n  a: 0\nsingle: {<<: *m, d: 5}\nodd: {<<: 7}\n"
	plain, perr := core.build(transmute([]u8)text, yaml.as(.Yaml_1_2))
	defer core.destroy(&plain)
	walktest.expect_nil(t, perr)
	host, _ := core.member(&plain, core.ROOT, "host")
	_, found := core.member(&plain, host, "<<")
	testing.expect(t, found)

	doc, err := core.build(transmute([]u8)text, yaml.as(.Yaml_1_2, {merge_keys = true}))
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	want := [?]struct {
		at:    string,
		key:   string,
		value: i64,
	}{{"host", "a", 0}, {"host", "b", 2}, {"host", "c", 4}, {"single", "b", 3}, {"single", "c", 4}, {"single", "d", 5}, {"odd", "<<", 7}}
	for w in want {
		owner, _ := core.member(&doc, core.ROOT, w.at)
		i, ok := core.member(&doc, owner, w.key)
		got, _ := core.int_value(&doc, i)
		testing.expectf(t, ok && got == w.value, "%s.%s is %d, got %d", w.at, w.key, w.value, got)
	}
	host, _ = core.member(&doc, core.ROOT, "host")
	testing.expect_value(t, core.length(&doc, host), 3)
	_, found = core.member(&doc, host, "<<")
	testing.expect(t, !found)
	testing.expect(t, yaml.validate(transmute([]u8)text, .Yaml_1_2, {merge_keys = true}) == nil)
}

@(test)
style_names_how_a_node_is_written :: proc(t: ^testing.T) {
	doc, _ := build("a: x\nb: 'x'\nc: \"x\"\nd: |\n  x\ne: >\n  x\nf: [x]\ng: {y: z}\nh: 5\n")
	defer core.destroy(&doc)
	want := [?]string{"plain", "single", "double", "literal", "folded", "flow", "flow", "plain"}
	for name, k in ([?]string{"a", "b", "c", "d", "e", "f", "g", "h"}) {
		i, _ := core.member(&doc, core.ROOT, name)
		style, ok := core.fact_value(&doc, i, .Style)
		testing.expectf(t, ok && style.text == want[k], "%s is %s, got %s", name, want[k], style.text)
	}
}
