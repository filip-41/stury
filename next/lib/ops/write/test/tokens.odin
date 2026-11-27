package write_tests

import "base:runtime"
import "core:testing"
import "stury:cbor"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:testkit"

// The token writer: the tokens of a document written one at a time are the text a write of the document makes, and a
// malformed sequence is refused where it is written.

@(private = "file")
emit_value :: proc(w: ^json.Writer, doc: ^tape.Document, at: tape.Node_Index) -> json.Write_Error {
	n := doc.nodes[at]
	#partial switch n.kind {
	case .Null: return json.token(w, .Null)
	case .False: return json.token(w, .False)
	case .True: return json.token(w, .True)
	case .Number: return json.token(w, .Number, testkit.scalar_text(doc, at))
	case .String, .Plain: return json.token(w, .String, testkit.scalar_text(doc, at))
	}
	r := tape.Reader{doc, nil}
	c, _, _ := tape.children(r, at, context.temp_allocator)
	object := n.kind == .Object
	if e := json.token(w, .Object if object else .Array); e != nil {
		return e
	}
	for {
		key, value, p := tape.next_child(r, &c, .Group)
		if p != .Found {
			break
		}
		if object {
			if e := json.token(w, .Key, testkit.scalar_text(doc, key)); e != nil {
				return e
			}
		}
		if e := emit_value(w, doc, value); e != nil {
			return e
		}
	}
	return json.token(w, .Close)
}

@(private = "file")
TEXTS := [?]string{
	`{"a":1,"b":[true,false,null,"x\ny","é\u0001"],"c":{},"d":[],"e":{"f":[[],{}]}}`,
	`[1,2.5e10,-0,"",[[[]]]]`,
	`"a string"`,
	`7`,
	`null`,
}

@(test)
tokens_write_the_text_of_a_document :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for src in TEXTS {
		doc, err := json.build(transmute([]u8)src)
		defer json.destroy(&doc)
		testing.expectf(t, err == nil, "%s: %v", src, err)
		for opts in LAYOUTS {
			want, _, werr := json.write(&doc, .Json, opts)
			defer delete(want)
			testing.expectf(t, werr == nil, "%s: %v", src, werr)
			w: json.Writer
			testing.expect(t, json.writer_start(&w, opts) == nil)
			testing.expectf(t, emit_value(&w, &doc, json.ROOT) == nil, "%s", src)
			got, eerr := json.writer_end(&w)
			defer delete(got)
			testing.expectf(t, eerr == nil && string(got) == string(want), "%s under %v: got %q, want %q (%v)", src, opts, got, want, eerr)
		}
	}
}

@(test)
tokens_refuse_a_malformed_sequence :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Step :: struct {
		kind: write.Token_Kind,
		text: string,
		why:  Maybe(write.Refusal),
	}
	cases := [?][]Step{
		{{.Close, "", .Malformed}},
		{{.Key, "a", .Malformed}},
		{{.Object, "", nil}, {.String, "v", .Malformed}, {.Key, "a", nil}, {.Key, "b", .Malformed}, {.Close, "", .Malformed}, {.Null, "", nil}, {.Close, "", nil}},
		{{.Array, "", nil}, {.Key, "a", .Malformed}, {.Number, "01", .No_Spelling}, {.Number, "1", nil}, {.Close, "", nil}, {.Null, "", .Malformed}},
		{{.String, "\xff", .No_Spelling}, {.String, "ok", nil}},
	}
	for steps, k in cases {
		w: json.Writer
		testing.expect(t, json.writer_start(&w) == nil)
		for s, i in steps {
			err := json.token(&w, s.kind, s.text)
			got: Maybe(write.Refusal)
			if r, refused := err.(write.Refused); refused {
				got = r.why
			}
			testing.expectf(t, got == s.why, "case %d step %d: %v", k, i, err)
		}
		text, err := json.writer_end(&w)
		delete(text)
		_ = err
	}
	w: json.Writer
	testing.expect(t, json.writer_start(&w) == nil)
	testing.expect(t, json.token(&w, .Array) == nil)
	text, err := json.writer_end(&w)
	testing.expect(t, text == nil)
	refused, ok := err.(write.Refused)
	testing.expectf(t, ok && refused.why == .Malformed, "an open container: %v", err)
}

@(test)
tokens_frame_each_root_value :: proc(t: ^testing.T) {
	testkit.deadline(t)
	wants := [write.Record_Framing]string{.None = "", .Lines = "{\"a\":[1]}\n2\n", .Seq = "\x1e{\"a\":[1]}\n\x1e2\n"}
	for framing in ([?]write.Record_Framing{.Lines, .Seq}) {
		want := wants[framing]
		w: json.Writer
		testing.expect(t, json.writer_start(&w, {framing = framing}) == nil)
		for kind, i in ([?]write.Token_Kind{.Object, .Key, .Array, .Number, .Close, .Close, .Number}) {
			text := "a" if kind == .Key else "1" if kind == .Number && i == 3 else "2"
			testing.expectf(t, json.token(&w, kind, text) == nil, "%v", kind)
		}
		got, err := json.writer_end(&w)
		defer delete(got)
		testing.expectf(t, err == nil && string(got) == want, "%v: %q", framing, got)
	}
	w: json.Writer
	testing.expect(t, json.writer_start(&w, {framing = .Lines, indent = 2}) != nil)
}

@(test)
documents_write_a_record :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, _ := json.build(transmute([]u8)string(`{"a":[1, 2]}`))
	defer json.destroy(&doc)
	wants := [write.Record_Framing]string{.None = `{"a":[1,2]}`, .Lines = "{\"a\":[1,2]}\n", .Seq = "\x1e{\"a\":[1,2]}\n"}
	for framing in write.Record_Framing {
		got, _, err := json.write(&doc, .Json, {framing = framing})
		defer delete(got)
		testing.expectf(t, err == nil && string(got) == wants[framing], "%v: %q (%v)", framing, got, err)
	}
	_, _, err := json.write(&doc, .Json, {framing = .Lines, indent = 2})
	testing.expect(t, err != nil)

	// Comments are dropped cleanly under `.Lines` framing so NDJSON never contains embedded newlines.
	commented, _ := json.build(transmute([]u8)string("// head\n{\"a\": 1 /* mid */}\n// foot\n"), .Jsonc)
	defer json.destroy(&commented)
	line, dropped, lerr := json.write(&commented, .Jsonc, {framing = .Lines})
	defer delete(line)
	testing.expectf(t, lerr == nil && string(line) == "{\"a\":1}\n" && dropped == {.Comment, .Comment_Inline, .Comment_Foot}, "lines comments: %v %q %v", lerr, line, dropped)

	// `json.put` streams documents into a `json.Writer`.
	w: json.Writer
	testing.expect(t, json.writer_start(&w, {framing = .Lines}) == nil)
	testing.expect(t, json.put(&w, &doc) == nil)
	testing.expect(t, json.put(&w, &commented) == nil)
	streamed, serr := json.writer_end(&w)
	defer delete(streamed)
	testing.expectf(t, serr == nil && string(streamed) == "{\"a\":[1,2]}\n{\"a\":1}\n", "json.put: %v %q", serr, streamed)
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
