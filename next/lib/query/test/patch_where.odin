package query_test

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:cbor"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/diff"
import "stury:lib/query"
import "stury:testkit"
import "stury:xml"

@(test)
value_place_doc_scalars_partial_and_cbor :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	h: query.Heap
	query.heap_init(&h, alloc)
	defer query.heap_destroy(&h)
	h.keep_origins = true

	src := transmute([]u8)string("{\n  \"flag\": true,\n  \"nil\": null,\n  \"esc\": \"a\\nb\",\n  \"arr\": [10, 20]\n}\n")
	doc, err := json.build(src, .Json, {}, alloc)
	testing.expect(t, err == nil)
	defer tape.destroy_document(&doc)

	root, rs := query.document_value(&h, doc, false)
	testing.expect_value(t, rs, query.Status.Ok)
	defer query.release(&h, root)

	// Root object.
	rp, rok := query.value_place(&h, root)
	testing.expect(t, rok && rp.line == 1 && rp.col == 1 && rp.byte == 0)

	// Boolean scalar (with keep_origins).
	fv, _ := query.member(&h, root, "flag")
	defer query.release(&h, fv)
	fp, fok := query.value_place(&h, fv)
	testing.expect(t, fok && fp.line == 2 && fp.col == 11)

	// Null scalar.
	nv, _ := query.member(&h, root, "nil")
	defer query.release(&h, nv)
	np, nok := query.value_place(&h, nv)
	testing.expect(t, nok && np.line == 3 && np.col == 10)

	// Escaped string (`BLOCK_HAS_DOC`).
	ev, _ := query.member(&h, root, "esc")
	defer query.release(&h, ev)
	ep, eok := query.value_place(&h, ev)
	testing.expect(t, eok && ep.line == 4 && ep.col == 10)

	// Constructed values return ok = false.
	built_obj, _ := query.make_object(&h, 1)
	defer query.release(&h, built_obj)
	_, bok := query.value_place(&h, built_obj)
	testing.expect(t, !bok)
	_, iok := query.value_place(&h, query.int_value(7))
	testing.expect(t, !iok)

	// Synthetic document (`fromjson`) returns ok = false.
	syn, _ := query.document_value(&h, doc, false, synthetic = true)
	defer query.release(&h, syn)
	_, sok := query.value_place(&h, syn)
	testing.expect(t, !sok)

	// CBOR document reports byte offset with line = 0, col = 0.
	cbor_bytes := []u8{0xA2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x82, 0x01, 0x02}
	cdoc, cerr := cbor.build(cbor_bytes, .Cbor, {}, alloc)
	testing.expect(t, cerr == nil)
	defer tape.destroy_document(&cdoc)
	croot, _ := query.document_value(&h, cdoc, false)
	defer query.release(&h, croot)
	cb, _ := query.member(&h, croot, "b")
	defer query.release(&h, cb)
	ce1, _ := query.element(&h, cb, 1)
	defer query.release(&h, ce1)
	cp, cok := query.value_place(&h, ce1)
	testing.expect(t, cok && cp.line == 0 && cp.col == 0 && cp.byte == 8)
}

