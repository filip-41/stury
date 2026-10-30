// The walk's run-time dialect against the current tree's `csv`: a random delimiter and comment byte for each spec,
// Plain included, compared with the equal `cur.Dialect`. `make test-oracle` builds it from a copy of next/.
package dsv_oracle

import "core:fmt"
import "core:math/rand"
import "core:testing"
import cur "stury:csv"
import core "../../../core"
import dsv "../.."
import gen "../gen"
import walktest "../../../walktest"

// The delimiters a case may pick: no CR, LF, non-ASCII byte or quote. The current tree refuses a quote in any dialect
// while this walk refuses it only under CSV, so the oracle leaves the quote out and `dsv/test` tests that rule.
DELIMITERS :: []byte{',', '\t', ';', '|', ':', '^', '~', '#'}

// The comment bytes a case may pick: no CR, LF, non-ASCII byte, backslash or quote, which the specs refuse where they
// matter. The generator keeps the comment byte away from the delimiter.
COMMENTS :: []byte{'#', ';', '%', '!', '@', '&'}

// A cell's body for each spec, spelled as that spec writes it: CSV quotes or not, TSV escapes, Plain text.
CSV_PLAIN :: []string{"", "a", "12.5", "sp ace", "é", "日本", "😀"}
CSV_QUOTED :: []string{"", "a", "a,b", "x\"\"y", "multi\nline", "cr\r\nlf", "é", "😀"}
TSV_CELLS :: []string{"", "a", "\\t", "\\n", "\\r", "\\0", "\\\\", "x\\ty", "\"q\"", "12.5", "é", "😀"}
PLAIN_CELLS :: []string{"", "a", "\"q\"", "x\\y", "12.5", "é", "😀", " sp "}

Dialect_Case :: struct {
	spec:    dsv.Spec,
	delim:   byte,
	comment: byte,
}

@(test)
dialects_agree :: proc(t: ^testing.T) {
	state := rand.create(SEED + 29)
	context.random_generator = rand.default_random_generator(&state)
	text, broken: [dynamic]u8
	defer delete(text)
	defer delete(broken)
	compared := 0
	for round in 0 ..< ROUNDS {
		c := pick_case()
		gen_dialect_text(&text, c)
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

pick_case :: proc() -> Dialect_Case {
	spec := rand.choice([]dsv.Spec{.Csv, .Tsv, .Plain})
	delim := rand.choice(DELIMITERS)
	comment: byte
	if rand.int_max(2) == 0 {
		for {
			comment = rand.choice(COMMENTS)
			if comment != delim {
				break
			}
		}
	}
	return {spec, delim, comment}
}

old_dialect :: proc(c: Dialect_Case) -> cur.Dialect {
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

validate_case :: proc(src: []u8, c: Dialect_Case, opts: dsv.Options) -> Maybe(core.Fault) {
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

build_case :: proc(src: []u8, c: Dialect_Case, opts: dsv.Options) -> (core.Document, core.Document_Error) {
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

// Appends a valid text of a case to `out`: a header and records of one width, a comment line before the header and
// now and then between records, a line end at the end or not, and now and then a BOM. A comment line holds arbitrary
// text bytes, including a delimiter, a quote and a CR.
gen_dialect_text :: proc(out: ^[dynamic]u8, c: Dialect_Case) {
	clear(out)
	if rand.int_max(10) == 0 {
		append(out, "\xef\xbb\xbf")
	}
	width := 1 + rand.int_max(5)
	rows := rand.int_max(6)
	crlf := rand.int_max(3) == 0
	line_end := []string{"\r\n", "\n"}
	le := line_end[0 if crlf else 1]
	for r in 0 ..= rows {
		if c.comment != 0 && (r == 0 || rand.int_max(2) == 0) {
			append(out, c.comment)
			for _ in 0 ..< rand.int_max(10) {
				append(out, rand.choice([]byte{'a', '#', ';', ',', '"', '\\', ' ', '\r', '|'}))
			}
			append(out, le)
		}
		for col in 0 ..< width {
			if col > 0 {
				append(out, c.delim)
			}
			switch c.spec {
			case .Csv:
				if rand.int_max(2) == 0 {
					append(out, '"')
					append(out, rand.choice(CSV_QUOTED))
					append(out, '"')
				} else {
					append(out, rand.choice(CSV_PLAIN))
				}
			case .Tsv:
				append(out, rand.choice(TSV_CELLS))
			case .Plain:
				append(out, rand.choice(PLAIN_CELLS))
			}
		}
		if r < rows || rand.int_max(2) == 0 {
			append(out, le)
		}
		if r < rows && rand.int_max(8) == 0 {
			append(out, le)
		}
	}
}

check_dialect :: proc(t: ^testing.T, src: []u8, c: Dialect_Case) -> bool {
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

validate_agrees :: proc(t: ^testing.T, src: []u8, c: Dialect_Case, refused: bool, want: cur.Error, bad: bool, got: core.Fault) -> bool {
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
