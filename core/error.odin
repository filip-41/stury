package core

import "core:io"
import "core:reflect"
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
	.Too_Deep      = {"too_deep", "Exceeds depth limit for parsing"},
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
	_, err := io.write_string(w, rule_of(f).message)
	return err
}

// The value layer's error kinds. `Document_Error.inner` holds a `Fault` by value for `.Walk`, `.Bad_Value` and
// `.Bad_Result`, so the error renders with its cause. The last two name a byte of a text that is not the rendered
// source.
Document_Error_Kind :: enum u8 {
	None,
	Walk, // the walk's fault, in `inner`
	Duplicate_Key, // a build with `refuse_duplicates` met a key that repeats one of its object's, at the second key's first byte, or a commit's named cell is one its record holds, at the header cell
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
}

// The document error kinds that name no byte of the text. Their `at` is not read.
@(private)
DOCUMENT_AT_NO_BYTE :: bit_set[Document_Error_Kind]{.None, .No_Memory, .Bad_Index, .Bad_Position, .Wrong_Container, .Bad_Value, .Bad_Fact, .Bad_Width, .Bad_Spec, .Bad_Result}

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

// A value layer error. `at` is the byte `kind` names: the walk's fault byte for `.Walk`, the first byte of the
// repeated key for `.Duplicate_Key`, of the shared node or span for `.Conflicting_Edits`. `inner` is the fault, set for
// `.Walk`, `.Bad_Value` and `.Bad_Result`, whose `inner.at` for the last two is a byte of the recorded text or of the
// commit's output, not of the source.
Document_Error :: struct {
	kind:  Document_Error_Kind,
	at:    u64,
	inner: Fault,
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

// Writes `line:col: message` for `e` in `src`. For `.Walk` it also writes `  caused by line:col: message` for
// `e.inner`, and for `.Bad_Value` and `.Bad_Result` `  caused by message`, since `inner.at` is a byte of a
// text that is not `src`. `lines` is as in `render_fault`. Errors from the edit list other than a conflict name no
// byte, since they describe a node, a recorded text or a position rather than a place in `src`.
@(private)
render_document :: proc(w: io.Writer, src: []u8, e: Document_Error, lines: ^Lines = nil) -> io.Error {
	if document_at_byte(e) {
		write_position(w, src, e.at, lines) or_return
	}
	io.write_string(w, DOCUMENT_KIND_RULES[e.kind].message) or_return
	if e.inner.kind == .None {
		return nil
	}
	io.write_string(w, "\n  caused by ") or_return
	if e.kind == .Walk {
		return render_fault(w, src, e.inner, lines)
	}
	_, err := io.write_string(w, rule_of(e.inner).message)
	return err
}

// The path layer's error kinds. A value a path does not reach is an `Answer`'s outcome, not an error.
Path_Error_Kind :: enum u8 {
	None,
	Bad_Path, // the path's text does not parse, at the byte of that text
	Over_Capacity, // a read past `MAX_PATHS` paths, a path past `MAX_STEPS` steps or of `MAX_STEPS` with a `Descend`, at no byte
	No_Memory, // an allocation the read owns was refused, at no byte
	Walk, // the walk's fault, in `inner`
	Duplicate_Key, // a read with `refuse_duplicates` met a key that repeats one of its object's, at the second key's first byte
	Unsupported, // a query of a partial document, or a read through a handle with no format, at no byte
}

// A path layer error. `at` is the byte `kind` names: a byte of the path's text for `.Bad_Path`, and the walk's fault
// byte for `.Walk`. `path` is the number in the read of the path a `.Bad_Path` or an `.Over_Capacity` of steps names, 0
// for the other kinds.
Path_Error :: struct {
	kind:  Path_Error_Kind,
	at:    u64,
	path:  u32,
	inner: Fault,
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

// Writes `line:col: message` for `e`. A `.Bad_Path`'s `at` is a byte of `path`, the path's text, and a `.Duplicate_Key`'s
// a byte of `src`, so the caller passes both and never tests the kind. `.Walk` writes its fault. `lines` is as in
// `render_fault`.
@(private)
render_path :: proc(w: io.Writer, src: []u8, path: string, e: Path_Error, lines: ^Lines = nil) -> io.Error {
	if e.kind == .Walk {
		return render_fault(w, src, e.inner, lines)
	}
	if e.kind == .Bad_Path {
		write_position(w, transmute([]u8)path, e.at, lines) or_return
	} else if e.kind == .Duplicate_Key {
		write_position(w, src, e.at, lines) or_return
	}
	_, err := io.write_string(w, PATH_KIND_RULES[e.kind].message)
	return err
}

// Writes `e`'s code: the path error's or the document error's, by `e.kind`.
@(private)
write_edit_code :: proc(w: io.Writer, e: Path_Edit_Error) -> io.Error {
	#partial switch e.kind {
	case .Path:
		return write_path_code(w, e.path)
	case .Edit:
		return write_document_code(w, e.edit)
	}
	return write_coded(w, "", "none")
}

// Writes the rendered line of `e`, as `render_path` for a path error and `render_document` for an edit's.
@(private)
render_edit :: proc(w: io.Writer, src: []u8, path: string, e: Path_Edit_Error, lines: ^Lines = nil) -> io.Error {
	#partial switch e.kind {
	case .Path:
		return render_path(w, src, path, e.path, lines)
	case .Edit:
		return render_document(w, src, e.edit, lines)
	}
	return write_coded(w, "", "No error")
}

