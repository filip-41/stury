package core

import "base:runtime"
import "core:io"
import "core:reflect"
import "core:strings"
import spell "./spell"

// The error types of the layers that walk and build a text. `Fault` is the walk's error and `Document_Error` the
// value layer's, which holds a `Fault` by value in `inner`.

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
// line and a lone CR is a byte of the line. The column counts bytes. `byte_at` may be `len(src)`, and a larger value
// is clamped to it. When `byte_at` is before `lines.at`, the count goes back over the bytes between. A nil `lines` counts from byte
// 0 for this call only.
locate :: proc "contextless" (src: []u8, byte_at: u64, lines: ^Lines = nil) -> (line, col: u64) {
	at := min(byte_at, u64(len(src)))
	fresh: Lines
	l := lines if lines != nil else &fresh
	if at < l.at {
		// Back over the bytes between, so a text read out of order costs the distance and not the text.
		for i in at ..< l.at {
			if src[i] == '\n' {
				l.line -= 1
			}
		}
		l.line_lo = at
		for l.line_lo > 0 && src[l.line_lo - 1] != '\n' {
			l.line_lo -= 1
		}
		l.at = at
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
	hex := "0123456789ABCDEF"
	b := src[f.at]
	switch r.code {
	case "control_char":
		io.write_string(w, " U+00") or_return
	case "invalid_utf8":
		io.write_string(w, " byte 0x") or_return
	case:
		return nil
	}
	io.write_byte(w, hex[b >> 4]) or_return
	return io.write_byte(w, hex[b & 15])
}

// The value layer's error kinds. `Document_Error.inner` holds a `Fault` by value for `.Walk`, `.Bad_Value` and
// `.Bad_Result`, so the error renders with its cause. The last two name a byte of a text that is not the rendered
// source.
Document_Error_Kind :: enum u8 {
	None,
	Walk, // the walk's fault, in `inner`
	Duplicate_Key, // a build under `.Refuse` met a key that repeats one of its object's, at the second key's first byte, or a commit's named cell is one its record holds, at the header cell
	No_Memory, // an allocation the document or the edit list owns was refused, at no byte
	Bad_Index, // an edit names no node it may change: no such node, a key of a member, the root, a table's record
	Bad_Position, // an insert position is past the container's length
	Wrong_Container, // the container requires the other insert form: a key for a member, none for an element
	Bad_Value, // a recorded text is not exactly one value of the document's format and spec
	Bad_Fact, // a recorded fact body does not have its role's shape
	Bad_Width, // an edit would leave a delimited text a record the table cannot read
	Bad_Spec, // a commit asks for a spec of another format family, or one a delimited text cannot write
	Conflicting_Edits, // two edits of one node, or an edit inside what another replaces or removes, at the first byte of the node or span they share
	Bad_Result, // a committed text does not read, the walk's fault in `inner`
	Frozen, // the format does not let an edit touch the node, at no byte: `at` is the node, and `inner.rules` and `inner.detail` give the reason
}

// The document error kinds that name no byte of the text. Their `at` is not read.
@(private)
DOCUMENT_AT_NO_BYTE :: bit_set[Document_Error_Kind]{.None, .No_Memory, .Bad_Index, .Bad_Position, .Wrong_Container, .Bad_Value, .Bad_Fact, .Bad_Width, .Bad_Spec, .Bad_Result, .Frozen}

// Whether `e` names a byte of the source: its kind does, and for `.Walk` its fault does too, as a bad option is found
// before any byte is read.
@(private)
document_at_byte :: proc "contextless" (e: Document_Error) -> bool {
	return e.kind not_in DOCUMENT_AT_NO_BYTE && (e.kind != .Walk || e.inner.kind not_in AT_NO_BYTE)
}

// Moves the bytes of the source `e` names by `by`, for an error found in a text that starts `by` bytes in.
move_document_error :: proc(e: ^Document_Error, by: u64) {
	if document_at_byte(e^) {
		e.at += by
		if e.kind == .Walk {
			e.inner.at += by
		}
	}
}

// Why an edit is `.Bad_Index`, or for the cell reasons `.Bad_Value`, with `at` the position of the cell in a record.
Edit_Reason :: enum u8 {
	None,
	No_Document, // the edit list has no document
	No_Node, // the index is past the document's last node
	Fact_Node, // the node is a fact, which takes only fact edits
	Flat_Container, // the node is a flat text's container, whose members take the edit
	Root, // the root is not removed
	Key_Node, // a key is removed with its member and holds no facts
	Not_Fact_Role, // the role is a value's or a key's, not a fact's
	Not_Object, // a member is set in a node that is no object
	Not_Array, // an element is set in a node that is no array
	Not_Loaded, // the node is not loaded in a partial document
	No_Parent, // a path reaches no container to set its last step in
	Not_Scalar, // a flat text holds a scalar, and the value is an array or an object
	Empty_Text, // a flat format cannot tell the empty text from null
	Starts_With_Mark, // the value would start the text with a byte order mark
	Reads_Back_Typed, // the document reads kinds from the text, and the format has no quotes to keep the value a string
	No_Spelling, // the format has no spelling for the value
}

// A value layer error. `at` is the byte `kind` names: the walk's fault byte for `.Walk`, the first byte of the
// repeated key for `.Duplicate_Key`, of the shared node or span for `.Conflicting_Edits`. `inner` is the fault, set for
// `.Walk`, `.Bad_Value` and `.Bad_Result`, whose `inner.at` for the last two is a byte of the recorded text or of the
// commit's output, not of the source. A `.Bad_Index` says why in `reason`.
Document_Error :: struct {
	kind:   Document_Error_Kind,
	reason: Edit_Reason,
	at:     u64,
	inner:  Fault,
}

@(private, rodata)
DOCUMENT_KIND_RULES := [Document_Error_Kind]Rule {
	.None              = {"none", "No error"},
	.Walk              = {"walk", "Input does not parse"},
	.Duplicate_Key     = {"duplicate_key", "Duplicate key"},
	.No_Memory         = {"no_memory", "Out of memory"},
	.Bad_Index         = {"bad_index", "The node takes no such edit"},
	.Bad_Position      = {"bad_position", "Insert position is past the container"},
	.Wrong_Container   = {"wrong_container", "The container takes the other insert form"},
	.Bad_Value         = {"bad_value", "Not one value of the format"},
	.Bad_Fact          = {"bad_fact", "Not a fact of the role's shape"},
	.Bad_Width         = {"bad_width", "The edit would break the table's width"},
	.Bad_Spec          = {"bad_spec", "The commit cannot write that spec"},
	.Conflicting_Edits = {"conflicting_edits", "Edits conflict"},
	.Bad_Result        = {"bad_result", "The edited text does not read"},
	.Frozen            = {"frozen", "The node cannot be edited"},
}

@(private, rodata)
EDIT_REASONS := [Edit_Reason]string {
	.None          = "",
	.No_Document   = "the edit list has no document",
	.No_Node       = "no node has that index",
	.Fact_Node     = "the node is a comment, which takes a fact edit",
	.Flat_Container    = "a flat text's container is edited through its members",
	.Root          = "the root is set, not removed",
	.Key_Node      = "a key is removed with its member and holds no comment",
	.Not_Fact_Role = "the role is no comment's",
	.Not_Object    = "the node is no object",
	.Not_Array     = "the node is no array",
	.Not_Loaded    = "the node is not loaded in this partial document",
	.No_Parent     = "the path reaches no container to set its last step in",
	.Not_Scalar = "a flat text holds a text, a number, true, false or null",
	.Empty_Text     = "a TSV text cannot hold the empty text",
	.Starts_With_Mark       = "the value would start the text with a byte order mark",
	.Reads_Back_Typed  = "a read with kinds inferred would read the value back as a number, true or false, and the format has no quotes",
	.No_Spelling = "the format has no spelling for the value",
}

// Writes `e`'s code: `document.` then the kind's code, as in `document.walk` or `document.duplicate_key`. The
// `write_code` overload below exposes it beside the fault's code.
@(private)
write_document_code :: proc(w: io.Writer, e: Document_Error) -> io.Error {return write_coded(w, "document.", DOCUMENT_KIND_RULES[e.kind].code)}

// Writes `prefix` then `code`.
@(private)
write_coded :: proc(w: io.Writer, prefix, code: string) -> io.Error {
	io.write_string(w, prefix) or_return
	_, err := io.write_string(w, code)
	return err
}

// Writes `line:col: message` for `e` in `src`. `.Walk` writes its fault. `.Bad_Value` and `.Bad_Result` name their
// fault and its offset in the recorded text or the commit's output, which is not `src`, and `.Bad_Index` its reason.
// `lines` is as in `render_fault`. Errors from the edit list other than a conflict name no byte, since they describe a
// node, a recorded text or a position rather than a place in `src`.
@(private)
render_document :: proc(w: io.Writer, src: []u8, e: Document_Error, lines: ^Lines = nil) -> io.Error {
	if e.kind == .Walk {
		return render_fault(w, src, e.inner, lines)
	}
	if document_at_byte(e) {
		write_position(w, src, e.at, lines) or_return
	}
	io.write_string(w, DOCUMENT_KIND_RULES[e.kind].message) or_return
	if e.reason != .None {
		io.write_string(w, ": ") or_return
		io.write_string(w, EDIT_REASONS[e.reason]) or_return
	}
	if e.kind == .Frozen {
		if e.inner.rules == nil || int(e.inner.detail) >= len(e.inner.rules.details) {
			return nil
		}
		io.write_string(w, ": ") or_return
		_, err := io.write_string(w, e.inner.rules.details[e.inner.detail].message)
		return err
	}
	if e.inner.kind == .None {
		return nil
	}
	io.write_string(w, ": ") or_return
	io.write_string(w, rule_of(e.inner).message) or_return
	io.write_string(w, " at offset ") or_return
	io.write_u64(w, e.inner.at) or_return
	_, err := io.write_string(w, " of the new text" if e.kind == .Bad_Value else " of the edited text")
	return err
}

// The path layer's error kinds. A value a path does not reach is an `Answer`'s outcome, not an error.
Path_Error_Kind :: enum u8 {
	None,
	Bad_Path, // the path's text does not parse, at the byte of that text
	Over_Capacity, // a read past `MAX_PATHS` paths, a path past `MAX_STEPS` steps or of `MAX_STEPS` with a `Descend`, at no byte
	No_Memory, // an allocation the read owns was refused, at no byte
	Walk, // the walk's fault, in `inner`
	Duplicate_Key, // a read under `.Refuse` met a key that repeats one of its object's, at the second key's first byte
	Unsupported, // a query of a partial document, or a read through a handle with no format, at no byte
}

// Why a path is `.Bad_Path`.
Path_Reason :: enum u8 {
	None,
	No_Dot, // jq path text does not start with `.`
	Pointer_Text, // jq path text starts with `/`, as a JSON Pointer does
	No_Slash, // a JSON Pointer does not start with `/`
	Bad_Name, // a `.` is followed by no name, quoted name or `[`
	Bad_Bracket, // a `[` holds no quoted name, index or slice
	Unclosed_Bracket, // a `[` is not closed by `]`
	Unclosed_Quote, // a quoted name is not closed
	Unclosed_Paren, // a `first(` or `limit(` is not closed
	Bad_Escape, // a quoted name holds what is no JSON string escape
	Invalid_Utf8, // an ill-formed UTF-8 sequence
	Bad_Tilde, // a pointer's `~` is not followed by `0` or `1`
	Bad_Limit, // a `limit` count is negative or no integer
	No_Semicolon, // a `limit(N` is not followed by `;`
	Trailing, // text past the end of the path
	Two_Descends, // a path holds a second `Descend`
	Unset_Step, // a path holds a zero `Step`
}

// A path layer error. `at` is the byte `kind` names: a byte of the path's text for `.Bad_Path`, and the walk's fault
// byte for `.Walk`. `path` is the number in the read of the path a `.Bad_Path` or an `.Over_Capacity` of steps names, 0
// for the other kinds. A `.Bad_Path` says why in `reason`, and one from `parse_path` or `parse_pointer` holds the text
// it read in `text`, which lives as long as the caller's text.
Path_Error :: struct {
	kind:   Path_Error_Kind,
	reason: Path_Reason,
	path:   u32,
	at:     u64,
	text:   string,
	inner:  Fault,
}

@(private, rodata)
PATH_KIND_RULES := [Path_Error_Kind]Rule {
	.None          = {"none", "No error"},
	.Bad_Path      = {"bad_path", "Invalid path"},
	.Over_Capacity = {"over_capacity", "Read exceeds a fixed limit: MAX_PATHS paths or MAX_STEPS steps in a path"},
	.No_Memory     = {"no_memory", "Out of memory"},
	.Walk          = {"walk", "Input does not parse"},
	.Duplicate_Key = {"duplicate_key", "Duplicate key"},
	.Unsupported   = {"unsupported", "Read is not supported"},
}

@(private, rodata)
PATH_REASONS := [Path_Reason]string {
	.None             = "",
	.No_Dot           = "a path starts with `.`",
	.Pointer_Text     = "a path starts with `.`, and `parse_pointer` reads a JSON Pointer",
	.No_Slash         = "a JSON Pointer starts with `/`",
	.Bad_Name         = "`.` is followed by a name, a quoted name or `[`",
	.Bad_Bracket      = "`[` holds a quoted name, an index or a slice",
	.Unclosed_Bracket = "`[` is not closed",
	.Unclosed_Quote   = "the quoted name is not closed",
	.Unclosed_Paren   = "`(` is not closed",
	.Bad_Escape       = "not a JSON string escape",
	.Invalid_Utf8     = "ill-formed UTF-8",
	.Bad_Tilde        = "`~` is followed by `0` or `1`",
	.Bad_Limit        = "`limit` takes a count of 0 or more",
	.No_Semicolon     = "`limit(N; P)` takes a `;` after its count",
	.Trailing         = "text past the end of the path",
	.Two_Descends     = "a path holds one `..`",
	.Unset_Step       = "a step is unset",
}

// Returns the read error a build's error is.
path_error :: proc(e: Document_Error) -> Path_Error {
	#partial switch e.kind {
	case .None:
		return {}
	case .Walk:
		return {kind = .Walk, at = e.at, inner = e.inner}
	case .Duplicate_Key:
		return {kind = .Duplicate_Key, at = e.at}
	}
	return {kind = .No_Memory}
}

