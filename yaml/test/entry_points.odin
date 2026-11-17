// The entry points of the format package and the calls in `core` with a handle read, edit and write a valid text, and
// a repeated key follows the duplicate policy of every read.
package yaml_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import core "../../core"
import compose "../../core/compose"
import engine "../../core/build"
import typed "../../core/typed"
import write "../../core/write"
import records "../../core/records"
import testkit "../../testkit"
import yaml ".."

@(private = "file")
Entry :: struct {
	a: i64,
	b: []i64,
}

@(private = "file")
ENTRY_TEXT :: "a: 1\nb: [2, 3]\n"

@(private = "file")
ENTRY_EDITED :: "a: 7\nb: [2, 3]\n"

// What `constant_forms` leaves out of the reads, the one-call edit and the marshal of a text through the forms the
// group `spec` picks.
@(private = "file")
text_forms :: proc(t: ^testing.T, $spec: yaml.Spec) {
	src := transmute([]u8)string(ENTRY_TEXT)
	path, perr := yaml.parse_path(".a")
	testkit.expect_nil(t, perr)
	defer yaml.destroy(&path)

	sdoc, serr := yaml.scan(src, spec, path)
	testkit.expect_nil(t, serr)
	testing.expect_value(t, len(sdoc.answers), 1)
	yaml.destroy(&sdoc)

	spelled, werr := yaml.set(src, spec, path, i64(7))
	testkit.expect_nil(t, werr)
	testing.expect_value(t, string(spelled), ENTRY_EDITED)
	delete(spelled)

	v: Entry
	defer delete(v.b)
	testkit.expect_nil(t, yaml.unmarshal(src, spec, &v))
	plan, plerr := yaml.plan_make(Entry, spec)
	testkit.expect_nil(t, plerr)
	defer yaml.destroy(&plan)
	again: Entry
	defer delete(again.b)
	testkit.expect_nil(t, yaml.unmarshal(src, spec, &again, &plan))
	testing.expect(t, again.a == 1 && len(again.b) == 2)

	text, terr := yaml.marshal(v, spec, write = yaml.PRETTY)
	testkit.expect_nil(t, terr)
	testing.expect_value(t, string(text), "a: 1\nb:\n  - 2\n  - 3\n")
	delete(text)
	planned, plnerr := yaml.marshal(v, &plan)
	testkit.expect_nil(t, plnerr)
	testing.expect_value(t, string(planned), "{a: 1, b: [2, 3]}")
	delete(planned)
}

@(test)
every_entry_point_accepts_valid_input :: proc(t: ^testing.T) {
	text_forms(t, .Yaml_1_2)
}

