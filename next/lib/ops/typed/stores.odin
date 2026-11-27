package typed

import "base:intrinsics"
import "base:runtime"
import "core:strconv"
import "core:time"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// Stores of a scalar token into the bytes its type spells: text, bytes, numbers, enums, bits and times.

// Frees a scratch block `token_text` allocated.
@(private)
free_held :: #force_inline proc "contextless" (h: ^Reader, held: []u8) {
	context = h.ctx
	if held != nil {
		runtime.mem_free_with_size(raw_data(held), len(held), h.scratch)
	}
}

// Frees a persistent block `store_text` allocated (from `h.allocator`).
@(private)
free_owned :: #force_inline proc "contextless" (h: ^Reader, owned: []u8) {
	context = h.ctx
	if owned != nil {
		runtime.mem_free_with_size(raw_data(owned), len(owned), h.allocator)
	}
}

// The text of scalar token `t`: its bytes in the text, or its decode in `buf`, or in a block of the read's scratch
// allocator, `held`, when `buf` is too short. False when memory is refused.
@(private)
token_text :: proc "contextless" (h: ^Reader, t: tape.Token, buf: []u8) -> (s: string, held: []u8, ok: bool) {
	context = h.ctx
	src := h.base[:h.len]
	if s, ok = tape.node_text(h.format, src, t, buf); ok {
		return
	}
	room := h.format.room(src, t, nil)
	err: runtime.Allocator_Error
	if held, err = runtime.mem_alloc_non_zeroed(room, 1, h.scratch); err != nil || len(held) < room {
		return "", nil, false
	}
	s, ok = tape.node_text(h.format, src, t, held)
	return s, held, ok
}

// Stores the text of string token `t` at `dest`: a span of the text when the read borrows and it has nothing to decode,
// else a copy in the read's allocator, returned too when `held` asks for it. False when memory is refused.
@(private)
store_text :: #force_inline proc "contextless" (h: ^Reader, t: tape.Token, dest: uintptr, $held: bool) -> ([]u8, bool) {
	if t.spelling & tape.SPELLING_DECODE == 0 {
		if h.borrow {
			(^runtime.Raw_String)(dest)^ = {h.base[t.lo:], int(t.n)}
			return nil, true
		}
		if !copy_span(h, dest, t.lo, t.n) {
			return nil, false
		}
	} else if !store_string(h, t, dest) {
		return nil, false
	}
	when held {
		text := (^runtime.Raw_String)(dest)^
		return text.data[:text.len], true
	} else {
		return nil, true
	}
}

// Stores the `n` bytes of the text at `lo` at `dest` as a copy in the read's allocator, the zero string when `n` is 0,
// so no string points into the text. False when memory is refused, which leaves `dest` untouched.
@(private)
copy_span :: #force_no_inline proc "contextless" (h: ^Reader, dest: uintptr, lo: u64, n: u32) -> bool {
	text := (^runtime.Raw_String)(dest)
	if n == 0 {
		text^ = {}
		return true
	}
	if h.allocator.procedure == nil {
		return false
	}
	context = h.ctx
	buf, err := h.allocator.procedure(h.allocator.data, .Alloc_Non_Zeroed, int(n), 1, nil, 0)
	if err != nil || len(buf) < int(n) {
		return false
	}
	kernel.copy_short(raw_data(buf), h.base[lo:], int(n))
	text^ = {raw_data(buf), int(n)}
	return true
}

// Stores a copy of the text of token `t` at `dest`, false when memory is refused. An empty text allocates nothing.
@(private)
store_string :: #force_no_inline proc "contextless" (h: ^Reader, t: tape.Token, dest: uintptr) -> bool {
	if t.spelling & tape.SPELLING_DECODE == 0 {
		return copy_span(h, dest, t.lo, t.n)
	}
	context = h.ctx
	src := h.base[:h.len]
	room := h.format.room(src, t, nil)
	buf, err := runtime.mem_alloc_non_zeroed(room, 1, h.allocator)
	if err != nil || len(buf) < room {
		return false
	}
	text, _ := h.format.decode(src, t, buf, nil)
	if len(text) == 0 {
		runtime.mem_free_with_size(raw_data(buf), room, h.allocator)
		text = ""
	}
	(^runtime.Raw_String)(dest)^ = transmute(runtime.Raw_String)text
	return true
}