@(private)
write_path_code :: proc(w: io.Writer, e: Path_Error) -> io.Error {return write_coded(w, "path.", PATH_KIND_RULES[e.kind].code)}

// Writes `line:col: message` for `e`, the position in the path's text for a `.Bad_Path` that holds it and in `src` for
// a `.Duplicate_Key`. A `.Bad_Path` names its text and its reason. `.Walk` writes its fault. `lines` is as in
// `render_fault`.
@(private)
render_path :: proc(w: io.Writer, src: []u8, e: Path_Error, lines: ^Lines = nil) -> io.Error {
	#partial switch e.kind {
	case .Walk:
		return render_fault(w, src, e.inner, lines)
	case .Duplicate_Key:
		write_position(w, src, e.at, lines) or_return
	case .Bad_Path:
		if len(e.text) > 0 {
			write_position(w, transmute([]u8)e.text, e.at, nil) or_return
		}
		io.write_string(w, PATH_KIND_RULES[e.kind].message) or_return
		if len(e.text) > 0 {
			io.write_string(w, " \"") or_return
			write_shown(w, e.text) or_return
			io.write_byte(w, '"') or_return
		}
		if e.reason != .None {
			io.write_string(w, ": ") or_return
			io.write_string(w, PATH_REASONS[e.reason]) or_return
		}
		return nil
	}
	_, err := io.write_string(w, PATH_KIND_RULES[e.kind].message)
	return err
}

