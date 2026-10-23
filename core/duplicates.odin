package core

// Which occurrence a read uses when a key repeats within its scope: a JSON object's member key or a CSV header
// name. The zero value is the format's default, named in its docs. Each format documents which members it accepts.
//
//	.Default  the format's default: JSON `.Last`, CSV `.Refuse`
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
