package json_tests

// Number readers: a token's `Number` result, and the integer and float readers.

import json "../.."
import scan "../../scan"
import "core:strconv"
import "core:strings"
import "core:testing"

// A token's exactness, `2.5`, `0.0` and `1e2` included, read alone and behind
// `PAD`, where the read folds its digits from the counts the build kept (`number_token`).
@(test)
test_number_exactness_is_one_verdict :: proc(t: ^testing.T) {
	cases := []struct {
		tok:   string,
		value: f64,
		want:  json.Exactness,
	}{
		{"2.5", 2.5, .Exact},
		{"0.0", 0, .Exact},
		{"1e2", 100, .Exact},
		{"0", 0, .Exact},
		{"0e5", 0, .Exact},
		{"1", 1, .Exact},
		{"9007199254740992", 9007199254740992, .Exact},
		{"9007199254740993", 9007199254740992, .Inexact},
		{"0.1", 0.1, .Inexact},
		{"1e23", 1e23, .Inexact},
		{"1e-400", 0, .Underflowed},
		{"1e400", 0, .None},
		{"1e309", 0, .None},
		{"-1e400", 0, .None},
		// Past 2^53 an integer whose binary64 is the authored value is `.Exact`, through the integer arm
		// and the Eisel-Lemire arm's scaled significand alike.
		{"9007199254740994", 9007199254740994, .Exact},
		{"18014398509481984", 18014398509481984, .Exact},
		{"9223372036854775808", 9223372036854775808, .Exact},
		{"-9223372036854775808", -9223372036854775808, .Exact},
		{"9223372036854775807", 9223372036854775808, .Inexact},
		{"9007199254740994.0", 9007199254740994, .Exact},
		{"9007199254740993.0", 9007199254740992, .Inexact},
	}
	defer free_all(context.temp_allocator)
	for c in cases do for pad in ([]string{"", PAD}) {
		doc := build_ok(t, strings.concatenate({pad, c.tok}, context.temp_allocator))
		defer json.destroy(&doc)
		want := json.Number{c.value, c.want}
		// A number past binary64's range is still a number: `ok`, with `.None` and +0 for its value.
		got, got_ok := json.get_number(&doc, json.ROOT)
		testing.expectf(t, got_ok && got == want && transmute(u64)got.value == transmute(u64)c.value, "%s: get_number %v %v, want %v", c.tok, got, got_ok, want)
		// `get_float` is the same value, refused only where there is none.
		f, f_ok := json.get_float(&doc, json.ROOT)
		testing.expectf(t, f_ok == (c.want != .None) && transmute(u64)f == transmute(u64)c.value, "%s: get_float %v %v", c.tok, f, f_ok)
	}
}

// Whitespace that puts a root token past the 24 bytes a document's number read folds back over.
@(private = "file")
PAD :: "                        "

// A document number reads the same at the start of its source, where the read folds its digits by byte, and
// behind `PAD`, where it folds words of the runs the build counted: every split of up to 21 digits into an
// integer and a fraction run, signed and not, with and without an exponent.
@(test)
test_a_number_reads_alike_from_its_counts_and_its_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	digits := "918273645546372819012"
	for n in 1 ..= len(digits) {
		for int_n in 1 ..= n {
			for sign in ([]string{"", "-"}) {
				for exp in ([]string{"", "e5", "E-17", "e+300", "e-330"}) {
					tok := strings.concatenate({sign, digits[:int_n], "." if int_n < n else "", digits[int_n:n], exp}, context.temp_allocator)
					alone := build_ok(t, tok)
					behind := build_ok(t, strings.concatenate({PAD, tok}, context.temp_allocator))
					a, _ := json.get_number(&alone, json.ROOT)
					b, _ := json.get_number(&behind, json.ROOT)
					want, _ := strconv.parse_f64(tok)
					json.destroy(&alone)
					json.destroy(&behind)
					same := a == b && transmute(u64)a.value == transmute(u64)b.value
					if !testing.expectf(t, same && (a.exactness == .None || a.value == want), "%s: alone %v, behind %v, strconv %v", tok, a, b, want) {
						return
					}
				}
			}
		}
	}
}

