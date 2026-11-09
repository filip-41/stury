// Reads CSV into a struct, writes it as JSON, reads the JSON back and writes CSV. One procedure reads and one
// reports a fault of either format.
//
// Run from the repository root: odin run examples/crossformat -collection:stury=.
package main

import "stury:core"
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

// Both formats return core's Error, so one function handles either.
load :: proc(format: Format, src: []byte, cities: ^[]City) -> core.Error {
	switch format {
	case .Csv:
		return dsv.unmarshal(src, .Csv, cities, allocator = context.temp_allocator)
	case .Json:
		return json.unmarshal(src, .Json, cities, allocator = context.temp_allocator)
	}
	unreachable()
}

// core.render writes the error of either format as `line:col: text at path`.
report :: proc(src: []byte, err: core.Error) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	core.render(strings.to_writer(&b), src, err)
	fmt.println(strings.to_string(b))
}

main :: proc() {
	// What the reads allocate, freed at once.
	defer free_all(context.temp_allocator)
	table := transmute([]byte)string("City,population,lat,lon\nOslo,709000,59.91,10.75\n\"Ho, Chi Minh\",,10.82,106.63\n")
	cities: []City
	if err := load(.Csv, table, &cities); err != nil {
		report(table, err)
		os.exit(1)
	}

	as_json, jerr := json.marshal(cities)
	if jerr != nil {
		report(nil, jerr)
		os.exit(1)
	}
	fmt.println(string(as_json)) // [{"city":"Oslo","population":709000,"lat":59.91,"lon":10.75},{"city":"Ho, Chi Minh","population":null,"lat":10.82,"lon":106.63}]

	back: []City
	if err := load(.Json, as_json, &back); err != nil {
		report(as_json, err)
		os.exit(1)
	}
	as_csv, cerr := dsv.marshal(back)
	if cerr != nil {
		report(nil, cerr)
		os.exit(1)
	}
	fmt.println(string(as_csv) == string(table)) // true

	// A population that is not a number, in each format.
	bad_csv := transmute([]byte)string("City,population,lat,lon\nOslo,lots,59.91,10.75\n")
	bad_json := transmute([]byte)string(`[{"city":"Oslo","population":"lots","lat":59.91,"lon":10.75}]`)
	if err := load(.Csv, bad_csv, &cities); err != nil {
		report(bad_csv, err) // 2:6: Expected i64, found "lots" at .[0].population
	}
	if err := load(.Json, bad_json, &cities); err != nil {
		report(bad_json, err) // 1:30: Expected i64, found string at .[0].population
	}
}
