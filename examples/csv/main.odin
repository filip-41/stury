// Read CSV rows into structs, write them back, and report a cell the struct cannot hold. Then the rest of
// the package: dialects, a document and path reads, edits that keep every other byte, and records read one
// at a time, from a reader, and on threads.
//
// Run from the repository root: odin run examples/csv -collection:stury=.
package main

import csv "stury:csv"
import "stury:host"
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

main :: proc() {
	src := transmute([]byte)string("City,population,lat,lon\nOslo,709000,59.91,10.75\n\"Ho, Chi Minh\",,10.82,106.63\n")
	cities: []City
	if err, bad := csv.unmarshal(src, &cities).?; bad {
		fmt.eprintln(err.kind, "at byte", err.offset)
		os.exit(1)
	}
	fmt.println(cities[1].name, cities[1].population) // Ho, Chi Minh nil

	out, err := csv.marshal(cities)
	if err != .None {
		fmt.eprintln(err)
		os.exit(1)
	}
	fmt.print(string(out)) // the same text back: the comma keeps its quotes, the missing population stays empty

	bad := transmute([]byte)string("City,population,lat,lon\nOslo,lots,59.91,10.75\n")
	e, refused := csv.unmarshal(bad, &cities).?
	if !refused {
		os.exit(1)
	}
	fmt.println(e.kind, "at byte", e.offset) // Wrong_Kind at byte 29: row 0's population

	dialects(&cities)
	document_and_edits(src)
	streaming(src)
}

// A Dialect reads other delimited text through the same calls.
dialects :: proc(cities: ^[]City) {
	tsv := transmute([]byte)string("City\tpopulation\tlat\tlon\nOslo\t709000\t59.91\t10.75\n")
	if _, bad := csv.unmarshal(tsv, cities, {dialect = csv.TSV}).?; bad {
		os.exit(1)
	}
	fmt.println(cities[0].name, cities[0].population) // Oslo 709000

	// No header: column k is the struct's field k. A semicolon delimiter, and lines starting with # skipped.
	plain := transmute([]byte)string("# name;population;lat;lon\nOslo;709000;59.91;10.75\n")
	opts := csv.Unmarshal_Opts{dialect = {delimiter = ';', comment = '#'}, no_header = true}
	if _, bad := csv.unmarshal(plain, cities, opts).?; bad {
		os.exit(1)
	}
	fmt.println(len(cities^), cities[0].lat) // 1 59.91
}

// A Document keeps where every cell is, `find` reads one cell without building anything, and the edits return
// the text with only the targeted bytes changed.
document_and_edits :: proc(src: []byte) {
	doc, derr := csv.build(src)
	if derr != nil {
		os.exit(1)
	}
	defer csv.document_destroy(&doc)
	col, _ := csv.column(&doc, "lat")
	lat, _ := csv.get_float(&doc, 0, col)
	fmt.println(csv.row_count(&doc), lat) // 2 59.91

	field, found, ferr := csv.find(src, ".[1].City")
	if ferr != nil || !found {
		os.exit(1)
	}
	text, _, _ := csv.field_text(src, field)
	fmt.println(string(text)) // Ho, Chi Minh

	edited, eerr := csv.set(src, ".[0].population", 710000)
	if eerr != nil {
		os.exit(1)
	}
	defer delete(edited)
	fmt.print(string(edited)) // City,population,lat,lon
	//                           Oslo,710000,59.91,10.75
	//                           "Ho, Chi Minh",,10.82,106.63

	added, aerr := csv.insert(src, csv.APPEND, City{name = "Bergen", lat = 60.39, lon = 5.32})
	if aerr != nil {
		os.exit(1)
	}
	defer delete(added)
	fmt.print(string(added)[len(src):]) // Bergen,,60.39,5.32

	trimmed, rerr := csv.remove(src, ".[].population")
	if rerr != nil {
		os.exit(1)
	}
	defer delete(trimmed)
	fmt.print(string(trimmed)) // City,lat,lon
	//                            Oslo,59.91,10.75
	//                            "Ho, Chi Minh",10.82,106.63
}

// Records one at a time from a reader, on threads, and a record written by hand.
streaming :: proc(src: []byte) {
	r: strings.Reader
	strings.reader_init(&r, string(src))
	rr := csv.records_from(io.to_reader(strings.reader_to_stream(&r)))
	defer csv.records_destroy(&rr)
	for rec in csv.next_record(&rr) {
		text, _, _ := csv.field_text(rec.src, rec.fields[0])
		fmt.println(rec.at, len(rec.fields), string(text)) // 0 4 City, then 24 4 Oslo, then 48 4 Ho, Chi Minh
	}
	if _, bad := rr.err.?; bad {
		os.exit(1)
	}

	pool: host.Batch_Pool
	host.batch_pool_init(&pool) // one worker per core
	defer host.batch_pool_destroy(&pool)
	rows: int
	count := proc(data: rawptr, piece: ^csv.Records, k: int) -> bool {
		for _ in csv.next_record(piece) {
			sync.atomic_add((^int)(data), 1)
		}
		return true
	}
	if _, bad := csv.each_record(src, {}, count, &rows, &pool.runner).?; bad {
		os.exit(1)
	}
	fmt.println(rows) // 3: the header and two rows

	line: [dynamic]u8
	defer delete(line)
	cells := []Maybe(string){"Tromsø", nil, "69.65", "18.96"}
	if csv.write_record(&line, cells) != .None {
		os.exit(1)
	}
	fmt.print(string(line[:])) // Tromsø,,69.65,18.96
}
