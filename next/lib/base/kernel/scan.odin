// `simd` is unused on scalar WebAssembly (`SCALAR_WASM`), where scans run byte loops.
#+vet !unused-imports
package kernel

import "base:intrinsics"
import "core:simd"

@(private = "file")
SCALAR_WASM :: IS_WASM && !intrinsics.has_target_feature("simd128")

// The bytes after an odd run of `escape` bytes. Subtracting each unescaped escape from its own bit moved up one, with
// every odd bit set, borrows through each run, so past a run the result differs from the odd pattern exactly at the
// escapes that open an escape and the bytes they escape. `odd^` must be 0 or 1 and carries an odd run across blocks:
// when 1, bit 0 is escaped unless it is an escape, which then continues the run.
@(require_results)
escaped :: #force_inline proc "contextless" (escape: u64, odd: ^u64) -> u64 {
	ODD :: u64(0xAAAA_AAAA_AAAA_AAAA)
	candidates := escape &~ odd^
	opens := ((candidates << 1 | ODD) - candidates) ~ ODD
	after := opens ~ (escape | odd^)
	odd^ = (opens & escape) >> 63
	return after &~ escape
}

// Bit i is set when an odd number of bits of `x` at or below i are. From a block's quote bits, it marks each quoted
// run, opening quote included and closing quote excluded. It is one carry-less multiply on x86 tiers above the floor,
// and on a target with `PMULL`. Otherwise it shifts, as x86-64-v2 has no carry-less multiply. Callers must carry
// `@(enable_target_feature = FEATURES[T])` so `clmul_prefix_xor` / `pmull_prefix_xor` inline.
@(require_results)
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
@(require_results)
index_byte :: #force_inline proc "contextless" (src: []u8, c: u8) -> int {
	return scan(src, c, nil, .Forward)
}

// The index of the last byte `c` in `src`, or -1.
@(require_results)
last_index_byte :: #force_inline proc "contextless" (src: []u8, c: u8) -> int {
	return scan(src, c, nil, .Back)
}

// The number of bytes in `src` equal to `c`.
@(require_results)
count_byte :: proc "contextless" (src: []u8, c: u8) -> int {
	return scan(src, c, nil, .Count)
}

// The bytes of `src` that are not continuation bytes (10xxxxxx): its code point count when it is UTF-8.
@(require_results)
count_chars :: proc "contextless" (src: []u8) -> int {
	return len(src) - scan(src, 0, nil, .Continuations)
}

