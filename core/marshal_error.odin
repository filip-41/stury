package core

// Why a marshal refused, shared by every format. A format reports only the members its docs list.
Marshal_Error :: enum u8 {
	None,
	Bad_State,     // JSON: a hook wrote other than exactly one value
	Bad_Utf8,      // a string or name that is not valid UTF-8, or a rune that is not a Unicode scalar value
	Non_Finite,    // a NaN or an infinity
	Too_Deep,      // JSON: nesting past MAX_DEPTH
	Cycle,         // JSON: a pointer reached again inside its own value
	Unsupported,   // a type the format cannot write
	Bad_Raw,       // JSON: a `Raw` that is not exactly one strict JSON value (an empty one is `null`)
	Plan_Mismatch, // the plan was made for another root type
	Not_A_Member,  // an enum, written by name, holding a value none of its members has
	Write_Failed,  // the `io.Writer` failed (bytes it accepted before stay written)
	Out_Of_Memory, // the allocator refused
	Bad_Option,    // CSV: a dialect the scanner refuses
	Unwritable,    // CSV: a cell or record the dialect cannot write so that it reads back the same
}

// `Plan_Error` members share their values with the `Marshal_Error` members of the same meaning.
#assert(u8(Plan_Error.Bad_Name) == u8(Marshal_Error.Bad_Utf8))
#assert(u8(Plan_Error.Out_Of_Memory) == u8(Marshal_Error.Out_Of_Memory))
