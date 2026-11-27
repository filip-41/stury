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
		n = hash_oneshot(Sha1_State{h = SHA1_IV}, data, buf[:20], 64, 56, .Big, sha1_block)
	case .Sha256:
		n = hash_oneshot(Sha256_State{h = SHA256_IV}, data, buf[:32], 64, 56, .Big, sha256_block)
	case .Sha512:
		n = hash_oneshot(Sha512_State{h = SHA512_IV}, data, buf[:64], 128, 112, .Big, sha512_block)
	case .Md5:
		n = hash_oneshot(Md5_State{h = MD5_IV}, data, buf[:16], 64, 56, .Little, md5_block)
	}
	return encode_hex(h, string(buf[:n]))
}

// The HMAC (RFC 2104) of the bytes of `s` under the bytes of `key` by `kind`, which is `.Sha256` or `.Sha512`, as hex.
@(require_results)
hmac_hex :: proc(h: ^Heap, s, key: string, kind: Digest) -> (res: Value, status: Status) {
	msg, kb := transmute([]u8)s, transmute([]u8)key
	buf: [MOST_DIGEST]u8
	n: int
	#partial switch kind {
	case .Sha256:
		n = hmac_compute(Sha256_State{h = SHA256_IV}, msg, kb, buf[:32], 64, 56, 32, sha256_block)
	case .Sha512:
		n = hmac_compute(Sha512_State{h = SHA512_IV}, msg, kb, buf[:64], 128, 112, 64, sha512_block)
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

// ---- Shared Merkle-Damgard streaming update, padding, and HMAC

@(private = "file")
hash_oneshot :: proc "contextless" (init: $S, data, out: []u8, $BLOCK, $PAD_END: int, $ORDER: endian.Byte_Order, $compress: proc "contextless" (s: ^S, blk: []u8)) -> int {
	st := init
	digest_update(&st, data, BLOCK, compress)
	digest_final(&st, out, BLOCK, PAD_END, ORDER, compress)
	return len(out)
}

@(private = "file")
hmac_compute :: proc "contextless" (init: $S, msg, kb, out: []u8, $BLOCK, $PAD_END, $DIGEST: int, $compress: proc "contextless" (s: ^S, blk: []u8)) -> int {
	k0, pad: [BLOCK]u8
	if len(kb) > BLOCK {
		_ = hash_oneshot(init, kb, k0[:DIGEST], BLOCK, PAD_END, .Big, compress)
	} else {
		copy(k0[:], kb)
	}
	for i in 0 ..< BLOCK {
		pad[i] = k0[i] ~ 0x36
	}
	inner: [DIGEST]u8
	st := init
	digest_update(&st, pad[:], BLOCK, compress)
	digest_update(&st, msg, BLOCK, compress)
	digest_final(&st, inner[:], BLOCK, PAD_END, .Big, compress)
	for i in 0 ..< BLOCK {
		pad[i] = k0[i] ~ 0x5C
	}
	st = init
	digest_update(&st, pad[:], BLOCK, compress)
	digest_update(&st, inner[:], BLOCK, compress)
	digest_final(&st, out, BLOCK, PAD_END, .Big, compress)
	return DIGEST
}

@(private = "file")
digest_update :: proc "contextless" (s: ^$S, data: []u8, $BLOCK: int, $compress: proc "contextless" (s: ^S, blk: []u8)) {
	s.total += u64(len(data))
	p := data
	if s.n > 0 {
		take := min(len(p), BLOCK - s.n)
		copy(s.buf[s.n:], p[:take])
		s.n += take
		p = p[take:]
		if s.n == BLOCK {
			compress(s, s.buf[:])
			s.n = 0
		}
	}
	for len(p) >= BLOCK {
		compress(s, p[:BLOCK])
		p = p[BLOCK:]
	}
	if len(p) > 0 {
		copy(s.buf[:], p)
		s.n = len(p)
	}
}

@(private = "file")
digest_final :: proc "contextless" (s: ^$S, out: []u8, $BLOCK, $PAD_END: int, $ORDER: endian.Byte_Order, $compress: proc "contextless" (s: ^S, blk: []u8)) {
	s.buf[s.n] = 0x80
	s.n += 1
	if s.n > PAD_END {
		for i in s.n ..< BLOCK {
			s.buf[i] = 0
		}
		compress(s, s.buf[:])
		s.n = 0
	}
	for i in s.n ..< PAD_END {
		s.buf[i] = 0
	}
	when BLOCK == 128 {
		endian.put_u64(s.buf[112:], ORDER, s.total >> 61)
		endian.put_u64(s.buf[120:], ORDER, s.total << 3)
	} else {
		endian.put_u64(s.buf[56:], ORDER, s.total * 8)
	}
	compress(s, s.buf[:])
	when size_of(s.h[0]) == 8 {
		for i in 0 ..< len(s.h) {
			endian.put_u64(out[i * 8:], ORDER, s.h[i])
		}
	} else {
		for i in 0 ..< len(s.h) {
			endian.put_u32(out[i * 4:], ORDER, s.h[i])
		}
	}
}

// ---- Digest states & compression blocks

@(private = "file")
Digest_State :: struct($W: typeid, $H, $B: int) {
	h:     [H]W,
	buf:   [B]u8,
	n:     int,
	total: u64,
}

@(private = "file")
Md5_State :: Digest_State(u32, 4, 64)
@(private = "file")
Sha1_State :: Digest_State(u32, 5, 64)
@(private = "file")
Sha256_State :: Digest_State(u32, 8, 64)
@(private = "file")
Sha512_State :: Digest_State(u64, 8, 128)

@(private = "file")
MD5_IV :: [4]u32{0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476}
@(private = "file")
SHA1_IV :: [5]u32{0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0}
@(private = "file")
SHA256_IV :: [8]u32{0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19}
@(private = "file")
SHA512_IV :: [8]u64{
	0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
	0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
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
MD5_S := [16]u8{7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21}

@(private = "file")
md5_block :: proc "contextless" (s: ^Md5_State, blk: []u8) #no_bounds_check {
	m: [16]u32
	for i in 0 ..< 16 {
		m[i], _ = endian.get_u32(blk[i * 4:], .Little)
	}
	a, b, c, d := s.h[0], s.h[1], s.h[2], s.h[3]
	for i in 0 ..< 64 {
		f, g: u32
		switch i >> 4 {
		case 0:
			f, g = (b & c) | ((~b) & d), u32(i)
		case 1:
			f, g = (d & b) | ((~d) & c), u32((5 * i + 1) & 15)
		case 2:
			f, g = b ~ c ~ d, u32((3 * i + 5) & 15)
		case:
			f, g = c ~ (b | (~d)), u32((7 * i) & 15)
		}
		shift := int(MD5_S[(i >> 4) * 4 + (i & 3)])
		a, b, c, d = d, b + bits.rotate_left32(a + f + MD5_K[i] + m[g], shift), b, c
	}
	s.h[0], s.h[1], s.h[2], s.h[3] = s.h[0] + a, s.h[1] + b, s.h[2] + c, s.h[3] + d
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
		switch i / 20 {
		case 0:
			f, k = (b & c) | ((~b) & d), 0x5a827999
		case 1:
			f, k = b ~ c ~ d, 0x6ed9eba1
		case 2:
			f, k = (b & c) | (b & d) | (c & d), 0x8f1bbcdc
		case:
			f, k = b ~ c ~ d, 0xca62c1d6
		}
		tmp := bits.rotate_left32(a, 5) + f + e + k + w[i]
		a, b, c, d, e = tmp, a, bits.rotate_left32(b, 30), c, d
	}
	s.h[0], s.h[1], s.h[2], s.h[3], s.h[4] = s.h[0] + a, s.h[1] + b, s.h[2] + c, s.h[3] + d, s.h[4] + e
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
rotr :: #force_inline proc "contextless" (x: $W, $k: uint) -> W {
	return (x >> k) | (x << (size_of(W) * 8 - k))
}

