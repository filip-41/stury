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
