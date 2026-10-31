package json_tests

// The decimal reader against `strconv.parse_f64`, bit for bit, over the shapes `json.number` converts without the
// grammar search: a 16 to 19 digit significand with a fraction or an exponent. `STURY_NUMBER_CASES` raises the count
// for a run outside the suite (`odin test json/test -o:speed`); the default is what `make test` runs.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:testing"
import core "../../core"
import json ".."

NUMBER_CASES :: 2_000_000
NUMBER_SEED :: u64(0x9E37_79B9_7F4A_7C15)
NUMBER_CHUNK :: 2048

number_rng :: proc(s: ^u64) -> u64 {
	s^ ~= s^ << 13
	s^ ~= s^ >> 7
	s^ ~= s^ << 17
	return s^
}

// Writes `v` in decimal into `buf` ending at `end`, and returns the first byte written.
number_digits :: proc(buf: []u8, end: int, v: u64) -> int {
	p := end
	w := v
	for {
		p -= 1
		buf[p] = u8('0' + w % 10)
		w /= 10
		if w == 0 {
			return p
		}
	}
}

// Appends the decimal `-?d.d e±e` for one case, and returns nothing: the caller reads the bytes back through
// `parse_f64` and `json.number`, so the text is the only record of the case.
number_case_text :: proc(text: ^[dynamic]u8, rng: ^u64, scratch: []u8, halfway: bool) {
	d := int(number_rng(rng) % 4) + 16
	digits: [24]u8
	digits[0] = u8('1' + number_rng(rng) % 9)
	for j in 1 ..< d {
		digits[j] = u8('0' + number_rng(rng) % 10)
	}
	if digits[d - 1] == '0' {
		digits[d - 1] = '7'
	}
	neg := number_rng(rng) & 1 == 1
	if neg {
		append(text, '-')
	}
	mode := number_rng(rng) % 3
	if halfway {
		// An exact binary64 midpoint: an odd 53-bit integer scaled by 5^f so it spells as a decimal of `d` digits
		// with the point `f` digits from the end. Its tie must round to even.
		f := int(number_rng(rng) % 22) + 1
		odd := (number_rng(rng) & ((u64(1) << 52) - 1)) | (u64(1) << 52)
		w := u128(odd)
		for _ in 0 ..< f {
			w *= 5
		}
		// Drop the 2^-f the midpoint needs by shifting the digits right where that keeps 16..19 of them.
		for w >= u128(10) * u128(10_000_000_000_000_000) {
			w /= 10
			f -= 1
		}
		if f > 0 && w <= u128(max(u64)) {
			st := int(number_digits(scratch, len(scratch), u64(w)))
			whole := len(scratch) - f
			if whole > st && whole < len(scratch) {
				append(text, ..scratch[st:whole])
				append(text, '.')
				append(text, ..scratch[whole:])
				return
			}
		}
		mode = 2
	}
	switch mode {
	case 0, 1:
		ip := int(number_rng(rng) % u64(d - 1)) + 1
		append(text, ..digits[:ip])
		append(text, '.')
		append(text, ..digits[ip:d])
	case:
		append(text, ..digits[:d])
		e := int(number_rng(rng) % 45) - 22
		if e == 0 {
			e = -7
		}
		append(text, 'e')
		if e > 0 {
			append(text, '+')
		}
		s := int(number_digits(scratch, len(scratch), u64(abs(e))))
		append(text, ..scratch[s:])
	}
}

@(test)
number_arm_agrees :: proc(t: ^testing.T) {
	cases := NUMBER_CASES
	if s := os.get_env("STURY_NUMBER_CASES", context.temp_allocator); s != "" {
		if n, ok := strconv.parse_int(s); ok && n > 0 {
			cases = n
		}
	}
	text: [dynamic]u8
	defer delete(text)
	los, lens: [NUMBER_CHUNK]int
	scratch: [24]u8
	rng := NUMBER_SEED
	done := 0
	for done < cases {
		n := min(NUMBER_CHUNK, cases - done)
		clear(&text)
		append(&text, '[')
		for k in 0 ..< n {
			if k > 0 {
				append(&text, ',')
			}
			los[k] = len(text)
			number_case_text(&text, &rng, scratch[:], k % 4 == 3)
			lens[k] = len(text) - los[k]
		}
		append(&text, ']')
		doc, err := json.build(transmute([]u8)string(text[:]), .Json, {}, .Last, context.allocator)
		if !testing.expectf(t, err.kind == .None, "chunk %d: build %v", done, err) {
			core.destroy(&doc)
			return
		}
		for k in 0 ..< n {
			got := json.number(&doc, u32(1 + k))
			field := string(text[los[k]:los[k] + lens[k]])
			want, ok := strconv.parse_f64(field)
			if !ok || got.kind != .Float || got.bits != transmute(u64)want {
				testing.expectf(
					t,
					false,
					"case %d %q: bits %x kind %v, parse_f64 %x ok %v",
					done + k,
					field,
					got.bits,
					got.kind,
					transmute(u64)want,
					ok,
				)
				core.destroy(&doc)
				return
			}
		}
		core.destroy(&doc)
		done += n
	}
	fmt.printfln("number arm: %d decimals compared with strconv.parse_f64", done)
}

// Spellings whose shape is not the fast arm's: a leading plus, a leading or trailing point, hex, and an exponent
// with no fraction, in each spec that accepts them. Each must read the same through `json.number` as through
// `strconv.parse_f64`, so a span the recorded shape does not describe takes the slow path.
number_slow_of :: proc(t: ^testing.T, $S: json.Spec, texts: []string) {
	for text in texts {
		doc, err := json.build(transmute([]u8)text, S, {}, .Last, context.allocator)
		if !testing.expectf(t, err.kind == .None, "%v %q: build %v", S, text, err) {
			continue
		}
		got := json.number(&doc, 0)
		want, ok := strconv.parse_f64(text)
		testing.expectf(
			t,
			ok && got.bits == transmute(u64)want,
			"%v %q: bits %x kind %v, parse_f64 %x",
			S,
			text,
			got.bits,
			got.kind,
			transmute(u64)want,
		)
		core.destroy(&doc)
	}
}

@(test)
number_slow_spellings :: proc(t: ^testing.T) {
	number_slow_of(t, .Json, {"1.5", "-1.5e3", "1234567890123456.7", "-12345678901234567.8e-22", "0.0000000000000001", "-7.5e21"})
	number_slow_of(t, .Jsonc, {"1.5", "-1.5e3", "1234567890123456.7", "7.25e7"})
	number_slow_of(t, .Json5, {"+1.5", ".5", "-.5", "5.", "+12345678901234567.", "+.5e-3", "-0.0", "-1.25e-19"})
}
