// The typed write of a binary tree: a tree whose `Heads` part is not empty. Each item is a head, its argument and a
// payload, a container's head holds its count, and nothing separates or closes items, so the walk writes no
// punctuation and the format gives its heads as data.
package write

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:slice"
import "../spell"
import core ".."
import "../typed"

// The kinds of head a binary tree's `Heads` holds a form for, `HEAD_FORM` bytes each in this order. An argument up to
// a form's second byte is added to its first byte. A larger one takes the marker of its width, the third to sixth bytes
// for one, two, four and eight bytes, followed by the argument big-endian. A zero marker is a width the format has
// not, and the next wider one is taken. A negative integer's argument is `-1 - x`.
Head :: enum u8 {
	Uint,
	Nint,
	Bytes,
	Text,
	Array,
	Map,
	Tag,
}

@(private)
HEAD_FORM :: 6

// Where `Heads` holds the markers of a half, a single and a double float, after the head forms. A zero marker is a
// width the format has not.
@(private)
FLOAT_AT :: len(Head) * HEAD_FORM

// The length of a binary tree's `Heads`.
@(private)
HEADS_SIZE :: FLOAT_AT + 3

// The tag numbers `Heads` writes a number past 64 bits with: a positive and a negative bignum, and a decimal fraction.
@(private)
TAG_BIGNUM :: 2
@(private)
TAG_NEG_BIGNUM :: 3
@(private)
TAG_DECIMAL :: 4

// What a binary write decides that its tree does not: the form of a struct and the order of listed keys.
Binary_Options :: struct {
	positional:   bool, // a struct is an array of its members in their order, with no keys
	length_first: bool, // listed keys sort by their written length, then by their bytes
}

// The order an object's listed keys sort in: their text, their written bytes, or their written length and then bytes.
@(private)
Key_Order :: enum u8 {
	Text,
	Written,
	Length_First,
}

// `marshal_as` for a binary tree `T`, whose string writer `put` writes a text string's head and bytes. Pretty layout
// and escapes have no meaning in a binary text, and `sort_keys` orders struct members by their written keys.
marshal_binary :: proc(plan: ^typed.Plan, value: rawptr, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator, omits: ^typed.Omits, binary: Binary_Options, $T: Tree, $put: Put) -> ([]u8, core.Typed_Refusal) {
	spill: [ROOM_MAX]u8 = ---
	out: Out
	init(&out, &spill, allocator, stream)
	err: core.Typed_Refusal
	kind := marshal_binary_into(&out, plan, value, opts, omits, binary, &err, T, put)
	err.kind = kind
	return finish(&out, err)
}

// Writes `value` by `plan` at `out` as `marshal_binary` does, with nothing around it: a token write's record. A refusal's
// kind and path go to `err`, and the kind is returned.
marshal_binary_into :: proc(out: ^Out, plan: ^typed.Plan, value: rawptr, opts: core.Write_Options, omits: ^typed.Omits, binary: Binary_Options, err: ^core.Typed_Refusal, $T: Tree, $put: Put) -> core.Typed_Error_Kind {
	#assert(len(T[.Heads]) == HEADS_SIZE)
	frames: [FRAMES]Frame = ---
	ptrs: [core.MAX_DEPTH]Target = ---
	w: Walker
	w.out = out^
	walker_init(&w, opts, raw_data(frames[:]), raw_data(ptrs[:]))
	w.omits, w.positional = omits, binary.positional
	w.key_order = .Length_First if binary.length_first else .Written
	w.plan, w.meta = plan, raw_data(plan.meta)
	kind := walk(&w, uintptr(value), false, T, put, false)
	out^ = w.out
	if kind != .None {
		err^ = w.err
		err.kind, err.cause = kind, out.cause
	}
	release_walker(&w)
	return kind
}

