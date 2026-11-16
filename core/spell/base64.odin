package spell

// Bytes as base64 text, with the standard alphabet of RFC 4648 section 4 and `=` padding. Every format that has no
// byte strings of its own spells bytes this way.

// The 64 characters, each standing for six bits.
@(private, rodata)
BASE64_ALPHABET := [64]u8{
	'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
	'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
	'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '+', '/',
}

// The room `base64_text` needs for `n` bytes: four characters for each three bytes, the last one to three included.
base64_room :: proc "contextless" (n: int) -> int {
	return (n + 2) / 3 * 4
}

// Writes the base64 text of `bytes` into `text`, which has room for `base64_room(len(bytes))` bytes. Returns the count
// written.
base64_text :: proc "contextless" (text: []u8, bytes: []u8) -> int {
	at, read := 0, 0
	for ; read + 3 <= len(bytes); read += 3 {
		group := u32(bytes[read]) << 16 | u32(bytes[read + 1]) << 8 | u32(bytes[read + 2])
		text[at], text[at + 1] = BASE64_ALPHABET[group >> 18], BASE64_ALPHABET[group >> 12 & 63]
		text[at + 2], text[at + 3] = BASE64_ALPHABET[group >> 6 & 63], BASE64_ALPHABET[group & 63]
		at += 4
	}
	// One or two bytes are left: they are padded with zero bits, and each character past their bits is `=`.
	if left := len(bytes) - read; left > 0 {
		group := u32(bytes[read]) << 16
		if left == 2 {
			group |= u32(bytes[read + 1]) << 8
		}
		text[at], text[at + 1] = BASE64_ALPHABET[group >> 18], BASE64_ALPHABET[group >> 12 & 63]
		text[at + 2], text[at + 3] = BASE64_ALPHABET[group >> 6 & 63] if left == 2 else '=', '='
		at += 4
	}
	return at
}

// Decodes base64 `text` into `bytes`, which has room for `len(text) / 4 * 3` bytes. Returns the bytes written, or false
// for text `base64_text` would not write: a length that is not a multiple of 4, a byte outside the alphabet, `=` other
// than as the last one or two characters, or padding after bits that are not zero. Each byte string so has one text.
base64_bytes :: proc "contextless" (bytes: []u8, text: []u8) -> (decoded: []u8, ok: bool) {
	if len(text) % 4 != 0 {
		return nil, false
	}
	pad := 0
	if len(text) > 0 && text[len(text) - 1] == '=' {
		pad = 2 if text[len(text) - 2] == '=' else 1
	}
	at := 0
	for read := 0; read < len(text); read += 4 {
		group: u32
		for i in read ..< read + 4 {
			bits, in_alphabet := base64_bits(text[i])
			if !in_alphabet && !(text[i] == '=' && i >= len(text) - pad) {
				return nil, false
			}
			group = group << 6 | u32(bits)
		}
		bytes[at], bytes[at + 1], bytes[at + 2] = u8(group >> 16), u8(group >> 8), u8(group)
		at += 3
	}
	at -= pad
	// The bits before the padding that no byte holds land in the first byte past the decoded ones.
	if pad > 0 && bytes[at] != 0 {
		return nil, false
	}
	return bytes[:at], true
}

// The six bits that base64 character `c` stands for, and false when `c` is not in the alphabet.
@(private)
base64_bits :: proc "contextless" (c: u8) -> (bits: u8, ok: bool) {
	switch {
	case c >= 'A' && c <= 'Z':
		return c - 'A', true
	case c >= 'a' && c <= 'z':
		return c - 'a' + 26, true
	case c >= '0' && c <= '9':
		return c - '0' + 52, true
	case c == '+':
		return 62, true
	case c == '/':
		return 63, true
	}
	return 0, false
}
