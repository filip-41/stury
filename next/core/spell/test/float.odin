package spell_tests

import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import spell ".."

ROUNDS :: #config(ROUNDS, 200_000)
// The exhaustive binary32 check visits every `F32_STRIDE`th pattern on `F32_THREADS` threads. The default samples the
// range, and the gate's full tier sets the stride to 1.
F32_STRIDE :: #config(F32_STRIDE, 4099)
F32_THREADS :: #config(F32_THREADS, 1)

CANARY :: u8(0xAA)
MAX_REPORTS :: 5

Fault :: enum {
	None,
	Wrote_Past_Room,
	Not_Read_Back,
	Not_Shortest,
	Not_Closest,
	Bad_Layout,
}

Guarded :: [spell.F64_ROOM + 16]u8

splitmix :: proc "contextless" (state: ^u64) -> u64 {
	state^ += 0x9E3779B97F4A7C15
	z := state^
	z = (z ~ z >> 30) * 0xBF58476D1CE4E5B9
	z = (z ~ z >> 27) * 0x94D049BB133111EB
	return z ~ z >> 31
}

// The float whose pattern is the low bits of `bits`.
float_of :: proc "contextless" (bits: u64, $F: typeid) -> F {
	when F == f64 {
		return transmute(f64)bits
	} else {
		return transmute(f32)u32(bits)
	}
}

is_finite :: proc "contextless" (bits: u64, $F: typeid) -> bool {
	when F == f64 {
		return bits >> 52 & 0x7ff != 0x7ff
	} else {
		return bits >> 23 & 0xff != 0xff
	}
}

// The significant digits of a float's text with no leading or trailing zero, and the decimal point's place: the value
// is 0.DIGITS * 10^point.
split_text :: proc(text: string, digits: ^[32]u8) -> (k, point: int) {
	s := text[1:] if text[0] == '-' else text
	exp: int
	if e := strings.index_byte(s, 'e'); e >= 0 {
		exp, _ = strconv.parse_int(s[e + 1:], 10)
		s = s[:e]
	}
	n, before := 0, -1
	for c in transmute([]u8)s {
		if c == '.' {
			before = n
		} else {
			digits[n] = c
			n += 1
		}
	}
	if before < 0 {
		before = n
	}
	lead := 0
	for lead < n && digits[lead] == '0' {
		lead += 1
	}
	end := n
	for end > lead && digits[end - 1] == '0' {
		end -= 1
	}
	copy(digits[:], digits[lead:end])
	return end - lead, before - lead + exp
}

// jq 1.8.2's text of the digits D1..Dk with the decimal point after digit `point`.
layout_model :: proc(sb: ^strings.Builder, neg: bool, digits: []u8, point: int) {
	k := len(digits)
	if neg {
		strings.write_byte(sb, '-')
	}
	switch {
	case -3 <= point && point <= k + 15:
		switch {
		case point <= 0:
			strings.write_string(sb, "0.")
			for _ in 0 ..< -point {
				strings.write_byte(sb, '0')
			}
			strings.write_bytes(sb, digits)
		case point < k:
			strings.write_bytes(sb, digits[:point])
			strings.write_byte(sb, '.')
			strings.write_bytes(sb, digits[point:])
		case:
			strings.write_bytes(sb, digits)
			for _ in 0 ..< point - k {
				strings.write_byte(sb, '0')
			}
		}
	case:
		strings.write_byte(sb, digits[0])
		if k > 1 {
			strings.write_byte(sb, '.')
			strings.write_bytes(sb, digits[1:])
		}
		exp := point - 1
		strings.write_string(sb, "e-" if exp < 0 else "e+")
		magnitude := -exp if exp < 0 else exp
		if magnitude < 10 {
			strings.write_byte(sb, '0')
		}
		strings.write_int(sb, magnitude)
	}
}

