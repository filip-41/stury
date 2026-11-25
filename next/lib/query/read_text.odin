package query

import "core:strings"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"

// Texts that hold structure: URL references, query strings and logfmt lines read into objects, and JSON Pointers into
// their tokens. Every `v` below is a string, which the caller checked.

// Sets member `key` of the built object `o^` to the string `s`, or to null for none.
@(private, require_results)
put_text :: proc(h: ^Heap, o: ^Value, key: string, s: Maybe(string)) -> Status {
	x := NULL
	if text, ok := s.?; ok {
		x = text_value(h, text) or_return
	}
	return object_put(h, o, text_borrowed(key), x)
}

// The value of the decimal digits `s`, or false for none, a byte that is no digit, or a value of `limit` and more.
@(private)
decimal_below :: proc "contextless" (s: string, limit: i64) -> (n: i64, ok: bool) {
	if len(s) == 0 {
		return 0, false
	}
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n * 10 + i64(c - '0')
		if n >= limit {
			return 0, false
		}
	}
	return n, true
}

// URL reference `v` by RFC 3986 section 3 as `{scheme, user, host, port, path, query, fragment}`. What the URL leaves
// out is null, except the path, which is "" when empty. `user` is the userinfo as written, a password included, `host`
// an IPv6 literal without its brackets, `port` a number, and nothing is percent-decoded.
@(require_results)
parse_url :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	url := text_of(v)
	for c in transmute([]u8)url {
		if c <= ' ' || c == 0x7F {
			return NULL, fail(h, .Parse, .Url, v, detail = "is not a URL: it holds a space or a control character")
		}
	}
	rest := url
	fragment, query, scheme, user, host: Maybe(string)
	port := i64(-1)
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
				return NULL, fail(h, .Parse, .Url, v, detail = "is not a URL: its host is a bad IP literal")
			}
			host, port_text = authority[1:close], after[1:] if after != "" else ""
		} else if colon := strings.last_index_byte(authority, ':'); colon >= 0 {
			host, port_text = authority[:colon], authority[colon + 1:]
		} else {
			host = authority
		}
		if port_text != "" {
			n, ok := decimal_below(port_text, 65536)
			if !ok {
				return NULL, fail(h, .Parse, .Url, v, detail = "is not a URL: its port is not a number up to 65535")
			}
			port = n
		}
	}
	out := make_object(h, 7) or_return
	defer if status != .Ok {
		release(h, out)
	}
	put_text(h, &out, "scheme", scheme) or_return
	put_text(h, &out, "user", user) or_return
	put_text(h, &out, "host", host) or_return
	object_put(h, &out, text_borrowed("port"), int_value(port) if port >= 0 else NULL) or_return
	put_text(h, &out, "path", rest) or_return
	put_text(h, &out, "query", query) or_return
	put_text(h, &out, "fragment", fragment) or_return
	return out, .Ok
}

@(private)
is_url_scheme :: proc "contextless" (s: string) -> bool {
	for c, i in transmute([]u8)s {
		alpha := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
		if !alpha && (i == 0 || !(c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.')) {
			return false
		}
	}
	return true
}

// Query string `v` as an object of strings, its `name=value` pairs split at `&` as the WHATWG URL standard reads
// application/x-www-form-urlencoded. A leading `?` is skipped, `+` is a space, `%XX` is a byte (a malformed one stays
// as written), a name without `=` has the value "", and a name that repeats becomes an array of its values in order.
@(require_results)
parse_query_string :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	rest := strings.trim_prefix(text_of(v), "?")
	out := make_object(h, 0) or_return
	defer if status != .Ok {
		release(h, out)
	}
	for pair in strings.split_iterator(&rest, "&") {
		if pair == "" {
			continue
		}
		name, _, value := strings.partition(pair, "=")
		key := form_component(h, name) or_return
		x, s := form_component(h, value)
		if s != .Ok {
			release(h, key)
			return NULL, s
		}
		add_member(h, &out, key, x) or_return
	}
	return out, .Ok
}

// Adds `x` to the built object `o^` under `key`, both moving in. A name that is there already holds an array of its
// values, which `x` joins.
@(private, require_results)
add_member :: proc(h: ^Heap, o: ^Value, key, x: Value) -> Status {
	k := find_key((^Object_Block)(o.p), text_of(key))
	if k < 0 {
		return object_put(h, o, key, x)
	}
	release(h, key)
	own_object(h, o, 0) or_return
	e := &object_entries((^Object_Block)(o.p))[k]
	if e.value.kind != .Array {
		list, s := make_array(h, 2)
		if s != .Ok {
			release(h, x)
			return s
		}
		first := e.value
		e.value = NULL
		if s = append_owned(h, &list, first); s != .Ok {
			release(h, x)
			release(h, list)
			return s
		}
		e.value = list
	}
	return append_owned(h, &e.value, x)
}

