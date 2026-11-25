package stury_tests

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:stury"
import "stury:testkit"

// A delimited text written as JSON or as another delimited text takes the rows route, with no document, and its text and
// its errors are those of reading a document and writing it.

// A read that bounds its memory is the one that takes the rows route.
@(private = "file")
BOUNDED :: tape.Options{budget = {memory = 1 << 30}}

@(private = "file")
document_route :: proc(src: []u8, from: dsv.Spec, to: stury.Spec, read: tape.Options, opts: write.Options) -> (text: []u8, err: stury.Format_Error) {
	doc, read_err := dsv.build(src, from, read)
	if read_err != nil {
		return nil, read_err
	}
	defer tape.destroy(&doc)
	werr: write.Error
	#partial switch target in to {
	case json.Spec:
		text, _, werr = json.write(&doc, target, opts)
	case dsv.Spec:
		text, _, werr = dsv.write(&doc, target, opts)
	}
	if werr != nil {
		return nil, werr
	}
	return text, nil
}

@(test)
rows_hold_less_than_a_document :: proc(t: ^testing.T) {
	testkit.deadline(t)
	big := strings.builder_make()
	defer strings.builder_destroy(&big)
	strings.write_string(&big, "id,name,note\n")
	for i in 0 ..< 60000 {
		fmt.sbprintf(&big, "%d,\"n, %d\",\n", i, i)
	}
	src := transmute([]u8)strings.to_string(big)
	peaks: [2]i64
	for route in 0 ..< 2 {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		allocator := mem.tracking_allocator(&track)
		text: []u8
		if route == 0 {
			text, _, _ = stury.format(src, dsv.Spec.Csv, dsv.Spec.Tsv, BOUNDED, {}, allocator)
		} else {
			doc, _ := dsv.build(src, .Csv, {}, allocator)
			text, _, _ = dsv.write(&doc, .Tsv, {}, allocator)
			tape.destroy(&doc)
		}
		delete(text, allocator)
		peaks[route] = track.peak_memory_allocated
	}
	testing.expectf(t, peaks[0] < peaks[1] / 2, "rows hold %d bytes at most, a document %d", peaks[0], peaks[1])
}

@(test)
rows_of_a_delimited_text_are_what_a_document_of_it_writes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	big := strings.builder_make()
	defer strings.builder_destroy(&big)
	strings.write_string(&big, "id,name,note\n")
	for i in 0 ..< 3000 {
		fmt.sbprintf(&big, "%d,\"n, %d\",\n", i, i)
	}
	texts := [?]string{
		"id,name\n1,x\n2,\"y,z\"\n",
		"\xEF\xBB\xBFid,name\r\n1,x\r\n2,\r\n",
		"id,name\n1,x\n2\n",
		"id,id\n1,2\n",
		"id,name\n",
		"",
		"id,name\n1,\"x\"\"\ny\"\n\n3,z",
		"a\n\"\"\n",
		strings.to_string(big),
	}
	targets := [?]stury.Spec{json.Spec.Json, dsv.Spec.Csv, dsv.Spec.Tsv}
	options := [?]write.Options{{}, {indent = 2}, {tab = true}, {ascii = true}}
	for text, i in texts {
		for from in ([?]dsv.Spec{.Csv, .Tsv}) {
			for to, j in targets {
				for opts, k in options {
					if _, is_json := to.(json.Spec); !is_json && k > 0 {
						continue
					}
					src := transmute([]u8)text
					got, _, gerr := stury.format(src, from, to, BOUNDED, opts)
					want, werr := document_route(src, from, to, BOUNDED, opts)
					defer delete(got)
					defer delete(want)
					testing.expectf(t, string(got) == string(want), "%d %v %d %d: %q, a document writes %q", i, from, j, k, got, want)
					testing.expectf(t, gerr == werr, "%d %v %d %d: %v, a document gives %v", i, from, j, k, gerr, werr)
				}
			}
		}
	}
}