// Writes the head of kind `h` for argument `n` at `p`, which holds 9 bytes, and returns its length.
put_head :: #force_inline proc "contextless" (p: [^]u8, n: u64, $T: Tree, $h: Head) -> int #no_bounds_check {
	H :: T[.Heads]
	A :: int(h) * HEAD_FORM
	if n <= u64(H[A + 1]) {
		p[0] = H[A] + u8(n)
		return 1
	}
	when H[A + 2] != 0 {
		if n <= 0xff {
			p[0], p[1] = H[A + 2], u8(n)
			return 2
		}
	}
	when H[A + 3] != 0 {
		if n <= 0xffff {
			p[0] = H[A + 3]
			intrinsics.unaligned_store((^u16be)(p[1:]), u16be(n))
			return 3
		}
	}
	when H[A + 4] != 0 {
		if n <= 0xffff_ffff {
			p[0] = H[A + 4]
			intrinsics.unaligned_store((^u32be)(p[1:]), u32be(n))
			return 5
		}
	}
	p[0] = H[A + 5]
	intrinsics.unaligned_store((^u64be)(p[1:]), u64be(n))
	return 9
}

// Writes integer `x` at `p`, which holds 9 bytes, and returns its length.
@(private)
put_int :: #force_inline proc "contextless" (p: [^]u8, x: i64, $T: Tree) -> int {
	if x >= 0 {
		return put_head(p, u64(x), T, .Uint)
	}
	return put_head(p, ~u64(x), T, .Nint)
}

// Writes `x` at `p`, which holds 9 bytes, as the narrowest float of the tree that holds it exactly, and returns its
// length. A NaN keeps its sign and as much of its payload as the width it is written in holds whole.
@(private)
put_float :: #force_inline proc "contextless" (p: [^]u8, x: f64, $T: Tree) -> int #no_bounds_check {
	H :: T[.Heads]
	bits := transmute(u64)x
	when H[FLOAT_AT + 1] != 0 {
		single: u32
		fits: bool
		if x == x {
			s := f32(x)
			single, fits = transmute(u32)s, f64(s) == x
		} else {
			single, fits = u32(bits >> 32) & 0x8000_0000 | 0x7f80_0000 | u32(bits >> 29) & 0x7f_ffff, bits & (1 << 29 - 1) == 0
		}
		if fits {
			when H[FLOAT_AT] != 0 {
				if half, ok := half_of(single); ok {
					p[0] = H[FLOAT_AT]
					intrinsics.unaligned_store((^u16be)(p[1:]), u16be(half))
					return 3
				}
			}
			p[0] = H[FLOAT_AT + 1]
			intrinsics.unaligned_store((^u32be)(p[1:]), u32be(single))
			return 5
		}
	}
	p[0] = H[FLOAT_AT + 2]
	intrinsics.unaligned_store((^u64be)(p[1:]), u64be(bits))
	return 9
}

// The binary16 bits of the binary32 `single` when they hold the same value, a NaN's payload included.
@(private)
half_of :: #force_inline proc "contextless" (single: u32) -> (u16, bool) {
	sign := u16(single >> 16) & 0x8000
	e := int(single >> 23) & 0xff
	m := single & 0x7f_ffff
	switch {
	case e == 0xff:
		return sign | 0x7c00 | u16(m >> 13), m & 0x1fff == 0
	case e == 0:
		return sign, m == 0
	case e >= 113 && e <= 142:
		return sign | u16(e - 112) << 10 | u16(m >> 13), m & 0x1fff == 0
	case e >= 103 && e < 113:
		// A half's subnormal is a multiple of 2^-24, which the significand shifted by `126 - e` must give exactly.
		full := m | 0x80_0000
		shift := uint(126 - e)
		return sign | u16(full >> shift), full & (1 << shift - 1) == 0
	}
	return 0, false
}

// The head of the struct of record `f` at `v`, at `p`, which holds 9 bytes: the array of its members by position, or
// the map of the members a keyed write leaves in.
@(private)
struct_head :: #force_inline proc(w: ^Walker, f: ^typed.Field, v: uintptr, p: [^]u8, $T: Tree) -> int #no_bounds_check {
	m := &w.meta[f.meta]
	if w.positional {
		return put_head(p, u64(m.members), T, .Array)
	}
	n := u64(m.members)
	if w.meta[m.block + m.members].omits {
		n = written_members(w, f.first, v)
	}
	return put_head(p, n, T, .Map)
}

