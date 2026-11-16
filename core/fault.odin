package core

import "core:io"
import spell "./spell"
import kernel "./kernel"

// A walk's fault: its kinds, the format's rules that name it, and its line and column in the text.

// The kinds of fault a walk raises, from `core/spell`, whose readers return them.
Fault_Kind :: spell.Fault_Kind

// The kinds that name no byte of the text. Their `at` is 0.
AT_NO_BYTE :: bit_set[Fault_Kind]{.None, .No_Memory, .Bad_Option}

// A fault's judgement reads no byte more than this past the byte it names, in any format: a lone surrogate's escape,
// judged by the escape after it, is 12. So a fault further than this from a text's cut is the fault of the whole text.
FAULT_REACH :: 16

// A walk's fault. `at` is the byte the kind names, `detail` is the format's rule within the kind (0 for none), and
// `rules` points at the format's table of those rules.
Fault :: struct {
	at:     u64,
	rules:  ^Rules,
	kind:   Fault_Kind,
	detail: u8,
}

// A format's rules, stored in rodata. `format` is the prefix of each of its codes, and `details[d]` holds the code
// and message for `Detail` `d` (`details[0]` is for no detail). Core renders a fault from this table without calling
// into the format.
Rules :: struct {
	format:  string,
	details: []Rule,
}

// `code` is stable across releases and a caller may match on it. `message` may change.
@(private)
Rule :: struct {
	code:    string,
	message: string,
}

@(private, rodata)
KIND_RULES := [Fault_Kind]Rule {
	.None          = {"none", "No fault"},
	.Truncated     = {"truncated", "Unfinished input"},
	.Bad_Char      = {"bad_char", "Unexpected character"},
	.Bad_Escape    = {"bad_escape", "Invalid escape"},
	.Bad_Number    = {"bad_number", "Invalid number"},
	.Too_Deep      = {"too_deep", "Exceeds the depth limit"},
	.Too_Wide      = {"too_wide", "Token is longer than 4 GiB"},
	.No_Memory     = {"no_memory", "Out of memory"},
	.Bad_Option    = {"bad_option", "Invalid option"},
	.Bad_Width     = {"bad_width", "Record width differs from the first record"},
	.Duplicate_Key = {"duplicate_key", "Duplicate key"},
}

// Returns the `Rule` for `f`: `f.rules.details[f.detail]` when `detail` is nonzero, `rules` is set and the index is
// in range, else `KIND_RULES[f.kind]`.
rule_of :: proc "contextless" (f: Fault) -> Rule {
	if f.detail != 0 && f.rules != nil && int(f.detail) < len(f.rules.details) {
		return f.rules.details[f.detail]
	}
	return KIND_RULES[f.kind]
}

// Writes the fault's code to `w`: `f.rules.format`, a dot when `rules` is set, then `rule_of(f).code`, as in
// `json.literal` or `dsv.bad_char`. Returns the writer's error.
@(private)
write_fault_code :: proc(w: io.Writer, f: Fault) -> io.Error {
	if f.rules != nil {
		io.write_string(w, f.rules.format) or_return
		io.write_byte(w, '.') or_return
	}
	_, err := io.write_string(w, rule_of(f).code)
	return err
}

// A count of a text's lines up to byte `at`, kept between faults met in offset order so that `locate` scans each byte
// once. The zero value starts at the text's first byte.
Lines :: struct {
	at:      u64, // the byte counted up to
	line:    u64, // its line, from 0
	line_lo: u64, // that line's first byte
}

// Returns the line and column of byte `byte_at` in `src`, both counted from 1. A line ends at LF, so CR LF ends one
// line and a lone CR is a byte of the line. The column counts bytes. `byte_at` may be `len(src)`, and a larger value is
// clamped to it. When `byte_at` is before `lines.at`, the count goes back over the bytes between. A nil `lines` counts
// from byte 0 for this call only.
locate :: proc "contextless" (src: []u8, byte_at: u64, lines: ^Lines = nil) -> (line, col: u64) {
	at := min(byte_at, u64(len(src)))
	fresh: Lines
	l := lines if lines != nil else &fresh
	if at < l.at {
		// Back over the bytes between, so a text read out of order costs the distance and not the text.
		l.line -= u64(kernel.count_byte(src[at:l.at], '\n'))
		l.line_lo = u64(kernel.last_index_byte(src[:at], '\n') + 1)
		l.at = at
	}
	ahead := src[l.at:at]
	if n := kernel.count_byte(ahead, '\n'); n > 0 {
		l.line += u64(n)
		l.line_lo = l.at + u64(kernel.last_index_byte(ahead, '\n') + 1)
	}
	l.at = at
	return l.line + 1, at - l.line_lo + 1
}

// Writes `line:col: ` of byte `at` in `src`, or `at byte N: ` with no `src`, which has no lines to count.
@(private)
write_position :: proc(w: io.Writer, src: []u8, at: u64, lines: ^Lines) -> io.Error {
	if src == nil && at > 0 {
		io.write_string(w, "at byte ") or_return
		io.write_u64(w, at) or_return
		_, err := io.write_string(w, ": ")
		return err
	}
	line, col := locate(src, at, lines)
	io.write_u64(w, line) or_return
	io.write_byte(w, ':') or_return
	io.write_u64(w, col) or_return
	io.write_string(w, ": ") or_return
	return nil
}

// Writes `line:col: message` for `f` in `src`, or the message alone when `f.kind` is in `AT_NO_BYTE`. `lines` is the
// count a previous fault in offset order left, or nil to count from byte 0.
@(private)
render_fault :: proc(w: io.Writer, src: []u8, f: Fault, lines: ^Lines = nil) -> io.Error {
	if f.kind not_in AT_NO_BYTE {
		write_position(w, src, f.at, lines) or_return
	}
	return write_fault_message(w, src, f)
}

// Writes `rule_of(f).message`, then for the codes `control_char` and `invalid_utf8` of any format the byte of `src` the
// fault is at, as in `Unescaped control character U+0009` or `Invalid UTF-8 byte 0xFF`.
write_fault_message :: proc(w: io.Writer, src: []u8, f: Fault) -> io.Error {
	r := rule_of(f)
	io.write_string(w, r.message) or_return
	if f.at >= u64(len(src)) {
		return nil
	}
	switch r.code {
	case "control_char":
		io.write_string(w, " U+00") or_return
	case "invalid_utf8":
		io.write_string(w, " byte 0x") or_return
	case:
		return nil
	}
	digits := spell.hex_text(u64(src[f.at]), 2, true)
	_, err := io.write(w, digits[:])
	return err
}
