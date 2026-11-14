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
import walktest "../../walktest"
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

@(private = "file")
take_first :: proc(state: rawptr, a: yaml.Token_Answer) -> bool {
	return false
}

// The reads and the one-call edit of a text through the forms the group `spec` picks.
@(private = "file")
text_forms :: proc(t: ^testing.T, $spec: yaml.Spec) {
	src := transmute([]u8)string(ENTRY_TEXT)
	path, perr := yaml.parse_path(".a")
	walktest.expect_nil(t, perr)
	defer yaml.destroy(&path)
	paths := [?]yaml.Path{path}

	walktest.expect_nil(t, yaml.validate(src, spec))
	testing.expect(t, yaml.validate(transmute([]u8)string("a: [1\n"), spec) != nil)

	doc, berr := yaml.build(src, spec)
	walktest.expect_nil(t, berr)
	yaml.destroy(&doc)

	sdoc, serr := yaml.scan(src, spec, path)
	walktest.expect_nil(t, serr)
	testing.expect_value(t, len(sdoc.answers), 1)
	yaml.destroy(&sdoc)
	mdoc, merr := yaml.scan(src, spec, paths[:])
	walktest.expect_nil(t, merr)
	yaml.destroy(&mdoc)
	walktest.expect_nil(t, yaml.each_answer(src, spec, path, nil, take_first))
	walktest.expect_nil(t, yaml.each_answer(src, spec, paths[:], nil, take_first))
	fdoc, found, ferr := yaml.find(src, spec, path)
	walktest.expect_nil(t, ferr)
	testing.expect(t, found.outcome == .Found)
	yaml.destroy(&fdoc)

	out, oerr := yaml.set(src, spec, path, typed.Raw("7"))
	walktest.expect_nil(t, oerr)
	testing.expect_value(t, string(out), ENTRY_EDITED)
	delete(out)
	spelled, werr := yaml.set(src, spec, path, i64(7))
	walktest.expect_nil(t, werr)
	testing.expect_value(t, string(spelled), ENTRY_EDITED)
	delete(spelled)

	v: Entry
	defer delete(v.b)
	walktest.expect_nil(t, yaml.unmarshal(src, spec, &v))
	testing.expect(t, v.a == 1 && len(v.b) == 2 && v.b[1] == 3)
	plan, plerr := yaml.plan_make(Entry, spec)
	walktest.expect_nil(t, plerr)
	defer yaml.destroy(&plan)
	again: Entry
	defer delete(again.b)
	walktest.expect_nil(t, yaml.unmarshal(src, spec, &again, &plan))
	testing.expect(t, again.a == 1 && len(again.b) == 2)

	text, terr := yaml.marshal(v, spec, write = yaml.PRETTY)
	walktest.expect_nil(t, terr)
	testing.expect_value(t, string(text), "a: 1\nb:\n  - 2\n  - 3\n")
	delete(text)
	planned, plnerr := yaml.marshal(v, &plan)
	walktest.expect_nil(t, plnerr)
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
	walktest.expect_nil(t, perr)
	defer yaml.destroy(&path)
	paths := [?]yaml.Path{path}

	walktest.expect_nil(t, yaml.validate(src, S))
	testing.expect(t, yaml.validate(transmute([]u8)string("a: [1\n"), S) != nil)

	doc, berr := yaml.build(src, S)
	walktest.expect_nil(t, berr)
	defer yaml.destroy(&doc)
	testing.expect(t, doc.readers.services == nil)
	answers, qerr := yaml.query(&doc, path)
	walktest.expect_nil(t, qerr)
	defer delete(answers)
	if testing.expect_value(t, len(answers), 1) {
		list := yaml.edit_list_init(&doc, S)
		defer yaml.destroy(&list)
		walktest.expect_nil(t, write.set(&list, answers[0].node, typed.Raw("7")))
		out, _, cerr := compose.commit(&list)
		defer delete(out)
		walktest.expect_nil(t, cerr)
		testing.expect_value(t, string(out), ENTRY_EDITED)
	}
	written, _, werr := yaml.write(&doc, S, yaml.PRETTY)
	defer delete(written)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, string(written), ENTRY_TEXT)

	sdoc, serr := yaml.scan(src, S, path)
	walktest.expect_nil(t, serr)
	yaml.destroy(&sdoc)
	mdoc, merr := yaml.scan(src, S, paths[:])
	walktest.expect_nil(t, merr)
	yaml.destroy(&mdoc)
	walktest.expect_nil(t, yaml.each_answer(src, S, path, nil, take_first))
	walktest.expect_nil(t, yaml.each_answer(src, S, paths[:], nil, take_first))
	fdoc, found, ferr := yaml.find(src, S, path)
	walktest.expect_nil(t, ferr)
	testing.expect(t, found.outcome == .Found)
	yaml.destroy(&fdoc)
	out, oerr := yaml.set(src, S, path, typed.Raw("7"))
	walktest.expect_nil(t, oerr)
	testing.expect_value(t, string(out), ENTRY_EDITED)
	delete(out)

	v: Entry
	defer delete(v.b)
	walktest.expect_nil(t, yaml.unmarshal(src, S, &v))
	testing.expect(t, v.a == 1 && len(v.b) == 2 && v.b[1] == 3)
	plan, plerr := yaml.plan_make(Entry, S, reads = yaml.reads(S))
	walktest.expect_nil(t, plerr)
	defer yaml.destroy(&plan)
	again, slot: Entry
	defer delete(again.b)
	defer delete(slot.b)
	walktest.expect_nil(t, yaml.unmarshal(src, S, &again, &plan))
	walktest.expect_nil(t, typed.unmarshal_text(src, &slot, Entry, &plan, {}))
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
		walktest.expect_nil(t, derr)
		yaml.destroy(&doc)
		n += 1
	}
	testing.expect_value(t, n, 2)

	path, perr := yaml.parse_path(".a")
	walktest.expect_nil(t, perr)
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
		walktest.expect_nil(t, serr)
		found += len(got.answers)
	}
	testing.expect_value(t, found, 2)

	Counted :: struct {
		records: int,
	}
	counted: Counted
	walktest.expect_nil(t, yaml.records_each(src, S, .Concatenated, proc(c: ^Counted, piece: ^yaml.Record_Reader, k: int) -> bool {
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
	faults, err := yaml.records_validate(src, spec)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(faults), 0)
	delete(faults)
	it := records.open(src, yaml.as(spec), .Concatenated)
	defer yaml.records_close(&it)
	n := 0
	for rec in yaml.records_next(&it) {
		doc, derr := yaml.records_build(&it, rec)
		walktest.expect_nil(t, derr)
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
	walktest.expect_nil(t, perr)
	spec :: yaml.Spec.Yaml_1_2
	for c in POLICY_CASES {
		read := core.Path_Options{dups = c.dups}
		refused := c.dups == .Refuse
		want := c.answers

		built, berr := yaml.build(src, spec, dups = c.dups)
		testing.expectf(t, (berr != nil) == refused, "build under %v: %v", c.dups, berr)
		if !refused {
			found, qerr := yaml.query(&built, path, {dups = c.dups})
			walktest.expect_nil(t, qerr)
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
			walktest.expect_nil(t, uerr)
			testing.expect_value(t, v.a, c.a)
		} else if c.dups == .All {
			walktest.expect_kind(t, uerr, yaml.Typed_Error_Kind.Bad_Option)
		} else {
			walktest.expect_kind(t, uerr, yaml.Typed_Error_Kind.Duplicate_Key)
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
		walktest.expect_nil(t, err)
		testing.expect_value(t, core.length(&doc, core.ROOT), 2)
		path, _ := yaml.parse_path(".\"1\"")
		for dups in core.Duplicates {
			_, qerr := yaml.query(&doc, path, {dups = dups})
			_, serr := yaml.scan(src, spec, path, read = {dups = dups})
			m: map[string]string
			uerr := yaml.unmarshal(src, spec, &m, read = {dups = dups})
			switch dups {
			case .First:
				walktest.expect_nil(t, qerr)
				walktest.expect_nil(t, serr)
				walktest.expect_nil(t, uerr)
				testing.expect_value(t, m["1"], "x")
			case .All:
				walktest.expect_nil(t, qerr)
				walktest.expect_nil(t, serr)
			case .Default, .Last, .Refuse:
				for e in ([]core.Error{qerr, serr}) {
					fault, _ := e.(core.Fault)
					testing.expectf(t, fault.kind == .Duplicate_Key && fault.at == 5, "%q under %v: %v", text, dups, e)
				}
				walktest.expect_kind(t, uerr, yaml.Typed_Error_Kind.Duplicate_Key)
			}
		}
	}
}

// A nil `any` is a null, which YAML writes as `null`.
@(test)
a_nil_any_marshals_as_null :: proc(t: ^testing.T) {
	nothing: any
	text, err := yaml.marshal(nothing, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect_value(t, strings.trim_space(string(text)), "null")
}

// `.Entries` gives the members of the container that a path of keys names as the walk reads them, a block member read
// as it does in its place, and a fault ends the records at the byte `validate` gives, after the members before it.
@(test)
entries_are_the_members_of_a_container :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "a: 0\nlogs:\n  - id: 1\n    s: x\n  - [1, 2]\n  - 3\n"
	walktest.expect_entries(t, src, yaml.as(.Yaml_1_2), {"logs"}, "15  {\"id\":1,\"s\":\"x\"}\n34  [1,2]\n45  3\nend")
	walktest.expect_entries(t, src, yaml.as(.Yaml_1_2), nil, "3 a 0\n13 logs [{\"id\":1,\"s\":\"x\"},[1,2],3]\nend")
	walktest.expect_entries(t, src, yaml.as(.Yaml_1_2), {"none"}, "end")
	walktest.expect_framings(t, yaml.CAPABILITIES, yaml.as(.Yaml_1_2))
	bad := "logs:\n  - 1\n  - [2\n"
	fault, _ := walktest.fault_in(yaml.validate(transmute([]u8)string(bad), .Yaml_1_2))
	walktest.expect_entries(t, bad, yaml.as(.Yaml_1_2), {"logs"}, fmt.tprintf("10  1\nfault %d", fault.at))
	other := "f: [1, {a: 2}, [3]]\nm:\n  x: 1\n  y:\n    - 2\n"
	walktest.expect_entries(t, other, yaml.as(.Yaml_1_2), {"f"}, "4  1\n7  {\"a\":2}\n15  [3]\nend")
	walktest.expect_entries(t, other, yaml.as(.Yaml_1_2), {"m"}, "28 x 1\n39 y [2]\nend")
	it := yaml.records_open(transmute([]u8)src, .Yaml_1_2, framing = .Entries, entries = {"logs"})
	testing.expect_value(t, walktest.entries_lines(&it), "15  {\"id\":1,\"s\":\"x\"}\n34  [1,2]\n45  3\nend")
}

// A member under `.Entries` reads in its place, as the build of the whole text reads it: an alias to an anchor of an
// earlier member, and a tag by a handle the directives declare, by a build and by a typed read.
@(test)
entries_read_in_their_place :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	aliased := "l:\n- &a 1\n- *a\n"
	walktest.expect_entries(t, aliased, yaml.as(.Yaml_1_2), {"l"}, "5  1\n12  1\nend")
	testing.expect_value(t, walktest.entries_read(aliased, yaml.as(.Yaml_1_2), {"l"}, int), "1\n1\nend")
	tagged := "%TAG !e! tag:e.com,2000:\n---\nl:\n- !e!x 1\n"
	walktest.expect_entries(t, tagged, yaml.as(.Yaml_1_2), {"l"}, "34  \"1\"\nend")
	testing.expect_value(t, walktest.entries_read(tagged, yaml.as(.Yaml_1_2), {"l"}, string), "1\nend")
}

// A member given before the last builds once later members are read, in memory and while a stream's window holds it:
// an alias to an anchor of an earlier member too.
@(test)
entries_build_after_later_members :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	walktest.expect_entries_built_later(t, "l:\n- &a {x: 1}\n- *a\n- [2, 3]\n- 4\n", yaml.as(.Yaml_1_2), {"l"})
	walktest.expect_entries_built_later(t, "m:\n  a: 1\n  b: {c: d}\n  e: [f]\n", yaml.as(.Yaml_1_2), {"m"})
}

// A stream's member given before the last builds as it did when it was given, once the window moved past the reader's
// first position, by a walk from the window's first step: an alias to an anchor before the window's start too.
@(test)
entries_build_after_the_window_moved :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "l:\n- &a {k: 1}\n")
	for i in 0 ..< 2000 {
		fmt.sbprintf(&b, "- {{id: %d, pad: 0123456789012345678901234567890123456789012345678901234567890123456789}}\n- *a\n", i)
	}
	r: strings.Reader
	it := records.open_stream(strings.to_reader(&r, strings.to_string(b)), yaml.as(.Yaml_1_2), .Entries, {entries = {"l"}})
	defer records.close(&it)
	given := make([dynamic]records.Record, context.temp_allocator)
	then := make([dynamic]string, context.temp_allocator)
	window, since, checked := it.src, 0, 0
	for rec in records.next(&it) {
		if raw_data(it.src) != raw_data(window) || len(it.src) != len(window) {
			window, since = it.src, len(given)
		}
		append(&given, rec)
		append(&then, entry_json(&it, rec))
		for k := len(given) - 2; k >= since && k >= len(given) - 4; k -= 1 {
			checked += int(since > 0)
			got := entry_json(&it, given[k])
			testing.expectf(t, got == then[k], "record %d after %d: %s, got %s", k, len(given) - 1, then[k], got)
		}
	}
	testing.expect(t, checked > 0)
	testing.expect_value(t, len(given), 4001)
}

