package dsv_tests

import "core:testing"
import "stury:dsv"
import "stury:lib/core/tape"
import "stury:testkit"

// The byte past the line end of the record that starts at `lo`: past its CR LF or LF outside a quoted cell, or the
// text's end.
@(private = "file")
past_record :: proc(src: []u8, lo: int, quotes: bool) -> int {
	quoted := false
	for i := lo; i < len(src); i += 1 {
		switch {
		case quotes && src[i] == '"':
			quoted = !quoted
		case !quoted && src[i] == '\n':
			return i + 1
		}
	}
	return len(src)
}

// The first byte of each record of `src`, which has no comments: where a line is not empty or only a CR LF.
@(private = "file")
record_starts :: proc(src: []u8, quotes: bool) -> (starts: [dynamic]int) {
	starts = make([dynamic]int, context.temp_allocator)
	for at := 0; at < len(src); {
		if src[at] == '\n' || src[at] == '\r' && at + 1 < len(src) && src[at + 1] == '\n' {
			at += 1
			continue
		}
		append(&starts, at)
		at = past_record(src, at, quotes)
	}
	return
}

// A container of a built table closes past its line end, and the root past the text's last byte, in texts headed and
// unheaded, with quoted cells, CR LF and a last record with no line end.
@(test)
builds_close_each_container_past_its_line_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	texts := []string{"a,b\n1,2\n", "a,b\r\n1,2\r\n3,4", "a,b\n1,2", "a\n\"x,y\"\n", "a,b\n\"x\ny\",2\n\n3,4\n", "1,2\n3,4\n", "", "\n\n"}
	for text in texts {
		src := transmute([]u8)text
		for spec in dsv.Spec {
			for no_header in ([]bool{false, true}) {
				opts := tape.Options {
					format = dsv.Dsv_Options{no_header = no_header},
				}
				doc, err := dsv.build(src, spec, opts)
				defer dsv.destroy(&doc)
				if err != nil {
					continue
				}
				starts := record_starts(src, spec == .Csv)
				rows := starts[:]
				if !no_header && len(rows) > 0 {
					rows = rows[1:]
				}
				got, ok := doc.format.close_end(&doc, dsv.ROOT)
				testing.expectf(t, ok && got == u64(len(src)) && doc.root_close == u64(len(src)), "%q %v: root closes at %d", text, spec, got)
				for start, i in rows {
					node, _ := dsv.element({doc = &doc}, dsv.ROOT, i)
					end, closed := doc.format.close_end(&doc, node)
					want := past_record(src, start, spec == .Csv)
					testing.expectf(t, closed && end == u64(want), "%q %v no_header %v: row %d closes at %d, want %d", text, spec, no_header, i, end, want)
				}
			}
		}
	}
}

// A scanned record closes where the walk that read it ended: at its line end in a text that tolerates a bare quote, and
// a scan that stops at its answer leaves the rest of the record, here an unfinished quoted cell, unread, so the record
// closes at the text's end.
@(test)
scans_close_a_record_where_the_walk_ended :: proc(t: ^testing.T) {
	testkit.deadline(t)
	demand, _ := dsv.demand_of({{tape.Index(0), tape.Name("a")}})
	defer dsv.destroy(&demand)
	for c in ([]struct {
			text: string,
			read: tape.Read_Options,
			opts: tape.Options,
			end:  u64,
		}{
			{"a,b\n1,x\"y\n2,3\n", {}, {tolerate = {.Bare_Quote}}, 10},
			{"a,b\n1,\"x", {stop_early = true}, {dups = .First}, 8},
		}) {
		src := transmute([]u8)c.text
		doc, err := dsv.scan(src, &demand, .Csv, c.read, c.opts)
		defer dsv.destroy(&doc)
		testing.expectf(t, err == nil, "%q: %v", c.text, err)
		row, _ := dsv.element({doc = &doc}, dsv.ROOT, 0)
		end, ok := doc.format.close_end(&doc, row)
		testing.expectf(t, ok && end == c.end, "%q: the record closes at %d, want %d", c.text, end, c.end)
	}
}