// How many of the members from `r` on a keyed write writes of the struct at `v`.
@(cold)
@(private)
written_members :: proc(w: ^Walker, r: ^typed.Field, v: uintptr) -> (n: u64) {
	for r := r; r.kind != .Never; r = intrinsics.ptr_offset(r, 1) {
		if !r.omit || !is_empty(w, r, v + uintptr(r.offset)) {
			n += 1
		}
	}
	return
}

// `leaf` of a binary tree.
@(private)
binary_leaf :: #force_no_inline proc(w: ^Walker, f: ^typed.Field, v: uintptr, top: int, $T: Tree, $put: Put) -> core.Typed_Error_Kind #no_bounds_check {
	out := &w.out
	m := &w.meta[f.meta]
	p := room(out, LEAF_ROOM)
	#partial switch f.kind {
	case .I8, .I16, .I32:
		out.cursor += put_int(p, i64(loaded(v, 1 << (uint(f.kind) - uint(typed.Read_Kind.I8)), true)), T)
	case .U8, .U16, .U32, .U64:
		out.cursor += put_head(p, loaded(v, 1 << (uint(f.kind) - uint(typed.Read_Kind.U8))), T, .Uint)
	case .F32:
		out.cursor += put_float(p, f64((^f32)(v)^), T)
	case .Bool_Wide:
		out.cursor += put_bool(p, loaded(v, int(m.size)) != 0, T)
	case .Cstring:
		cs := (^cstring)(v)^
		if cs == nil {
			out.cursor += put_word(p, T[.Null])
			return .None
		}
		return put(out, p, string(cs), &w.opts)
	case .Enum:
		return binary_enum(w, m.enum_info, enum_value(m.enum_info, v), T, put)
	case .Raw:
		return binary_raw(w, string((^typed.Raw)(v)^), top - w.n_ptrs, T)
	case .Value:
		// A built value is written by the format's token write, which a binary format's plans hold.
		text, err := value_text(w.plan, (^core.Value)(v)^, context.temp_allocator)
		if err.kind == .None {
			put_text(&w.out, string(text))
		}
		return err.kind
	case .Number_Text:
		return put_binary_number_text(&w.out, (^core.Number_Text)(v).text, T)
	case .Number:
		return put_binary_number(out, (^core.Number)(v)^, T)
	case .Bytes:
		return binary_bytes(out, cast([]u8)(^typed.Bytes)(v)^, T)
	case .Scalar:
		s := (^typed.Scalar)(v)^
		if text, is_text := s.(core.Number_Text); is_text {
			return put_binary_number_text(&w.out, text.text, T)
		}
		_, k := any_value(w, any{rawptr(v), scalar_type(s)}, T, put)
		return k
	case .Bit_Set:
		return binary_bit_set(w, m, v, top - w.n_ptrs, T, put)
	case:
		return .Unsupported
	}
	return .None
}

// An enum as `enum_spelled` spells it: its name as a text string, or under `.Int` its integer.
@(private)
binary_enum :: proc(w: ^Walker, info: ^runtime.Type_Info_Enum, value: i64, $T: Tree, $put: Put) -> core.Typed_Error_Kind {
	p := room(&w.out, LEAF_ROOM)
	if typed.enum_by_number(w.plan, info) {
		if typed.enum_member(info, value) < 0 {
			return .Not_A_Member
		}
		if base, ok := runtime.type_info_base(info.base).variant.(runtime.Type_Info_Integer); ok && !base.signed {
			w.out.cursor += put_head(p, u64(value), T, .Uint)
		} else {
			w.out.cursor += put_int(p, value, T)
		}
		return .None
	}
	text: [spell.INT_ROOM]u8
	name := enum_spelled(w.plan, info, value, &text[0]) or_return
	return put(&w.out, p, name, &w.opts)
}

