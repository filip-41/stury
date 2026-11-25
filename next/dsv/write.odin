package dsv

import "base:runtime"
import "core:io"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// The writes of a document as a delimited text, which `lib/ops/write` spells by the cell rules of `spec`.

Write_Options :: write.Options
Write_Error :: write.Error
Token_Kind :: write.Token_Kind
Record_Framing :: write.Record_Framing
Refused :: write.Refused
Refusal :: write.Refusal

// Writes value `opts.node` of `doc`, a document of any format, as a text of `spec`, a record a line, in a buffer from
// `allocator` that the caller owns. The value is a table a delimited read built, or an array of objects, the first
// one's keys the header and each other one holding the same keys, or of arrays of one width, with `no_header`, which
// also writes an array of objects with no header line. An array of arrays is refused without it: it has no keys, so
// any header would read back as the first record, and the table as objects. A cell
// is a scalar: null an empty cell, a string its text, a byte string its payload's base64, quoted (CSV) or escaped (TSV) where it must be, a number or
// boolean its text, which reads back as text unless the options `infer`. `opts.format` holds the `Dsv_Options`, by
// default those `doc` was read with when it is delimited. Comments on the table and on its records are written as
// comment lines under a comment byte. Returns the kinds of the facts `doc` holds that the text does not.
write :: proc(doc: ^tape.Document, spec := Spec.Csv, opts := Write_Options{}, allocator := context.allocator) -> (text: []u8, dropped: tape.Facts, err: Write_Error) {
	return write.to_buffer(doc, u8(spec), opts, allocator, write_out)
}

// `write` into `sink`, through a buffer of `write.SINK_BYTES` from `allocator`. A sink with no procedure is
// `Bad_Option{"sink"}`. On a refusal or a failed sink the sink may hold a prefix of the text.
write_to :: proc(sink: io.Writer, doc: ^tape.Document, spec := Spec.Csv, opts := Write_Options{}, allocator := context.allocator) -> (dropped: tape.Facts, err: Write_Error) {
	return write.to_sink(sink, doc, u8(spec), opts, allocator, write_out)
}

@(private)
write_out :: proc(out: ^write.Out, doc: ^tape.Document, wanted: u8, opts: Write_Options, allocator: runtime.Allocator) -> (tape.Facts, write.Error) {
	if wanted > u8(max(Spec)) {
		return {}, tape.Bad_Option{"spec"}
	}
	if opts.indent != 0 || opts.tab || opts.ascii || opts.framing != .None || opts.grow_header || len(opts.header) > 0 {
		opt := "indent" if opts.indent != 0 || opts.tab else "ascii" if opts.ascii else "framing" if opts.framing != .None else "header"
		return {}, tape.Bad_Option{opt}
	}
	spec := Spec(wanted)
	cells, d, verbatim, err := resolve_options(spec, opts, doc, allocator)
	if err != nil {
		return {}, err
	}
	return write.table(out, doc, &FORMATS[spec], cells, d, verbatim, opts, allocator)
}

// Validates `opts.format` for `spec`, inheriting options from `doc` when it is a delimited document, and resolves its
// delimiter and cell rules.
@(private)
resolve_options :: proc(spec: Spec, opts: Write_Options, doc: ^tape.Document, allocator: runtime.Allocator) -> (cells: write.Cells, d: tape.Dsv_Options, verbatim: bool, err: Write_Error) {
	given: bool
	d, given = opts.format.(tape.Dsv_Options)
	if !given && opts.format != nil {
		return {}, {}, false, tape.Bad_Option{"format"}
	}
	read: Maybe(tape.Dsv_Options)
	if doc != nil && doc.ext != nil {
		if ext, tabular := doc.ext.format.(tape.Tabular_Ext); tabular {
			if doc.format == &FORMATS[spec] {
				read = ext.options
			}
			if !given {
				d = ext.options
				if doc.format.options == .Dsv && doc.format != &FORMATS[spec] {
					d.delimiter = 0
				}
			}
		}
	}
	// A read refuses the options a write cannot use either: a delimiter or comment byte the spec cannot frame.
	// Validate directly through `pass_options` so write-only binaries do not link the DSV parser walks.
	refused: tape.Error
	switch spec {
	case .Csv:
		_, refused = pass_options(.Csv, {format = d})
	case .Tsv:
		_, refused = pass_options(.Tsv, {format = d})
	case .Plain:
		_, refused = pass_options(.Plain, {format = d})
	}
	if bad, ok := refused.(tape.Bad_Option); ok {
		return {}, {}, false, bad
	}
	d.delimiter = spec_delimiter(spec, d.delimiter)
	// A text of `spec` written under the options it was read with keeps the cells it read plainly.
	if r, ok := read.?; ok {
		r.delimiter, r.crlf = spec_delimiter(spec, r.delimiter), d.crlf
		verbatim = r == d
	}
	table_cells := [Spec]write.Cells{.Csv = .Quoted, .Tsv = .Escaped, .Plain = .Bare}
	return table_cells[spec], d, verbatim, nil
}
