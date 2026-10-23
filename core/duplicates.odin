package core

// What a read does with a key its scope spells twice: a JSON object's member key, a CSV header name. The zero
// value is the format's own default, which its docs name, and each format says which members it takes.
//
//	.Default  the format's: JSON `.Last`, CSV `.Refuse`
//	.Last     the last occurrence
//	.First    the first occurrence
//	.All      every occurrence, each read over the one before
//	.Refuse   none: the repeat is `.Duplicate_Key`
Duplicates :: enum u8 {
	Default,
	Last,
	First,
	All,
	Refuse,
}