// A bit set as an array of its elements in ascending order, as `put_bit_set` writes one.
@(private)
binary_bit_set :: proc(w: ^Walker, m: ^typed.Meta, v: uintptr, top: int, $T: Tree, $put: Put) -> core.Typed_Error_Kind {
	out := &w.out
	if top == core.MAX_DEPTH {
		return .Too_Deep
	}
	e := &w.meta[m.block]
	bits: u128
	runtime.mem_copy_non_overlapping(&bits, rawptr(v), int(m.size))
	out.cursor += put_head(room(out, 9), u64(intrinsics.count_ones(bits)), T, .Array)
	for b := bits; b != 0; b &= b - 1 {
		value := e.lower + i64(intrinsics.count_trailing_zeros(b))
		if e.enum_info == nil {
			out.cursor += put_int(room(out, 9), value, T)
		} else {
			binary_enum(w, e.enum_info, value, T, put) or_return
		}
	}
	return .None
}

// A byte string's head and its bytes.
@(private)
binary_bytes :: proc(out: ^Out, b: []u8, $T: Tree) -> core.Typed_Error_Kind {
	out.cursor += put_head(room(out, 9), u64(len(b)), T, .Bytes)
	put_text(out, string(b))
	return .None
}

// A `Raw`, the bytes of one item of the format, checked by the plan's `raw` and copied. An empty one is null. Its
// containers nest inside the `top` frames open.
@(private)
binary_raw :: proc(w: ^Walker, s: string, top: int, $T: Tree) -> core.Typed_Error_Kind {
	if len(s) == 0 {
		put_text(&w.out, T[.Null])
		return .None
	}
	if w.plan.raw == nil {
		return .Unsupported
	}
	text := transmute([]u8)s
	view := core.Token_View{as = w.plan.as}
	view.max_depth = u32(core.MAX_DEPTH - top)
	if top == core.MAX_DEPTH {
		// A depth of 0 is no limit, so with no level left the item is judged as the one element of an array, a level deep.
		head: [9]u8
		n := put_head(raw_data(head[:]), 1, T, .Array)
		held, failed := make([]u8, n + len(s), context.temp_allocator)
		if failed != nil {
			return .No_Memory
		}
		copy(held[copy(held, head[:n]):], s)
		text, view.max_depth = held, 1
	}
	if e := w.plan.raw(&view, text, context.allocator); e.kind != .None {
		return .Too_Deep if e.inner.kind == .Too_Deep else .Bad_Raw
	}
	put_text(&w.out, s)
	return .None
}

// A number by its value in binary tree `T`. A `Wide` one holds no value.
put_binary_number :: proc(out: ^Out, n: core.Number, $T: Tree) -> core.Typed_Error_Kind {
	p := room(out, 9)
	switch n.kind {
	case .Int:
		out.cursor += put_int(p, i64(n.bits), T)
	case .Uint:
		out.cursor += put_head(p, n.bits, T, .Uint)
	case .Float:
		out.cursor += put_float(p, transmute(f64)n.bits, T)
	case .Wide:
		return .Non_Finite
	}
	return .None
}

