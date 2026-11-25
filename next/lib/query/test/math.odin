package query_test

import "core:math"
import "core:testing"
import "stury:lib/query"
import "stury:testkit"

// The libm functions the engine computes itself and the `core:math` ones it relies on: exact where the operation is,
// within a few ulps against known values where it is an approximation.

@(private = "file")
near :: proc(t: ^testing.T, got, want: f64, ulps := 4.0, loc := #caller_location) {
	if math.is_nan(want) {
		testing.expectf(t, math.is_nan(got), "got %v, want NaN", got, loc = loc)
		return
	}
	tolerance := ulps * abs(want) * 2.220446049250313e-16
	testing.expectf(t, abs(got - want) <= tolerance, "got %v, want %v", got, want, loc = loc)
}

@(test)
fma_rounds_once :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, query.math_fma(2, 3, 4), 10)
	testing.expect_value(t, query.math_fma(0.1, 10, -1), 5.551115123125783e-17)
	testing.expect_value(t, query.math_fma(0.1, 0.1, -0.01), 9.020562075079397e-19)
	testing.expect_value(t, query.math_fma(1e154, 1e154, -1e308), 6.2916027746676e+291)
	testing.expect_value(t, query.math_fma(1e-320, 1e-320, 1e-320), 1e-320)
	testing.expect_value(t, query.math_fma(3, 5, -15), 0)
	testing.expect(t, math.is_nan(query.math_fma(math.inf_f64(1), 0, 1)))
	testing.expect(t, math.is_nan(query.math_fma(1, 1, math.nan_f64())))
	testing.expect_value(t, query.math_fma(1e308, 10, -1e308), math.inf_f64(1))
}

@(test)
fmod_is_exact :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, math.mod_f64(5, 3), 2)
	testing.expect_value(t, math.mod_f64(-5, 3), -2)
	testing.expect_value(t, math.mod_f64(5.5, 2), 1.5)
	testing.expect_value(t, math.mod_f64(1e300, 3), 0)
	testing.expect_value(t, math.mod_f64(1e22, 0.7), 0.15692866092049007)
	testing.expect_value(t, math.mod_f64(-6.999999999999999, 2.1), -0.6999999999999988)
	testing.expect_value(t, math.mod_f64(5, math.inf_f64(1)), 5)
	testing.expect(t, math.is_nan(math.mod_f64(5, 0)))
	testing.expect(t, math.is_nan(math.mod_f64(math.inf_f64(1), 3)))
	testing.expect(t, math.is_nan(math.mod_f64(math.nan_f64(), 3)))
}

@(test)
exponentials_follow_the_reference_algorithms :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, query.math_exp2(10), 1024)
	testing.expect_value(t, query.math_exp2(-1), 0.5)
	testing.expect_value(t, query.math_exp2(1023), 8.98846567431158e+307)
	testing.expect_value(t, query.math_exp2(0.5), 1.4142135623730951)
	testing.expect_value(t, query.math_exp2(-1074), 5e-324)
	testing.expect_value(t, query.math_exp2(-1075), 0)
	testing.expect_value(t, query.math_exp2(1024), math.inf_f64(1))
	testing.expect_value(t, query.math_exp2(math.inf_f64(-1)), 0)
	testing.expect_value(t, query.math_expm1(0), 0)
	testing.expect_value(t, query.math_expm1(1e-10), 1.00000000005e-10)
	testing.expect_value(t, query.math_expm1(-1e-300), -1e-300)
	testing.expect_value(t, query.math_expm1(-50), -1)
	testing.expect_value(t, query.math_expm1(710), math.inf_f64(1))
	near(t, query.math_expm1(1), 1.718281828459045, 2)
	near(t, query.math_expm1(0.5), 0.6487212707001282, 2)
	near(t, query.math_expm1(-0.5), -0.3934693402873666, 2)
	near(t, query.math_expm1(709), 8.218407461554972e+307, 2)
}

@(test)
scalb_takes_an_integral_exponent :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, query.math_scalb(1, 3), 8)
	testing.expect_value(t, query.math_scalb(1, -2), 0.25)
	testing.expect_value(t, query.math_scalb(1, 70000), math.inf_f64(1))
	testing.expect_value(t, query.math_scalb(1, math.inf_f64(1)), math.inf_f64(1))
	testing.expect(t, math.is_nan(query.math_scalb(1, 1.5)))
	testing.expect(t, math.is_nan(query.math_scalb(0, math.inf_f64(1))))
}

