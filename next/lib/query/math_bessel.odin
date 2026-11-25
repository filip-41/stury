package query

import "core:math"

// Bessel functions of the first and second kinds, integer orders, after FreeBSD's e_j0.c, e_j1.c and e_jn.c (Sun
// Microsystems, 1993, free to use with this notice) as musl carries them.

@(private = "file")
high_word :: #force_inline proc "contextless" (x: f64) -> u32 {
	return u32(transmute(u64)x >> 32)
}

// The orders 0 and 1's shared tail for |x| >= 2: j0 and y0 are `kind` 0 and 1, j1 and y1 are 2 and 3.
@(private = "file")
Order_Kind :: enum u8 {
	J0,
	Y0,
	J1,
	Y1,
}

@(private = "file")
asymptotic :: proc(ix: u32, x: f64, kind: Order_Kind, negative: bool) -> f64 {
	s, c, ss, cc, z: f64
	switch kind {
	case .J0, .Y0:
		s, c = math.sin(x), math.cos(x)
		if kind == .Y0 {
			c = -c
		}
		cc = s + c
		if ix < 0x7fe00000 {
			ss = s - c
			z = -math.cos(2 * x)
			if s * c < 0 {
				cc = z / ss
			} else {
				ss = z / cc
			}
			if ix < 0x48000000 {
				if kind == .Y0 {
					ss = -ss
				}
				cc = pzero(x) * cc - qzero(x) * ss
			}
		}
	case .J1, .Y1:
		s = math.sin(x)
		if kind == .Y1 {
			s = -s
		}
		c = math.cos(x)
		cc = s - c
		if ix < 0x7fe00000 {
			ss = -s - c
			z = math.cos(2 * x)
			if s * c > 0 {
				cc = z / ss
			} else {
				ss = z / cc
			}
			if ix < 0x48000000 {
				if kind == .Y1 {
					ss = -ss
				}
				cc = pone(x) * cc - qone(x) * ss
			}
		}
		if negative {
			cc = -cc
		}
	}
	return J0_INVSQRTPI * cc / math.sqrt(x)
}

// The Bessel function of the first kind of order 0.
bessel_j0 :: proc(x: f64) -> f64 {
	ix := high_word(x) & 0x7fffffff
	if ix >= 0x7ff00000 {
		return 1 / (x * x)
	}
	ax := abs(x)
	if ix >= 0x40000000 {
		return asymptotic(ix, ax, .J0, false)
	}
	if ix >= 0x3f200000 {
		z := ax * ax
		r := z * (J0_R02 + z * (J0_R03 + z * (J0_R04 + z * J0_R05)))
		s := 1 + z * (J0_S01 + z * (J0_S02 + z * (J0_S03 + z * J0_S04)))
		return (1 + ax / 2) * (1 - ax / 2) + z * (r / s)
	}
	if ix >= 0x38000000 {
		ax = 0.25 * ax * ax
	}
	return 1 - ax
}

// The Bessel function of the second kind of order 0.
bessel_y0 :: proc(x: f64) -> f64 {
	bits := transmute(u64)x
	ix := u32(bits >> 32)
	if bits << 1 == 0 {
		return math.inf_f64(-1)
	}
	if ix >> 31 != 0 {
		return math.nan_f64()
	}
	if ix >= 0x7ff00000 {
		return 1 / x
	}
	if ix >= 0x40000000 {
		return asymptotic(ix, x, .Y0, false)
	}
	if ix >= 0x3e400000 {
		z := x * x
		u := J0_U00 + z * (J0_U01 + z * (J0_U02 + z * (J0_U03 + z * (J0_U04 + z * (J0_U05 + z * J0_U06)))))
		v := 1.0 + z * (J0_V01 + z * (J0_V02 + z * (J0_V03 + z * J0_V04)))
		return u / v + J0_TPI * (bessel_j0(x) * math.ln(x))
	}
	return J0_U00 + J0_TPI * math.ln(x)
}

@(private = "file")
pzero :: proc(x: f64) -> f64 {
	ix := high_word(x) & 0x7fffffff
	p: ^[6]f64
	q: ^[5]f64
	switch {
	case ix >= 0x40200000:
		p, q = &J0_PR8, &J0_PS8
	case ix >= 0x40122E8B:
		p, q = &J0_PR5, &J0_PS5
	case ix >= 0x4006DB6D:
		p, q = &J0_PR3, &J0_PS3
	case:
		p, q = &J0_PR2, &J0_PS2
	}
	z := 1.0 / (x * x)
	r := p[0] + z * (p[1] + z * (p[2] + z * (p[3] + z * (p[4] + z * p[5]))))
	s := 1.0 + z * (q[0] + z * (q[1] + z * (q[2] + z * (q[3] + z * q[4]))))
	return 1.0 + r / s
}

