// Built-in carriers (`time.Time`, `uuid.Identifier`, `Email`, `Base64`, `Hex`, `Decimal`, `Number_Text`)
// and user-defined `Custom(T, C)` carriers operating natively without serialize-reparse.
package model

import "base:intrinsics"
import "base:runtime"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/uuid"
import "core:strconv"
import "core:time"
import "stury:lib/base/spell"
import "stury:lib/ops/typed"
import "stury:lib/schema/rules"

Number_Text :: struct { text: string, value: f64 }
Base64 :: distinct []u8
Hex :: distinct []u8
Email :: distinct string
Decimal :: distinct Number_Text

@(private)
Carrier :: struct { type: typeid, tag: string, subject: Value_Kinds, kinds: rules.Kinds, encoding: string }

@(private, rodata)
CARRIERS := [?]Carrier{
	{time.Time, `format=date-time,pattern=^(?![0-9]{4}-)|^(?:16(?:7[89]|[89][0-9])|1[7-9][0-9]{2}|2[01][0-9]{2}|22(?:[0-5][0-9]|6[01]))-`, {.Text}, {.String}, ""},
	{uuid.Identifier, "format=uuid", {.Text}, {.String}, ""},
	{Email, "format=email", {.Text}, {.String}, ""},
	{Base64, `pattern=^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/][AQgw]==|[A-Za-z0-9+/]{2}[AEIMQUYcgkosw048]=)?$`, {.Text}, {.String}, "base64"},
	{Hex, `pattern=^(?:[0-9a-fA-F]{2})*$`, {.Text}, {.String}, "base16"},
	{Decimal, `pattern=^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$`, {.Text, .Float}, {.Number, .String}, ""},
}

// Walks `ti` and any `distinct` wrappers to identify a built-in carrier or special type.
@(private)
builtin_carrier_kind :: proc(ti: ^runtime.Type_Info) -> Type_Kind {
	for cur := ti; cur != nil; {
		for c, idx in CARRIERS { if cur.id == c.type { return Type_Kind(int(Type_Kind.Time) + idx) } }
		switch cur.id {
		case Number_Text: return .Number_Text
		case typed.Raw:   return .Raw
		case rules.Value: return .Value
		}
		named, ok := cur.variant.(^runtime.Type_Info_Named); if !ok { break }
		cur = named.base
	}
	// In Odin RTTI, `distinct T` over a named struct/union points directly to `type_info_base(T)`.
	// Match unique structural bases (`time.Time`, `Number_Text`, `rules.Value`) — never primitives (`string`, `[]u8`).
	if ti != nil {
		switch runtime.type_info_base(ti).id {
		case runtime.type_info_base(type_info_of(time.Time)).id:   return .Time
		case runtime.type_info_base(type_info_of(Number_Text)).id: return .Number_Text
		case runtime.type_info_base(type_info_of(rules.Value)).id: return .Value
		}
	}
	return .Invalid
}

@(private)
is_number_text_type :: proc(ti: ^runtime.Type_Info) -> bool { return builtin_carrier_kind(ti) == .Number_Text }

@(private)
carried :: proc(reg: ^Registry, T: typeid) -> typeid {
	if reg != nil { for x in reg.customs { if x.type == T { return x.carrier } } }
	return T
}

@(private)
carrier_of :: proc(T: typeid) -> (Carrier, bool) {
	if T == nil { return {}, false }
	ti := type_info_of(T)
	for cur := ti; cur != nil; {
		for c in CARRIERS { if c.type == cur.id { return c, true } }
		named, ok := cur.variant.(^runtime.Type_Info_Named); if !ok { break }
		cur = named.base
	}
	if builtin_carrier_kind(ti) == .Time { return CARRIERS[0], true }
	return {}, false
}

Custom :: struct($T, $C: typeid) {
	from: proc(c: ^C, out: ^T, allocator: runtime.Allocator) -> Error_Kind,
	to:   proc(t: ^T, allocator: runtime.Allocator) -> (C, Error_Kind),
}

@(private)
Custom_Of :: struct {
	type, carrier: typeid, from, to: rawptr,
	convert_from: proc(fn, carrier_ptr, out_ptr: rawptr, allocator: runtime.Allocator) -> Error_Kind,
	convert_to:   proc(fn, val_ptr, carrier_out: rawptr, allocator: runtime.Allocator) -> Error_Kind,
}

