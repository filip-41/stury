// Reads CSV into a struct, writes it as JSON, reads the JSON back and writes CSV. One procedure reports a
// fault of either format.
//
// Run from the repository root: odin run examples/crossformat -collection:stury=.
package main

import "stury:core"
import csv "stury:csv"
import json "stury:json"
import "core:fmt"
import "core:os"

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

// Both formats return core's Unmarshal_Error, so one function handles either.
load :: proc(format: Format, src: []byte, cities: ^[]City) -> Maybe(core.Unmarshal_Error) {
	switch format {
	case .Csv:
		return csv.unmarshal(src, cities)
	case .Json:
		return json.unmarshal(src, cities)
	}
	unreachable()
}

// core.render_error writes the fault of either format as `line:col: kind at path`.
report :: proc(src: []byte, err: core.Unmarshal_Error) {
	fmt.println(core.render_error(src, err))
}

main :: proc() {
	table := transmute([]byte)string("City,population,lat,lon\nOslo,709000,59.91,10.75\n\"Ho, Chi Minh\",,10.82,106.63\n")
	cities: []City
	if err, bad := load(.Csv, table, &cities).?; bad {
		report(table, err)
		os.exit(1)
	}

	as_json, jerr := json.marshal(cities)
	if jerr != .None {
		fmt.eprintln(jerr)
		os.exit(1)
	}
	fmt.println(string(as_json)) // [{"city":"Oslo","population":709000,"lat":59.91,"lon":10.75},{"city":"Ho, Chi Minh","population":null,"lat":10.82,"lon":106.63}]

	back: []City
	if err, bad := load(.Json, as_json, &back).?; bad {
		report(as_json, err)
		os.exit(1)
	}
	as_csv, cerr := csv.marshal(back)
	if cerr != .None {
		fmt.eprintln(cerr)
		os.exit(1)
	}
	fmt.println(string(as_csv) == string(table)) // true

	// A population that is not a number, in each format.
	bad_csv := transmute([]byte)string("City,population,lat,lon\nOslo,lots,59.91,10.75\n")
	bad_json := transmute([]byte)string(`[{"city":"Oslo","population":"lots","lat":59.91,"lon":10.75}]`)
	if err, bad := load(.Csv, bad_csv, &cities).?; bad {
		report(bad_csv, err) // 2:6: Wrong_Kind at [0].population
	}
	if err, bad := load(.Json, bad_json, &cities).?; bad {
		report(bad_json, err) // 1:30: Wrong_Kind at [0].population
	}
}