@(private = "file")
qzero :: proc(x: f64) -> f64 {
	ix := high_word(x) & 0x7fffffff
	p, q: ^[6]f64
	switch {
	case ix >= 0x40200000:
		p, q = &J0_QR8, &J0_QS8
	case ix >= 0x40122E8B:
		p, q = &J0_QR5, &J0_QS5
	case ix >= 0x4006DB6D:
		p, q = &J0_QR3, &J0_QS3
	case:
		p, q = &J0_QR2, &J0_QS2
	}
	z := 1.0 / (x * x)
	r := p[0] + z * (p[1] + z * (p[2] + z * (p[3] + z * (p[4] + z * p[5]))))
	s := 1.0 + z * (q[0] + z * (q[1] + z * (q[2] + z * (q[3] + z * (q[4] + z * q[5])))))
	return (-.125 + r / s) / x
}

// The Bessel function of the first kind of order 1.
bessel_j1 :: proc(x: f64) -> f64 {
	ix := high_word(x) & 0x7fffffff
	negative := high_word(x) >> 31 != 0
	if ix >= 0x7ff00000 {
		return 1 / (x * x)
	}
	if ix >= 0x40000000 {
		return asymptotic(ix, abs(x), .J1, negative)
	}
	z: f64
	if ix >= 0x38000000 {
		z = x * x
		r := z * (J1_R00 + z * (J1_R01 + z * (J1_R02 + z * J1_R03)))
		s := 1 + z * (J1_S01 + z * (J1_S02 + z * (J1_S03 + z * (J1_S04 + z * J1_S05))))
		z = r / s
	} else {
		z = x
	}
	return (0.5 + z) * x
}

// The Bessel function of the second kind of order 1.
bessel_y1 :: proc(x: f64) -> f64 {
	bits := transmute(u64)x
	ix := u32(bits >> 32)
	if bits << 1 == 0 {
		return math.inf_f64(-1)
	}
	if ix >> 31 != 0 {
		return math.nan_f64()
	}
	if ix >= 0x7ff00000 {
		return 1 / x
	}
	if ix >= 0x40000000 {
		return asymptotic(ix, x, .Y1, false)
	}
	if ix < 0x3c900000 {
		return -J1_TPI / x
	}
	z := x * x
	u := J1_U0[0] + z * (J1_U0[1] + z * (J1_U0[2] + z * (J1_U0[3] + z * J1_U0[4])))
	v := 1 + z * (J1_V0[0] + z * (J1_V0[1] + z * (J1_V0[2] + z * (J1_V0[3] + z * J1_V0[4]))))
	return x * (u / v) + J1_TPI * (bessel_j1(x) * math.ln(x) - 1 / x)
}

@(private = "file")
pone :: proc(x: f64) -> f64 {
	ix := high_word(x) & 0x7fffffff
	p: ^[6]f64
	q: ^[5]f64
	switch {
	case ix >= 0x40200000:
		p, q = &J1_PR8, &J1_PS8
	case ix >= 0x40122E8B:
		p, q = &J1_PR5, &J1_PS5
	case ix >= 0x4006DB6D:
		p, q = &J1_PR3, &J1_PS3
	case:
		p, q = &J1_PR2, &J1_PS2
	}
	z := 1.0 / (x * x)
	r := p[0] + z * (p[1] + z * (p[2] + z * (p[3] + z * (p[4] + z * p[5]))))
	s := 1.0 + z * (q[0] + z * (q[1] + z * (q[2] + z * (q[3] + z * q[4]))))
	return 1.0 + r / s
}

@(private = "file")
qone :: proc(x: f64) -> f64 {
	ix := high_word(x) & 0x7fffffff
	p, q: ^[6]f64
	switch {
	case ix >= 0x40200000:
		p, q = &J1_QR8, &J1_QS8
	case ix >= 0x40122E8B:
		p, q = &J1_QR5, &J1_QS5
	case ix >= 0x4006DB6D:
		p, q = &J1_QR3, &J1_QS3
	case:
		p, q = &J1_QR2, &J1_QS2
	}
	z := 1.0 / (x * x)
	r := p[0] + z * (p[1] + z * (p[2] + z * (p[3] + z * (p[4] + z * p[5]))))
	s := 1.0 + z * (q[0] + z * (q[1] + z * (q[2] + z * (q[3] + z * (q[4] + z * q[5])))))
	return (.375 + r / s) / x
}