// The bytes of `src` equal to `c`, or with `CONT` the continuation bytes, counted into byte lanes. A lane overflows
// after 255 blocks, so the lanes are summed every 255.
@(private = "file")
count_lanes :: #force_inline proc "contextless" ($T: Tier, src: []u8, $CONT: bool, c: u8) -> (n: int) {
	when SCALAR_WASM {
		for b in src {
			when CONT {
				n += int(b & 0xC0 == 0x80)
			} else {
				n += int(b == c)
			}
		}
		return
	} else {
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
			when ODIN_ARCH == .amd64 {
				// Keep per-vector reductions on x86 so LLVM lowers each `u8 -> u16` sum to `psadbw`/`vpsadbw`.
				#unroll for v in acc {
					n += int(simd.reduce_add_ordered(cast(#simd[N]u16)v))
				}
			} else {
				sum := cast(#simd[N]u16)acc[0]
				#unroll for k in 1 ..< 64 / N {
					sum += cast(#simd[N]u16)acc[k]
				}
				n += int(simd.reduce_add_ordered(sum))
			}
		}
		// Fewer than 64 bytes are left: 16 at a time into one counter, then the last ones in one load where it stays
		// in the page.
		acc: V
		for ; at + 16 <= len(src); at += 16 {
			acc -= hits(load16(p[at:]), CONT, c)
		}
		if at < len(src) {
			if v, live, ok := head16(p[at:], len(src) - at); ok {
				acc -= simd.bit_and(hits(v, CONT, c), live)
				return n + int(simd.reduce_add_ordered(cast(#simd[16]u16)acc))
			}
			// Fewer than 16 bytes remain; masking with 15 proves the bound to LLVM so it does not auto-vectorize this
			// cold tail.
			for k in 0 ..< ((len(src) - at) & 15) {
				when CONT {
					n += int(p[at + k] & 0xC0 == 0x80)
				} else {
					n += int(p[at + k] == c)
				}
			}
		}
		return n + int(simd.reduce_add_ordered(cast(#simd[16]u16)acc))
	}
}

when !SCALAR_WASM {
	// 0xFF in each lane of `v` equal to `c`, or with `CONT` holding a continuation byte.
	@(private = "file")
	hits :: #force_inline proc "contextless" (v: #simd[$N]u8, $CONT: bool, c: u8) -> #simd[N]u8 {
		U :: #simd[N]u8
		I :: #simd[N]i8
		when CONT {
			// -64 == 0xC0, so signed < -64 selects 0x80..0xBF (10xxxxxx).
			return simd.lanes_lt(transmute(I)v, I(-64))
		} else {
			return simd.lanes_eq(v, U(c))
		}
	}
}

@(require_results)
is_ws :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\n' || c == '\r' || c == '\t'
}

// White space to every markup format: `is_ws` and form feed.
@(require_results)
is_markup_ws :: #force_inline proc "contextless" (c: u8) -> bool {
	return is_ws(c) || c == '\f'
}

// The first byte at or past `p` that is not `is_ws`, or `end`. Up to four bytes one at a time, then 64-byte blocks,
// then the rest. Inlined, since a call would make the walk's states save registers. On amd64, callers must carry
// `@(enable_target_feature = FEATURES[Tier(0)])` (or build at the x86-64-v2 floor) so `lookup` inlines as `pshufb`.
@(require_results)
skip_ws :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 {
	q := p
	when SCALAR_WASM {
		for q < end && is_ws(q[0]) {
			q = q[1:]
		}
		return q
	} else {
		for _ in 0 ..< 4 {
			if q >= end || !is_ws(q[0]) {
				return q
			}
			q = q[1:]
		}
		for intrinsics.ptr_sub(end, q) >= 64 {
			other := ws_other(load(q))
			if !all_zero(transmute(W)other) {
				when IS_WASM {
					// Per register on WebAssembly so `i8x16.ne` folds straight into `pack`'s `i8x16.bitmask`.
					z := V(0)
					nz := Block{
						simd.lanes_ne(other[0], z),
						simd.lanes_ne(other[1], z),
						simd.lanes_ne(other[2], z),
						simd.lanes_ne(other[3], z),
					}
					return q[intrinsics.count_trailing_zeros(pack(nz)):]
				} else {
					return q[intrinsics.count_trailing_zeros(pack(transmute(Block)simd.lanes_ne(transmute(W)other, W(0)))):]
				}
			}
			q = q[64:]
		}
		for q < end && is_ws(q[0]) {
			q = q[1:]
		}
		return q
	}
}

when !SCALAR_WASM {
	@(private = "file", rodata)
	WS_BY_LOW := V{0 = ' ', 9 = '\t', 10 = '\n', 13 = '\r'}

	// Zero in each lane of `b` that is `is_ws`, by the white space byte of its low nibble, which no two share.
	@(private = "file")
	ws_other :: #force_inline proc "contextless" (b: Block) -> Block {
		r: Block
		#unroll for i in 0 ..< 4 {
			// amd64 omits the mask `lookup` needs, since `pshufb` reads only the low nibble, and gives 0 for a byte
			// past 0x7F, which no white space byte matches.
			index := b[i] if ODIN_ARCH == .amd64 else simd.bit_and(b[i], V(0x0f))
			r[i] = simd.bit_xor(lookup(Tier(0), WS_BY_LOW, index), b[i])
		}
		return r
	}
}

// Settings and state of a scan for quoted runs and brackets. A quoted run goes from `quote` to the next `quote` no
// `escape` escapes (0 for none). `sep` is never 0, `quote` is 0 only for `quote_cut` (since a padded tail's zero bytes
// would match them), `escape != quote`, and `sep` differs from `quote` (and from `[`, `{`, `]`, `}` when `nest` is
// true). With `nest`, `[` and `{` outside quoted runs open a level and `]` and `}` close one.
//
// After `quote_run`, index 0 of `depth` and `low` is for a stretch that starts outside a quoted run and 1 for one that
// starts inside: `depth` is the change in level, `low` the lowest level reached from 0. `quoted` says a stretch
// started outside ends inside a quoted run, so one started inside ends outside.
Quotes :: struct {
	quote, escape, sep: u8,
	nest:               bool,
	quoted:             bool, // inside a quoted run
	odd:                bool, // an odd run of escapes ends just before
	want:               int, // `quote_cut`'s level
	depth, low:         [2]int,
}
#assert(size_of(Quotes) == (48 when size_of(int) == 8 else 28))

// Reads `src` as a stretch of text into `s`, reading `quote`, `escape`, `nest`, `odd`, `depth`, and `low` and updating
// `odd`, `quoted`, `depth`, and `low` (any incoming `quoted` is ignored).
@(enable_target_feature = FEATURES[Tier(0)])
quote_run :: proc "contextless" (src: []u8, s: ^Quotes) {
	_ = scan(src, 0, s, .Run)
}

// The index of the first `sep` outside quoted runs at level `want`, from state `s` at `src[0]`, or -1 when there is
// none or the level falls below `want` first. With `quote` 0 it is the first `sep`.
@(require_results, enable_target_feature = FEATURES[Tier(0)])
quote_cut :: proc "contextless" (src: []u8, s: Quotes) -> int {
	s := s
	if s.quote == 0 {
		return scan(src, s.sep, nil, .Forward)
	}
	if s.nest && s.depth[0] < s.want {
		return -1
	}
	return scan(src, s.sep, &s, .Cut)
}

// The lower of `low` and the lowest level a block's closes bring `depth` to, counting the opens before each close.
// Precondition: `open & close == 0`.
@(require_results)
depth_low :: #force_inline proc "contextless" (low, depth: int, open, close: u64) -> int {
	low := low
	if depth >= low && uint(depth) - uint(low) >= uint(intrinsics.count_ones(close)) {
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

when !SCALAR_WASM {
	// Advances `odd` and `inq` across one block and returns the mask of bytes inside a quoted run.
	@(private = "file")
	quote_step :: #force_inline proc "contextless" (
		$T: Tier,
		b: Block,
		quote, escape: u8,
		odd, inq: ^u64,
		$TAIL: bool,
		rem: int,
	) -> u64 {
		q := pack(eq(b, quote))
		if escape != 0 {
			e := escaped(pack(eq(b, escape)), odd)
			when TAIL {
				// A run that ends before a padded block's end escapes the first pad byte.
				odd^ = e >> uint(rem) & 1
			}
			q &~= e
		}
		inside := prefix_xor(T, q) ~ inq^
		inq^ = u64(i64(inside) >> 63)
		return inside
	}

	@(private = "file")
	quote_run_block :: #force_inline proc "contextless" (
		$T: Tier,
		b: Block,
		quote, escape: u8,
		nest: bool,
		odd, inq: ^u64,
		depth, low: ^[2]int,
		$TAIL: bool,
		rem: int,
	) {
		inside := quote_step(T, b, quote, escape, odd, inq, TAIL, rem)
		if nest {
			m := pack_n([2]Block{either(eq(b, '['), eq(b, '{')), either(eq(b, ']'), eq(b, '}'))})
			#unroll for g in 0 ..< 2 {
				out := inside if g == 1 else ~inside
				low[g] = depth_low(low[g], depth[g], m[0] & out, m[1] & out)
				depth[g] += int(intrinsics.count_ones(m[0] & out)) - int(intrinsics.count_ones(m[1] & out))
			}
		}
	}

	@(private = "file")
	quote_cut_block :: #force_inline proc "contextless" (
		$T: Tier,
		b: Block,
		lo: int,
		quote, escape, sep_byte: u8,
		nest: bool,
		want: int,
		odd, inq: ^u64,
		depth: ^int,
	) -> (cut: int, stop: bool) {
		inside := quote_step(T, b, quote, escape, odd, inq, false, 0)
		if !nest {
			if sep := pack(eq(b, sep_byte)) &~ inside; sep != 0 {
				return lo + int(intrinsics.count_trailing_zeros(sep)), true
			}
			return -1, false
		}
		m := pack_n([3]Block{eq(b, sep_byte), either(eq(b, '['), eq(b, '{')), either(eq(b, ']'), eq(b, '}'))})
		sep, open, close := m[0] &~ inside, m[1] &~ inside, m[2] &~ inside
		// A block whose closes cannot bring the level to `want` holds no cut. `closes` counts the closes before
		// `r`'s lowest bit, as they come in order. `depth >= want` holds on entry to every block.
		if dist := uint(depth^) - uint(want); dist <= uint(intrinsics.count_ones(close)) {
			above := int(dist)
			closes := 0
			for r := sep | close; r != 0; r &= r - 1 {
				first := r & -r
				d := above + int(intrinsics.count_ones(open & (first - 1))) - closes
				if close & first != 0 {
					if d <= 0 {
						return -1, true
					}
					closes += 1
				} else if d == 0 {
					return lo + int(intrinsics.count_trailing_zeros(r)), true
				}
			}
		}
		depth^ += int(intrinsics.count_ones(open)) - int(intrinsics.count_ones(close))
		return -1, false
	}
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
	} else when SCALAR_WASM {
		quote, escape, nest := s.quote, s.escape, s.nest
		esc := s.odd && escape != 0
		when OP == .Run {
			quoted := false
			depth, low := s.depth, s.low
			for b in src {
				was := esc
				esc = !esc && escape != 0 && b == escape
				if b == quote && !was {
					quoted = !quoted
				} else if nest {
					g := 1 if quoted else 0
					if b == '[' || b == '{' {
						depth[g] += 1
					} else if b == ']' || b == '}' {
						depth[g] -= 1
						low[g] = min(low[g], depth[g])
					}
				}
			}
			if escape != 0 {
				s.odd = esc
			}
			s.quoted = quoted
			s.depth, s.low = depth, low
			return -1
		} else {
			sep := s.sep
			quoted := s.quoted
			above := uint(s.depth[0]) - uint(s.want)
			for b, i in src {
				was := esc
				esc = !esc && escape != 0 && b == escape
				if b == quote && !was {
					quoted = !quoted
				} else if !quoted {
					if !nest {
						if b == sep {
							return i
						}
					} else if b == '[' || b == '{' {
						above += 1
					} else if b == ']' || b == '}' {
						if above == 0 {
							return -1
						}
						above -= 1
					} else if b == sep && above == 0 {
						return i
					}
				}
			}
			return -1
		}
	} else {
		inq := (~u64(0) if s.quoted else 0) when OP == .Cut else u64(0)
		odd := u64(s.odd)
		quote, escape, nest := s.quote, s.escape, s.nest
		p := raw_data(src)
		lo := 0
		when OP == .Run {
			depth, low := s.depth, s.low
			for ; lo + 64 <= len(src); lo += 64 {
				quote_run_block(T, load(p[lo:]), quote, escape, nest, &odd, &inq, &depth, &low, false, 0)
			}
			if rem := len(src) - lo; rem > 0 {
				quote_run_block(T, load_padded(src, lo), quote, escape, nest, &odd, &inq, &depth, &low, true, rem)
			}
			s.odd = odd != 0
			s.quoted = inq != 0
			s.depth, s.low = depth, low
			return -1
		} else {
			sep, want, depth := s.sep, s.want, s.depth[0]
			for ; lo + 64 <= len(src); lo += 64 {
				if cut, stop := quote_cut_block(T, load(p[lo:]), lo, quote, escape, sep, nest, want, &odd, &inq, &depth); stop {
					return cut
				}
			}
			if lo < len(src) {
				if cut, stop := quote_cut_block(T, load_padded(src, lo), lo, quote, escape, sep, nest, want, &odd, &inq, &depth); stop {
					return cut
				}
			}
			return -1
		}
	}
}

@(private = "file")
scan_loop :: #force_inline proc "contextless" (src: []u8, c: u8, $BACK: bool) -> int {
	p := raw_data(src)
	i := len(src)
	when SCALAR_WASM {
		when BACK {
			for i > 0 {
				i -= 1
				if p[i] == c {
					return i
				}
			}
		} else {
			for j := 0; j < i; j += 1 {
				if p[j] == c {
					return j
				}
			}
		}
		return -1
	} else when BACK {
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
		return -1
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
		return -1
	}
}
