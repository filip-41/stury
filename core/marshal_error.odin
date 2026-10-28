package core

// Why a marshal refused, shared by every format. A format reports only the members its docs list. The writers
// return the kind; the public entry points return a `Marshal_Error`.
Marshal_Error_Kind :: enum u8 {
	None,
	Bad_State,     // JSON: a hook wrote other than exactly one value
	Bad_Utf8,      // a string or name that is not valid UTF-8, or a rune that is not a Unicode scalar value
	Non_Finite,    // a NaN or an infinity; JSON: also a `Number` with no binary64 value (`.None`)
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
	Bad_Tag,       // a field tag with a flag the format does not know
}

// A sentence for each kind, as `render_error` writes it.
@(rodata)
MARSHAL_ERROR_TEXT := [Marshal_Error_Kind]string {
	.None          = "Unknown fault",
	.Bad_State     = "Hook wrote other than one value",
	.Bad_Utf8      = "Invalid UTF-8",
	.Non_Finite    = "Number has no finite value",
	.Too_Deep      = "Exceeds depth limit",
	.Cycle         = "Pointer reached inside its own value",
	.Unsupported   = "Unsupported type",
	.Bad_Raw       = "Raw text is not one value",
	.Plan_Mismatch = "Plan made for another type",
	.Not_A_Member  = "Not a member of the enum",
	.Write_Failed  = "Write failed",
	.Out_Of_Memory = "Out of memory",
	.Bad_Option    = "Unsupported option",
	.Unwritable    = "Dialect cannot write it unchanged",
	.Bad_Tag       = "Unknown field tag flag",
}

// A marshal's refusal: what, and the path to the value refused. A `Name` step borrows the type info or the
// value: a field's name as its tag or name gives it, a string map key. Any other map key is `Any`.
Marshal_Error :: struct {
	steps:     [ERROR_PATH_STEPS]Step, // the path, outermost first, as `steps[:n_steps]`
	kind:      Marshal_Error_Kind,
	n_steps:   u8,
	truncated: bool, // steps outside the innermost ERROR_PATH_STEPS were dropped
}

// A writer's result as the public entry points return it: nil for `.None`, else `fault`, the path found on the
// way out, with `kind`.
marshal_error_of :: proc(kind: Marshal_Error_Kind, fault: Marshal_Error = {}) -> Maybe(Marshal_Error) {
	if kind == .None {
		return nil
	}
	fault := fault
	fault.kind = kind
	return fault
}

// `Plan_Error` members share their values with the `Marshal_Error_Kind` members of the same meaning.
#assert(u8(Plan_Error.Bad_Name) == u8(Marshal_Error_Kind.Bad_Utf8))
#assert(u8(Plan_Error.Bad_Tag) == u8(Marshal_Error_Kind.Bad_Tag))
#assert(u8(Plan_Error.Out_Of_Memory) == u8(Marshal_Error_Kind.Out_Of_Memory))
