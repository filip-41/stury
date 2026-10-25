package json_tests

// `build`, `Document` and its readers.

import json "../.."
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"

NESTED_DOC :: `{"s":"a\nb","t":"plain","n":[1,2.5,0.1,1e400,true,false,null],"o":{"k":"é","e":""}}`

@(test)
test_build_and_read_a_nested_document :: proc(t: ^testing.T) {
	src := raw(NESTED_DOC)
	doc := build_ok(t, string(src))
	defer json.destroy(&doc)
	kd, _ := json.kind(&doc, 0)
	testing.expect_value(t, kd, json.Kind.Object)
	testing.expect_value(t, json.child_count(&doc, 0), 4)
	testing.expect_value(t, json.child(&doc, json.ROOT, 0), json.Node(1))

	s := json.child(&doc, 0, "s")
	got, ok := json.get_string(&doc, s)
	testing.expect(t, ok)
	testing.expect_value(t, got, "a\nb")

	// An escape-free string is a slice of the source.
	plain := json.child(&doc, 0, "t")
	got, ok = json.get_string(&doc, plain)
	testing.expect(t, ok)
	testing.expect_value(t, got, "plain")
	testing.expect(t, in_source(got, string(src)), "an escape-free string must not be copied")

	n := json.child(&doc, 0, "n")
	kd, _ = json.kind(&doc, n)
	testing.expect_value(t, kd, json.Kind.Array)
	testing.expect_value(t, json.child_count(&doc, n), 7)
	want := [?]json.Number{{1, .Exact}, {2.5, .Exact}, {0.1, .Inexact}, {0, .None}}
	for w, k in want {
		num, num_ok := json.get_number(&doc, json.child(&doc, n, k))
		testing.expect(t, num_ok)
		testing.expect_value(t, num, w)
	}
	kinds := [?]json.Kind{.True, .False, .Null}
	for k, j in kinds {
		kd, _ = json.kind(&doc, json.child(&doc, n, 4 + j))
		testing.expect_value(t, kd, k)
	}
	not_number, number_ok := json.get_number(&doc, s)
	testing.expect(t, !number_ok && not_number == {}, "a string row is not a number")
	_, ok = json.get_string(&doc, json.child(&doc, n, 0))
	testing.expect(t, !ok, "a number row is not a string")

	// Navigation: members in order.
	members := json.children(&doc, n)
	visited := 0
	for c in json.children(&members) {
		testing.expect_value(t, c, json.child(&doc, n, visited))
		visited += 1
	}
	testing.expect_value(t, visited, 7)
	scalar := json.children(&doc, plain)
	_, has_member := json.children(&scalar)
	testing.expect(t, !has_member, "a scalar has no members")
	testing.expect_value(t, json.child_count(&doc, plain), 0)

	o := json.child(&doc, 0, "o")
	got, ok = json.get_string(&doc, json.child(&doc, o, "k"))
	testing.expect(t, ok)
	testing.expect_value(t, got, "é")
	got, ok = json.get_string(&doc, json.child(&doc, o, "e"))
	testing.expect(t, ok)
	testing.expect_value(t, got, "")

}

// Deep into a container of containers, `child` by index answers from the member rows it lists once, each answer
// is the walk's, and a request that scans again lists the new document's rows, not the last one's.
@(test)
test_child_by_index_deep_agrees_with_the_walk :: proc(t: ^testing.T) {
	req: json.Request({.Nodes})
	defer json.destroy(&req)
	for width in ([]int{150, 91}) {
		b: [dynamic]byte
		defer delete(b)
		append(&b, "[")
		for k in 0 ..< width {
			// A member's size varies with `width`, so the second document's rows sit elsewhere.
			if k > 0 {
				append(&b, ",")
			}
			append(&b, "[0]" if (k + width) % 3 == 0 else "1")
		}
		append(&b, "]")
		err := json.scan(b[:], &req)
		testing.expect_value(t, err, nil)
		doc := &req.doc
		walked: [dynamic]json.Node
		defer delete(walked)
		it := json.children(doc, json.ROOT)
		for j in json.children(&it) {
			append(&walked, j)
		}
		testing.expect_value(t, len(walked), width)
		#reverse for j, k in walked {
			testing.expectf(t, json.child(doc, 0, k) == j, "width %d: member %d", width, k)
		}
		testing.expect_value(t, json.child(doc, 0, width), json.NO_NODE)
	}
}