// `s` with each `+` a space and each `%XX` its byte, a `%` not before two hex digits as written.
@(private, require_results)
form_component :: proc(h: ^Heap, s: string) -> (res: Value, status: Status) {
	if strings.index_any(s, "+%") < 0 {
		return text_value(h, s)
	}
	bytes := make([dynamic]u8, 0, len(s), h.allocator)
	defer delete(bytes)
	for i := 0; i < len(s); i += 1 {
		switch {
		case s[i] == '+':
			append(&bytes, ' ')
		case s[i] == '%' && i + 2 < len(s) && spell.HEX_NIBBLE[s[i + 1]] | spell.HEX_NIBBLE[s[i + 2]] <= 15:
			append(&bytes, spell.HEX_NIBBLE[s[i + 1]] << 4 | spell.HEX_NIBBLE[s[i + 2]])
			i += 2
		case:
			append(&bytes, s[i])
		}
	}
	return text_lossy(h, bytes[:])
}

// Line `v` of logfmt, the Heroku `key=value` pairs separated by white space, as an object of strings. A bare key is
// true, `key=` is "", a value in double quotes may hold white space and the escapes `\"`, `\\`, `\n`, `\r` and `\t`,
// and a key that repeats keeps its last value. A fault has the line in `a` and a byte offset in `b`: where a stray
// character is, or where the key of the faulty value starts.
@(require_results)
parse_logfmt :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	line := text_of(v)
	out := make_object(h, 0) or_return
	defer if status != .Ok {
		release(h, out)
	}
	fault :: proc(h: ^Heap, v: Value, at: int, why: string) -> Status {
		return fail(h, .Parse, .Logfmt, v, int_value(i64(at)), why)
	}
	for i := 0; i < len(line); {
		if kernel.is_ws(line[i]) {
			i += 1
			continue
		}
		start := i
		for i < len(line) && !kernel.is_ws(line[i]) && line[i] != '=' && line[i] != '"' {
			i += 1
		}
		key := line[start:i]
		if key == "" {
			return NULL, fault(h, v, i, "unexpected")
		}
		if i >= len(line) || kernel.is_ws(line[i]) {
			object_put(h, &out, text_value(h, key) or_return, TRUE) or_return
			continue
		}
		if line[i] == '"' {
			return NULL, fault(h, v, i, "unexpected")
		}
		i += 1 // past the =
		value: Value
		if i < len(line) && line[i] == '"' {
			i += 1
			text := make([dynamic]u8, 0, 16, h.allocator)
			defer delete(text)
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
						return NULL, fault(h, v, start, "unknown escape")
					}
				case:
					append(&text, c)
				}
			}
			if !closed {
				return NULL, fault(h, v, start, "unclosed")
			}
			value = text_lossy(h, text[:]) or_return
		} else {
			from := i
			for i < len(line) && !kernel.is_ws(line[i]) {
				i += 1
			}
			value = text_value(h, line[from:i]) or_return
		}
		k, s := text_value(h, key)
		if s == .Ok {
			s = object_put(h, &out, k, value)
		} else {
			release(h, value)
		}
		if s != .Ok {
			return NULL, s
		}
	}
	return out, .Ok
}

// The reference tokens of RFC 6901 pointer `v` as an array of strings, `~1` unescaped to `/` and `~0` to `~`, or a
// fault for a value that is not a string, empty or starting with `/`.
@(require_results)
pointer_tokens :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	if !is_text(v) || text_of(v) != "" && text_of(v)[0] != '/' {
		return NULL, fail(h, .Parse, .Pointer, v)
	}
	rest := text_of(v)
	out := make_array(h, 4) or_return
	defer if status != .Ok {
		release(h, out)
	}
	for len(rest) > 0 {
		rest = rest[1:]
		end := strings.index_byte(rest, '/')
		token := rest if end < 0 else rest[:end]
		rest = "" if end < 0 else rest[end:]
		x := unescape_token(h, token) or_return
		append_owned(h, &out, x) or_return
	}
	return out, .Ok
}

// Reference token `token` with `~1` as `/` and `~0` as `~`.
@(private, require_results)
unescape_token :: proc(h: ^Heap, token: string) -> (res: Value, status: Status) {
	if strings.index_byte(token, '~') < 0 {
		return text_value(h, token)
	}
	bytes := make([dynamic]u8, 0, len(token), h.allocator)
	defer delete(bytes)
	for i := 0; i < len(token); i += 1 {
		if token[i] == '~' && i + 1 < len(token) && (token[i + 1] == '0' || token[i + 1] == '1') {
			append(&bytes, '~' if token[i + 1] == '0' else '/')
			i += 1
		} else {
			append(&bytes, token[i])
		}
	}
	return text_value(h, string(bytes[:]))
}

// The array index reference token `token` names: its decimal digits with no leading zero, below 2^31, or false.
pointer_index :: proc "contextless" (token: string) -> (index: i64, ok: bool) {
	if len(token) > 1 && token[0] == '0' {
		return 0, false
	}
	return decimal_below(token, 1 << 31)
}
