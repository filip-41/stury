package json

import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// JSON's detail of a fault, in `tape.Fault.detail`. The cold states that fault choose it from the byte and the state
// that refused it, and `described` gives the faults of strings and numbers theirs, whose readers return a kind alone.
@(private)
Detail :: enum u8 {
	None,
	Literal, // `Bad_Char`: a byte breaking `true`, `false` or `null`, or a word that is none of them
	Identifier, // `Bad_Char`: JSON5 only, a byte that starts no key, quoted or not, where an object's key must start
	Colon, // `Bad_Char`: a byte where a member's colon must be
	Trailing, // `Bad_Char`: the first byte after the root value that is no white space or comment
	// `Bad_Char`: an `I` or `N` where a value must start outside JSON5, `Bad_Number` after a minus. A detail is judged
	// from the bytes up to the fault's, which a text in pieces holds in the same window, so the word is not read.
	Non_Finite,
	Array_Separator, // `Bad_Char`: a byte after an array's element that is no comma and no `]`
	Member_Separator, // `Bad_Char`: a byte after an object's member that is no comma and no `}`
	Trailing_Comma, // `Bad_Char`: a container's close right after a comma
	Lone_Comma, // `Bad_Char`: a comma where a value or a key must start
	Unmatched_Bracket, // `Bad_Char`: a `]` that closes no array
	Unmatched_Brace, // `Bad_Char`: a `}` that closes no object
	Single_Quote, // `Bad_Char`: a `'` where a string must start
	Control_Char, // `Bad_Char`: a byte below 0x20 that is no white space there, as in a string
	Invalid_Utf8, // `Bad_Char`: at the lead byte of an ill-formed UTF-8 sequence
	Leading_Zero, // `Bad_Number`: a digit after a number's leading zero
	Leading_Dot, // `Bad_Char`: a `.` where a value must start
	Leading_Plus, // `Bad_Char`: a `+` where a value must start
	Key_Not_String, // `Bad_Char`: a byte that opens no string where an object's key must start
	Expected_Value, // `Bad_Char`: any other byte where a value must start
}

// JSON's `tape.Rules`, one rule per `Detail` in its order.
@(private, rodata)
RULES := tape.Rules{"json", {
	{},
	{"literal", "Invalid literal"},
	{"identifier", "Invalid unquoted key"},
	{"colon", "Missing colon after key"},
	{"trailing", "Unexpected text after the value"},
	{"non_finite", "Infinity and NaN have no JSON value"},
	{"array_separator", "Expected ',' or ']' after an array element"},
	{"member_separator", "Expected ',' or '}' after an object member"},
	{"trailing_comma", "Trailing comma before the closing bracket"},
	{"lone_comma", "Expected value before ','"},
	{"unmatched_bracket", "Unmatched ']'"},
	{"unmatched_brace", "Unmatched '}'"},
	{"single_quote", "Invalid string literal, expected \" but got '"},
	{"control_char", "Unescaped control character"},
	{"invalid_utf8", "Invalid UTF-8"},
	{"leading_zero", "Leading zero in a number"},
	{"leading_dot", "A number cannot start with '.'"},
	{"leading_plus", "A number cannot start with '+'"},
	{"key_not_string", "Object keys must be strings"},
	{"expected_value", "Expected a value"},
}}

// The detail for the byte at `p` where a value must start and none does, in the container `d` names. A close of its
// own array there follows a comma, as an empty container's close is read where it opens, and an object's value follows
// its colon.
@(private, cold)
value_detail :: proc "contextless" (p, end: [^]u8, d: u64) -> Detail {
	b := p[0]
	switch b {
	case ']', '}':
		if d < 2 || b != ']' | u8(d & 1) << 5 {
			return .Unmatched_Bracket if b == ']' else .Unmatched_Brace
		}
		return .Expected_Value if d & 1 != 0 else .Trailing_Comma
	case ',':
		return .Lone_Comma
	case '\'':
		return .Single_Quote
	case '.':
		return .Leading_Dot
	case '+':
		return .Leading_Plus
	case 'N', 'I':
		return .Non_Finite
	}
	if 'a' <= b | 0x20 && b | 0x20 <= 'z' {
		return .Literal
	}
	return byte_detail(p, end, .Expected_Value)
}

// The detail for the byte at `p` where an object's key must start and no string does. A close of the object there
// follows a comma, as an empty object's close is read where it opens.
@(private, cold)
key_detail :: proc "contextless" (p, end: [^]u8) -> Detail {
	switch p[0] {
	case '}':
		return .Trailing_Comma
	case ']':
		return .Unmatched_Bracket
	case ',':
		return .Lone_Comma
	case '\'':
		return .Single_Quote
	}
	return byte_detail(p, end, .Key_Not_String)
}

// The detail for the byte at `p` after a value in the container `d` names, which is no comma and no close of it.
@(private, cold)
after_detail :: proc "contextless" (p: [^]u8, d: u64) -> Detail {
	switch p[0] {
	case ']':
		return .Unmatched_Bracket
	case '}':
		return .Unmatched_Brace
	}
	return .Member_Separator if d & 1 != 0 else .Array_Separator
}

// `.Control_Char` for a control byte at `p`, `.Invalid_Utf8` for the lead of an ill-formed UTF-8 sequence, or `other`.
@(private)
byte_detail :: proc "contextless" (p, end: [^]u8, other: Detail) -> Detail {
	if p[0] < 0x20 {
		return .Control_Char
	}
	if p[0] >= 0x80 {
		if _, kind := spell.utf8_char(p, end); kind == .Bad_Char {
			return .Invalid_Utf8
		}
	}
	return other
}

// The walk's fault `r` with the detail a string's or a number's fault names: a control byte or an ill-formed UTF-8
// sequence, a leading zero, or a minus before `Infinity` or `NaN` outside JSON5. The walk's bytes run from `lo` to
// `end`, and offsets count from `base`.
@(private, cold)
described :: #force_no_inline proc "contextless" (r: hook.Walk_Result, base, lo, end: [^]u8, json5: bool) -> hook.Walk_Result {
	at := u64(r) >> 16
	kind := tape.Fault_Kind(u8(r))
	q := base[at:]
	if u8(u64(r) >> 8) != 0 || q < lo || q >= end {
		return r
	}
	detail := Detail.None
	#partial switch kind {
	case .Bad_Char:
		detail = byte_detail(q, end, .None)
	case .Bad_Number:
		// A number's fault past its first digit lies within its bytes, which a window that cut it holds again.
		if !json5 && q > lo {
			if q[-1] == '-' && (q[0] == 'I' || q[0] == 'N') {
				detail = .Non_Finite
			} else if q[-1] == '0' && q[0] - '0' < 10 && (q[-1:] == lo || q[-2] - '0' >= 10) {
				detail = .Leading_Zero
			}
		}
	}
	return hook.walk_result(at, u8(kind), u8(detail))
}