// What is wrong with `text` as the shortest text of `f` that reads back as `f`.
fault_of :: proc(text: string, f: $F) -> Fault {
	back, nr, ok := strconv.parse_float_prefix_generic(F, text)
	if !ok || nr != len(text) || bits_of(back) != bits_of(f) {
		return .Not_Read_Back
	}
	neg := text[0] == '-'
	digits: [32]u8
	k, point := split_text(text, &digits)
	if k == 0 {
		return .None if text == "-0" || text == "0" else .Bad_Layout
	}
	if k > 1 {
		// A shorter text exists if either neighbour of the digits on the next coarser grid reads back, since the
		// interval of texts that read back is contiguous and holds the digits.
		prefix, _ := strconv.parse_u64_of_base(string(digits[:k - 1]), 10)
		for candidate in ([2]u64{prefix, prefix + 1}) {
			buf: [48]u8
			sb := strings.builder_from_bytes(buf[:])
			strings.write_u64(&sb, candidate)
			strings.write_byte(&sb, 'e')
			strings.write_int(&sb, point - k + 1)
			shorter, _, shorter_ok := strconv.parse_float_prefix_generic(F, strings.to_string(sb))
			if shorter_ok && bits_of(shorter) == bits_of(f) {
				return .Not_Shortest
			}
		}
	}
	when F == f64 {
		// `write_float` rounds the exact value to `k` digits in big decimal arithmetic, with no shortcut through zmij.
		// That text may not read back at a power of two, whose lower gap is half the upper one.
		exact: [48]u8
		near := strconv.write_float(exact[:], f, 'e', k - 1, 64)
		near = near[1:] if near[0] == '+' else near
		near_back, _, _ := strconv.parse_float_prefix_generic(f64, near)
		near_digits: [32]u8
		near_k, near_point := split_text(near, &near_digits)
		same := near_k == k && near_point == point && string(near_digits[:k]) == string(digits[:k])
		if !same && bits_of(near_back) == bits_of(abs(f)) {
			return .Not_Closest
		}
	}
	buf: [64]u8
	sb := strings.builder_from_bytes(buf[:])
	layout_model(&sb, neg, digits[:k], point)
	return .None if strings.to_string(sb) == text else .Bad_Layout
}

bits_of :: proc "contextless" (f: $F) -> u64 {
	when F == f64 {
		return transmute(u64)f
	} else {
		return u64(transmute(u32)f)
	}
}

// Writes `f` into `buf` between canaries and returns the text, or the fault that stopped the check.
check_float :: proc(buf: ^Guarded, f: $F) -> (text: string, fault: Fault) {
	for &b in buf {
		b = CANARY
	}
	n: int
	when F == f64 {
		n = spell.f64_text(raw_data(buf[:]), f)
	} else {
		n = spell.f32_text(raw_data(buf[:]), f)
	}
	for b in buf[spell.F64_ROOM:] {
		if b != CANARY {
			return "", .Wrote_Past_Room
		}
	}
	text = string(buf[:n])
	return text, fault_of(text, f)
}

// Checks each pattern of `all`, and reports the first few that fail.
verify :: proc(t: ^testing.T, all: []u64, $F: typeid) {
	reports := 0
	buf: Guarded
	for bits in all {
		if !is_finite(bits, F) {
			continue
		}
		f := float_of(bits, F)
		text, fault := check_float(&buf, f)
		if fault != .None && reports < MAX_REPORTS {
			testing.expectf(t, false, "%T pattern %#x wrote %q: %v", f, bits, text, fault)
			reports += 1
		}
	}
	testing.expect_value(t, reports, 0)
}

// Both signs of each pattern.
signed :: proc(all: ^[dynamic]u64, bits: u64, $F: typeid) {
	sign := u64(1) << (63 if F == f64 else 31)
	append(all, bits, bits | sign)
}

