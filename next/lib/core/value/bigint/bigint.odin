package bigint

import "core:math/big"
import "stury:lib/core/value"

// Exact integers past `i64` for the values of `lib/core/value`, apart from it so that only a caller of this package
// links big integers.

// Sets `out` to the integer `n` is: its bits for `.Int` and `.Uint`, else the decimal digits of its spelling, with a
// leading `-`. `.Invalid_Argument` for a number whose spelling is no decimal integer, as a fraction or an exponent.
@(require_results)
integer_of :: proc(n: value.Number, out: ^big.Int, allocator := context.allocator) -> big.Error {
	#partial switch n.kind {
	case .Int:
		return big.set(out, i64(n.bits), allocator = allocator)
	case .Uint:
		return big.set(out, n.bits, allocator = allocator)
	}
	text := value.number_text(n)
	digits := text[1:] if len(text) > 0 && text[0] == '-' else text
	if len(digits) == 0 {
		return .Invalid_Argument
	}
	for c in transmute([]u8)digits {
		if c < '0' || c > '9' {
			return .Invalid_Argument
		}
	}
	return big.atoi(out, text, allocator = allocator)
}
