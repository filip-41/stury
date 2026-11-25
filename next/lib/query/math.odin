package query

import "base:intrinsics"
import "core:math"

// The floating-point functions of C's libm that `core:math` lacks, in the algorithms of musl (FreeBSD's expm1,
// ARM's exp2, musl's fma), so that the same arguments give the same bits on every OS.

// `x * y + z` rounded once, exactly.
math_fma :: proc(x, y, z: f64) -> f64 {
	Num :: struct {
		m:    u64,
		e:    int,
		sign: bool,
	}
	normalize :: proc(x: f64) -> Num {
		bits := transmute(u64)x
		e := int(bits >> 52)
		sign := e & 0x800 != 0
		e &= 0x7ff
		if e == 0 {
			bits = transmute(u64)(x * 0h43E0000000000000)
			e = int(bits >> 52) & 0x7ff
			e = e - 63 if e != 0 else 0x800
		}
		bits &= 1 << 52 - 1
		bits |= 1 << 52
		bits <<= 1
		return {bits, e - (0x3ff + 52 + 1), sign}
	}
	// A product of two 64-bit numbers as a 128-bit one.
	mul :: proc(x, y: u64) -> (hi, lo: u64) {
		xlo, xhi := x & 0xffffffff, x >> 32
		ylo, yhi := y & 0xffffffff, y >> 32
		t1 := xlo * ylo
		t2 := xlo * yhi + xhi * ylo
		t3 := xhi * yhi
		lo = t1 + t2 << 32
		hi = t3 + t2 >> 32 + u64(t1 > lo)
		return
	}
	ZEROINFNAN :: 0x7ff - 0x3ff - 52 - 1
	nx, ny, nz := normalize(x), normalize(y), normalize(z)
	if nx.e >= ZEROINFNAN || ny.e >= ZEROINFNAN {
		return x * y + z
	}
	if nz.e >= ZEROINFNAN {
		if nz.e > ZEROINFNAN {
			return x * y + z
		}
		return z
	}
	rhi, rlo := mul(nx.m, ny.m)
	zhi, zlo: u64
	e := nx.e + ny.e
	d := nz.e - e
	// Shift z left and r right by d between them, e following r.
	if d > 0 {
		if d < 64 {
			zlo = nz.m << uint(d)
			zhi = nz.m >> uint(64 - d)
		} else {
			zlo = 0
			zhi = nz.m
			e = nz.e - 64
			d -= 64
			if d == 0 {
			} else if d < 64 {
				rlo = rhi << uint(64 - d) | rlo >> uint(d) | u64(rlo << uint(64 - d) != 0)
				rhi = rhi >> uint(d)
			} else {
				rlo = 1
				rhi = 0
			}
		}
	} else {
		zhi = 0
		d = -d
		if d == 0 {
			zlo = nz.m
		} else if d < 64 {
			zlo = nz.m >> uint(d) | u64(nz.m << uint(64 - d) != 0)
		} else {
			zlo = 1
		}
	}
	sign := nx.sign != ny.sign
	nonzero := true
	if sign == nz.sign {
		rlo += zlo
		rhi += zhi + u64(rlo < zlo)
	} else {
		t := rlo
		rlo -= zlo
		rhi = rhi - zhi - u64(t < rlo)
		if rhi >> 63 != 0 {
			rlo = -rlo
			rhi = -rhi - u64(rlo != 0)
			sign = !sign
		}
		nonzero = rhi != 0
	}
	// rhi becomes the top 63 bits of the result, the last one sticky.
	switch {
	case nonzero:
		e += 64
		d = int(intrinsics.count_leading_zeros(rhi)) - 1
		rhi = rhi << uint(d) | rlo >> uint(64 - d) | u64(rlo << uint(d) != 0)
	case rlo != 0:
		d = int(intrinsics.count_leading_zeros(rlo)) - 1
		if d < 0 {
			rhi = rlo >> 1 | rlo & 1
		} else {
			rhi = rlo << uint(d)
		}
	case:
		return x * y + z
	}
	e -= d
	i := i64(rhi)
	if sign {
		i = -i
	}
	r := f64(i)
	if e < -1022 - 62 {
		// The result is subnormal before rounding.
		if e == -1022 - 63 {
			c := 0h43E0000000000000
			if sign {
				c = -c
			}
			if r == c {
				return math.ldexp(r, e)
			}
			// One bit is lost when scaled: add another top bit to round once.
			if rhi << 53 != 0 {
				i = i64(rhi >> 1 | rhi & 1 | 1 << 62)
				if sign {
					i = -i
				}
				r = f64(i)
				r = 2 * r - c
			}
		} else {
			// Only round once when scaled.
			i = i64((rhi >> 10 | u64(rhi << 54 != 0)) << 10)
			if sign {
				i = -i
			}
			r = f64(i)
		}
	}
	return math.ldexp(r, e)
}