@(test)
f64_decided_samples :: proc(t: ^testing.T) {
	// jq 1.8.2 prints each of these values, multiplied by 1 so that it is a computed number, as the text beside it.
	Sample :: struct {
		f:    f64,
		text: string,
	}
	samples := [?]Sample {
		{0, "0"}, {transmute(f64)(u64(1) << 63), "-0"}, {1, "1"}, {-1, "-1"}, {3, "3"}, {0.1, "0.1"}, {100, "100"},
		{1e15, "1000000000000000"}, {1e16, "1e+16"}, {1e17, "1e+17"}, {1.5e17, "1.5e+17"},
		{999999999999999.9, "999999999999999.9"}, {123456789012345678, "123456789012345680"},
		{12345678.9e10, "123456789000000000"}, {1e21, "1e+21"}, {1e100, "1e+100"}, {1.5e300, "1.5e+300"},
		{0.001, "0.001"}, {0.0001, "0.0001"}, {0.00001, "1e-05"}, {1.5e-5, "1.5e-05"}, {0.000123, "0.000123"},
		{1e-6, "1e-06"}, {1e-7, "1e-07"}, {1.25e-7, "1.25e-07"}, {5e-324, "5e-324"},
		{1.7976931348623157e308, "1.7976931348623157e+308"}, {2.2250738585072014e-308, "2.2250738585072014e-308"},
		{0.30000000000000004, "0.30000000000000004"}, {1.0 / 3.0, "0.3333333333333333"},
		{9007199254740993, "9007199254740992"}, {1e22, "1e+22"}, {-2.5e-10, "-2.5e-10"},
	}
	buf: Guarded
	for s in samples {
		n := spell.f64_text(raw_data(buf[:]), s.f)
		testing.expect_value(t, string(buf[:n]), s.text)
	}
}

@(test)
f32_decided_samples :: proc(t: ^testing.T) {
	Sample :: struct {
		f:    f32,
		text: string,
	}
	samples := [?]Sample {
		{0, "0"}, {transmute(f32)(u32(1) << 31), "-0"}, {1, "1"}, {0.1, "0.1"}, {16777216, "16777216"},
		{3.4028235e38, "3.4028235e+38"}, {1e-45, "1e-45"}, {1.17549435e-38, "1.1754944e-38"}, {0.3, "0.3"},
		{1e15, "1000000000000000"}, {1e16, "1e+16"}, {0.0001, "0.0001"}, {0.00001, "1e-05"}, {-123.456, "-123.456"},
	}
	buf: Guarded
	for s in samples {
		n := spell.f32_text(raw_data(buf[:]), s.f)
		testing.expect_value(t, string(buf[:n]), s.text)
	}
}

@(test)
f64_every_binade_edge :: proc(t: ^testing.T) {
	all: [dynamic]u64
	defer delete(all)
	for e in u64(0) ..< 2047 {
		for mant in ([?]u64{0, 1, 2, 1 << 51, 1<<52 - 2, 1<<52 - 1}) {
			signed(&all, e << 52 | mant, f64)
		}
	}
	verify(t, all[:], f64)
}

@(test)
f64_powers_of_two_and_ten :: proc(t: ^testing.T) {
	all: [dynamic]u64
	defer delete(all)
	for k in 0 ..< 64 {
		bits := u64(1) << u64(k)
		append(&all, bits - 1, bits, bits + 1)
	}
	for k in -330 ..= 310 {
		for lead in ([?]string{"1", "5", "9.999999999999999", "2.2250738585072014"}) {
			buf: [48]u8
			sb := strings.builder_from_bytes(buf[:])
			strings.write_string(&sb, lead)
			strings.write_byte(&sb, 'e')
			strings.write_int(&sb, k)
			f, ok := strconv.parse_f64(strings.to_string(sb))
			if ok {
				bits := transmute(u64)f
				append(&all, bits - 1, bits, bits + 1)
			}
		}
	}
	verify(t, all[:], f64)
}

@(test)
f64_layout_thresholds :: proc(t: ^testing.T) {
	all: [dynamic]u64
	defer delete(all)
	for center in ([?]f64{1e-5, 1e-4, 1e-3, 1, 1e14, 1e15, 1e16, 1e17, 123456789012345.6, 99999999999999.99}) {
		bits := transmute(u64)center
		for delta in -3 ..= 3 {
			signed(&all, bits + u64(delta), f64)
		}
	}
	verify(t, all[:], f64)
}

