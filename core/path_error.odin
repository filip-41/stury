package core

// A path procedure's refusal, the same for every format: `find` and the edits `set`, `insert`, `remove`,
// `splice` and `edit_comment` answer a `Maybe(Path_Error)`, nil when they succeeded.

// Why a path procedure refused. Nothing was written, and the source is unchanged. A format reports the kinds
// its docs list and never the others.
Path_Error_Kind :: enum u8 {
	Bad_Edit,         // `splice`: an edit out of range, or edits unsorted or overlapping
	Bad_Path,         // the path text does not parse (`offset` is where in the text the parser stopped)
	Unsupported_Path, // CSV: the path parses but is not one this procedure takes (a negative index, `limit(...)`, a name without a header)
	Over_Capacity,    // JSON: a fixed scan limit (`Capacity`) refused the path, as one past MAX_PATH_STEPS, or the source
	Bad_Option,       // CSV: the dialect is one the scanner refuses
	Bad_Source,       // the source is not valid in the format (`syntax`, `offset`: the scan's fault)
	Bad_Result,       // the edited text, or the value's text, is not valid (`syntax`, `offset` into that text)
	Bad_Row,          // CSV `insert`: the row has other cells than the columns (`offset` is its cell count, or the index of the struct field no column names)
	Not_Found,        // the path matched nothing
	Type_Mismatch,    // JSON `set`: the path found nothing, and every answer was a step meeting a value of another kind
	Too_Deep,         // JSON: the value, nested where it lands, would pass MAX_DEPTH
	Encode,           // `marshal` refused the value, or the format cannot spell it where it lands (`encode`; CSV `offset` is the record, or 0)
	Exists,           // JSON `insert`: the object already has the member
	Bad_Comment,      // JSON: the comment text is not one `//` line or one `/* */` block
	Unplaceable,      // no place for the entry or the result would not read back as the edit says (JSON: the root removed, a value of the wrong kind, past an array's end, `upsert` below a non-object. CSV: no record, a record taken for a comment, a changed BOM; `offset` is the record, or 0)
	Out_Of_Memory,    // the allocator refused
	Internal,         // JSON: a scan refusal no edit can produce, a bug in this package and not in the caller's request
}

// A refusal: `syntax` and `offset` are set for `.Bad_Source` and `.Bad_Result` (`syntax` may stay `.None`), `offset`
// alone for `.Bad_Path`, `.Bad_Row`, and for `.Encode` and `.Unplaceable` where the kind's docs say, `encode` for
// `.Encode`.
Path_Error :: struct {
	kind:   Path_Error_Kind,
	syntax: Error_Kind,    // the scan's fault
	encode: Marshal_Error, // marshal's refusal
	offset: u64,
}

// The refusal of an allocator.
PATH_OUT_OF_MEMORY :: Path_Error{kind = .Out_Of_Memory}