@(test)
rfc6902_apply_patch_all_ops_errors_and_atomic_rollback :: proc(t: ^testing.T) {
	testkit.deadline(t)
	h: query.Heap
	query.heap_init(&h, runtime.heap_allocator())
	defer query.heap_destroy(&h)

	// 1. All 6 ops: add (object, array insert, `-` append), remove, replace, move, copy, test (1 == 1.0).
	{
		tgt := read_json(t, &h, `{"a":1,"arr":[10,30],"obj":{"x":"hi","y":"drop"},"a/b":"slash","m~n":"tilde"}`)
		defer query.release(&h, tgt)
		patch := read_json(t, &h, `[
			{"op":"test","path":"/a","value":1.0},
			{"op":"add","path":"/arr/1","value":20},
			{"op":"add","path":"/arr/-","value":40},
			{"op":"remove","path":"/obj/y"},
			{"op":"replace","path":"/a~1b","value":"updated"},
			{"op":"move","from":"/m~0n","path":"/moved"},
			{"op":"copy","from":"/obj/x","path":"/copied"},
			{"op":"test","path":"/arr","value":[10,20,30,40]}
		]`)
		defer query.release(&h, patch)
		want := read_json(t, &h, `{"a":1,"arr":[10,20,30,40],"obj":{"x":"hi"},"a/b":"updated","moved":"tilde","copied":"hi"}`)
		defer query.release(&h, want)

		got, s := query.apply_patch(&h, tgt, patch)
		testing.expect_value(t, s, query.Status.Ok)
		defer query.release(&h, got)
		eq, _ := query.equal(&h, got, want)
		testing.expect(t, eq)
	}

	// 2. Atomic rollback on failed `test` after prior mutating ops: shared `tgt` MUST remain completely untouched.
	{
		tgt := read_json(t, &h, `{"a":1,"nested":{"k":[1,2,3]}}`)
		defer query.release(&h, tgt)
		// Convert to built mutable object so we also prove COW rollback on heap-owned containers.
		built_tgt, _ := query.built(&h, tgt)
		defer query.release(&h, built_tgt)
		snap := read_json(t, &h, `{"a":1,"nested":{"k":[1,2,3]}}`)
		defer query.release(&h, snap)

		patch := read_json(t, &h, `[
			{"op":"replace","path":"/a","value":99},
			{"op":"add","path":"/nested/k/-","value":4},
			{"op":"remove","path":"/nested/k/0"},
			{"op":"test","path":"/a","value":1}
		]`)
		defer query.release(&h, patch)

		got, s := query.apply_patch(&h, built_tgt, patch)
		testing.expect_value(t, s, query.Status.Error)
		query.clear_error(&h)
		query.release(&h, got)

		still_same, _ := query.equal(&h, built_tgt, snap)
		testing.expect(t, still_same)
	}

	// 3. Move cycle rejection (proper prefix), self-move identical path, and strict pointer errors.
	{
		tgt := read_json(t, &h, `{"a":{"b":{"c":1}},"arr":[1,2]}`)
		defer query.release(&h, tgt)

		bad_patches := [?]string{
			`[{"op":"move","from":"/a","path":"/a/b"}]`,       // proper prefix cycle
			`[{"op":"move","from":"","path":"/a"}]`,           // root into child cycle
			`[{"op":"move","from":"/missing","path":"/x"}]`,   // missing from
			`[{"op":"remove","path":"/arr/-"}]`,               // `-` not allowed in remove
			`[{"op":"replace","path":"/arr/-","value":9}]`,    // `-` not allowed in replace
			`[{"op":"add","path":"/arr/01","value":9}]`,       // leading zero forbidden by RFC 6901
			`[{"op":"add","path":"/arr/5","value":9}]`,        // index > len
			`[{"op":"remove","path":"/nope"}]`,                // missing key
			`[{"op":"replace","path":"/nope","value":1}]`,     // missing key
			`[{"op":"add","path":"no-slash","value":1}]`,      // missing leading slash
			`[{"op":"add","path":"/bad~2","value":1}]`,        // bad escape
			`[{"op":"remove","path":""}]`,                     // cannot remove root
		}
		for bp in bad_patches {
			pv := read_json(t, &h, bp)
			got, s := query.apply_patch(&h, tgt, pv)
			testing.expectf(t, s == .Error, "expected error for %s", bp)
			query.clear_error(&h)
			query.release(&h, got)
			query.release(&h, pv)
		}

		// Identical path move `/a/b` -> `/a/b` succeeds as no-op.
		noop := read_json(t, &h, `[{"op":"move","from":"/a/b","path":"/a/b"}]`)
		defer query.release(&h, noop)
		got, s := query.apply_patch(&h, tgt, noop)
		testing.expect_value(t, s, query.Status.Ok)
		defer query.release(&h, got)
		eq, _ := query.equal(&h, got, tgt)
		testing.expect(t, eq)

		// Non-prefix `/a` -> `/ab` succeeds!
		non_prefix := read_json(t, &h, `[{"op":"move","from":"/a","path":"/ab"}]`)
		defer query.release(&h, non_prefix)
		got2, s2 := query.apply_patch(&h, tgt, non_prefix)
		testing.expect_value(t, s2, query.Status.Ok)
		defer query.release(&h, got2)
		testing.expect(t, query.has_member(&h, got2, "ab") && !query.has_member(&h, got2, "a"))
	}
}

