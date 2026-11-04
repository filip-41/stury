// Reads CSV rows into structs, writes them back and reports a cell the struct cannot hold. Also shows other
// delimited dialects, a document, path reads, edits that keep every other byte, and records read from an io.Reader
// and on threads.
//
// Run from the repository root: odin run examples/dsv -collection:stury=.
package main

import "stury:core"
import "stury:core/records"
import "stury:dsv"
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

// An error renders as `line:col: message at path`.
report :: proc(src: []u8, e: $E) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	core.render(strings.to_writer(&b), src, e)
	fmt.println(strings.to_string(b))
}

main :: proc() {
	// What the reads allocate, freed at once.
	defer free_all(context.temp_allocator)
	src := transmute([]byte)string("City,population,lat,lon\nOslo,709000,59.91,10.75\n\"Ho, Chi Minh\",,10.82,106.63\n")
	cities: []City
	if err := dsv.unmarshal(src, .Csv, &cities, allocator = context.temp_allocator); err.kind != .None {
		report(src, err)
		os.exit(1)
	}
	fmt.println(cities[1].name, cities[1].population) // Ho, Chi Minh nil

	out, err := dsv.marshal(cities)
	if err.kind != .None {
		report(nil, err)
		os.exit(1)
	}
	fmt.print(string(out)) // src again: "Ho, Chi Minh" keeps its quotes and the absent population stays empty

	bad := transmute([]byte)string("City,population,lat,lon\nOslo,lots,59.91,10.75\n")
	if err := dsv.unmarshal(bad, .Csv, &cities, allocator = context.temp_allocator); err.kind != .None {
		report(bad, err) // 2:6: Value does not fit the field's type at [0].population
	}

	dialects(&cities)
	document_and_edits(src)
	streaming(src)
}

// A Spec and Options read other delimited text through the same calls.
dialects :: proc(cities: ^[]City) {
	tsv := transmute([]byte)string("City\tpopulation\tlat\tlon\nOslo\t709000\t59.91\t10.75\n")
	if dsv.unmarshal(tsv, .Tsv, cities, allocator = context.temp_allocator).kind != .None {
		os.exit(1)
	}
	fmt.println(cities[0].name, cities[0].population) // Oslo 709000

	// No header: column k is the struct's field k. A semicolon delimiter, and lines starting with # skipped.
	plain := transmute([]byte)string("# name;population;lat;lon\nOslo;709000;59.91;10.75\n")
	layout := dsv.Options{no_header = true, delimiter = ';', comment = '#'}
	if dsv.unmarshal(plain, .Csv, cities, opts = layout, allocator = context.temp_allocator).kind != .None {
		os.exit(1)
	}
	fmt.println(len(cities^), cities[0].lat) // 1 59.91
}

// A Document is the text as core's rows: an array of objects keyed by the header. `find` reads one cell without
// building a document. An edit returns the text with only the targeted bytes changed.
document_and_edits :: proc(src: []byte) {
	doc, derr := dsv.build(src, .Csv)
	if derr.kind != .None {
		os.exit(1)
	}
	defer core.destroy(&doc)
	oslo, _ := core.child_at(&doc, core.ROOT, 0)
	lat, _ := core.member(&doc, oslo, "lat")
	buf: [32]u8
	text, _ := core.text(&doc, lat, buf[:])
	fmt.println(core.length(&doc, core.ROOT), text) // 2 59.91

	city, _ := core.parse_path(".[1].City")
	defer core.path_destroy(&city)
	fdoc, answer, ferr := dsv.find(src, .Csv, city)
	if ferr.kind != .None || answer == nil {
		os.exit(1)
	}
	defer core.destroy(&fdoc)
	text, _ = core.text(&fdoc, answer.?.node, buf[:])
	fmt.println(text) // Ho, Chi Minh

	population, _ := core.parse_path(".[0].population")
	defer core.path_destroy(&population)
	edited, eerr := dsv.set(src, .Csv, population, "710000")
	if eerr.kind != .None {
		os.exit(1)
	}
	defer delete(edited)
	fmt.print(string(edited)) // City,population,lat,lon
	//                           Oslo,710000,59.91,10.75
	//                           "Ho, Chi Minh",,10.82,106.63

	// Edits on a document are recorded on a list and applied by one commit.
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	if core.insert(&list, core.ROOT, 2, "Bergen,,60.39,5.32").kind != .None {
		os.exit(1)
	}
	added, _, aerr := core.commit(&list)
	if aerr.kind != .None {
		os.exit(1)
	}
	defer delete(added)
	fmt.print(string(added)[len(src):]) // Bergen,,60.39,5.32

	// A cell removed from every row drops its column, header included.
	every, _ := core.parse_path(".[].population")
	defer core.path_destroy(&every)
	cells, qerr := core.query(&doc, every)
	if qerr.kind != .None {
		os.exit(1)
	}
	defer delete(cells)
	dropping := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&dropping)
	for c in cells {
		if core.remove(&dropping, c.node).kind != .None {
			os.exit(1)
		}
	}
	trimmed, _, rerr := core.commit(&dropping)
	if rerr.kind != .None {
		os.exit(1)
	}
	defer delete(trimmed)
	fmt.print(string(trimmed)) // City,lat,lon
	//                            Oslo,59.91,10.75
	//                            "Ho, Chi Minh",10.82,106.63
}

// Records read from an io.Reader and on threads, and one row written with `write_cells`.
streaming :: proc(src: []byte) {
	as := dsv.as(.Csv)
	r: strings.Reader
	strings.reader_init(&r, string(src))
	rr := records.open_stream(io.to_reader(strings.reader_to_stream(&r)), as)
	defer records.close(&rr)
	for rec in records.next(&rr) {
		fmt.println(rec.at, len(rec.text), string(rec.text)) // 24 and Oslo's row, then 48: the header is no record
	}
	if rr.fault != nil {
		os.exit(1)
	}

	pool: host.Pool
	if host.pool_init(&pool) != nil { // one worker per core
		os.exit(1)
	}
	defer host.pool_destroy(&pool)
	rows: int
	count := proc(n: ^int, piece: ^records.Reader, _: int) -> bool {
		for _ in records.next(piece) {
			sync.atomic_add(n, 1)
		}
		return true
	}
	if _, bad := records.each(src, as, .Lines, count, &rows, &pool.runner).?; bad {
		os.exit(1)
	}
	fmt.println(rows) // 2: the header is no record

	wr: records.Writer
	if records.writer_init(&wr, {}, as) != .None {
		os.exit(1)
	}
	defer records.writer_destroy(&wr)
	if records.write_cells(&wr, []Maybe(string){"Tromsø", nil, "69.65", "18.96"}) != .None {
		os.exit(1)
	}
	line, werr := records.writer_end(&wr)
	if werr.kind != .None {
		os.exit(1)
	}
	defer delete(line)
	fmt.print(string(line)) // Tromsø,,69.65,18.96
}
