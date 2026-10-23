package core

// Why a marshal refused, the same for every format. A format reports the members its docs list and never the
// others.
Marshal_Error :: enum u8 {
	None,
	Bad_State,     // JSON: a hook that writes other than one value
	Bad_Utf8,      // a string or name that is not valid UTF-8, or a rune that is not a Unicode scalar value
	Non_Finite,    // a NaN or an infinity
	Too_Deep,      // JSON: nesting past MAX_DEPTH
	Cycle,         // JSON: a pointer met again on its own open path
	Unsupported,   // a type the format has no spelling for
	Bad_Raw,       // JSON: a `Raw` that is not exactly one strict JSON value (an empty one is `null`)
	Plan_Mismatch, // the plan was made for another root type
	Not_A_Member,  // an enum, written by name, holding a value none of its members has
	Write_Failed,  // the `io.Writer` refused (what it took before is written)
	Out_Of_Memory, // the allocator refused
	Bad_Option,    // CSV: a dialect the scanner refuses
	Unwritable,    // CSV: a cell the dialect cannot spell so that it reads back
}

// A plan's error is the marshal error of its name.
#assert(u8(Plan_Error.Bad_Name) == u8(Marshal_Error.Bad_Utf8))
#assert(u8(Plan_Error.Out_Of_Memory) == u8(Marshal_Error.Out_Of_Memory))
