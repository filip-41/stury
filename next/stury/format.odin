package stury

import "base:runtime"
import "stury:cbor"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:toml"
import "stury:xml"

// The facade of the library, which a program that works with more than one format imports. It holds what reads in one
// format and writes in another, which no format's package can, as a format imports no other.

// A format and its spec, as a read or a write takes them.
Spec :: union {
	json.Spec,
	toml.Spec,
	xml.Spec,
	dsv.Spec,
	cbor.Spec,
}

// The error of `format`: the read's or the write's.
Format_Error :: union {
	tape.Error,
	write.Error,
}

// Reads `src` as a text of `from` under `read` and writes it as a text of `to` under `opts` in a buffer from
// `allocator` that the caller owns. Returns the kinds of the facts the text read holds that the written text does not,
// as the target's `write` does. A read that finds a fault, and a value the target cannot spell, are the error.
format :: proc(src: []u8, from, to: Spec, read := tape.Options{}, opts := write.Options{}, allocator := context.allocator) -> (text: []u8, dropped: tape.Facts, err: Format_Error) {
	if from == nil {
		return nil, {}, tape.Error(tape.Bad_Option{"from"})
	}
	if to == nil {
		return nil, {}, write.Error(tape.Bad_Option{"to"})
	}
	doc, read_err := build(src, from, read, allocator)
	if read_err != nil {
		return nil, {}, read_err
	}
	defer tape.destroy(&doc)
	werr: write.Error
	switch target in to {
	case json.Spec:
		text, dropped, werr = json.write(&doc, target, opts, allocator)
	case toml.Spec:
		text, dropped, werr = toml.write(&doc, target, opts, allocator)
	case xml.Spec:
		text, dropped, werr = xml.write(&doc, target, opts, allocator)
	case dsv.Spec:
		text, dropped, werr = dsv.write(&doc, target, opts, allocator)
	case cbor.Spec:
		text, dropped, werr = cbor.write(&doc, target, opts, allocator)
	}
	if werr != nil {
		return nil, {}, werr
	}
	return text, dropped, nil
}

@(private)
build :: proc(src: []u8, from: Spec, opts: tape.Options, allocator: runtime.Allocator) -> (doc: tape.Document, err: tape.Error) {
	switch spec in from {
	case json.Spec:
		return json.build(src, spec, opts, allocator)
	case toml.Spec:
		return toml.build(src, spec, opts, allocator)
	case xml.Spec:
		return xml.build(src, spec, opts, allocator)
	case dsv.Spec:
		return dsv.build(src, spec, opts, allocator)
	case cbor.Spec:
		return cbor.build(src, spec, opts, allocator)
	}
	return {}, tape.Bad_Option{"from"}
}
