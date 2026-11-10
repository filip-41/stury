package rules

import "core:encoding/uuid"
import "core:strings"
import regex "../regex"
import "../spell"

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

// Each format's name and check. The checks take the decoded string. A regex is judged as ECMA-262 with the `u` flag,
// as `pattern` is.
@(private, rodata)
FORMATS := [String_Format]struct {
	name:  string,
	valid: proc(s: string) -> bool,
} {
	.None = {},
	.Date_Time = {"date-time", proc(s: string) -> bool {_, ok := date_time_of(s);return ok}},
	.Date = {"date", proc(s: string) -> bool {_, ok := date_of(s);return ok}},
	.Time = {"time", proc(s: string) -> bool {_, ok := time_of(s);return ok}},
	.Duration = {"duration", duration_valid},
	.Email = {"email", proc(s: string) -> bool {return mailbox_valid(s, false)}},
	.Idn_Email = {"idn-email", proc(s: string) -> bool {return mailbox_valid(s, true)}},
	.Hostname = {"hostname", proc(s: string) -> bool {return domain_valid(s, false)}},
	.Idn_Hostname = {"idn-hostname", proc(s: string) -> bool {return domain_valid(s, true)}},
	.Ipv4 = {"ipv4", ipv4_valid},
	.Ipv6 = {"ipv6", ipv6_valid},
	.Uri = {"uri", proc(s: string) -> bool {return uri_valid(s, false, false)}},
	.Uri_Reference = {"uri-reference", proc(s: string) -> bool {return uri_valid(s, false, true)}},
	.Iri = {"iri", proc(s: string) -> bool {return uri_valid(s, true, false)}},
	.Iri_Reference = {"iri-reference", proc(s: string) -> bool {return uri_valid(s, true, true)}},
	.Uri_Template = {"uri-template", template_valid},
	.Uuid = {"uuid", proc(s: string) -> bool {_, err := uuid.read(s);return err == nil}},
	.Json_Pointer = {"json-pointer", pointer_valid},
	.Relative_Json_Pointer = {"relative-json-pointer", relative_pointer_valid},
	.Regex = {"regex", proc(s: string) -> bool {return regex.valid(s, {ecma = true})}},
}

// The format `name` is, `.None` for a name no checker judges.
format_of :: proc(name: string) -> String_Format {
	for f in String_Format.Date_Time ..= String_Format.Regex {
		if FORMATS[f].name == name {
			return f
		}
	}
	return .None
}

// Whether the decoded string `s` is a value of format `f`. Allocates nothing that outlives the call.
@(private)
format_valid :: proc(f: String_Format, s: string) -> bool {
	return FORMATS[f].valid == nil || FORMATS[f].valid(s)
}

// The length of the run of ASCII digits that starts `s`.
@(private)
digits :: proc(s: string) -> int {
	n := 0
	for n < len(s) && s[n] >= '0' && s[n] <= '9' {
		n += 1
	}
	return n
}

// The ASCII decimal number `s` is, false for any other byte and for an empty `s`.
@(private)
decimal :: proc(s: string) -> (n: int, ok: bool) {
	for c in transmute([]u8)s {
		if c < '0' || c > '9' || n > 1 << 40 {
			return 0, false
		}
		n = n * 10 + int(c - '0')
	}
	return n, s != ""
}

@(private)
all_hex :: proc(s: string) -> bool {
	for c in transmute([]u8)s {
		if spell.HEX_NIBBLE[c] > 15 {
			return false
		}
	}
	return s != ""
}

@(private)
is_leap :: proc(y: int) -> bool {
	return y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
}

// The fields of an RFC 3339 date and time. `offset` is in minutes east of UTC, `nanosecond` the fraction cut at nine digits.
@(private)
Date_Time_Parts :: struct {
	year, month, day, hour, minute, second, nanosecond, offset: int,
}