@(test)
gamma_is_exact_at_the_integers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, math.gamma_f64(1), 1)
	testing.expect_value(t, math.gamma_f64(5), 24)
	testing.expect_value(t, math.gamma_f64(23), 1124000727777607680000.0)
	testing.expect_value(t, math.gamma_f64(math.inf_f64(1)), math.inf_f64(1))
	testing.expect_value(t, math.gamma_f64(172), math.inf_f64(1))
	testing.expect_value(t, math.gamma_f64(0), math.inf_f64(1))
	testing.expect_value(t, math.gamma_f64(-0.0), math.inf_f64(-1))
	testing.expect(t, math.is_nan(math.gamma_f64(-1)))
	testing.expect(t, math.is_nan(math.gamma_f64(math.inf_f64(-1))))
	near(t, math.gamma_f64(0.5), 1.772453850905516, 8)
	near(t, math.gamma_f64(-0.5), -3.544907701811032, 8)
	near(t, math.gamma_f64(10.5), 1133278.3889487856, 8)
	near(t, math.gamma_f64(171), 7.257415615307999e+306, 8)
}

@(test)
bessel_functions_match_their_known_values :: proc(t: ^testing.T) {
	testkit.deadline(t)
	near(t, query.bessel_j0(1), 0.7651976865579666)
	near(t, query.bessel_j0(10), -0.2459357644513483)
	testing.expect(t, abs(query.bessel_j0(2.4048255576957727)) < 1e-15)
	near(t, query.bessel_j1(1), 0.4400505857449335)
	near(t, query.bessel_j1(-10), -0.043472746168861445)
	near(t, query.bessel_y0(1), 0.08825696421567697)
	near(t, query.bessel_y0(10), 0.055671167283599395)
	near(t, query.bessel_y1(1), -0.7812128213002887)
	near(t, query.bessel_y1(10), 0.2490154242069538)
	near(t, query.bessel_jn(2, 1.5), 0.23208767214421472)
	near(t, query.bessel_jn(-3, 4), -query.bessel_jn(3, 4))
	near(t, query.bessel_jn(3, -4), -query.bessel_jn(3, 4))
	near(t, query.bessel_jn(10, 5), 0.0014678026473104741, 8)
	near(t, query.bessel_yn(2, 1.5), -0.9321937597629739, 8)
	near(t, query.bessel_yn(5, 0.5), -7946.301478807475, 8)
	testing.expect_value(t, query.bessel_j0(0), 1)
	testing.expect_value(t, query.bessel_j0(math.inf_f64(1)), 0)
	testing.expect_value(t, query.bessel_j1(0), 0)
	testing.expect_value(t, query.bessel_y0(0), math.inf_f64(-1))
	testing.expect_value(t, query.bessel_y1(0), math.inf_f64(-1))
	testing.expect_value(t, query.bessel_yn(3, 0), math.inf_f64(-1))
	testing.expect_value(t, query.bessel_jn(3, 0), 0)
	testing.expect_value(t, query.bessel_y0(math.inf_f64(1)), 0)
	testing.expect(t, math.is_nan(query.bessel_y0(-1)))
	testing.expect(t, math.is_nan(query.bessel_yn(2, -1)))
	testing.expect(t, math.is_nan(query.bessel_jn(2, math.nan_f64())))
}

// The spacing of doubles at `want`, the smallest subnormal below the smallest normal.
@(private = "file")
ulp_of :: proc(want: f64) -> f64 {
	_, e := math.frexp(want)
	return math.ldexp(f64(1), max(e - 53, -1074))
}

// `got` within `ulps` of the host's `want`: the same NaN-ness, the same infinities and the same sign of zero.
@(private = "file")
within_ulps :: proc(t: ^testing.T, got, want: f64, ulps: f64, what: string, args: [2]f64, loc := #caller_location) {
	if math.is_nan(want) || math.is_inf(want) || want == 0 {
		same := transmute(u64)got == transmute(u64)want || math.is_nan(got) && math.is_nan(want)
		testing.expectf(t, same, "%s%v: got %v, want %v", what, args, got, want, loc = loc)
		return
	}
	testing.expectf(t, abs(got - want) <= ulps * ulp_of(want), "%s%v: got %v, want %v", what, args, got, want, loc = loc)
}