// `exp(x) - 1`, accurate for small `x`, after FreeBSD's s_expm1.c.
math_expm1 :: proc(x: f64) -> f64 {
	O_THRESHOLD :: 7.09782712893383973096e+02
	LN2_HI :: 6.93147180369123816490e-01
	LN2_LO :: 1.90821492927058770002e-10
	INVLN2 :: 1.44269504088896338700e+00
	Q1 :: -3.33333333333331316428e-02
	Q2 :: 1.58730158725481460165e-03
	Q3 :: -7.93650757867487942473e-05
	Q4 :: 4.00821782732936239552e-06
	Q5 :: -2.01099218183624371326e-07
	bits := transmute(u64)x
	hx := u32(bits >> 32) & 0x7fffffff
	negative := bits >> 63 != 0
	x := x
	if hx >= 0x4043687A {
		if math.is_nan(x) {
			return x
		}
		if negative {
			return -1
		}
		if x > O_THRESHOLD {
			return math.inf_f64(1)
		}
	}
	k: int
	c: f64
	switch {
	case hx > 0x3fd62e42:
		hi, lo: f64
		if hx < 0x3FF0A2B2 {
			if !negative {
				hi, lo, k = x - LN2_HI, LN2_LO, 1
			} else {
				hi, lo, k = x + LN2_HI, -LN2_LO, -1
			}
		} else {
			k = int(INVLN2 * x + (-0.5 if negative else 0.5))
			t := f64(k)
			hi = x - t * LN2_HI
			lo = t * LN2_LO
		}
		x = hi - lo
		c = (hi - x) - lo
	case hx < 0x3c900000:
		return x
	}
	hfx := 0.5 * x
	hxs := x * hfx
	r1 := 1.0 + hxs * (Q1 + hxs * (Q2 + hxs * (Q3 + hxs * (Q4 + hxs * Q5))))
	t := 3.0 - r1 * hfx
	e := hxs * ((r1 - t) / (6.0 - x * t))
	if k == 0 {
		return x - (x * e - hxs)
	}
	e = x * (e - c) - c
	e -= hxs
	if k == -1 {
		return 0.5 * (x - e) - 0.5
	}
	if k == 1 {
		if x < -0.25 {
			return -2.0 * (e - (x + 0.5))
		}
		return 1.0 + 2.0 * (x - e)
	}
	twopk := transmute(f64)(u64(0x3ff + k) << 52)
	if k < 0 || k > 56 {
		y := x - e + 1.0
		if k == 1024 {
			y = y * 2.0 * 0h7FE0000000000000
		} else {
			y = y * twopk
		}
		return y - 1.0
	}
	two_neg_k := transmute(f64)(u64(0x3ff - k) << 52)
	if k < 20 {
		return (x - e + (1 - two_neg_k)) * twopk
	}
	return (x - (e + two_neg_k) + 1) * twopk
}

