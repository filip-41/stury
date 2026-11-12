// A path read of a YAML text with no build: the answers and the faults a query of the built document gives, the
// stream of answers, the first answer and a read that stops early.
package yaml_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import core "../../core"
import engine "../../core/build"
import "../../core/records"
import walktest "../../walktest"
import yaml ".."

@(private = "file")
Seen :: struct {
	path:    u32,
	outcome: core.Presence,
	kind:    core.Kind,
	text:    string,
}

@(private = "file")
seen_of :: proc(doc: ^core.Document, answers: []core.Answer) -> string {
	b := strings.builder_make(context.temp_allocator)
	for a in answers {
		s := Seen{path = a.path, outcome = a.outcome}
		if a.outcome == .Found || a.outcome == .Wrong_Kind {
			s.kind = core.kind(doc, a.node)
		}
		if a.outcome == .Found {
			s.text = string(core.span(doc, a.node))
		}
		fmt.sbprintf(&b, "%v\n", s)
	}
	return strings.to_string(b)
}

@(private = "file")
TEXTS := [?]string {
	"a:\n  b: 1\n  c: [x, {k: v}]\nlist:\n  - one\n  - k: two\n    m: 2\n  - [3, 4]\n  - &e {k: last}\nal: *e\nx: !!int \"12\"\ns: !!str 12\nq: !!float 1\n",
	"- 1\n- - 2\n  - 3\n- {a: 1, b: [4, 5]}\n- |\n  block\n- \"q\"\n",
	"top: &t\n  k: 1\n  x: [9]\nlist: [*t, *t, {k: 3}]\n",
	"--- !!map\nk: 1\nlist: [a, b]\n...\n",
	"plain\n",
	"# only a comment\n",
	"a: 1\n--- b\n",
	"a: [1, 2\nlist: [x]\n",
	"list: [1, 2]\nb: {x: \"\\uD800\"}\n",
	"list: [1, 2]\nb:\n  - x\n - y\n",
	"a: 1\na: 2\nlist: []\n",
	"list: [1, *nope]\n",
	"[a, b, c]\n",
}

@(private = "file")
PATHS := [?]string {".", ".a", ".a.b", ".a.c[1].k", ".list", ".list[0]", ".list[1].k", ".list[-1]", ".list[-1].k", ".list[1:3]", ".list[-2:]", ".list[]", ".list[].k", "...k", ".missing", ".a[0]", ".al", ".al.k", ".x", ".s", ".q", ".[1]", ".[-1]", "first(.list[])", "limit(2; ...k)"}

// Every path, alone and all at once, answers over the text as a query of the built document does, and fails where the
// build does.
@(test)
a_read_answers_as_a_query_of_the_document :: proc(t: ^testing.T) {
	as := yaml.as(.Yaml_1_2)
	paths: [len(PATHS)]core.Path
	for text, i in PATHS {
		e: core.Error
		paths[i], e = core.parse_path(text, context.temp_allocator)
		walktest.expect_nil(t, e)
	}
	for text in TEXTS {
		src := transmute([]u8)text
		built, berr := core.build(src, as)
		defer core.destroy(&built)
		for k in 0 ..= len(paths) {
			set := paths[k:k + 1] if k < len(paths) else paths[:]
			read, rerr := engine.scan(src, as, set)
			defer core.destroy(&read)
			if berr != nil {
				_, faulted := rerr.(core.Fault)
				testing.expectf(t, faulted && walktest.at_of(rerr) == walktest.at_of(berr), "%q %v: %v, built %v", text, PATHS[min(k, len(PATHS) - 1)], rerr, berr)
				continue
			}
			answers, qerr := engine.query(&built, set, allocator = context.temp_allocator)
			testing.expect(t, walktest.same_error(rerr, core.error_of(qerr)))
			testing.expectf(t, seen_of(&read, read.answers) == seen_of(&built, answers), "%q %v:\n%s\nbuilt:\n%s", text, PATHS[min(k, len(PATHS) - 1)], seen_of(&read, read.answers), seen_of(&built, answers))
		}
	}
}

