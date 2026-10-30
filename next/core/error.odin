package core

import "core:io"

// The error types of the layers that walk and build a text. `Fault` is the walk's error and `Document_Error` the
// value layer's, which holds a `Fault` by value in `inner`.

// The kinds of fault a walk raises, shared by every format. Each member's comment names the formats that raise it
// and the byte `at` names.
Fault_Kind :: enum u8 {
	None, // no fault
	Truncated, // json, dsv: the input ended inside a construct, at `len(src)`
	Bad_Char, // json, dsv: the first byte that cannot extend the construct, or that is not UTF-8
	Bad_Escape, // json: at the escape's letter, or a lone surrogate half at its backslash, dsv (TSV): at the backslash
	Bad_Number, // json: at the byte that breaks the number
	Too_Deep, // json: at the bracket past the depth limit
	Trailing, // json's `validate`: at the first byte after the document
	Bad_Structure, // dsv: well-formed text breaking a rule of the format's structure, at the construct's first byte
	Too_Wide, // json, dsv: the first byte of a token longer than `Token.n` holds
	No_Memory, // json (depth stack past `MAX_DEPTH`), dsv (header's keys): the walk's scratch allocation failed, no byte
	Bad_Option, // dsv: an option the spec does not take, found before any byte is read
}

// The kinds that name no byte of the text. Their `at` is 0.
AT_NO_BYTE :: bit_set[Fault_Kind]{.None, .No_Memory, .Bad_Option}

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
	.Bad_Option    = {"bad_option", "An option the format does not take"},
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
// line and a lone CR is a byte of the line. The column counts bytes. `byte_at` may be `len(src)`, and a larger value
// is clamped to it. When `byte_at` is before `lines.at`, the count restarts at byte 0. A nil `lines` counts from byte
// 0 for this call only.
locate :: proc "contextless" (src: []u8, byte_at: u64, lines: ^Lines = nil) -> (line, col: u64) {
	at := min(byte_at, u64(len(src)))
	fresh: Lines
	l := lines if lines != nil else &fresh
	if at < l.at {
		l^ = {}
	}
	for i in l.at ..< at {
		if src[i] == '\n' {
			l.line += 1
			l.line_lo = i + 1
		}
	}
	l.at = at
	return l.line + 1, at - l.line_lo + 1
}

@(private)
write_position :: proc(w: io.Writer, src: []u8, at: u64, lines: ^Lines) -> io.Error {
	fresh: Lines
	line, col := locate(src, at, lines if lines != nil else &fresh)
	io.write_u64(w, line) or_return
	io.write_byte(w, ':') or_return
	io.write_u64(w, col) or_return
	io.write_string(w, ": ") or_return
	return nil
}

// Writes `line:col: message` for `f` in `src`, or the message alone when `f.kind` is in `AT_NO_BYTE`. `lines` is the
// count a previous fault in offset order left, or nil to count from byte 0.
render_fault :: proc(w: io.Writer, src: []u8, f: Fault, lines: ^Lines = nil) -> io.Error {
	if f.kind not_in AT_NO_BYTE {
		write_position(w, src, f.at, lines) or_return
	}
	_, err := io.write_string(w, rule_of(f).message)
	return err
}

// The value layer's error kinds. `Document_Error.inner` holds the walk's `Fault` by value for `.Walk`, so a syntax
// fault met while building a document renders as the document error and its cause.
Document_Error_Kind :: enum u8 {
	None,
	Walk, // the walk's fault, in `inner`
	Duplicate_Key, // `.Refuse` met a key that repeats one of its object's, at the second key's first byte
	No_Memory, // an allocation the document or the edit list owns was refused, at no byte
	Bad_Index, // an edit names no node it may change: no such node, a key of a member, the root, a table's record
	Bad_Position, // an insert position is past the container's length
	Wrong_Container, // the container requires the other insert form: a key for a member, none for an element
	Bad_Value, // a recorded text is not exactly one value of the document's format and spec
	Bad_Key, // a recorded key text is not exactly one key of the document's format and spec
	Bad_Fact, // a recorded fact body does not have its role's shape
	Bad_Width, // an edit would leave a delimited text a record the table cannot read
	Conflicting_Edits, // two edits of one node, or an edit inside what another replaces or removes
	Bad_Result, // a committed text does not read, the walk's fault in `inner`
}

// The document error kinds that name no byte of the text. Their `at` is not read.
DOCUMENT_AT_NO_BYTE :: bit_set[Document_Error_Kind]{.None, .No_Memory, .Bad_Index, .Bad_Position, .Wrong_Container, .Bad_Value, .Bad_Key, .Bad_Fact, .Bad_Width, .Bad_Result}

// A value layer error. `at` is the byte `kind` names: the walk's fault byte for `.Walk`, the first byte of the
// repeated key for `.Duplicate_Key`. `inner` is the walk's fault, set for `.Walk`.
Document_Error :: struct {
	kind:  Document_Error_Kind,
	at:    u64,
	inner: Fault,
}

@(rodata)
DOCUMENT_KIND_RULES := [Document_Error_Kind]Rule {
	.None              = {"none", "No error"},
	.Walk              = {"walk", "Input does not parse"},
	.Duplicate_Key     = {"duplicate_key", "Duplicate key"},
	.No_Memory         = {"no_memory", "Out of memory"},
	.Bad_Index         = {"bad_index", "The node takes no such edit"},
	.Bad_Position      = {"bad_position", "Insert position is past the container"},
	.Wrong_Container   = {"wrong_container", "The container takes the other insert form"},
	.Bad_Value         = {"bad_value", "Not one value of the format"},
	.Bad_Key           = {"bad_key", "Not one key of the format"},
	.Bad_Fact          = {"bad_fact", "Not a fact of the role's shape"},
	.Bad_Width         = {"bad_width", "The edit would break the table's width"},
	.Conflicting_Edits = {"conflicting_edits", "Edits conflict"},
	.Bad_Result        = {"bad_result", "The edited text does not read"},
}

// Writes `e`'s code: `document.` then the kind's code, as in `document.walk` or `document.duplicate_key`. The
// `write_code` overload below exposes it beside the fault's code.
write_document_code :: proc(w: io.Writer, e: Document_Error) -> io.Error {
	io.write_string(w, "document.") or_return
	_, err := io.write_string(w, DOCUMENT_KIND_RULES[e.kind].code)
	return err
}

// Writes `line:col: message` for `e` in `src`, and for `.Walk` also `  caused by line:col: message` for `e.inner`.
// `lines` is as in `render_fault`. Errors from the edit list other than a conflict name no byte, since they describe
// a node, a recorded text or a position rather than a place in `src`.
render_document :: proc(w: io.Writer, src: []u8, e: Document_Error, lines: ^Lines = nil) -> io.Error {
	// No position is written when `e.kind` is in `DOCUMENT_AT_NO_BYTE`, or when `e.kind` is `.Walk` and
	// `e.inner.kind` names no byte, as a bad option is found before any byte is read.
	no_byte := e.kind in DOCUMENT_AT_NO_BYTE || (e.kind == .Walk && e.inner.kind in AT_NO_BYTE)
	if !no_byte {
		write_position(w, src, e.at, lines) or_return
	}
	io.write_string(w, DOCUMENT_KIND_RULES[e.kind].message) or_return
	if e.kind == .Walk && e.inner.kind != .None {
		io.write_string(w, "\n  caused by ") or_return
		render_fault(w, src, e.inner, lines) or_return
	}
	return nil
}

// `write_code` writes a fault's or a document error's code, `render` writes its rendered line.
write_code :: proc {write_fault_code, write_document_code}
render :: proc {render_fault, render_document}
