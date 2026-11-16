package kernel

import "base:intrinsics"
import "core:simd"

// Returns a mask of the bytes after an odd run of escape bytes. Each escape that `*odd` does not escape (bit 0 only)
// is a candidate, and subtracting the candidates from their own bits moved up one, with every odd bit set, borrows
// through each run: past a run the result's bit differs from the odd pattern exactly at the escape bytes that open an
// escape and at the byte each escapes. When `*odd` is set, bit 0 continues the previous run and is escaped if it is
// not an escape. On return `*odd` says whether this block ends in a run of odd length.
escaped :: #force_inline proc "contextless" (escape: u64, odd: ^u64) -> u64 {
	ODD :: u64(0xAAAA_AAAA_AAAA_AAAA)
	candidates := escape &~ odd^
	opens := ((candidates << 1 | ODD) - candidates) ~ ODD
	after := opens ~ (escape | odd^)
	odd^ = (opens & escape) >> 63
	return after &~ escape
}

// Returns a mask with bit i set when an odd number of bits of `x` at or below i are set. With a block's quote bits
// as `x`, the set bits mark the bytes from each opening quote to its closing quote, excluding the close. The lowest
// tier shifts, since x86-64-v2 has no carry-less multiply, and NEON takes each shift as an operand of its XOR.
prefix_xor :: #force_inline proc "contextless" ($T: Tier, x: u64) -> u64 {
	when T == Tier(0) {
		x := x
		x ~= x << 1
		x ~= x << 2
		x ~= x << 4
		x ~= x << 8
		x ~= x << 16
		x ~= x << 32
		return x
	} else {
		return clmul_prefix_xor(x)
	}
}

// Returns the index of the first byte `c` in `src`, or -1. Reads 64 bytes at a time with the CPU's tier.
index_byte :: #force_inline proc "contextless" (src: []u8, c: u8) -> int {
	return scan(src, c, nil, .Forward)
}

// Returns the index of the last byte `c` in `src`, or -1. Reads 64 bytes at a time back from the end.
last_index_byte :: #force_inline proc "contextless" (src: []u8, c: u8) -> int {
	return scan(src, c, nil, .Back)
}

// Returns the number of bytes `c` in `src`.
count_byte :: proc "contextless" (src: []u8, c: u8) -> int {
	return count_lanes(src, false, c)
}

// Returns the number of bytes of `src` that are not continuation bytes (10xxxxxx), which is its number of code points
// when it is UTF-8.
count_chars :: proc "contextless" (src: []u8) -> int {
	return len(src) - count_lanes(src, true, 0)
}

// Counts the bytes of `src` that equal `c`, or with `CONT` the continuation bytes, 64 at a time into byte counters.
// A counter takes 255 blocks before it can overflow, so the counters are summed after each 255.
@(private)
count_lanes :: #force_inline proc "contextless" (src: []u8, $CONT: bool, c: u8) -> (n: int) {
	p := raw_data(src)
	at := 0
	for whole := len(src) &~ 63; at < whole; {
		acc: Block
		for end := min(at + 64 * 255, whole); at < end; at += 64 {
			b := load(p[at:])
			#unroll for k in 0 ..< 4 {
				when CONT {
					acc[k] -= simd.lanes_lt(transmute(#simd[16]i8)b[k], (#simd[16]i8)(-64))
				} else {
					acc[k] -= simd.lanes_eq(b[k], V(c))
				}
			}
		}
		for v in acc {
			for x in transmute([16]u8)v {
				n += int(x)
			}
		}
	}
	for ; at < len(src); at += 1 {
		n += int(CONT && p[at] & 0xC0 == 0x80 || !CONT && p[at] == c)
	}
	return
}

// Whether `c` is a space, tab, CR or LF.
is_ws :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\n' || c == '\r' || c == '\t'
}

// Whether `c` is white space to every markup format: space, tab, CR, LF or form feed.
is_markup_ws :: #force_inline proc "contextless" (c: u8) -> bool {
	return is_ws(c) || c == '\f'
}

// Returns the first byte at or past `p` that is no space, tab, CR or LF, or `end`. Reads up to four bytes one at a
// time, then 64-byte blocks, then the remaining bytes one at a time. Inlined into the states that skip whitespace,
// which would otherwise save registers for a call.
skip_ws :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 {
	q := p
	for _ in 0 ..< 4 {
		if q >= end || !is_ws(q[0]) {
			return q
		}
		q = q[1:]
	}
	for intrinsics.ptr_sub(end, q) >= 64 {
		b := load(q)
		ws := pack(either(either(eq(b, ' '), eq(b, '\n')), either(eq(b, '\t'), eq(b, '\r'))))
		if ws != max(u64) {
			return q[intrinsics.count_trailing_zeros(~ws):]
		}
		q = q[64:]
	}
	for q < end && is_ws(q[0]) {
		q = q[1:]
	}
	return q
}