// Each constant form. A document it makes holds no services, so the document is read through the format package's own
// `query`, `edit_list_init` and `write`.
@(private = "file")
constant_forms :: proc(t: ^testing.T, $S: yaml.Spec) {
	src := transmute([]u8)string(ENTRY_TEXT)
	path, perr := yaml.parse_path(".a")
	testkit.expect_nil(t, perr)
	defer yaml.destroy(&path)
	paths := [?]yaml.Path{path}

	testkit.expect_nil(t, yaml.validate(src, S))
	testing.expect(t, yaml.validate(transmute([]u8)string("a: [1\n"), S) != nil)

	doc, berr := yaml.build(src, S)
	testkit.expect_nil(t, berr)
	defer yaml.destroy(&doc)
	testing.expect(t, doc.readers.services == nil)
	answers, qerr := yaml.query(&doc, path)
	testkit.expect_nil(t, qerr)
	defer delete(answers)
	if testing.expect_value(t, len(answers), 1) {
		list := yaml.edit_list_init(&doc, S)
		defer yaml.destroy(&list)
		testkit.expect_nil(t, write.set_node(&list, answers[0].node, typed.Raw("7")))
		out, _, cerr := compose.commit(&list)
		defer delete(out)
		testkit.expect_nil(t, cerr)
		testing.expect_value(t, string(out), ENTRY_EDITED)
	}
	written, _, werr := yaml.write(&doc, S, yaml.PRETTY)
	defer delete(written)
	testkit.expect_nil(t, werr)
	testing.expect_value(t, string(written), ENTRY_TEXT)

	sdoc, serr := yaml.scan(src, S, path)
	testkit.expect_nil(t, serr)
	yaml.destroy(&sdoc)
	mdoc, merr := yaml.scan(src, S, paths[:])
	testkit.expect_nil(t, merr)
	yaml.destroy(&mdoc)
	testkit.expect_nil(t, yaml.each_answer(src, S, path, nil, testkit.take_first))
	testkit.expect_nil(t, yaml.each_answer(src, S, paths[:], nil, testkit.take_first))
	fdoc, found, ferr := yaml.find(src, S, path)
	testkit.expect_nil(t, ferr)
	testing.expect(t, found.outcome == .Found)
	yaml.destroy(&fdoc)
	out, oerr := yaml.set(src, S, path, typed.Raw("7"))
	testkit.expect_nil(t, oerr)
	testing.expect_value(t, string(out), ENTRY_EDITED)
	delete(out)

	v: Entry
	defer delete(v.b)
	testkit.expect_nil(t, yaml.unmarshal(src, S, &v))
	testing.expect(t, v.a == 1 && len(v.b) == 2 && v.b[1] == 3)
	plan, plerr := yaml.plan_make(Entry, S, reads = yaml.reads(S))
	testkit.expect_nil(t, plerr)
	defer yaml.destroy(&plan)
	again, slot: Entry
	defer delete(again.b)
	defer delete(slot.b)
	testkit.expect_nil(t, yaml.unmarshal(src, S, &again, &plan))
	testkit.expect_nil(t, typed.unmarshal_text(src, &slot, Entry, &plan, {}))
	testing.expect(t, again.a == 1 && len(again.b) == 2)
	testing.expect(t, slot.a == 1 && len(slot.b) == 2)

	tokens: yaml.Tokens
	testing.expect_value(t, yaml.tokens_init(&tokens, S), yaml.Typed_Error_Kind.None)
	yaml.open_array(&tokens)
	yaml.value_int(&tokens, 1)
	yaml.close(&tokens)
	laid, lerr := write.tokens_finish(&tokens)
	defer delete(laid)
	testing.expect_value(t, lerr.kind, yaml.Typed_Error_Kind.None)
	testing.expect_value(t, string(laid), "[1]")
}

@(test)
every_constant_form_reads_and_writes :: proc(t: ^testing.T) {
	constant_forms(t, .Yaml_1_2)
}

// The record entry points frame and judge the documents of a stream, and a reader of a constant spec that gets
// `record_docs` builds and scans them.
@(private = "file")
record_forms :: proc(t: ^testing.T, $S: yaml.Spec) {
	src := transmute([]u8)string("a: 1\n---\na: 2\n")
	faults, err := yaml.records_validate(src, S)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(faults), 0)
	delete(faults)
	it := yaml.records_open(src, S)
	defer yaml.records_close(&it)
	it.docs = yaml.record_docs(S)
	n := 0
	for rec in yaml.records_next(&it) {
		doc, derr := yaml.records_build(&it, rec)
		testkit.expect_nil(t, derr)
		yaml.destroy(&doc)
		n += 1
	}
	testing.expect_value(t, n, 2)

	path, perr := yaml.parse_path(".a")
	testkit.expect_nil(t, perr)
	defer yaml.destroy(&path)
	scanned := yaml.records_open(src, S)
	defer yaml.records_close(&scanned)
	scanned.docs = yaml.record_docs(S)
	found := 0
	for {
		_, got, serr, more := yaml.records_scan(&scanned, path)
		if !more {
			break
		}
		testkit.expect_nil(t, serr)
		found += len(got.answers)
	}
	testing.expect_value(t, found, 2)

	Counted :: struct {
		records: int,
	}
	counted: Counted
	testkit.expect_nil(t, yaml.records_each(src, S, .Concatenated, proc(c: ^Counted, piece: ^yaml.Record_Reader, k: int) -> bool {
		for _ in yaml.records_next(piece) {
			c.records += 1
		}
		return true
	}, &counted))
	testing.expect_value(t, counted.records, 2)
}