// The Bessel function of the first kind of order `n`.
bessel_jn :: proc(n: int, xin: f64) -> f64 {
	bits := transmute(u64)xin
	ix := u32(bits >> 32) & 0x7fffffff
	lx := u32(bits)
	negative := bits >> 63 != 0
	if math.is_nan(xin) {
		return xin
	}
	// J(-n, x) = (-1)^n J(n, x) and J(n, -x) = (-1)^n J(n, x), so J(-n, x) = J(n, -x).
	if n == 0 {
		return bessel_j0(xin)
	}
	nm1: int
	arg := xin
	if n < 0 {
		nm1 = -(n + 1)
		arg = -xin
		negative = !negative
	} else {
		nm1 = n - 1
	}
	if nm1 == 0 {
		return bessel_j1(arg)
	}
	// An even order has no sign: an odd one has x's.
	negative = negative && n & 1 != 0
	x := abs(arg)
	b, a, temp: f64
	switch {
	case ix | lx == 0 || ix == 0x7ff00000:
		b = 0
	case f64(nm1) < x:
		if ix >= 0x52d00000 {
			s, c := math.sin(x), math.cos(x)
			switch nm1 & 3 {
			case 0:
				temp = -c + s
			case 1:
				temp = -c - s
			case 2:
				temp = c - s
			case:
				temp = c + s
			}
			b = J0_INVSQRTPI * temp / math.sqrt(x)
		} else {
			a = bessel_j0(x)
			b = bessel_j1(x)
			for i := 0; i < nm1; {
				i += 1
				temp = b
				b = b * (2.0 * f64(i) / x) - a
				a = temp
			}
		}
	case ix < 0x3e100000:
		// x is tiny, the first Taylor term of J(n, x) is 1/n! (x/2)^n.
		if nm1 > 32 {
			b = 0
		} else {
			temp = x * 0.5
			b = temp
			a = 1
			for i := 2; i <= nm1 + 1; i += 1 {
				a *= f64(i)
				b *= temp
			}
			b = b / a
		}
	case:
		// The backward recurrence, as a continued fraction whose terms are counted until it settles.
		nf := f64(nm1) + 1.0
		w := 2 * nf / x
		h := 2 / x
		z := w + h
		q0 := w
		q1 := w * z - 1.0
		k := 1
		for q1 < 1.0e9 {
			k += 1
			z += h
			tmp := z * q1 - q0
			q0 = q1
			q1 = tmp
		}
		t := 0.0
		for i := k; i >= 0; i -= 1 {
			t = 1 / (2 * (f64(i) + nf) / x - t)
		}
		a = t
		b = 1.0
		// A recurrence value past what a double holds means the result underflows to zero.
		if nf * math.ln(abs(w)) < 7.09782712893383973096e+02 {
			for i := nm1; i > 0; i -= 1 {
				temp = b
				b = b * (2.0 * f64(i)) / x - a
				a = temp
			}
		} else {
			for i := nm1; i > 0; i -= 1 {
				temp = b
				b = b * (2.0 * f64(i)) / x - a
				a = temp
				if b > 0h5F30000000000000 {
					a /= b
					t /= b
					b = 1.0
				}
			}
		}
		z = bessel_j0(x)
		w = bessel_j1(x)
		if abs(z) >= abs(w) {
			b = t * z / b
		} else {
			b = t * w / a
		}
	}
	return -b if negative else b
}