// How a typed read or write refuses. `.None` is no error. The kinds from `Invalid_Utf8` on are a write's, and none of them
// names a byte of a source.
Typed_Error_Kind :: enum u8 {
	None,
	Walk, // the walk's fault, in `inner`
	Wrong_Kind, // a value the target's type does not read
	Out_Of_Range, // a value past what the target holds, other than a number
	Not_A_Member, // a name or number no enum or union member has
	Wrong_Length, // a table's row holds more cells than its type, or a second record where one is read
	Missing_Field, // a `required` member is absent, the last step names it, or for a check `want.text` with the object's path
	Unknown_Field, // a key the type does not name, the last step names it
	Missing_Tag, // an object for a union that reads by tag has no tag member
	Repeated_Tag, // an object for a union that reads by tag has two
	Duplicate_Key, // a read under `.Refuse` met a key that repeats one of its object's
	No_Memory,
	Bad_Option, // an option or a target the call cannot take, at no byte, `want.text` saying why where it can
	Plan_Mismatch, // a plan built for another type or format, at no byte
	Unsupported, // a type a plan cannot read or write, the last step names the field
	Ambiguous_Union, // a union whose arms a value's class cannot tell apart
	Bad_Tag, // a field's tag holds a flag no reader knows
	Invalid_Utf8, // a string to write is not UTF-8
	Non_Finite, // a number to write is infinite or not a number
	Too_Deep, // a value to write nests past `MAX_DEPTH`
	Cycle, // a pointer to write leads back to itself
	Bad_Raw, // a `Raw` or `Number_Text` to write is not one value of the format
	Unwritable, // a value the format cannot spell, the last step names it
	Out_Of_Order, // a token call the text's grammar does not allow next, or a text finished before it is whole
	Write_Failed, // the output stream refused bytes, which may have left a prefix in it
	Bad_Schema, // a schema the reader refuses, `want.text` names the keyword and why, the steps lead to it
	Below_Minimum, // a number below a rule's lower bound or the least value its type holds
	Above_Maximum, // a number above a rule's upper bound or the greatest value its type holds
	Not_Multiple, // a number that is no whole multiple of a rule's divisor
	Too_Short, // a string with fewer code points than a rule allows
	Too_Long, // a string with more code points than a rule allows
	No_Match, // a string a rule's pattern does not match
	Pattern_Undecided, // a string a rule's pattern was not searched through, for the search ran out of memory
	Bad_Format, // a string that is no value of a rule's format
	Too_Few, // an array or object with fewer elements or members than a rule or a fixed array allows
	Too_Many, // an array or object with more elements or members than a rule, a fixed array or a fixed capacity allows
	Not_Unique, // an array whose elements repeat where a rule wants them unique
	Not_Allowed, // a value where a rule takes none, or a key a model's struct forbids: one it does not name or a read_only member
	No_Arm, // a value that passes none of a rule's subschemas, or no arm of a model's union takes
	Many_Arms, // a value that passes more than one of a rule's subschemas, where it takes one
	No_Sample, // a description no value passes, or none the bounded search found, `want.text` names the node
	No_Invalid_Sample, // a description every value passes, or one the bounded search found no failing value of
	Custom, // a value a model's validator refused, `want.text` holds its message
	Check_Failed, // a value a model's dump checked fails its rules, the steps lead to the first and `want.text` is its code
}