// Randomized roundtrip proof: `apply_patch(a, diff_to_patch(a, b)) == b` across 200 random mutated trees,
// destroying `doc_b` BEFORE checking equality to prove zero dangling pointers!
@(test)
rfc6902_diff_to_patch_roundtrip :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	h: query.Heap
	query.heap_init(&h, alloc)
	defer query.heap_destroy(&h)

	keys := [?]string{"a", "b/c", "d~e", "f", ""}
	gen_json :: proc(sb: ^strings.Builder, r: rand.Generator, keys: []string, depth: int) {
		if depth >= 3 || rand.int_max(3, r) == 0 {
			switch rand.int_max(4, r) {
			case 0:
				strings.write_string(sb, "null")
			case 1:
				strings.write_string(sb, "true" if rand.int_max(2, r) == 0 else "false")
			case 2:
				fmt.sbprintf(sb, "%d", rand.int_max(12, r) - 3)
			case 3:
				fmt.sbprintf(sb, `"s%d"`, rand.int_max(8, r))
			}
			return
		}
		if rand.int_max(2, r) == 0 {
			strings.write_byte(sb, '[')
			n := rand.int_max(8, r)
			for i in 0 ..< n {
				if i > 0 {
					strings.write_byte(sb, ',')
				}
				gen_json(sb, r, keys, depth + 1)
			}
			strings.write_byte(sb, ']')
		} else {
			strings.write_byte(sb, '{')
			wrote := 0
			for k in keys {
				if rand.int_max(2, r) == 0 {
					if wrote > 0 {
						strings.write_byte(sb, ',')
					}
					fmt.sbprintf(sb, `"%s":`, k)
					gen_json(sb, r, keys, depth + 1)
					wrote += 1
				}
			}
			strings.write_byte(sb, '}')
		}
	}

	for seed in 0 ..< 200 {
		state := rand.create(u64(seed) + 101)
		r := rand.default_random_generator(&state)
		sa := strings.builder_make(context.temp_allocator)
		sb := strings.builder_make(context.temp_allocator)
		gen_json(&sa, r, keys[:], 0)
		gen_json(&sb, r, keys[:], 0)
		str_a, str_b := strings.to_string(sa), strings.to_string(sb)

		doc_a, ea := json.build(transmute([]u8)str_a, .Json, {}, alloc)
		doc_b, eb := json.build(transmute([]u8)str_b, .Json, {}, alloc)
		testing.expect(t, ea == nil && eb == nil)

		patch, perr := diff.diff_to_patch(&doc_a, &doc_b, {}, alloc)
		testing.expect(t, perr == nil)

		va, _ := query.document_value(&h, doc_a, false)
		patched, ps := query.apply_patch(&h, va, patch.ops)
		testing.expectf(t, ps == .Ok, "seed %d apply failed: %s -> %s", seed, str_a, str_b)

		// Destroy `patch` and `doc_b` BEFORE checking equality against a fresh parse of `str_b` (no dangling pointers!).
		diff.destroy_patch(&patch)
		tape.destroy_document(&doc_b)

		vb_fresh := read_json(t, &h, str_b)
		eq, _ := query.equal(&h, patched, vb_fresh)
		testing.expectf(t, eq, "seed %d roundtrip mismatch: %s -> %s", seed, str_a, str_b)

		query.release(&h, patched)
		query.release(&h, vb_fresh)
		query.release(&h, va)
		tape.destroy_document(&doc_a)
		free_all(context.temp_allocator)
	}
}