// The JSON number `s` in binary tree `T`: an integer that 64 bits hold, a fraction or an exponent as binary64 reads it,
// an integer past 64 bits as a bignum, and a number past binary64's range, or one that binary64 rounds to zero, as the
// decimal fraction of its exponent and its significand. An empty one is null, and any other text is `.Bad_Raw`.
put_binary_number_text :: proc(out: ^Out, s: string, $T: Tree) -> core.Typed_Error_Kind {
	if len(s) == 0 {
		put_text(out, T[.Null])
		return .None
	}
	n, ok := number_of_text(s)
	if !ok {
		return .Bad_Raw
	}
	neg := s[0] == '-'
	digits := s[1:] if neg else s
	point, exp_at := len(digits), len(digits)
	zero := true
	for c, i in transmute([]u8)digits {
		if c == '.' {
			point = i
		} else if c == 'e' || c == 'E' {
			exp_at = i
			break
		} else if c != '0' {
			zero = false
		}
	}
	integer := point == len(digits) && exp_at == len(digits)
	finite := n.bits & F64_EXPONENT != F64_EXPONENT
	if n.kind == .Int || n.kind == .Uint || n.kind == .Float && !integer && finite && (zero || n.bits << 1 != 0) {
		return put_binary_number(out, n, T)
	}
	when T[.Heads][int(Head.Tag) * HEAD_FORM + 5] == 0 {
		return .Non_Finite
	} else {
		exp := 0
		if exp_at < len(digits) {
			e, parsed := parse_exponent(digits[exp_at + 1:])
			if !parsed {
				return .Non_Finite
			}
			exp = e
		}
		whole := digits[:min(point, exp_at)]
		fraction := digits[point + 1:exp_at] if point < exp_at else ""
		exp -= len(fraction)
		if exp == 0 {
			return put_bignum(out, whole, fraction, neg, T)
		}
		out.cursor += put_head(room(out, 9), TAG_DECIMAL, T, .Tag)
		out.cursor += put_head(room(out, 9), 2, T, .Array)
		out.cursor += put_int(room(out, 9), i64(exp), T)
		return put_bignum(out, whole, fraction, neg, T)
	}
}

// The exponent bits of a binary64, all set for an infinity and a NaN.
@(private)
F64_EXPONENT :: u64(0x7ff) << 52

@(private)
number_of_text :: proc(s: string) -> (core.Number, bool) {
	return spell.number_strict(transmute([]u8)s, 0, u64(len(s)))
}

// The exponent digits `text`, with their sign, within what a decimal fraction's exponent holds.
@(private)
parse_exponent :: proc(text: string) -> (int, bool) {
	neg := len(text) > 0 && text[0] == '-'
	digits := text[1:] if len(text) > 0 && (text[0] == '-' || text[0] == '+') else text
	e := 0
	for c in transmute([]u8)digits {
		e = e * 10 + int(c - '0')
		if e > 1 << 40 {
			return 0, false
		}
	}
	return -e if neg else e, len(digits) > 0
}

// The integer of the decimal digits `whole` then `fraction`, negative when `neg`: an integer when it fits 64 bits, else
// the bignum of its magnitude, `-1 - x` for a negative one, big-endian with no leading zero byte.
@(private)
put_bignum :: proc(out: ^Out, whole, fraction: string, neg: bool, $T: Tree) -> core.Typed_Error_Kind {
	// Base 2^32 words, the least significant first.
	words, failed := make([dynamic]u32, 0, (len(whole) + len(fraction)) / 9 + 1, context.temp_allocator)
	if failed != nil {
		return .No_Memory
	}
	for part in ([2]string{whole, fraction}) {
		for c in transmute([]u8)part {
			carry := u64(c - '0')
			for &x in words {
				y := u64(x) * 10 + carry
				x, carry = u32(y), y >> 32
			}
			if carry > 0 {
				if _, grew := append(&words, u32(carry)); grew != nil {
					return .No_Memory
				}
			}
		}
	}
	if neg {
		// `-1 - x` of a magnitude that is not zero is the magnitude less one.
		for &x in words {
			x -= 1
			if x != max(u32) {
				break
			}
		}
	}
	for len(words) > 0 && words[len(words) - 1] == 0 {
		pop(&words)
	}
	if len(words) <= 2 {
		x := u64(words[0]) if len(words) > 0 else 0
		if len(words) == 2 {
			x |= u64(words[1]) << 32
		}
		if neg {
			out.cursor += put_head(room(out, 9), x, T, .Nint)
		} else {
			out.cursor += put_head(room(out, 9), x, T, .Uint)
		}
		return .None
	}
	top := words[len(words) - 1]
	lead := int(intrinsics.count_leading_zeros(top)) / 8
	size := 4 * len(words) - lead
	p := room(out, 18)
	out.cursor += put_head(p, TAG_NEG_BIGNUM if neg else TAG_BIGNUM, T, .Tag)
	out.cursor += put_head(room(out, 9), u64(size), T, .Bytes)
	for i := 3 - lead; i >= 0; i -= 1 {
		put_byte(out, u8(top >> uint(8 * i)))
	}
	#reverse for x in words[:len(words) - 1] {
		q := room(out, 4)
		intrinsics.unaligned_store((^u32be)(q), u32be(x))
		out.cursor += 4
	}
	return .None
}