// Every reader answers "nothing" for a row index that is no row:`NO_NODE`, which navigation returns, and
// one past the last row.
@(test)
test_readers_are_total_over_no_row :: proc(t: ^testing.T) {
	doc, err := json.build(raw(`{"a":[1,"s"]}`), {dialect = .Jsonc})
	defer json.destroy(&doc)
	testing.expect(t, err == nil)
	for i in ([]json.Node{json.NO_NODE, json.Node(len(doc.rows))}) {
		k, k_ok := json.kind(&doc, i)
		testing.expectf(t, !k_ok && k == .Null, "kind(%d): %v %v", i, k, k_ok)
		_, s_ok := json.get_string(&doc, i)
		_, key_ok := json.get_key(&doc, i)
		_, i_ok := json.get_int(&doc, i)
		_, f_ok := json.get_float(&doc, i)
		testing.expectf(t, !s_ok && !key_ok && !i_ok && !f_ok, "a scalar reader answered row %d", i)
		num, num_ok := json.get_number(&doc, i)
		testing.expect(t, !num_ok && num == {})
		testing.expect(t, json.get_raw(&doc, i) == nil)
		testing.expect(t, json.child(&doc, i, 0) == json.NO_NODE)
		testing.expect(t, json.child_count(&doc, i) == 0 && json.child(&doc, i, "a") == json.NO_NODE)
		testing.expect(t, len(json.facts(&doc, i)) == 0)
		testing.expect(t, json.pointer(&doc, i, "") == json.NO_NODE && json.pointer(&doc, i, "/a") == json.NO_NODE)
		values := json.children(&doc, i)
		_, more := json.children(&values)
		testing.expect(t, !more)
		it := json.members(&doc, i)
		_, _, more = json.members(&it)
		testing.expect(t, !more)
		for text in ([]string{".", ".[0]", ".a", ".[]"}) {
			steps: [4]json.Step
			p, _ := json.parse_path(text, steps[:])
			rows: [dynamic]json.Node
			defer delete(rows)
			testing.expect(t, json.query(&doc, i, p, &rows) == nil)
			testing.expectf(t, len(rows) == 0, "query(%d, %s): %v", i, text, rows)
		}
	}
}

@(test)
test_pointer_reads_rfc_6901 :: proc(t: ^testing.T) {
	// RFC 6901 section 5's document. Each member's value is its number there.
	doc := build_ok(t, `{"foo":["bar","baz"],"":0,"a/b":1,"c%d":2,"e^f":3,"g|h":4,"i\\j":5,"k\"l":6," ":7,"m~n":8}`)
	defer json.destroy(&doc)
	foo := json.child(&doc, 0, "foo")
	testing.expect_value(t, json.pointer(&doc, 0, ""), 0)
	testing.expect_value(t, json.pointer(&doc, 0, "/foo"), foo)
	bar, _ := json.get_string(&doc, json.pointer(&doc, 0, "/foo/0"))
	testing.expect_value(t, bar, "bar")
	for c, want in ([]string{"/", "/a~1b", "/c%d", "/e^f", "/g|h", `/i\j`, `/k"l`, "/ ", "/m~0n"}) {
		got, ok := json.get_int(&doc, json.pointer(&doc, 0, c))
		testing.expectf(t, ok && got == i64(want), "pointer %s: %d %v, want %d", c, got, ok, want)
	}
	baz := json.child(&doc, foo, 1)
	testing.expect_value(t, json.pointer(&doc, foo, "/1"), baz)
	for c in ([]string {
		"/foo/01",
		"/foo/00",
		"/foo/-",
		"/foo/2",
		"/foo/+1",
		"/foo/",
		"/foo/99999999999999999999999",
		"/foo/0/x",
		"/nope",
		"foo",
		"#/foo",
		"/m~2n",
		"/m~n",
		"/m~",
	}) {
		testing.expectf(t, json.pointer(&doc, 0, c) == json.NO_NODE, "pointer %s reaches a row", c)
	}
	testing.expect_value(t, json.pointer(&doc, json.NO_NODE, ""), json.NO_NODE)
	testing.expect_value(t, json.pointer(&doc, json.Node(len(doc.rows)), ""), json.NO_NODE)

	tilde := build_ok(t, `{"~1":1,"/":2,"d":3,"d":4}`)
	defer json.destroy(&tilde)
	for c in ([]struct {
		ptr:  string,
		want: i64,
	}{{"/~01", 1}, {"/~1", 2}, {"/d", 4}}) {
		got, _ := json.get_int(&tilde, json.pointer(&tilde, 0, c.ptr))
		testing.expectf(t, got == c.want, "pointer %s: %d, want %d", c.ptr, got, c.want)
	}
}

