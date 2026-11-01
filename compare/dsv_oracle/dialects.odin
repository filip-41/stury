// The walk's run-time dialect against the current tree's `csv`: a random delimiter and comment byte for each spec,
// Plain included, compared with the equal `cur.Dialect`. `make test-oracle` builds it from a copy of next/.
package dsv_oracle

import "core:fmt"
import "core:math/rand"
import "core:testing"
import cur "stury:csv"
import core "../../next/core"
import dsv "../../next/dsv"
import gen "../../next/dsv/test/gen"
import walktest "../../next/walktest"

@(test)
dialects_agree :: proc(t: ^testing.T) {
	state := rand.create(SEED + 29)
	context.random_generator = rand.default_random_generator(&state)
	text, broken: [dynamic]u8
	defer delete(text)
	defer delete(broken)
	compared := 0
	for _ in 0 ..< ROUNDS {
		c := gen.pick_case()
		gen.options_text(&text, c)
		for src in ([][]u8{text[:]}) {
			compared += 1
			if !check_dialect(t, src, c) {
				return
			}
		}
		// Mutations check the same dialect's refusal verdict without requiring the two documents to agree on a broken
		// text.
		walktest.mutate(&broken, text[:], gen.SHARP)
		compared += 1
		if !check_dialect(t, broken[:], c) {
			return
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("seed %d: %d dialect texts compared", SEED, compared)
}

old_dialect :: proc(c: gen.Options_Case) -> cur.Dialect {
	d := cur.Dialect{delimiter = c.delim, comment = c.comment}
	switch c.spec {
	case .Csv:
		d.quoting = .Quotes
	case .Tsv:
		d.quoting = .Backslash
	case .Plain:
		d.quoting = .None
	}
	return d
}

validate_case :: proc(src: []u8, c: gen.Options_Case, opts: dsv.Options) -> Maybe(core.Fault) {
	switch c.spec {
	case .Csv:
		return dsv.validate(src, .Csv, opts)
	case .Tsv:
		return dsv.validate(src, .Tsv, opts)
	case .Plain:
		return dsv.validate(src, .Plain, opts)
	}
	return nil
}

build_case :: proc(src: []u8, c: gen.Options_Case, opts: dsv.Options) -> (core.Document, core.Document_Error) {
	switch c.spec {
	case .Csv:
		return dsv.build(src, .Csv, opts)
	case .Tsv:
		return dsv.build(src, .Tsv, opts)
	case .Plain:
		return dsv.build(src, .Plain, opts)
	}
	return {}, {}
}

check_dialect :: proc(t: ^testing.T, src: []u8, c: gen.Options_Case) -> bool {
	no_header := rand.int_max(3) == 0
	old_opts := cur.Read_Opts{dialect = old_dialect(c), no_header = no_header}
	opts := dsv.Options{no_header = no_header, delimiter = c.delim, comment = c.comment}
	want, refused := cur.validate(src, old_opts).?
	got, bad := validate_case(src, c, opts).?
	if !validate_agrees(t, src, c, refused, want, bad, got) {
		return false
	}
	// Builds a text the walk accepts and compares its document with the current tree's. `validate` already checked a
	// refused text.
	if bad {
		return true
	}
	old, old_err := cur.build(src, old_opts)
	defer cur.destroy(&old)
	doc, err := build_case(src, c, opts)
	defer core.destroy(&doc)
	if old_err != nil || err.kind != .None {
		return testing.expectf(t, (old_err != nil) == (err.kind != .None), "%q %v %v: build %v, current tree %v", src, c.spec, opts, err, old_err)
	}
	return compare(t, src, &doc, 0, &old, 0, !no_header && doc.header != 0)
}

validate_agrees :: proc(t: ^testing.T, src: []u8, c: gen.Options_Case, refused: bool, want: cur.Error, bad: bool, got: core.Fault) -> bool {
	if !testing.expectf(t, refused == bad, "%q %v %v: walk %v, current tree %v", src, c.spec, c, got, want) {
		return false
	}
	if !refused {
		return true
	}
	// The walk's own `Bad_Char` detail has no member in the current tree, which carries none.
	detail_agrees := want.detail == got.detail || want.detail == 0 && got.kind == .Bad_Char && got.detail == u8(dsv.Detail.Bare_Quote)
	same := false
	if got.kind == .Bad_Structure && got.detail == u8(dsv.Detail.Field_Count) {
		// The current tree puts `Field_Count` at the record's first byte, and a fault at a later byte comes before it.
		same = want.kind == .Bad_Structure && want.detail == u8(dsv.Detail.Field_Count) || want.offset >= got.at
	} else {
		same = fmt.tprint(want.kind) == fmt.tprint(got.kind) && want.offset == got.at && detail_agrees
	}
	return testing.expectf(t, same, "%q %v %v: walk %v, current tree %v", src, c.spec, c, got, want)
}
