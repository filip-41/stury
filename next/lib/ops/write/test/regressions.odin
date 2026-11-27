package write_tests

import "base:runtime"
import "core:mem"
import "core:testing"
import "stury:cbor"
import "stury:dsv"
import "stury:json"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:testkit"
import "stury:yaml"

// Regression tests for Waves 1-4 fixes across `write`, `tokens`, `token_tape`, `text`, `tree`, and `table`.

@(test)
out_empty_buffer_finish_and_compact_and_size_hint :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// P9: `out_finish` on 0-byte buffer write frees its backing block and returns `nil, nil`.
	out: write.Out
	testing.expect_value(t, write.out_start(&out, context.allocator, {}, write.ROOM_MAX), nil)
	text, err := write.out_finish(&out)
	testing.expect_value(t, err, nil)
	testing.expect(t, text == nil && len(text) == 0)
	// Safe to call `out_drop` after `out_finish` because `out^` was zeroed.
	write.out_drop(&out)

	// P9: `out_start` with zero or nil allocator fails cleanly with `.Out_Of_Memory`.
	for bad in ([?]runtime.Allocator{{}, mem.nil_allocator()}) {
		o: write.Out
		testing.expect_value(t, write.out_start(&o, bad, {}, write.ROOM_MAX), runtime.Allocator_Error.Out_Of_Memory)
	}

	// P11: `compact` combinations.
	testing.expect(t, write.compact({}))
	testing.expect(t, !write.compact({indent = 2}))
	testing.expect(t, !write.compact({tab = true}))
	testing.expect(t, !write.compact({indent = 2, tab = true}))

	// P11: `opts.node != ROOT`, `tape.NO_NODE`, and `indent = 255`.
	doc, berr := json.build(transmute([]u8)string(`{"a":[1,2,3],"b":"leaf"}`))
	defer json.destroy(&doc)
	testing.expect_value(t, berr, nil)
	leaf, p := json.member({&doc, nil}, json.ROOT, "b")
	testing.expect_value(t, p, tape.Presence.Found)
	sub, _, serr := json.write(&doc, .Json, {node = leaf})
	defer delete(sub)
	testing.expectf(t, serr == nil && string(sub) == `"leaf"`, "subtree write: %q %v", sub, serr)
	_, _, no_err := json.write(&doc, .Json, {node = tape.NO_NODE})
	testing.expect_value(t, no_err, json.Write_Error(tape.Bad_Option{"node"}))
	big_ind, _, ierr := json.write(&doc, .Json, {indent = 255})
	defer delete(big_ind)
	testing.expect_value(t, ierr, nil)
}

@(test)
text_cbor_unspellable_and_json5_number_edges :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// P12: CBOR unspellable bigfloat (`c5 82 19 13 89 01`) returns `.No_Spelling` instead of leaking raw wire bytes.
	raw := []u8{0xC5, 0x82, 0x19, 0x13, 0x89, 0x01}
	cdoc, cerr := cbor.build(raw)
	defer cbor.destroy(&cdoc)
	testing.expect_value(t, cerr, nil)
	jout, _, jerr := json.write(&cdoc, .Json)
	delete(jout)
	r, refused := jerr.(write.Refused)
	testing.expectf(t, refused && r.why == .No_Spelling, "unspellable cbor bigfloat: %q %v", jout, jerr)

	// P12: JSON5 negative-zero hex consistency (`-0x0` == `-0x0000000000000000` == `"0"`) and leading-zero fast path.
	for c in ([?]struct{ src, want: string }{
		{"-0x0", "0"},
		{"-0x0000000000000000", "0"},
		{"-0x00000000000000000000", "0"},
		{"0x00000000000000000001", "1"},
		{"-0x00000000000000000001", "-1"},
	}) {
		j5, err := json.build(transmute([]u8)c.src, .Json5)
		defer json.destroy(&j5)
		testing.expect_value(t, err, nil)
		out, _, werr := json.write(&j5, .Json)
		defer delete(out)
		testing.expectf(t, werr == nil && string(out) == c.want, "%s -> %q (%v), want %q", c.src, out, werr, c.want)
	}

	// P12: Synthetic multi-dot / digitless JSON5 decimals do not overflow or turn into `"0.0"` / `"0.0e5"`.
	wide_fmt := tape.Format{
		name = "test",
		number = proc "contextless" (src: []u8, t: tape.Node) -> spell.Number {
			return {kind = .Wide}
		},
	}
	for bad in ([?]string{"1.2.3", ".", ".e5", "........................................"}) {
		nodes := [?]tape.Node{{kind = .Number, role = .Value, lo = 0, n = u32(len(bad))}}
		syn := tape.Document{src = transmute([]u8)bad, nodes = nodes[:], format = &wide_fmt}
		wt: write.Tree
		testing.expect_value(t, write.tree_start(&wt, &syn, {}, {}, context.allocator), nil)
		defer write.tree_end(&wt)
		buf: [write.NUMBER_ROOM]u8
		s, ok := write.number_text(&wt, 0, &buf)
		testing.expectf(t, !ok, "bad decimal %q unexpectedly spelled as %q", bad, s)
	}
}

