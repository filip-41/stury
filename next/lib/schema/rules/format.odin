package rules

import "core:mem"
import "core:strings"
import "stury:lib/base/regex"
import "stury:lib/base/spell"

// The string formats a string rule can ask for. Another name is an annotation and judges nothing.
String_Format :: enum u8 {
	None,
	Date_Time,
	Date,
	Time,
	Duration,
	Email,
	Idn_Email,
	Hostname,
	Idn_Hostname,
	Ipv4,
	Ipv6,
	Uri,
	Uri_Reference,
	Iri,
	Iri_Reference,
	Uri_Template,
	Uuid,
	Json_Pointer,
	Relative_Json_Pointer,
	Regex,
}

// Each format's name. A name and its check are apart, so a plan that only names formats links no check.
@(rodata)
FORMAT_NAMES := [String_Format]string {
	.None                  = "",
	.Date_Time             = "date-time",
	.Date                  = "date",
	.Time                  = "time",
	.Duration              = "duration",
	.Email                 = "email",
	.Idn_Email             = "idn-email",
	.Hostname              = "hostname",
	.Idn_Hostname          = "idn-hostname",
	.Ipv4                  = "ipv4",
	.Ipv6                  = "ipv6",
	.Uri                   = "uri",
	.Uri_Reference         = "uri-reference",
	.Iri                   = "iri",
	.Iri_Reference         = "iri-reference",
	.Uri_Template          = "uri-template",
	.Uuid                  = "uuid",
	.Json_Pointer          = "json-pointer",
	.Relative_Json_Pointer = "relative-json-pointer",
	.Regex                 = "regex",
}

// The ECMA pattern that matches exactly the strings each format's check takes, "" where none of a fair length does.
@(rodata)
FORMAT_PATTERNS := #partial [String_Format]string {
	.Date                  = `^(?:\d{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12]\d|3[01])|(?:0[469]|11)-(?:0[1-9]|[12]\d|30)|02-(?:0[1-9]|1\d|2[0-8]))|(?:\d\d(?:0[48]|[2468][048]|[13579][26])|(?:[02468][048]|[13579][26])00)-02-29)$`,
	.Duration              = `^P(?:\d+W|(?:\d+D|\d+M(?:\d+D)?|\d+Y(?:\d+M(?:\d+D)?)?)(?:T(?:\d+H(?:\d+M(?:\d+S)?)?|\d+M(?:\d+S)?|\d+S))?|T(?:\d+H(?:\d+M(?:\d+S)?)?|\d+M(?:\d+S)?|\d+S))$`,
	.Ipv6                  = `^(?:(?:(?:[\dA-Fa-f]{1,4}:){6}|::(?:[\dA-Fa-f]{1,4}:){5}|(?:[\dA-Fa-f]{1,4})?::(?:[\dA-Fa-f]{1,4}:){4}|(?:(?:[\dA-Fa-f]{1,4}:){0,1}[\dA-Fa-f]{1,4})?::(?:[\dA-Fa-f]{1,4}:){3}|(?:(?:[\dA-Fa-f]{1,4}:){0,2}[\dA-Fa-f]{1,4})?::(?:[\dA-Fa-f]{1,4}:){2}|(?:(?:[\dA-Fa-f]{1,4}:){0,3}[\dA-Fa-f]{1,4})?::[\dA-Fa-f]{1,4}:|(?:(?:[\dA-Fa-f]{1,4}:){0,4}[\dA-Fa-f]{1,4})?::)(?:[\dA-Fa-f]{1,4}:[\dA-Fa-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d))|(?:(?:[\dA-Fa-f]{1,4}:){0,5}[\dA-Fa-f]{1,4})?::[\dA-Fa-f]{1,4}|(?:(?:[\dA-Fa-f]{1,4}:){0,6}[\dA-Fa-f]{1,4})?::)$`,
	.Ipv4                  = `^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$`,
	.Uuid                  = `^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`,
	.Json_Pointer          = `^(?:/(?:[^~/]|~[01])*)*$`,
	.Relative_Json_Pointer = `^(?:0|[1-9]\d*)(?:[+-](?:0|[1-9]\d*))?(?:#|(?:/(?:[^~/]|~[01])*)*)$`,
}

// The format `name` is, `.None` for a name no checker judges.
format_of :: proc "contextless" (name: string) -> String_Format {
	for f in String_Format.Date_Time ..= String_Format.Regex {
		if FORMAT_NAMES[f] == name {
			return f
		}
	}
	return .None
}

// Whether the decoded string `s` is a value of format `f`. Allocates nothing that outlives the call.
// `.Regex` compiles in a temporary `Dynamic_Arena` backed by `scratch`, with no automaton.
format_valid :: proc(f: String_Format, s: string, scratch := context.allocator) -> bool {
	switch f {
	case .None:
		return true
	case .Date_Time:
		return spell.is_date_time(s)
	case .Date:
		return spell.is_full_date(s)
	case .Time:
		return spell.is_full_time(s)
	case .Duration:
		return duration_valid(s)
	case .Email:
		return mailbox_valid(s, false)
	case .Idn_Email:
		return mailbox_valid(s, true)
	case .Hostname:
		return domain_valid(s, false)
	case .Idn_Hostname:
		return domain_valid(s, true)
	case .Ipv4:
		return ipv4_valid(s)
	case .Ipv6:
		return ipv6_valid(s)
	case .Uri:
		return uri_valid(s, false, false)
	case .Uri_Reference:
		return uri_valid(s, false, true)
	case .Iri:
		return uri_valid(s, true, false)
	case .Iri_Reference:
		return uri_valid(s, true, true)
	case .Uri_Template:
		return template_valid(s)
	case .Uuid:
		return uuid_valid(s)
	case .Json_Pointer:
		return pointer_valid(s)
	case .Relative_Json_Pointer:
		return relative_pointer_valid(s)
	case .Regex:
		return regex_format_valid(s, scratch)
	}
	return true
}

