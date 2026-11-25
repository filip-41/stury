package query_test

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"
import "stury:cbor"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/query"
import "stury:testkit"
import "stury:xml"

@(test)
dsv_row_iteration_keeps_column_keys :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	src := "name,age\nalice,30\nbob,40\n"
	doc, err := dsv.build(transmute([]u8)src, .Csv, allocator = h.allocator)
	testing.expectf(t, err == nil, "csv build failed: %v", err)
	root, rs := query.document_value(h, doc, true)
	testing.expect_value(t, rs, query.Status.Ok)
	defer query.release(h, root)

	row0, es := query.element(h, root, 0)
	testing.expect_value(t, es, query.Status.Ok)
	defer query.release(h, row0)

	c, cs := query.cursor_open(h, row0)
	testing.expect_value(t, cs, query.Status.Ok)
	defer query.cursor_close(&c)

	k0, v0, m0, s0 := query.cursor_next(h, &c)
	testing.expect_value(t, s0, query.Status.Ok)
	testing.expect(t, m0)
	testing.expect_value(t, query.text_of(k0), "name")
	testing.expect_value(t, query.text_of(v0), "alice")
	query.release(h, k0)
	query.release(h, v0)

	k1, v1, m1, s1 := query.cursor_next(h, &c)
	testing.expect_value(t, s1, query.Status.Ok)
	testing.expect(t, m1)
	testing.expect_value(t, query.text_of(k1), "age")
	testing.expect_value(t, query.text_of(v1), "30")
	query.release(h, k1)
	query.release(h, v1)

	_, _, m2, s2 := query.cursor_next(h, &c)
	testing.expect_value(t, s2, query.Status.Ok)
	testing.expect(t, !m2)
}

@(test)
exact_big_int_compare_hash_and_divide :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	// .Node integers past i64 compare and hash distinctly and match .Big.
	a_node := read_json(t, h, "100000000000000000000")
	defer query.release(h, a_node)
	b_node := read_json(t, h, "100000000000000000001")
	defer query.release(h, b_node)
	testing.expect(t, query.compare_numbers(a_node, b_node) < 0)
	testing.expect(t, !query.numbers_equal(a_node, b_node))

	a_big, sa := query.num_add(h, a_node, query.int_value(0))
	testing.expect_value(t, sa, query.Status.Ok)
	defer query.release(h, a_big)
	testing.expect(t, query.numbers_equal(a_node, a_big))
	ha, hsa := query.hash(h, a_node)
	hb, hsb := query.hash(h, a_big)
	testing.expect_value(t, hsa, query.Status.Ok)
	testing.expect_value(t, hsb, query.Status.Ok)
	testing.expect_value(t, ha, hb)

	// Exact integer Big(2^64) == Double(2^64) MUST have identical hashes.
	two64_node := read_json(t, h, "18446744073709551616")
	defer query.release(h, two64_node)
	two64_big, s64 := query.num_add(h, two64_node, query.int_value(0))
	testing.expect_value(t, s64, query.Status.Ok)
	defer query.release(h, two64_big)
	two64_dbl := query.double_value(18446744073709551616.0)
	testing.expect(t, query.numbers_equal(two64_big, two64_dbl))
	h_big, _ := query.hash(h, two64_big)
	h_dbl, _ := query.hash(h, two64_dbl)
	h_nod, _ := query.hash(h, two64_node)
	testing.expect_value(t, h_big, h_dbl)
	testing.expect_value(t, h_big, h_nod)

	// +/-Inf vs +/-10^310.
	huge_zeros := strings.repeat("0", 310, context.temp_allocator)
	huge_str := strings.concatenate({"1", huge_zeros}, context.temp_allocator)
	huge_node := read_json(t, h, huge_str)
	defer query.release(h, huge_node)
	huge_big, sh := query.num_add(h, huge_node, query.int_value(0))
	testing.expect_value(t, sh, query.Status.Ok)
	defer query.release(h, huge_big)
	pos_inf := query.double_value(math.inf_f64(1))
	neg_inf := query.double_value(math.inf_f64(-1))
	testing.expect(t, query.compare_numbers(pos_inf, huge_big) > 0)
	testing.expect(t, query.compare_numbers(huge_big, pos_inf) < 0)
	testing.expect(t, query.compare_numbers(neg_inf, huge_big) < 0)
	testing.expect(t, query.compare_numbers(pos_inf, huge_node) > 0)

	// Big division when both operands exceed f64 max (10^400 / 10^399 == 10.0, not NaN).
	d400_str := strings.concatenate({"1", strings.repeat("0", 400, context.temp_allocator)}, context.temp_allocator)
	d399_str := strings.concatenate({"1", strings.repeat("0", 399, context.temp_allocator)}, context.temp_allocator)
	d400_node := read_json(t, h, d400_str)
	defer query.release(h, d400_node)
	d399_node := read_json(t, h, d399_str)
	defer query.release(h, d399_node)
	q, sq := query.num_div(h, d400_node, d399_node)
	testing.expect_value(t, sq, query.Status.Ok)
	defer query.release(h, q)
	testing.expect(t, !math.is_nan(query.as_f64(q)))
	testing.expect(t, abs(query.as_f64(q) - 10.0) < 1e-12)
}