// The steps a `Typed_Refusal` holds.
MAX_ERROR_STEPS :: 8

// A typed read's or write's refusal, as an `Error` holds it. `at` is the value's byte in the source, 0 for a write and
// for a kind with no byte. `steps` is the path to the value from the target, the innermost `MAX_ERROR_STEPS` when
// `truncated` says more were cut from the front. The path is a slice of an allocator's, so that the union stays small
// on the path of every call that returns nil. A step's name lives as long as `src` or the plan, or for a decoded key as
// long as `context.temp_allocator`'s block. `found` is the kind of the value a `.Wrong_Kind` read. `.Write_Failed` holds
// what the stream answered in `cause`, which is `.Unknown` for most failures of a `core:os` file stream. `detail` holds
// the rest by kind.
Typed_Error :: struct {
	kind:         Typed_Error_Kind,
	truncated:    bool,
	found:        Kind,
	cause:        io.Error,
	at:           u64,
	using detail: Typed_Detail,
	steps:        []Step,
}

// A `Typed_Error` with its path in line, `steps[:n_steps]`: what a reader, a writer and a sink hold, so that a refusal
// allocates nothing.
Typed_Refusal :: struct {
	kind:         Typed_Error_Kind,
	truncated:    bool,
	n_steps:      u8,
	found:        Kind,
	cause:        io.Error,
	at:           u64,
	using detail: Typed_Detail,
	steps:        [MAX_ERROR_STEPS]Step,
}

// Makes the `Typed_Error` of `e`, whose path lives as long as `allocator`'s block. A path that cannot be copied is left
// out.
@(private)
typed_error_of :: proc(e: Typed_Refusal, allocator: runtime.Allocator) -> Typed_Error {
	e := e
	f := Typed_Error{kind = e.kind, truncated = e.truncated, found = e.found, cause = e.cause, at = e.at, detail = e.detail}
	if e.n_steps > 0 {
		if steps, failed := make([]Step, e.n_steps, allocator); failed == nil {
			copy(steps, e.steps[:e.n_steps])
			f.steps = steps
		}
	}
	return f
}

// The `Typed_Refusal` of `f`, whose path keeps the innermost `MAX_ERROR_STEPS` of `f.steps`.
typed_refusal_of :: proc "contextless" (f: Typed_Error) -> Typed_Refusal {
	e := Typed_Refusal{kind = f.kind, truncated = f.truncated, found = f.found, cause = f.cause, at = f.at, detail = f.detail}
	kept := f.steps[max(0, len(f.steps) - MAX_ERROR_STEPS):]
	e.n_steps = u8(len(kept))
	e.truncated = e.truncated || len(kept) < len(f.steps)
	copy(e.steps[:], kept)
	return e
}

// One error a check or a load reports. `start` and `end` are the failing value's first byte and the byte past it in the
// source (a container the read skips ends at its open token, since the walk passes its close unseen), `record` is the index of the record the read was in
// (0 for a read of one text), `path` the steps to the value from the root, any depth, and `keyword_path` the steps through
// the rules that failed it. `operand` is the rule's operand: what a model's failed rule asks, a member's name for `.Missing_Field` and a name rule. The steps' names are the sink's own
// copies, freed by `sink_destroy`.
Error_Entry :: struct {
	kind:         Typed_Error_Kind,
	start, end:   u64,
	record:       i64,
	path:         []Step,
	keyword_path: []Step,
	operand:      Value,
}

// What a refusal names beside its kind: `.Walk`'s fault in `inner`, what a `.Plan_Mismatch` met in `plans`, and
// `want` for the other kinds. The three share their bytes, so a reader reads the one its kind names, as `core:fmt` does
// by the tags.
Typed_Detail :: struct #raw_union {
	inner: Fault `raw_union_tag:"kind=Walk"`,
	want:  Typed_Want `raw_union_tag:"kind=Wrong_Kind,kind=Out_Of_Range,kind=Not_A_Member,kind=Below_Minimum,kind=Above_Maximum,kind=Missing_Field,kind=Bad_Tag,kind=Unsupported,kind=Ambiguous_Union,kind=Bad_Schema,kind=No_Sample,kind=No_Invalid_Sample,kind=Custom,kind=Check_Failed,kind=Bad_Option,kind=Too_Deep"`,
	plans: Plan_Clash `raw_union_tag:"kind=Plan_Mismatch"`,
}