// Unified FIPS 180-4 SHA-2 compression block for both SHA-256 (`u32`, 64 rounds) and SHA-512 (`u64`, 80 rounds).
@(private = "file")
sha2_block :: proc "contextless" (
	s: ^$S,
	blk: []u8,
	k_tbl: []$W,
	$ROUNDS: int,
	$W0A, $W0B, $W0S, $W1A, $W1B, $W1S, $E0, $E1, $E2, $A0, $A1, $A2: uint,
) #no_bounds_check {
	w: [ROUNDS]W
	for i in 0 ..< 16 {
		when size_of(W) == 8 {
			w[i], _ = endian.get_u64(blk[i * 8:], .Big)
		} else {
			w[i], _ = endian.get_u32(blk[i * 4:], .Big)
		}
	}
	for i in 16 ..< ROUNDS {
		s0 := rotr(w[i - 15], W0A) ~ rotr(w[i - 15], W0B) ~ (w[i - 15] >> W0S)
		s1 := rotr(w[i - 2], W1A) ~ rotr(w[i - 2], W1B) ~ (w[i - 2] >> W1S)
		w[i] = w[i - 16] + s0 + w[i - 7] + s1
	}
	a, b, c, d, e, f, g, hh := s.h[0], s.h[1], s.h[2], s.h[3], s.h[4], s.h[5], s.h[6], s.h[7]
	for i in 0 ..< ROUNDS {
		s1 := rotr(e, E0) ~ rotr(e, E1) ~ rotr(e, E2)
		t1 := hh + s1 + ((e & f) ~ ((~e) & g)) + k_tbl[i] + w[i]
		s0 := rotr(a, A0) ~ rotr(a, A1) ~ rotr(a, A2)
		t2 := s0 + ((a & b) ~ (a & c) ~ (b & c))
		a, b, c, d, e, f, g, hh = t1 + t2, a, b, c, d + t1, e, f, g
	}
	s.h[0], s.h[1], s.h[2], s.h[3] = s.h[0] + a, s.h[1] + b, s.h[2] + c, s.h[3] + d
	s.h[4], s.h[5], s.h[6], s.h[7] = s.h[4] + e, s.h[5] + f, s.h[6] + g, s.h[7] + hh
}

@(private = "file")
sha256_block :: proc "contextless" (s: ^Sha256_State, blk: []u8) {
	sha2_block(s, blk, SHA256_K[:], 64, 7, 18, 3, 17, 19, 10, 6, 11, 25, 2, 13, 22)
}

@(private = "file")
sha512_block :: proc "contextless" (s: ^Sha512_State, blk: []u8) {
	sha2_block(s, blk, SHA512_K[:], 80, 1, 8, 7, 19, 61, 6, 14, 18, 41, 28, 34, 39)
}