@(test)
pivot_non_string_key_error_has_no_uaf_or_leak :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	rows := read_json(t, h, `[{"id":1,"k":123,"v":10}]`)
	defer query.release(h, rows)
	id_cols := read_json(t, h, `["id"]`)
	defer query.release(h, id_cols)
	_, s := query.pivot(h, rows, id_cols, query.text_borrowed("k"), query.text_borrowed("v"))
	testing.expect_value(t, s, query.Status.Error)
	e := query.take_error(h)
	testing.expect_value(t, e.kind, query.Error_Kind.Types)
	query.destroy_error(h, &e)
}

@(test)
rfc3339_tiny_negative_and_urid_lossy_and_cidr_v4mapped :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	// -1e-70 | torfc3339 must not overflow buffer or emit ':'.
	ts, ts_s := query.rfc3339_text(h, query.double_value(-1e-70))
	testing.expect_value(t, ts_s, query.Status.Ok)
	defer query.release(h, ts)
	ts_str := query.text_of(ts)
	testing.expect(t, len(ts_str) > 20)
	testing.expect(t, ts_str[:20] == "1969-12-31T23:59:59.")
	for c in transmute([]u8)ts_str[20:len(ts_str) - 1] {
		testing.expect(t, c >= '0' && c <= '9')
	}

	// Non-number rejected cleanly before as_f64.
	_, bad_ts := query.rfc3339_text(h, query.text_borrowed("nope"))
	testing.expect_value(t, bad_ts, query.Status.Error)
	query.clear_error(h)

	// @urid turns invalid UTF-8 bytes into U+FFFD.
	dec, ok, ds := query.percent_decode(h, "%ff", false)
	testing.expect_value(t, ds, query.Status.Ok)
	testing.expect(t, ok)
	defer query.release(h, dec)
	testing.expect_value(t, query.text_of(dec), "\uFFFD")

	// ip_in_cidr with leading :: + 5 groups + dotted IPv4 tail.
	in_net, cs := query.ip_in_cidr(h, query.text_borrowed("::1:2:3:4:5:1.2.3.4"), query.text_borrowed("::1:2:3:4:5:1.2.3.4/128"))
	testing.expect_value(t, cs, query.Status.Ok)
	testing.expect(t, in_net)

	// Invalid CIDR prefix lengths rejected.
	_, bad_cidr := query.ip_in_cidr(h, query.text_borrowed("10.0.0.1"), query.text_borrowed("10.0.0.0/33"))
	testing.expect_value(t, bad_cidr, query.Status.Error)
	query.clear_error(h)
	_, bad_cidr2 := query.ip_in_cidr(h, query.text_borrowed("10.0.0.1"), query.text_borrowed("10.0.0.0/08"))
	testing.expect_value(t, bad_cidr2, query.Status.Error)
	query.clear_error(h)
}

