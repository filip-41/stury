package msgpack_tests

import "base:runtime"
import "core:bytes"
import "core:math"
import "core:testing"
import "stury:cbor"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:msgpack"
import "stury:testkit"
import "stury:yaml"

// MessagePack `write`, `write_to`, and streaming token `Writer` tests: round-trips from JSON/CBOR/MessagePack,
// shortest integer/float encodings, `sort_keys`, `ext` & Timestamp preservation/conversion, dropped facts, and OOM.

@(test)
json_and_cbor_documents_write_as_msgpack :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	json_texts := [?]string {
		`{"z":1,"aa":[true,false,null,-1,-32,-33,-128,-129,127,128,255,256,65536,4294967296,18446744073709551615,-9223372036854775808],"c":{"d":"é\n"},"e":[]}`,
		`[0.5,1.0,1e300,-0.0,100000.0,1.1]`,
		`"text"`,
		`{}`,
	}
	for src, k in json_texts {
		doc, err := json.build(transmute([]u8)src, allocator = context.temp_allocator)
		testing.expectf(t, err == nil, "%s: %v", src, err)
		for spec in msgpack.Spec {
			item, dropped, werr := msgpack.write(&doc, spec, allocator = context.temp_allocator)
			testing.expectf(t, werr == nil && dropped == {}, "%d %v: %v", k, spec, werr)
			testing.expectf(t, msgpack.validate(item, spec) == nil, "%d %v validate", k, spec)
			back, berr := msgpack.build(item, spec, allocator = context.temp_allocator)
			testing.expectf(t, berr == nil, "%d: %v", k, berr)
			testkit.values_agree(t, &doc, tape.ROOT, &back, tape.ROOT, {number_values = true}, "msgpack")
		}
	}

	// CBOR tag 0 (RFC3339), CBOR tag 1 (epoch), and binary strings convert cleanly into MessagePack timestamps & bin.
	cbor_src := hex("83 d8 18 43 010203 c0 74 323031332d30332d32315432303a30343a30305a c1 1a 514b67b0")
	cdoc, cerr := cbor.build(cbor_src, allocator = context.temp_allocator)
	testing.expect_value(t, cerr, nil)
	mp_bytes, dropped, mwerr := msgpack.write(&cdoc, .Compact, allocator = context.temp_allocator)
	testing.expect_value(t, mwerr, nil)
	// Unknown CBOR tag 24 on element 0 is dropped (`{.Tag}`), while tag 0 and 1 became MessagePack Timestamp ext -1.
	testing.expect(t, .Tag in dropped)
	mdoc, mberr := msgpack.build(mp_bytes, .Compact, allocator = context.temp_allocator)
	testing.expect_value(t, mberr, nil)
	testing.expect_value(t, mdoc.nodes[1].kind, msgpack.Kind.Bytes)
	ts0, _ := text_of(&mdoc, 2)
	ts1, _ := text_of(&mdoc, 3)
	testing.expect(t, ts0 == "2013-03-21T20:04:00Z" && ts1 == "2013-03-21T20:04:00Z")
}

@(test)
write_canonical_sort_keys_and_options :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Non-compact MessagePack compacted by `.Compact` write, keeping ext/timestamps and sorting keys.
	non_compact := hex("83 a2 6262 cc 01 a1 61 cb 3ff8000000000000 a1 74 c7 0c ff 00000000 00000000514b67b0")
	doc, err := msgpack.build(non_compact, .Msgpack, allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)

	out, dropped, werr := msgpack.write(&doc, .Compact, {sort_keys = true}, context.temp_allocator)
	testing.expect_value(t, werr, nil)
	testing.expect_value(t, dropped, msgpack.Facts{})
	testing.expect_value(t, msgpack.validate(out, .Compact), nil)
	// Sorted key order: "a" (1.5 f32), "bb" (fixint 1), "t" (TS32 0x514b67b0).
	want := hex("83 a1 61 ca 3fc00000 a2 6262 01 a1 74 d6 ff 514b67b0")
	testing.expectf(t, bytes.equal(out, want), "got %x want %x", out, want)

	// Refusals on invalid options / unspellable JSON number.
	wide_doc, _ := json.build(transmute([]u8)string(`[1.5e400]`), allocator = context.temp_allocator)
	_, _, bad_num := msgpack.write(&wide_doc, .Compact)
	testing.expect(t, bad_num != nil)
	_, _, bad_opt := msgpack.write(&doc, .Msgpack, {indent = 2})
	testing.expect(t, bad_opt != nil)
}

