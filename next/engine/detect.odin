package engine

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"
import "stury:cbor"
import "stury:dsv"
import "stury:html"
import "stury:json"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:msgpack"
import "stury:toml"
import "stury:xml"
import "stury:yaml"

// Format detection by file path (extension with optional trailing compression suffix)
// and by content inspection (magic bytes / leading grammar heuristics).

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
	{"gz", .Gzip}, {"gzip", .Gzip}, {"zst", .Zstd}, {"zstd", .Zstd},
	{"bz2", .Bzip2}, {"xz", .Xz}, {"lz4", .Lz4}, {"br", .Brotli},
}

@(private = "file")
path_ext_bounds :: proc "contextless" (path: string) -> (base_start, last_dot: int) {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			base_start = i + 1
			break
		}
	}
	last_dot = -1
	for i := len(path) - 1; i > base_start; i -= 1 {
		if path[i] == '.' {
			last_dot = i
			break
		}
	}
	return
}

// Strips a trailing compression suffix (case-insensitive) when preceded by another extension.
strip_compression_suffix :: proc "contextless" (path: string) -> (stripped: string, comp: Compression_Kind) {
	base_start, last_dot := path_ext_bounds(path)
	if last_dot <= base_start {
		return path, .None
	}
	ext := path[last_dot + 1:]
	for s in COMP_SUFFIXES {
		if ascii_eq_fold(ext, s.ext) {
			_, inner_dot := path_ext_bounds(path[:last_dot])
			return path[:last_dot] if inner_dot > base_start else path, s.kind
		}
	}
	return path, .None
}

// Maps a file path (stripping known compression suffixes) to its `Format_Entry` and default `Framing`.
format_of_path :: proc "contextless" (path: string) -> (entry: Format_Entry, framing: Framing, ok: bool) {
	clean, _ := strip_compression_suffix(path)
	base_start, dot := path_ext_bounds(clean)
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
				f := json_framing_for_tag(ext, e.default_framing) if m.id == .Json else e.default_framing
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
	if bom == 0 && looks_binary_cbor(src) {
		if fr, cok := detect_cbor(src, allocator); cok {
			return entry_of_detect(.Cbor, fr)
		}
		if fr, mok := detect_msgpack(src, allocator); mok {
			return entry_of_detect(.Msgpack, fr)
		}
	}

	p := bom
	for p < len(src) && is_ascii_ws(src[p]) {
		p += 1
	}
	if p >= len(src) {
		return {}, .Single, false
	}

	first := src[p]
	if first == 0x1E {
		for sp in ([3]struct{id: Format_Id, js: json.Spec}{{.Json, .Json}, {.Jsonc, .Jsonc}, {.Json5, .Json5}}) {
			if valid_json_records(src, .Seq, sp.js, allocator) {
				return entry_of_detect(sp.id, .Seq)
			}
		}
	}

	if first == '<' {
		if looks_like_html(src[p:]) && html.validate(src, .Html, {}, allocator) == nil {
			return entry_of_detect(.Html, .Single)
		}
		if xml.validate(src, .Xml, {}, allocator) == nil {
			return entry_of_detect(.Xml, .Single)
		}
	}

	if (first == '%' || first == '-') && looks_like_yaml_marker(src[p:]) {
		if yaml.validate(src, .Yaml_1_2, {}, allocator) == nil {
			return entry_of_detect(.Yaml, yaml_framing(src, allocator))
		}
	}

	if first == '{' || (first == '/' && p + 1 < len(src) && (src[p + 1] == '/' || src[p + 1] == '*')) {
		if e, fr, hit := detect_json_family(src, allocator); hit {
			return e, fr, true
		}
	}

	if first == '[' {
		if e, fr, hit := detect_json_family(src, allocator); hit {
			return e, fr, true
		}
		if e, fr, hit := detect_toml(src, allocator); hit {
			return e, fr, true
		}
	}

	if first == '#' {
		if e, fr, hit := detect_toml(src, allocator); hit {
			return e, fr, true
		}
	}

	if first == '"' || first == '\'' || (first >= '0' && first <= '9') || first == '-' || first == '+' || first == '.' ||
	   first == 't' || first == 'f' || first == 'n' || first == 'I' || first == 'N' {
		if e, fr, hit := detect_json_family(src, allocator); hit {
			return e, fr, true
		}
	}

	if looks_like_toml(src[p:]) {
		if e, fr, hit := detect_toml(src, allocator); hit {
			return e, fr, true
		}
	}

	if dsv_id, hit := detect_dsv_spec(src[p:]); hit {
		if e, fr, ok_d := entry_of_detect(dsv_id, .Lines); ok_d && dsv.validate(src, e.spec.(dsv.Spec), {}, allocator) == nil {
			return e, fr, true
		}
	}

	return detect_json_family(src, allocator)
}

@(private = "file")
entry_of_detect :: proc "contextless" (id: Format_Id, f: Framing) -> (Format_Entry, Framing, bool) {
	e, ok := entry_of_id(id)
	return e, f, ok
}

