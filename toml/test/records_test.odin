// The records of TOML: a text is one record, from the reader's position to the input's end.
package toml_tests

import "core:strings"
import "core:testing"
import core "../../core"
import records "../../core/records"
import toml ".."
import walktest "../../walktest"

@(private = "file")
RECORD_TEXT :: "a = 1\n[t]\nb = [1, 2]\n\n[t.u]\nc = 'x'\n"

// The record entry points of a constant spec frame and judge the text as one record, and a reader that gets
// `record_docs` builds and scans it.
@(private = "file")
record_forms :: proc(t: ^testing.T, $S: toml.Spec) {
	src := transmute([]u8)string(RECORD_TEXT)
	faults, err := toml.records_check(src, S)
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
		walktest.expect_nil(t, derr)
		testing.expect_value(t, core.length(core.Value(core.Node_Ref{&doc, core.ROOT})), 2)
		toml.destroy(&doc)
		n += 1
	}
	testing.expect_value(t, n, 1)

	path, perr := toml.parse_path(".t.b[1]")
	walktest.expect_nil(t, perr)
	defer toml.destroy(&path)
	scanned := toml.records_open(src, S)
	defer toml.records_close(&scanned)
	scanned.docs = toml.record_docs(S)
	found := 0
	for {
		_, got, serr, more := toml.records_scan(&scanned, path)
		if !more {
			break
		}
		walktest.expect_nil(t, serr)
		found += len(got.answers)
	}
	testing.expect_value(t, found, 1)

	Counted :: struct {
		records: int,
	}
	counted: Counted
	walktest.expect_nil(t, toml.records_each(src, S, .Concatenated, proc(c: ^Counted, piece: ^toml.Record_Reader, k: int) -> bool {
		for _ in toml.records_next(piece) {
			c.records += 1
		}
		return true
	}, &counted))
	testing.expect_value(t, counted.records, 1)
}

@(test)
every_record_form_reads_a_text :: proc(t: ^testing.T) {
	record_forms(t, .Toml_1_0)
	record_forms(t, .Toml_1_1)
	src := transmute([]u8)string(RECORD_TEXT)
	spec := toml.Spec.Toml_1_1
	it := toml.records_open(src, spec)
	defer toml.records_close(&it)
	n := 0
	for rec in toml.records_next(&it) {
		doc, derr := toml.records_build(&it, rec)
		walktest.expect_nil(t, derr)
		toml.destroy(&doc)
		n += 1
	}
	testing.expect_value(t, n, 1)
}

// An input of no bytes holds no record, a record read from a byte past the first starts there, and a refused text is
// the reader's fault at its byte in the input.
@(test)
a_record_is_the_rest_of_the_input :: proc(t: ^testing.T) {
	spec := toml.Spec.Toml_1_1
	empty := toml.records_open(nil, spec)
	defer toml.records_close(&empty)
	_, more := toml.records_next(&empty)
	testing.expect(t, !more && empty.fault == nil)
	src := transmute([]u8)string("# lead\na = 1\nb = 2\n")
	from := toml.records_open(src, spec, at = 7)
	defer toml.records_close(&from)
	rec, ok := toml.records_next(&from)
	testing.expect(t, ok && rec.at == 7 && string(rec.text) == "a = 1\nb = 2\n")
	bad := transmute([]u8)string("a = 1\nb = 2\na = 3\n")
	faults, err := toml.records_check(bad, spec)
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
	for text in ([]string{RECORD_TEXT, whole}) {
		r: strings.Reader
		it := toml.records_open_stream(strings.to_reader(&r, text), toml.Spec.Toml_1_1, stream = {max_bytes = 1 << 22})
		defer toml.records_close(&it)
		n := 0
		for rec in records.next(&it) {
			testing.expect(t, string(rec.text) == text && rec.at == 0)
			n += 1
		}
		testing.expect(t, n == 1 && it.fault == nil)
	}
	strings.write_string(&b, "[t17]\n")
	r: strings.Reader
	it := toml.records_open_stream(strings.to_reader(&r, strings.to_string(b)), toml.Spec.Toml_1_1, stream = {max_bytes = 1 << 22})
	defer toml.records_close(&it)
	for _ in records.next(&it) {
	}
	f, bad := it.fault.?
	testing.expect(t, bad && f.detail == u8(toml.Detail.Redefined_Table) && f.at == u64(len(whole)) + 1)
}