@(test)
pure_odin_digests_and_hmac_vectors :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	check_digest :: proc(t: ^testing.T, h: ^query.Heap, input: string, kind: query.Digest, want: string) {
		v, s := query.digest_hex(h, input, kind)
		testing.expect_value(t, s, query.Status.Ok)
		defer query.release(h, v)
		testing.expect_value(t, query.text_of(v), want)
	}
	check_digest(t, h, "abc", .Md5, "900150983cd24fb0d6963f7d28e17f72")
	check_digest(t, h, "abc", .Sha1, "a9993e364706816aba3e25717850c26c9cd0d89d")
	check_digest(t, h, "abc", .Sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	check_digest(t, h, "abc", .Sha512, "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")

	// RFC 4231 test case 2 (key = "Jefe", data = "what do ya want for nothing?")
	hm256, s256 := query.hmac_hex(h, "what do ya want for nothing?", "Jefe", .Sha256)
	testing.expect_value(t, s256, query.Status.Ok)
	defer query.release(h, hm256)
	testing.expect_value(t, query.text_of(hm256), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")

	hm512, s512 := query.hmac_hex(h, "what do ya want for nothing?", "Jefe", .Sha512)
	testing.expect_value(t, s512, query.Status.Ok)
	defer query.release(h, hm512)
	testing.expect_value(t, query.text_of(hm512), "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737")

	// Key longer than block size (131 bytes of 0xaa) — RFC 4231 test case 6.
	long_key_bytes: [131]u8
	for &b in long_key_bytes {
		b = 0xaa
	}
	hm256_long, s256l := query.hmac_hex(h, "Test Using Larger Than Block-Size Key - Hash Key First", string(long_key_bytes[:]), .Sha256)
	testing.expect_value(t, s256l, query.Status.Ok)
	defer query.release(h, hm256_long)
	testing.expect_value(t, query.text_of(hm256_long), "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
}

@(test)
radix_sort_array_without_and_batch_delete :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	// Multi-byte signed integer radix sort (n >= 64) including min(i64) and max(i64), ascending and descending.
	vals := make([]query.Value, 128)
	defer delete(vals)
	for i in 0 ..< 128 {
		switch i {
		case 0:
			vals[i] = query.int_value(max(i64))
		case 1:
			vals[i] = query.int_value(min(i64))
		case 2:
			vals[i] = query.int_value(-1)
		case 3:
			vals[i] = query.int_value(0)
		case:
			vals[i] = query.int_value(i64((i * 7919) % 100000 - 50000))
		}
	}
	testing.expect_value(t, query.sort_values(h, vals), query.Status.Ok)
	for i in 1 ..< len(vals) {
		testing.expect(t, vals[i - 1].i <= vals[i].i)
	}
	testing.expect_value(t, query.sort_values(h, vals, descending = true), query.Status.Ok)
	for i in 1 ..< len(vals) {
		testing.expect(t, vals[i - 1].i >= vals[i].i)
	}

	// array_without with len(b) > 16 (hash path).
	arr_a, sa := query.make_array(h, 64)
	testing.expect_value(t, sa, query.Status.Ok)
	defer query.release(h, arr_a)
	arr_b, sb := query.make_array(h, 32)
	testing.expect_value(t, sb, query.Status.Ok)
	defer query.release(h, arr_b)
	for i in 0 ..< 64 {
		testing.expect_value(t, query.append_owned(h, &arr_a, query.int_value(i64(i))), query.Status.Ok)
	}
	for i in 0 ..< 32 {
		testing.expect_value(t, query.append_owned(h, &arr_b, query.int_value(i64(i * 2))), query.Status.Ok)
	}
	diff, sd := query.array_without(h, arr_a, arr_b)
	testing.expect_value(t, sd, query.Status.Ok)
	defer query.release(h, diff)
	testing.expect_value(t, len(query.items_of(diff)), 32)
	for item, idx in query.items_of(diff) {
		testing.expect_value(t, item.i, i64(idx * 2 + 1))
	}

	// Batch object delete (> SMALL_ENTRIES) keeps remaining keys searchable.
	obj, so := query.make_object(h, 32)
	testing.expect_value(t, so, query.Status.Ok)
	defer query.release(h, obj)
	for i in 0 ..< 32 {
		buf: [16]u8
		ks := fmt.bprintf(buf[:], "k%d", i)
		kv, ks_s := query.text_value(h, ks)
		testing.expect_value(t, ks_s, query.Status.Ok)
		testing.expect_value(t, query.object_put(h, &obj, kv, query.int_value(i64(i))), query.Status.Ok)
	}
	del_list := make([]query.Value, 16)
	defer {
		for k in del_list {
			query.release(h, k)
		}
		delete(del_list)
	}
	for i in 0 ..< 16 {
		buf: [16]u8
		ks := fmt.bprintf(buf[:], "k%d", i * 2)
		kv, ks_s := query.text_value(h, ks)
		testing.expect_value(t, ks_s, query.Status.Ok)
		del_list[i] = kv
	}
	testing.expect_value(t, query.object_delete_many(h, &obj, del_list), query.Status.Ok)
	testing.expect_value(t, query.length_of(h, obj), 16)
	for i in 0 ..< 32 {
		buf: [16]u8
		ks := fmt.bprintf(buf[:], "k%d", i)
		testing.expect_value(t, query.has_member(h, obj, ks), i % 2 == 1)
	}
}

@(test)
guard_empty_partial_document_taints_heap :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	// Partial document with no root node sets h.tainted = true via tape.root.
	demand, derr := tape.demand_of({{tape.Name("missing")}})
	testing.expect(t, derr == nil)
	defer tape.destroy_demand(&demand)
	doc, err := json.scan(transmute([]u8)string(`{"other":1}`), &demand, allocator = h.allocator)
	testing.expect(t, err == nil)
	v, s := query.document_value(h, doc, true)
	testing.expect_value(t, s, query.Status.Ok)
	defer query.release(h, v)
	if v.kind == .Absent {
		testing.expect(t, h.tainted)
	} else {
		// equal(v, v) must not take the pointer shortcut on a partial document; touching its unloaded members taints h.
		_, _ = query.equal(h, v, v)
		query.clear_error(h)
		testing.expect(t, h.tainted)
	}
}

