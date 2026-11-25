package query

import "stury:lib/core/tape"

// The errors of the engine's operations, as values: what went wrong, in which operation, on which operands, and where
// in the data when the caller knows it. A query language renders them in its own words.

Error_Kind :: enum u8 {
	None,
	Types, // `op` takes no value of the type of `a` (and `b`)
	Zero_Divisor, // `a` divided by `b`, which is zero
	Range, // an index, count, code point or size out of what `op` takes
	Parse, // `a`, a text, does not read as `op` reads it: `detail` says why
	Raised, // a value a program raised, `a`
	Pattern, // `a` does not compile as a regular expression: `detail` says why
	Memory, // the memory budget ran out, or the allocator refused
	Budget, // the budget dimension `budget` ran out
	Depth, // a value or a path goes past the depth budget, in `op`
}

// The engine's operations, which an error names.
Op :: enum u8 {
	None,
	Add,
	Subtract,
	Multiply,
	Divide,
	Quotient, // a division truncated to an integer
	Remainder,
	Negate,
	Compare,
	Equal,
	Merge, // an object merged into another, member by member
	Index, // a member or element of `a` by `b`
	Slice,
	Iterate,
	Length,
	Keys,
	Has,
	Contains,
	Join,
	Split,
	Implode,
	Explode,
	To_Number,
	To_Text,
	Repeat,
	Set_Path,
	Delete_Paths,
	Get_Path,
	Sort,
	Group,
	Range,
	Match,
	Trim,
	Affix,
	Case,
	Format,
	Time,
	Math,
	Search, // a binary search of `a`, which is no array
	Entries,
	Indices,
	Encode,
	Decode,
	Url, // a text read as a URL reference
	Logfmt, // a text read as a line of logfmt
	Number_Format, // a number written by a format text
	Address, // a text read as an IP address or a network
	Pointer, // a text read as an RFC 6901 pointer
	Aggregate,
	Set, // a union, intersection or difference of arrays
	Reshape, // a melt or pivot of an array of objects
	Utf8_Length,
}

Error :: struct {
	kind:   Error_Kind,
	op:     Op,
	budget: tape.Budget_Kind,
	a, b:   Value, // held
	path:   Value, // where in the data, an array of keys and indexes, `.Absent` when not known
	detail: string, // borrowed, rodata or the run's
}