@(private = "file")
detect_toml :: proc(src: []u8, allocator: runtime.Allocator) -> (Format_Entry, Framing, bool) {
	if toml.validate(src, .Toml_1_0, {}, allocator) == nil {
		return entry_of_detect(.Toml_1_0, .Single)
	}
	if toml.validate(src, .Toml_1_1, {}, allocator) == nil {
		return entry_of_detect(.Toml_1_1, .Single)
	}
	return {}, .Single, false
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
	for b in src[:min(len(src), 256)] {
		if b < 0x20 && b != '\t' && b != '\n' && b != '\r' && b != 0x0B && b != 0x0C && b != 0x1E {
			return true
		}
	}
	utf_len := min(len(src), 512)
	if utf_len < len(src) && (src[utf_len] & 0xC0) == 0x80 {
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
	return utf_len == 0 || !utf8.valid_string(string(src[:utf_len]))
}

@(private = "file")
detect_cbor :: proc(src: []u8, allocator: runtime.Allocator) -> (Framing, bool) {
	if cbor.validate(src, .Cbor, {}, allocator) == nil {
		return .Single, true
	}
	r := cbor.records_open(src, .Concatenated, .Cbor)
	defer tape.destroy_records(&r)
	if r.err != nil {
		return .Single, false
	}
	rec: [8]tape.Record
	n := cbor.records_validate(&r, rec[:], allocator)
	return .Concatenated, n == 0 && r.err == nil && r.index > 0
}

@(private = "file")
detect_msgpack :: proc(src: []u8, allocator: runtime.Allocator) -> (Framing, bool) {
	if msgpack.validate(src, .Msgpack, {}, allocator) == nil {
		return .Single, true
	}
	has_high := false
	for b in src[:min(len(src), 256)] {
		if b >= 0x80 {
			has_high = true
			break
		}
	}
	if !has_high {
		return .Single, false
	}
	r := msgpack.records_open(src, .Concatenated, .Msgpack)
	defer tape.destroy_records(&r)
	if r.err != nil {
		return .Single, false
	}
	rec: [8]tape.Record
	n := msgpack.records_validate(&r, rec[:], allocator)
	return .Concatenated, n == 0 && r.err == nil && r.index > 0
}

@(private = "file")
looks_like_html :: proc "contextless" (s: []u8) -> bool {
	if len(s) >= 14 && ascii_eq_fold(string(s[:14]), "<!doctype html") {
		return len(s) == 14 || is_ascii_ws(s[14]) || s[14] == '>'
	}
	if len(s) >= 5 && ascii_eq_fold(string(s[:5]), "<html") {
		return len(s) == 5 || is_ascii_ws(s[5]) || s[5] == '>' || s[5] == '/'
	}
	return false
}

@(private = "file")
looks_like_yaml_marker :: proc "contextless" (s: []u8) -> bool {
	if len(s) >= 6 && string(s[:5]) == "%YAML" && (s[5] == ' ' || s[5] == '\t') {
		return true
	}
	if len(s) >= 3 && s[0] == '-' && s[1] == '-' && s[2] == '-' {
		if len(s) == 3 || s[3] == '\n' || s[3] == '\r' {
			return true
		}
		if s[3] == ' ' || s[3] == '\t' {
			i := 3
			for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
				i += 1
			}
			return i >= len(s) || s[i] != '='
		}
	}
	return false
}

@(private = "file")
yaml_framing :: proc(src: []u8, allocator: runtime.Allocator) -> Framing {
	r := yaml.records_open(src, .Concatenated, .Yaml_1_2)
	defer tape.destroy_records(&r)
	if r.err != nil {
		return .Single
	}
	rec: [4]tape.Record
	_ = yaml.records_validate(&r, rec[:], allocator)
	return .Concatenated if r.index > 1 else .Single
}

@(private = "file")
detect_json_family :: proc(src: []u8, allocator: runtime.Allocator) -> (entry: Format_Entry, framing: Framing, ok: bool) {
	for b in src[:min(len(src), 64)] {
		if b == 0x1E && valid_json_records(src, .Seq, .Json, allocator) {
			return entry_of_detect(.Json, .Seq)
		}
	}
	specs := [3]struct{id: Format_Id, js: json.Spec}{{.Json, .Json}, {.Jsonc, .Jsonc}, {.Json5, .Json5}}
	for sp in specs {
		if json.validate(src, sp.js, {}, allocator) == nil {
			return entry_of_detect(sp.id, .Single)
		}
	}
	for fr in ([2]struct{tf: tape.Framing, f: Framing}{{.Lines, .Lines}, {.Concatenated, .Concatenated}}) {
		for sp in specs {
			if valid_json_records(src, fr.tf, sp.js, allocator) {
				return entry_of_detect(sp.id, fr.f)
			}
		}
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
	for c in s[:min(len(s), 4096)] {
		if c == '"' {
			in_quote = !in_quote
		} else if !in_quote {
			if c == '\t' {
				tabs += 1
			} else if c == ',' {
				commas += 1
			}
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