// `2` to the power `x`, after ARM's optimized routines as musl carries them.
math_exp2 :: proc(x: f64) -> f64 {
	N :: 128
	SHIFT :: 52776558133248.0 // 0x1.8p52 / N
	bits := transmute(u64)x
	abstop := u32(bits >> 52) & 0x7ff
	if abstop - 0x3c9 >= 0x408 - 0x3c9 {
		if abstop - 0x3c9 >= 0x80000000 {
			return 1.0 + x
		}
		if abstop >= 0x409 {
			if math.is_inf(x, -1) {
				return 0
			}
			if abstop >= 0x7ff {
				return 1.0 + x
			}
			if bits >> 63 == 0 {
				return math.inf_f64(1)
			}
			if x <= -2147483648.0 || bits >= transmute(u64)f64(-1075.0) {
				return 0
			}
		}
		if 2 * bits > 2 * transmute(u64)f64(928.0) {
			abstop = 0
		}
	}
	kd := x + SHIFT
	ki := transmute(u64)kd
	kd -= SHIFT
	r := x - kd
	idx := 2 * (ki % N)
	top := ki << (52 - 7)
	tail := transmute(f64)EXP2_TABLE[idx]
	sbits := EXP2_TABLE[idx + 1] + top
	r2 := r * r
	tmp := tail + r * EXP2_POLY[0] + r2 * (EXP2_POLY[1] + r * EXP2_POLY[2]) + r2 * r2 * (EXP2_POLY[3] + r * EXP2_POLY[4])
	if abstop == 0 {
		// Cases that may overflow or underflow when computing scale * (1 + tmp) without an intermediate rounding.
		sbits := sbits
		if ki & 0x80000000 == 0 {
			sbits -= 1 << 52
			scale := transmute(f64)sbits
			return 2 * (scale + scale * tmp)
		}
		sbits += 1022 << 52
		scale := transmute(f64)sbits
		y := scale + scale * tmp
		if y < 1.0 {
			// Round y to the right precision before scaling it into the subnormal range.
			lo := scale - y + scale * tmp
			hi := 1.0 + y
			lo = 1.0 - hi + y + lo
			y = (hi + lo) - 1.0
			if y == 0 {
				y = 0
			}
		}
		return 0h0010000000000000 * y
	}
	scale := transmute(f64)sbits
	return scale + scale * tmp
}

// `x` times two to the power the exponent `fn`, as glibc's scalb: a non-integer exponent gives NaN.
math_scalb :: proc(x, fn: f64) -> f64 {
	switch {
	case math.is_nan(x) || math.is_nan(fn):
		return x * fn
	case math.is_inf(fn):
		return x * fn if fn > 0 else x / -fn
	case math.floor(fn) != fn:
		return math.nan_f64()
	case fn > 65000:
		return math.ldexp(x, 65000)
	case fn < -65000:
		return math.ldexp(x, -65000)
	}
	return math.ldexp(x, int(fn))
}

@(private = "file")
EXP2_POLY :: [5]f64{0.6931471805599453, 0.24022650695909065, 0.0555041086686087, 0.009618131975721055, 0.0013332074570119598}