// All 15 official RFC 7396 Appendix A test vectors + deep nesting + diff_merge_patch roundtrips.
@(test)
rfc7396_merge_patch_appendix_a_and_diff :: proc(t: ^testing.T) {
	testkit.deadline(t)
	h: query.Heap
	query.heap_init(&h, runtime.heap_allocator())
	defer query.heap_destroy(&h)

	Case :: struct {
		target, patch, want: string,
	}
	vectors := [?]Case{
		{`{"a":"b"}`, `{"a":"c"}`, `{"a":"c"}`},
		{`{"a":"b"}`, `{"b":"c"}`, `{"a":"b","b":"c"}`},
		{`{"a":"b"}`, `{"a":null}`, `{}`},
		{`{"a":"b","b":"c"}`, `{"a":null}`, `{"b":"c"}`},
		{`{"a":["b"]}`, `{"a":"c"}`, `{"a":"c"}`},
		{`{"a":"c"}`, `{"a":["b"]}`, `{"a":["b"]}`},
		{`{"a":{"b":"c"}}`, `{"a":{"b":"d","c":null}}`, `{"a":{"b":"d"}}`},
		{`{"a":[{"b":"c"}]}`, `{"a":[1]}`, `{"a":[1]}`},
		{`["a","b"]`, `["c","d"]`, `["c","d"]`},
		{`{"a":"b"}`, `["c"]`, `["c"]`},
		{`{"a":"foo"}`, `null`, `null`},
		{`{"a":"foo"}`, `"bar"`, `"bar"`},
		{`{"e":null}`, `{"a":1}`, `{"e":null,"a":1}`},
		{`[1,2]`, `{"a":"b","c":null}`, `{"a":"b"}`},
		{`{}`, `{"a":{"bb":{"ccc":null}}}`, `{"a":{"bb":{}}}`},
	}

	for tc, i in vectors {
		tgt := read_json(t, &h, tc.target)
		pat := read_json(t, &h, tc.patch)
		want := read_json(t, &h, tc.want)
		got, s := query.apply_merge_patch(&h, tgt, pat)
		testing.expectf(t, s == .Ok, "vector %d status %v", i, s)
		eq, _ := query.equal(&h, got, want)
		testing.expectf(t, eq, "vector %d failed: %s + %s", i, tc.target, tc.patch)
		query.release(&h, got)
		query.release(&h, tgt)
		query.release(&h, pat)
		query.release(&h, want)
	}

	// diff_merge_patch -> apply_merge_patch roundtrip.
	{
		a := read_json(t, &h, `{"title":"Goodbye!","author":{"givenName":"John","familyName":"Doe"},"tags":["example","sample"],"content":"This will be unchanged"}`)
		b := read_json(t, &h, `{"title":"Hello!","phoneNumber":"+01-123-456-7890","author":{"givenName":"John"},"tags":["example"],"content":"This will be unchanged"}`)
		defer query.release(&h, a)
		defer query.release(&h, b)

		mp, ds := query.diff_merge_patch(&h, a, b)
		testing.expect_value(t, ds, query.Status.Ok)
		defer query.release(&h, mp)

		applied, as := query.apply_merge_patch(&h, a, mp)
		testing.expect_value(t, as, query.Status.Ok)
		defer query.release(&h, applied)

		eq, _ := query.equal(&h, applied, b)
		testing.expect(t, eq)
	}

	// Deep nesting proof (2,000 levels of nested objects) with explicit heap stack.
	{
		h_deep: query.Heap
		query.heap_init(&h_deep, runtime.heap_allocator(), depth = 3000)
		defer query.heap_destroy(&h_deep)

		build_deep_obj :: proc(h: ^query.Heap, depth: int, leaf: query.Value) -> query.Value {
			cur := leaf
			for _ in 0 ..< depth {
				o, _ := query.make_object(h, 1)
				_ = query.object_put(h, &o, query.text_borrowed("k"), cur)
				cur = o
			}
			return cur
		}
		a := build_deep_obj(&h_deep, 2000, query.int_value(1))
		b := build_deep_obj(&h_deep, 2000, query.int_value(2))
		defer query.release(&h_deep, a)
		defer query.release(&h_deep, b)

		mp, ds := query.diff_merge_patch(&h_deep, a, b)
		testing.expect_value(t, ds, query.Status.Ok)
		defer query.release(&h_deep, mp)

		applied, as := query.apply_merge_patch(&h_deep, a, mp)
		testing.expect_value(t, as, query.Status.Ok)
		defer query.release(&h_deep, applied)

		eq, es := query.equal(&h_deep, applied, b)
		testing.expect(t, es == .Ok && eq)
	}
}

