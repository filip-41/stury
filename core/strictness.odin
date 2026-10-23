package core

// How much of a text a read judges. The zero value is `.Strict`. Each format says what its levels check.
//
//	.Strict      every byte, by everything the format's grammar requires
//	.Structural  the structure only: where values and records start and end, not what scalars hold
//	.Lazy        what `.Strict` judges in each value the read uses; a value it does not use may be skipped
//	             unjudged, so an unused malformed value may be accepted or refused
Strictness :: enum {
	Strict,
	Structural,
	Lazy,
}