@(private = "file")
regex_format_valid :: proc(s: string, scratch: mem.Allocator) -> bool {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, scratch, scratch, block_size = 4096, out_band_size = 1024)
	defer mem.dynamic_arena_destroy(&arena)
	_, err := regex.compile(s, .Ecma, {}, mem.dynamic_arena_allocator(&arena), scratch, automaton = false)
	return err.kind == .None
}

// The length of the run of ASCII digits that starts `s`.
@(private)
digits :: proc "contextless" (s: string) -> int {
	n := 0
	for n < len(s) && s[n] >= '0' && s[n] <= '9' {
		n += 1
	}
	return n
}

// The ASCII decimal number `s` is, false for any other byte, empty `s`, or overflow past `1 << 40`.
@(private)
decimal_u64 :: proc "contextless" (s: string) -> (int, bool) {
	if len(s) == 0 {
		return 0, false
	}
	n: u64
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n * 10 + u64(c - '0')
		if n > 1 << 40 {
			return 0, false
		}
	}
	return int(n), true
}

@(private)
all_hex :: proc "contextless" (s: string) -> bool {
	for c in transmute([]u8)s {
		if spell.HEX_NIBBLE[c] > 15 {
			return false
		}
	}
	return s != ""
}

// RFC 3339 appendix A `duration`: weeks alone, or date units that follow in order from the first one given (`Y` then
// `M` then `D`) and `T` with time units `H`, `M`, `S` likewise.
@(private)
duration_valid :: proc "contextless" (s: string) -> bool {
	if len(s) < 3 || s[0] != 'P' {
		return false
	}
	r := s[1:]
	if r[len(r) - 1] == 'W' {
		return digits(r) == len(r) - 1
	}
	date := duration_units(&r, "YMD")
	time := false
	if len(r) > 0 && r[0] == 'T' {
		r = r[1:]
		if time = duration_units(&r, "HMS"); !time {
			return false
		}
	}
	return r == "" && (date || time)
}

@(private)
duration_units :: proc "contextless" (r: ^string, order: string) -> bool {
	take :: proc "contextless" (r: ^string, unit: u8) -> bool {
		t := r^
		n := digits(t)
		if n == 0 || n == len(t) || t[n] != unit {
			return false
		}
		r^ = t[n + 1:]
		return true
	}
	for i in 0 ..< len(order) {
		if take(r, order[i]) {
			for j in i + 1 ..< len(order) {
				take(r, order[j]) or_break
			}
			return true
		}
	}
	return false
}

// Dotted decimal of four octets with no leading zero.
@(private)
ipv4_valid :: proc(s: string) -> bool {
	rest, parts := s, 0
	for part in strings.split_iterator(&rest, ".") {
		if n, ok := decimal_u64(part); !ok || n > 255 || len(part) > 3 || len(part) > 1 && part[0] == '0' {
			return false
		}
		parts += 1
	}
	return parts == 4 && strings.count(s, ".") == 3
}

// RFC 4291 text form: groups of one to four hex digits, one `::` in place of one or more, and a dotted quad as the
// last 32 bits.
@(private)
ipv6_valid :: proc(s: string) -> bool {
	groups :: proc(part: string, last: bool) -> (n: int, ok: bool) {
		rest := part
		for rest != "" {
			item := rest
			if cut := strings.index_byte(rest, ':'); cut >= 0 {
				item, rest = rest[:cut], rest[cut + 1:]
				if rest == "" {
					return 0, false
				}
			} else {
				rest = ""
			}
			switch {
			case last && rest == "" && strings.contains_rune(item, '.'):
				ipv4_valid(item) or_return
				n += 2
			case len(item) > 4 || !all_hex(item):
				return 0, false
			case:
				n += 1
			}
		}
		return n, true
	}
	gap := strings.index(s, "::")
	if gap < 0 {
		n, ok := groups(s, true)
		return ok && n == 8
	}
	tail := s[gap + 2:]
	if strings.has_prefix(tail, ":") || strings.contains(tail, "::") {
		return false
	}
	head, head_ok := groups(s[:gap], false)
	rest, rest_ok := groups(tail, true)
	return head_ok && rest_ok && head + rest <= 7
}

// RFC 4122 text form, any variant and version.
@(private)
uuid_valid :: proc "contextless" (s: string) -> bool {
	if len(s) != 36 {
		return false
	}
	for c, i in transmute([]u8)s {
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		case:
			if spell.HEX_NIBBLE[c] > 15 {
				return false
			}
		}
	}
	return true
}

// RFC 6901: empty, or `/` before every token, with `~` only as `~0` and `~1`.
@(private)
pointer_valid :: proc "contextless" (s: string) -> bool {
	if s != "" && s[0] != '/' {
		return false
	}
	for i in 0 ..< len(s) {
		if s[i] == '~' && (i + 1 == len(s) || s[i + 1] != '0' && s[i + 1] != '1') {
			return false
		}
	}
	return true
}

// A relative JSON pointer, draft-bhutton-relative-json-pointer-00.
@(private)
relative_pointer_valid :: proc "contextless" (s: string) -> bool {
	number :: proc "contextless" (s: string) -> (n: int, ok: bool) {
		n = digits(s)
		return n, n > 0 && (n == 1 || s[0] != '0')
	}
	n := number(s) or_return
	rest := s[n:]
	if rest != "" && (rest[0] == '+' || rest[0] == '-') {
		n = number(rest[1:]) or_return
		rest = rest[n + 1:]
	}
	return rest == "#" || pointer_valid(rest)
}
