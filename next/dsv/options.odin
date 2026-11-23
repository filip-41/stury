package dsv

import "stury:lib/core/tape"

// The options of a pass: `Dsv_Options` with the delimiter resolved, the bytes a delimiter or a comment byte may not be,
// and the defaults that a pass instance folds.

// `Dsv_Options` with the delimiter resolved, plus the read's tolerances and depth limit.
@(private)
Pass_Options :: struct {
	tolerate:  tape.Tolerances,
	delim:     u8,
	comment:   u8,
	no_header: bool,
	infer:     bool,
	limit:     u64,
}

// The depth a record's cells lie at in a text: the root array holds the record, which holds them. A read whose depth
// limit is lower reads no record.
@(private)
RECORD_DEPTH :: 2

// The options of a read that takes every default, as constants the pass folds.
@(private)
default_options :: #force_inline proc "contextless" ($S: Spec) -> Pass_Options {
	return {delim = spec_delimiter(S, 0), limit = max(u64)}
}

// The delimiter byte of `spec` when `delimiter` is 0: `,` for CSV and Plain and a tab for TSV.
@(private)
spec_delimiter :: #force_inline proc "contextless" (spec: Spec, delimiter: u8) -> u8 {
	return delimiter if delimiter != 0 else '\t' if spec == .Tsv else ','
}

// The pass options of `opts`, or the error for an option that spec `S` cannot read.
// A delimiter is refused when it is CR, LF, non-ASCII or, under CSV, a quote, and under TSV also a backslash or one of
// `t`, `n`, `r`, `0`. A comment byte is refused when it is CR, LF, the delimiter, non-ASCII or, under CSV, a quote, and
// under TSV also a backslash.
@(private)
pass_options :: #force_inline proc "contextless" ($S: Spec, opts: tape.Options) -> (p: Pass_Options, refused: tape.Error) {
	if refused = tape.options_refused(&FORMATS[S], opts); refused != nil {
		return
	}
	d, _ := opts.format.(tape.Dsv_Options)
	delim, c := spec_delimiter(S, d.delimiter), d.comment
	bad_delim := delim == '\r' || delim == '\n' || delim >= 0x80
	bad_comment := c != 0 && (c == '\r' || c == '\n' || c == delim || c >= 0x80)
	when S == .Csv {
		bad_delim ||= delim == '"'
		bad_comment ||= c == '"'
	} else when S == .Tsv {
		bad_delim ||= delim == '\\' || delim == 't' || delim == 'n' || delim == 'r' || delim == '0'
		bad_comment ||= c == '\\'
	}
	if bad_delim {
		return {}, tape.Bad_Option{"delimiter"}
	}
	if bad_comment {
		return {}, tape.Bad_Option{"comment"}
	}
	return {tolerate = opts.tolerate, delim = delim, comment = c, no_header = d.no_header, infer = d.infer, limit = u64(opts.budget.depth) if opts.budget.depth != 0 else tape.DEFAULT_DEPTH}, nil
}

// Whether `p` holds every default, so the pass runs the instance that folds them.
@(private)
is_default :: #force_inline proc "contextless" ($S: Spec, p: Pass_Options) -> bool {
	return p.tolerate == {} && p.delim == spec_delimiter(S, 0) && p.comment == 0 && !p.no_header && !p.infer && p.limit >= RECORD_DEPTH
}