// `pointer` and text `query` decode on the stack, or past it in the document's allocator, and never touch the
// temporary allocator: a long-running caller that never frees it must not accumulate their scratch.
@(test)
test_pointer_and_query_leave_the_temp_allocator_alone :: proc(t: ^testing.T) {
	long := strings.repeat("k", 300)
	defer delete(long)
	src := strings.concatenate({`{"`, long, `~/":1,"`, long, `\"":2,"a~b":3}`})
	defer delete(src)
	doc := build_ok(t, src)
	defer json.destroy(&doc)
	long_ptr := strings.concatenate({"/", long, "~0~1"})
	defer delete(long_ptr)
	bad_ptr := strings.concatenate({"/", long, "~2"})
	defer delete(bad_ptr)
	path := strings.concatenate({`."`, long, `\""`})
	defer delete(path)
	context.temp_allocator = runtime.panic_allocator()

	got, _ := json.get_int(&doc, json.pointer(&doc, json.ROOT, long_ptr))
	testing.expect_value(t, got, 1)
	got, _ = json.get_int(&doc, json.pointer(&doc, json.ROOT, "/a~0b"))
	testing.expect_value(t, got, 3)
	testing.expect_value(t, json.pointer(&doc, json.ROOT, bad_ptr), json.NO_NODE)

	rows: [dynamic]json.Node
	defer delete(rows)
	testing.expect_value(t, json.query(&doc, json.ROOT, path, &rows), nil)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		got, _ = json.get_int(&doc, rows[0])
		testing.expect_value(t, got, 2)
	}
}

// `get_raw` is a value's authored text, and `child` answers `NO_NODE` for a key or an index it does not hold.
@(test)
test_get_raw_and_child_misses :: proc(t: ^testing.T) {
	src :: `{"s": "a\tb", "n": -1.50, "o": {"k": [1, 2]}, "o": null}`
	doc := build_ok(t, src)
	defer json.destroy(&doc)
	testing.expect_value(t, string(json.get_raw(&doc, json.ROOT)), src)
	testing.expect_value(t, string(json.get_raw(&doc, json.child(&doc, json.ROOT, "s"))), `"a\tb"`)
	testing.expect_value(t, string(json.get_raw(&doc, json.child(&doc, json.ROOT, "n"))), `-1.50`)
	first_o := json.child(&doc, json.ROOT, 2)
	testing.expect_value(t, string(json.get_raw(&doc, first_o)), `{"k": [1, 2]}`)
	k := json.child(&doc, first_o, "k")
	testing.expect_value(t, string(json.get_raw(&doc, k)), `[1, 2]`)
	// By key, the last of repeated members.
	o_kind, _ := json.kind(&doc, json.child(&doc, json.ROOT, "o"))
	testing.expect_value(t, o_kind, json.Kind.Null)

	misses := []json.Node{
		json.child(&doc, json.ROOT, "missing"),
		json.child(&doc, json.ROOT, ""),
		json.child(&doc, json.ROOT, 4),
		json.child(&doc, json.ROOT, -100),
		json.child(&doc, k, 2),
		json.child(&doc, k, "0"),
		json.child(&doc, json.child(&doc, k, 0), 0),
		json.child(&doc, json.child(&doc, k, 0), "a"),
	}
	for m, i in misses {
		testing.expectf(t, m == json.NO_NODE, "miss %d answered %d", i, m)
	}
}