// `type` is the type a `.Wrong_Kind`, `.Out_Of_Range`, `.Not_A_Member`, `.Below_Minimum` or `.Above_Maximum` read wanted. `text` is the refused scalar's
// source text for those kinds, which lives as long as `src`, the flag a `.Bad_Tag` names, why a type is
// `.Unsupported`, a union `.Ambiguous_Union` or an option `.Bad_Option`, or what a `.Too_Deep` limit bounds. Either may be empty.
Typed_Want :: struct {
	type: typeid,
	text: string,
}

// The formats a `.Plan_Mismatch` met, the plan's and the read's, and the plan's type when the formats agree. Both are
// nil where the refusal does not know them.
Plan_Clash :: struct {
	plan, read: ^Readers,
	type:       typeid,
}

@(private, rodata)
TYPED_KIND_RULES := [Typed_Error_Kind]Rule {
	.None          = {"none", "No error"},
	.Walk          = {"walk", "Input does not parse"},
	.Wrong_Kind    = {"wrong_kind", "Value does not fit the field's type"},
	.Out_Of_Range  = {"out_of_range", "Value is out of range for the field's type"},
	.Not_A_Member  = {"not_a_member", "Value is no member of the type"},
	.Wrong_Length  = {"wrong_length", "Wrong number of elements"},
	.Missing_Field = {"missing_field", "Required field is missing"},
	.Unknown_Field = {"unknown_field", "Unknown field"},
	.Missing_Tag   = {"missing_tag", "Object has no tag member"},
	.Repeated_Tag  = {"repeated_tag", "Object repeats its tag member"},
	.Duplicate_Key = {"duplicate_key", "Duplicate key"},
	.No_Memory     = {"no_memory", "Out of memory"},
	.Bad_Option    = {"bad_option", "Invalid option"},
	.Plan_Mismatch = {"plan_mismatch", "Plan does not read this target"},
	.Unsupported   = {"unsupported", "Type is not supported"},
	.Ambiguous_Union = {"ambiguous_union", "Union arms cannot be told apart"},
	.Bad_Tag       = {"bad_tag", "Invalid field tag"},
	.Invalid_Utf8  = {"invalid_utf8", "Invalid UTF-8"},
	.Non_Finite    = {"non_finite", "Number is not finite"},
	.Too_Deep      = {"too_deep", "Exceeds the depth limit"},
	.Cycle         = {"cycle", "Value refers to itself"},
	.Bad_Raw       = {"bad_raw", "Not one value of the format"},
	.Unwritable    = {"unwritable", "Value cannot be written in the format"},
	.Out_Of_Order  = {"out_of_order", "Token written out of order"},
	.Write_Failed  = {"write_failed", "Output refused the bytes"},
	.Bad_Schema    = {"bad_schema", "Schema is refused"},
	.Below_Minimum = {"below_minimum", "Number is below the minimum"},
	.Above_Maximum = {"above_maximum", "Number is above the maximum"},
	.Not_Multiple  = {"not_multiple", "Number is not a multiple of the divisor"},
	.Too_Short     = {"too_short", "String is too short"},
	.Too_Long      = {"too_long", "String is too long"},
	.No_Match      = {"no_match", "String does not match the pattern"},
	.Pattern_Undecided = {"pattern_undecided", "The pattern could not be decided on the string"},
	.Bad_Format    = {"bad_format", "String is not in the format"},
	.Too_Few       = {"too_few", "Too few elements or members"},
	.Too_Many      = {"too_many", "Too many elements or members"},
	.Not_Unique    = {"not_unique", "Elements are not unique"},
	.Not_Allowed   = {"not_allowed", "No value is allowed here"},
	.No_Arm        = {"no_arm", "Value passes none of the subschemas"},
	.Many_Arms     = {"many_arms", "Value passes more than one subschema"},
	.No_Sample     = {"no_sample", "No value passing the description was found"},
	.No_Invalid_Sample = {"no_invalid_sample", "No value failing the description was found"},
	.Custom        = {"custom", "Value is not valid"},
	.Check_Failed  = {"check_failed", "Value fails its model's rules"},
}

// The messages of a schema check's entries, which name keywords and not a type's fields, where they differ.
@(private, rodata)
SCHEMA_MESSAGES := #partial [Typed_Error_Kind]string {
	.Wrong_Kind    = "Value is not of the allowed type",
	.Not_A_Member  = "Value is not one of the allowed values",
	.Missing_Field = "Required member is missing",
	.Bad_Format    = "String is not valid for the asserted format",
}

// The kinds that name no byte of a source.
TYPED_AT_NO_BYTE :: bit_set[Typed_Error_Kind]{.None, .No_Sample, .No_Invalid_Sample, .Bad_Option, .Plan_Mismatch, .Unsupported, .Ambiguous_Union, .Bad_Tag, .Invalid_Utf8, .Non_Finite, .Too_Deep, .Cycle, .Bad_Raw, .Unwritable, .Out_Of_Order, .Write_Failed}

// Moves the bytes of the source `e` names by `by`, for an error found in a text that starts `by` bytes in.
move_typed_error :: proc(e: ^Typed_Refusal, by: u64) {
	if e.kind not_in TYPED_AT_NO_BYTE && (e.kind != .Walk || e.inner.kind not_in AT_NO_BYTE) {
		e.at += by
		if e.kind == .Walk {
			e.inner.at += by
		}
	}
}

@(private)
write_typed_code :: proc(w: io.Writer, e: Typed_Refusal) -> io.Error {return write_coded(w, "typed.", TYPED_KIND_RULES[e.kind].code)}