@(test)
token_writer_and_chunked_sink :: proc(t: ^testing.T) {
	testkit.deadline(t)
	heap_alloc := context.allocator
	defer free_all(context.temp_allocator)

	w: msgpack.Writer
	testing.expect(t, msgpack.writer_start(&w, .Compact, allocator = context.temp_allocator) == nil)
	testing.expect(t, msgpack.token(&w, .Object) == nil)
	testing.expect(t, msgpack.token(&w, .Key, "arr") == nil)
	testing.expect(t, msgpack.token(&w, .Array) == nil)
	testing.expect(t, msgpack.token(&w, .Number, "1") == nil)
	testing.expect(t, msgpack.token(&w, .Number, "NaN") == nil)
	testing.expect(t, msgpack.token(&w, .Number, "-Inf") == nil)
	testing.expect(t, msgpack.token(&w, .Close) == nil)
	testing.expect(t, msgpack.token(&w, .Key, "bin") == nil)
	testing.expect(t, msgpack.bytes(&w, {0xde, 0xad}) == nil)
	testing.expect(t, msgpack.token(&w, .Key, "ext") == nil)
	testing.expect(t, msgpack.ext(&w, 9, {0x42}) == nil)
	testing.expect(t, msgpack.token(&w, .Key, "ts1") == nil)
	testing.expect(t, msgpack.timestamp(&w, 1_700_000_000, 500) == nil)
	testing.expect(t, msgpack.token(&w, .Key, "ts2") == nil)
	testing.expect(t, msgpack.tag(&w, "datetime") == nil)
	testing.expect(t, msgpack.token(&w, .String, "2013-03-21T20:04:00Z") == nil)
	testing.expect(t, msgpack.token(&w, .Close) == nil)

	// Extra token past close must be refused as Malformed.
	testing.expect(t, msgpack.token(&w, .Null) != nil)
	encoded, err := msgpack.writer_end(&w)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, msgpack.validate(encoded, .Compact), nil)

	doc, berr := msgpack.build(encoded, .Compact, allocator = context.temp_allocator)
	testing.expect_value(t, berr, nil)
	arr_n, _ := msgpack.member({&doc, nil}, msgpack.ROOT, "arr")
	e1, _ := msgpack.element({&doc, nil}, arr_n, 1)
	e2, _ := msgpack.element({&doc, nil}, arr_n, 2)
	n1, _ := msgpack.node_number(&doc, e1)
	n2, _ := msgpack.node_number(&doc, e2)
	testing.expect(t, math.is_nan(transmute(f64)n1.bits) && math.is_inf(transmute(f64)n2.bits, -1))

	// Build a finite document for `msgpack.put` token streaming (as `NaN`/`Inf` has no decimal JSON token).
	wf: msgpack.Writer
	testing.expect(t, msgpack.writer_start(&wf, .Compact, allocator = context.temp_allocator) == nil)
	_ = msgpack.token(&wf, .Object)
	_ = msgpack.token(&wf, .Key, "n")
	_ = msgpack.token(&wf, .Number, "42")
	_ = msgpack.token(&wf, .Key, "ts")
	_ = msgpack.timestamp(&wf, 1_700_000_000, 500)
	_ = msgpack.token(&wf, .Key, "s")
	_ = msgpack.token(&wf, .String, "ok")
	_ = msgpack.token(&wf, .Close)
	f_encoded, ferr := msgpack.writer_end(&wf)
	testing.expect_value(t, ferr, nil)
	fdoc, fberr := msgpack.build(f_encoded, .Compact, allocator = context.temp_allocator)
	testing.expect_value(t, fberr, nil)

	// Chunked sink `write_to` and `put`
	for limit in ([?]int{1, 3, 7}) {
		ch: testkit.Chunked
		defer testkit.chunked_destroy(&ch)
		_, serr := msgpack.write_to(testkit.chunked_sink(&ch, limit), &doc, .Compact)
		testing.expectf(t, serr == nil && bytes.equal(ch.taken[:], encoded), "limit %d mismatch", limit)

		w2: msgpack.Writer
		ch2: testkit.Chunked
		defer testkit.chunked_destroy(&ch2)
		testing.expect(t, msgpack.writer_start(&w2, .Compact, {}, testkit.chunked_sink(&ch2, limit), heap_alloc) == nil)
		testing.expect(t, msgpack.put(&w2, &fdoc) == nil)
		_, w2err := msgpack.writer_end(&w2)
		testing.expectf(t, w2err == nil && bytes.equal(ch2.taken[:], f_encoded), "put chunked %d", limit)
	}

	// `writer_drop` frees cleanly on aborted write.
	w3: msgpack.Writer
	testing.expect(t, msgpack.writer_start(&w3, .Msgpack, allocator = heap_alloc) == nil)
	_ = msgpack.token(&w3, .Array)
	_ = msgpack.token(&w3, .String, "leak check")
	msgpack.writer_drop(&w3)
}

