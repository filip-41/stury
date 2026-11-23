package kernel

import "base:intrinsics"
import "core:simd"

// The bytes after an odd run of `escape` bytes. Subtracting each unescaped escape from its own bit moved up one, with
// every odd bit set, borrows through each run, so past a run the result differs from the odd pattern exactly at the
// escapes that open an escape and the bytes they escape. `odd` carries an odd run across blocks: when set, bit 0 is
// escaped unless it is an escape, which then continues the run.
escaped :: #force_inline proc "contextless" (escape: u64, odd: ^u64) -> u64 {
	ODD :: u64(0xAAAA_AAAA_AAAA_AAAA)
	candidates := escape &~ odd^
	opens := ((candidates << 1 | ODD) - candidates) ~ ODD
	after := opens ~ (escape | odd^)
	odd^ = (opens & escape) >> 63
	return after &~ escape
}

// Bit i is set when an odd number of bits of `x` at or below i are. From a block's quote bits, it marks each quoted
// run, opening quote included and closing quote excluded. The floor tier shifts, since x86-64-v2 has no carry-less
// multiply.
prefix_xor :: #force_inline proc "contextless" ($T: Tier, x: u64) -> u64 {
	when T != Tier(0) {
		return clmul_prefix_xor(x)
	} else when PMULL {
		return pmull_prefix_xor(x)
	} else {
		x := x
		x ~= x << 1
		x ~= x << 2
		x ~= x << 4
		x ~= x << 8
		x ~= x << 16
		x ~= x << 32
		return x
	}
}

// The index of the first byte `c` in `src`, or -1.
index_byte :: #force_inline proc "contextless" (src: []u8, c: u8) -> int {
	return scan(src, c, nil, .Forward)
}

// The index of the last byte `c` in `src`, or -1.
last_index_byte :: #force_inline proc "contextless" (src: []u8, c: u8) -> int {
	return scan(src, c, nil, .Back)
}

count_byte :: proc "contextless" (src: []u8, c: u8) -> int {
	return scan(src, c, nil, .Count)
}

// The bytes of `src` that are not continuation bytes (10xxxxxx): its code point count when it is UTF-8.
count_chars :: proc "contextless" (src: []u8) -> int {
	return len(src) - scan(src, 0, nil, .Continuations)
}

