package jq

import "core:math"
import "stury:lib/query"

// The math builtins of one, two and three numbers, over doubles, but rounding, which keeps an exact integer.
@(private)
v_math :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (query.Value, query.Status) {
	ins := [3]query.Value{x, {}, {}}
	n := 1
	if len(args) > 0 {
		n = len(args)
		copy(ins[:], args)
	}
	for v in ins[:n] {
		if query.type_of(v) != .Number {
			return query.NULL, raise_typed(m, v, " number required")
		}
	}
	if ins[0].kind == .Int || ins[0].kind == .Big {
		switch b.name {
		case "floor", "ceil", "round", "trunc", "rint", "nearbyint", "fabs":
			if b.name == "fabs" && query.compare_numbers(ins[0], query.int_value(0)) < 0 {
				return query.num_neg(m.h, ins[0])
			}
			return query.retain(ins[0]), .Ok
		}
	}
	a := query.as_f64(ins[0])
	c := query.as_f64(ins[1]) if n > 1 else 0
	d := query.as_f64(ins[2]) if n > 2 else 0
	r: f64
	switch b.name {
	case "floor": r = math.floor(a)
	case "ceil": r = math.ceil(a)
	case "round": r = math.round(a)
	case "trunc": r = math.trunc(a)
	case "rint", "nearbyint": r = round_even(a)
	case "fabs": r = abs(a)
	case "sqrt": r = math.sqrt(a)
	case "cbrt": r = math.cbrt(a)
	case "exp": r = math.exp(a)
	case "exp2": r = query.math_exp2(a)
	case "exp10": r = math.pow(10, a)
	case "expm1": r = query.math_expm1(a)
	case "log": r = math.ln(a)
	case "log2": r = math.log2(a)
	case "log10": r = math.log10(a)
	case "log1p": r = math.log1p(a)
	case "logb": r = math.logb(a)
	case "gamma", "lgamma": r, _ = math.lgamma(a)
	case "tgamma": r = math.gamma(a)
	case "sin": r = math.sin(a)
	case "cos": r = math.cos(a)
	case "tan": r = math.tan(a)
	case "asin": r = math.asin(a)
	case "acos": r = math.acos(a)
	case "atan": r = math.atan(a)
	case "sinh": r = math.sinh(a)
	case "cosh": r = math.cosh(a)
	case "tanh": r = math.tanh(a)
	case "asinh": r = math.asinh(a)
	case "acosh": r = math.acosh(a)
	case "atanh": r = math.atanh(a)
	case "erf": r = math.erf(a)
	case "erfc": r = math.erfc(a)
	case "j0": r = query.bessel_j0(a)
	case "j1": r = query.bessel_j1(a)
	case "y0": r = query.bessel_y0(a)
	case "y1": r = query.bessel_y1(a)
	case "significand":
		if a == 0 || math.is_inf(a) || math.is_nan(a) {
			r = a
		} else {
			fr, _ := math.frexp(a)
			r = fr * 2
		}
	case "pow": r = math.pow(a, c)
	case "atan2": r = math.atan2(a, c)
	case "fmod": r = math.mod(a, c)
	case "fmin": r = c if math.is_nan(a) else (a if math.is_nan(c) else min(a, c))
	case "fmax": r = c if math.is_nan(a) else (a if math.is_nan(c) else max(a, c))
	case "fdim": r = a + c if math.is_nan(a) || math.is_nan(c) else (a - c if a > c else 0)
	case "hypot": r = math.hypot(a, c)
	case "copysign": r = math.copy_sign(a, c)
	case "nextafter", "nexttoward": r = math.nextafter(a, c)
	case "remainder", "drem": r = math.remainder(a, c)
	case "ldexp", "scalbln": r = math.ldexp(a, int_of(c))
	case "scalb": r = query.math_scalb(a, c)
	case "jn": r = query.bessel_jn(int_of(a), c)
	case "yn": r = query.bessel_yn(int_of(a), c)
	case "fma": r = query.math_fma(a, c, d)
	case:
		return query.NULL, raise_text(m, "math function not available")
	}
	return query.double_value(r), .Ok
}

@(private)
int_of :: proc(f: f64) -> int {
	return 0 if math.is_nan(f) else int(clamp(f, f64(min(i32)), f64(max(i32))))
}