// How a typed read or write refuses. `.None` is no error. The kinds from `Bad_Utf8` on are a write's, and none of them
// names a byte of a source.
Typed_Error_Kind :: enum u8 {
	None,
	Walk, // the walk's fault, in `inner`
	Wrong_Kind, // a value the target's type does not read
	Out_Of_Range, // a value past what the target holds
	Not_A_Member, // a name or number no enum or union member has
	Wrong_Length, // an array's element count differs from a fixed array's, or passes a fixed capacity
	Missing_Field, // a `required` member is absent, the last step names it
	Unknown_Field, // a key the type does not name, the last step names it
	Missing_Tag, // an object for a union that reads by tag has no tag member
	Repeated_Tag, // an object for a union that reads by tag has two
	Duplicate_Key, // a read with `refuse_duplicates` met a key that repeats one of its object's
	Out_Of_Memory,
	Bad_Option, // a nil target, at no byte
	Plan_Mismatch, // a plan built for another type or format, at no byte
	Unsupported, // a type a plan cannot read or write, the last step names the field
	Ambiguous_Union, // a union whose arms a value's class cannot tell apart
	Bad_Tag, // a field's tag holds a flag no reader knows
	Bad_Utf8, // a string to write is not UTF-8
	Non_Finite, // a number to write is infinite or not a number
	Too_Deep, // a value to write nests past `MAX_DEPTH`
	Cycle, // a pointer to write leads back to itself
	Bad_Raw, // a `Raw` or `Number_Text` to write is not one value of the format
	Unwritable, // a value the format cannot spell, the last step names it
	Out_Of_Order, // a token call the text's grammar does not allow next, or a text finished before it is whole
	Write_Failed, // the output stream refused bytes, which may have left a prefix in it
}

// The steps a `Typed_Error` holds.
MAX_ERROR_STEPS :: 8

// A typed read's or write's refusal. `at` is the value's byte in the source, 0 for a write and for a kind with no
// byte. `steps[:n_steps]` is the path to the value from the target, the innermost `MAX_ERROR_STEPS` when `truncated`
// says more were cut from the front. A step's name lives as long as `src` or the plan,
// or for a decoded key as long as `context.temp_allocator`'s block. `.Walk` holds its fault in `inner`, and
// `.Write_Failed` what the stream answered in `cause`, which is `.Unknown` for most failures of a `core:os` file stream.
Typed_Error :: struct {
	kind:      Typed_Error_Kind,
	truncated: bool,
	n_steps:   u8,
	cause:     io.Error,
	at:        u64,
	inner:     Fault,
	steps:     [MAX_ERROR_STEPS]Step,
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
	.Out_Of_Memory = {"out_of_memory", "Out of memory"},
	.Bad_Option    = {"bad_option", "Invalid option"},
	.Plan_Mismatch = {"plan_mismatch", "Plan does not read this target"},
	.Unsupported   = {"unsupported", "Type is not supported"},
	.Ambiguous_Union = {"ambiguous_union", "Union arms cannot be told apart"},
	.Bad_Tag       = {"bad_tag", "Invalid field tag"},
	.Bad_Utf8      = {"bad_utf8", "String is not valid UTF-8"},
	.Non_Finite    = {"non_finite", "Number is not finite"},
	.Too_Deep      = {"too_deep", "Value nests past the depth limit"},
	.Cycle         = {"cycle", "Value refers to itself"},
	.Bad_Raw       = {"bad_raw", "Text is not one value of the format"},
	.Unwritable    = {"unwritable", "Value cannot be written in the format"},
	.Out_Of_Order  = {"out_of_order", "Token written out of order"},
	.Write_Failed  = {"write_failed", "Output refused the bytes"},
}

// The kinds that name no byte of a source.
TYPED_AT_NO_BYTE :: bit_set[Typed_Error_Kind]{.None, .Bad_Option, .Plan_Mismatch, .Unsupported, .Ambiguous_Union, .Bad_Tag, .Bad_Utf8, .Non_Finite, .Too_Deep, .Cycle, .Bad_Raw, .Unwritable, .Out_Of_Order, .Write_Failed}

// Moves the bytes of the source `e` names by `by`, for an error found in a text that starts `by` bytes in.
move_typed_error :: proc(e: ^Typed_Error, by: u64) {
	if e.kind not_in TYPED_AT_NO_BYTE && (e.kind != .Walk || e.inner.kind not_in AT_NO_BYTE) {
		e.at += by
		if e.kind == .Walk {
			e.inner.at += by
		}
	}
}

@(private)
write_typed_code :: proc(w: io.Writer, e: Typed_Error) -> io.Error {return write_coded(w, "typed.", TYPED_KIND_RULES[e.kind].code)}

// Writes `line:col: message at path` for `e`, the position left out where the kind has no byte. `.Walk` writes its
// fault. `lines` is as in `render_fault`.
@(private)
render_typed :: proc(w: io.Writer, src: []u8, e: Typed_Error, lines: ^Lines = nil) -> io.Error {
	if e.kind == .Walk {
		return render_fault(w, src, e.inner, lines)
	}
	if e.kind not_in TYPED_AT_NO_BYTE {
		write_position(w, src, e.at, lines) or_return
	}
	io.write_string(w, TYPED_KIND_RULES[e.kind].message) or_return
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
	for s in e.steps[:e.n_steps] {
		#partial switch v in s {
		case Name:
			io.write_byte(w, '.') or_return
			io.write_string(w, string(v)) or_return
		case Index:
			io.write_byte(w, '[') or_return
			io.write_int(w, int(v)) or_return
			io.write_byte(w, ']') or_return
		}
	}
	return nil
}

// `write_code` writes an error's code, `render` writes its rendered line.
write_code :: proc {write_fault_code, write_document_code, write_path_code, write_edit_code, write_typed_code}
render :: proc {render_fault, render_document, render_path, render_edit, render_typed}
