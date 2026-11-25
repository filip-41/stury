package query

import "core:math"

// `sin`, `cos`, `exp` and `pow` of C's libm. `core:math` reaches them through LLVM's intrinsics, which a WebAssembly
// target with no C library leaves undefined, so its object would import them. The procedures are plain so a host
// can compare them with its own libm, and only a wasm target without a JavaScript host exports them under libm's
// names, which keeps the freestanding and WASI objects free of those imports.

libm_sin :: proc "contextless" (x: f64) -> f64 {
	s, _ := math.sincos_f64(x)
	return s
}

libm_cos :: proc "contextless" (x: f64) -> f64 {
	_, c := math.sincos_f64(x)
	return c
}

// After FreeBSD's e_exp.c: `x` is reduced by a multiple of ln 2 held in two parts, and a rational form of the
// remainder is scaled back.
libm_exp :: proc "contextless" (x: f64) -> f64 {
	LN2_HI :: 6.93147180369123816490e-01
	LN2_LO :: 1.90821492927058770002e-10
	INVLN2 :: 1.44269504088896338700e+00
	P1 :: 1.66666666666666019037e-01
	P2 :: -2.77777777770155933842e-03
	P3 :: 6.61375632143793436117e-05
	P4 :: -1.65339022054652515390e-06
	P5 :: 4.13813679705723846039e-08
	switch {
	case math.is_nan(x):
		return x
	case x > 709.782712893383973096:
		return math.inf_f64(1)
	case x < -745.13321910194110842:
		return 0
	case abs(x) < 0h3e30000000000000: // 2^-28
		return 1 + x
	}
	hi, lo: f64
	k: int
	if abs(x) > 0.5 * math.LN2 {
		if abs(x) < 1.5 * math.LN2 {
			k = 1 if x > 0 else -1
		} else {
			k = int(INVLN2 * x + (0.5 if x > 0 else -0.5))
		}
		hi = x - f64(k) * LN2_HI
		lo = f64(k) * LN2_LO
	} else {
		hi = x
	}
	r := hi - lo
	rr := r * r
	c := r - rr * (P1 + rr * (P2 + rr * (P3 + rr * (P4 + rr * P5))))
	y := 1 - ((lo - (r * c) / (2 - c)) - hi)
	return math.ldexp(y, k)
}

// `a * b` as a sum of two doubles, exact when neither the product's high nor its low part leaves the range of a
// double. The operands are cut into halves of 26 bits, which Veltkamp's split makes exact.
@(private = "file")
two_product :: proc "contextless" (a, b: f64) -> (hi, lo: f64) {
	SPLIT :: 134217729.0 // 2^27 + 1
	ca := SPLIT * a
	a_hi := ca - (ca - a)
	a_lo := a - a_hi
	cb := SPLIT * b
	b_hi := cb - (cb - b)
	b_lo := b - b_hi
	hi = a * b
	lo = ((a_hi * b_hi - hi) + a_hi * b_lo + a_lo * b_hi) + a_lo * b_lo
	return
}

// The product of two sums of two doubles, as a sum of two doubles accurate to about 2^-104.
@(private = "file")
dd_mul :: proc "contextless" (ah, al, bh, bl: f64) -> (hi, lo: f64) {
	p, e := two_product(ah, bh)
	e += ah * bl + al * bh
	hi = p + e
	lo = e - (hi - p)
	return
}

// `x` to the power `y` with C99's special cases. A negative `x` takes an integral `y` only. `x` is a mantissa and
// an exponent: the integral part of `y` raises the mantissa by repeated squaring in doubles of two parts, and
// the exponent's share of the fractional part is split off exactly, so what `exp` is given stays below 0.6.
// Past 2^50 the squaring's error is no longer below an ulp, and `exp` of the product takes over.
libm_pow :: proc "contextless" (x, y: f64) -> f64 {
	TWO_53 :: 9007199254740992.0
	SQUARED_MAX :: 0h4310000000000000 // 2^50
	switch {
	case y == 0 || x == 1:
		return 1
	case math.is_nan(x) || math.is_nan(y):
		return math.nan_f64()
	}
	integral := y == math.trunc(y)
	odd := integral && abs(y) < TWO_53 && math.trunc(y * 0.5) * 2 != y
	switch {
	case x == 0:
		zero := math.copy_sign(0.0, x) if odd else 0.0
		return zero if y > 0 else 1 / zero
	case math.is_inf(x):
		r := math.inf_f64(1) if y > 0 else 0.0
		return -r if x < 0 && odd else r
	case x < 0 && !integral:
		return math.nan_f64()
	case abs(x) == 1:
		return -1 if x < 0 && odd else 1
	case math.is_inf(y):
		return 0 if (abs(x) < 1) == (y > 0) else math.inf_f64(1)
	}
	negative := x < 0 && odd
	m, e := math.frexp(abs(x))
	yi, yf := math.modf(abs(y))
	if yi >= SQUARED_MAX {
		r := libm_exp(y * math.ln(abs(x)))
		return -r if negative else r
	}
	if yf > 0.5 {
		yf -= 1
		yi += 1
	}
	// The mantissa in [1/sqrt 2, sqrt 2) and the exponent that goes with it.
	mantissa, shift := m * 2, e - 1
	if mantissa > math.SQRT_TWO {
		mantissa *= 0.5
		shift += 1
	}
	// shift * yf is split into an integer and a part of at most a half, with the product's rounding error kept.
	prod, prod_err := two_product(f64(shift), yf)
	whole := math.round(prod)
	rest := (prod - whole) + prod_err
	a_hi := libm_exp(rest * math.LN2 + yf * math.ln(mantissa))
	a_lo := 0.0
	ae := int(whole)
	x_hi, x_lo, xe := m, 0.0, e
	for i := u64(yi); i != 0; i >>= 1 {
		if xe < -(1 << 12) || 1 << 12 < xe {
			// The product already lies outside the range of a double.
			ae += xe
			break
		}
		if i & 1 == 1 {
			a_hi, a_lo = dd_mul(a_hi, a_lo, x_hi, x_lo)
			ae += xe
		}
		x_hi, x_lo = dd_mul(x_hi, x_lo, x_hi, x_lo)
		xe <<= 1
		if x_hi < 0.5 {
			x_hi, x_lo = x_hi + x_hi, x_lo + x_lo
			xe -= 1
		}
	}
	a := a_hi + a_lo
	if y < 0 {
		a = 1 / a
		ae = -ae
	}
	r := math.ldexp(a, ae)
	return -r if negative else r
}

when ODIN_ARCH == .wasm32 && ODIN_OS == .Freestanding {
	@(export, link_name = "sin")
	c_sin :: proc "c" (x: f64) -> f64 {
		return libm_sin(x)
	}

	@(export, link_name = "cos")
	c_cos :: proc "c" (x: f64) -> f64 {
		return libm_cos(x)
	}

	@(export, link_name = "exp")
	c_exp :: proc "c" (x: f64) -> f64 {
		return libm_exp(x)
	}

	@(export, link_name = "pow")
	c_pow :: proc "c" (x, y: f64) -> f64 {
		return libm_pow(x, y)
	}
}