@(test)
f64_subnormals :: proc(t: ^testing.T) {
	all: [dynamic]u64
	defer delete(all)
	for bits in u64(0) ..< 5000 {
		signed(&all, bits, f64)
	}
	state := u64(2)
	for _ in 0 ..< ROUNDS / 4 {
		signed(&all, splitmix(&state) & (1<<52 - 1), f64)
	}
	verify(t, all[:], f64)
}

@(test)
f64_random_bits :: proc(t: ^testing.T) {
	all := make([]u64, ROUNDS)
	defer delete(all)
	state := u64(1)
	for &bits in all {
		bits = splitmix(&state)
	}
	verify(t, all, f64)
}

@(test)
f64_short_decimals_and_integers :: proc(t: ^testing.T) {
	all: [dynamic]u64
	defer delete(all)
	state := u64(3)
	for _ in 0 ..< ROUNDS / 2 {
		r := splitmix(&state)
		digits := r % 1_000_000_000
		scale := r >> 40 % 14
		buf: [32]u8
		sb := strings.builder_from_bytes(buf[:])
		strings.write_u64(&sb, digits)
		strings.write_string(&sb, "e-")
		strings.write_u64(&sb, scale)
		f, _ := strconv.parse_f64(strings.to_string(sb))
		signed(&all, transmute(u64)f, f64)
		signed(&all, transmute(u64)(f64(r % 10_000_000) / 100), f64)
		signed(&all, transmute(u64)f64(r >> 11), f64)
	}
	for i in 0 ..< 20000 {
		signed(&all, transmute(u64)f64(i), f64)
	}
	verify(t, all[:], f64)
}

@(test)
f32_every_binade_edge :: proc(t: ^testing.T) {
	all: [dynamic]u64
	defer delete(all)
	for e in u64(0) ..< 255 {
		for mant in ([?]u64{0, 1, 2, 1 << 22, 1<<23 - 2, 1<<23 - 1}) {
			signed(&all, e << 23 | mant, f32)
		}
	}
	verify(t, all[:], f32)
}

@(test)
f32_random_bits :: proc(t: ^testing.T) {
	all := make([]u64, ROUNDS)
	defer delete(all)
	state := u64(4)
	for &bits in all {
		bits = splitmix(&state) & 0xffff_ffff
	}
	verify(t, all, f32)
}

@(test)
f32_short_decimals :: proc(t: ^testing.T) {
	all: [dynamic]u64
	defer delete(all)
	state := u64(5)
	for _ in 0 ..< ROUNDS / 2 {
		r := splitmix(&state)
		f := f32(r % 100_000) / 100
		signed(&all, u64(transmute(u32)f), f32)
		signed(&all, u64(transmute(u32)f32(r >> 40)), f32)
	}
	verify(t, all[:], f32)
}

Sweep :: struct {
	first, last: u64,
	faults:      int,
	witness:     u64,
}

sweep_f32 :: proc(data: rawptr) {
	sweep := (^Sweep)(data)
	buf: Guarded
	for bits := sweep.first; bits < sweep.last; bits += F32_STRIDE {
		if !is_finite(bits, f32) {
			continue
		}
		if _, fault := check_float(&buf, float_of(bits, f32)); fault != .None {
			if sweep.faults == 0 {
				sweep.witness = bits
			}
			sweep.faults += 1
		}
	}
}

// Every `F32_STRIDE`th binary32 pattern reads back and is the shortest, and the gate's full tier visits all 2^32.
@(test)
f32_exhaustive :: proc(t: ^testing.T) {
	sweeps: [F32_THREADS]Sweep
	threads: [F32_THREADS]^thread.Thread
	span := (u64(1) << 32) / F32_THREADS
	for &sweep, i in sweeps {
		sweep.first = u64(i) * span
		sweep.last = sweep.first + span
		threads[i] = thread.create_and_start_with_data(&sweep, sweep_f32)
	}
	for worker in threads {
		thread.join(worker)
		thread.destroy(worker)
	}
	for sweep in sweeps {
		testing.expectf(t, sweep.faults == 0, "%d binary32 patterns fail, first %#x", sweep.faults, sweep.witness)
	}
}
