package core

// A typed read's refusal: what, where, and the path to it. A `Name` step borrows the source or the type info,
// except a JSON5 key's decoded name, which `unmarshal` makes with its allocator.

// The kinds a read itself reports come first, numbered from 1. A hook's refusal uses the same numbers.
Unmarshal_Error_Kind :: enum u8 {
	Wrong_Kind = 1,  // the value's kind is not one the target takes, at the value
	Out_Of_Range,    // the right kind, but the target cannot hold it, at the value (or the map key)
	Not_A_Member,    // an enum target and a name or an integer that is none of its members, at the value
	Wrong_Length,    // a fixed array short (at its end) or over (at the first element too many)
	Missing_Field,   // a field tagged `required` absent, at the object's end, the path ends at the field
	Unknown_Field,   // unknown fields refused and a member the type does not name, at its key
	Missing_Tag,     // a union only `Plan_Opts.union_tag` reads objects into, and an object without it, at the object
	Repeated_Tag,    // such an object with its `union_tag` member twice, at the second key
	Out_Of_Memory,   // the allocator refused, or a list past 2^31 elements, at the value being read (0 preparing the type)
	Syntax,          // the walk's own syntax or budget result (`syntax`), at the validator's offset (the path is approximate)
	Unsupported,     // a type the read cannot read, before any byte, offset 0, the path names the field
	Ambiguous_Union, // a union two of whose arms take one kind, before any byte, offset 0, the path names the union
	Bad_Option,      // a nil target, or an option the read cannot take
	Plan_Mismatch,   // the plan was made for another root type
	Duplicate_Key,   // duplicate keys refused and a key repeating one of its object's, at the repeat's key, the path as deep as the target reads
	Bad_Tag,         // a field tag with a flag the format does not know, before any byte, offset 0, no path
}

// A sentence for each kind, as `render_error` writes it. A `.Syntax` reads as its `syntax` fault's text.
@(rodata)
UNMARSHAL_ERROR_TEXT := [Unmarshal_Error_Kind]string {
	.Wrong_Kind      = "Value of the wrong kind",
	.Out_Of_Range    = "Value out of range",
	.Not_A_Member    = "Not a member of the enum",
	.Wrong_Length    = "Wrong number of elements",
	.Missing_Field   = "Missing required field",
	.Unknown_Field   = "Unknown field",
	.Missing_Tag     = "Missing union tag",
	.Repeated_Tag    = "Repeated union tag",
	.Out_Of_Memory   = "Out of memory",
	.Syntax          = "Invalid text",
	.Unsupported     = "Unsupported type",
	.Ambiguous_Union = "Ambiguous union",
	.Bad_Option      = "Unsupported option",
	.Plan_Mismatch   = "Plan made for another type",
	.Duplicate_Key   = "Duplicate key",
	.Bad_Tag         = "Unknown field tag flag",
}

// A shape fault is the kind of its name, so a hook's answer passes through it as it is.
#assert(u8(Shape_Fault.Wrong_Kind) == u8(Unmarshal_Error_Kind.Wrong_Kind))
#assert(u8(Shape_Fault.Out_Of_Range) == u8(Unmarshal_Error_Kind.Out_Of_Range))
#assert(u8(Shape_Fault.Not_A_Member) == u8(Unmarshal_Error_Kind.Not_A_Member))
#assert(u8(Shape_Fault.Wrong_Length) == u8(Unmarshal_Error_Kind.Wrong_Length))
#assert(u8(Shape_Fault.Missing_Field) == u8(Unmarshal_Error_Kind.Missing_Field))
#assert(u8(Shape_Fault.Unknown_Field) == u8(Unmarshal_Error_Kind.Unknown_Field))
#assert(u8(Shape_Fault.Missing_Tag) == u8(Unmarshal_Error_Kind.Missing_Tag))
#assert(u8(Shape_Fault.Repeated_Tag) == u8(Unmarshal_Error_Kind.Repeated_Tag))
#assert(u8(Shape_Fault.Out_Of_Memory) == u8(Unmarshal_Error_Kind.Out_Of_Memory))

// The innermost steps an error path keeps (`Unmarshal_Error`, `Marshal_Error`).
ERROR_PATH_STEPS :: 8

Unmarshal_Error :: struct {
	steps:     [ERROR_PATH_STEPS]Step, // the path, outermost first, as `steps[:n_steps]`
	offset:    u64,
	kind:      Unmarshal_Error_Kind,
	syntax:    Error_Kind, // `.Syntax` only
	detail:    u8, // `syntax`'s format detail, as `Error.detail`
	n_steps:   u8,
	truncated: bool, // steps outside the innermost ERROR_PATH_STEPS were dropped
}

// A scan's fault `e` as a typed read's: `.Syntax` with the fault in `syntax`, except a refused allocation and
// a refused option, which keep their kinds and have no offset.
unmarshal_error_from :: proc(e: Error) -> Unmarshal_Error {
	#partial switch e.kind {
	case .Out_Of_Memory:
		return {kind = .Out_Of_Memory}
	case .Bad_Option:
		return {kind = .Bad_Option}
	}
	return {kind = .Syntax, syntax = e.kind, detail = e.detail, offset = e.offset}
}

// Put `s` before the path's steps of `err`, an `Unmarshal_Error` or a `Marshal_Error`. Paths are found
// innermost first, so once ERROR_PATH_STEPS are held a further step is an outer one, and it is dropped.
error_path_prepend :: proc(err: ^$E, s: Step) {
	if int(err.n_steps) == ERROR_PATH_STEPS {
		err.truncated = true
		return
	}
	copy(err.steps[1:err.n_steps + 1], err.steps[:err.n_steps])
	err.steps[0] = s
	err.n_steps += 1
}