@(private = "file")
entry_json :: proc(it: ^records.Reader, rec: records.Record) -> string {
	doc, err := records.build(it, rec, context.temp_allocator)
	defer core.destroy(&doc)
	if err != nil {
		return fmt.tprint("error", err)
	}
	out, _, _ := yaml.write(&doc, .Yaml_1_2, {}, allocator = context.temp_allocator)
	return string(out)
}

// Reading the records of a sequence ten times as long under `.Entries` holds no more of the reader's memory at its
// peak, so the reader walks the members and holds no tree of the text.
@(test)
entries_hold_no_tree :: proc(t: ^testing.T) {
	walktest.expect_entries_bounded(t, yaml.as(.Yaml_1_2), {"logs"}, "meta: 1\nlogs:\n", "  - id: 7\n    tags: [a, b]\n", "", false)
}

// A stream's window follows the records under `.Entries`, as the input of a stream ten times as long holds no more of
// the reader's memory at its peak: in a block and a flow container, with an anchor each member takes again and an
// alias to it, and with a tag by a handle the directives declare.
@(test)
entries_hold_one_member :: proc(t: ^testing.T) {
	as := yaml.as(.Yaml_1_2)
	text :: "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"
	walktest.expect_entries_bounded(t, as, {"logs"}, "meta: 1\nlogs:\n", "  - id: 7\n    name: " + text + "\n    tags: [a, b]\n", "", true)
	walktest.expect_entries_bounded(t, as, {"logs"}, "logs: [", "{id: 7, name: " + text + "}, ", "1]\n", true)
	walktest.expect_entries_bounded(t, as, {"logs"}, "logs:\n", "- &m {id: 7, name: " + text + "}\n- *m\n", "", true)
	walktest.expect_entries_bounded(t, as, {"logs"}, "%TAG !e! tag:e.com,2000:\n---\nlogs:\n", "- !e!x " + text + "\n", "", true)
	merging := yaml.as(.Yaml_1_2, {merge_keys = true})
	walktest.expect_entries_bounded(t, merging, {"logs"}, "logs:\n", "- <<: {id: 7, name: " + text + "}\n  id: 8\n", "", true)
}