// `each_answer` gives each found value's span, an alias's included where the stream reaches one after it gave answers,
// and `find` the first answer of a read. A record's read answers as the read of its text does.
@(test)
the_stream_and_the_first_answer_agree_with_the_read :: proc(t: ^testing.T) {
	Case :: struct {
		text, path, first: string,
	}
	cases := [?]Case {
		{TEXTS[0], ".list[]", "one"},
		{TEXTS[0], "...k", ""},
		{TEXTS[2], ".list[]", "k: 1\n  x: [9]"},
		{"- &a 1\n- [2]\n- *a\n- 4\n", ".[]", "1"},
		{"- &a 1\n- [2]\n- *a\n- 4\n", ".[-1]", "4"},
	}
	Spans :: struct {
		src:  []u8,
		seen: [dynamic]string,
	}
	on :: proc(state: rawptr, a: core.Token_Answer) -> bool {
		s := (^Spans)(state)
		append(&s.seen, string(s.src[a.lo:a.hi]))
		return true
	}
	as := yaml.as(.Yaml_1_2)
	for c in cases {
		src := transmute([]u8)c.text
		path, _ := core.parse_path(c.path, context.temp_allocator)
		read, rerr := engine.scan(src, as, path)
		defer core.destroy(&read)
		walktest.expect_nil(t, rerr)
		spans := Spans{src = src, seen = make([dynamic]string, context.temp_allocator)}
		walktest.expect_nil(t, engine.each_answer(src, as, path, &spans, on))
		testing.expectf(t, len(spans.seen) == len(read.answers), "%q %s: %v", c.text, c.path, spans.seen)
		for a, i in read.answers {
			if i < len(spans.seen) {
				testing.expect_value(t, spans.seen[i], string(core.span(&read, a.node)))
			}
		}
		doc, first, ferr := engine.find(src, as, path)
		defer core.destroy(&doc)
		walktest.expect_nil(t, ferr)
		testing.expect_value(t, string(core.span(&doc, first.node)) if first.outcome == .Found else "", c.first)
		testing.expect_value(t, first.outcome, read.answers[0].outcome if len(read.answers) > 0 else .Missing)

		stream := strings.concatenate({c.text, "---\n", c.text, "--- [x]\n"}, context.temp_allocator)
		it := records.open(transmute([]u8)stream, as, .Concatenated)
		defer records.close(&it)
		k := 0
		for {
			_, got, err, more := records.scan(&it, path)
			if !more {
				break
			}
			walktest.expect_nil(t, err)
			if k < 2 {
				testing.expectf(t, seen_of(&got, got.answers) == seen_of(&read, read.answers), "%q %s record %d", c.text, c.path, k)
			}
			k += 1
		}
		testing.expect_value(t, k, 3)
		testing.expectf(t, it.fault == nil, "%v", it.fault)
	}
}

// A read that stops early leaves the text past its last answer unjudged, and judges every byte before it.
@(test)
a_read_that_stops_early_judges_the_text_before_its_answer :: proc(t: ^testing.T) {
	as := yaml.as(.Yaml_1_2)
	path, _ := core.parse_path(".b", context.temp_allocator)
	src := transmute([]u8)string("a: [1, {x: 2}]\nb: here\nc: [unclosed\n")
	doc, answer, err := engine.find(src, as, path, {stop_early = true})
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(core.span(&doc, answer.node)), "here")
	whole, werr := engine.scan(src, as, path)
	defer core.destroy(&whole)
	walktest.expect_kind(t, werr, core.Path_Error_Kind.Walk)
	bad := transmute([]u8)string("a: [1, {x: \"\\q\"}]\nb: here\n")
	early, _, eerr := engine.find(bad, as, path, {stop_early = true})
	defer core.destroy(&early)
	walktest.expect_kind(t, eerr, core.Path_Error_Kind.Walk)
	testing.expect_value(t, walktest.at_of(eerr), u64(12))
}
