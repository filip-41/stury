package records

import "stury:lib/core/tape"

// A text that holds a list of records, which a format's records read hands on one at a time, each as it closes.

// How a text holds its records.
Framing :: enum u8 {
	// One value per line (NDJSON). A line of white space alone holds no record. A record whose line holds more than one
	// value, or a value that runs on past its line, is refused, and the records go on at the next line.
	Lines,
	// The elements of the root array. A fault ends the records, as the text holds no list past it.
	Elements,
}

// One record: the records before it, its bytes in the text, and why it does not read, nil when it does. Its bytes run
// from its first byte that is no white space to its line's end less a CR under `.Lines`, and to its value's end under
// `.Elements`. Every offset, those of `err` included, counts from the text's first byte.
Record :: struct {
	index:  u64,
	lo, hi: u64,
	err:    tape.Error,
}
