package json

// The table the JSON walk and its value layer share: the byte a one-letter escape produces. The walk reads it to measure
// and check an escape, and the value layer reads it while decoding a string's text.

// The bytes a one-letter escape decodes to, packed little-endian in the low 24 bits, and the byte count 1 in bits 24
// to 31. 0 for `u` and for every byte that is not a one-letter escape.
@(private, rodata)
ESC_WORD: [256]u32 = {
	'"'  = 0x0100_0022,
	'\\' = 0x0100_005C,
	'/'  = 0x0100_002F,
	'b'  = 0x0100_0008,
	'f'  = 0x0100_000C,
	'n'  = 0x0100_000A,
	'r'  = 0x0100_000D,
	't'  = 0x0100_0009,
}
