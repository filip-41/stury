package core

// Path procedure errors, shared by every format. `request_init`, `scan`, `find`, `route_of`, `query`,
// the edits `set`, `insert`, `remove`, `splice`, `insert_comment`, `set_comment` and `remove_comment`, and
// JSON's `format` return a `Maybe(Path_Error)`, nil on success. A fault of the text they read is `.Bad_Source`
// with the scan's `Error` in `syntax`, `detail` and
// `offset`.

// Why a path procedure refused. On a refusal nothing is written and the source is unchanged. A format reports
// only the kinds its docs list.
Path_Error_Kind :: enum u8 {
	Bad_Edit,         // `splice`: an edit out of range, or edits unsorted or overlapping
	Bad_Path,         // the path text does not parse (`offset` is where in the text the parser stopped)
	Unsupported_Path, // the path parses but this procedure does not accept it (CSV: a negative index, `limit(...)`, a name without a header)
	Over_Capacity,    // a fixed scan limit refused the path (for example more than MAX_PATH_STEPS steps) or the source
	Bad_Option,       // an option the procedure does not take (a dialect with no edits, or one the scanner refuses)
	Bad_Source,       // the source is not valid in the format (`syntax` and `offset` give the scan's fault)
	Bad_Result,       // the edited text, or the value's text, is not valid (`syntax`, and `offset` into that text)
	Bad_Entry,        // `insert`: the entry does not fit the shape of its destination (CSV: the row's cells and the columns; `offset` is its cell count, or the index of the struct field no column names)
	Not_Found,        // the path matched nothing
	Type_Mismatch,    // the path matched nothing, and every miss was a step reaching a value of another kind
	Too_Deep,         // the value, nested at its destination, would exceed MAX_DEPTH
	Encode,           // `marshal` refused the value, or the format cannot write it at its destination (`encode`; `offset` is the record, the refused value's in `format`, or 0)
	Exists,           // `insert`: the object already has the member
	Bad_Comment,      // the comment text is not one comment of the format
	Unplaceable,      // the entry has no valid place, or the result would not read back as the edit specifies (JSON: removing the root, a value of the wrong kind, past an array's end, `upsert` below a non-object, a JSONC `splice` opening a comment the source bytes close. CSV: no record, a record read as a comment, a changed BOM; `offset` is the record, or 0)
	Out_Of_Memory,    // the allocator refused
	Internal,         // a scan refusal no edit can cause; a bug in the format's package, not in the caller's request
}

// A sentence for each kind, as `render_error` writes it.
@(rodata)
PATH_ERROR_TEXT := [Path_Error_Kind]string {
	.Bad_Edit         = "Edits out of range, unsorted or overlapping",
	.Bad_Path         = "Invalid path",
	.Unsupported_Path = "Unsupported path",
	.Over_Capacity    = "Exceeds a fixed limit of the path scan",
	.Bad_Option       = "Unsupported option",
	.Bad_Source       = "Invalid source text",
	.Bad_Result       = "Invalid result text",
	.Bad_Entry        = "Entry does not fit its destination",
	.Not_Found        = "Path matched nothing",
	.Type_Mismatch    = "Path reaches a value of another kind",
	.Too_Deep         = "Exceeds depth limit",
	.Encode           = "Value cannot be written",
	.Exists           = "Member already exists",
	.Bad_Comment      = "Invalid comment",
	.Unplaceable      = "Entry has no valid place",
	.Out_Of_Memory    = "Out of memory",
	.Internal         = "Internal error",
}

// A path procedure's refusal. `syntax` and `offset` are set for `.Bad_Source` and `.Bad_Result`.
// `offset` alone is set for `.Bad_Path` and `.Bad_Entry`, and for `.Encode` and `.Unplaceable` where the
// kind's comment says so. `encode` is set for `.Encode`.
Path_Error :: struct {
	kind:   Path_Error_Kind,
	syntax: Error_Kind,    // the scan's fault
	detail: u8,            // `syntax`'s format detail, as `Error.detail`
	encode: Marshal_Error_Kind, // marshal's refusal
	offset: u64,
}

// The error for a refused allocation.
PATH_OUT_OF_MEMORY :: Path_Error{kind = .Out_Of_Memory}

// The scan's fault `e` on a text read as `kind`'s text (`.Bad_Source` or `.Bad_Result`). A refused allocation
// is `PATH_OUT_OF_MEMORY` and a refused option `.Bad_Option`, whichever text the scan read.
path_error_of :: proc(e: Error, kind := Path_Error_Kind.Bad_Source) -> Path_Error {
	#partial switch e.kind {
	case .Out_Of_Memory:
		return PATH_OUT_OF_MEMORY
	case .Bad_Option:
		return {kind = .Bad_Option}
	}
	return {kind = kind, syntax = e.kind, detail = e.detail, offset = e.offset}
}

// The `Error` a scan found that `e` carries: a `.Bad_Source`'s fault, or a `.Bad_Option` or `.Out_Of_Memory`
// as that kind. `ok` is false for a refusal of the path or the request, which no text caused.
source_error :: proc(e: Path_Error) -> (err: Error, ok: bool) {
	#partial switch e.kind {
	case .Bad_Source:
		return {kind = e.syntax, detail = e.detail, offset = e.offset}, true
	case .Bad_Option:
		return {kind = .Bad_Option}, true
	case .Out_Of_Memory:
		return {kind = .Out_Of_Memory}, true
	}
	return {}, false
}