// `any_value`'s scalars in a binary tree, with false for a type it leaves to a side plan.
@(private)
binary_any :: proc(w: ^Walker, a: any, p: [^]u8, $T: Tree, $put: Put) -> (kind: core.Typed_Error_Kind, done: bool) {
	out := &w.out
	switch a.id {
	case typeid_of(string):
		return put(out, p, (^string)(a.data)^, &w.opts), true
	case typeid_of(bool):
		out.cursor += put_bool(p, (^bool)(a.data)^, T)
	case typeid_of(i64):
		out.cursor += put_int(p, (^i64)(a.data)^, T)
	case typeid_of(u64):
		out.cursor += put_head(p, (^u64)(a.data)^, T, .Uint)
	case typeid_of(f64):
		out.cursor += put_float(p, (^f64)(a.data)^, T)
	case typeid_of(typed.Bytes):
		return binary_bytes(out, cast([]u8)(^typed.Bytes)(a.data)^, T), true
	case typeid_of(core.Number_Text):
		return put_binary_number_text(&w.out, (^core.Number_Text)(a.data).text, T), true
	case:
		return .None, false
	}
	return .None, true
}

// A map key that is not a string, written as the tree writes its value: an integer as an integer and an enum by its
// spelling. Its text follows its written bytes in `keys`, as `add_entry` leaves a string key's.
@(private)
binary_key_entry :: proc(w: ^Walker, m: ^typed.Meta, key, value: uintptr, rec: ^typed.Field, $T: Tree, $put: Put) -> core.Typed_Error_Kind {
	text: [spell.INT_ROOM]u8
	name: string
	#partial switch m.key_kind {
	case .Cstring:
		return add_entry(w, string((^cstring)(key)^), value, rec, put)
	case .Enum:
		if !typed.enum_by_number(w.plan, m.enum_info) {
			name = enum_spelled(w.plan, m.enum_info, enum_value(m.enum_info, key), &text[0]) or_return
			return add_entry(w, name, value, rec, put)
		}
	}
	at := w.keys.cursor
	p := room(&w.keys, 9)
	signed := m.key_kind == .Enum || m.key_kind >= .I8 && m.key_kind <= .I64
	x: i64
	if m.key_kind == .Enum {
		x = enum_value(m.enum_info, key)
		if typed.enum_member(m.enum_info, x) < 0 {
			return .Not_A_Member
		}
		name = string(text[:spell.i64_text(&text[0], x)])
	} else {
		name = string(text[:int_text(&text[0], m.key_kind, key)])
		if signed {
			x = i64(loaded(key, 1 << (uint(m.key_kind) - uint(typed.Read_Kind.I8)), true))
		}
	}
	if signed {
		w.keys.cursor += put_int(p, x, T)
	} else {
		w.keys.cursor += put_head(p, loaded(key, 1 << (uint(m.key_kind) - uint(typed.Read_Kind.U8))), T, .Uint)
	}
	size := w.keys.cursor - at
	put_text(&w.keys, name)
	if _, failed := append(&w.entries, Entry{at = at, size = size, named = len(name), value = value, rec = rec}); failed != nil {
		return .No_Memory
	}
	return w.keys.err
}

// Sorts the entries from `first` by their written keys, the length first under `.Length_First`.
@(private)
sort_written :: proc(w: ^Walker, first: int) {
	entries := w.entries[first:]
	for &e in entries {
		e.text = string(w.keys.buf[e.at:][:e.size])
	}
	if w.key_order == .Length_First {
		slice.sort_by(entries, proc(a, b: Entry) -> bool {
			return len(a.text) < len(b.text) || len(a.text) == len(b.text) && a.text < b.text
		})
	} else {
		slice.sort_by(entries, proc(a, b: Entry) -> bool {return a.text < b.text})
	}
}