@(test)
tree_sort_keys_oom_and_no_dups_container_key :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// P14: `sort_keys = true` OOM sweep (including escaped keys cloned out of `w.scratch`).
	src := `{"b\n1":1,"a\u00e9":2,"c":3,"d\t4":{"z\n":9,"a\n":8}}`
	doc, err := json.build(transmute([]u8)src)
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil)
	Sort_Run :: struct {
		doc: ^json.Document,
	}
	run := Sort_Run{&doc}
	s := testkit.sweep_failures(proc(data: rawptr, a: runtime.Allocator) {
		r := (^Sort_Run)(data)
		text, _, werr := json.write(r.doc, .Json, {sort_keys = true}, a)
		if werr == nil {
			delete(text, a)
		} else {
			_ = werr.(runtime.Allocator_Error)
		}
	}, &run)
	testing.expectf(t, s.bad == 0 && s.refused >= 1, "sort_keys oom sweep: %v", s)

	// P14: Container key between duplicate `""` keys does not mask `no_dups` in `sort_members`.
	syn_src := "123"
	syn_nodes := [?]tape.Node{
		{kind = .Object, role = .Value, n = 8, spelling = 3},
		{kind = .String, role = .Key, lo = 0, n = 0},
		{kind = .Number, role = .Value, lo = 0, n = 1},
		{kind = .Array, role = .Key, n = 2, spelling = 1},
		{kind = .Number, role = .Value, lo = 1, n = 1},
		{kind = .Number, role = .Value, lo = 1, n = 1},
		{kind = .String, role = .Key, lo = 0, n = 0},
		{kind = .Number, role = .Value, lo = 2, n = 1},
	}
	syn_doc := tape.Document{src = transmute([]u8)syn_src, nodes = syn_nodes[:], format = json.as(.Json)}
	wt: write.Tree
	testing.expect_value(t, write.tree_start(&wt, &syn_doc, {sort_keys = true}, {}, context.allocator), nil)
	defer write.tree_end(&wt)
	wt.no_dups = true
	step := write.tree_next(&wt, false, false)
	testing.expect(t, step.kind == .Done)
	r, refused := wt.err.(write.Refused)
	testing.expectf(t, refused && r.why == .No_Spelling, "dup empty key masked by container key: %v", wt.err)
}