@(test)
every_record_form_reads_a_stream :: proc(t: ^testing.T) {
	record_forms(t, .Yaml_1_2)
	src := transmute([]u8)string("a: 1\n---\na: 2\n")
	spec :: yaml.Spec.Yaml_1_2
	it := records.open(src, yaml.as(spec), .Concatenated)
	defer yaml.records_close(&it)
	n := 0
	for rec in yaml.records_next(&it) {
		doc, derr := yaml.records_build(&it, rec)
		testkit.expect_nil(t, derr)
		yaml.destroy(&doc)
		n += 1
	}
	testing.expect_value(t, n, 2)
}

// What a text with a repeated key gives under each duplicate policy through every read of the package.
@(private = "file")
Policy_Case :: struct {
	dups:    yaml.Duplicates,
	answers: string, // the answers of `.a`, comma-joined
	set:     string, // the text `.a = 7` gives
	a:       i64, // the member an unmarshal reads, 0 where it is refused
	refused: core.Fault_Kind, // what a read that takes no answer gives
}

@(private = "file")
POLICY_CASES := [?]Policy_Case {
	{.Default, "2", "a: 1\na: 7\nb: [2, 3]\n", 2, .None},
	{.Last, "2", "a: 1\na: 7\nb: [2, 3]\n", 2, .None},
	{.First, "1", "a: 7\na: 2\nb: [2, 3]\n", 1, .None},
	{.All, "1,2", "a: 7\na: 7\nb: [2, 3]\n", 0, .Bad_Option},
	{.Refuse, "", "", 0, .Duplicate_Key},
}

@(private = "file")
answer_texts :: proc(src: []u8, list: []yaml.Token_Answer) -> string {
	texts := make([dynamic]string)
	for a in list {
		append(&texts, string(src[a.lo:a.hi]))
	}
	return strings.join(texts[:], ",")
}

// A repeated key follows `dups` in the build, the scans, the answers, the typed read and the one-call edit, through the
// entries of the package and through `core` with a handle.
@(test)
a_repeated_key_follows_the_duplicate_policy_of_every_read :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	text := "a: 1\na: 2\nb: [2, 3]\n"
	src := transmute([]u8)text
	path, perr := yaml.parse_path(".a")
	testkit.expect_nil(t, perr)
	spec :: yaml.Spec.Yaml_1_2
	for c in POLICY_CASES {
		read := core.Path_Options{dups = c.dups}
		refused := c.dups == .Refuse
		want := c.answers

		built, berr := yaml.build(src, spec, dups = c.dups)
		testing.expectf(t, (berr != nil) == refused, "build under %v: %v", c.dups, berr)
		if !refused {
			found, qerr := yaml.query(&built, path, {dups = c.dups})
			testkit.expect_nil(t, qerr)
			got := make([dynamic]string)
			for a in found {
				v, _ := core.int_value(&built, a.node)
				append(&got, fmt.tprint(v))
			}
			testing.expectf(t, strings.join(got[:], ",") == want, "query under %v: %v", c.dups, got)
		} else {
			fault, _ := berr.(core.Fault)
			testing.expect_value(t, fault.kind, core.Fault_Kind.Duplicate_Key)
		}
		yaml.destroy(&built)

		doc, serr := yaml.scan(src, spec, path, read = read)
		testing.expectf(t, (serr != nil) == refused, "scan under %v: %v", c.dups, serr)
		if !refused {
			got := make([dynamic]string)
			for a in doc.answers {
				v, _ := core.int_value(&doc, a.node)
				append(&got, fmt.tprint(v))
			}
			testing.expectf(t, strings.join(got[:], ",") == want, "scan under %v: %v", c.dups, got)
		}
		yaml.destroy(&doc)

		streamed := make([dynamic]yaml.Token_Answer)
		eerr := yaml.each_answer(src, spec, path, &streamed, proc(state: rawptr, a: yaml.Token_Answer) -> bool {
			append((^[dynamic]yaml.Token_Answer)(state), a)
			return true
		}, read = read)
		testing.expectf(t, (eerr != nil) == refused && (refused || answer_texts(src, streamed[:]) == want), "each_answer under %v: %v %s", c.dups, eerr, answer_texts(src, streamed[:]))

		it := yaml.answers(src, spec, path, read = read)
		pulled := make([dynamic]yaml.Token_Answer)
		for a in yaml.next(&it) {
			append(&pulled, a)
		}
		testing.expectf(t, (it.err != nil) == refused && (refused || answer_texts(src, pulled[:]) == want), "answers under %v: %v %s", c.dups, it.err, answer_texts(src, pulled[:]))

		fdoc, found, ferr := yaml.find(src, spec, path, read = read)
		testing.expectf(t, (ferr != nil) == refused, "find under %v: %v", c.dups, ferr)
		if !refused {
			v, _ := core.int_value(&fdoc, found.node)
			testing.expectf(t, c.answers[:1] == fmt.tprint(v), "find under %v: %v", c.dups, v)
		}
		yaml.destroy(&fdoc)

		out, oerr := yaml.set(src, spec, path, typed.Raw("7"), read = {dups = c.dups})
		testing.expectf(t, (oerr != nil) == refused && string(out) == c.set, "set under %v: %v %q", c.dups, oerr, out)

		v: Entry
		uerr := yaml.unmarshal(src, spec, &v, read = {dups = c.dups})
		if c.refused == .None {
			testkit.expect_nil(t, uerr)
			testing.expect_value(t, v.a, c.a)
		} else if c.dups == .All {
			testkit.expect_kind(t, uerr, yaml.Typed_Error_Kind.Bad_Option)
		} else {
			testkit.expect_kind(t, uerr, yaml.Typed_Error_Kind.Duplicate_Key)
		}

		// `core` with a handle reads as the entries do.
		cdoc, cerr := engine.scan(src, yaml.as(spec), path, read)
		testing.expectf(t, (cerr != nil) == refused, "core scan under %v: %v", c.dups, cerr)
		core.destroy(&cdoc)
	}
}

