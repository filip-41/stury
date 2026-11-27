package rules

import "core:strings"
import "core:unicode/utf8"
import "stury:lib/base/spell"

Uri :: struct {
	scheme, authority, path, query, fragment: string,
	has_scheme, has_authority, has_query:     bool,
}

uri_split :: proc(s: string) -> (u: Uri) {
	rest := s
	if i := strings.index_byte(rest, '#'); i >= 0 { u.fragment, rest = rest[i + 1:], rest[:i] }
	if i := strings.index_byte(rest, '?'); i >= 0 { u.query, u.has_query, rest = rest[i + 1:], true, rest[:i] }
	if i := strings.index_any(rest, ":/"); i > 0 && rest[i] == ':' { u.scheme, u.has_scheme, rest = rest[:i], true, rest[i + 1:] }
	if strings.has_prefix(rest, "//") {
		end := strings.index_byte(rest[2:], '/')
		end = len(rest) if end < 0 else end + 2
		u.authority, u.has_authority, rest = rest[2:end], true, rest[end:]
	}
	u.path = rest
	return
}

@(private)
ucschar :: proc "contextless" (r: rune) -> bool {
	return r >= 0xA0 && r <= 0xD7FF || r >= 0xF900 && r <= 0xFDCF || r >= 0xFDF0 && r <= 0xFFEF || r >= 0x10000 && r <= 0xEFFFD && !(r >= 0xE0000 && r < 0xE1000) && r & 0xFFFF < 0xFFFE
}

@(private)
iprivate :: proc "contextless" (r: rune) -> bool {
	return r >= 0xE000 && r <= 0xF8FF || r >= 0xF0000 && r <= 0xFFFFD || r >= 0x100000 && r <= 0x10FFFD
}

@(private)
escape_at :: proc "contextless" (s: string, i: int) -> bool {
	return i + 2 < len(s) && spell.HEX_NIBBLE[s[i + 1]] < 16 && spell.HEX_NIBBLE[s[i + 2]] < 16
}

@(private)
uri_part_valid :: proc(s, extra: string, iri, private: bool) -> bool {
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c >= 0x80:
			r, n := utf8.decode_rune_in_string(s[i:])
			if !iri || !(ucschar(r) || private && iprivate(r)) { return false }
			i += n; continue
		case c == '%':
			if !escape_at(s, i) { return false }
			i += 2
		case c >= '0' && c <= '9', c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z':
		case strings.contains_rune("-._~!$&'()*+,;=", rune(c)) || strings.contains_rune(extra, rune(c)):
		case: return false
		}
		i += 1
	}
	return true
}

@(private)
authority_valid :: proc(a: string, iri: bool) -> bool {
	host, port := a, ""
	if at := strings.index_byte(a, '@'); at >= 0 {
		uri_part_valid(a[:at], ":", iri, false) or_return
		host = a[at + 1:]
	}
	if strings.has_prefix(host, "[") {
		end := strings.index_byte(host, ']')
		if end < 0 { return false }
		inner := host[1:end]
		host, port = "", host[end + 1:]
		if inner != "" && inner[0] | 0x20 == 'v' {
			v := inner[1:]
			dot := strings.index_byte(v, '.')
			if dot < 1 || !all_hex(v[:dot]) || dot + 1 == len(v) || !uri_part_valid(v[dot + 1:], ":", false, false) || strings.contains_rune(v, '%') { return false }
		} else if !ipv6_valid(inner) {
			return false
		}
		if port != "" && port[0] != ':' { return false }
		port = port[min(1, len(port)):]
	} else if colon := strings.index_byte(host, ':'); colon >= 0 {
		host, port = host[:colon], host[colon + 1:]
	}
	return digits(port) == len(port) && uri_part_valid(host, "", iri, false)
}

@(private)
uri_valid :: proc(s: string, iri, relative: bool) -> bool {
	u := uri_split(s)
	if !relative && !u.has_scheme { return false }
	if u.has_scheme {
		for c, i in transmute([]u8)u.scheme {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || i > 0 && (c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.')) { return false }
		}
	} else if !u.has_authority {
		first := u.path[:strings.index_byte(u.path, '/')] if strings.contains_rune(u.path, '/') else u.path
		if strings.contains_rune(first, ':') { return false }
	}
	if u.has_authority && !authority_valid(u.authority, iri) { return false }
	return uri_part_valid(u.path, ":@/", iri, false) && uri_part_valid(u.query, ":@/?", iri, true) && uri_part_valid(u.fragment, ":@/?", iri, false)
}

@(private)
template_valid :: proc(s: string) -> bool {
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == '{':
			end := strings.index_byte(s[i:], '}')
			if end < 0 || !expression_valid(s[i + 1:i + end]) { return false }
			i += end
		case c >= 0x80:
			r, n := utf8.decode_rune_in_string(s[i:])
			if !ucschar(r) && !iprivate(r) { return false }
			i += n; continue
		case c == '%':
			if !escape_at(s, i) { return false }
			i += 2
		case c <= ' ', c == 0x7F, strings.contains_rune("\"'<>\\^`|}", rune(c)):
			return false
		}
		i += 1
	}
	return true
}

@(private)
expression_valid :: proc(e: string) -> bool {
	list := e
	if list != "" && strings.contains_rune("+#./;?&", rune(list[0])) { list = list[1:] }
	count := 0
	for spec in strings.split_iterator(&list, ",") {
		varspec_valid(spec) or_return
		count += 1
	}
	return count > 0 && !strings.has_suffix(e, ",")
}

@(private)
varspec_valid :: proc(v: string) -> bool {
	name := v
	if colon := strings.index_byte(v, ':'); colon >= 0 {
		name = v[:colon]
		if n, ok := decimal_u64(v[colon + 1:]); !ok || n < 1 || n > 9999 || v[colon + 1] == '0' { return false }
	} else if strings.has_suffix(v, "*") {
		name = v[:len(v) - 1]
	}
	if name == "" || name[0] == '.' || name[len(name) - 1] == '.' || strings.contains(name, "..") { return false }
	for i := 0; i < len(name); i += 1 {
		c := name[i]
		switch {
		case c >= '0' && c <= '9', c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c == '_', c == '.':
		case c == '%' && escape_at(name, i): i += 2
		case: return false
		}
	}
	return true
}