// Under merge keys a stream's member merges what its `<<` names as the whole text does while the window moves, and so
// does a container of the records, whose earlier keys the window let go.
@(test)
entries_merge_keys_across_window_moves :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	as := yaml.as(.Yaml_1_2, {merge_keys = true})
	walktest.expect_entries(t, "base: &b {x: 1, y: 2}\nl:\n- <<: *b\n  y: 3\n- {<<: [*b, {w: 0}], z: 4}\n- k: 1\n  <<: {k: 2, m: 3}\n", as, {"l"}, "27  {\"y\":3,\"x\":1}\n43  {\"z\":4,\"x\":1,\"y\":2,\"w\":0}\n70  {\"k\":1,\"m\":3}\nend")
	walktest.expect_entries(t, "m:\n  alpha: 1\n  beta: [2]\n  <<: {alpha: 9, zeta: 1}\n", as, {"m"}, "12 alpha 1\n22 beta [2]\n49 zeta 1\nend")
}

// A stream's member reads as the whole text reads it while the window moves under it: an alias to an anchor of an
// earlier member, after the name was taken again too, a tag by a handle a `%TAG` directive declares or redefines, a
// repeated key, block and flow members, and scalars that end only at a line past them.
@(test)
entries_read_across_window_moves :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	as := yaml.as(.Yaml_1_2)
	walktest.expect_entries(t, "l:\n- &a 1\n- x\n- {k: &b [2, 3]}\n- *a\n- &a 4\n- {y: 1, z: *b}\n- *a\n", as, {"l"}, "5  1\n12  \"x\"\n16  {\"k\":[2,3]}\n33  1\n38  4\n45  {\"y\":1,\"z\":[2,3]}\n61  4\nend")
	walktest.expect_entries(t, "%TAG !e! tag:e.com,2000:\n%TAG !! tag:e.com:\n---\nl:\n- !e!x 1\n- !!int 2\n- 3\n", as, {"l"}, "53  \"1\"\n62  \"2\"\n72  3\nend")
	walktest.expect_entries(t, "l:\n- {a: 1, a: 2}\n- 1: a\n  0x1: b\n- k: [1]\n  k: [2]\n", as, {"l"}, "5  {\"a\":1,\"a\":2}\n20  {\"1\":\"a\",\"0x1\":\"b\"}\n36  {\"k\":[1],\"k\":[2]}\nend")
	walktest.expect_entries(t, "l: [1, {a: [2, 3]}, \"q\", 'r', [ ], b c\n  d]\n", as, {"l"}, "4  1\n7  {\"a\":[2,3]}\n20  \"q\"\n25  \"r\"\n30  []\n35  \"b c d\"\nend")
	walktest.expect_entries(t, "l:\n- |\n  text\n  more\n- >-\n  folded\n  line\n- a\n  b\n- - 1\n  - 2\n- k: v\n  m:\n    n: 1\n# end\n", as, {"l"}, "5  \"text\\nmore\\n\"\n23  \"folded line\"\n44  \"a b\"\n52  [1,2]\n64  {\"k\":\"v\",\"m\":{\"n\":1}}\nend")
	for size in 1 ..= 3 {
		b := strings.builder_make(context.temp_allocator)
		want := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "l:\n- &keep k\n")
		strings.write_string(&want, "5  \"k\"\n")
		for i in 0 ..< 40 {
			fmt.sbprintf(&want, "%d  %d\n%d  %d\n", len(b.buf) + 2, i, len(b.buf) + len(fmt.tprintf("- &a %d\n", i)) + 2, i)
			fmt.sbprintf(&b, "- &a %d\n- *a\n", i)
		}
		fmt.sbprintf(&want, "%d  \"k\"\nend", len(b.buf) + 2)
		strings.write_string(&b, "- *keep\n")
		trickle := walktest.Trickle{src = b.buf[:], size = size}
		it := records.open_stream(walktest.trickle_reader(&trickle), as, .Entries, {entries = {"l"}})
		testing.expect_value(t, walktest.entries_lines(&it), strings.to_string(want))
	}
}