// Two keys repeat only when they resolve to one type and value. A read by name refuses two keys of one text and two
// types, `1` and `"1"`, under every policy but `.First` and `.All`, and a document holds both.
@(test)
a_key_is_its_resolved_value :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	spec :: yaml.Spec.Yaml_1_2
	for text in ([]string{"a: 1\na: 2\n", "a: 1\n\"a\": 2\n", "1: x\n0x1: y\n", "~: x\nnull: y\n", "!!str 1: x\n\"1\": y\n", "{a: 1, a: 2}\n", "a: 1\nb:\n  c: 1\n  \"c\": 2\n"}) {
		_, err := yaml.build(transmute([]u8)text, spec, dups = .Refuse)
		fault, _ := err.(core.Fault)
		testing.expectf(t, fault.kind == .Duplicate_Key, "%q is refused: %v", text, err)
	}

	// A read by name sees two names in `1` and `"1"`, two keys, and in `1` and `0x1`, one repeated.
	for text in ([]string{"1: x\n\"1\": y\n", "1: x\n0x1: y\n"}) {
		src := transmute([]u8)text
		doc, err := yaml.build(src, spec)
		testkit.expect_nil(t, err)
		testing.expect_value(t, core.length(&doc, core.ROOT), 2)
		path, _ := yaml.parse_path(".\"1\"")
		for dups in core.Duplicates {
			_, qerr := yaml.query(&doc, path, {dups = dups})
			_, serr := yaml.scan(src, spec, path, read = {dups = dups})
			m: map[string]string
			uerr := yaml.unmarshal(src, spec, &m, read = {dups = dups})
			switch dups {
			case .First:
				testkit.expect_nil(t, qerr)
				testkit.expect_nil(t, serr)
				testkit.expect_nil(t, uerr)
				testing.expect_value(t, m["1"], "x")
			case .All:
				testkit.expect_nil(t, qerr)
				testkit.expect_nil(t, serr)
			case .Default, .Last, .Refuse:
				for e in ([]core.Error{qerr, serr}) {
					fault, _ := e.(core.Fault)
					testing.expectf(t, fault.kind == .Duplicate_Key && fault.at == 5, "%q under %v: %v", text, dups, e)
				}
				testkit.expect_kind(t, uerr, yaml.Typed_Error_Kind.Duplicate_Key)
			}
		}
	}
}