register_custom :: proc(reg: ^Registry, custom: Custom($T, $C)) -> runtime.Allocator_Error {
	cfrom :: proc(fn, cp, op: rawptr, a: runtime.Allocator) -> Error_Kind { return (proc(c: ^C, out: ^T, a: runtime.Allocator) -> Error_Kind)(fn)((^C)(cp), (^T)(op), a) }
	cto :: proc(fn, vp, co: rawptr, a: runtime.Allocator) -> Error_Kind { c, k := (proc(t: ^T, a: runtime.Allocator) -> (C, Error_Kind))(fn)((^T)(vp), a); (^C)(co)^ = c; return k }
	entry := Custom_Of{T, C, rawptr(custom.from), rawptr(custom.to), cfrom, cto}
	for &x in reg.customs { if x.type == T { x = entry; return nil } }
	_, err := append(&reg.customs, entry); return err
}

@(private)
decode_time :: proc(s: string, optional_seconds := false) -> (t: time.Time, kind: Error_Kind) {
	nsec, spelled, in_range := spell.date_time_nsec(s, optional_seconds)
	if !spelled { return {}, .Bad_Format }
	if !in_range { return {}, .No_Match }
	return time.Time{_nsec = nsec}, .None
}

@(private)
decode_epoch_time :: proc "contextless" (n: spell.Number) -> (t: time.Time, kind: Error_Kind) {
	#partial switch n.kind {
	case .Int, .Uint:
		if n.kind == .Uint && n.bits > u64(max(i64)) { return {}, .No_Match }
		nsec, past := intrinsics.overflow_mul(i64(n.bits), 1_000_000_000)
		if past { return {}, .No_Match }
		return time.Time{_nsec = nsec}, .None
	case .Float:
		nsec := transmute(f64)n.bits * 1e9
		if abs(nsec) < f64(max(i64)) { return time.Time{_nsec = i64(nsec)}, .None }
	}
	return {}, .No_Match
}

@(private)
format_rfc3339_utc :: proc(t: time.Time, buf: ^[40]u8) -> (s: string, ok: bool) {
	y, mo, d := time.date(t); if y < 0 || y > 9999 { return "", false }
	h, mi, sec := time.clock_from_time(t)
	ns := t._nsec % 1_000_000_000; if ns < 0 { ns += 1_000_000_000 }
	put :: proc "contextless" (dst: []u8, pos: ^int, val, width: int, sep := u8(0)) {
		v := val; for k := width - 1; k >= 0; k -= 1 { dst[pos^ + k] = '0' + u8(v % 10); v /= 10 }
		pos^ += width; if sep != 0 { dst[pos^] = sep; pos^ += 1 }
	}
	n := 0
	put(buf[:], &n, y, 4, '-'); put(buf[:], &n, int(mo), 2, '-'); put(buf[:], &n, d, 2, 'T')
	put(buf[:], &n, h, 2, ':'); put(buf[:], &n, mi, 2, ':'); put(buf[:], &n, sec, 2)
	if ns > 0 { buf[n] = '.'; n += 1; fs := n; put(buf[:], &n, int(ns), 9); for n > fs && buf[n - 1] == '0' { n -= 1 } }
	buf[n] = 'Z'; return string(buf[:n + 1]), true
}

@(private)
decode_uuid :: proc(s: string) -> (uuid.Identifier, Error_Kind) {
	if len(s) != 36 { return {}, .Bad_Format }
	parsed, err := uuid.read(s)
	if err != nil { return {}, .Bad_Format }
	return parsed, .None
}
@(private)
format_uuid :: proc(id: uuid.Identifier, buf: ^[36]u8) -> string { return uuid.to_string_buffer(id, buf[:]) }

@(private)
decode_base64 :: proc(s: string, allocator: runtime.Allocator) -> (Base64, Error_Kind) {
	if len(s) == 0 { return nil, .None }
	bytes, err := base64.decode(s, allocator = allocator)
	if err == nil { return Base64(bytes), .None }
	_, oom := err.(runtime.Allocator_Error); return nil, .No_Memory if oom else .Bad_Format
}
@(private)
encode_base64 :: proc(b: []u8, allocator: runtime.Allocator) -> (string, runtime.Allocator_Error) {
	if len(b) == 0 { return "", nil }
	return base64.encode(b, allocator = allocator)
}

@(private)
decode_hex :: proc(s: string, allocator: runtime.Allocator) -> (Hex, Error_Kind) {
	if len(s) == 0 { return nil, .None }
	bytes, err := hex.decode(transmute([]u8)s, allocator)
	if err == nil { return Hex(bytes), .None }
	_, oom := err.(runtime.Allocator_Error); return nil, .No_Memory if oom else .Bad_Format
}
@(private)
encode_hex :: proc(h: Hex, allocator: runtime.Allocator) -> (s: string, err: runtime.Allocator_Error) {
	if len(h) == 0 { return "", nil }
	enc := hex.encode(([]u8)(h), allocator) or_return
	return string(enc), nil
}
@(private)
parse_f64_approx :: proc(s: string) -> f64 { v, _ := strconv.parse_f64(s); return v }