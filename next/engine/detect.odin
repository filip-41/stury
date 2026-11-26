package engine

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"
import "stury:cbor"
import "stury:dsv"
import "stury:json"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:toml"
import "stury:xml"

// Format detection by file path (extension with optional trailing compression suffix)
// and by content inspection (magic bytes / leading grammar heuristics).

// Recognized trailing compression suffixes stripped by `strip_compression_suffix`.
Compression_Kind :: enum u8 {
	None,
	Gzip,
	Zstd,
	Bzip2,
	Xz,
	Lz4,
	Brotli,
}

@(private = "file")
Comp_Suffix :: struct {
	ext:  string,
	kind: Compression_Kind,
}

@(private = "file", rodata)
COMP_SUFFIXES := [?]Comp_Suffix {
	{"gz", .Gzip},
	{"gzip", .Gzip},
	{"zst", .Zstd},
	{"zstd", .Zstd},
	{"bz2", .Bzip2},
	{"xz", .Xz},
	{"lz4", .Lz4},
	{"br", .Brotli},
}

// Strips a trailing compression suffix (case-insensitive) when preceded by another extension.
strip_compression_suffix :: proc "contextless" (path: string) -> (stripped: string, comp: Compression_Kind) {
	base_start := 0
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			base_start = i + 1
			break
		}
	}
	last_dot := -1
	for i := len(path) - 1; i > base_start; i -= 1 {
		if path[i] == '.' {
			last_dot = i
			break
		}
	}
	if last_dot <= base_start {
		return path, .None
	}
	ext := path[last_dot + 1:]
	for s in COMP_SUFFIXES {
		if ascii_eq_fold(ext, s.ext) {
			// Require an inner extension before stripping so standalone `archive.gz` isn't stripped to `archive`.
			inner_dot := -1
			for i := last_dot - 1; i > base_start; i -= 1 {
				if path[i] == '.' {
					inner_dot = i
					break
				}
			}
			if inner_dot > base_start {
				return path[:last_dot], s.kind
			}
			return path, s.kind
		}
	}
	return path, .None
}

// Maps a file path (stripping known compression suffixes like `.gz`, `.zst`, `.bz2`, `.xz`, `.lz4`)
// to its `Format_Entry` and default `Framing`. Case-insensitive extension lookup.
format_of_path :: proc "contextless" (path: string) -> (entry: Format_Entry, framing: Framing, ok: bool) {
	clean, _ := strip_compression_suffix(path)
	base_start := 0
	for i := len(clean) - 1; i >= 0; i -= 1 {
		if clean[i] == '/' || clean[i] == '\\' {
			base_start = i + 1
			break
		}
	}
	dot := -1
	for i := len(clean) - 1; i > base_start; i -= 1 {
		if clean[i] == '.' {
			dot = i
			break
		}
	}
	if dot <= base_start || dot + 1 >= len(clean) {
		return {}, .Single, false
	}
	ext := clean[dot + 1:]
	for m in FORMAT_META {
		for candidate in m.extensions {
			if ascii_eq_fold(ext, candidate) {
				e, found := entry_of_id(m.id)
				if !found {
					return {}, .Single, false
				}
				f := e.default_framing
				if m.id == .Json {
					switch {
					case ascii_eq_fold(ext, "ndjson"), ascii_eq_fold(ext, "jsonl"), ascii_eq_fold(ext, "ldjson"), ascii_eq_fold(ext, "jsonlines"):
						f = .Lines
					case ascii_eq_fold(ext, "jsonseq"):
						f = .Seq
					}
				}
				return e, f, true
			}
		}
	}
	return {}, .Single, false
}