// C1 + M3: XML `.Group` roundtrip through `diff_to_patch` + `apply_patch` (`built_deep`), and partial-doc taint guard.
@(test)
patch_xml_group_roundtrip_and_partial_doc_taint :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	h: query.Heap
	query.heap_init(&h, alloc)
	defer query.heap_destroy(&h)

	// C1: XML `.Group` scalar->group and nested group materialization via `built_deep`.
	for tc in ([?][3]string{
		{`<r><a>1</a></r>`, `<r><a>1</a><a>2</a></r>`, `{"r":{"a":["1","2"]}}`},
		{`<r/>`, `<r><x><a>1</a><a>2</a></x></r>`, `{"r":{"x":{"a":["1","2"]}}}`},
		{`<r><a>1</a><a>1</a></r>`, `<r><a>1</a><a>2</a></r>`, `{"r":{"a":["1","2"]}}`},
	}) {
		xa, ea := xml.build(transmute([]u8)tc[0], .Xml, {}, alloc)
		xb, eb := xml.build(transmute([]u8)tc[1], .Xml, {}, alloc)
		testing.expect(t, ea == nil && eb == nil)

		p, perr := diff.diff_to_patch(&xa, &xb, {}, alloc)
		testing.expect(t, perr == nil)

		va, _ := query.document_value(&h, xa, false)
		patched, ps := query.apply_patch(&h, va, p.ops)
		testing.expect_value(t, ps, query.Status.Ok)

		diff.destroy_patch(&p)
		tape.destroy_document(&xb)

		want := read_json(t, &h, tc[2])
		eq, _ := query.equal(&h, patched, want)
		testing.expectf(t, eq, "XML patch roundtrip failed for %s -> %s", tc[0], tc[1])

		query.release(&h, patched)
		query.release(&h, want)
		query.release(&h, va)
		tape.destroy_document(&xa)
	}

	// M3: Partial documents must fail and set `h.tainted = true` in `apply_patch`, `apply_merge_patch`, `diff_merge_patch`.
	{
		demand, derr := tape.demand_of({{tape.Name("a")}}, allocator = alloc)
		testing.expect(t, derr == nil)
		defer tape.destroy_demand(&demand)
		pdoc, perr := json.scan(transmute([]u8)string(`{"a":1,"b":2}`), &demand, .Json, {}, {}, alloc)
		testing.expect(t, perr == nil)
		defer tape.destroy_document(&pdoc)

		pv, _ := query.document_value(&h, pdoc, false)
		defer query.release(&h, pv)
		full := read_json(t, &h, `{"a":1}`)
		defer query.release(&h, full)
		empty_patch := read_json(t, &h, `[]`)
		defer query.release(&h, empty_patch)
		merge_obj := read_json(t, &h, `{"a":2}`)
		defer query.release(&h, merge_obj)

		h.tainted = false
		r1, s1 := query.apply_patch(&h, pv, []diff.Patch_Op{})
		testing.expect(t, s1 == .Error && h.tainted)
		query.clear_error(&h)
		query.release(&h, r1)

		h.tainted = false
		r2, s2 := query.apply_patch(&h, pv, empty_patch)
		testing.expect(t, s2 == .Error && h.tainted)
		query.clear_error(&h)
		query.release(&h, r2)

		h.tainted = false
		r3, s3 := query.apply_merge_patch(&h, pv, merge_obj)
		testing.expect(t, s3 == .Error && h.tainted)
		query.clear_error(&h)
		query.release(&h, r3)

		h.tainted = false
		r4, s4 := query.diff_merge_patch(&h, pv, full)
		testing.expect(t, s4 == .Error && h.tainted)
		query.clear_error(&h)
		query.release(&h, r4)
	}
}