@(test)
regex_compile_oom_fails_cleanly :: proc(t: ^testing.T) {
	testkit.deadline(t)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer {
		testing.expect_value(t, len(track.allocation_map), 0)
		mem.tracking_allocator_destroy(&track)
	}
	h: query.Heap
	query.heap_init(&h, mem.tracking_allocator(&track), 64)
	defer query.heap_destroy(&h)
	cache: query.Regex_Cache
	defer query.regex_cache_destroy(&cache)
	re, s := query.regex_compile(&h, &cache, query.text_borrowed("(a+)+b[0-9]{1,5}c(d|e|f)+"), .Ecma, {})
	testing.expect(t, re == nil)
	testing.expect_value(t, s, query.Status.Error)
	e := query.take_error(&h)
	testing.expect_value(t, e.kind, query.Error_Kind.Memory)
	query.destroy_error(&h, &e)
}

@(test)
partial_array_slice_element_and_object_hash_paths :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	// Partial JSON array slice [0:32] exercises indexed `tape.element` on `CONTAINER_PARTIAL` arrays (> INDEX_ELEMENTS).
	b := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"items":[`)
	for i in 0 ..< 48 {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		fmt.sbprintf(&b, `{{"id":%d,"status":%d,"pad":"item_%d"}}`, i, 200 + (i % 5), i)
	}
	strings.write_string(&b, `]}`)
	src := strings.to_string(b)

	demand, derr := tape.demand_of({
		{tape.Name("items"), tape.Slice{lo = 0, hi = 32}, tape.Name("id")},
		{tape.Name("items"), tape.Slice{lo = 0, hi = 32}, tape.Name("status")},
	})
	testing.expect(t, derr == nil)
	defer tape.destroy_demand(&demand)

	doc, serr := json.scan(transmute([]u8)src, &demand, allocator = h.allocator)
	testing.expectf(t, serr == nil, "scan failed: %v src=%q", serr, src[:min(len(src), 60)])
	if serr != nil {
		return
	}
	// Exercise both unindexed and indexed `tape.element` directly on the partial array (crossing INDEX_ELEMENTS = 16).
	{
		idx: tape.Doc_Index
		idx.allocator = context.allocator
		defer tape.destroy_index(&idx)
		items_node, mp := tape.member({&doc, nil}, tape.ROOT, "items")
		testing.expect_value(t, mp, tape.Presence.Found)
		for indexed in ([]bool{false, true}) {
			r := tape.Reader{&doc, &idx if indexed else nil}
			for i in 0 ..< 48 {
				_, ep := tape.element(r, items_node, i)
				testing.expect_value(t, ep, tape.Presence.Found if i < 32 else tape.Presence.Not_Loaded)
			}
			_, p_neg_miss := tape.element(r, items_node, -1)
			testing.expect_value(t, p_neg_miss, tape.Presence.Not_Loaded)
			_, p_neg_hit := tape.element(r, items_node, -48)
			testing.expect_value(t, p_neg_hit, tape.Presence.Found)
			_, p_oob := tape.element(r, items_node, 48)
			testing.expect_value(t, p_oob, tape.Presence.Missing)
		}
	}
	root, rs := query.document_value(h, doc, true)
	testing.expect_value(t, rs, query.Status.Ok)
	defer query.release(h, root)

	items, ms := query.member(h, root, "items")
	testing.expect_value(t, ms, query.Status.Ok)
	defer query.release(h, items)

	for i in 0 ..< 32 {
		el, es := query.element(h, items, i)
		testing.expect_value(t, es, query.Status.Ok)
		idv, is := query.member(h, el, "id")
		testing.expect_value(t, is, query.Status.Ok)
		id_i, ok := query.as_i64(idv)
		testing.expect(t, ok && id_i == i64(i))
		query.release(h, idv)
		query.release(h, el)
	}
	testing.expect(t, !h.tainted)

	// Sparse partial array (even indices 0,2,...,38 out of 48) exercises binary search in `kept_lookup`.
	{
		paths := make([][]tape.Step, 20, context.allocator)
		defer {
			for p in paths {
				delete(p)
			}
			delete(paths)
		}
		for i in 0 ..< 20 {
			p := make([]tape.Step, 3, context.allocator)
			p[0], p[1], p[2] = tape.Name("items"), tape.Index(i * 2), tape.Name("id")
			paths[i] = p
		}
		sdem, sderr := tape.demand_of(paths)
		testing.expect(t, sderr == nil)
		defer tape.destroy_demand(&sdem)
		sdoc, sserr := json.scan(transmute([]u8)src, &sdem, allocator = context.allocator)
		testing.expect(t, sserr == nil)
		defer tape.destroy_document(&sdoc)
		sidx: tape.Doc_Index
		sidx.allocator = context.allocator
		defer tape.destroy_index(&sidx)
		sitems, smp := tape.member({&sdoc, nil}, tape.ROOT, "items")
		testing.expect_value(t, smp, tape.Presence.Found)
		for indexed in ([]bool{false, true}) {
			r := tape.Reader{&sdoc, &sidx if indexed else nil}
			for i in 0 ..< 48 {
				_, ep := tape.element(r, sitems, i)
				want := tape.Presence.Found if (i < 40 && i % 2 == 0) else tape.Presence.Not_Loaded
				testing.expect_value(t, ep, want)
			}
		}
	}

	// Built object with short (0..8B) and long (>16B) keys across slot table growth and overwrites.
	obj, os := query.make_object(h, 4)
	testing.expect_value(t, os, query.Status.Ok)
	defer query.release(h, obj)
	for i in 0 ..< 40 {
		buf: [48]u8
		ks := ""
		if i == 0 {
			ks = ""
		} else if i < 20 {
			ks = fmt.bprintf(buf[:], "k%d", i)
		} else {
			ks = fmt.bprintf(buf[:], "long_object_key_prefix_%02d_suffix", i)
		}
		kv, kvs := query.text_value(h, ks)
		testing.expect_value(t, kvs, query.Status.Ok)
		testing.expect_value(t, query.object_put(h, &obj, kv, query.int_value(i64(i))), query.Status.Ok)
	}
	// Overwrite existing short and long keys.
	for ks in ([]string{"", "k7", "long_object_key_prefix_25_suffix"}) {
		kv, kvs := query.text_value(h, ks)
		testing.expect_value(t, kvs, query.Status.Ok)
		testing.expect_value(t, query.object_put(h, &obj, kv, query.int_value(999)), query.Status.Ok)
		got, gs := query.member(h, obj, ks)
		testing.expect_value(t, gs, query.Status.Ok)
		v_i, ok := query.as_i64(got)
		testing.expect(t, ok && v_i == 999)
		query.release(h, got)
	}
	testing.expect_value(t, query.length_of(h, obj), 40)
}

@(test)
cbor_negative_ints_and_bignum_query_and_json :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	// CBOR array: [-17, -24, -49, 2^64, 2^64 + 1].
	// -17 is 0x30 ('0'), -24 is 0x37 ('7'), -49 is 0x38 0x30 ("80"): raw bytes look like JSON numerals!
	src := [?]u8{
		0x85,
		0x30,
		0x37,
		0x38, 0x30,
		0xc2, 0x49, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0xc2, 0x49, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
	}
	doc, err := cbor.build(src[:], .Cbor, allocator = h.allocator)
	testing.expectf(t, err == nil, "cbor build failed: %v", err)
	root, rs := query.document_value(h, doc, true)
	testing.expect_value(t, rs, query.Status.Ok)
	defer query.release(h, root)

	out := make([dynamic]u8, h.allocator)
	defer delete(out)
	testing.expect_value(t, query.write_json(h, &out, root), query.Status.Ok)
	testing.expect_value(t, string(out[:]), "[-17,-24,-49,18446744073709551616,18446744073709551617]")

	for idx in 3 ..= 4 {
		big_elem, es := query.element(h, root, idx)
		testing.expect_value(t, es, query.Status.Ok)
		defer query.release(h, big_elem)
		testing.expect(t, query.is_integer(big_elem))
		testing.expect(t, abs(query.as_f64(big_elem) - 18446744073709551616.0) == 0)
		num, ns := query.number_of(h, big_elem)
		testing.expect_value(t, ns, query.Status.Ok)
		defer query.release(h, num)
		testing.expect_value(t, num.kind, query.Kind.Big)
	}
}

@(test)
xml_grouped_propagates_partial_flag :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	src := `<root><x><a/></x><x><b/></x></root>`
	doc, err := xml.build(transmute([]u8)src, .Xml, allocator = h.allocator)
	testing.expectf(t, err == nil, "xml build failed: %v", err)
	part, perr := tape.partial_block(0, 0, 0, 0, 0, .Group, h.allocator)
	testing.expect(t, perr == nil)
	doc.partial = part
	// Mark the second `<x>` element's object value as partial while keeping the first complete.
	seen := 0
	for &n, i in doc.nodes {
		if n.kind == .Object && i > 1 {
			seen += 1
			if seen == 2 {
				n.spelling |= tape.CONTAINER_PARTIAL
				break
			}
		}
	}
	testing.expect_value(t, seen, 2)
	root, rs := query.document_value(h, doc, true)
	testing.expect_value(t, rs, query.Status.Ok)
	defer query.release(h, root)

	el, es := query.member(h, root, "root")
	testing.expect_value(t, es, query.Status.Ok)
	defer query.release(h, el)
	built_el, bs := query.built(h, el)
	testing.expect_value(t, bs, query.Status.Ok)
	defer query.release(h, built_el)
	testing.expect(t, query.value_has_partial(built_el))
}
