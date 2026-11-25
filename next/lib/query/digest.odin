package query

import "core:encoding/endian"
import hashing "core:hash"
import "core:math/bits"

// Pure-Odin digests (SHA-1, SHA-256, SHA-512, MD5, RFC 2104 HMAC, IEEE CRC-32) as lowercase hex, and UUID formatting.
// Kept self-contained so linking `lib/query` brings in no OS crypto framework or WASI fd_* syscalls.

Digest :: enum u8 {
	Sha1,
	Sha256,
	Sha512,
	Md5,
}

@(private)
MOST_DIGEST :: 64

// The digest of the bytes of `s` by `kind`, as hex.
@(require_results)
digest_hex :: proc(h: ^Heap, s: string, kind: Digest) -> (res: Value, status: Status) {
	data := transmute([]u8)s
	buf: [MOST_DIGEST]u8
	n: int
	switch kind {
	case .Sha1:
		st: Sha1_State
		sha1_init(&st)
		sha1_update(&st, data)
		sha1_final(&st, buf[:20])
		n = 20
	case .Sha256:
		st: Sha256_State
		sha256_init(&st)
		sha256_update(&st, data)
		sha256_final(&st, buf[:32])
		n = 32
	case .Sha512:
		st: Sha512_State
		sha512_init(&st)
		sha512_update(&st, data)
		sha512_final(&st, buf[:64])
		n = 64
	case .Md5:
		st: Md5_State
		md5_init(&st)
		md5_update(&st, data)
		md5_final(&st, buf[:16])
		n = 16
	}
	return encode_hex(h, string(buf[:n]))
}

// The HMAC (RFC 2104) of the bytes of `s` under the bytes of `key` by `kind`, which is `.Sha256` or `.Sha512`, as hex.
@(require_results)
hmac_hex :: proc(h: ^Heap, s, key: string, kind: Digest) -> (res: Value, status: Status) {
	msg := transmute([]u8)s
	kb := transmute([]u8)key
	buf: [MOST_DIGEST]u8
	n: int
	#partial switch kind {
	case .Sha256:
		k0, pad: [64]u8
		if len(kb) > 64 {
			st: Sha256_State
			sha256_init(&st)
			sha256_update(&st, kb)
			sha256_final(&st, k0[:32])
		} else {
			copy(k0[:], kb)
		}
		for i in 0 ..< 64 {
			pad[i] = k0[i] ~ 0x36
		}
		inner: [32]u8
		st: Sha256_State
		sha256_init(&st)
		sha256_update(&st, pad[:])
		sha256_update(&st, msg)
		sha256_final(&st, inner[:])
		for i in 0 ..< 64 {
			pad[i] = k0[i] ~ 0x5C
		}
		sha256_init(&st)
		sha256_update(&st, pad[:])
		sha256_update(&st, inner[:])
		sha256_final(&st, buf[:32])
		n = 32
	case .Sha512:
		k0, pad: [128]u8
		if len(kb) > 128 {
			st: Sha512_State
			sha512_init(&st)
			sha512_update(&st, kb)
			sha512_final(&st, k0[:64])
		} else {
			copy(k0[:], kb)
		}
		for i in 0 ..< 128 {
			pad[i] = k0[i] ~ 0x36
		}
		inner: [64]u8
		st: Sha512_State
		sha512_init(&st)
		sha512_update(&st, pad[:])
		sha512_update(&st, msg)
		sha512_final(&st, inner[:])
		for i in 0 ..< 128 {
			pad[i] = k0[i] ~ 0x5C
		}
		sha512_init(&st)
		sha512_update(&st, pad[:])
		sha512_update(&st, inner[:])
		sha512_final(&st, buf[:64])
		n = 64
	}
	return encode_hex(h, string(buf[:n]))
}

// The IEEE CRC-32 of the bytes of `s`.
crc32 :: proc "contextless" (s: string) -> u32 {
	return hashing.crc32(transmute([]u8)s)
}

// An RFC 9562 identifier from 16 random bytes, version 4, or version 7 when `unix_ms` is not negative, which takes the
// first six bytes for the Unix time in milliseconds.
@(require_results)
uuid_text :: proc(h: ^Heap, random: [16]u8, unix_ms := i64(-1)) -> (res: Value, status: Status) {
	id := random
	version := u8(0x40)
	if unix_ms >= 0 {
		for i in 0 ..< 6 {
			id[i] = u8(u64(unix_ms) >> uint(40 - 8 * i))
		}
		version = 0x70
	}
	id[6] = id[6] & 0x0F | version
	id[8] = id[8] & 0x3F | 0x80
	v, out := make_text(h, 36) or_return
	digits := HEX_DIGITS
	at := 0
	for b, i in id {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			out[at] = '-'
			at += 1
		}
		out[at], out[at + 1] = digits[b >> 4], digits[b & 15]
		at += 2
	}
	return v, .Ok
}

