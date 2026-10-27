package core

// How much of a text a read validates. The zero value is `.Strict`. Each format documents what its levels check.
//
//	.Strict      every byte, against the format's full grammar
//	.Structural  the structure only: where values and records start and end, not the content of scalars
//	.Lazy        what `.Strict` checks, in each value the read uses; an unused value may be skipped unchecked,
//	             so an unused malformed value may be accepted or refused
Strictness :: enum {
	Strict,
	Structural,
	Lazy,
}

// The read options every format shares, embedded first in each format's `Read_Opts`.
Read_Opts :: struct {
	strictness: Strictness,
	duplicates: Duplicates,
}