// Whether `rec` reads a slice or dynamic array of `u8`, which takes a byte string's bytes.
@(private)
byte_list :: proc "contextless" (rec: ^Record) -> bool {
	return (rec.kind == .Slice || rec.kind == .Dynamic) && (^Record)(uintptr(rec.first) - size_of(Record)).kind == .U8
}

// Stores the bytes of byte string `t` as the list `rec` at `dest`: a span of the text when the read borrows and they
// have nothing to decode, else a copy. False when memory is refused.
@(private)
store_bytes :: proc "contextless" (h: ^Reader, t: tape.Token, rec: ^Record, dest: uintptr) -> bool {
	context = h.ctx
	buf: [64]u8 = ---
	text, held, ok := token_text(h, t, buf[:])
	if !ok {
		return false
	}
	defer free_held(h, held)
	// A dynamic array frees its block with its allocator, so it never borrows.
	data := raw_data(text)
	inside := uintptr(data) >= uintptr(h.base) && uintptr(data) < uintptr(h.base) + uintptr(h.len)
	if !(h.borrow && inside && rec.kind == .Slice) {
		data = nil
		if len(text) > 0 {
			block, err := runtime.mem_alloc_non_zeroed(len(text), 1, h.allocator)
			if err != nil || len(block) < len(text) {
				return false
			}
			copy(block, text)
			data = raw_data(block)
		}
	}
	if rec.kind == .Slice {
		(^runtime.Raw_Slice)(dest)^ = {data, len(text)}
	} else {
		(^runtime.Raw_Dynamic_Array)(dest)^ = {data, len(text), len(text), h.caller}
	}
	return true
}

// Stores the span `lo` to `hi` of the text at `dest` as a `Raw`, borrowed or copied as the read keeps strings.
@(private)
store_raw :: proc "contextless" (h: ^Reader, lo, hi: u64, dest: uintptr) -> bool {
	_, ok := store_text(h, {lo = lo, n = u32(hi - lo), kind = .String, role = .Value}, dest, false)
	return ok
}

// A number the hot store did not take: an integer past `i64` or out of the field's range, a decimal for an integer, a
// float `f32` may round twice, or one past binary64.
@(private, cold)
number_cold :: #force_no_inline proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token, n: spell.Number) -> (hook.Regs, hook.Action) {
	s := s
	rec := (^Record)(uintptr(s.b) - size_of(Record))
	dest := uintptr(s.c) + uintptr(rec.offset)
	buf: [128]u8 = ---
	text, held, ok := token_text(h, t, buf[:])
	if !ok {
		return refuse_memory(h, s, t)
	}
	detail: Typed_Refusal
	if rec.kind <= .U64 {
		detail = store_integer(n, true, text, rec.kind, dest)
	} else {
		detail = store_float(h, n, text, rec.kind == .F32, dest)
	}
	free_held(h, held)
	if detail != .None {
		return refuse_value(h, s, t, detail)
	}
	s.c += u64(rec.stride)
	return s, .Next
}

// Stores number `n`, spelled `text`, as an integer of `kind` at `dest`. A text that spells a fraction or an exponent is
// no integer, and one past what the type holds is refused on the side of its sign.
@(private)
store_integer :: proc "contextless" (n: spell.Number, ok: bool, text: string, kind: Read_Kind, dest: uintptr) -> Typed_Refusal {
	if !ok || !integer_text(text) {
		return .Expected_Integer
	}
	minus := len(text) > 0 && text[0] == '-'
	switch n.kind {
	case .Int:
		v := i64(n.bits)
		if v < INT_LO[kind] {
			return .Below_Minimum
		}
		if v > INT_HI[kind] {
			return .Above_Maximum
		}
	case .Uint:
		if kind != .U64 {
			return .Above_Maximum
		}
	case .Float, .Wide:
		// A format that reads an integer of a word as a float holds it as a fraction, as CBOR's bigfloat.
		if word_digits(text, minus) {
			return .Expected_Integer
		}
		return .Below_Minimum if minus else .Above_Maximum
	}
	write_int(dest, n.bits, kind)
	return .None
}