// Writes `line:col: message at path` for `e`, the position left out where the kind has no byte. `.Walk` writes its
// fault. `lines` is as in `render_fault`.
@(private)
render_typed :: proc(w: io.Writer, src: []u8, e: Typed_Refusal, lines: ^Lines = nil) -> io.Error {
	if e.kind == .Walk {
		return render_fault(w, src, e.inner, lines)
	}
	if e.kind not_in TYPED_AT_NO_BYTE {
		write_position(w, src, e.at, lines) or_return
	}
	write_typed_message(w, e) or_return
	if e.cause != .None {
		io.write_string(w, " (") or_return
		io.write_string(w, reflect.enum_string(e.cause)) or_return
		io.write_byte(w, ')') or_return
	}
	if e.n_steps == 0 {
		return nil
	}
	io.write_string(w, " at ") or_return
	if e.truncated {
		io.write_string(w, "...") or_return
	}
	e := e
	return write_steps(w, e.steps[:e.n_steps], !e.truncated)
}

// The most bytes of a refused value's text a message shows.
@(private)
SHOWN_TEXT_MAX :: 40

// Writes `e`'s message, naming what `e.detail` holds where its kind has one.
@(private)
write_typed_message :: proc(w: io.Writer, e: Typed_Refusal) -> io.Error {
	#partial switch e.kind {
	case .Wrong_Kind:
		if e.want.type != nil {
			io.write_string(w, "Expected ") or_return
			reflect.write_typeid(w, e.want.type) or_return
			io.write_string(w, ", found ") or_return
			// A plain value, as a dsv cell, has no kind of its own to name, so its text stands in quotes.
			if e.found == .Plain && len(e.want.text) > 0 {
				quoted := e.want.text[0] == '"'
				if !quoted {
					io.write_byte(w, '"') or_return
				}
				write_shown(w, e.want.text) or_return
				return nil if quoted else io.write_byte(w, '"')
			}
			return write_kind_word(w, e.found)
		}
	case .Out_Of_Range, .Below_Minimum, .Above_Maximum:
		if e.want.type != nil && len(e.want.text) > 0 {
			write_shown(w, e.want.text) or_return
			io.write_string(w, " is out of range for ") or_return
			_, err := reflect.write_typeid(w, e.want.type)
			return err
		}
	case .Not_A_Member:
		if e.want.type != nil {
			if len(e.want.text) > 0 {
				write_shown(w, e.want.text) or_return
				io.write_string(w, " is not a ") or_return
			} else {
				io.write_string(w, "Value is no member of ") or_return
			}
			_, err := reflect.write_typeid(w, e.want.type)
			return err
		}
	case .Plan_Mismatch:
		if p := e.plans; p.plan != nil && p.read != nil && p.plan.format != p.read.format {
			io.write_string(w, "Plan is for ") or_return
			io.write_string(w, p.plan.tag_key) or_return
			io.write_string(w, ", the read is ") or_return
			_, err := io.write_string(w, p.read.tag_key)
			return err
		} else if p.type != nil {
			io.write_string(w, "Plan is for ") or_return
			reflect.write_typeid(w, p.type) or_return
			_, err := io.write_string(w, ", not the target's type")
			return err
		}
	case .Bad_Tag:
		if len(e.want.text) > 0 {
			io.write_string(w, "Field tag flag \"") or_return
			io.write_string(w, e.want.text) or_return
			io.write_string(w, "\" is not one the field takes") or_return
			if e.want.type != nil {
				io.write_string(w, " in ") or_return
				reflect.write_typeid(w, e.want.type) or_return
			}
			if strings.has_prefix(e.want.text, "pattern") && strings.contains_rune(e.want.text, ',') {
				_, err := io.write_string(w, ": pattern= takes the rest of the tag, commas included, so put it last or add the rule with register_field")
				return err
			}
			return nil
		}
	case .Custom:
		if len(e.want.text) > 0 {
			_, err := io.write_string(w, e.want.text)
			return err
		}
	case .Unsupported, .Ambiguous_Union, .Bad_Schema, .No_Sample, .No_Invalid_Sample, .Bad_Option, .Too_Deep:
		io.write_string(w, TYPED_KIND_RULES[e.kind].message) or_return
		if len(e.want.text) > 0 {
			io.write_string(w, ": ") or_return
			io.write_string(w, e.want.text) or_return
		}
		return nil
	}
	_, err := io.write_string(w, TYPED_KIND_RULES[e.kind].message)
	return err
}

// Writes `text`, cut to `SHOWN_TEXT_MAX` bytes at a character's start with `...` after it.
@(private)
write_shown :: proc(w: io.Writer, text: string) -> io.Error {
	if len(text) <= SHOWN_TEXT_MAX {
		_, err := io.write_string(w, text)
		return err
	}
	cut := SHOWN_TEXT_MAX
	for cut > 0 && text[cut] & 0xC0 == 0x80 {
		cut -= 1
	}
	io.write_string(w, text[:cut]) or_return
	_, err := io.write_string(w, "...")
	return err
}

// Writes the kind of a value as a word: `null`, `true`, `number`, `object`.
@(private)
write_kind_word :: proc(w: io.Writer, k: Kind) -> io.Error {
	name := reflect.enum_string(k)
	if name == "Map" {
		name = "Object"
	}
	for i in 0 ..< len(name) {
		c := name[i]
		io.write_byte(w, c + 32 if c >= 'A' && c <= 'Z' else c) or_return
	}
	return nil
}

