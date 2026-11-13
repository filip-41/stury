package jq

// Builtins beyond jq that read structure out of a string: URLs, query strings, logfmt lines and JSON Pointers.

import "core:strings"
import "../../../core/spell"

@(private = "file")
must_be_text :: proc(ip: ^Interp, name: string, v: Value) -> (string, Signal) {
	s, ok := string_of(v)
	if !ok {
		return "", fail(ip, "%s (%s) cannot be parsed by %s, only a string", type_name(v), brief(ip, v), name)
	}
	return s, .Go
}

// parse_url: a URL reference by RFC 3986 section 3 as {scheme, user, host, port, path, query, fragment}. What the URL
// leaves out is null, except the path, which is "" when empty. `user` is the userinfo as written, a password
// included, `host` an IPv6 literal without its brackets, `port` a number, and nothing is percent-decoded.
fn_parse_url :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (result: Value, sig: Signal) {
	url := must_be_text(ip, name, v) or_return
	for c in transmute([]byte)url {
		if c <= ' ' || c == 0x7F {
			return nil, fail(ip, "string (%s) is not a URL: it holds a space or a control character", brief(ip, url))
		}
	}
	out := new_object()
	rest := url
	fragment, query, scheme, user, host, port: Value
	if i := strings.index_byte(rest, '#'); i >= 0 {
		fragment, rest = rest[i + 1:], rest[:i]
	}
	if i := strings.index_byte(rest, '?'); i >= 0 {
		query, rest = rest[i + 1:], rest[:i]
	}
	if i := strings.index_any(rest, ":/"); i > 0 && rest[i] == ':' && is_url_scheme(rest[:i]) {
		scheme, rest = rest[:i], rest[i + 1:]
	}
	if strings.has_prefix(rest, "//") {
		end := strings.index_byte(rest[2:], '/')
		end = len(rest) if end < 0 else end + 2
		authority := rest[2:end]
		rest = rest[end:]
		if at := strings.last_index_byte(authority, '@'); at >= 0 {
			user, authority = authority[:at], authority[at + 1:]
		}
		port_text := ""
		if strings.has_prefix(authority, "[") {
			close := strings.index_byte(authority, ']')
			after := authority[close + 1:] if close >= 0 else "?"
			if close < 0 || after != "" && after[0] != ':' {
				return nil, fail(ip, "string (%s) is not a URL: its host is a bad IP literal", brief(ip, url))
			}
			host, port_text = authority[1:close], after[1:] if after != "" else ""
		} else if colon := strings.last_index_byte(authority, ':'); colon >= 0 {
			host, port_text = authority[:colon], authority[colon + 1:]
		} else {
			host = authority
		}
		if port_text != "" {
			n := 0
			for c in transmute([]byte)port_text {
				n = n * 10 + int(c - '0')
				if c < '0' || c > '9' || n > 65535 {
					return nil, fail(ip, "string (%s) is not a URL: its port is not a number up to 65535", brief(ip, url))
				}
			}
			port = num(f64(n))
		}
	}
	object_put(out, "scheme", scheme)
	object_put(out, "user", user)
	object_put(out, "host", host)
	object_put(out, "port", port)
	object_put(out, "path", rest)
	object_put(out, "query", query)
	object_put(out, "fragment", fragment)
	return out, .Go
}

