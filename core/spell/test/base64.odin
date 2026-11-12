package spell_tests

import "core:testing"
import spell ".."

// RFC 4648 section 10's vectors, in both directions.
BASE64_VECTORS :: [?][2]string {
	{"", ""},
	{"f", "Zg=="},
	{"fo", "Zm8="},
	{"foo", "Zm9v"},
	{"foob", "Zm9vYg=="},
	{"fooba", "Zm9vYmE="},
	{"foobar", "Zm9vYmFy"},
}

@(test)
base64_rfc_vectors :: proc(t: ^testing.T) {
	for v in BASE64_VECTORS {
		raw := transmute([]u8)v[0]
		testing.expect_value(t, spell.base64_len(len(raw)), len(v[1]))
		text: [16]u8
		n := spell.base64_put(text[:], raw)
		testing.expect_value(t, string(text[:n]), v[1])

		room: [16]u8
		decoded, ok := spell.base64_decode(room[:], transmute([]u8)v[1])
		testing.expectf(t, ok, "%q refused", v[1])
		testing.expect_value(t, string(decoded), v[0])
	}
}

// Every length up to 300 bytes round trips.
@(test)
base64_round_trip :: proc(t: ^testing.T) {
	raw: [300]u8
	for i in 0 ..< len(raw) {
		raw[i] = u8(i * 7 + 3)
	}
	for n in 0 ..= len(raw) {
		text: [400]u8
		w := spell.base64_put(text[:], raw[:n])
		testing.expect_value(t, w, spell.base64_len(n))
		room: [300]u8
		decoded, ok := spell.base64_decode(room[:], text[:w])
		testing.expectf(t, ok && string(decoded) == string(raw[:n]), "length %d did not round trip", n)
	}
}

// A text that is not the one canonical spelling of some byte string is refused.
@(test)
base64_refuses_other_text :: proc(t: ^testing.T) {
	for text in ([?]string {
			"Zg", // unpadded
			"Zg=", // short padding
			"Zg===", // length not a multiple of 4
			"Z===", // three padding bytes
			"Zg=a", // padding not last
			"=g==", // padding first
			"Zm9v\n", // whitespace
			"Zm9 v", // whitespace inside
			"Zm-_", // the URL alphabet
			"Zh==", // trailing bits not zero
			"Zm9=", // trailing bits not zero
			"Zm\x009", // a byte outside the alphabet
		}) {
		room: [16]u8
		_, ok := spell.base64_decode(room[:], transmute([]u8)text)
		testing.expectf(t, !ok, "%q accepted", text)
	}
}
