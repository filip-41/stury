package write_tests

import "core:testing"
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