// Writes `steps` as stury path text, `.a[1]."b c"`, which `parse_path` reads back. `whole` says the steps start at the
// root, so a first step that is no name opens with `.`.
write_steps :: proc(w: io.Writer, steps: []Step, whole: bool) -> io.Error {
	for s, i in steps {
		if i == 0 && whole {
			if _, named := s.(Name); !named {
				io.write_byte(w, '.') or_return
			}
		}
		switch v in s {
		case Name:
			io.write_byte(w, '.') or_return
			write_step_name(w, string(v)) or_return
		case Index:
			io.write_byte(w, '[') or_return
			io.write_int(w, int(v)) or_return
			io.write_byte(w, ']') or_return
		case Index_Or_Name:
			io.write_byte(w, '[') or_return
			io.write_int(w, v.index) or_return
			io.write_byte(w, ']') or_return
		case All:
			io.write_string(w, "[]") or_return
		case Slice:
			io.write_byte(w, '[') or_return
			io.write_int(w, v.lo) or_return
			io.write_byte(w, ':') or_return
			if hi, bounded := v.hi.?; bounded {
				io.write_int(w, hi) or_return
			}
			io.write_byte(w, ']') or_return
		case Descend:
			io.write_byte(w, '.') or_return
		}
	}
	return nil
}

// Writes `steps` as a JSON Pointer (RFC 6901): nothing for the root, else `/` and each step's name with `~` and `/` escaped,
// or its index. A step that names no one member, or all, writes `-`.
write_pointer :: proc(w: io.Writer, steps: []Step) -> io.Error {
	for s in steps {
		io.write_byte(w, '/') or_return
		switch v in s {
		case Name:
			for c in transmute([]u8)string(v) {
				switch c {
				case '~': io.write_string(w, "~0") or_return
				case '/': io.write_string(w, "~1") or_return
				case: io.write_byte(w, c) or_return
				}
			}
		case Index:
			io.write_int(w, int(v)) or_return
		case Index_Or_Name:
			io.write_int(w, v.index) or_return
		case All, Slice, Descend:
			io.write_byte(w, '-') or_return
		}
	}
	return nil
}

// Writes a member name as a path step spells it: bare when it is a jq identifier, else quoted as a JSON string.
@(private)
write_step_name :: proc(w: io.Writer, name: string) -> io.Error {
	bare := len(name) > 0 && is_name_start(name[0])
	for i in 1 ..< len(name) {
		bare &&= is_name_start(name[i]) || name[i] >= '0' && name[i] <= '9'
	}
	if bare {
		_, err := io.write_string(w, name)
		return err
	}
	io.write_byte(w, '"') or_return
	for i in 0 ..< len(name) {
		c := name[i]
		switch {
		case c == '"' || c == '\\':
			io.write_byte(w, '\\') or_return
			io.write_byte(w, c) or_return
		case c < 0x20:
			hex := "0123456789abcdef"
			io.write_string(w, "\\u00") or_return
			io.write_byte(w, hex[c >> 4]) or_return
			io.write_byte(w, hex[c & 15]) or_return
		case:
			io.write_byte(w, c) or_return
		}
	}
	return io.write_byte(w, '"')
}

// What a public procedure returns when it fails, nil when it does not. The arms are disjoint by cause: a `Fault` is a
// text that does not read, whichever call found it, and `runtime.Allocator_Error` is an allocation refused. The structs
// hold what is theirs: a refused edit or document call, a refused path, a refused typed read or write as a `Typed_Error`.
// `Typed_Error_Kind` is what the token writer returns once a token.
Error :: union {
	Fault,
	runtime.Allocator_Error,
	Document_Error,
	Path_Error,
	Typed_Error,
	Typed_Error_Kind,
}

// Makes the `Error` of a concrete error: nil for the kind `.None`, the inner `Fault` for `.Walk`, an out of memory
// for `.No_Memory`, a `Fault` for `.Duplicate_Key`, else the struct itself, a `Typed_Refusal` as its `Typed_Error`. A
// struct that is assigned to an `Error` by hand is not nil when its kind is `.None`, so every public procedure returns
// through this one. `edit` says a `Document_Error` is an edit's own refusal, whose `.Duplicate_Key` is a commit's named
// cell that its record holds and no fault of a text.
error_of :: proc{error_of_untyped, error_of_typed}

// Nil is judged in line, so that a call that succeeds does not unpack the struct it was given.
@(private)
error_of_untyped :: #force_inline proc "contextless" (e: $E, edit := false) -> Error {
	when E == Maybe(Fault) {
		if e == nil {
			return nil
		}
	} else {
		if e.kind == .None {
			return nil
		}
	}
	return refusal_of(e, edit)
}

@(private)
@(cold)
refusal_of :: #force_no_inline proc "contextless" (e: $E, edit: bool) -> Error {
	when E == Fault {
		#partial switch e.kind {
		case .None:
			return nil
		case .No_Memory:
			return runtime.Allocator_Error.Out_Of_Memory
		}
		return e
	} else when E == Maybe(Fault) {
		if f, ok := e.?; ok {
			return error_of(f)
		}
		return nil
	} else when E == Document_Error {
		#partial switch e.kind {
		case .None:
			return nil
		case .Walk:
			return error_of(e.inner)
		case .No_Memory:
			return runtime.Allocator_Error.Out_Of_Memory
		case .Duplicate_Key:
			if !edit {
				return Fault{at = e.at, kind = .Duplicate_Key}
			}
		}
		return e
	} else when E == Path_Error {
		#partial switch e.kind {
		case .None:
			return nil
		case .Walk:
			return error_of(e.inner)
		case .No_Memory:
			return runtime.Allocator_Error.Out_Of_Memory
		case .Duplicate_Key:
			return Fault{at = e.at, kind = .Duplicate_Key}
		}
		return e
	} else {
		#panic("error_of takes a Fault, a Maybe(Fault), a Document_Error, a Path_Error")
	}
}

// `error_of` of a `Typed_Refusal`, whose path is copied to `allocator`: the temp allocator, or a reader's own for a
// record read in a loop.
@(private)
error_of_typed :: #force_inline proc(e: Typed_Refusal, allocator := context.temp_allocator) -> Error {
	if e.kind == .None {
		return nil
	}
	return refusal_of_typed(e, allocator)
}