// The Bessel function of the second kind of order `n`.
bessel_yn :: proc(n: int, x: f64) -> f64 {
	bits := transmute(u64)x
	ix := u32(bits >> 32) & 0x7fffffff
	if math.is_nan(x) {
		return x
	}
	if bits >> 63 != 0 && bits << 1 != 0 {
		return math.nan_f64()
	}
	if ix == 0x7ff00000 {
		return 0
	}
	if n == 0 {
		return bessel_y0(x)
	}
	nm1: int
	negative: bool
	if n < 0 {
		nm1 = -(n + 1)
		negative = n & 1 != 0
	} else {
		nm1 = n - 1
	}
	if nm1 == 0 {
		return -bessel_y1(x) if negative else bessel_y1(x)
	}
	b, a, temp: f64
	if ix >= 0x52d00000 {
		s, c := math.sin(x), math.cos(x)
		switch nm1 & 3 {
		case 0:
			temp = -s - c
		case 1:
			temp = -s + c
		case 2:
			temp = s + c
		case:
			temp = s - c
		}
		b = J0_INVSQRTPI * temp / math.sqrt(x)
	} else {
		a = bessel_y0(x)
		b = bessel_y1(x)
		// Stop at minus infinity.
		for i := 0; i < nm1 && high_word(b) != 0xfff00000; {
			i += 1
			temp = b
			b = (2.0 * f64(i) / x) * b - a
			a = temp
		}
	}
	return -b if negative else b
}

@(private = "file", rodata)
J0_PR8 := [6]f64{
	0.00000000000000000000e+00,
	-7.03124999999900357484e-02,
	-8.08167041275349795626e+00,
	-2.57063105679704847262e+02,
	-2.48521641009428822144e+03,
	-5.25304380490729545272e+03,
}

@(private = "file", rodata)
J0_PS8 := [5]f64{
	1.16534364619668181717e+02,
	3.83374475364121826715e+03,
	4.05978572648472545552e+04,
	1.16752972564375915681e+05,
	4.76277284146730962675e+04,
}

@(private = "file", rodata)
J0_PR5 := [6]f64{
	-1.14125464691894502584e-11,
	-7.03124940873599280078e-02,
	-4.15961064470587782438e+00,
	-6.76747652265167261021e+01,
	-3.31231299649172967747e+02,
	-3.46433388365604912451e+02,
}

@(private = "file", rodata)
J0_PS5 := [5]f64{
	6.07539382692300335975e+01,
	1.05125230595704579173e+03,
	5.97897094333855784498e+03,
	9.62544514357774460223e+03,
	2.40605815922939109441e+03,
}

@(private = "file", rodata)
J0_PR3 := [6]f64{
	-2.54704601771951915620e-09,
	-7.03119616381481654654e-02,
	-2.40903221549529611423e+00,
	-2.19659774734883086467e+01,
	-5.80791704701737572236e+01,
	-3.14479470594888503854e+01,
}

@(private = "file", rodata)
J0_PS3 := [5]f64{
	3.58560338055209726349e+01,
	3.61513983050303863820e+02,
	1.19360783792111533330e+03,
	1.12799679856907414432e+03,
	1.73580930813335754692e+02,
}

@(private = "file", rodata)
J0_PR2 := [6]f64{
	-8.87534333032526411254e-08,
	-7.03030995483624743247e-02,
	-1.45073846780952986357e+00,
	-7.63569613823527770791e+00,
	-1.11931668860356747786e+01,
	-3.23364579351335335033e+00,
}

@(private = "file", rodata)
J0_PS2 := [5]f64{
	2.22202997532088808441e+01,
	1.36206794218215208048e+02,
	2.70470278658083486789e+02,
	1.53875394208320329881e+02,
	1.46576176948256193810e+01,
}

@(private = "file", rodata)
J0_QR8 := [6]f64{
	0.00000000000000000000e+00,
	7.32421874999935051953e-02,
	1.17682064682252693899e+01,
	5.57673380256401856059e+02,
	8.85919720756468632317e+03,
	3.70146267776887834771e+04,
}

@(private = "file", rodata)
J0_QS8 := [6]f64{
	1.63776026895689824414e+02,
	8.09834494656449805916e+03,
	1.42538291419120476348e+05,
	8.03309257119514397345e+05,
	8.40501579819060512818e+05,
	-3.43899293537866615225e+05,
}

@(private = "file", rodata)
J0_QR5 := [6]f64{
	1.84085963594515531381e-11,
	7.32421766612684765896e-02,
	5.83563508962056953777e+00,
	1.35111577286449829671e+02,
	1.02724376596164097464e+03,
	1.98997785864605384631e+03,
}

@(private = "file", rodata)
J0_QS5 := [6]f64{
	8.27766102236537761883e+01,
	2.07781416421392987104e+03,
	1.88472887785718085070e+04,
	5.67511122894947329769e+04,
	3.59767538425114471465e+04,
	-5.35434275601944773371e+03,
}

