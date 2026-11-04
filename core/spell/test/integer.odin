package spell_tests

import "core:strconv"
import "core:testing"
import spell ".."

// Checks `u` and the signed values it stands for against `strconv`'s digits, with canaries past `INT_ROOM`.
check_integer :: proc(t: ^testing.T, u: u64) {
	want: [24]u8
	buf: [spell.INT_ROOM + 16]u8
	for &b in buf {
		b = CANARY
	}
	n := spell.u64_text(raw_data(buf[:]), u)
	testing.expectf(t, string(buf[:n]) == strconv.write_uint(want[:], u, 10), "u64 %d wrote %q", u, string(buf[:n]))
	for b in buf[spell.INT_ROOM:] {
		testing.expect_value(t, b, CANARY)
	}

	v := i64(u)
	for &b in buf {
		b = CANARY
	}
	n = spell.i64_text(raw_data(buf[:]), v)
	testing.expectf(t, string(buf[:n]) == strconv.write_int(want[:], v, 10), "i64 %d wrote %q", v, string(buf[:n]))
	for b in buf[spell.INT_ROOM:] {
		testing.expect_value(t, b, CANARY)
	}
}

@(test)
integer_boundaries :: proc(t: ^testing.T) {
	for u in ([?]u64{0, 1, 9, 10, 99, 100, max(u64), u64(max(i64)), u64(1) << 63, u64(1) << 63 + 1}) {
		check_integer(t, u)
	}
	power := u64(1)
	for _ in 0 ..< 20 {
		check_integer(t, power - 1)
		check_integer(t, power)
		check_integer(t, power + 1)
		check_integer(t, power * 5)
		if power > max(u64) / 10 {
			break
		}
		power *= 10
	}
	for k in 0 ..< 64 {
		bits := u64(1) << u64(k)
		check_integer(t, bits - 1)
		check_integer(t, bits)
		check_integer(t, bits + 1)
	}
}

@(test)
integer_every_length :: proc(t: ^testing.T) {
	state := u64(6)
	for digits in 1 ..= 20 {
		high := u64(1)
		for _ in 1 ..< digits {
			high *= 10
		}
		for _ in 0 ..< ROUNDS / 20 {
			check_integer(t, high + splitmix(&state) % (high * 9 if digits < 20 else max(u64) - high))
		}
	}
}

@(test)
integer_random_bits :: proc(t: ^testing.T) {
	state := u64(7)
	for _ in 0 ..< ROUNDS {
		check_integer(t, splitmix(&state))
	}
}