// ---- MD5 (RFC 1321)

@(private = "file")
Md5_State :: struct {
	h:     [4]u32,
	buf:   [64]u8,
	n:     int,
	total: u64,
}

@(private = "file", rodata)
MD5_K := [64]u32 {
	0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
	0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
	0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
	0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
	0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
	0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
	0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
	0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
}

@(private = "file", rodata)
MD5_S := [64]u8 {
	7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
	5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
	4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
	6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

@(private = "file")
md5_init :: proc "contextless" (s: ^Md5_State) {
	s^ = {h = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476}}
}

@(private = "file")
md5_block :: proc "contextless" (s: ^Md5_State, blk: []u8) #no_bounds_check {
	m: [16]u32
	for i in 0 ..< 16 {
		m[i], _ = endian.get_u32(blk[i * 4:], .Little)
	}
	a, b, c, d := s.h[0], s.h[1], s.h[2], s.h[3]
	for i in 0 ..< 64 {
		f, g: u32
		switch {
		case i < 16:
			f, g = (b & c) | ((~b) & d), u32(i)
		case i < 32:
			f, g = (d & b) | ((~d) & c), u32((5 * i + 1) & 15)
		case i < 48:
			f, g = b ~ c ~ d, u32((3 * i + 5) & 15)
		case:
			f, g = c ~ (b | (~d)), u32((7 * i) & 15)
		}
		tmp := d
		d = c
		c = b
		b = b + bits.rotate_left32(a + f + MD5_K[i] + m[g], int(MD5_S[i]))
		a = tmp
	}
	s.h[0] += a
	s.h[1] += b
	s.h[2] += c
	s.h[3] += d
}

@(private = "file")
md5_update :: proc "contextless" (s: ^Md5_State, data: []u8) {
	s.total += u64(len(data))
	p := data
	if s.n > 0 {
		take := min(len(p), 64 - s.n)
		copy(s.buf[s.n:], p[:take])
		s.n += take
		p = p[take:]
		if s.n == 64 {
			md5_block(s, s.buf[:])
			s.n = 0
		}
	}
	for len(p) >= 64 {
		md5_block(s, p[:64])
		p = p[64:]
	}
	if len(p) > 0 {
		copy(s.buf[:], p)
		s.n = len(p)
	}
}

@(private = "file")
md5_final :: proc "contextless" (s: ^Md5_State, out: []u8) {
	s.buf[s.n] = 0x80
	s.n += 1
	if s.n > 56 {
		for i in s.n ..< 64 {
			s.buf[i] = 0
		}
		md5_block(s, s.buf[:])
		s.n = 0
	}
	for i in s.n ..< 56 {
		s.buf[i] = 0
	}
	endian.put_u64(s.buf[56:], .Little, s.total * 8)
	md5_block(s, s.buf[:])
	for i in 0 ..< 4 {
		endian.put_u32(out[i * 4:], .Little, s.h[i])
	}
}

// ---- SHA-1 (FIPS 180-4)

@(private = "file")
Sha1_State :: struct {
	h:     [5]u32,
	buf:   [64]u8,
	n:     int,
	total: u64,
}

@(private = "file")
sha1_init :: proc "contextless" (s: ^Sha1_State) {
	s^ = {h = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0}}
}

@(private = "file")
sha1_block :: proc "contextless" (s: ^Sha1_State, blk: []u8) #no_bounds_check {
	w: [80]u32
	for i in 0 ..< 16 {
		w[i], _ = endian.get_u32(blk[i * 4:], .Big)
	}
	for i in 16 ..< 80 {
		w[i] = bits.rotate_left32(w[i - 3] ~ w[i - 8] ~ w[i - 14] ~ w[i - 16], 1)
	}
	a, b, c, d, e := s.h[0], s.h[1], s.h[2], s.h[3], s.h[4]
	for i in 0 ..< 80 {
		f, k: u32
		switch {
		case i < 20:
			f, k = (b & c) | ((~b) & d), 0x5a827999
		case i < 40:
			f, k = b ~ c ~ d, 0x6ed9eba1
		case i < 60:
			f, k = (b & c) | (b & d) | (c & d), 0x8f1bbcdc
		case:
			f, k = b ~ c ~ d, 0xca62c1d6
		}
		tmp := bits.rotate_left32(a, 5) + f + e + k + w[i]
		e = d
		d = c
		c = bits.rotate_left32(b, 30)
		b = a
		a = tmp
	}
	s.h[0] += a
	s.h[1] += b
	s.h[2] += c
	s.h[3] += d
	s.h[4] += e
}