@(private = "file", rodata)
J0_QR3 := [6]f64{
	4.37741014089738620906e-09,
	7.32411180042911447163e-02,
	3.34423137516170720929e+00,
	4.26218440745412650017e+01,
	1.70808091340565596283e+02,
	1.66733948696651168575e+02,
}

@(private = "file", rodata)
J0_QS3 := [6]f64{
	4.87588729724587182091e+01,
	7.09689221056606015736e+02,
	3.70414822620111362994e+03,
	6.46042516752568917582e+03,
	2.51633368920368957333e+03,
	-1.49247451836156386662e+02,
}

@(private = "file", rodata)
J0_QR2 := [6]f64{
	1.50444444886983272379e-07,
	7.32234265963079278272e-02,
	1.99819174093815998816e+00,
	1.44956029347885735348e+01,
	3.16662317504781540833e+01,
	1.62527075710929267416e+01,
}

@(private = "file", rodata)
J0_QS2 := [6]f64{
	3.03655848355219184498e+01,
	2.69348118608049844624e+02,
	8.44783757595320139444e+02,
	8.82935845112488550512e+02,
	2.12666388511798828631e+02,
	-5.31095493882666946917e+00,
}

@(private = "file")
J0_INVSQRTPI :: 5.64189583547756279280e-01

@(private = "file")
J0_TPI :: 6.36619772367581382433e-01

@(private = "file")
J0_R02 :: 1.56249999999999947958e-02

@(private = "file")
J0_R03 :: -1.89979294238854721751e-04

@(private = "file")
J0_R04 :: 1.82954049532700665670e-06

@(private = "file")
J0_R05 :: -4.61832688532103189199e-09

@(private = "file")
J0_S01 :: 1.56191029464890010492e-02

@(private = "file")
J0_S02 :: 1.16926784663337450260e-04

@(private = "file")
J0_S03 :: 5.13546550207318111446e-07

@(private = "file")
J0_S04 :: 1.16614003333790000205e-09

@(private = "file")
J0_U00 :: -7.38042951086872317523e-02

@(private = "file")
J0_U01 :: 1.76666452509181115538e-01

@(private = "file")
J0_U02 :: -1.38185671945596898896e-02

@(private = "file")
J0_U03 :: 3.47453432093683650238e-04

@(private = "file")
J0_U04 :: -3.81407053724364161125e-06

@(private = "file")
J0_U05 :: 1.95590137035022920206e-08

@(private = "file")
J0_U06 :: -3.98205194132103398453e-11

@(private = "file")
J0_V01 :: 1.27304834834123699328e-02

@(private = "file")
J0_V02 :: 7.60068627350353253702e-05

@(private = "file")
J0_V03 :: 2.59150851840457805467e-07

@(private = "file")
J0_V04 :: 4.41110311332675467403e-10

@(private = "file", rodata)
J1_U0 := [5]f64{
	-1.96057090646238940668e-01,
	5.04438716639811282616e-02,
	-1.91256895875763547298e-03,
	2.35252600561610495928e-05,
	-9.19099158039878874504e-08,
}

@(private = "file", rodata)
J1_V0 := [5]f64{
	1.99167318236649903973e-02,
	2.02552581025135171496e-04,
	1.35608801097516229404e-06,
	6.22741452364621501295e-09,
	1.66559246207992079114e-11,
}

@(private = "file", rodata)
J1_PR8 := [6]f64{
	0.00000000000000000000e+00,
	1.17187499999988647970e-01,
	1.32394806593073575129e+01,
	4.12051854307378562225e+02,
	3.87474538913960532227e+03,
	7.91447954031891731574e+03,
}

@(private = "file", rodata)
J1_PS8 := [5]f64{
	1.14207370375678408436e+02,
	3.65093083420853463394e+03,
	3.69562060269033463555e+04,
	9.76027935934950801311e+04,
	3.08042720627888811578e+04,
}

@(private = "file", rodata)
J1_PR5 := [6]f64{
	1.31990519556243522749e-11,
	1.17187493190614097638e-01,
	6.80275127868432871736e+00,
	1.08308182990189109773e+02,
	5.17636139533199752805e+02,
	5.28715201363337541807e+02,
}

@(private = "file", rodata)
J1_PS5 := [5]f64{
	5.92805987221131331921e+01,
	9.91401418733614377743e+02,
	5.35326695291487976647e+03,
	7.84469031749551231769e+03,
	1.50404688810361062679e+03,
}

