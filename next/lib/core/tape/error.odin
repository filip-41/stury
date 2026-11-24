package tape

import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"

// The `at` of an error that names no byte of the text.
NO_BYTE :: max(u64)

// A `Budget` limit that ran out.
Exceeded :: struct {
	at:   u64, // the byte the read was at, `NO_BYTE` for memory
	kind: Budget_Kind,
}

Fault_Kind :: spell.Fault_Kind

// Why and where a text failed to parse.
Fault :: struct {
	at:     u64,
	rules:  ^Rules,
	kind:   Fault_Kind,
	detail: u8, // index into `rules.details`, 0 for none
}

// A format's fault rules, in rodata. `details[d]` holds the code and message of detail `d`, and `details[0]` is unused.
Rules :: struct {
	format:  string,
	details: []Rule,
}

Rule :: struct {
	code:    string, // stable, for callers to match on
	message: string, // may change
}

// An option the read does not take, which it names.
Bad_Option :: struct {
	option: string,
}

// The error of a library call, one arm per cause.
Error :: union {
	Fault,
	runtime.Allocator_Error,
	Exceeded,
	Piece_Gap,
	Bad_Option,
}

@(private, rodata)
KIND_RULES := [Fault_Kind]Rule {
	.None          = {"none", "No fault"},
	.Truncated     = {"truncated", "Unfinished input"},
	.Bad_Char      = {"bad_char", "Unexpected character"},
	.Bad_Escape    = {"bad_escape", "Invalid escape"},
	.Bad_Number    = {"bad_number", "Invalid number"},
	.Too_Wide      = {"too_wide", "Token is longer than 4 GiB"},
	.Bad_Width     = {"bad_width", "Record width differs from the first record"},
	.Duplicate_Key = {"duplicate_key", "Duplicate key"},
}

@(private, rodata)
BUDGET_MESSAGES := [Budget_Kind]string {
	.Depth     = "Exceeds the depth limit",
	.Nodes     = "Exceeds the node limit",
	.Memory    = "Exceeds the memory limit",
	.Steps     = "Exceeds the step limit",
	.Expansion = "Exceeds the expansion limit",
}

// The rule of fault `f`: its format's detail, or else its kind's.
fault_rule :: proc "contextless" (f: Fault) -> Rule {
	if f.detail != 0 && f.rules != nil && int(f.detail) < len(f.rules.details) {
		return f.rules.details[f.detail]
	}
	return KIND_RULES[f.kind]
}

// Writes the message of `err`, an error of a read of `src`, a text of `format`, into `buf` and returns it, cut to
// `len(buf)` bytes. An error that names a byte starts with its line and column, both from 1, where a line ends at LF
// and a column counts bytes, or in a `.Binary` format with `byte` and its offset, from 0, as a binary text has no
// lines. Nil gives an empty message.
error_message :: proc "contextless" (buf: []u8, err: Error, src: []u8, format: ^Format = nil) -> string {
	m := Message{buf = buf}
	binary := format != nil && .Binary in format.caps
	switch e in err {
	case Fault:
		message_place(&m, src, e.at, binary)
		r := fault_rule(e)
		message_text(&m, r.message)
		if e.at < u64(len(src)) && (r.code == "control_char" || r.code == "invalid_utf8") {
			message_text(&m, " U+00" if r.code == "control_char" else " byte 0x")
			hex := "0123456789ABCDEF"
			b := src[e.at]
			message_text(&m, hex[b >> 4:][:1])
			message_text(&m, hex[b & 15:][:1])
		}
	case Exceeded:
		if e.at != NO_BYTE {
			message_place(&m, src, e.at, binary)
		}
		message_text(&m, BUDGET_MESSAGES[e.kind])
	case runtime.Allocator_Error:
		message_text(&m, "Out of memory")
	case Piece_Gap:
		message_text(&m, "The window holds bytes ")
		message_number(&m, e.from)
		message_text(&m, " to ")
		message_number(&m, e.to)
		message_text(&m, ", the read needs ")
		message_number(&m, e.keep)
		message_text(&m, " to ")
		message_number(&m, e.at)
	case Bad_Option:
		message_text(&m, "Option not taken: ")
		message_text(&m, e.option)
	}
	return string(m.buf[:m.n])
}

@(private)
Message :: struct {
	buf: []u8,
	n:   int,
}

@(private)
message_text :: proc "contextless" (m: ^Message, s: string) {
	k := copy(m.buf[m.n:], s)
	m.n += k
}

@(private)
message_number :: proc "contextless" (m: ^Message, v: u64) {
	digits: [20]u8
	i := len(digits)
	for v := v; ; v /= 10 {
		i -= 1
		digits[i] = '0' + u8(v % 10)
		if v < 10 {
			break
		}
	}
	message_text(m, string(digits[i:]))
}

// Writes `line:col: ` of byte `at` of `src`, clamped to its length, or of a `binary` text `byte at: `.
@(private)
message_place :: proc "contextless" (m: ^Message, src: []u8, at: u64, binary: bool) {
	if binary {
		message_text(m, "byte ")
		message_number(m, min(at, u64(len(src))))
		message_text(m, ": ")
		return
	}
	at := int(min(at, u64(len(src))))
	head := src[:at]
	message_number(m, u64(kernel.count_byte(head, '\n') + 1))
	message_text(m, ":")
	message_number(m, u64(at - (kernel.last_index_byte(head, '\n') + 1) + 1))
	message_text(m, ": ")
}
