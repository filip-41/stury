package dsv_tests

import "core:testing"
import "stury:dsv"
import "stury:host"
import "stury:lib/core/tape"
import "stury:testkit"

// A document says how it was read: the options of its build, in its `Tabular_Ext`.

@(private = "file")
Read_As :: struct {
	spec:    dsv.Spec,
	options: dsv.Dsv_Options,
	want:    dsv.Dsv_Options, // `options` with the spec's own delimiter in place of 0
}

@(private = "file")
READ_AS :: [?]Read_As {
	{.Csv, {}, {delimiter = ','}},
	{.Tsv, {}, {delimiter = '\t'}},
	{.Plain, {}, {delimiter = ','}},
	{.Csv, {delimiter = ';'}, {delimiter = ';'}},
	{.Tsv, {delimiter = '|', comment = '#'}, {delimiter = '|', comment = '#'}},
	{.Plain, {comment = '%', no_header = true}, {delimiter = ',', comment = '%', no_header = true}},
	{.Csv, {delimiter = ';', infer = true}, {delimiter = ';', infer = true}},
	{.Tsv, {comment = ';', no_header = true, infer = true}, {delimiter = '\t', comment = ';', no_header = true, infer = true}},
}

@(private = "file")
TEXT :: "a;b\n1;2\n;c\n3;4\n"

@(private = "file")
kept_options :: proc(t: ^testing.T, doc: ^dsv.Document, err: dsv.Error, want: dsv.Dsv_Options, name: string) {
	testing.expectf(t, err == nil, "%s: %v", name, err)
	ext, tabular := doc.ext.format.(tape.Tabular_Ext)
	testing.expectf(t, tabular && ext.options == want, "%s: kept %v, wanted %v", name, ext.options, want)
}

// A build keeps the options it was made with, the delimiter its spec's own when it left it 0, whole, in pieces and on
// a runner's threads.
@(test)
a_document_keeps_the_options_it_was_built_with :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(TEXT)
	pool: host.Pool
	host.pool_init(&pool, 3)
	defer host.pool_destroy(&pool)
	for c in READ_AS {
		opts := dsv.Options{format = c.options}
		whole, werr := dsv.build(src, c.spec, opts)
		defer dsv.destroy(&whole)
		kept_options(t, &whole, werr, c.want, "whole")
		pieces := dsv.Pieces{so_far = true, allocator = context.allocator}
		defer dsv.destroy(&pieces)
		cut := opts
		cut.pieces = &pieces
		part, perr := dsv.build(src[:9], c.spec, cut)
		defer dsv.destroy(&part)
		kept_options(t, &part, perr, c.want, "pieces")
		wide := opts
		wide.runner = &pool.runner
		many, merr := dsv.build(src, c.spec, wide)
		defer dsv.destroy(&many)
		kept_options(t, &many, merr, c.want, "threads")
	}
}

// Options a spec cannot read, and options of another family, are refused before the text is read.
@(test)
reads_refuse_bad_options :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a\n")
	for c in ([]struct {
			spec: dsv.Spec,
			opts: dsv.Dsv_Options,
			want: string,
		}{{.Csv, {delimiter = '"'}, "delimiter"}, {.Csv, {delimiter = '\n'}, "delimiter"}, {.Tsv, {delimiter = 'n'}, "delimiter"}, {.Csv, {comment = ','}, "comment"}, {.Tsv, {comment = '\\'}, "comment"}}) {
		want := tape.Error(tape.Bad_Option{c.want})
		opts := dsv.Options{format = c.opts}
		testing.expectf(t, dsv.validate(src, c.spec, opts) == want, "%v", c)
		_, err := dsv.build(src, c.spec, opts)
		testing.expectf(t, err == want, "%v build: %v", c, err)
		r := dsv.records_open(src, .Lines, c.spec, opts)
		testing.expectf(t, r.err == want, "%v records: %v", c, r.err)
	}
	// A runner is no option a read refuses: a build may run on its threads, and the other reads run on the caller's.
	runner: tape.Runner
	testing.expect_value(t, dsv.validate(src, .Csv, {runner = &runner}), nil)
	doc, err := dsv.build(src, .Csv, {runner = &runner})
	testing.expect_value(t, err, nil)
	dsv.destroy(&doc)
}

// A depth budget of one level holds the text but no record.
@(test)
reads_keep_the_depth_budget :: proc(t: ^testing.T) {
	testkit.deadline(t)
	want := tape.Error(tape.Exceeded{at = 2, kind = .Depth})
	src := transmute([]u8)string("a\n1\n")
	opts := dsv.Options{budget = {depth = 1}}
	testing.expect_value(t, dsv.validate(src, .Csv, opts), want)
	_, err := dsv.build(src, .Csv, opts)
	testing.expect_value(t, err, want)
	testing.expect_value(t, dsv.validate(transmute([]u8)string("a\n"), .Csv, opts), nil)
}

Bad_Byte :: struct {
	spec:   dsv.Spec,
	opts:   dsv.Dsv_Options,
	option: string,
}

// Each spec refuses the bytes it cannot read as a delimiter or a comment, and a comment equal to the delimiter. CSV
// refuses a quote, CR, LF and a non-ASCII byte, TSV the backslash and the letters of its escapes, Plain CR, LF and a
// non-ASCII byte.
@(test)
reads_refuse_each_byte_a_spec_cannot_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a,b\n1,2\n")
	for c in ([]Bad_Byte {
			{.Csv, {delimiter = '"'}, "delimiter"},
			{.Csv, {comment = '"'}, "comment"},
			{.Csv, {delimiter = '\n'}, "delimiter"},
			{.Csv, {delimiter = '\r'}, "delimiter"},
			{.Csv, {delimiter = 0x80}, "delimiter"},
			{.Csv, {delimiter = ';', comment = ';'}, "comment"},
			{.Csv, {comment = 0x80}, "comment"},
			{.Plain, {delimiter = '\n'}, "delimiter"},
			{.Plain, {delimiter = '\r'}, "delimiter"},
			{.Plain, {delimiter = 0x80}, "delimiter"},
			{.Plain, {delimiter = ';', comment = ';'}, "comment"},
			{.Tsv, {delimiter = '\\'}, "delimiter"},
			{.Tsv, {delimiter = 't'}, "delimiter"},
			{.Tsv, {delimiter = 'n'}, "delimiter"},
			{.Tsv, {delimiter = 'r'}, "delimiter"},
			{.Tsv, {delimiter = '0'}, "delimiter"},
			{.Tsv, {comment = '\\'}, "comment"},
			{.Tsv, {delimiter = '\n'}, "delimiter"},
		}) {
		want := tape.Error(tape.Bad_Option{c.option})
		opts := dsv.Options {
			format = c.opts,
		}
		testing.expectf(t, dsv.validate(src, c.spec, opts) == want, "%v %v: validate %v", c.spec, c.opts, dsv.validate(src, c.spec, opts))
		doc, err := dsv.build(src, c.spec, opts)
		testing.expectf(t, err == want && len(doc.nodes) == 0, "%v %v: build %v", c.spec, c.opts, err)
		dsv.destroy(&doc)
	}
}