@(private = "file")
sha1_update :: proc "contextless" (s: ^Sha1_State, data: []u8) {
	s.total += u64(len(data))
	p := data
	if s.n > 0 {
		take := min(len(p), 64 - s.n)
		copy(s.buf[s.n:], p[:take])
		s.n += take
		p = p[take:]
		if s.n == 64 {
			sha1_block(s, s.buf[:])
			s.n = 0
		}
	}
	for len(p) >= 64 {
		sha1_block(s, p[:64])
		p = p[64:]
	}
	if len(p) > 0 {
		copy(s.buf[:], p)
		s.n = len(p)
	}
}

@(private = "file")
sha1_final :: proc "contextless" (s: ^Sha1_State, out: []u8) {
	s.buf[s.n] = 0x80
	s.n += 1
	if s.n > 56 {
		for i in s.n ..< 64 {
			s.buf[i] = 0
		}
		sha1_block(s, s.buf[:])
		s.n = 0
	}
	for i in s.n ..< 56 {
		s.buf[i] = 0
	}
	endian.put_u64(s.buf[56:], .Big, s.total * 8)
	sha1_block(s, s.buf[:])
	for i in 0 ..< 5 {
		endian.put_u32(out[i * 4:], .Big, s.h[i])
	}
}

// ---- SHA-256 (FIPS 180-4)

@(private = "file")
Sha256_State :: struct {
	h:     [8]u32,
	buf:   [64]u8,
	n:     int,
	total: u64,
}

@(private = "file", rodata)
SHA256_K := [64]u32 {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

@(private = "file")
sha256_init :: proc "contextless" (s: ^Sha256_State) {
	s^ = {h = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19}}
}

@(private = "file")
rotr32 :: #force_inline proc "contextless" (x: u32, $k: uint) -> u32 {
	return (x >> k) | (x << (32 - k))
}

@(private = "file")
rotr64 :: #force_inline proc "contextless" (x: u64, $k: uint) -> u64 {
	return (x >> k) | (x << (64 - k))
}

@(private = "file")
sha256_block :: proc "contextless" (s: ^Sha256_State, blk: []u8) #no_bounds_check {
	w: [64]u32
	for i in 0 ..< 16 {
		w[i], _ = endian.get_u32(blk[i * 4:], .Big)
	}
	for i in 16 ..< 64 {
		s0 := rotr32(w[i - 15], 7) ~ rotr32(w[i - 15], 18) ~ (w[i - 15] >> 3)
		s1 := rotr32(w[i - 2], 17) ~ rotr32(w[i - 2], 19) ~ (w[i - 2] >> 10)
		w[i] = w[i - 16] + s0 + w[i - 7] + s1
	}
	a, b, c, d, e, f, g, hh := s.h[0], s.h[1], s.h[2], s.h[3], s.h[4], s.h[5], s.h[6], s.h[7]
	for i in 0 ..< 64 {
		s1 := rotr32(e, 6) ~ rotr32(e, 11) ~ rotr32(e, 25)
		ch := (e & f) ~ ((~e) & g)
		t1 := hh + s1 + ch + SHA256_K[i] + w[i]
		s0 := rotr32(a, 2) ~ rotr32(a, 13) ~ rotr32(a, 22)
		maj := (a & b) ~ (a & c) ~ (b & c)
		t2 := s0 + maj
		hh = g
		g = f
		f = e
		e = d + t1
		d = c
		c = b
		b = a
		a = t1 + t2
	}
	s.h[0] += a
	s.h[1] += b
	s.h[2] += c
	s.h[3] += d
	s.h[4] += e
	s.h[5] += f
	s.h[6] += g
	s.h[7] += hh
}

@(private = "file")
sha256_update :: proc "contextless" (s: ^Sha256_State, data: []u8) {
	s.total += u64(len(data))
	p := data
	if s.n > 0 {
		take := min(len(p), 64 - s.n)
		copy(s.buf[s.n:], p[:take])
		s.n += take
		p = p[take:]
		if s.n == 64 {
			sha256_block(s, s.buf[:])
			s.n = 0
		}
	}
	for len(p) >= 64 {
		sha256_block(s, p[:64])
		p = p[64:]
	}
	if len(p) > 0 {
		copy(s.buf[:], p)
		s.n = len(p)
	}
}