@(test)
write_oom_sweep :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := hex("83 a1 61 92 01 02 a1 62 a5 68656c6c6f a1 74 d6 ff 514b67b0")
	doc, err := msgpack.build(src, .Msgpack)
	testing.expect_value(t, err, nil)
	defer msgpack.destroy(&doc)

	Ctx :: struct {
		doc: ^tape.Document,
	}
	run_write :: proc(data: rawptr, a: runtime.Allocator) {
		c := (^Ctx)(data)
		out, _, werr := msgpack.write(c.doc, .Compact, {sort_keys = true}, a)
		if werr == nil {
			delete(out, a)
		} else {
			_ = werr.(runtime.Allocator_Error)
		}
	}
	c := Ctx{&doc}
	sw := testkit.sweep_failures(run_write, &c)
	testing.expectf(t, sw.bad == 0 && sw.refused >= 1, "write OOM sweep: %v", sw)
}

@(test)
dsv_tabular_write_round_trip_and_token_writer_keys :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Normal headered CSV, TSV with inference, ragged rows (`cells > keys_n` & short rows), and duplicate headers.
	cases := [?]struct {
		spec: dsv.Spec,
		opts: dsv.Options,
		src:  string,
	}{
		{.Csv, {}, "a,b\n1,2\nhello,world\n"},
		{.Tsv, {format = tape.Dsv_Options{infer = true}}, "x\ty\n10\ttrue\n20\tfalse\n"},
		{.Csv, {tolerate = {.Ragged}}, "a,b\n1,2,extra1,extra2\n3\n"},
		{.Csv, {dups = .All}, "a,a\n1,2\n3,4\n"},
		{.Csv, {dups = .First}, "a,a\n1,2\n3,4\n"},
		{.Csv, {dups = .Last}, "a,a\n1,2\n3,4\n"},
	}
	for tc, k in cases {
		ddoc, derr := dsv.build(transmute([]u8)tc.src, tc.spec, tc.opts, context.temp_allocator)
		testing.expectf(t, derr == nil, "dsv case %d build: %v", k, derr)
		for sort_keys in ([?]bool{false, true}) {
			for mspec in msgpack.Spec {
				out, dropped, werr := msgpack.write(&ddoc, mspec, {sort_keys = sort_keys}, context.temp_allocator)
				testing.expectf(t, werr == nil && dropped == {}, "dsv case %d sort=%v spec=%v: %v dropped=%v", k, sort_keys, mspec, werr, dropped)
				testing.expectf(t, msgpack.validate(out, mspec) == nil, "dsv case %d sort=%v validate: %x", k, sort_keys, out)
				back, berr := msgpack.build(out, mspec, allocator = context.temp_allocator)
				testing.expectf(t, berr == nil, "dsv case %d rebuild: %v", k, berr)
				if !sort_keys && tc.opts.dups != .All {
					testkit.values_agree(t, &ddoc, tape.ROOT, &back, tape.ROOT, {number_values = true}, "dsv->msgpack")
				} else {
					testing.expect_value(t, back.nodes[0].kind, msgpack.Kind.Array)
				}
			}
		}
	}

	// Token writer supports `.Bytes` in key position and clears stale `pending_dt` on non-datetime tags.
	w: msgpack.Writer
	testing.expect_value(t, msgpack.writer_start(&w, .Compact, allocator = context.temp_allocator), nil)
	testing.expect_value(t, msgpack.token(&w, .Object), nil)
	testing.expect_value(t, msgpack.bytes(&w, {0xca, 0xfe}), nil)
	testing.expect_value(t, msgpack.tag(&w, "datetime"), nil)
	testing.expect_value(t, msgpack.tag(&w, "!!str"), nil)
	testing.expect_value(t, msgpack.token(&w, .String, "2013-03-21T20:04:00Z"), nil)
	testing.expect_value(t, msgpack.token(&w, .Close), nil)
	tw_out, tw_err := msgpack.writer_end(&w)
	testing.expect_value(t, tw_err, nil)
	testing.expect_value(t, msgpack.validate(tw_out, .Compact), nil)
	tw_doc, tw_berr := msgpack.build(tw_out, .Compact, allocator = context.temp_allocator)
	testing.expect_value(t, tw_berr, nil)
	testing.expect_value(t, tw_doc.nodes[1].kind, msgpack.Kind.Bytes)
	testing.expect_value(t, tw_doc.nodes[2].kind, msgpack.Kind.String)
	testing.expect_value(t, len(tw_doc.facts), 0)
}

