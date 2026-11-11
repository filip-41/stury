// Reads CSV into a struct, writes it as JSON, reads the JSON back and writes CSV. One procedure reads and one
// reports a fault of either format.
//
// Run from the repository root: odin run examples/crossformat -collection:stury=.
package main

import "stury:dsv"
import "stury:json"
import "core:fmt"
import "core:os"
import "core:strings"

// Each format reads its own tag key. A field with no tag uses its own name in both.
City :: struct {
	name:       string `csv:"City" json:"city"`,
	population: Maybe(i64),
	lat, lon:   f64,
}

Format :: enum {
	Csv,
	Json,
}

// Both formats return the same Error, so one function handles either.
load :: proc(format: Format, src: []byte, cities: ^[]City) -> json.Error {
	switch format {
	case .Csv:
		return dsv.unmarshal(src, .Csv, cities, allocator = context.temp_allocator)
	case .Json:
		return json.unmarshal(src, .Json, cities, allocator = context.temp_allocator)
	}
	unreachable()
}

// json.render writes the error of either format as `line:col: text at path`.
report :: proc(src: []byte, err: json.Error) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	json.render(strings.to_writer(&b), src, err)
	fmt.println(strings.to_string(b))
}

main :: proc() {
	// What the reads allocate, freed at once.
	defer free_all(context.temp_allocator)
	table := transmute([]byte)string("City,population,lat,lon\nOslo,709000,59.91,10.75\n\"Ho, Chi Minh\",,10.82,106.63\n")
	if err := convert(table); err != nil {
		report(table, err)
		os.exit(1)
	}

	// A population that is not a number, in each format.
	cities: []City
	bad_csv := transmute([]byte)string("City,population,lat,lon\nOslo,lots,59.91,10.75\n")
	bad_json := transmute([]byte)string(`[{"city":"Oslo","population":"lots","lat":59.91,"lon":10.75}]`)
	if err := load(.Csv, bad_csv, &cities); err != nil {
		report(bad_csv, err) // 2:6: Expected i64, found "lots" at .[0].population
	}
	if err := load(.Json, bad_json, &cities); err != nil {
		report(bad_json, err) // 1:30: Expected i64, found string at .[0].population
	}
}

// Reads `table` as CSV, writes it as JSON, reads the JSON back and writes CSV.
convert :: proc(table: []byte) -> json.Error {
	cities: []City
	load(.Csv, table, &cities) or_return

	as_json := json.marshal(cities) or_return
	fmt.println(string(as_json)) // [{"city":"Oslo","population":709000,"lat":59.91,"lon":10.75},{"city":"Ho, Chi Minh","population":null,"lat":10.82,"lon":106.63}]

	back: []City
	load(.Json, as_json, &back) or_return
	as_csv := dsv.marshal(back) or_return
	fmt.println(string(as_csv) == string(table)) // true
	return nil
}
