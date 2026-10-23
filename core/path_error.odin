package core

// Path procedure errors, shared by every format. `find` and the edits `set`, `insert`, `remove`, `splice` and
// `edit_comment` return a `Maybe(Path_Error)`, nil on success.

// Why a path procedure refused. On a refusal nothing is written and the source is unchanged. A format reports
// only the kinds its docs list.
Path_Error_Kind :: enum u8 {
	Bad_Edit,         // `splice`: an edit out of range, or edits unsorted or overlapping
	Bad_Path,         // the path text does not parse (`offset` is where in the text the parser stopped)
	Unsupported_Path, // CSV: the path parses but this procedure does not accept it (a negative index, `limit(...)`, a name without a header)
	Over_Capacity,    // JSON: a fixed scan limit (`Capacity`) refused the path (for example more than MAX_PATH_STEPS steps) or the source
	Bad_Option,       // CSV: the scanner refuses the dialect
	Bad_Source,       // the source is not valid in the format (`syntax` and `offset` give the scan's fault)
	Bad_Result,       // the edited text, or the value's text, is not valid (`syntax`, and `offset` into that text)
	Bad_Row,          // CSV `insert`: the row's cells do not match the columns (`offset` is its cell count, or the index of the struct field no column names)
	Not_Found,        // the path matched nothing
	Type_Mismatch,    // JSON `set`: the path matched nothing, and every miss was a step reaching a value of another kind
	Too_Deep,         // JSON: the value, nested at its destination, would exceed MAX_DEPTH
	Encode,           // `marshal` refused the value, or the format cannot write it at its destination (`encode`; CSV `offset` is the record, or 0)
	Exists,           // JSON `insert`: the object already has the member
	Bad_Comment,      // JSON: the comment text is not one `//` line or one `/* */` block
	Unplaceable,      // the entry has no valid place, or the result would not read back as the edit specifies (JSON: removing the root, a value of the wrong kind, past an array's end, `upsert` below a non-object. CSV: no record, a record read as a comment, a changed BOM; `offset` is the record, or 0)
	Out_Of_Memory,    // the allocator refused
	Internal,         // JSON: a scan refusal no edit can cause; a bug in this package, not in the caller's request
}

// A path procedure's refusal. `syntax` and `offset` are set for `.Bad_Source` and `.Bad_Result` (`syntax` may be
// `.None`). `offset` alone is set for `.Bad_Path` and `.Bad_Row`, and for `.Encode` and `.Unplaceable` where the
// kind's comment says so. `encode` is set for `.Encode`.
Path_Error :: struct {
	kind:   Path_Error_Kind,
	syntax: Error_Kind,    // the scan's fault
	encode: Marshal_Error, // marshal's refusal
	offset: u64,
}

// The error for a refused allocation.
PATH_OUT_OF_MEMORY :: Path_Error{kind = .Out_Of_Memory}