// The row of `tok`, read behind `pad` spaces, against the span lexer reading the same text: `get_number` bit for
// bit with its exactness (`scan.number_span`), `get_int` as `scan.decode_int` answers it. The span lexer is the
// reference the row's fast paths (the integer, the plain fraction, the folded exponent, the byte fold at the head
// of the source) must not differ from.
@(private = "file")
expect_row_reads_as_span :: proc(t: ^testing.T, tok: string, pad: int) -> bool {
	src := strings.concatenate({strings.repeat(" ", pad, context.temp_allocator), tok}, context.temp_allocator)
	doc, err := json.build(raw(src))
	if _, refused := err.?; refused {
		return true // a token the build refuses has no row to read
	}
	defer json.destroy(&doc)
	lo, hi := u64(doc.rows[0].lo), u64(doc.rows[0].hi)
	want := scan.number_span(doc.src, lo, hi)
	got, _ := json.get_number(&doc, json.ROOT)
	ok := got.exactness == want.exactness && transmute(u64)got.value == transmute(u64)want.value
	testing.expectf(t, ok, "%q behind %d: get_number %v, span %v", tok, pad, got, want)
	want_int, want_int_ok := scan.decode_int(doc.src, lo, hi)
	got_int, got_int_ok := json.get_int(&doc, json.ROOT)
	int_ok := got_int == want_int && got_int_ok == want_int_ok
	testing.expectf(t, int_ok, "%q behind %d: get_int %d %v, decode_int %d %v", tok, pad, got_int, got_int_ok, want_int, want_int_ok)
	return ok && int_ok
}

// Edge tokens of every arm a row's read takes: signed zeros, the digit counts around the word folds (8, 16, 19, 20),
// `i64` and `u64` limits, the Clinger window and its edges, subnormals, overflow and underflow, saturated exponents.
@(test)
test_a_number_row_reads_as_its_span_does :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	toks := []string{
		"0", "-0", "0.0", "-0.0", "0e0", "-0e-5", "0.000", "1", "-1", "9", "12", "-123", "1234567", "12345678", "123456789",
		"1234567890123456", "12345678901234567", "123456789012345678", "1234567890123456789", "-1234567890123456789",
		"9999999999999999999", "12345678901234567890", "-12345678901234567890", "9223372036854775807", "9223372036854775808",
		"-9223372036854775807", "-9223372036854775808", "-9223372036854775809", "18446744073709551615", "18446744073709551616",
		"9007199254740991", "9007199254740992", "9007199254740993", "9007199254740994", "-9007199254740993",
		"0.5", "-0.5", "0.1", "0.10", "1.5", "1.0", "-1.0", "10.0", "100.5", "0.001", "123.456", "-123.456",
		"0.12345678", "0.123456789", "0.123456789012345", "0.1234567890123456", "0.12345678901234567", "0.123456789012345678",
		"0.1234567890123456789", "0.12345678901234567890", "1.234567890123456789", "1.2345678901234567890", "-0.9999999999999999999",
		"9.99999999999999", "9.007199254740993", "9.123456789012345", "-9.999999999999999", "9007199254740993.0e-15",
		"123456789012345.6", "1234567890123456.7","9007199254740992.5", "9007199254740993.0", "4503599627370496.5",
		"1.7976931348623157", "0.30000000000000004", "0.6292258741982828", "0.061038061325733195", "5e-324", "0.000000000000000001",
		"1e0", "1e1", "1E1", "1e+1", "1e-1", "1e22", "1e23", "1e-22", "1e-23", "1.5e300", "-1.5e-300", "1e308", "1.7976931348623157e308",
		"1e309", "1e400", "-1e400", "1e-320", "4.9e-324", "2.4703282292062327e-324", "2.2250738585072014e-308", "2.2250738585072011e-308",
		"1e-400", "-1e-400", "0e999999999", "1e99999999999", "1e-99999999999", "12345678901234567e10", "1234567890123456789e-30",
		"9007199254740993e0", "9007199254740993e1", "5e-1", "125e-3", "1234.5678e-8", "1.5E+10", "-0.0E-0",
	}
	for tok in toks do for pad in 0 ..= 27 {
		if !expect_row_reads_as_span(t, tok, pad) {
			return
		}
	}
}

// Every split of up to 21 digits into an integer run and a fraction run, signed and not, with and without an
// exponent, at the offsets where the source head, a word boundary and the body fall on the run's end.
@(test)
test_every_digit_split_reads_as_its_span_does :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	digits := "918273645546372819012"
	for n in 1 ..= len(digits) {
		for int_n in 1 ..= n {
			for sign in ([]string{"", "-"}) {
				for exp in ([]string{"", "e5", "E-17", "e+300", "e-330", "e0"}) {
					tok := strings.concatenate({sign, digits[:int_n], "." if int_n < n else "", digits[int_n:n], exp}, context.temp_allocator)
					for pad in ([]int{0, 1, 5, 8, 17, 23, 24, 25}) {
						if !expect_row_reads_as_span(t, tok, pad) {
							return
						}
					}
				}
			}
		}
		free_all(context.temp_allocator)
	}
}

