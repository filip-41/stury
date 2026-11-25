package query

import "core:crypto/hash"
import "core:crypto/hmac"
import hashing "core:hash"

// Digests of a string's bytes, as lowercase hex, and the identifiers built from random bytes.

Digest :: enum u8 {
	Sha1,
	Sha256,
	Sha512,
	Md5,
}

@(private, rodata)
DIGEST_ALGORITHM := [Digest]hash.Algorithm {
	.Sha1   = .Insecure_SHA1,
	.Sha256 = .SHA256,
	.Sha512 = .SHA512,
	.Md5    = .Insecure_MD5,
}

// The widest digest, SHA-512's.
@(private)
MOST_DIGEST :: 64

// The digest of the bytes of `s` by `kind`, as hex.
@(require_results)
digest_hex :: proc(h: ^Heap, s: string, kind: Digest) -> (res: Value, status: Status) {
	buf: [MOST_DIGEST]u8
	sum := hash.hash_string_to_buffer(DIGEST_ALGORITHM[kind], s, buf[:])
	return encode_hex(h, string(sum))
}

// The HMAC (RFC 2104) of the bytes of `s` under the bytes of `key` by `kind`, which is `.Sha256` or `.Sha512`, as hex.
@(require_results)
hmac_hex :: proc(h: ^Heap, s, key: string, kind: Digest) -> (res: Value, status: Status) {
	algorithm := DIGEST_ALGORITHM[kind]
	buf: [MOST_DIGEST]u8
	tag := buf[:hash.DIGEST_SIZES[algorithm]]
	hmac.sum(algorithm, tag, transmute([]u8)s, transmute([]u8)key)
	return encode_hex(h, string(tag))
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
