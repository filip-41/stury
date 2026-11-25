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
	if rows, taken := rows_route(src, from, to, read, opts, allocator); taken {
		return rows.text, {}, rows.err
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

// The records of a delimited text written as rows, with no document of the text: each record is read and written
// alone, so the memory held is a record and a batch of rows. It is slower than a document of the text, which writes
// a delimited target by copying the cells' bytes, so a read takes it when it bounds memory (`Budget.memory` and no other
// limit), for a delimited text with no comment byte and no pieces, a target that is a delimited text or JSON, written
// whole and unsorted, and a text with a record, since a text with none holds a header that a document of it writes and
// records do not. A JSON array of objects is not read so, as its header is the union of every row's keys and the rows
// are held to know it.
@(private)
Rows :: struct {
	text: []u8,
	err:  Format_Error,
}

// What the rows are written into.
@(private)
Row_Sink :: struct {
	json:    json.Writer,
	dsv:     dsv.Writer,
	to_json: bool,
}

@(private)
ROWS_BATCH :: 64

@(private)
rows_route :: proc(src: []u8, from, to: Spec, read: tape.Options, opts: write.Options, allocator: runtime.Allocator) -> (rows: Rows, taken: bool) {
	spec, delimited := from.(dsv.Spec)
	if !delimited || read.budget.memory == 0 || read.budget != {memory = read.budget.memory} || read.pieces != nil || opts.framing != .None || opts.node != 0 || opts.sort_keys {
		return
	}
	if format, given := read.format.(tape.Dsv_Options); given && format.comment != 0 {
		return
	}
	sink: Row_Sink
	switch target in to {
	case json.Spec:
		if target != .Json || opts.format != nil {
			return
		}
		sink.to_json = true
	case dsv.Spec:
	case toml.Spec, xml.Spec, cbor.Spec:
		return
	}
	r := dsv.records_open(src, .Lines, spec, read)
	defer tape.destroy_records(&r)
	demand, derr := tape.demand_of([][]tape.Step{{}}, allocator = allocator)
	if derr != nil {
		return
	}
	defer tape.destroy(&demand)
	if err := rows_start(&sink, to, opts, allocator); err != nil {
		return Rows{err = err}, true
	}
	out: [ROWS_BATCH]tape.Record
	docs: [ROWS_BATCH]tape.Document
	count: int
	fault: Format_Error
	for fault == nil {
		n := dsv.records_scan(&r, &demand, out[:], docs[:], {}, allocator)
		for i in 0 ..< n {
			if out[i].err != nil {
				fault = out[i].err
			} else if e := rows_put(&sink, &docs[i], allocator); e != nil {
				fault = e
			}
			if fault != nil {
				break
			}
		}
		count += n
		if n < ROWS_BATCH {
			if fault == nil && r.err != nil {
				fault = r.err
			}
			break
		}
	}
	text, end := rows_end(&sink, fault == nil && count > 0)
	if fault == nil && count > 0 && end != nil {
		fault = end
	}
	// Records of one text share the header's keys, so a row with a key the header lacks is a header that repeats a name,
	// which a document of the text writes as its columns.
	written, _ := fault.(write.Error)
	refused, _ := written.(write.Refused)
	repeats := refused.why == .Row_Keys && fault != nil
	if fault != nil || count == 0 {
		delete(text, allocator)
		return Rows{err = fault}, fault != nil && !repeats
	}
	return Rows{text = text}, true
}

@(private)
rows_start :: proc(s: ^Row_Sink, to: Spec, opts: write.Options, allocator: runtime.Allocator) -> write.Error {
	if s.to_json {
		json.writer_start(&s.json, opts, {}, allocator) or_return
		return json.token(&s.json, .Array)
	}
	o := opts
	o.framing = .Lines
	return dsv.writer_start(&s.dsv, to.(dsv.Spec), o, {}, allocator)
}

@(private)
rows_put :: proc(s: ^Row_Sink, doc: ^tape.Document, allocator: runtime.Allocator) -> write.Error {
	if s.to_json {
		return write.tokens_of(doc, tape.ROOT, &s.json, json.token, allocator)
	}
	return dsv.put(&s.dsv, doc)
}

// Ends the text, closing the array of JSON rows when `whole`.
@(private)
rows_end :: proc(s: ^Row_Sink, whole: bool) -> (text: []u8, err: write.Error) {
	if s.to_json {
		if whole {
			if err = json.token(&s.json, .Close); err != nil {
				_, _ = json.writer_end(&s.json)
				return nil, err
			}
		}
		return json.writer_end(&s.json)
	}
	return dsv.writer_end(&s.dsv)
}
