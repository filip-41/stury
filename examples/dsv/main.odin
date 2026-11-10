// Reads CSV rows into structs, writes them back and reports a cell the struct cannot hold. Also shows other
// delimited dialects, a document, path reads, edits that keep every other byte, and records read from an io.Reader
// and on threads.
//
// Run from the repository root: odin run examples/dsv -collection:stury=.
package main

import "stury:dsv"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:sync"

City :: struct {
	name:       string `csv:"City"`,
	population: Maybe(i64),
	lat, lon:   f64,
}

// An error renders as `line:col: message at path`.
report :: proc(src: []u8, e: dsv.Error) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	dsv.render(strings.to_writer(&b), src, e)
	fmt.println(strings.to_string(b))
}

main :: proc() {
	// What the reads allocate, freed at once.
	defer free_all(context.temp_allocator)
	src := transmute([]byte)string("City,population,lat,lon\nOslo,709000,59.91,10.75\n\"Ho, Chi Minh\",,10.82,106.63\n")
	if err := run(src); err != nil {
		report(src, err)
		os.exit(1)
	}
}

run :: proc(src: []byte) -> dsv.Error {
	cities: []City
	dsv.unmarshal(src, .Csv, &cities, allocator = context.temp_allocator) or_return
	fmt.println(cities[1].name, cities[1].population) // Ho, Chi Minh nil

	out := dsv.marshal(cities) or_return
	fmt.print(string(out)) // src again: "Ho, Chi Minh" keeps its quotes and the absent population stays empty

	bad := transmute([]byte)string("City,population,lat,lon\nOslo,lots,59.91,10.75\n")
	if bad_err := dsv.unmarshal(bad, .Csv, &cities, allocator = context.temp_allocator); bad_err != nil {
		report(bad, bad_err) // 2:6: Expected i64, found "lots" at .[0].population
	}

	dialects(&cities) or_return
	document_and_edits(src) or_return
	streaming(src) or_return
	return nil
}

// A Spec and Options read other delimited text through the same calls.
dialects :: proc(cities: ^[]City) -> dsv.Error {
	tsv := transmute([]byte)string("City\tpopulation\tlat\tlon\nOslo\t709000\t59.91\t10.75\n")
	dsv.unmarshal(tsv, .Tsv, cities, allocator = context.temp_allocator) or_return
	fmt.println(cities[0].name, cities[0].population) // Oslo 709000

	// No header: column k is the struct's field k. A semicolon delimiter, and lines starting with # skipped.
	plain := transmute([]byte)string("# name;population;lat;lon\nOslo;709000;59.91;10.75\n")
	layout := dsv.Options{no_header = true, delimiter = ';', comment = '#'}
	dsv.unmarshal(plain, .Csv, cities, opts = layout, allocator = context.temp_allocator) or_return
	fmt.println(len(cities^), cities[0].lat) // 1 59.91
	return nil
}

// A Document is the text as rows: an array of objects keyed by the header. `find` reads one cell without
// building a document. An edit returns the text with only the targeted bytes changed.
document_and_edits :: proc(src: []byte) -> dsv.Error {
	doc := dsv.build(src, .Csv) or_return
	defer dsv.destroy(&doc)
	oslo, _ := dsv.child_at(&doc, dsv.ROOT, 0)
	lat, _ := dsv.member(&doc, oslo, "lat")
	buf: [32]u8
	text, _ := dsv.text(&doc, lat, buf[:])
	fmt.println(dsv.length(&doc, dsv.ROOT), text) // 2 59.91

	city, _ := dsv.parse_path(".[1].City")
	defer dsv.destroy(&city)
	fdoc, answer := dsv.find(src, .Csv, city) or_return
	if answer.outcome != .Found {
		fmt.println("not found")
		os.exit(1)
	}
	defer dsv.destroy(&fdoc)
	text, _ = dsv.text(&fdoc, answer.node, buf[:])
	fmt.println(text) // Ho, Chi Minh

	population, _ := dsv.parse_path(".[0].population")
	defer dsv.destroy(&population)
	edited := dsv.set(src, .Csv, population, "710000") or_return
	defer delete(edited)
	fmt.print(string(edited)) // City,population,lat,lon
	//                           Oslo,710000,59.91,10.75
	//                           "Ho, Chi Minh",,10.82,106.63

	// Edits on a document are recorded on a list and applied by one commit.
	list := dsv.edit_list_init(&doc, .Csv)
	defer dsv.destroy(&list)
	dsv.insert(&list, dsv.ROOT, 2, "Bergen,,60.39,5.32") or_return
	added, _ := dsv.commit(&list) or_return
	defer delete(added)
	fmt.print(string(added)[len(src):]) // Bergen,,60.39,5.32

	// A cell removed from every row drops its column, header included.
	every, _ := dsv.parse_path(".[].population")
	defer dsv.destroy(&every)
	cells := dsv.query(&doc, every) or_return
	defer delete(cells)
	dropping := dsv.edit_list_init(&doc, .Csv)
	defer dsv.destroy(&dropping)
	for c in cells {
		dsv.remove(&dropping, c.node) or_return
	}
	trimmed, _ := dsv.commit(&dropping) or_return
	defer delete(trimmed)
	fmt.print(string(trimmed)) // City,lat,lon
	//                            Oslo,59.91,10.75
	//                            "Ho, Chi Minh",10.82,106.63
	return nil
}

// Records read from an io.Reader and on threads, and one row written with `write_cells`.
streaming :: proc(src: []byte) -> dsv.Error {
	r: strings.Reader
	strings.reader_init(&r, string(src))
	rr := dsv.records_open_stream(io.to_reader(strings.reader_to_stream(&r)), .Csv)
	defer dsv.records_close(&rr)
	for rec in dsv.records_next(&rr) {
		fmt.println(rec.at, len(rec.text), string(rec.text)) // 24 and Oslo's row, then 48: the header is no record
	}
	if fault, bad := rr.fault.?; bad {
		return fault
	}

	pool: dsv.Pool
	dsv.pool_init(&pool) or_return // one worker per core
	defer dsv.destroy(&pool)
	rows: int
	count := proc(n: ^int, piece: ^dsv.Record_Reader, _: int) -> bool {
		for _ in dsv.records_next(piece) {
			sync.atomic_add(n, 1)
		}
		return true
	}
	dsv.records_each(src, .Csv, .Lines, count, &rows, &pool.runner) or_return
	fmt.println(rows) // 2: the header is no record

	wr: dsv.Record_Writer
	if kind := dsv.writer_init(&wr, {}, .Csv); kind != .None {
		return kind
	}
	defer dsv.destroy(&wr)
	if kind := dsv.write_cells(&wr, {"Tromsø", nil, "69.65", "18.96"}); kind != .None {
		return kind
	}
	line := dsv.writer_end(&wr) or_return
	defer delete(line)
	fmt.print(string(line)) // Tromsø,,69.65,18.96
	return nil
}
