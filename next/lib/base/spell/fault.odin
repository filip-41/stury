package spell

// Why a text failed to parse. Running out of depth and failed allocations are not faults.
Fault_Kind :: enum u8 {
	None,
	Truncated, // the text ends inside a construct, or a quoted cell never closes
	Bad_Char, // a byte that cannot continue the text, or invalid UTF-8
	Bad_Escape, // an undefined escape, or a lone surrogate half
	Bad_Number, // the byte that breaks a number
	Too_Wide, // a token longer than `Token.n` holds, or a record past its size limit
	Bad_Option, // a spec, option or framing the format does not take, and names no byte
	Bad_Width, // a record wider or narrower than the first
	Duplicate_Key, // a repeated key under a refusing duplicate policy
}
