package schema

import "core:encoding/hex"
import "core:strings"

// A URI reference split at its delimiters, as RFC 3986 names the parts.
@(private)
Uri :: struct {
	scheme, authority, path, query, fragment: string,
	has_scheme, has_authority, has_query:     bool,
}

@(private)
uri_split :: proc(s: string) -> (u: Uri) {
	rest := s
	if i := strings.index_byte(rest, '#'); i >= 0 {
		u.fragment, rest = rest[i + 1:], rest[:i]
	}
	if i := strings.index_byte(rest, '?'); i >= 0 {
		u.query, u.has_query, rest = rest[i + 1:], true, rest[:i]
	}
	if i := strings.index_any(rest, ":/"); i > 0 && rest[i] == ':' {
		u.scheme, u.has_scheme, rest = rest[:i], true, rest[i + 1:]
	}
	if strings.has_prefix(rest, "//") {
		end := strings.index_byte(rest[2:], '/')
		end = len(rest) if end < 0 else end + 2
		u.authority, u.has_authority, rest = rest[2:end], true, rest[end:]
	}
	u.path = rest
	return
}

// `ref` resolved against `base` as RFC 3986 section 5.2 says, in the context's allocator. `base` is absolute or empty.
@(private)
uri_resolve :: proc(base, ref: string) -> string {
	r, b := uri_split(ref), uri_split(base)
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
	return strings.concatenate(
		{
			t.scheme,
			":" if t.has_scheme else "",
			"//" if t.has_authority else "",
			t.authority,
			remove_dots(t.path),
			"?" if t.has_query else "",
			t.query,
			"#" if t.fragment != "" else "",
			t.fragment,
		},
	)
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