@(private = "file")
sha256_final :: proc "contextless" (s: ^Sha256_State, out: []u8) {
	s.buf[s.n] = 0x80
	s.n += 1
	if s.n > 56 {
		for i in s.n ..< 64 {
			s.buf[i] = 0
		}
		sha256_block(s, s.buf[:])
		s.n = 0
	}
	for i in s.n ..< 56 {
		s.buf[i] = 0
	}
	endian.put_u64(s.buf[56:], .Big, s.total * 8)
	sha256_block(s, s.buf[:])
	for i in 0 ..< 8 {
		endian.put_u32(out[i * 4:], .Big, s.h[i])
	}
}

// ---- SHA-512 (FIPS 180-4)

@(private = "file")
Sha512_State :: struct {
	h:     [8]u64,
	buf:   [128]u8,
	n:     int,
	total: u64,
}

@(private = "file", rodata)
SHA512_K := [80]u64 {
	0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
	0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
	0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
	0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
	0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
	0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
	0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
	0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
	0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
	0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
	0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
	0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
	0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
	0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
	0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
	0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
	0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
	0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
	0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
	0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
}

@(private = "file")
sha512_init :: proc "contextless" (s: ^Sha512_State) {
	s^ = {
		h = {
			0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
			0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
		},
	}
}

@(private = "file")
sha512_block :: proc "contextless" (s: ^Sha512_State, blk: []u8) #no_bounds_check {
	w: [80]u64
	for i in 0 ..< 16 {
		w[i], _ = endian.get_u64(blk[i * 8:], .Big)
	}
	for i in 16 ..< 80 {
		s0 := rotr64(w[i - 15], 1) ~ rotr64(w[i - 15], 8) ~ (w[i - 15] >> 7)
		s1 := rotr64(w[i - 2], 19) ~ rotr64(w[i - 2], 61) ~ (w[i - 2] >> 6)
		w[i] = w[i - 16] + s0 + w[i - 7] + s1
	}
	a, b, c, d, e, f, g, hh := s.h[0], s.h[1], s.h[2], s.h[3], s.h[4], s.h[5], s.h[6], s.h[7]
	for i in 0 ..< 80 {
		s1 := rotr64(e, 14) ~ rotr64(e, 18) ~ rotr64(e, 41)
		ch := (e & f) ~ ((~e) & g)
		t1 := hh + s1 + ch + SHA512_K[i] + w[i]
		s0 := rotr64(a, 28) ~ rotr64(a, 34) ~ rotr64(a, 39)
		maj := (a & b) ~ (a & c) ~ (b & c)
		t2 := s0 + maj
		hh = g
		g = f
		f = e
		e = d + t1
		d = c
		c = b
		b = a
		a = t1 + t2
	}
	s.h[0] += a
	s.h[1] += b
	s.h[2] += c
	s.h[3] += d
	s.h[4] += e
	s.h[5] += f
	s.h[6] += g
	s.h[7] += hh
}

@(private = "file")
sha512_update :: proc "contextless" (s: ^Sha512_State, data: []u8) {
	s.total += u64(len(data))
	p := data
	if s.n > 0 {
		take := min(len(p), 128 - s.n)
		copy(s.buf[s.n:], p[:take])
		s.n += take
		p = p[take:]
		if s.n == 128 {
			sha512_block(s, s.buf[:])
			s.n = 0
		}
	}
	for len(p) >= 128 {
		sha512_block(s, p[:128])
		p = p[128:]
	}
	if len(p) > 0 {
		copy(s.buf[:], p)
		s.n = len(p)
	}
}

@(private = "file")
sha512_final :: proc "contextless" (s: ^Sha512_State, out: []u8) {
	s.buf[s.n] = 0x80
	s.n += 1
	if s.n > 112 {
		for i in s.n ..< 128 {
			s.buf[i] = 0
		}
		sha512_block(s, s.buf[:])
		s.n = 0
	}
	for i in s.n ..< 112 {
		s.buf[i] = 0
	}
	endian.put_u64(s.buf[112:], .Big, s.total >> 61)
	endian.put_u64(s.buf[120:], .Big, s.total << 3)
	sha512_block(s, s.buf[:])
	for i in 0 ..< 8 {
		endian.put_u64(out[i * 8:], .Big, s.h[i])
	}
}