// A nil `any` is a null, which YAML writes as `null`.
@(test)
a_nil_any_marshals_as_null :: proc(t: ^testing.T) {
	nothing: any
	text, err := yaml.marshal(nothing, allocator = context.temp_allocator)
	testkit.expect_nil(t, err)
	testing.expect_value(t, strings.trim_space(string(text)), "null")
}

// The members a read of a text takes from the tokens of their values, which a plan reads during the walk.
@(private = "file")
Probe :: struct {
	a, b, c, foo, key: string,
	n:    i64,
	f:    f64,
	on:   bool,
	seq:  []string,
	m:    map[string]string,
	bar:  []map[string]string,
	home: Maybe(i64),
}

// `Probe` with a member that makes the plan read the text's document, which no text holds.
@(private = "file")
Probe_Doc :: struct {
	using probe: Probe,
	built:       typed.Raw `yaml:"read the document"`,
}

@(private = "file")
error_spelled :: proc(err: core.Error) -> string {
	#partial switch e in err {
	case core.Fault:
		return fmt.tprintf("fault %v %d %d", e.kind, e.detail, e.at)
	case core.Typed_Error:
		return fmt.tprintf("typed %v %d %v", e.kind, e.at, e.steps)
	}
	return fmt.tprint(err)
}

// A read during the walk gives what a read of the text's document gives: the value, or the same refusal at the same
// byte, under every duplicate policy, over the yaml-test-suite and texts of repeated, clashing, aliased and tagged keys.
@(test)
a_read_during_the_walk_reads_as_the_document_does :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	crafted := []string{
		"a: 1\na: 2\n", "1: x\n\"1\": y\nb: 2\n", "1: x\n0x1: y\n", "a: x\nm: {1: x, \"1\": y}\n", "m: {1: x, 1: y}\n",
		"a: 1\na: 2\nb: [\n", "m: {a: 1, a: 2}\nb: [\n", "x: &a {k: 1, k: 2}\nm: *a\nn: 3\n",
		"a: !!str 12\nn: !!int \"12\"\nf: !!float '1'\n", "bar:\n- {a: 1, 2: b}\n- {\"2\": c, 2: d}\n", "seq: [a, b]\nseq: [c]\n",
		"n: yes\nn: 2\n", "home: ~\nn: 0o17\nf: .inf\n", "a: 1\n1: 2\nother: {x: {1: a, \"1\": b}}\n", "on: true\n? [a]\n: b\n",
		"a: '1'\nb: \"2\\n\"\nc: |\n  x\n", "x: {a: 1, a: 2}\n1: y\n", "1: y\nx: {a: 1, a: 2}\nb: [\n",
	}
	texts := make([dynamic]string)
	append(&texts, ..crafted)
	list: [dynamic]Case
	cases(&list, SUITE_DIR, "")
	for c in list {
		src, _ := read_file(c.dir, "in.yaml")
		append(&texts, string(src))
	}
	compared := 0
	for text in texts {
		src := transmute([]u8)text
		for dups in ([]core.Duplicates{.Default, .First, .Last, .Refuse}) {
			v: Probe
			d: Probe_Doc
			got := yaml.unmarshal(src, .Yaml_1_2, &v, read = {dups = dups})
			want := yaml.unmarshal(src, .Yaml_1_2, &d, read = {dups = dups})
			testing.expectf(t, error_spelled(got) == error_spelled(want), "%q under %v: %s, the document's %s", text, dups, error_spelled(got), error_spelled(want))
			if want == nil {
				read, built := fmt.tprint(v), fmt.tprint(d.probe)
				testing.expectf(t, read == built, "%q under %v: %s, the document's %s", text, dups, read, built)
				compared += 1
			}
		}
	}
	testing.expect(t, compared > 100)
}
