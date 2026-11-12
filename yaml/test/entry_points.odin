// The entry points of the format package: each form of a constant spec and of a spec chosen at run time reads, edits
// and writes a valid text, and a read asked for a duplicate policy YAML does not have is refused.
package yaml_tests

import "core:testing"
import compose "../../core/compose"
import typed "../../core/typed"
import write "../../core/write"
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
text_forms :: proc(t: ^testing.T, spec: yaml.Spec) {
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
	yaml.tokens_close(&tokens)
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
	faults, err := yaml.records_check(src, S)
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
	spec := yaml.Spec.Yaml_1_2
	faults, err := yaml.records_check(src, spec)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(faults), 0)
	delete(faults)
	it := yaml.records_open(src, spec)
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

// `.Refuse` is YAML's only duplicate policy: a read takes it or names none, and a read asked for another is refused
// before it reads a byte.
@(test)
a_read_asked_for_another_duplicate_policy_is_refused :: proc(t: ^testing.T) {
	src := transmute([]u8)string(ENTRY_TEXT)
	path, perr := yaml.parse_path(".a")
	walktest.expect_nil(t, perr)
	defer yaml.destroy(&path)
	spec := yaml.Spec.Yaml_1_2
	for dups in ([?]yaml.Duplicates{.Default, .Refuse}) {
		doc, err := yaml.scan(src, spec, path, read = {dups = dups})
		walktest.expect_nil(t, err)
		testing.expect_value(t, len(doc.answers), 1)
		yaml.destroy(&doc)
		bound, berr := yaml.scan(src, .Yaml_1_2, path, read = {dups = dups})
		walktest.expect_nil(t, berr)
		yaml.destroy(&bound)
		out, serr := yaml.set(src, spec, path, typed.Raw("7"), read = {dups = dups})
		walktest.expect_nil(t, serr)
		delete(out)
		v: Entry
		walktest.expect_nil(t, yaml.unmarshal(src, spec, &v, read = {dups = dups}))
		delete(v.b)
	}
	for dups in ([?]yaml.Duplicates{.Last, .First, .All}) {
		doc, err := yaml.scan(src, spec, path, read = {dups = dups})
		testing.expectf(t, walktest.fault_is(err, .Bad_Option, 0), "scan under %v: %v", dups, err)
		yaml.destroy(&doc)
		bound, berr := yaml.scan(src, .Yaml_1_2, path, read = {dups = dups})
		testing.expectf(t, walktest.fault_is(berr, .Bad_Option, 0), "scan under %v: %v", dups, berr)
		yaml.destroy(&bound)
		testing.expect(t, walktest.fault_is(yaml.each_answer(src, spec, path, nil, take_first, read = {dups = dups}), .Bad_Option, 0))
		fdoc, _, ferr := yaml.find(src, spec, path, read = {dups = dups})
		testing.expect(t, walktest.fault_is(ferr, .Bad_Option, 0))
		yaml.destroy(&fdoc)
		out, serr := yaml.set(src, spec, path, typed.Raw("7"), read = {dups = dups})
		testing.expectf(t, out == nil && walktest.fault_is(serr, .Bad_Option, 0), "set under %v: %v", dups, serr)
		v: Entry
		walktest.expect_kind(t, yaml.unmarshal(src, spec, &v, read = {dups = dups}), yaml.Typed_Error_Kind.Bad_Option)
		built, _ := yaml.build(src, spec)
		answers, qerr := yaml.query(&built, path, {dups = dups})
		testing.expect(t, answers == nil && walktest.fault_is(qerr, .Bad_Option, 0))
		yaml.destroy(&built)
	}
	// A repeated key is a fault of the text under the policy a read names and under none.
	repeated := transmute([]u8)string("a: 1\na: 2\n")
	for dups in ([?]yaml.Duplicates{.Default, .Refuse}) {
		doc, err := yaml.scan(repeated, spec, path, read = {dups = dups})
		fault, faulted := err.(yaml.Fault)
		testing.expectf(t, faulted && fault.detail == u8(yaml.Detail.Duplicate_Key), "under %v: %v", dups, err)
		yaml.destroy(&doc)
	}
}
