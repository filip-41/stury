package dsv

import "stury:lib/core/tape"

// `dsv.reads`, which gives a caller that picks the format at run time the reads and records of a delimited format, and
// the byte where a record closes.

// The id of the first spec, which the others follow.
@(private)
FIRST_ID :: tape.Format_Id(4)

// The reads of `spec`, for a caller that picks the format at run time, to use with the handle `as` returns. Nil for a
// `spec` out of range.
reads :: proc "contextless" (spec: Spec) -> ^tape.Reads {
	return tape.format_reads(Spec, FIRST_ID, validate, build, find, scan, Records, records_open, records_validate, records_find, records_scan) if spec <= max(Spec) else nil
}

// The spec of a delimited format handle.
@(private)
spec_of :: #force_inline proc "contextless" (f: ^tape.Format) -> Spec {
	return Spec(f.id - FIRST_ID)
}

@(private)
close_csv :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (u64, bool) {return close_end(doc, at, .Csv)}

@(private)
close_tsv :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (u64, bool) {return close_end(doc, at, .Tsv)}

@(private)
close_plain :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (u64, bool) {return close_end(doc, at, .Plain)}

// The byte just past the line end of record `at`, CR LF included, or past its last cell at the text's end. A record
// kept whole ends past its last cell. One a path read kept only part of is framed from its first byte as the walk frames
// it, so a quote that opens no quoted cell does not hide a line end. The root ends at `root_close`. False for a record of a `.Held` document, which holds
// no byte between its nodes.
@(private)
close_end :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index, $S: Spec) -> (u64, bool) #no_bounds_check {
	if at == tape.ROOT {
		return doc.root_close, true
	}
	if .Held in doc.flags {
		return 0, false
	}
	src := doc.src
	node := doc.nodes[at]
	p: u64
	if node.spelling & tape.CONTAINER_PARTIAL == 0 && node.n > 1 {
		last := doc.nodes[at + tape.Node_Index(node.n) - 1]
		_, tail := quotes(src, last)
		p = last.lo + u64(last.n) + u64(tail)
	} else {
		delim := spec_delimiter(S, 0)
		if doc.ext != nil {
			if ext, tabular := &doc.ext.format.(tape.Tabular_Ext); tabular {
				delim = spec_delimiter(S, ext.options.delimiter)
			}
		}
		return u64(min(scan_record(src, int(node.lo), 0, S, delim).line_end + 1, len(src))), true
	}
	if p < u64(len(src)) && src[p] == '\r' {
		p += 1
	}
	if p < u64(len(src)) && src[p] == '\n' {
		p += 1
	}
	return p, true
}