@(private = "file", rodata)
J1_PR3 := [6]f64{
	3.02503916137373618024e-09,
	1.17186865567253592491e-01,
	3.93297750033315640650e+00,
	3.51194035591636932736e+01,
	9.10550110750781271918e+01,
	4.85590685197364919645e+01,
}

@(private = "file", rodata)
J1_PS3 := [5]f64{
	3.47913095001251519989e+01,
	3.36762458747825746741e+02,
	1.04687139975775130551e+03,
	8.90811346398256432622e+02,
	1.03787932439639277504e+02,
}

@(private = "file", rodata)
J1_PR2 := [6]f64{
	1.07710830106873743082e-07,
	1.17176219462683348094e-01,
	2.36851496667608785174e+00,
	1.22426109148261232917e+01,
	1.76939711271687727390e+01,
	5.07352312588818499250e+00,
}

@(private = "file", rodata)
J1_PS2 := [5]f64{
	2.14364859363821409488e+01,
	1.25290227168402751090e+02,
	2.32276469057162813669e+02,
	1.17679373287147100768e+02,
	8.36463893371618283368e+00,
}

@(private = "file", rodata)
J1_QR8 := [6]f64{
	0.00000000000000000000e+00,
	-1.02539062499992714161e-01,
	-1.62717534544589987888e+01,
	-7.59601722513950107896e+02,
	-1.18498066702429587167e+04,
	-4.84385124285750353010e+04,
}

@(private = "file", rodata)
J1_QS8 := [6]f64{
	1.61395369700722909556e+02,
	7.82538599923348465381e+03,
	1.33875336287249578163e+05,
	7.19657723683240939863e+05,
	6.66601232617776375264e+05,
	-2.94490264303834643215e+05,
}

@(private = "file", rodata)
J1_QR5 := [6]f64{
	-2.08979931141764104297e-11,
	-1.02539050241375426231e-01,
	-8.05644828123936029840e+00,
	-1.83669607474888380239e+02,
	-1.37319376065508163265e+03,
	-2.61244440453215656817e+03,
}

@(private = "file", rodata)
J1_QS5 := [6]f64{
	8.12765501384335777857e+01,
	1.99179873460485964642e+03,
	1.74684851924908907677e+04,
	4.98514270910352279316e+04,
	2.79480751638918118260e+04,
	-4.71918354795128470869e+03,
}

@(private = "file", rodata)
J1_QR3 := [6]f64{
	-5.07831226461766561369e-09,
	-1.02537829820837089745e-01,
	-4.61011581139473403113e+00,
	-5.78472216562783643212e+01,
	-2.28244540737631695038e+02,
	-2.19210128478909325622e+02,
}

@(private = "file", rodata)
J1_QS3 := [6]f64{
	4.76651550323729509273e+01,
	6.73865112676699709482e+02,
	3.38015286679526343505e+03,
	5.54772909720722782367e+03,
	1.90311919338810798763e+03,
	-1.35201191444307340817e+02,
}

@(private = "file", rodata)
J1_QR2 := [6]f64{
	-1.78381727510958865572e-07,
	-1.02517042607985553460e-01,
	-2.75220568278187460720e+00,
	-1.96636162643703720221e+01,
	-4.23253133372830490089e+01,
	-2.13719211703704061733e+01,
}

@(private = "file", rodata)
J1_QS2 := [6]f64{
	2.95333629060523854548e+01,
	2.52981549982190529136e+02,
	7.57502834868645436472e+02,
	7.39393205320467245656e+02,
	1.55949003336666123687e+02,
	-4.95949898822628210127e+00,
}

@(private = "file")
J1_INVSQRTPI :: 5.64189583547756279280e-01

@(private = "file")
J1_TPI :: 6.36619772367581382433e-01

@(private = "file")
J1_R00 :: -6.25000000000000000000e-02

@(private = "file")
J1_R01 :: 1.40705666955189706048e-03

@(private = "file")
J1_R02 :: -1.59955631084035597520e-05

@(private = "file")
J1_R03 :: 4.96727999609584448412e-08

@(private = "file")
J1_S01 :: 1.91537599538363460805e-02

@(private = "file")
J1_S02 :: 1.85946785588630915560e-04

@(private = "file")
J1_S03 :: 1.17718464042623683263e-06

@(private = "file")
J1_S04 :: 5.04636257076217042715e-09

@(private = "file")
J1_S05 :: 1.23542274426137913908e-11