// Seeded random numbers: integers of every length, and decimals of random binary64 values, plain and in
// exponent notation (subnormals and the largest exponents included).
@(test)
test_random_numbers_read_as_their_span_does :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := u64(0xD1B54A32D192ED03)
	next := proc(state: ^u64) -> u64 {
		state^ += 0x9E3779B97F4A7C15
		z := state^
		z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
		z = (z ~ (z >> 27)) * 0x94D049BB133111EB
		return z ~ (z >> 31)
	}
	buf: [64]byte
	for i in 0 ..< 6000 {
		bits := next(&state)
		digits := int(bits % 20) + 1
		whole := next(&state)
		for _ in 0 ..< 19 - digits {
			whole /= 10
		}
		int_tok := strconv.write_uint(buf[:], whole, 10)
		neg := bits >> 8 & 1 == 1
		pad := int(bits >> 16 % 28)
		if !expect_row_reads_as_span(t, strings.concatenate({"-" if neg else "", int_tok}, context.temp_allocator), pad) {
			return
		}
		f := transmute(f64)next(&state)
		if f == f && f <= max(f64) && f >= -max(f64) {
			for fmt_ in ([]byte{'e', 'g'}) {
				text := strings.trim_prefix(strconv.write_float(buf[:], f, fmt_, -1, 64), "+")
				if !expect_row_reads_as_span(t, strings.clone(text, context.temp_allocator), pad) {
					return
				}
			}
		}
		// Random digits split at a random point, with a short exponent or none.
		n := int(next(&state) % 19) + 1
		int_n := int(next(&state) % u64(n)) + 1
		text: [dynamic]byte
		text.allocator = context.temp_allocator
		for k in 0 ..< n {
			if k == int_n {
				append(&text, '.')
			}
			d := byte(next(&state) % 10) + '0'
			if k == 0 && int_n > 1 && d == '0' {
				d = '9'
			}
			append(&text, d)
		}
		exps := [?]string{"", "", "e1", "e-7", "E+22", "e-23", "e300", "e-325"}
		append(&text, exps[next(&state) % len(exps)])
		if !expect_row_reads_as_span(t, string(text[:]), pad) {
			return
		}
		// A unit-interval decimal, as a JSON producer prints a `random()`.
		unit := f64(next(&state) >> 11) / f64(u64(1) << 53)
		if !expect_row_reads_as_span(t, strings.clone(strconv.write_float(buf[:], unit, 'f', -1, 64), context.temp_allocator), pad) {
			return
		}
		if i % 256 == 0 {
			free_all(context.temp_allocator)
		}
	}
}

// A digit count past the node row's saturation (254) and past the default cap builds and reads as a
// number when the caller raised `max_scalar_digits`.
@(test)
test_a_300_digit_token_reads_under_a_raised_cap :: proc(t: ^testing.T) {
	limits := json.Limits{max_scalar_digits = 1000}
	tok := strings.repeat("7", 300, context.temp_allocator)
	for src in ([]string{tok, strings.concatenate({tok, ".25e-4"}, context.temp_allocator)}) {
		doc, err := json.build(raw(src), {limits = limits})
		_, has_err := err.?
		if !testing.expectf(t, !has_err, "a 300-digit token under max_scalar_digits=1000 must build, got %v", err) {
			continue
		}
		defer json.destroy(&doc)
		want, _ := strconv.parse_f64(src)
		got, _ := json.get_number(&doc, json.ROOT)
		testing.expect_value(t, got, json.Number{want, .Inexact})
	}
}

