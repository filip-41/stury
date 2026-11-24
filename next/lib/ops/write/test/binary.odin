package write_tests

import "core:testing"
import "stury:cbor"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// A CBOR document into JSON and CSV: a byte string is the base64 of its payload as a value, as it is as a key, and a
// number is its value in decimal, exact, whatever its size: a bignum, a decimal fraction, a negative integer down to
// -2^64, none a float spelling.

@(private = "file")
Binary_Case :: struct {
	cbor: []u8,
	json: string,
	csv:  string, 
}

@(private = "file")
BINARY_CASES := []Binary_Case {
	{{0x41, 0x01}, `"AQ=="`, "AQ==\n"},
	{{0x40}, `""`, "\"\"\n"},
	{{0x82, 0x41, 0x01, 0x42, 0xff, 0x00}, `["AQ==","/wA="]`, "AQ==\n/wA=\n"},
	{{0x5f, 0x41, 0x01, 0x42, 0x02, 0x03, 0xff}, `"AQID"`, "AQID\n"},
	{{0xa1, 0x41, 0x01, 0x41, 0x02}, `{"AQ==":"Ag=="}`, "AQ==\nAg==\n"},
	{{0xc2, 0x49, 1, 0, 0, 0, 0, 0, 0, 0, 0}, "18446744073709551616", "18446744073709551616\n"},
	{{0xc3, 0x49, 1, 0, 0, 0, 0, 0, 0, 0, 0}, "-18446744073709551617", "-18446744073709551617\n"},
	{{0xc4, 0x82, 0x20, 0x03}, "3e-1", "3e-1\n"},
	{{0x3b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, "-18446744073709551616", "-18446744073709551616\n"},
	{{0x3b, 0x80, 0, 0, 0, 0, 0, 0, 0}, "-9223372036854775809", "-9223372036854775809\n"},
	{{0x3b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, "-9223372036854775808", "-9223372036854775808\n"},
	{{0x3b, 0x80, 0, 0, 0, 0, 0, 0, 0x01}, "-9223372036854775810", "-9223372036854775810\n"},
	{{0x31}, "-18", "-18\n"},
	{{0x38, 0x33}, "-52", "-52\n"},
	{{0x82, 0x38, 0x33, 0x18, 0x31}, "[-52,49]", "-52\n49\n"},
	{{0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, "18446744073709551615", "18446744073709551615\n"},
	{{0xf9, 0x3c, 0x00}, "1.0", "1.0\n"},
}

@(test)
binary_documents_into_json_and_csv :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in BINARY_CASES {
		doc, err := cbor.build(c.cbor)
		if !testing.expectf(t, err == nil, "%x: %v", c.cbor, err) {
			continue
		}
		defer cbor.destroy(&doc)
		for spec in ([]json.Spec{.Json, .Jsonc, .Json5}) {
			text, _, werr := json.write(&doc, spec)
			testing.expectf(t, werr == nil && string(text) == c.json, "%x as %v: %q, %v, want %q", c.cbor, spec, text, werr, c.json)
			delete(text)
		}
		text, _, werr := dsv.write(&doc, .Csv)
		testing.expectf(t, werr == nil && string(text) == c.csv, "%x as CSV: %q, %v, want %q", c.cbor, text, werr, c.csv)
		delete(text)
	}
}

// Nothing an array of arrays writes as CSV has keys, so a header would read back as its first record.
@(test)
binary_array_of_arrays_into_csv_needs_no_header :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := cbor.build({0x82, 0x82, 0x01, 0x02, 0x82, 0x03, 0x04})
	testing.expect(t, err == nil)
	defer cbor.destroy(&doc)
	_, _, werr := dsv.write(&doc, .Csv)
	bad, is_bad := werr.(tape.Bad_Option)
	testing.expect(t, is_bad && bad.option == "no_header")
	text, _, werr2 := dsv.write(&doc, .Csv, {format = tape.Dsv_Options{no_header = true}})
	testing.expectf(t, werr2 == nil && string(text) == "1,2\n3,4\n", "%q, %v", text, werr2)
	delete(text)
}
