package jsonpath

import "core:strconv"
import "core:strings"
import "stury:lib/query"

// RFC 9535 §2.7 Normalized Paths: `$['a'][0]['b']` with strict single-quote escaping.

// One step along a normalized path during evaluation.
@(private)
Path_Seg_Kind :: enum u8 {
	Name,
	Index,
}

@(private)
Path_Seg :: struct {
	kind:    Path_Seg_Kind,
	key_val: query.Value, // `.Name` (held or borrowed string `query.Value`)
	index:   i64,         // `.Index` (always >= 0)
}

// Formats `segs` as an RFC 9535 §2.7 normalized path into `b` (clearing `b` first).
@(private)
format_norm_path :: proc(b: ^strings.Builder, segs: []Path_Seg) {
	strings.builder_reset(b)
	strings.write_byte(b, '$')
	num_buf: [24]u8
	for seg in segs {
		strings.write_byte(b, '[')
		switch seg.kind {
		case .Index:
			strings.write_string(b, strconv.write_int(num_buf[:], seg.index, 10))
		case .Name:
			strings.write_byte(b, '\'')
			write_norm_name(b, query.text_of(seg.key_val))
			strings.write_byte(b, '\'')
		}
		strings.write_byte(b, ']')
	}
}

// Writes `name` escaped per RFC 9535 §2.7 `normal-single-quoted`:
// `\b`, `\f`, `\n`, `\r`, `\t`, `\'`, `\\`, and `\u00xx` (lowercase hex) for other U+0000..U+001F.
// All other characters (including `"`, `/`, U+007F, and non-ASCII UTF-8) are written verbatim.
@(private)
write_norm_name :: proc(b: ^strings.Builder, name: string) {
	@(rodata, static)
	HEX := "0123456789abcdef"
	start := 0
	for i := 0; i < len(name); i += 1 {
		c := name[i]
		if c >= 0x20 && c != '\'' && c != '\\' {
			continue
		}
		if i > start {
			strings.write_string(b, name[start:i])
		}
		switch c {
		case '\b':
			strings.write_string(b, `\b`)
		case '\f':
			strings.write_string(b, `\f`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case '\'':
			strings.write_string(b, `\'`)
		case '\\':
			strings.write_string(b, `\\`)
		case:
			// Remaining control characters U+0000..U+001F as `\u00xx` (lowercase hex).
			esc := [6]u8{'\\', 'u', '0', '0', HEX[(c >> 4) & 0xF], HEX[c & 0xF]}
			strings.write_bytes(b, esc[:])
		}
		start = i + 1
	}
	if start < len(name) {
		strings.write_string(b, name[start:])
	}
}