// `child` counts a negative index from the end, as `query`'s `.[-1]` does, on every route it takes (a flat
// array, a walk, the listed members past 64), one before the first member is no member.
@(test)
test_child_negative_index_counts_from_end :: proc(t: ^testing.T) {
	wide := strings.concatenate({"[", strings.repeat("[0],", 99, context.temp_allocator), "[7]]"}, context.temp_allocator)
	for src in ([]string{`[1,2,3]`, `[[1],{"a":2},3]`, wide}) {
		doc := build_ok(t, src)
		defer json.destroy(&doc)
		n := json.child_count(&doc, json.ROOT)
		// Reading past the first 64 members lists them, which `child` reads from after.
		last := json.child(&doc, json.ROOT, n - 1)
		testing.expect(t, last != json.NO_NODE)
		testing.expectf(t, json.child(&doc, json.ROOT, -1) == last, "%s: child -1", src)
		testing.expectf(t, json.child(&doc, json.ROOT, -n) == json.child(&doc, json.ROOT, 0), "%s: child -n", src)
		for i in ([]int{-n - 1, min(int)}) {
			testing.expectf(t, json.child(&doc, json.ROOT, i) == json.NO_NODE, "%s: child %d answered", src, i)
		}
		found: [dynamic]json.Node
		defer delete(found)
		testing.expect(t, json.query(&doc, json.ROOT, ".[-1]", &found) == nil)
		testing.expectf(t, len(found) == 1 && found[0] == last, "%s: .[-1] answered %v, want %d", src, found[:], last)
		clear(&found)
		testing.expect(t, json.query(&doc, json.ROOT, fmt.tprintf(".[%d]", -n - 1), &found) == nil)
		testing.expectf(t, len(found) == 0, "%s: .[-n-1] answered %v", src, found[:])
	}
}

// An escaped key keeps only its decoded bytes in the document's arena: the next one starts where it ends.
@(test)
test_document_arena_keeps_decoded_bytes_only :: proc(t: ^testing.T) {
	doc := build_ok(t, `{"a\u0062c":1,"\td":2}`)
	defer json.destroy(&doc)
	first, ok1 := json.get_key(&doc, json.child(&doc, json.ROOT, 0))
	second, ok2 := json.get_key(&doc, json.child(&doc, json.ROOT, 1))
	testing.expect(t, ok1 && ok2)
	testing.expect_value(t, first, "abc")
	testing.expect_value(t, second, "\td")
	testing.expect(t, raw_data(second) == raw_data(first)[len(first):], "the unfilled tail is handed back")
}

// A rescan reuses the decoded-string store, so a request scanning many documents holds the largest one's
// decoded strings, not their sum.
@(test)
test_rescan_reuses_the_decoded_strings :: proc(t: ^testing.T) {
	big := strings.concatenate({"[", strings.repeat(`"a\nb",`, 60_000, context.temp_allocator), `"x"]`}, context.temp_allocator)
	req: json.Request({.Dom})
	defer json.destroy(&req)
	testing.expect(t, json.scan(raw(big), &req) == nil)
	grown := cap(req.doc.values)
	testing.expectf(t, grown >= 3 * 60_000, "%d bytes hold the decoded strings", grown)
	for src in ([]string{`{"a":"b\tc"}`, big, `[1]`, big}) {
		testing.expect(t, json.scan(raw(src), &req) == nil)
		testing.expectf(t, cap(req.doc.values) == grown, "%d bytes after a rescan, want %d", cap(req.doc.values), grown)
	}
}
