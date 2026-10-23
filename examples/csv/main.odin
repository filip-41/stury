// Read CSV rows into structs, write them back, and report a cell the struct cannot hold.
//
// Run from the repository root: odin run examples/csv -collection:stury=.
package main

import csv "stury:csv"
import "core:fmt"
import "core:os"

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
}
