package jq

// Builtins beyond jq that turn a string's UTF-8 bytes into other text: digests, HMACs, CRC-32, hex, base64url, and
// the random identifiers.

import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/uuid"
import hashing "core:hash"

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
	return string(hex.encode(hash.hash_string(algorithm, s, context.temp_allocator))), .Go
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
	return string(hex.encode(tag)), .Go
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
		return string(hex.encode(transmute([]byte)s)), .Go
	case "base64url_encode":
		return base64.encode(transmute([]byte)s, base64.ENC_URL_TABLE, options = {.No_Padding}), .Go
	case "base64url_decode":
		return decode_base64(ip, s, BASE64_URL)
	}
	b, ok := hex.decode(transmute([]byte)s)
	if !ok {
		return nil, fail(ip, "string (%s) is not valid hex data", brief(ip, s))
	}
	return valid_utf8(string(b)), .Go
}

// uuid_v4 and uuid_v7 (RFC 9562): a new identifier per call, from the system's random source. A version 7 one starts
// with the Unix time in milliseconds.
fn_uuid :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	context.random_generator = crypto.random_generator()
	return uuid.to_string(uuid.generate_v7() if name == "uuid_v7" else uuid.generate_v4()), .Go
}