@(private = "file", rodata)
EXP2_TABLE := [256]u64{
	0x0, 0x3ff0000000000000,
	0x3c9b3b4f1a88bf6e, 0x3feff63da9fb3335,
	0xbc7160139cd8dc5d, 0x3fefec9a3e778061,
	0xbc905e7a108766d1, 0x3fefe315e86e7f85,
	0x3c8cd2523567f613, 0x3fefd9b0d3158574,
	0xbc8bce8023f98efa, 0x3fefd06b29ddf6de,
	0x3c60f74e61e6c861, 0x3fefc74518759bc8,
	0x3c90a3e45b33d399, 0x3fefbe3ecac6f383,
	0x3c979aa65d837b6d, 0x3fefb5586cf9890f,
	0x3c8eb51a92fdeffc, 0x3fefac922b7247f7,
	0x3c3ebe3d702f9cd1, 0x3fefa3ec32d3d1a2,
	0xbc6a033489906e0b, 0x3fef9b66affed31b,
	0xbc9556522a2fbd0e, 0x3fef9301d0125b51,
	0xbc5080ef8c4eea55, 0x3fef8abdc06c31cc,
	0xbc91c923b9d5f416, 0x3fef829aaea92de0,
	0x3c80d3e3e95c55af, 0x3fef7a98c8a58e51,
	0xbc801b15eaa59348, 0x3fef72b83c7d517b,
	0xbc8f1ff055de323d, 0x3fef6af9388c8dea,
	0x3c8b898c3f1353bf, 0x3fef635beb6fcb75,
	0xbc96d99c7611eb26, 0x3fef5be084045cd4,
	0x3c9aecf73e3a2f60, 0x3fef54873168b9aa,
	0xbc8fe782cb86389d, 0x3fef4d5022fcd91d,
	0x3c8a6f4144a6c38d, 0x3fef463b88628cd6,
	0x3c807a05b0e4047d, 0x3fef3f49917ddc96,
	0x3c968efde3a8a894, 0x3fef387a6e756238,
	0x3c875e18f274487d, 0x3fef31ce4fb2a63f,
	0x3c80472b981fe7f2, 0x3fef2b4565e27cdd,
	0xbc96b87b3f71085e, 0x3fef24dfe1f56381,
	0x3c82f7e16d09ab31, 0x3fef1e9df51fdee1,
	0xbc3d219b1a6fbffa, 0x3fef187fd0dad990,
	0x3c8b3782720c0ab4, 0x3fef1285a6e4030b,
	0x3c6e149289cecb8f, 0x3fef0cafa93e2f56,
	0x3c834d754db0abb6, 0x3fef06fe0a31b715,
	0x3c864201e2ac744c, 0x3fef0170fc4cd831,
	0x3c8fdd395dd3f84a, 0x3feefc08b26416ff,
	0xbc86a3803b8e5b04, 0x3feef6c55f929ff1,
	0xbc924aedcc4b5068, 0x3feef1a7373aa9cb,
	0xbc9907f81b512d8e, 0x3feeecae6d05d866,
	0xbc71d1e83e9436d2, 0x3feee7db34e59ff7,
	0xbc991919b3ce1b15, 0x3feee32dc313a8e5,
	0x3c859f48a72a4c6d, 0x3feedea64c123422,
	0xbc9312607a28698a, 0x3feeda4504ac801c,
	0xbc58a78f4817895b, 0x3feed60a21f72e2a,
	0xbc7c2c9b67499a1b, 0x3feed1f5d950a897,
	0x3c4363ed60c2ac11, 0x3feece086061892d,
	0x3c9666093b0664ef, 0x3feeca41ed1d0057,
	0x3c6ecce1daa10379, 0x3feec6a2b5c13cd0,
	0x3c93ff8e3f0f1230, 0x3feec32af0d7d3de,
	0x3c7690cebb7aafb0, 0x3feebfdad5362a27,
	0x3c931dbdeb54e077, 0x3feebcb299fddd0d,
	0xbc8f94340071a38e, 0x3feeb9b2769d2ca7,
	0xbc87deccdc93a349, 0x3feeb6daa2cf6642,
	0xbc78dec6bd0f385f, 0x3feeb42b569d4f82,
	0xbc861246ec7b5cf6, 0x3feeb1a4ca5d920f,
	0x3c93350518fdd78e, 0x3feeaf4736b527da,
	0x3c7b98b72f8a9b05, 0x3feead12d497c7fd,
	0x3c9063e1e21c5409, 0x3feeab07dd485429,
	0x3c34c7855019c6ea, 0x3feea9268a5946b7,
	0x3c9432e62b64c035, 0x3feea76f15ad2148,
	0xbc8ce44a6199769f, 0x3feea5e1b976dc09,
	0xbc8c33c53bef4da8, 0x3feea47eb03a5585,
	0xbc845378892be9ae, 0x3feea34634ccc320,
	0xbc93cedd78565858, 0x3feea23882552225,
	0x3c5710aa807e1964, 0x3feea155d44ca973,
	0xbc93b3efbf5e2228, 0x3feea09e667f3bcd,
	0xbc6a12ad8734b982, 0x3feea012750bdabf,
	0xbc6367efb86da9ee, 0x3fee9fb23c651a2f,
	0xbc80dc3d54e08851, 0x3fee9f7df9519484,
	0xbc781f647e5a3ecf, 0x3fee9f75e8ec5f74,
	0xbc86ee4ac08b7db0, 0x3fee9f9a48a58174,
	0xbc8619321e55e68a, 0x3fee9feb564267c9,
	0x3c909ccb5e09d4d3, 0x3feea0694fde5d3f,
	0xbc7b32dcb94da51d, 0x3feea11473eb0187,
	0x3c94ecfd5467c06b, 0x3feea1ed0130c132,
	0x3c65ebe1abd66c55, 0x3feea2f336cf4e62,
	0xbc88a1c52fb3cf42, 0x3feea427543e1a12,
	0xbc9369b6f13b3734, 0x3feea589994cce13,
	0xbc805e843a19ff1e, 0x3feea71a4623c7ad,
	0xbc94d450d872576e, 0x3feea8d99b4492ed,
	0x3c90ad675b0e8a00, 0x3feeaac7d98a6699,
	0x3c8db72fc1f0eab4, 0x3feeace5422aa0db,
	0xbc65b6609cc5e7ff, 0x3feeaf3216b5448c,
	0x3c7bf68359f35f44, 0x3feeb1ae99157736,
	0xbc93091fa71e3d83, 0x3feeb45b0b91ffc6,
	0xbc5da9b88b6c1e29, 0x3feeb737b0cdc5e5,
	0xbc6c23f97c90b959, 0x3feeba44cbc8520f,
	0xbc92434322f4f9aa, 0x3feebd829fde4e50,
	0xbc85ca6cd7668e4b, 0x3feec0f170ca07ba,
	0x3c71affc2b91ce27, 0x3feec49182a3f090,
	0x3c6dd235e10a73bb, 0x3feec86319e32323,
	0xbc87c50422622263, 0x3feecc667b5de565,
	0x3c8b1c86e3e231d5, 0x3feed09bec4a2d33,
	0xbc91bbd1d3bcbb15, 0x3feed503b23e255d,
	0x3c90cc319cee31d2, 0x3feed99e1330b358,
	0x3c8469846e735ab3, 0x3feede6b5579fdbf,
	0xbc82dfcd978e9db4, 0x3feee36bbfd3f37a,
	0x3c8c1a7792cb3387, 0x3feee89f995ad3ad,
	0xbc907b8f4ad1d9fa, 0x3feeee07298db666,
	0xbc55c3d956dcaeba, 0x3feef3a2b84f15fb,
	0xbc90a40e3da6f640, 0x3feef9728de5593a,
	0xbc68d6f438ad9334, 0x3feeff76f2fb5e47,
	0xbc91eee26b588a35, 0x3fef05b030a1064a,
	0x3c74ffd70a5fddcd, 0x3fef0c1e904bc1d2,
	0xbc91bdfbfa9298ac, 0x3fef12c25bd71e09,
	0x3c736eae30af0cb3, 0x3fef199bdd85529c,
	0x3c8ee3325c9ffd94, 0x3fef20ab5fffd07a,
	0x3c84e08fd10959ac, 0x3fef27f12e57d14b,
	0x3c63cdaf384e1a67, 0x3fef2f6d9406e7b5,
	0x3c676b2c6c921968, 0x3fef3720dcef9069,
	0xbc808a1883ccb5d2, 0x3fef3f0b555dc3fa,
	0xbc8fad5d3ffffa6f, 0x3fef472d4a07897c,
	0xbc900dae3875a949, 0x3fef4f87080d89f2,
	0x3c74a385a63d07a7, 0x3fef5818dcfba487,
	0xbc82919e2040220f, 0x3fef60e316c98398,
	0x3c8e5a50d5c192ac, 0x3fef69e603db3285,
	0x3c843a59ac016b4b, 0x3fef7321f301b460,
	0xbc82d52107b43e1f, 0x3fef7c97337b9b5f,
	0xbc892ab93b470dc9, 0x3fef864614f5a129,
	0x3c74b604603a88d3, 0x3fef902ee78b3ff6,
	0x3c83c5ec519d7271, 0x3fef9a51fbc74c83,
	0xbc8ff7128fd391f0, 0x3fefa4afa2a490da,
	0xbc8dae98e223747d, 0x3fefaf482d8e67f1,
	0x3c8ec3bc41aa2008, 0x3fefba1bee615a27,
	0x3c842b94c3a9eb32, 0x3fefc52b376bba97,
	0x3c8a64a931d185ee, 0x3fefd0765b6e4540,
	0xbc8e37bae43be3ed, 0x3fefdbfdad9cbe14,
	0x3c77893b4d91cd9d, 0x3fefe7c1819e90d8,
	0x3c5305c14160cc89, 0x3feff3c22b8f71f1,
}