// Whether the decimal digits of `text` after its sign spell a value of `i64` or `u64`, `minus` saying its sign.
@(private)
word_digits :: proc "contextless" (text: string, minus: bool) -> bool {
	t := text[1:] if len(text) > 0 && (text[0] == '-' || text[0] == '+') else text
	v: u64
	for c in transmute([]u8)t {
		if c < '0' || c > '9' || v > (max(u64) - u64(c - '0')) / 10 {
			return false
		}
		v = v * 10 + u64(c - '0')
	}
	return len(t) > 0 && (!minus || v <= 1 << 63)
}

// Whether a number's text spells an integer: digits with a sign, or a radix prefix.
@(private)
integer_text :: proc "contextless" (text: string) -> bool {
	t := text
	if len(t) > 0 && (t[0] == '-' || t[0] == '+') {
		t = t[1:]
	}
	if len(t) > 2 && t[0] == '0' && (t[1] == 'x' || t[1] == 'o' || t[1] == 'b') {
		return true
	}
	for c in transmute([]u8)t {
		if (c < '0' || c > '9') && c != '_' {
			return false
		}
	}
	return len(t) > 0
}

// Stores number `n`, spelled `text`, as an `f32` when `narrow`, else an `f64`, at `dest`. A value past binary64, or past
// `f32` for one, is refused, and a format's own infinity and NaN are taken.
@(private)
store_float :: proc "contextless" (h: ^Reader, n: spell.Number, text: string, narrow: bool, dest: uintptr) -> Typed_Refusal {
	context = h.ctx
	minus := len(text) > 0 && text[0] == '-'
	x: f64
	switch n.kind {
	case .Int:
		x = f64(i64(n.bits))
		// `-0` is the integer 0, and a float keeps its sign.
		if n.bits == 0 && minus {
			x = -x
		}
	case .Uint:
		x = f64(n.bits)
	case .Float:
		x = transmute(f64)n.bits
	case .Wide:
		parsed, ok := strconv.parse_f64(text)
		if !ok || abs(parsed) > max(f64) {
			return .Below_Minimum if minus else .Above_Maximum
		}
		x = parsed
	}
	if !narrow {
		(^f64)(dest)^ = x
		return .None
	}
	v := f32(x)
	// An integer rounds to `f32` once, from its own value.
	if n.kind == .Int && n.bits != 0 {
		v = f32(i64(n.bits))
	} else if n.kind == .Uint {
		v = f32(n.bits)
	}
	if n.kind == .Float && .Binary not_in h.format.caps && f32_double_rounds(x) {
		// Rounds the decimal once. Past `max(f32)` it is infinity, refused below.
		v, _ = strconv.parse_f32(text)
	}
	if abs(v) > max(f32) && abs(x) <= max(f64) {
		return .Below_Minimum if v < 0 else .Above_Maximum
	}
	(^f32)(dest)^ = v
	return .None
}