@(test)
write_refuses_foreign_bad_keys_and_reports_exact_tag_drop :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Foreign YAML documents with unsupported scalar map keys: float, bool, null -> must refuse `.No_Spelling`.
	bad_keys := [?]string{
		"1.5: 1\n",
		"true: 1\n",
		"false: 1\n",
		"null: 1\n",
	}
	for ysrc, k in bad_keys {
		ydoc, yerr := yaml.build(transmute([]u8)ysrc, .Yaml_1_2, allocator = context.temp_allocator)
		testing.expectf(t, yerr == nil, "yaml build %d (%q): %v", k, ysrc, yerr)
		for sort_keys in ([?]bool{false, true}) {
			_, _, werr := msgpack.write(&ydoc, .Compact, {sort_keys = sort_keys}, context.temp_allocator)
			ref, is_ref := werr.(msgpack.Refused)
			testing.expectf(t, is_ref && ref.why == .No_Spelling, "bad key %d sort=%v: got %v", k, sort_keys, werr)
		}
	}

	// Container keys (`.Array` and `.Object`) on a synthetic `tape.Document` must also refuse `.No_Spelling`.
	for kkind in ([?]tape.Kind{.Array, .Object}) {
		nodes := [4]tape.Node{
			{kind = .Object, role = .Value, n = 4, spelling = 1},
			{kind = kkind, role = .Key, n = 2, spelling = 1},
			{kind = .Null, role = .Value},
			{kind = .Null, role = .Value},
		}
		fdoc := tape.Document{nodes = nodes[:], format = json.as(.Json)}
		for sort_keys in ([?]bool{false, true}) {
			_, _, werr := msgpack.write(&fdoc, .Compact, {sort_keys = sort_keys}, context.temp_allocator)
			ref, is_ref := werr.(msgpack.Refused)
			testing.expectf(t, is_ref && ref.why == .No_Spelling, "container key %v sort=%v: got %v", kkind, sort_keys, werr)
		}
	}

	// Container with `.Comment` and leaf scalar with convertible `!!timestamp` `.Tag`: `.Comment` dropped, `.Tag` NOT dropped.
	yaml_src := "# container comment\nitems:\n  - !!timestamp 2013-03-21T20:04:00Z\n"
	ydoc, yerr := yaml.build(transmute([]u8)yaml_src, .Yaml_1_2, allocator = context.temp_allocator)
	testing.expect_value(t, yerr, nil)
	mp_out, dropped, mwerr := msgpack.write(&ydoc, .Compact, allocator = context.temp_allocator)
	testing.expect_value(t, mwerr, nil)
	testing.expect_value(t, msgpack.validate(mp_out, .Compact), nil)
	testing.expect(t, .Comment in dropped)
	testing.expect(t, .Tag not_in dropped)
}
