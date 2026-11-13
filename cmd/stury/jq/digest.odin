package jq

// Builtins beyond jq that turn a string's UTF-8 bytes into other text: digests, HMACs, CRC-32, hex, base64url, and
// the random identifiers.

import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/base64"
import hashing "core:hash"
import "core:strings"
import "core:time"
import "../../../core/spell"

@(private = "file")
HEX_DIGITS :: "0123456789abcdef"

@(private = "file")
hex_text :: proc(bytes: []byte) -> string {
	digits := HEX_DIGITS
	b := make([]byte, len(bytes) * 2)
	for c, i in bytes {
		b[i * 2], b[i * 2 + 1] = digits[c >> 4], digits[c & 15]
	}
	return string(b)
}

@(private = "file")
must_be_string :: proc(ip: ^Interp, name: string, v: Value) -> (string, Signal) {
	s, ok := string_of(v)
	if !ok {
		return "", fail(ip, "%s input must be a string", name)
	}
	return s, .Go
}

// sha1, sha256, sha512 and md5: the digest of the input's bytes, as lowercase hex.
fn_digest :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (result: Value, sig: Signal) {
	s := must_be_string(ip, name, v) or_return
	algorithm: hash.Algorithm
	switch name {
	case "sha1":
		algorithm = .Insecure_SHA1
	case "sha256":
		algorithm = .SHA256
	case "sha512":
		algorithm = .SHA512
	case:
		algorithm = .Insecure_MD5
	}
	return hex_text(hash.hash_string(algorithm, s, context.temp_allocator)), .Go
}

// hmac_sha256(key) and hmac_sha512(key): the HMAC of the input's bytes under the key's, as lowercase hex.
fn_hmac :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (result: Value, sig: Signal) {
	s := must_be_string(ip, name, v) or_return
	key, key_ok := string_of(args[0])
	if !key_ok {
		return nil, fail(ip, "%s key must be a string", name)
	}
	algorithm := hash.Algorithm.SHA256 if name == "hmac_sha256" else .SHA512
	tag := make([]byte, hash.DIGEST_SIZES[algorithm], context.temp_allocator)
	hmac.sum(algorithm, tag, transmute([]byte)s, transmute([]byte)key)
	return hex_text(tag), .Go
}

// crc32: the IEEE CRC-32 of the input's bytes, as a number.
fn_crc32 :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (result: Value, sig: Signal) {
	s := must_be_string(ip, name, v) or_return
	return num(f64(hashing.crc32(transmute([]byte)s))), .Go
}

// hex_encode, hex_decode, base64url_encode and base64url_decode. A decoded text that is not UTF-8 is read as
// `@base64d` reads it, each bad sequence one U+FFFD.
fn_text_encoding :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (result: Value, sig: Signal) {
	s := must_be_string(ip, name, v) or_return
	switch name {
	case "hex_encode":
		return hex_text(transmute([]byte)s), .Go
	case "base64url_encode":
		return base64.encode(transmute([]byte)s, base64.ENC_URL_TABLE, options = {.No_Padding}), .Go
	case "base64url_decode":
		return decode_base64(ip, s, BASE64_URL)
	}
	if len(s) % 2 != 0 {
		return nil, fail(ip, "string (%s) is not valid hex data", brief(ip, s))
	}
	b := make([]byte, len(s) / 2)
	for i in 0 ..< len(b) {
		hi, lo := spell.HEX_NIBBLE[s[i * 2]], spell.HEX_NIBBLE[s[i * 2 + 1]]
		if hi | lo > 15 {
			return nil, fail(ip, "string (%s) is not valid hex data", brief(ip, s))
		}
		b[i] = hi << 4 | lo
	}
	return valid_utf8(string(b)), .Go
}

// uuid_v4 and uuid_v7 (RFC 9562): a new identifier per call, from the system's random source. A version 7 one starts
// with the Unix time in milliseconds.
fn_uuid :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	id: [16]byte
	crypto.rand_bytes(id[:])
	version: byte = 4
	if name == "uuid_v7" {
		version = 7
		ms := u64(time.time_to_unix_nano(time.now()) / 1_000_000)
		for i in 0 ..< 6 {
			id[i] = byte(ms >> uint(40 - 8 * i))
		}
	}
	id[6] = version << 4 | id[6] & 0x0F
	id[8] = 0x80 | id[8] & 0x3F
	text := hex_text(id[:])
	return strings.join({text[0:8], text[8:12], text[12:16], text[16:20], text[20:32]}, "-"), .Go
}