// Stores an enum value of `m`'s type at `dest`: a member's name, or under `Plan_Options.enums` `.Int` a member's value.
@(private)
store_enum :: proc "contextless" (h: ^Reader, t: tape.Token, m: ^Meta, dest: uintptr, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> Typed_Refusal {
	v, detail := enum_value(h, t, m.enum_info, number)
	if detail == .None {
		write_size(dest, u64(v), int(m.size))
	}
	return detail
}

// The value of the member of enum `info` that token `t` names, by name or under `.Int` by value.
@(private)
enum_value :: proc "contextless" (h: ^Reader, t: tape.Token, info: ^runtime.Type_Info_Enum, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> (i64, Typed_Refusal) {
	if h.plan.options.enums == .Int {
		if t.kind != .Number {
			return 0, .Expected_Integer
		}
		n := number(h.base[:h.len], t)
		if n.kind != .Int {
			return 0, .Not_A_Member
		}
		for x in info.values {
			if i64(x) == i64(n.bits) {
				return i64(n.bits), .None
			}
		}
		return 0, .Not_A_Member
	}
	if t.kind != .String && t.kind != .Plain {
		return 0, .Expected_Name
	}
	buf: [128]u8 = ---
	text, held, ok := token_text(h, t, buf[:])
	if !ok {
		return 0, .Not_A_Member
	}
	defer free_held(h, held)
	for name, i in info.names {
		if name == text {
			return i64(info.values[i]), .None
		}
	}
	return 0, .Not_A_Member
}

// Stores enum `info`'s member named `text` as `size` bytes at `dest`, for a map's key.
@(private)
store_enum_name :: proc "contextless" (h: ^Reader, info: ^runtime.Type_Info_Enum, text: string, dest: uintptr, size: int) -> Typed_Refusal {
	for name, i in info.names {
		if h.plan.options.enums == .Name && name == text || h.plan.options.enums == .Int && enum_text(text) == i64(info.values[i]) {
			write_size(dest, u64(info.values[i]), size)
			return .None
		}
	}
	return .Not_A_Member
}

// The integer a map key's `text` spells, or a value no enum holds when it spells none.
@(private)
enum_text :: proc "contextless" (text: string) -> i64 {
	n, ok := spell.number_strict(transmute([]u8)text, 0, u64(len(text)))
	return i64(n.bits) if ok && n.kind == .Int else min(i64)
}

// Sets the element token `t` names in the bit set at `dest`: a member's name or value, or an integer of its range.
@(private)
store_bit :: proc "contextless" (h: ^Reader, t: tape.Token, m: ^Meta, dest: uintptr, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> Typed_Refusal {
	v: i64
	if m.enum_info != nil {
		detail: Typed_Refusal
		if v, detail = enum_value(h, t, m.enum_info, number); detail != .None {
			return detail
		}
	} else {
		if t.kind != .Number {
			return .Expected_Integer
		}
		n := number(h.base[:h.len], t)
		v = i64(n.bits)
		if n.kind != .Int {
			// The number's text tells an integer past `i64` from a fraction.
			buf: [128]u8 = ---
			text, held, ok := token_text(h, t, buf[:])
			if !ok {
				return .Expected_Integer
			}
			detail := store_integer(n, true, text, .I64, uintptr(&v))
			free_held(h, held)
			if detail != .None {
				return detail
			}
		}
	}
	bit := v - m.lower
	if bit < 0 {
		return .Below_Minimum
	}
	if bit >= i64(m.count) {
		return .Above_Maximum
	}
	(^u8)(dest + uintptr(bit / 8))^ |= 1 << uint(bit % 8)
	return .None
}

// Stores a `time.Time` at `dest`: an RFC 3339 date-time with an offset, in UTC, a space taken for its `T`, or under
// CBOR's tag 1 a number of seconds since the Unix epoch.
@(private)
store_time :: proc "contextless" (h: ^Reader, t: tape.Token, dest: uintptr, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> Typed_Refusal {
	at: time.Time
	detail: Typed_Refusal
	#partial switch t.kind {
	case .Number:
		if h.epoch != t.lo {
			return .Expected_Date_Time
		}
		at, detail = epoch_time(number(h.base[:h.len], t))
	case .String, .Plain:
		at, detail = text_time(h, t)
	case:
		return .Expected_Date_Time
	}
	if detail == .None {
		(^time.Time)(dest)^ = at
	}
	return detail
}

// The instant `n` seconds after the Unix epoch.
@(private)
epoch_time :: proc "contextless" (n: spell.Number) -> (time.Time, Typed_Refusal) {
	#partial switch n.kind {
	case .Int:
		nsec, past := intrinsics.overflow_mul(i64(n.bits), 1e9)
		if past {
			return {}, .Out_Of_Range
		}
		return {nsec}, .None
	case .Float:
		// Written so NaN fails it, and judged on the product, which may round up to 2^63, the float of `max(i64)`.
		nsec := transmute(f64)n.bits * 1e9
		if !(abs(nsec) < f64(max(i64))) {
			return {}, .Out_Of_Range
		}
		return {i64(nsec)}, .None
	}
	return {}, .Out_Of_Range
}

// The instant of the date-time text token `t`.
@(private)
text_time :: proc "contextless" (h: ^Reader, t: tape.Token) -> (time.Time, Typed_Refusal) {
	buf: [64]u8 = ---
	text, held, ok := token_text(h, t, buf[:])
	if !ok {
		return {}, .Bad_Date_Time
	}
	defer free_held(h, held)
	nsec, spelled, in_range := spell.date_time_nsec(text, h.optional_seconds)
	if !spelled {
		return {}, .Bad_Date_Time
	}
	if !in_range {
		return {}, .Out_Of_Range
	}
	return {nsec}, .None
}