// Detects the format and framing of `src` by inspecting magic bytes, UTF-8 validity, and leading structure.
detect_format :: proc(src: []u8, allocator := context.allocator) -> (entry: Format_Entry, framing: Framing, ok: bool) {
	if len(src) == 0 {
		return {}, .Single, false
	}
	bom := spell.bom_length(src)
	// Binary / non-UTF-8 / high-major CBOR check before text heuristics.
	if bom == 0 && looks_binary_cbor(src) {
		if is_valid_cbor(src, allocator) {
			return entry_of_detect(.Cbor, cbor_framing(src, allocator))
		}
	}

	// Skip UTF-8 BOM and leading ASCII whitespace.
	p := bom
	for p < len(src) && is_ascii_ws(src[p]) {
		p += 1
	}
	if p >= len(src) {
		return {}, .Single, false
	}

	first := src[p]
	// RFC 7464 Record Separator leading a JSON text sequence.
	if first == 0x1E {
		if valid_json_records(src, .Seq, .Json, allocator) {
			return entry_of_detect(.Json, .Seq)
		}
		if valid_json_records(src, .Seq, .Jsonc, allocator) {
			return entry_of_detect(.Jsonc, .Seq)
		}
		if valid_json_records(src, .Seq, .Json5, allocator) {
			return entry_of_detect(.Json5, .Seq)
		}
	}

	// XML starts with `<` (declaration, comment, DOCTYPE, processing instruction, or root element).
	if first == '<' {
		if xml.validate(src, .Xml, {}, allocator) == nil {
			return entry_of_detect(.Xml, .Single)
		}
	}

	// Leading `{`: JSON family (Single -> JSON/JSONC/JSON5, else Lines / Seq / Concatenated).
	if first == '{' {
		if e, fr, hit := detect_json_family(src, allocator); hit {
			return e, fr, true
		}
	}

	// Leading `[`: JSON array vs TOML table header `[section]` / `[[array]]`.
	if first == '[' {
		if e, fr, hit := detect_json_family(src, allocator); hit {
			return e, fr, true
		}
		if toml.validate(src, .Toml_1_0, {}, allocator) == nil {
			return entry_of_detect(.Toml_1_0, .Single)
		}
		if toml.validate(src, .Toml_1_1, {}, allocator) == nil {
			return entry_of_detect(.Toml_1_1, .Single)
		}
	}

	// Leading `//` or `/*`: JSONC / JSON5.
	if first == '/' && p + 1 < len(src) && (src[p + 1] == '/' || src[p + 1] == '*') {
		if e, fr, hit := detect_json_family(src, allocator); hit {
			return e, fr, true
		}
	}

	// Leading `#`: TOML comment (or `#` DSV comment).
	if first == '#' {
		if toml.validate(src, .Toml_1_0, {}, allocator) == nil {
			return entry_of_detect(.Toml_1_0, .Single)
		}
		if toml.validate(src, .Toml_1_1, {}, allocator) == nil {
			return entry_of_detect(.Toml_1_1, .Single)
		}
	}

	// Check JSON scalar / multi-record text before TOML/DSV (e.g. `123`, `"abc"`, `true`).
	if first == '"' || first == '\'' || (first >= '0' && first <= '9') || first == '-' || first == '+' || first == '.' {
		if e, fr, hit := detect_json_family(src, allocator); hit {
			return e, fr, true
		}
	}
	if first == 't' || first == 'f' || first == 'n' || first == 'I' || first == 'N' {
		if e, fr, hit := detect_json_family(src, allocator); hit {
			return e, fr, true
		}
	}

	// Check TOML (key = value assignments or section headers past leading ws).
	if looks_like_toml(src[p:]) {
		if toml.validate(src, .Toml_1_0, {}, allocator) == nil {
			return entry_of_detect(.Toml_1_0, .Single)
		}
		if toml.validate(src, .Toml_1_1, {}, allocator) == nil {
			return entry_of_detect(.Toml_1_1, .Single)
		}
	}

	// Check TSV / CSV by unquoted delimiter presence on the header / lines.
	if dsv_id, hit := detect_dsv_spec(src[p:]); hit {
		if e, fr, ok_d := entry_of_detect(dsv_id, .Lines); ok_d && dsv.validate(src, e.spec.(dsv.Spec), {}, allocator) == nil {
			return e, fr, true
		}
	}

	// Fallback loose JSON5 check (e.g. bare identifier keys on line 2+).
	if e, fr, hit := detect_json_family(src, allocator); hit {
		return e, fr, true
	}
	return {}, .Single, false
}

@(private = "file")
entry_of_detect :: proc "contextless" (id: Format_Id, f: Framing) -> (Format_Entry, Framing, bool) {
	e, ok := entry_of_id(id)
	return e, f, ok
}

@(private = "file")
is_ascii_ws :: proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

@(private = "file")
looks_binary_cbor :: proc "contextless" (src: []u8) -> bool #no_bounds_check {
	if len(src) == 0 {
		return false
	}
	// Non-UTF-8 bytes or non-whitespace ASCII control bytes strongly signal binary data;
	// printable UTF-8 ASCII text (e.g. `//`, `#`, ` `) must go through text detectors.
	has_ctrl := false
	for b in src[:min(len(src), 256)] {
		if b < 0x20 && b != '\t' && b != '\n' && b != '\r' && b != 0x1E {
			has_ctrl = true
			break
		}
	}
	if has_ctrl {
		return true
	}
	utf_len := min(len(src), 512)
	if utf_len < len(src) && (src[utf_len] & 0xC0) == 0x80 {
		// Rewind at most 3 continuation bytes to trim only a valid multi-byte UTF-8 rune split at byte 512.
		for step in 1 ..= min(utf_len, 3) {
			b := src[utf_len - step]
			if b >= 0xC2 && b <= 0xF4 {
				seq_len := 2 if b < 0xE0 else (3 if b < 0xF0 else 4)
				if utf_len - step + seq_len > utf_len {
					utf_len -= step
				}
				break
			}
			if (b & 0xC0) != 0x80 {
				break
			}
		}
	}
	if utf_len == 0 {
		return true
	}
	return !utf8.valid_string(string(src[:utf_len]))
}