// The bytes of `src` equal to `c`, or with `CONT` the continuation bytes, counted into byte lanes. A lane overflows
// after 255 blocks, so the lanes are summed every 255.
@(private)
count_lanes :: #force_inline proc "contextless" ($T: Tier, src: []u8, $CONT: bool, c: u8) -> (n: int) {
	N :: VECTOR_BYTES[T]
	U :: #simd[N]u8
	p := raw_data(src)
	at := 0
	for whole := len(src) &~ 63; at < whole; {
		acc: [64 / N]U
		for end := at + min(64 * 255, whole - at); at < end; at += 64 {
			w := transmute([64 / N]U)load(p[at:])
			#unroll for k in 0 ..< 64 / N {
				acc[k] -= hits(w[k], CONT, c)
			}
		}
		for v in acc {
			n += int(simd.reduce_add_ordered(cast(#simd[N]u16)v))
		}
	}
	// Fewer than 64 bytes are left: 16 at a time into one counter, then the last ones in one load where it stays in the
	// page.
	acc: V
	for ; at + 16 <= len(src); at += 16 {
		acc -= hits(load16(p[at:]), CONT, c)
	}
	if at < len(src) {
		if v, live, ok := head16(p[at:], len(src) - at); ok {
			acc -= simd.bit_and(hits(v, CONT, c), live)
			at = len(src)
		}
	}
	n += int(simd.reduce_add_ordered(cast(#simd[16]u16)acc))
	for ; at < len(src); at += 1 {
		n += int(CONT && p[at] & 0xC0 == 0x80 || !CONT && p[at] == c)
	}
	return
}

// 0xFF in each lane of `v` equal to `c`, or with `CONT` holding a continuation byte.
@(private)
hits :: #force_inline proc "contextless" (v: #simd[$N]u8, $CONT: bool, c: u8) -> #simd[N]u8 {
	U :: #simd[N]u8
	I :: #simd[N]i8
	when CONT {
		return simd.lanes_lt(transmute(I)v, I(-64))
	} else {
		return simd.lanes_eq(v, U(c))
	}
}

is_ws :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\n' || c == '\r' || c == '\t'
}

// White space to every markup format: `is_ws` and form feed.
is_markup_ws :: #force_inline proc "contextless" (c: u8) -> bool {
	return is_ws(c) || c == '\f'
}

// The first byte at or past `p` that is not `is_ws`, or `end`. Up to four bytes one at a time, then 64-byte blocks,
// then the rest. Inlined, since a call would make the walk's states save registers.
skip_ws :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 {
	q := p
	for _ in 0 ..< 4 {
		if q >= end || !is_ws(q[0]) {
			return q
		}
		q = q[1:]
	}
	for intrinsics.ptr_sub(end, q) >= 64 {
		other := ws_other(load(q))
		if !all_zero(transmute(W)other) {
			return q[intrinsics.count_trailing_zeros(pack(transmute(Block)simd.lanes_ne(transmute(W)other, W(0)))):]
		}
		q = q[64:]
	}
	for q < end && is_ws(q[0]) {
		q = q[1:]
	}
	return q
}

@(private, rodata)
WS_BY_LOW := V{0 = ' ', 9 = '\t', 10 = '\n', 13 = '\r'}

// Zero in each lane of `b` that is `is_ws`, by the white space byte of its low nibble, which no two share.
@(private)
ws_other :: #force_inline proc "contextless" (b: Block) -> Block {
	r: Block
	#unroll for i in 0 ..< 4 {
		// amd64 omits the mask `lookup` needs, since `pshufb` reads only the low nibble, and gives 0 for a byte past
		// 0x7F, which no white space byte matches.
		index := b[i] if ODIN_ARCH == .amd64 else simd.bit_and(b[i], V(0x0f))
		r[i] = simd.bit_xor(lookup(Tier(0), WS_BY_LOW, index), b[i])
	}
	return r
}

// Settings and state of a scan for quoted runs and brackets. A quoted run goes from `quote` to the next `quote` no
// `escape` escapes (0 for none). `sep` is never 0 and `quote` is 0 only for `quote_cut`, since the zeros that pad the
// last block would match them. With `nest`, `[` and `{` outside quoted runs open a level and `]` and `}` close one.
//
// After `quote_run`, index 0 of `depth` and `low` is for a stretch that starts outside a quoted run and 1 for one that
// starts inside: `depth` is the change in level, `low` the lowest level reached from 0. `quoted` says a stretch
// started outside ends inside a quoted run, so one started inside ends outside.
Quotes :: struct {
	quote, escape, sep: u8,
	nest:               bool,
	quoted:             bool, // inside a quoted run
	odd:                u64, // an odd run of escapes ends just before
	want:               int, // `quote_cut`'s level
	depth, low:         [2]int,
}

// Reads `src` as a stretch of text into `s`, which holds only `quote`, `escape`, `nest` and `odd`, with `quoted`
// false.
quote_run :: proc "contextless" (src: []u8, s: ^Quotes) {
	scan(src, 0, s, .Run)
}

// The index of the first `sep` outside quoted runs at level `want`, from state `s` at `src[0]`, or -1 when there is
// none or the level falls below `want` first. With `quote` 0 it is the first `sep`.
quote_cut :: proc "contextless" (src: []u8, s: Quotes) -> int {
	s := s
	if s.quote == 0 {
		return scan(src, s.sep, nil, .Forward)
	}
	return scan(src, s.sep, &s, .Cut)
}

// The lower of `low` and the lowest level a block's closes bring `depth` to, counting the opens before each close.
depth_low :: #force_inline proc "contextless" (low, depth: int, open, close: u64) -> int {
	low := low
	if depth - int(intrinsics.count_ones(close)) >= low {
		return low
	}
	// The closes come in order, so the k-th one has brought the level down by k.
	level := depth
	for m := close; m != 0; m &= m - 1 {
		level -= 1
		low = min(low, level + int(intrinsics.count_ones(open & (m ~ (m - 1)))))
	}
	return low
}