@(test)
table_bug_regressions :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// P16 Bug 1 (HIGH SEGFAULT): empty column-0 header with `comment != 0` and >= 2 columns.
	jdoc, jerr := json.build(transmute([]u8)string(`[{"":1,"b":2}]`))
	defer json.destroy(&jdoc)
	testing.expect_value(t, jerr, nil)
	jcsv, _, jwerr := dsv.write(&jdoc, .Csv, {format = dsv.Dsv_Options{comment = '#'}})
	defer delete(jcsv)
	testing.expectf(t, jwerr == nil && string(jcsv) == ",b\n1,2\n", "empty col-0 header json: %q %v", jcsv, jwerr)

	w: dsv.Writer
	testing.expect_value(t, dsv.writer_start(&w, .Csv, {header = {"", "b"}, format = dsv.Dsv_Options{comment = '#'}}), nil)
	testing.expect_value(t, dsv.token(&w, .Object), nil)
	testing.expect_value(t, dsv.token(&w, .Key, ""), nil)
	testing.expect_value(t, dsv.token(&w, .Number, "1"), nil)
	testing.expect_value(t, dsv.token(&w, .Key, "b"), nil)
	testing.expect_value(t, dsv.token(&w, .Number, "2"), nil)
	testing.expect_value(t, dsv.token(&w, .Close), nil)
	wcsv, wwerr := dsv.writer_end(&w)
	defer delete(wcsv)
	testing.expectf(t, wwerr == nil && string(wcsv) == ",b\n1,2\n", "empty col-0 header writer: %q %v", wcsv, wwerr)

	// P16 Bug 2 (HIGH OOB panic): `dsv.write(&csv_doc, .Csv, {node = row0})` on odd- and even-width Tabular_Ext rows.
	for c in ([?]struct{ src, want: string }{
		{"a,b,c\n1,2,3\n4,5,6\n", "a,b,c\n1,2,3\n"},
		{"a,b\n1,2\n3,4\n", "a,b\n1,2\n"},
	}) {
		cdoc, cerr := dsv.build(transmute([]u8)c.src, .Csv)
		defer dsv.destroy(&cdoc)
		testing.expect_value(t, cerr, nil)
		row0, p := dsv.element({&cdoc, nil}, dsv.ROOT, 0)
		testing.expect_value(t, p, tape.Presence.Found)
		out, _, werr := dsv.write(&cdoc, .Csv, {node = row0})
		defer delete(out)
		testing.expectf(t, werr == nil && string(out) == c.want, "single tabular row %q -> %q (%v)", c.src, out, werr)
	}

	// P16 Bug 3 (HIGH blank-line data loss): duplicate header collapsed to 1 column whose kept cell is `.Null`.
	for c in ([?]struct{ src: string, dups: tape.Duplicates }{
		{"a,a\n1,\n", .Last},
		{"a,a\n,1\n", .First},
	}) {
		cdoc, cerr := dsv.build(transmute([]u8)c.src, .Csv, {dups = c.dups})
		defer dsv.destroy(&cdoc)
		testing.expect_value(t, cerr, nil)
		out, _, werr := dsv.write(&cdoc, .Csv)
		delete(out)
		r, refused := werr.(write.Refused)
		testing.expectf(t, refused && r.why == .No_Spelling, "dup single null %q %v: %q %v", c.src, c.dups, out, werr)
	}

	// P16 Bug 4: `same_key` does not conflate `.Null` key with empty `.String` key.
	ydoc, yerr := yaml.build(transmute([]u8)string("- null: 1\n  \"\": 2\n"))
	defer yaml.destroy(&ydoc)
	testing.expect_value(t, yerr, nil)
	ycsv, _, ywerr := dsv.write(&ydoc, .Csv)
	defer delete(ycsv)
	testing.expectf(t, ywerr == nil && string(ycsv) == "null,\n1,2\n", "yaml null vs empty key: %q %v", ycsv, ywerr)

	// P16 Bug 6: `table_writer_start` rejects non-zero `opts.node`, `indent`, `ascii`, out-of-range `framing`.
	bad_w: dsv.Writer
	testing.expect_value(t, dsv.writer_start(&bad_w, .Csv, {node = 1}), dsv.Write_Error(tape.Bad_Option{"node"}))
	testing.expect_value(t, dsv.writer_start(&bad_w, .Csv, {indent = 2}), dsv.Write_Error(tape.Bad_Option{"indent"}))
	testing.expect_value(t, dsv.writer_start(&bad_w, .Csv, {ascii = true}), dsv.Write_Error(tape.Bad_Option{"ascii"}))
	testing.expect_value(t, dsv.writer_start(&bad_w, .Csv, {framing = write.Record_Framing(9)}), dsv.Write_Error(tape.Bad_Option{"framing"}))

	// P16 Bug 7: short ragged delimited rows under `sort_keys` and `dups = .Last`.
	rag1, r1err := dsv.build(transmute([]u8)string("b,a\n1\n"), .Csv, {tolerate = {.Ragged}})
	defer dsv.destroy(&rag1)
	testing.expect_value(t, r1err, nil)
	rag1_out, _, rag1_werr := dsv.write(&rag1, .Csv, {sort_keys = true})
	defer delete(rag1_out)
	testing.expectf(t, rag1_werr == nil && string(rag1_out) == "a,b\n,1\n", "short ragged sort_keys: %q %v", rag1_out, rag1_werr)

	rag2, r2err := dsv.build(transmute([]u8)string("a,b,a\n1,2\n"), .Csv, {dups = .Last, tolerate = {.Ragged}})
	defer dsv.destroy(&rag2)
	testing.expect_value(t, r2err, nil)
	rag2_out, _, rag2_werr := dsv.write(&rag2, .Csv)
	defer delete(rag2_out)
	testing.expectf(t, rag2_werr == nil && string(rag2_out) == "b,a\n2,1\n", "short ragged dup .Last: %q %v", rag2_out, rag2_werr)

	// P16 Bug 5: `Table_Writer` OOM sweep across explicit header, streaming header, and `grow_header`.
	for mode in 0 ..< 3 {
		m := mode
		s := testkit.sweep_failures(proc(data: rawptr, a: runtime.Allocator) {
			mode := (^int)(data)^
			opts: dsv.Write_Options
			switch mode {
			case 0:
				opts = {header = {"a", "b"}}
			case 1:
				opts = {}
			case 2:
				opts = {grow_header = true}
			}
			tw: dsv.Writer
			if err := dsv.writer_start(&tw, .Csv, opts, {}, a); err != nil {
				_ = err.(runtime.Allocator_Error)
				return
			}
			for step in ([?]struct{ kind: write.Token_Kind, text: string }{
				{.Array, ""}, {.Object, ""}, {.Key, "a"}, {.String, "1"}, {.Key, "b"}, {.String, "2"}, {.Close, ""}, {.Close, ""},
			}) {
				if err := dsv.token(&tw, step.kind, step.text); err != nil {
					_ = err.(runtime.Allocator_Error)
					dsv.writer_drop(&tw)
					return
				}
			}
			out, eerr := dsv.writer_end(&tw)
			if eerr == nil {
				delete(out, a)
			} else {
				_ = eerr.(runtime.Allocator_Error)
			}
		}, &m)
		testing.expectf(t, s.bad == 0 && s.refused >= 1, "Table_Writer mode %d oom sweep: %v", mode, s)
	}
}

