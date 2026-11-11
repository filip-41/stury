package schema

import "core:encoding/hex"
import "core:strings"
import "../rules"

// `ref` resolved against `base` as RFC 3986 section 5.2 says, in the context's allocator. `base` is absolute or empty.
// The result is in the normal form of section 6.2.2, so that two spellings of one URI name one resource: the scheme and
// the host in lower case, each escape of an unreserved character undone and the other escapes in upper case.
@(private)
uri_resolve :: proc(base, ref: string) -> string {
	r, b := rules.uri_split(ref), rules.uri_split(base)
	t := r
	if !r.has_scheme {
		t.scheme, t.has_scheme = b.scheme, b.has_scheme
		if !r.has_authority {
			t.authority, t.has_authority = b.authority, b.has_authority
			switch {
			case r.path == "":
				t.path = b.path
				if !r.has_query {
					t.query, t.has_query = b.query, b.has_query
				}
			case r.path[0] == '/':
			case b.has_authority && b.path == "":
				t.path = strings.concatenate({"/", r.path})
			case:
				cut := strings.last_index_byte(b.path, '/') + 1
				t.path = strings.concatenate({b.path[:cut], r.path})
			}
		}
	}
	authority := normal_escapes(t.authority)
	host := strings.last_index_byte(authority, '@') + 1
	return strings.concatenate(
		{
			strings.to_lower(t.scheme),
			":" if t.has_scheme else "",
			"//" if t.has_authority else "",
			authority[:host],
			strings.to_lower(authority[host:]),
			remove_dots(normal_escapes(t.path)),
			"?" if t.has_query else "",
			normal_escapes(t.query),
			"#" if t.fragment != "" else "",
			normal_escapes(t.fragment),
		},
	)
}

// `part` with each `%XX` escape of an unreserved character undone and the hex digits of the other escapes in upper case.
// A `%` not followed by two hex digits stays as it is.
@(private)
normal_escapes :: proc(part: string) -> string {
	if strings.index_byte(part, '%') < 0 {
		return part
	}
	out := make([dynamic]u8, 0, len(part))
	for i := 0; i < len(part); i += 1 {
		b, ok := u8(0), false
		if part[i] == '%' && i + 2 < len(part) {
			b, ok = hex.decode_sequence(part[i + 1:i + 3])
		}
		switch {
		case !ok:
			append(&out, part[i])
			continue
		case 'A' <= b && b <= 'Z', 'a' <= b && b <= 'z', '0' <= b && b <= '9', b == '-', b == '.', b == '_', b == '~':
			append(&out, b)
		case:
			append(&out, '%', upper_hex(part[i + 1]), upper_hex(part[i + 2]))
		}
		i += 2
	}
	return string(out[:])
}

@(private)
upper_hex :: proc(c: u8) -> u8 {
	return c - 'a' + 'A' if 'a' <= c && c <= 'f' else c
}

// RFC 3986 section 5.2.4: drops the `.` segments and each `..` with the segment before it.
@(private)
remove_dots :: proc(path: string) -> string {
	if strings.index_byte(path, '.') < 0 {
		return path
	}
	out := make([dynamic]u8, 0, len(path))
	rest := path
	for rest != "" {
		switch {
		case strings.has_prefix(rest, "../"):
			rest = rest[3:]
		case strings.has_prefix(rest, "./"):
			rest = rest[2:]
		case strings.has_prefix(rest, "/./"):
			rest = rest[2:]
		case rest == "/." || rest == "." || rest == "..":
			rest = "/" if rest == "/." else ""
		case strings.has_prefix(rest, "/../") || rest == "/..":
			rest = "/" if rest == "/.." else rest[3:]
			resize(&out, max(strings.last_index_byte(string(out[:]), '/'), 0))
		case:
			end := strings.index_byte(rest[1:], '/')
			end = len(rest) if end < 0 else end + 1
			append(&out, rest[:end])
			rest = rest[end:]
		}
	}
	return string(out[:])
}

// Undoes `%XX` escapes. False for a `%` not followed by two hex digits.
@(private)
percent_decode :: proc(s: string) -> (string, bool) {
	if strings.index_byte(s, '%') < 0 {
		return s, true
	}
	out := make([dynamic]u8, 0, len(s))
	for i := 0; i < len(s); i += 1 {
		if s[i] != '%' {
			append(&out, s[i])
			continue
		}
		if i + 2 >= len(s) {
			return "", false
		}
		b, ok := hex.decode_sequence(s[i + 1:i + 3])
		if !ok {
			return "", false
		}
		append(&out, b)
		i += 2
	}
	return string(out[:]), true
}

// Whether `s` is an anchor name: a letter or `_`, then letters, digits, `-`, `_` and `.`.
@(private)
is_anchor :: proc(s: string) -> bool {
	for c, i in transmute([]u8)s {
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '_':
		case '0' ..= '9', '-', '.':
			if i == 0 {
				return false
			}
		case:
			return false
		}
	}
	return s != ""
}