// The loops `scan` builds once per tier.
@(private)
Scan_Op :: enum u8 {
	Forward,
	Back,
	Count,
	Continuations,
	Utf8,
	Run,
	Cut,
}

// A padded last block's zeros are no quote, escape, separator or bracket.
@(private)
scan_op :: #force_inline proc "contextless" ($T: Tier, src: []u8, c: u8, s: ^Quotes, $OP: Scan_Op) -> int {
	when OP <= .Back {
		return scan_loop(src, c, OP == .Back)
	} else when OP == .Count {
		return count_lanes(T, src, false, c)
	} else when OP == .Continuations {
		return count_lanes(T, src, true, 0)
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
			when OP == .Run {
				if s.nest {
					m := pack_n([2]Block{either(eq(b, '['), eq(b, '{')), either(eq(b, ']'), eq(b, '}'))})
					#unroll for g in 0 ..< 2 {
						out := inside if g == 1 else ~inside
						s.low[g] = depth_low(s.low[g], s.depth[g], m[0] & out, m[1] & out)
						s.depth[g] += int(intrinsics.count_ones(m[0] & out)) - int(intrinsics.count_ones(m[1] & out))
					}
				}
			} else {
				if !s.nest {
					if sep := pack(eq(b, s.sep)) &~ inside; sep != 0 {
						return lo + int(intrinsics.count_trailing_zeros(sep))
					}
					continue
				}
				m := pack_n([3]Block{eq(b, s.sep), either(eq(b, '['), eq(b, '{')), either(eq(b, ']'), eq(b, '}'))})
				sep, open, close := m[0] &~ inside, m[1] &~ inside, m[2] &~ inside
				// A block whose closes cannot bring the level to `want` holds no cut. `closes` counts the closes before
				// `r`'s lowest bit, as they come in order.
				closes := 0
				for r := sep | close if s.depth[0] - int(intrinsics.count_ones(close)) <= s.want else 0; r != 0; r &= r - 1 {
					first := r & -r
					d := s.depth[0] + int(intrinsics.count_ones(open & (first - 1))) - closes
					if close & first != 0 {
						if d <= s.want {
							return -1
						}
						closes += 1
					} else if d == s.want {
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

@(private)
scan_loop :: #force_inline proc "contextless" (src: []u8, c: u8, $BACK: bool) -> int {
	p := raw_data(src)
	i := len(src)
	when BACK {
		for i >= 64 {
			i -= 64
			if e := eq(load(p[i:]), c); any_lane(e) {
				return i + 63 - int(intrinsics.count_leading_zeros(pack(e)))
			}
		}
		for i >= 16 {
			i -= 16
			if e := simd.lanes_eq(load16(p[i:]), V(c)); any_lane16(e) {
				return i + int(last_lane16(e))
			}
		}
		if i == 0 {
			return -1
		}
		if v, live, ok := head16(p, i); ok {
			e := simd.bit_and(simd.lanes_eq(v, V(c)), live)
			return int(last_lane16(e)) if any_lane16(e) else -1
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
			if e := eq(load(p[i:]), c); any_lane(e) {
				return i + int(intrinsics.count_trailing_zeros(pack(e)))
			}
		}
		for ; i + 16 <= n; i += 16 {
			if e := simd.lanes_eq(load16(p[i:]), V(c)); any_lane16(e) {
				return i + int(first_lane16(e))
			}
		}
		if i == n {
			return -1
		}
		if v, live, ok := head16(p[i:], n - i); ok {
			e := simd.bit_and(simd.lanes_eq(v, V(c)), live)
			return i + int(first_lane16(e)) if any_lane16(e) else -1
		}
		for ; i < n; i += 1 {
			if p[i] == c {
				return i
			}
		}
	}
	return -1
}
