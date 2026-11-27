package diff

import "base:runtime"
import "core:math"
import "core:strconv"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// Exact mathematical number normalization, equality, and canonical hashing across all `tape.Document` formats.

@(private = "file")
TWO_63 :: f64(1 << 63)
@(private = "file")
TWO_64 :: f64(1 << 64)
@(private = "file")
HASH_MOD :: u64((1 << 61) - 1)

@(private = "file")
mod_hash_p :: #force_inline proc "contextless" (v: u128) -> u64 {
	r := (v & u128(HASH_MOD)) + (v >> 61)
	r = (r & u128(HASH_MOD)) + (r >> 61)
	return 0 if u64(r) == HASH_MOD else u64(r)
}

@(private = "file")
hash_wide_int :: #force_inline proc "contextless" (neg: bool, rem: u64) -> u64 {
	return mix64(rem ~ (0x5555555555555555 if neg else 0xAAAAAAAAAAAAAAAA))
}

@(private = "file")
Num_Kind :: enum u8 {
	Int,
	Uint,
	Float,
	Wide_Int,
	Raw_Bytes, // unspellable binary number past format's decode limit (compared by exact raw bytes)
}

@(private = "file")
Num_Val :: struct {
	kind: Num_Kind,
	i:    i64,
	u:    u64,
	f:    f64,
	dec:  string,
}

@(private = "file")
float_num :: #force_inline proc "contextless" (f: f64) -> Num_Val {
	if f == math.trunc(f) && !math.is_inf(f) {
		if f >= -TWO_63 && f < TWO_63 {
			return {kind = .Int, i = i64(f)}
		}
		if f >= TWO_63 && f < TWO_64 {
			return {kind = .Uint, u = u64(f)}
		}
	}
	return {kind = .Float, f = f}
}

// Extracts canonical mathematical representation of a number node. When decoding a binary `.Wide` number requires heap
// space beyond `buf`, `owned` holds the temporary buffer for the caller to free in `alloc`.
// Invariant: `at` is a valid index in `doc.nodes`.
@(private = "file")
node_num :: proc(doc: ^tape.Document, at: tape.Node_Index, buf: []u8, alloc: runtime.Allocator) -> (val: Num_Val, owned: []u8) #no_bounds_check {
	n, _ := tape.node_number(doc, at)
	is_binary := doc.format != nil && .Binary in doc.format.caps
	switch n.kind {
	case .Int:
		return {kind = .Int, i = i64(n.bits)}, nil
	case .Uint:
		if n.bits <= u64(max(i64)) {
			return {kind = .Int, i = i64(n.bits)}, nil
		}
		return {kind = .Uint, u = n.bits}, nil
	case .Float:
		if !is_binary {
			form, _ := tape.number_form(doc, at)
			if form.frac_digits == 0 && !form.exponent && !form.point && form.kind == 0 {
				t := doc.nodes[at]
				return {kind = .Wide_Int, dec = string(tape.span_bytes(doc, t.lo, t.n))}, nil
			}
		}
		return float_num(transmute(f64)n.bits), nil
	case .Wide:
		t := doc.nodes[at]
		if is_binary {
			s, tmp, decoded := read_node_text(doc, at, buf, alloc)
			if !decoded {
				return {kind = .Raw_Bytes, dec = string(tape.span_bytes(doc, t.lo, t.n))}, nil
			}
			sn, valid := spell.number_strict(transmute([]u8)s, 0, u64(len(s)))
			if valid {
				switch sn.kind {
				case .Int:
					if tmp != nil {
						delete(tmp, alloc)
					}
					return {kind = .Int, i = i64(sn.bits)}, nil
				case .Uint:
					if tmp != nil {
						delete(tmp, alloc)
					}
					if sn.bits <= u64(max(i64)) {
						return {kind = .Int, i = i64(sn.bits)}, nil
					}
					return {kind = .Uint, u = sn.bits}, nil
				case .Float:
					if spell.is_plain_int_dec(s) {
						return {kind = .Wide_Int, dec = s}, tmp
					}
					if tmp != nil {
						delete(tmp, alloc)
					}
					return float_num(transmute(f64)sn.bits), nil
				case .Wide:
					if spell.is_plain_int_dec(s) {
						return {kind = .Wide_Int, dec = s}, tmp
					}
				}
			}
			f := spell.wide_double(transmute([]u8)s)
			if tmp != nil {
				delete(tmp, alloc)
			}
			return float_num(f), nil
		}
		form, _ := tape.number_form(doc, at)
		raw := tape.span_bytes(doc, t.lo, t.n)
		if form.frac_digits == 0 && !form.exponent && !form.point && form.kind == 0 {
			return {kind = .Wide_Int, dec = string(raw)}, nil
		}
		return float_num(spell.wide_double(raw)), nil
	}
	return {kind = .Int, i = 0}, nil
}