// `get_int` answers an integer form whose value fits `i64` (`-0` as 0), and nothing else. `get_float` answers
// any number with a binary64 value.
@(test)
test_integer_and_float_readers :: proc(t: ^testing.T) {
	cases := []struct {
		tok:      string,
		int_ok:   bool,
		i:        i64,
		float_ok: bool,
		f:        f64,
	}{
		{"0", true, 0, true, 0},
		{"42", true, 42, true, 42},
		{"-7", true, -7, true, -7},
		// An integer has no negative zero: `-0` is 0, as `unmarshal` reads it into any integer.
		{"-0", true, 0, true, -0.0},
		{"9223372036854775807", true, max(i64), true, 9223372036854775807},
		{"9223372036854775808", false, 0, true, 9223372036854775808},
		{"18446744073709551615", false, 0, true, 18446744073709551615},
		{"18446744073709551616", false, 0, true, 18446744073709551616},
		{"-9223372036854775808", true, min(i64), true, -9223372036854775808},
		{"2.5", false, 0, true, 2.5},
		{"1e2", false, 0, true, 100},
		{"1e400", false, 0, false, 0},
		{"-1e400", false, 0, false, 0},
	}
	for c in cases {
		doc := build_ok(t, c.tok)
		defer json.destroy(&doc)
		i, i_ok := json.get_int(&doc, json.ROOT)
		testing.expectf(t, i_ok == c.int_ok && i == c.i, "%s: get_int %d %v", c.tok, i, i_ok)
		f, f_ok := json.get_float(&doc, json.ROOT)
		testing.expectf(t, f_ok == c.float_ok && f == c.f, "%s: get_float %v %v", c.tok, f, f_ok)
	}
	// None of them reads another kind.
	doc := build_ok(t, `"1"`)
	defer json.destroy(&doc)
	_, i_ok := json.get_int(&doc, json.ROOT)
	_, f_ok := json.get_float(&doc, json.ROOT)
	testing.expect(t, !i_ok && !f_ok, "a string is not a number")
}

// `get_float` of a number's shortest decimal is the same binary64, over seeded random bit patterns (subnormals and
// the largest exponents included), and at the digit cap: 256 digits read, 257 refused.
@(test)
test_get_float_round_trips_shortest_decimals :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := u64(0x9E3779B97F4A7C15)
	buf: [64]byte
	for i in 0 ..< 4000 {
		// splitmix64
		state += 0x9E3779B97F4A7C15
		z := state
		z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
		z = (z ~ (z >> 27)) * 0x94D049BB133111EB
		z ~= z >> 31
		f := transmute(f64)z
		if f != f || f > max(f64) || f < -max(f64) {
			continue
		}
		text := strings.trim_prefix(strconv.write_float(buf[:], f, 'e', -1, 64), "+")
		doc := build_ok(t, text)
		got, ok := json.get_float(&doc, json.ROOT)
		testing.expectf(t, ok && transmute(u64)got == z, "%s: bits %x, want %x", text, transmute(u64)got, z)
		json.destroy(&doc)
		if i % 256 == 0 {
			free_all(context.temp_allocator)
		}
	}

	digits_256 := strings.concatenate({"1", strings.repeat("0", 255, context.temp_allocator)}, context.temp_allocator)
	doc := build_ok(t, digits_256)
	got, ok := json.get_float(&doc, json.ROOT)
	json.destroy(&doc)
	testing.expectf(t, ok && got == 1e255, "256 digits: %v %v", got, ok)
	_, err := json.build(raw(strings.concatenate({digits_256, "0"}, context.temp_allocator)))
	e, refused := err.?
	testing.expectf(t, refused && e.kind == .Limit_Digits, "257 digits: %v", e)
}

// A digit run ends at the first non-digit byte of its eight-byte load, one just past '9' (`:` .. `?`) or
// with the high bit set included: the build refuses where `validate` does, and a run that ends at a
// separator reads as its digits.
@(test)
test_a_digit_run_ends_at_its_first_non_digit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	run := "98765432109876543210"
	for n in 1 ..= len(run) {
		digits := run[:n]
		for stop in ([]byte{':', ';', '<', '=', '>', '?', '/', 'A', 0x80, 0xB9, 0xFF}) {
			src := strings.concatenate({"[", digits, string([]byte{stop}), "99999999]"}, context.temp_allocator)
			_, err := json.build(raw(src))
			got, refused := err.?
			want, _ := json.validate(raw(src)).?
			testing.expectf(t, refused && got == want && got.offset == u64(1 + n), "%q: build %v, validate %v", src, got, want)
		}
		doc := build_ok(t, strings.concatenate({"[", digits, ",", digits, "]"}, context.temp_allocator))
		v, ok := json.get_float(&doc, json.child(&doc, json.ROOT, 1))
		json.destroy(&doc)
		want, _ := strconv.parse_f64(digits)
		testing.expectf(t, ok && transmute(u64)v == transmute(u64)want, "%s: %v, want %v", digits, v, want)
	}
}