@(private = "file", rodata)
LIBM_EDGES := [?]f64 {
	0, 0h8000000000000000, 1, -1, 0.5, -0.5, 2, -2, 3, -3, 1e-300, 5e-324, -5e-324, 2.2250738585072014e-308, 1e300,
	-1e300, 1.7976931348623157e+308, 709.78, 709.79, -745.13, -745.14, 1e15, 9007199254740993, math.PI, -math.PI,
	math.PI / 2, 4611686018427387904, 9223372036854775808, 0h7ff0000000000000, 0hfff0000000000000, 0h7ff8000000000000,
}

// The shims that stand in for libm's `sin`, `cos`, `exp` and `pow` on a WebAssembly target with no C library, against
// the host's libm. `sin` and `cos` hold the 1.5 ulp of `math.sincos_f64` and a half more for the host, `exp` the one
// ulp of FreeBSD's algorithm, `pow` two: its integral part is squared in doubles of two parts, so only the
// exponential of the fractional part and the last rounding err.
@(test)
libm_shims_follow_the_host_libm :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for x in LIBM_EDGES {
		within_ulps(t, query.libm_sin(x), math.sin(x), 2, "sin", {x, 0})
		within_ulps(t, query.libm_cos(x), math.cos(x), 2, "cos", {x, 0})
		within_ulps(t, query.libm_exp(x), math.exp(x), 1, "exp", {x, 0})
		for y in LIBM_EDGES {
			within_ulps(t, query.libm_pow(x, y), math.pow(x, y), 2, "pow", {x, y})
		}
	}
	for k in 1 ..= 2000 {
		x := f64(k) * math.PI
		within_ulps(t, query.libm_sin(x), math.sin(x), 2, "sin", {x, 0})
		within_ulps(t, query.libm_cos(-x), math.cos(-x), 2, "cos", {-x, 0})
		within_ulps(t, query.libm_sin(-x / 2), math.sin(-x / 2), 2, "sin", {-x / 2, 0})
	}
	// A fixed pseudo-random walk over the ranges of an argument, so a failure repeats.
	state := u64(0x9e3779b97f4a7c15)
	next :: proc(state: ^u64) -> f64 {
		state^ = state^ * 6364136223846793005 + 1442695040888963407
		return f64(state^ >> 11) / f64(1 << 53)
	}
	for i in 0 ..< 20000 {
		s := next(&state) * 2000 - 1000
		within_ulps(t, query.libm_sin(s), math.sin(s), 2, "sin", {s, 0})
		c := next(&state) * 1e6
		within_ulps(t, query.libm_cos(c), math.cos(c), 2, "cos", {c, 0})
		e := next(&state) * 1500 - 750
		within_ulps(t, query.libm_exp(e), math.exp(e), 1, "exp", {e, 0})
		x := math.exp((next(&state) - 0.5) * 100)
		y := (next(&state) - 0.5) * (200 if i % 2 == 0 else 2e6)
		if i % 5 == 0 {
			y = math.trunc(y / 1e4)
			x = -x
		}
		within_ulps(t, query.libm_pow(x, y), math.pow(x, y), 2, "pow", {x, y})
	}
}

@(test)
libm_pow_is_exact_where_the_result_is :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, query.libm_pow(2, 10), 1024)
	testing.expect_value(t, query.libm_pow(2, -3), 0.125)
	testing.expect_value(t, query.libm_pow(2, 100), 1.2676506002282294e30)
	testing.expect_value(t, query.libm_pow(10, 22), 1e22)
	testing.expect_value(t, query.libm_pow(10, -2), 0.01)
	testing.expect_value(t, query.libm_pow(3, 33), 5559060566555523)
	testing.expect_value(t, query.libm_pow(-3, 3), -27)
	testing.expect_value(t, query.libm_pow(-2, 1023), -8.98846567431158e+307)
	testing.expect_value(t, query.libm_pow(0.5, 1074), 5e-324)
	testing.expect_value(t, query.libm_pow(4, 0.5), 2)
	testing.expect_value(t, query.libm_pow(2, 1024), math.inf_f64(1))
	testing.expect_value(t, query.libm_pow(2, -1075), 0)
	testing.expect(t, math.is_nan(query.libm_pow(-8, 1.0 / 3)))
}
