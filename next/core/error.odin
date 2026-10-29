package core

import "core:io"

// The errors of every layer live here, one type per layer, each with its own kinds. A layer's error holds the error
// beneath it by value, one level. The walk's is `Fault`.

// What went wrong in a walk, the same for every format, and where. Each member names the formats that raise it.
Fault_Kind :: enum u8 {
	None, // no fault
	Truncated, // json, dsv: the input ended inside a construct, at `len(src)`
	Bad_Char, // json, dsv: the first byte that cannot extend the construct, or that is not UTF-8
	Bad_Escape, // json: at the escape's letter, or a lone surrogate half at its backslash, dsv (TSV): at the backslash
	Bad_Number, // json: at the byte that breaks the number
	Too_Deep, // json: at the bracket past the depth limit
	Trailing, // json's `validate`: at the first byte after the document
	Bad_Structure, // dsv: well-formed text breaking a rule of the format's structure, at the construct's first byte
	Too_Wide, // json, dsv: a token longer than `Token.n` holds, at its first byte
	No_Memory, // json (a depth stack past `MAX_DEPTH`), dsv (the header's keys): the walk's scratch could not be allocated, at no byte
}

// The kinds that name no byte of the text: `at` is 0 and says nothing.
AT_NO_BYTE :: bit_set[Fault_Kind]{.None, .No_Memory}

// `at` is the byte the kind names. `detail` tells a format's own rules apart within a kind, 0 for none, and `rules`
// is that format's table, which names and words them.
Fault :: struct {
	at:     u64,
	rules:  ^Rules,
	kind:   Fault_Kind,
	detail: u8,
}

// A format's rules, in its rodata: its name, which starts each of its codes, and per value of its `Detail` the rule's
// code and message (`details[0]` stands for none). Core names and words any format's fault from it, with no call into
// the format.
Rules :: struct {
	format:  string,
	details: []Rule,
}

// A code stays the same from release to release, so a caller may match on it. A message may change.
Rule :: struct {
	code:    string,
	message: string,
}

@(rodata)
KIND_RULES := [Fault_Kind]Rule {
	.None          = {"none", "No fault"},
	.Truncated     = {"truncated", "Unfinished input"},
	.Bad_Char      = {"bad_char", "Unexpected character"},
	.Bad_Escape    = {"bad_escape", "Invalid escape"},
	.Bad_Number    = {"bad_number", "Invalid number"},
	.Too_Deep      = {"too_deep", "Exceeds depth limit for parsing"},
	.Trailing      = {"trailing", "Unexpected text after the value"},
	.Bad_Structure = {"bad_structure", "Text breaks a rule of its format"},
	.Too_Wide      = {"too_wide", "Token is longer than 4 GiB"},
	.No_Memory     = {"no_memory", "Out of memory"},
}

// The rule a fault breaks: its format's rule for its detail, or its kind's.
rule_of :: proc "contextless" (f: Fault) -> Rule {
	if f.detail != 0 && f.rules != nil && int(f.detail) < len(f.rules.details) {
		return f.rules.details[f.detail]
	}
	return KIND_RULES[f.kind]
}

// Writes a fault's code: its format, a dot, and its rule's code, as `json.literal` or `dsv.bad_char`.
write_code :: proc(w: io.Writer, f: Fault) -> io.Error {
	if f.rules != nil {
		io.write_string(w, f.rules.format) or_return
		io.write_byte(w, '.') or_return
	}
	_, err := io.write_string(w, rule_of(f).code)
	return err
}

// A count of a text's lines up to a byte, which goes on from there for the next fault, so that the positions of many
// faults met in offset order take one pass over the text. Its zero value stands at the text's first byte.
Lines :: struct {
	at:      u64, // the byte counted up to
	line:    u64, // its line, from 0
	line_lo: u64, // that line's first byte
}

// The line and column of byte `byte_at` of `src`, both from 1. A line ends at LF, so CR LF is one line end and a lone CR
// is a byte of its line. The column counts bytes. `byte_at` may be `len(src)`. A byte before the count's starts it again
// from the text's first byte.
locate :: proc "contextless" (src: []u8, byte_at: u64, lines: ^Lines) -> (line, col: u64) {
	at := min(byte_at, u64(len(src)))
	if at < lines.at {
		lines^ = {}
	}
	for i in lines.at ..< at {
		if src[i] == '\n' {
			lines.line += 1
			lines.line_lo = i + 1
		}
	}
	lines.at = at
	return lines.line + 1, at - lines.line_lo + 1
}

// Writes `line:col: message` for a fault in `src`, or the message alone for a kind at no byte. `lines` is the count
// the last fault rendered in offset order left, or nil for a fault on its own.
render :: proc(w: io.Writer, src: []u8, f: Fault, lines: ^Lines = nil) -> io.Error {
	if f.kind not_in AT_NO_BYTE {
		fresh: Lines
		line, col := locate(src, f.at, lines if lines != nil else &fresh)
		io.write_u64(w, line) or_return
		io.write_byte(w, ':') or_return
		io.write_u64(w, col) or_return
		io.write_string(w, ": ") or_return
	}
	_, err := io.write_string(w, rule_of(f).message)
	return err
}
