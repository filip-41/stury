package json_tests

import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/ops/write"
import "stury:testkit"

// A text written token by token into a sink is the text `write` makes of the document, whatever the layout.

@(test)
tokens_into_a_sink_are_the_text_of_the_document :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := `{"a":[1,2.5,{"b":null}],"c":"x\ny","d":{},"e":[]}`
	doc, err := json.build(transmute([]u8)src)
	defer json.destroy(&doc)
	testing.expect(t, err == nil)
	for opts in ([?]json.Write_Options{{}, {indent = 2}, {tab = true}, {ascii = true}}) {
		want, _, werr := json.write(&doc, .Json, opts)
		defer delete(want)
		testing.expect(t, werr == nil)
		sink: strings.Builder
		defer strings.builder_destroy(&sink)
		w: json.Writer
		testing.expect(t, json.writer_start(&w, opts, strings.to_writer(&sink)) == nil)
		steps := [?]struct {
			kind: write.Token_Kind,
			text: string,
		}{{.Object, ""}, {.Key, "a"}, {.Array, ""}, {.Number, "1"}, {.Number, "2.5"}, {.Object, ""}, {.Key, "b"}, {.Null, ""}, {.Close, ""}, {.Close, ""}, {.Key, "c"}, {.String, "x\ny"}, {.Key, "d"}, {.Object, ""}, {.Close, ""}, {.Key, "e"}, {.Array, ""}, {.Close, ""}, {.Close, ""}}
		for step in steps {
			testing.expect(t, json.token(&w, step.kind, step.text) == nil)
		}
		_, eerr := json.writer_end(&w)
		testing.expect(t, eerr == nil)
		testing.expectf(t, strings.to_string(sink) == string(want), "%v: %s\nwant %s", opts, strings.to_string(sink), want)
	}
}