@(private = "file")
decimal_equal :: proc "contextless" (a, b: string) -> bool {
	an, ad := spell.decimal_parts(a)
	bn, bd := spell.decimal_parts(b)
	return an == bn && ad == bd
}

@(private, require_results)
numbers_equal :: proc(d: ^Differ, a, b: tape.Node_Index) -> bool {
	ba, bb: [256]u8 = ---, ---
	va, oa := node_num(d.docs[0], a, ba[:], d.scratch)
	defer if oa != nil {
		delete(oa, d.scratch)
	}
	vb, ob := node_num(d.docs[1], b, bb[:], d.scratch)
	defer if ob != nil {
		delete(ob, d.scratch)
	}
	if va.kind == .Float && math.is_nan(va.f) || vb.kind == .Float && math.is_nan(vb.f) {
		return false
	}
	if va.kind == vb.kind {
		switch va.kind {
		case .Int:
			return va.i == vb.i
		case .Uint:
			return va.u == vb.u
		case .Float:
			return va.f == vb.f
		case .Wide_Int:
			return decimal_equal(va.dec, vb.dec)
		case .Raw_Bytes:
			return va.dec == vb.dec
		}
	}
	// Cross-kind equality: `.Wide_Int` (strictly outside `[-2^63, 2^64-1]`) vs exact integer `.Float`.
	if va.kind == .Float && vb.kind == .Wide_Int {
		va, vb = vb, va
	}
	if va.kind == .Wide_Int && vb.kind == .Float {
		return wide_int_equals_float(va.dec, vb.f)
	}
	return false
}

@(private = "file")
wide_int_equals_float :: proc(dec: string, f: f64) -> bool {
	if math.is_nan(f) || math.is_inf(f) || f != math.trunc(f) {
		return false
	}
	if abs(f) < TWO_63 {
		return false
	}
	buf: [320]u8 = ---
	fd := strconv.write_float(buf[:], f, 'f', 0, 64, {})
	return decimal_equal(dec, fd)
}

// Canonical hash matching `numbers_equal`: `numbers_equal(a, b) => hash_number(a) == hash_number(b)`.
// Integers in `[-2^63, 2^63-1]` hash via `mix64(u64(i))`; all integers outside `i64` (`.Uint`, `.Wide_Int`,
// and integral `.Float`) hash via `hash_wide_int(neg, |n| mod (2^61 - 1))`.
@(private, require_results)
hash_number :: proc(d: ^Differ, doc: ^tape.Document, at: tape.Node_Index) -> u64 {
	buf: [256]u8 = ---
	v, owned := node_num(doc, at, buf[:], d.scratch)
	defer if owned != nil {
		delete(owned, d.scratch)
	}
	switch v.kind {
	case .Int:
		return mix64(u64(v.i))
	case .Uint:
		return hash_wide_int(false, mod_hash_p(u128(v.u)))
	case .Wide_Int:
		neg, digits := spell.decimal_parts(v.dec)
		acc: u64
		for c in transmute([]u8)digits {
			acc = mod_hash_p(u128(acc) * 10 + u128(c - '0'))
		}
		return hash_wide_int(neg, acc)
	case .Raw_Bytes:
		return hash_bytes(v.dec)
	case .Float:
		f := v.f
		if f == math.trunc(f) && !math.is_inf(f) {
			bits := transmute(u64)abs(f)
			m := (u64(1) << 52) | (bits & ((u64(1) << 52) - 1))
			exp := int((bits >> 52) & 0x7FF) - 1023 - 52
			rem := mod_hash_p(u128(m))
			if exp > 0 {
				// Multiply by 2^exp mod (2^61 - 1): 2^61 == 1 mod (2^61 - 1).
				shift := uint(exp % 61)
				rem = mod_hash_p(u128(rem) << shift)
			}
			return hash_wide_int(f < 0, rem)
		}
		return mix64(transmute(u64)f)
	}
	return 1
}