@(private)
@(cold)
refusal_of_typed :: #force_no_inline proc(e: Typed_Refusal, allocator: runtime.Allocator) -> Error {
	#partial switch e.kind {
	case .Walk:
		return error_of(e.inner)
	case .No_Memory:
		return runtime.Allocator_Error.Out_Of_Memory
	case .Duplicate_Key:
		return Fault{at = e.at, kind = .Duplicate_Key}
	}
	return typed_error_of(e, allocator)
}

// Writes `err`'s code, as `json.literal`, `document.bad_index`, `path.bad_path` or `typed.wrong_kind`. A `Fault`'s is
// its rule's, prefixed by its format when it has one, and an allocation refused is `no_memory`. Nil writes nothing.
write_code :: proc(w: io.Writer, err: Error) -> io.Error {
	switch e in err {
	case Fault:
		return write_fault_code(w, e)
	case runtime.Allocator_Error:
		return write_coded(w, "", KIND_RULES[.No_Memory].code if e == .Out_Of_Memory else "allocator_error")
	case Document_Error:
		return write_document_code(w, e)
	case Path_Error:
		return write_path_code(w, e)
	case Typed_Error:
		return write_typed_code(w, typed_refusal_of(e))
	case Typed_Error_Kind:
		return write_typed_code(w, Typed_Refusal{kind = e})
	}
	return nil
}

// Writes the rendered line of `err` in `src`, as `line:col: message`, with `at path` after a typed error's. A
// `Typed_Error_Kind` renders as a `Typed_Refusal` of that kind, and an allocation refused as out of memory. `lines` is as in
// `render_fault`. Nil writes nothing.
render :: proc(w: io.Writer, src: []u8, err: Error, lines: ^Lines = nil) -> io.Error {
	switch e in err {
	case Fault:
		return render_fault(w, src, e, lines)
	case runtime.Allocator_Error:
		if e == .Out_Of_Memory {
			_, werr := io.write_string(w, KIND_RULES[.No_Memory].message)
			return werr
		}
		io.write_string(w, "Allocator error: ") or_return
		_, werr := io.write_string(w, reflect.enum_string(e))
		return werr
	case Document_Error:
		return render_document(w, src, e, lines)
	case Path_Error:
		return render_path(w, src, e, lines)
	case Typed_Error:
		return render_typed(w, src, typed_refusal_of(e), lines)
	case Typed_Error_Kind:
		return render_typed(w, src, Typed_Refusal{kind = e}, lines)
	}
	return nil
}

// The kinds whose entry, outside a keyword path, holds in its operand what the failed rule asks.
@(private)
ENTRY_OPERAND_KINDS :: bit_set[Typed_Error_Kind]{.Wrong_Kind, .Below_Minimum, .Above_Maximum, .Too_Short, .Too_Long, .Too_Few, .Too_Many, .Too_Deep}

// The message of a check's entry `e`, in a schema's words where the entry has a keyword path and the kind has such words.
// A missing member is named, which only the entry's operand does, and so is the member whose name failed a name rule.
write_entry_message :: proc(w: io.Writer, e: Error_Entry) -> io.Error {
	if text, named := e.operand.(string); named && e.kind == .Custom {
		_, err := io.write_string(w, text)
		return err
	}
	if name, named := e.operand.(string); named && e.kind == .Missing_Field {
		io.write_string(w, "Required member ") or_return
		io.write_quoted_string(w, name) or_return
		io.write_string(w, " is missing") or_return
		return nil
	}
	message := TYPED_KIND_RULES[e.kind].message
	if len(e.keyword_path) > 0 && SCHEMA_MESSAGES[e.kind] != "" {
		message = SCHEMA_MESSAGES[e.kind]
	}
	last: Step
	if len(e.keyword_path) > 0 {
		last = e.keyword_path[len(e.keyword_path) - 1]
	}
	if e.kind == .Not_Allowed && last == Step(Name("not")) {
		message = "Value passes the subschema that not refuses"
	}
	if (e.kind == .Too_Few || e.kind == .Too_Many) && (last == Step(Name("contains")) || last == Step(Name("minContains")) || last == Step(Name("maxContains"))) {
		message = "Too few elements pass contains" if e.kind == .Too_Few else "Too many elements pass contains"
	}
	io.write_string(w, message) or_return
	if text, named := e.operand.(string); named && e.kind in ENTRY_OPERAND_KINDS && !names_member(e) {
		// What the failed rule asks, after the message: "String is too short, at least 2 characters".
		io.write_string(w, ", ") or_return
		if e.kind == .Wrong_Kind {
			io.write_string(w, "expected ") or_return
		}
		_, err := io.write_string(w, text)
		return err
	}
	if name, named := e.operand.(string); named {
		io.write_string(w, " in the member name ") or_return
		io.write_quoted_string(w, name) or_return
	}
	return nil
}

// Whether the operand of a schema's entry `e` is the member name a `propertyNames` rule failed on.
@(private)
names_member :: proc(e: Error_Entry) -> bool {
	for step in e.keyword_path {
		if step == Step(Name("propertyNames")) {
			return true
		}
	}
	return false
}

// The stable code of a check's entry `e`, which a problem document and a caller match on.
entry_code :: proc(e: Error_Entry) -> string {
	return TYPED_KIND_RULES[e.kind].code
}

// Writes the rendered line of a check's entry `e` in `src`, as `line:col: message at path`, with the keyword path after
// it in parentheses and the message in a schema's words where the entry has one. `lines` is as in `render_fault`.
render_entry :: proc(w: io.Writer, src: []u8, e: Error_Entry, lines: ^Lines = nil) -> io.Error {
	write_position(w, src, e.start, lines) or_return
	write_entry_message(w, e) or_return
	if len(e.path) > 0 {
		io.write_string(w, " at ") or_return
		write_steps(w, e.path, true) or_return
	}
	if len(e.keyword_path) > 0 {
		io.write_string(w, " (") or_return
		write_steps(w, e.keyword_path, false) or_return
		io.write_byte(w, ')') or_return
	}
	return nil
}
