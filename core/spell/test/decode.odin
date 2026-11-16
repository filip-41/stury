package spell_tests

import "core:testing"
import spell ".."

// Checks `bytes_equal` on lengths 0 to 40, with the last byte differing and with the second slice a byte shorter.
@(test)
bytes_equal_table :: proc(t: ^testing.T) {
	a, b: [64]u8
	for i in 0 ..< len(a) {
		a[i] = u8(i * 31 + 7)
		b[i] = a[i]
	}
	for n in 0 ..= 40 {
		testing.expectf(t, spell.bytes_equal(a[:n], b[:n]), "length %d: equal", n)
		if n > 0 {
			b[n - 1] = a[n - 1] ~ 0x80
			testing.expectf(t, !spell.bytes_equal(a[:n], b[:n]), "length %d: last byte differs", n)
			b[n - 1] = a[n - 1]
			testing.expectf(t, !spell.bytes_equal(a[:n], b[:n - 1]), "length %d against %d", n, n - 1)
		}
	}
}