@(test)
sequence_and_token_tape_and_tokens_of_regressions :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// P18: `Sequence` deep nesting past 64 levels inside objects after `.Key`, framed empty done, `max_depth`, and OOM.
	seq: write.Sequence
	write.sequence_start(&seq, true, 0, context.allocator)
	defer write.sequence_drop(&seq)
	testing.expect(t, write.sequence_done(&seq))
	for _ in 0 ..< 80 {
		_, e1 := write.sequence_take(&seq, .Object)
		testing.expect_value(t, e1, nil)
		_, e2 := write.sequence_take(&seq, .Key)
		testing.expect_value(t, e2, nil)
	}
	_, ev := write.sequence_take(&seq, .Null)
	testing.expect_value(t, ev, nil)
	for _ in 0 ..< 80 {
		_, ec := write.sequence_take(&seq, .Close)
		testing.expect_value(t, ec, nil)
	}
	testing.expect(t, write.sequence_done(&seq))

	// `max_depth` refusal leaves sequence valid.
	lim: write.Sequence
	write.sequence_start(&lim, false, 2, context.allocator)
	defer write.sequence_drop(&lim)
	_, _ = write.sequence_take(&lim, .Array)
	_, _ = write.sequence_take(&lim, .Array)
	_, deep_err := write.sequence_take(&lim, .Array)
	dr, dok := deep_err.(write.Refused)
	testing.expectf(t, dok && dr.why == .Malformed, "max_depth refusal: %v", deep_err)
	_, ok_val := write.sequence_take(&lim, .Null)
	testing.expect_value(t, ok_val, nil)

	// P19: `Token_Tape` populates `.Number` `node.spelling` so `tape.number_form` distinguishes floats/exponents/ints.
	tt: write.Token_Tape
	testing.expect_value(t, write.token_tape_start(&tt, false, 0, context.allocator), nil)
	defer write.token_tape_drop(&tt)
	testing.expect_value(t, write.token_tape_take(&tt, .Array, ""), nil)
	testing.expect_value(t, write.token_tape_take(&tt, .Number, "1.5"), nil)
	testing.expect_value(t, write.token_tape_take(&tt, .Number, "1e2"), nil)
	testing.expect_value(t, write.token_tape_take(&tt, .Number, "42"), nil)
	testing.expect_value(t, write.token_tape_take(&tt, .Close, ""), nil)
	tt_doc, derr := write.token_tape_document(&tt)
	testing.expect_value(t, derr, nil)
	f0, ok0 := tape.number_form(&tt_doc, 1)
	f1, ok1 := tape.number_form(&tt_doc, 2)
	f2, ok2 := tape.number_form(&tt_doc, 3)
	testing.expectf(t, ok0 && f0.int_digits == 1 && f0.frac_digits == 1 && !f0.exponent, "1.5 form: %v %v", f0, ok0)
	testing.expectf(t, ok1 && f1.exponent && f1.frac_digits == 0, "1e2 form: %v %v", f1, ok1)
	testing.expectf(t, ok2 && !f2.point && !f2.exponent && f2.frac_digits == 0, "42 form: %v %v", f2, ok2)

	// P19: `token_tape_document` is idempotent on `framed = true` with >= `MAX_CHILDREN` roots.
	many: write.Token_Tape
	testing.expect_value(t, write.token_tape_start(&many, true, 0, context.allocator), nil)
	defer write.token_tape_drop(&many)
	total_roots := int(tape.MAX_CHILDREN) + 2
	for _ in 0 ..< total_roots {
		testing.expect_value(t, write.token_tape_take(&many, .Null, ""), nil)
	}
	d1, e1 := write.token_tape_document(&many)
	testing.expect_value(t, e1, nil)
	d2, e2 := write.token_tape_document(&many)
	testing.expect_value(t, e2, nil)
	testing.expect_value(t, len(d1.counts), 1)
	testing.expect_value(t, len(d2.counts), 1)
	testing.expect_value(t, tape.child_count(&d2, tape.ROOT, d2.nodes[0]), total_roots)

	// P19: `token_tape_take` OOM rollback leaves `t` consistent (a subsequent `.Close` never panics).
	oom_tt := testkit.sweep_failures(proc(data: rawptr, a: runtime.Allocator) {
		_ = data
		tp: write.Token_Tape
		if err := write.token_tape_start(&tp, true, 0, a); err != nil {
			return
		}
		defer write.token_tape_drop(&tp)
		for step in ([?]struct{ kind: write.Token_Kind, text: string }{
			{.Object, ""}, {.Key, "long_key_name"}, {.Array, ""}, {.Number, "1.5"}, {.String, "payload"}, {.Close, ""}, {.Close, ""},
		}) {
			if err := write.token_tape_take(&tp, step.kind, step.text); err != nil {
				// Calling `.Close` after an OOM must never panic even if the open container failed to push.
				_ = write.token_tape_take(&tp, .Close, "")
				return
			}
		}
	}, nil)
	testing.expectf(t, oom_tt.bad == 0 && oom_tt.refused >= 1, "token_tape oom sweep: %v", oom_tt)

	// P20: `tokens_of` rejects container keys before calling `text_of` (no OOB slice even when `lo + n > len(src)`).
	ck_src := "3"
	ck_nodes := [?]tape.Node{
		{kind = .Object, role = .Value, n = 5, spelling = 1},
		{kind = .Array, role = .Key, lo = 1, n = 3, spelling = 2},
		{kind = .Number, role = .Value, lo = 0, n = 1},
		{kind = .Number, role = .Value, lo = 0, n = 1},
		{kind = .Number, role = .Value, lo = 0, n = 1},
	}
	ck_doc := tape.Document{src = transmute([]u8)ck_src, nodes = ck_nodes[:], format = json.as(.Json)}
	jw: json.Writer
	testing.expect_value(t, json.writer_start(&jw), nil)
	defer json.writer_drop(&jw)
	put_err := json.put(&jw, &ck_doc)
	pr, pok := put_err.(write.Refused)
	testing.expectf(t, pok && pr.why == .No_Spelling && pr.node == 1, "container key tokens_of: %v", put_err)

	// P20: `tokens_of` with CBOR tags preserves tags via linear `node_facts`.
	// CBOR tag 1 (epoch datetime) on uint 10: C1 0A
	tagged_doc, terr := cbor.build([]u8{0xC1, 0x0A})
	defer cbor.destroy(&tagged_doc)
	testing.expect_value(t, terr, nil)
	cw: cbor.Writer
	testing.expect_value(t, cbor.writer_start(&cw), nil)
	testing.expect_value(t, cbor.put(&cw, &tagged_doc), nil)
	cout, cerr := cbor.writer_end(&cw)
	defer delete(cout)
	testing.expectf(t, cerr == nil && len(cout) == 2 && cout[0] == 0xC1 && cout[1] == 0x0A, "tagged cbor put: %x %v", cout, cerr)
}
