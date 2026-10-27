package core

// Which occurrence a read uses when a key repeats within its scope: a JSON object's member key or a CSV header
// name. The zero value is `.Default`. Each format documents which members it accepts.
//
//	.Default  `.Last` for every read in every format, `.Refuse` for the edits
//	.Last     the last occurrence
//	.First    the first occurrence
//	.All      every occurrence, each read over the one before
//	.Refuse   none; the repeat is a `.Duplicate_Key` error
Duplicates :: enum u8 {
	Default,
	Last,
	First,
	All,
	Refuse,
}

// `d`, with `.Default` read as `fallback`: `.Last` for a reader, `.Refuse` for an edit.
duplicates_or :: #force_inline proc(d, fallback: Duplicates) -> Duplicates {
	return fallback if d == .Default else d
}