// The settings and state of a scan of quoted runs and brackets. A quoted run goes from a `quote` byte to the next
// one no `escape` byte escapes, 0 for no escape. `sep` is not 0, and `quote` is 0 only for `quote_cut`, since the
// zeros that pad the last block would match them. With `nest`, `[` and `{` outside quoted runs open a level and `]`
// and `}` close one. At a byte, `odd` says an odd run of escapes ends just before it, `quoted` that it is in a quoted
// run, and `depth[0]` is its level, far below `want` once the level fell below `want` before it.
//
// After `quote_run` over a stretch from `odd`, index 0 is for a start outside a quoted run and 1 for a start inside
// one: `depth` holds the change in level and `low` the lowest level from 0. `quoted` says the stretch ends in a quoted
// run from a start outside one, and so ends outside from a start inside one.
Quotes :: struct {
	quote, escape, sep: u8,
	nest, quoted:       bool,
	odd:                u64,
	want:               int,
	depth, low:         [2]int,
}

// Reads `src` as a stretch of text into `s`, which holds only `quote`, `escape`, `nest` and `odd`, and `quoted` false.
quote_run :: proc "contextless" (src: []u8, s: ^Quotes) {
	scan(src, 0, s, .Run)
}

// Returns the index of the first `sep` of `src` outside quoted runs at level `want`, with `s` the state at
// `src[0]`, or -1 when there is none or the level falls below `want` first. With `quote` 0 there are no quoted runs
// or levels, and it returns the first `sep`.
quote_cut :: proc "contextless" (src: []u8, s: Quotes) -> int {
	s := s
	if s.quote == 0 {
		return scan(src, s.sep, nil, .Forward)
	}
	return scan(src, s.sep, &s, .Cut)
}

// Returns the lower of `low` and the lowest level the closes of a block bring `depth` to, counting the opens before
// each close.
depth_low :: #force_inline proc "contextless" (low, depth: int, open, close: u64) -> int {
	low := low
	if depth - int(intrinsics.count_ones(close)) >= low {
		return low
	}
	for m := close; m != 0; m &= m - 1 {
		through := (m & -m) << 1 - 1
		low = min(low, depth + int(intrinsics.count_ones(open & through)) - int(intrinsics.count_ones(close & through)))
	}
	return low
}

@(private)
Scan_Op :: enum u8 {
	Forward,
	Back,
	Utf8,
	Run,
	Cut,
}

// The loops `scan` builds once per tier: `index_byte` and `last_index_byte` for `c`, `utf8_valid`, then `quote_run`
// and `quote_cut`.
// The zeros of a padded last block are no quote, escape, separator or bracket.
@(private)
scan_op :: #force_inline proc "contextless" ($T: Tier, src: []u8, c: u8, s: ^Quotes, $OP: Scan_Op) -> int {
	when OP <= .Back {
		return scan_loop(src, c, OP == .Back)
	} else when OP == .Utf8 {
		return int(utf8_blocks(T, src))
	} else {
		inq := ~u64(0) if s.quoted else 0
		for lo := 0; lo < len(src); lo += 64 {
			b := load_block(T, src, lo)
			q := pack(eq(b, s.quote))
			if s.escape != 0 {
				e := escaped(pack(eq(b, s.escape)), &s.odd)
				// A run that ends before a padded block's end escapes the first pad byte.
				if n := len(src) - lo; n < 64 {
					s.odd = e >> uint(n) & 1
				}
				q &~= e
			}
			inside := prefix_xor(T, q) ~ inq
			inq = u64(i64(inside) >> 63)
			m := pack_n([3]Block{eq(b, s.sep), either(eq(b, '['), eq(b, '{')), either(eq(b, ']'), eq(b, '}'))})
			when OP == .Run {
				if s.nest {
					#unroll for g in 0 ..< 2 {
						out := inside if g == 1 else ~inside
						s.low[g] = depth_low(s.low[g], s.depth[g], m[1] & out, m[2] & out)
						s.depth[g] += int(intrinsics.count_ones(m[1] & out)) - int(intrinsics.count_ones(m[2] & out))
					}
				}
			} else {
				sep, open, close := m[0] &~ inside, m[1] &~ inside, m[2] &~ inside
				if !s.nest {
					if sep != 0 {
						return lo + int(intrinsics.count_trailing_zeros(sep))
					}
					continue
				}
				for r := sep | close; r != 0; r &= r - 1 {
					before := (r & -r) - 1
					d := s.depth[0] + int(intrinsics.count_ones(open & before)) - int(intrinsics.count_ones(close & before))
					if close & r & -r != 0 && d <= s.want {
						return -1
					}
					if sep & r & -r != 0 && d == s.want {
						return lo + int(intrinsics.count_trailing_zeros(r))
					}
				}
				s.depth[0] += int(intrinsics.count_ones(open)) - int(intrinsics.count_ones(close))
			}
		}
		s.quoted = inq != 0
		return -1
	}
}

// The loop of `index_byte` and `last_index_byte`.
@(private)
scan_loop :: #force_inline proc "contextless" (src: []u8, c: u8, $BACK: bool) -> int {
	p := raw_data(src)
	i := len(src)
	when BACK {
		for i >= 64 {
			i -= 64
			if m := pack(eq(load(p[i:]), c)); m != 0 {
				return i + 63 - int(intrinsics.count_leading_zeros(m))
			}
		}
		for i > 0 {
			i -= 1
			if p[i] == c {
				return i
			}
		}
	} else {
		n := i
		for i = 0; i + 64 <= n; i += 64 {
			if m := pack(eq(load(p[i:]), c)); m != 0 {
				return i + int(intrinsics.count_trailing_zeros(m))
			}
		}
		for ; i < n; i += 1 {
			if p[i] == c {
				return i
			}
		}
	}
	return -1
}

