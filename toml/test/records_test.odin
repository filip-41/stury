// The records of TOML: a text is one record, from the reader's position to the input's end.
package toml_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import core "../../core"
import records "../../core/records"
import toml ".."
import testkit "../../testkit"

@(private = "file")
RECORD_TEXT :: "a = 1\n[t]\nb = [1, 2]\n\n[t.u]\nc = 'x'\n"

// The record entry points of a constant spec frame and judge the text as one record, and a reader that gets
// `record_docs` builds and scans it.
@(private = "file")
record_forms :: proc(t: ^testing.T, $S: toml.Spec) {
	src := transmute([]u8)string(RECORD_TEXT)
	faults, err := toml.records_validate(src, S)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(faults), 0)
	delete(faults)
	it := toml.records_open(src, S)
	defer toml.records_close(&it)
	it.docs = toml.record_docs(S)
	n := 0
	for rec in toml.records_next(&it) {
		testing.expect_value(t, string(rec.text), RECORD_TEXT)
		doc, derr := toml.records_build(&it, rec)
		testkit.expect_nil(t, derr)
		testing.expect_value(t, core.length(core.Value(core.Node_Ref{&doc, core.ROOT})), 2)
		toml.destroy(&doc)
		n += 1
	}
	testing.expect_value(t, n, 1)

	path, perr := toml.parse_path(".t.b[1]")
	testkit.expect_nil(t, perr)
	defer toml.destroy(&path)
	scanned := toml.records_open(src, S)
	defer toml.records_close(&scanned)
	scanned.docs = toml.record_docs(S)
	testkit.expect_records_scanned(t, &scanned, path, 1)
	each := 0
	testkit.expect_nil(t, toml.records_each(src, S, .Concatenated, testkit.count_records, &each))
	testing.expect_value(t, each, 1)
}

@(test)
every_record_form_reads_a_text :: proc(t: ^testing.T) {
	record_forms(t, .Toml_1_0)
	record_forms(t, .Toml_1_1)
	src := transmute([]u8)string(RECORD_TEXT)
	it := records.open(src, toml.as(.Toml_1_1), .Concatenated)
	defer toml.records_close(&it)
	n := 0
	for rec in toml.records_next(&it) {
		doc, derr := toml.records_build(&it, rec)
		testkit.expect_nil(t, derr)
		toml.destroy(&doc)
		n += 1
	}
	testing.expect_value(t, n, 1)
}

// An input of no bytes holds no record, a record read from a byte past the first starts there, and a refused text is
// the reader's fault at its byte in the input.
@(test)
a_record_is_the_rest_of_the_input :: proc(t: ^testing.T) {
	spec :: toml.Spec.Toml_1_1
	testkit.expect_record_is_the_rest(t, "# lead\na = 1\nb = 2\n", 7, toml.as(spec))
	bad := transmute([]u8)string("a = 1\nb = 2\na = 3\n")
	faults, err := toml.records_validate(bad, spec)
	defer delete(faults)
	testing.expect(t, err == nil && len(faults) == 1 && faults[0].detail == u8(toml.Detail.Duplicate_Key) && faults[0].at == 12)
}

// A stream's text is one record once the input has ended, though it spans many of the stream's reads and a string
// crosses the end of one, and a repeated key far into it is the reader's fault at its byte.
@(test)
a_stream_is_read_as_one_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for i in 0 ..< 4000 {
		strings.write_string(&b, "[t")
		strings.write_int(&b, i)
		strings.write_string(&b, "]\nk = 1\n")
		if i == 3000 {
			strings.write_string(&b, "s = '''\n")
			strings.write_string(&b, strings.repeat("x", 70000, context.temp_allocator))
			strings.write_string(&b, "'''\n")
		}
	}
	whole := strings.to_string(b)
	testkit.expect_stream_is_one_record(t, RECORD_TEXT, toml.as(.Toml_1_1))
	testkit.expect_stream_is_one_record(t, whole, toml.as(.Toml_1_1))
	strings.write_string(&b, "[t17]\n")
	r: strings.Reader
	it := toml.records_open_stream(strings.to_reader(&r, strings.to_string(b)), toml.Spec.Toml_1_1, stream = {max_bytes = 1 << 22})
	defer toml.records_close(&it)
	for _ in records.next(&it) {
	}
	f, bad := it.fault.?
	testing.expect(t, bad && f.detail == u8(toml.Detail.Redefined_Table) && f.at == u64(len(whole)) + 1)
}

// `.Entries` gives the tables of an array of tables, each with the subtables its sections hold after it, and the
// members of a table, and a fault ends the records at the byte `validate` gives.
@(test)
entries_are_the_members_of_a_container :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "a = 1\n[[x]]\ny = 1\n[x.z]\nq = 2\n[[x]]\ny = 2\n"
	testkit.expect_entries(t, src, toml.as(.Toml_1_0), {"x"}, "6  {\"y\":1,\"z\":{\"q\":2}}\n30  {\"y\":2}\nend")
	testkit.expect_entries(t, src, toml.as(.Toml_1_0), nil, "4 a 1\n6 x [{\"y\":1,\"z\":{\"q\":2}},{\"y\":2}]\nend")
	testkit.expect_framings(t, toml.CAPABILITIES, toml.as(.Toml_1_0))
	bad := "[[x]]\ny = 1\n[[x]]\ny = \n"
	fault, _ := testkit.fault_in(toml.validate(transmute([]u8)string(bad), .Toml_1_0))
	testkit.expect_entries(t, bad, toml.as(.Toml_1_0), {"x"}, fmt.tprintf("fault %d", fault.at))
	it := toml.records_open(transmute([]u8)src, .Toml_1_0, framing = .Entries, entries = {"x"})
	testing.expect_value(t, testkit.entries_lines(&it), "6  {\"y\":1,\"z\":{\"q\":2}}\n30  {\"y\":2}\nend")
}

@(private = "file")
Reading :: struct {
	a: int,
	t: struct {
		b: [dynamic]int,
		u: struct {
			c: string,
		},
	},
}

// A text read into a value under `.Concatenated` is what `unmarshal` reads, and a read past it gives no record.
@(test)
a_record_reads_into_a_value :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	plan, perr := toml.plan_make(Reading, .Toml_1_0)
	testkit.expect_nil(t, perr)
	it := records.open(transmute([]u8)string(RECORD_TEXT), toml.as(.Toml_1_0), .Concatenated)
	defer records.close(&it)
	v: Reading
	err, more := records.read(&it, &v, &plan)
	testkit.expect_nil(t, err)
	testing.expect(t, more)
	testing.expect_value(t, v.a, 1)
	testing.expect_value(t, len(v.t.b), 2)
	testing.expect_value(t, v.t.u.c, "x")
	_, more = records.read(&it, &v, &plan)
	testing.expect(t, !more && it.fault == nil)
	wrong := records.open(transmute([]u8)string("a = 'x'\n"), toml.as(.Toml_1_0), .Concatenated)
	defer records.close(&wrong)
	err, more = records.read(&wrong, &v, &plan)
	typed_err, is_typed := err.(core.Typed_Error)
	testing.expect(t, is_typed && more)
	testing.expect_value(t, typed_err.kind, core.Typed_Error_Kind.Wrong_Kind)
}