@(private = "file")
is_valid_cbor :: proc(src: []u8, allocator: runtime.Allocator) -> bool {
	if cbor.validate(src, .Cbor, {}, allocator) == nil {
		return true
	}
	r := cbor.records_open(src, .Concatenated, .Cbor)
	defer tape.destroy_records(&r)
	if r.err != nil {
		return false
	}
	rec: [8]tape.Record
	n := cbor.records_validate(&r, rec[:], allocator)
	return n == 0 && r.err == nil && r.index > 0
}

@(private = "file")
cbor_framing :: proc(src: []u8, allocator: runtime.Allocator) -> Framing {
	if cbor.validate(src, .Cbor, {}, allocator) == nil {
		return .Single
	}
	return .Concatenated
}

@(private = "file")
detect_json_family :: proc(src: []u8, allocator: runtime.Allocator) -> (entry: Format_Entry, framing: Framing, ok: bool) {
	// Fast scan for RFC 7464 RS separator anywhere early.
	for i in 0 ..< min(len(src), 64) {
		if src[i] == 0x1E {
			if valid_json_records(src, .Seq, .Json, allocator) {
				return entry_of_detect(.Json, .Seq)
			}
		}
	}
	if json.validate(src, .Json, {}, allocator) == nil {
		return entry_of_detect(.Json, .Single)
	}
	if json.validate(src, .Jsonc, {}, allocator) == nil {
		return entry_of_detect(.Jsonc, .Single)
	}
	if json.validate(src, .Json5, {}, allocator) == nil {
		return entry_of_detect(.Json5, .Single)
	}
	if valid_json_records(src, .Lines, .Json, allocator) {
		return entry_of_detect(.Json, .Lines)
	}
	if valid_json_records(src, .Lines, .Jsonc, allocator) {
		return entry_of_detect(.Jsonc, .Lines)
	}
	if valid_json_records(src, .Lines, .Json5, allocator) {
		return entry_of_detect(.Json5, .Lines)
	}
	if valid_json_records(src, .Concatenated, .Json, allocator) {
		return entry_of_detect(.Json, .Concatenated)
	}
	if valid_json_records(src, .Concatenated, .Jsonc, allocator) {
		return entry_of_detect(.Jsonc, .Concatenated)
	}
	if valid_json_records(src, .Concatenated, .Json5, allocator) {
		return entry_of_detect(.Json5, .Concatenated)
	}
	return {}, .Single, false
}

@(private = "file")
valid_json_records :: proc(src: []u8, framing: tape.Framing, spec: json.Spec, allocator: runtime.Allocator) -> bool {
	r := json.records_open(src, framing, spec)
	defer tape.destroy_records(&r)
	if r.err != nil {
		return false
	}
	rec: [8]tape.Record
	n := json.records_validate(&r, rec[:], allocator)
	return n == 0 && r.err == nil && r.index > 0
}

@(private = "file")
looks_like_toml :: proc "contextless" (s: []u8) -> bool {
	// Look on first few non-empty lines for `=` outside quotes or `[section]`.
	line := string(s[:min(len(s), 1024)])
	in_q: u8
	for idx := 0; idx < len(line); idx += 1 {
		c := line[idx]
		if in_q == 0 {
			if c == '"' || c == '\'' {
				in_q = c
			} else if c == '=' || c == '[' {
				return true
			} else if c == '\n' {
				break
			}
		} else if c == in_q && (in_q == '\'' || idx == 0 || line[idx - 1] != '\\') {
			in_q = 0
		}
	}
	return strings.index_byte(line, '=') >= 0
}

@(private = "file")
detect_dsv_spec :: proc "contextless" (s: []u8) -> (id: Format_Id, ok: bool) {
	tabs, commas := 0, 0
	in_quote := false
	limit := min(len(s), 4096)
	for i := 0; i < limit; i += 1 {
		c := s[i]
		if c == '"' {
			in_quote = !in_quote
			continue
		}
		if in_quote {
			continue
		}
		if c == '\t' {
			tabs += 1
		} else if c == ',' {
			commas += 1
		}
	}
	if tabs > 0 && tabs >= commas {
		return .Tsv, true
	}
	if commas > 0 {
		return .Csv, true
	}
	return {}, false
}