@(private = "file")
is_url_scheme :: proc(s: string) -> bool {
	for c, i in transmute([]byte)s {
		alpha := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
		if !alpha && (i == 0 || !(c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.')) {
			return false
		}
	}
	return true
}

// parse_query_string: `name=value` pairs split at `&` as the WHATWG URL standard reads application/x-www-form-urlencoded,
// into an object of strings. A leading `?` is skipped, `+` is a space, `%XX` is a byte (a malformed one stays as
// written), a name without `=` has the value "", and a name that repeats becomes an array of its values in order.
fn_parse_query_string :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (result: Value, sig: Signal) {
	rest := strings.trim_prefix(must_be_text(ip, name, v) or_return, "?")
	out := new_object()
	for pair in strings.split_iterator(&rest, "&") {
		if pair == "" {
			continue
		}
		key, _, value := strings.partition(pair, "=")
		key = decode_form_component(key)
		value = decode_form_component(value)
		i := object_slot(out, key)
		if i < 0 {
			object_put(out, key, value)
		} else if values, repeated := out.vals[i].(^Array); repeated {
			append(&values.items, value)
		} else {
			values = new_array(2)
			append(&values.items, out.vals[i], value)
			out.vals[i] = values
		}
	}
	return out, .Go
}

@(private = "file")
decode_form_component :: proc(s: string) -> string {
	if strings.index_any(s, "+%") < 0 {
		return s
	}
	b := make([dynamic]byte, 0, len(s))
	for i := 0; i < len(s); i += 1 {
		switch {
		case s[i] == '+':
			append(&b, ' ')
		case s[i] == '%' && i + 2 < len(s) && spell.HEX_NIBBLE[s[i + 1]] | spell.HEX_NIBBLE[s[i + 2]] <= 15:
			append(&b, spell.HEX_NIBBLE[s[i + 1]] << 4 | spell.HEX_NIBBLE[s[i + 2]])
			i += 2
		case:
			append(&b, s[i])
		}
	}
	return valid_utf8(string(b[:]))
}

// parse_logfmt: a line of `key=value` pairs separated by white space, as the Heroku logfmt that go-logfmt reads, into
// an object of strings. A bare key is true, `key=` is "", a value in double quotes may hold white space and the
// escapes `\"`, `\\`, `\n`, `\r` and `\t`, and a key that repeats keeps its last value.
fn_parse_logfmt :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (result: Value, sig: Signal) {
	line := must_be_text(ip, name, v) or_return
	out := new_object()
	is_space :: proc(c: byte) -> bool {
		return c == ' ' || c == '\t' || c == '\n' || c == '\r'
	}
	for i := 0; i < len(line); {
		if is_space(line[i]) {
			i += 1
			continue
		}
		start := i
		for i < len(line) && !is_space(line[i]) && line[i] != '=' && line[i] != '"' {
			i += 1
		}
		key := line[start:i]
		if key == "" {
			return nil, fail(ip, "logfmt: unexpected %s at byte %d", line[i:i + 1], i)
		}
		if i >= len(line) || is_space(line[i]) {
			object_put(out, key, true)
			continue
		}
		if line[i] == '"' {
			return nil, fail(ip, "logfmt: unexpected \" at byte %d", i)
		}
		i += 1 // past the =
		if i < len(line) && line[i] == '"' {
			i += 1
			text := make([dynamic]byte, 0, 16)
			closed := false
			for ; i < len(line) && !closed; i += 1 {
				switch c := line[i]; c {
				case '"':
					closed = true
				case '\\':
					i += 1
					escaped := line[i] if i < len(line) else 0
					switch escaped {
					case '"', '\\':
						append(&text, escaped)
					case 'n':
						append(&text, '\n')
					case 'r':
						append(&text, '\r')
					case 't':
						append(&text, '\t')
					case:
						return nil, fail(ip, "logfmt: unknown escape in the value of %s", key)
					}
				case:
					append(&text, c)
				}
			}
			if !closed {
				return nil, fail(ip, "logfmt: the quoted value of %s is not closed", key)
			}
			object_put(out, key, valid_utf8(string(text[:])))
			continue
		}
		start = i
		for i < len(line) && !is_space(line[i]) {
			i += 1
		}
		object_put(out, key, line[start:i])
	}
	return out, .Go
}

// json_pointer(ptr): the value RFC 6901's pointer names in the input. `~1` is `/` and `~0` is `~` in a token, a
// token of an array is its index, and what is not there is null, as `getpath` gives.
fn_json_pointer :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	pointer, is_str := string_of(args[0])
	if !is_str || pointer != "" && pointer[0] != '/' {
		return nil, fail(ip, "json_pointer: %s is not a JSON Pointer", brief(ip, args[0]))
	}
	cur := v
	rest := pointer
	for len(rest) > 0 {
		rest = rest[1:]
		end := strings.index_byte(rest, '/')
		token := rest if end < 0 else rest[:end]
		rest = "" if end < 0 else rest[end:]
		if strings.contains(token, "~") {
			unescaped, _ := strings.replace_all(token, "~1", "/", context.temp_allocator)
			unescaped, _ = strings.replace_all(unescaped, "~0", "~", context.temp_allocator)
			token = unescaped
		}
		step: Value = token
		if kind(cur) == .Array {
			if token == "" || len(token) > 1 && token[0] == '0' {
				return nil, .Go
			}
			index := 0
			for c in transmute([]byte)token {
				index = index * 10 + int(c - '0')
				if c < '0' || c > '9' || index > 1 << 31 {
					return nil, .Go
				}
			}
			step = num(f64(index))
		}
		sig: Signal
		if cur, sig = index_value(ip, cur, step); sig != .Go {
			return nil, sig
		}
	}
	return cur, .Go
}