// RFC 3339 `full-date`.
@(private)
date_of :: proc(s: string) -> (p: Date_Time_Parts, ok: bool) {
	if len(s) != 10 || s[4] != '-' || s[7] != '-' {
		return
	}
	y, y_ok := decimal(s[:4])
	m, m_ok := decimal(s[5:7])
	d, d_ok := decimal(s[8:])
	if !y_ok || !m_ok || !d_ok || m < 1 || m > 12 || d < 1 {
		return
	}
	days := [?]int{31, 29 if is_leap(y) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	return {year = y, month = m, day = d}, d <= days[m - 1]
}

// RFC 3339 `full-time`: `HH:MM:SS`, a fraction of one digit or more, and a `Z` or `+HH:MM` offset. A leap second is
// the last second of a minute that is 23:59 in UTC.
@(private)
time_of :: proc(s: string) -> (p: Date_Time_Parts, ok: bool) {
	if len(s) < 9 || s[2] != ':' || s[5] != ':' {
		return
	}
	h, h_ok := decimal(s[:2])
	m, m_ok := decimal(s[3:5])
	sec, s_ok := decimal(s[6:8])
	if !h_ok || !m_ok || !s_ok || h > 23 || m > 59 || sec > 60 {
		return
	}
	p = {hour = h, minute = m, second = sec}
	rest := s[8:]
	if rest[0] == '.' {
		n := digits(rest[1:])
		if n == 0 {
			return
		}
		scale := 100_000_000
		for c in transmute([]u8)rest[1:1 + min(n, 9)] {
			p.nanosecond += int(c - '0') * scale
			scale /= 10
		}
		rest = rest[n + 1:]
	}
	switch {
	case rest == "Z" || rest == "z":
	case len(rest) == 6 && (rest[0] == '+' || rest[0] == '-') && rest[3] == ':':
		oh, oh_ok := decimal(rest[1:3])
		om, om_ok := decimal(rest[4:])
		if !oh_ok || !om_ok || oh > 23 || om > 59 {
			return
		}
		p.offset = (oh * 60 + om) * (1 if rest[0] == '+' else -1)
	case:
		return
	}
	return p, sec < 60 || ((h * 60 + m - p.offset) % 1440 + 1440) % 1440 == 23 * 60 + 59
}

// RFC 3339 `date-time`: a date, `T` or `t`, and a time.
@(private)
date_time_of :: proc(s: string) -> (p: Date_Time_Parts, ok: bool) {
	if len(s) <= 11 || s[10] != 'T' && s[10] != 't' {
		return
	}
	d, d_ok := date_of(s[:10])
	t, t_ok := time_of(s[11:])
	t.year, t.month, t.day = d.year, d.month, d.day
	return t, d_ok && t_ok
}

// RFC 3339 appendix A `duration`: weeks alone, or date units that follow in order from the first one given (`Y` then
// `M` then `D`) and `T` with time units `H`, `M`, `S` likewise.
@(private)
duration_valid :: proc(s: string) -> bool {
	if len(s) < 3 || s[0] != 'P' {
		return false
	}
	r := s[1:]
	if r[len(r) - 1] == 'W' {
		_, ok := decimal(r[:len(r) - 1])
		return ok
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

// Takes the units of `order` from the front of `r`, each as digits and its letter: the first one present and the ones
// after it with no gap. False when none is.
@(private)
duration_units :: proc(r: ^string, order: string) -> bool {
	take :: proc(r: ^string, unit: u8) -> bool {
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
		if n, ok := decimal(part); !ok || n > 255 || len(part) > 3 || len(part) > 1 && part[0] == '0' {
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

// RFC 6901: empty, or `/` before every token, with `~` only as `~0` and `~1`.
@(private)
pointer_valid :: proc(s: string) -> bool {
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

// A relative JSON pointer, draft-bhutton-relative-json-pointer-00: a number with no leading zero, an optional `+` or
// `-` and a second such number, then `#` or a JSON pointer.
@(private)
relative_pointer_valid :: proc(s: string) -> bool {
	number :: proc(s: string) -> (n: int, ok: bool) {
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
