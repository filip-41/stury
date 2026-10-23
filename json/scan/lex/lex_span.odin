package lex

// A string's body crossed in one call (`span_advance`, from lex_string.odin's string readers): the cursor
// moves to the next quote or backslash, or control byte under `.Values`, validating wire UTF-8 on the way. It
// may stop early on a byte >= 0x80, whose result the caller re-derives.
//
// Loads are unchecked and gated on the bytes left in `s.src`, not on padding: the eight-byte head on
// `s.pos + 8 <= len`, the 64-byte tier on `p + 64 <= len` before each block, the 16-byte loop and
// `span_land16` on `s.pos + 16 <= len`. `prefix_keep` is asked only of a lane a non-empty stop mask names.
// `$check` picks the stop set: `.Values` adds control bytes and passes a clean ASCII window whole.
// `SCAN_FORCE_SLOW` compiles every route out but `span_tail`.

import "base:intrinsics"
import "core:simd"
import bits "../../../core/bits"

// Sixteen-byte window at p. Caller guarantees p + 16 <= len(src).
// `p` is a cursor, so the load is unaligned. Callers gate on that bound
// before loading.
load16 :: #force_inline proc(src: []byte, p: u64) -> #simd[16]u8 {
	#no_bounds_check {
		return intrinsics.unaligned_load((^#simd[16]u8)(&src[p]))
	}
}

utf8_pairs_err :: bits.utf8_pairs_err
utf8_err :: bits.utf8_err
any_lane :: bits.any_lane
any_high :: bits.any_high

// Lane of the first stop byte in a 16-byte window, from that window's own stop mask (never empty: the
// caller knows the window holds a stop). The mask must be the chosen window's, not the fold of three: a
// stop in lane 4 of a later window is bit 4 of the same 16-bit fold.
//
// The count is a narrowing shift (four bits per lane in one u64) rather than a movemask, which NEON builds
// from a bit-weight AND and a horizontal add on the cursor's dependency chain. It needs each lane all-ones
// or all-zero, which every comparison result and OR of them is.
first_stop_lane :: #force_inline proc(stop: #simd[16]u8) -> u64 {
	// x86 has the movemask NEON lacks: pmovmskb, one bit per lane.
	when ODIN_ARCH == .amd64 {
		return u64(intrinsics.count_trailing_zeros(transmute(u16)simd.extract_msbs(stop)))
	}
	nib := cast(#simd[8]u8)simd.shr(transmute(#simd[8]u16)stop, 4)
	return u64(intrinsics.count_trailing_zeros(transmute(u64)nib)) >> 2
}

// The scalar tail of a span: the residue after the vector body is short, so one direct check per byte. This
// is the stop rule written out. The probes read the same rule from `SPAN_STOP`, and the span head tests pin
// the two against each other at both check levels.
@(private = "file")
span_tail :: #force_inline proc(s: ^Scanner, $check: Check_Level) {
	for s.pos < u64(len(s.src)) {
		c := s.src[s.pos]
		if c == 0x22 || c == 0x5c || c >= 0x80 {
			break
		}
		when check == .Values {
			if c < 0x20 {
				break
			}
		}
		s.pos += 1
	}
}

@(private = "file")
span_stop_bit :: #force_inline proc($check: Check_Level) -> u8 {
	when check == .Values {
		return SPAN_STOP_VALUES
	} else {
		return SPAN_STOP_LOCATE
	}
}

// `span_tail` over a window the caller has bounded: PRE `s.pos + 16 <= len`.
// Resolve with the byte walk, not ctz(hit): on short-string documents this exit IS the span loop, and
// `span_tail` lands on the first stop byte by construction. One `SPAN_STOP` probe per byte at a fixed
// offset, so each exit sets the cursor from a constant and nothing waits on a lane count.
@(private = "file")
span_land16 :: #force_inline proc(s: ^Scanner, $check: Check_Level) -> int {
	p := s.pos
	w := ([^]u8)(raw_data(s.src)[p:])
	#no_bounds_check #unroll for k in 0 ..< 16 {
		if SPAN_STOP[w[k]] & span_stop_bit(check) != 0 {
			s.pos = p + u64(k)
			return int(w[k])
		}
	}
	s.pos = p + 16
	span_tail(s, check)
	return peek(s)
}

// Lanes 0..k of a 16-byte window as a byte mask, one row per lane index: row `k` keeps `k + 1` lanes. The
// stop lane is kept too, because a lead byte immediately before it must be cleared before the prefix may
// be stepped over.
//
// A table because `k` is a run-time value. Row 16 is all-zero and unreachable (`first_stop_lane` returns
// at most 15). It keeps an out-of-range index on a defined row at `-o:speed`, where bounds checks are off.
// Rows are `[16]u8` because a composite literal for a vector element does not parse.
@(rodata)
PREFIX_KEEP: [17][16]u8 = {
	{0xff,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},
	{0xff,0xff,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},
	{0xff,0xff,0xff,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},
	{0xff,0xff,0xff,0xff,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},
	{0xff,0xff,0xff,0xff,0xff,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},
	{0xff,0xff,0xff,0xff,0xff,0xff,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},
	{0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},
	{0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},
	{0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x00,0x00,0x00,0x00,0x00,0x00,0x00},
	{0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x00,0x00,0x00,0x00,0x00,0x00},
	{0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x00,0x00,0x00,0x00,0x00},
	{0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x00,0x00,0x00,0x00},
	{0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x00,0x00,0x00},
	{0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x00,0x00},
	{0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x00},
	{0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff},
	{0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},
}

// The 17-row prefix mask, indexed by a lane number. PRE: `k` is in `0 ..= 16`. Odin elides the bounds
// check on `x[a & (N-1)]` only for a constant power-of-two `len(x)`, so `#no_bounds_check` is the only
// form that removes it here.
prefix_keep :: #force_inline proc(k: u64) -> #simd[16]u8 {
	#no_bounds_check {
		return transmute(#simd[16]u8)PREFIX_KEEP[k]
	}
}

// Where a vector route leaves after a window `v` ending at `end`: `end`, or the lead of a character the
// window does not finish (rule 2 at `span_advance`).
char_boundary_at :: #force_inline proc "contextless" (v: #simd[16]u8, end: u64) -> u64 {
	c := simd.extract(v, 15)
	if c >= 0xc0 {
		return end - 1
	} else if c >= 0x80 {
		c2 := simd.extract(v, 14)
		if c2 >= 0xe0 {
			return end - 2
		} else if c2 >= 0x80 && simd.extract(v, 13) >= 0xf0 {
			return end - 3
		}
	}
	return end
}

// How one 16-byte window checks against the window before it: no stop and no fault, a stop at a lane with
// every lane up to and including it fault-free, or a fault.
Span_Judge :: enum u8 {
	Clean,
	Stop,
	Fault,
}

// `prev` is the window before `v` (zero where `v` follows a character boundary), `stop` the stop lanes of
// `v`. The stop lane is kept in the fault mask because an unfinished character just before it has its
// continuation where the stop sits (`prefix_keep`). A fault past the stop is the next span's.
span_judge16 :: #force_inline proc(prev, v, stop: #simd[16]u8) -> (k: u64, j: Span_Judge) {
	e := utf8_err(prev, v)
	if any_lane(stop) {
		k = first_stop_lane(stop)
		if any_lane(e & prefix_keep(k)) {
			return 0, .Fault
		}
		return k, .Stop
	}
	if any_lane(e) {
		return 0, .Fault
	}
	return 0, .Clean
}

// The lanes of `v` that end a span: a quote (`qv`), a backslash (`bv`), and under `.Values` a control byte.
// The two vectors are the caller's locals.
@(private = "file")
span_stops :: #force_inline proc(v, qv, bv: #simd[16]u8, $check: Check_Level) -> #simd[16]u8 {
	st := simd.lanes_eq(v, qv) | simd.lanes_eq(v, bv)
	when check == .Values {
		st |= simd.lanes_lt(v, 0x20)
	}
	return st
}

// String-span advance, shared by both walks. `check == .Values` adds the control-byte stop, the only
// thing the skip route omits. Both validate UTF-8, because encoding is not grammar.
//
// The tiers gate on the bytes left in the document, not in the string, so the head makes a short string in
// a long document cheap. It does not take a high byte: the wide body consumes those in validated runs.
//
// A route may only land on a byte the caller can re-derive a result from (quote, backslash, control under
// `Values`, a byte >= 0x80, or the end of input), with everything before it already checked:
//   1. A route steps over a byte >= 0x80 only after validating the whole sequence it belongs to.
//   2. The vector tiers leave on a character boundary: an unfinished character at a tier's end goes back to
//      its lead, since a split sequence would read as malformed to the next window's `utf8_err`.
//   3. A stop is landed on only after `utf8_err` has cleared every lane up to and including it
//      (`span_judge16`, `prefix_keep`).
// Stopping early is only slow.
//
// `land_by_count` lands a span that reached the 16-byte loop by its window's first stop lane, where
// `span_land16` probes byte by byte. A span that long has a length the branch predictor seldom learns,
// so each probe exit mispredicts, while the count only lengthens the cursor's chain. The plain validate walk
// keeps the probes, whose code its registers are laid out around: the count there would spill more.
//
// Answers the byte the span stopped on, as `peek` would read it at `s.pos`.
span_advance :: #force_inline proc(s: ^Scanner, $check: Check_Level, $land_by_count: bool) -> int {
	#no_bounds_check {
		n := u64(len(s.src))
		when !SCAN_FORCE_SLOW {
			if s.pos + 8 <= n {
				p := s.pos
				w := ([^]u8)(raw_data(s.src)[p:])
				head: {
					#unroll for k in 0 ..< 8 {
						if SPAN_STOP[w[k]] & span_stop_bit(check) != 0 {
							s.pos = p + u64(k)
							if w[k] < 0x80 {
								return int(w[k])
							}
							break head
						}
					}
					s.pos = p + 8
				}
			}
		}
		// Sixty-four bytes per iteration. Each block carries the previous block's last window as the context of
		// its first, so the cursor advances by exactly 64 with no trim. Only a block that holds a stop or a
		// fault takes the window-by-window check, and that ends the span.
		when !SCAN_FORCE_SLOW {
			qv: #simd[16]u8 = '"'
			bv: #simd[16]u8 = '\\'
			tier64: if s.pos + 64 <= n {
				v0 := load16(s.src, s.pos)
				st0 := span_stops(v0, qv, bv, check)
				if any_lane(st0) {
					// The 16-byte loop would only re-test this same window.
					return span_land16(s, check)
				}
				when ODIN_ARCH == .amd64 {
					// Past its first window, the span goes on in 64-byte registers where the processor has them.
					if wide_ok() {
						at := span_wide(s.src, s.pos, check)
						if at >= 0 {
							s.pos = u64(at)
							return int(s.src[at])
						}
						s.pos = u64(~at) // unfinished: the narrow loops below go on from there
						break tier64
					}
				}
				when check == .Values {
					if !any_lane(simd.lanes_gt(v0, 0x7f)) {
						// Strict only: a clean ASCII window is passed here rather than re-tested by the
						// 16-byte loop.
						s.pos += 16
						break tier64
					}
				}
				// `entry` is a character boundary (the head passes only ASCII), so its context is the
				// zero fill.
				entry := s.pos
				p := entry
				prev: #simd[16]u8
				for {
					v1 := load16(s.src, p + 16)
					v2 := load16(s.src, p + 32)
					v3 := load16(s.src, p + 48)
					st1 := span_stops(v1, qv, bv, check)
					st2 := span_stops(v2, qv, bv, check)
					st3 := span_stops(v3, qv, bv, check)
					stops := (st0 | st1) | (st2 | st3)
					e: #simd[16]u8
					when check == .Locate {
						// Locate has no ASCII hand-off above: a block of ASCII needs the context window
						// only, to catch an unfinished character carried in from the block before.
						if !any_lane(simd.lanes_gt((v0 | v1) | (v2 | v3), 0x7f)) {
							e = utf8_err(prev, v0)
						} else {
							e = (utf8_err(prev, v0) | utf8_err(v0, v1)) | (utf8_err(v1, v2) | utf8_err(v2, v3))
						}
					} else {
						e = (utf8_err(prev, v0) | utf8_err(v0, v1)) | (utf8_err(v1, v2) | utf8_err(v2, v3))
					}
					if any_lane(stops | e) {
						// A stop or a fault in this block: check the windows in order.
						k: u64
						j: Span_Judge
						k, j = span_judge16(prev, v0, st0)
						if j == .Clean {
							k, j = span_judge16(v0, v1, st1)
							if j == .Clean {
								k, j = span_judge16(v1, v2, st2)
								if j == .Clean {
									k, j = span_judge16(v2, v3, st3)
									if j == .Stop { k += 48 } // the lane is in the window's own terms
								} else if j == .Stop {
									k += 32
								}
							} else if j == .Stop {
								k += 16
							}
						}
						if j == .Stop {
							s.pos = p + k
							return int(s.src[s.pos]) // the caller handles the stop byte
						}
						s.pos = entry // a fault: the loops below re-derive it
						break tier64
					}
					prev = v3
					p += 64
					if p + 64 > n {
						// Leaving the tier: an unfinished character at the end goes back to its lead, so
						// the loop below starts on a boundary.
						s.pos = char_boundary_at(v3, p)
						break tier64
					}
					v0 = load16(s.src, p)
					st0 = span_stops(v0, qv, bv, check)
					when check == .Values {
						if !any_lane(st0 | simd.lanes_gt(v0, 0x7f)) {
							// A clean ASCII window: the rest of the span is the 16-byte loop's, once the
							// context carried in has been checked against it.
							if any_lane(utf8_err(prev, v0)) {
								s.pos = entry
								break tier64
							}
							s.pos = p + 16
							break tier64
						}
					}
				}
			}
			for s.pos + 16 <= n {
				v := load16(s.src, s.pos)
				// `v - 0x20 > 0x5F` is "< 0x20 or >= 0x80": one compare for the control stop and
				// the wire byte.
				hit := simd.lanes_eq(v, qv) | simd.lanes_eq(v, bv)
				when check == .Values {
					hit |= simd.lanes_gt(v - 0x20, 0x5f)
				} else {
					hit |= simd.lanes_gt(v, 0x7f)
				}
				adv := u64(16)
				if any_lane(hit) {
					if any_lane(span_stops(v, qv, bv, check)) {
						// The span ends in this window.
						when land_by_count {
							s.pos += first_stop_lane(hit)
							return int(s.src[s.pos])
						} else {
							return span_land16(s, check)
						}
					}
					// Zero-filled context: the window starts on a boundary.
					if any_lane(utf8_err({}, v)) {
						break // wire fault: `span_tail` re-derives it
					}
					// A window ending inside a character hands its trailing bytes to the next one.
					c := simd.extract(v, 15)
					if c >= 0xc0 {
						adv = 15
					} else if c >= 0x80 {
						c2 := simd.extract(v, 14)
						if c2 >= 0xe0 {
							adv = 14
						} else if c2 >= 0x80 && simd.extract(v, 13) >= 0xf0 {
							adv = 13
						}
					}
				}
				s.pos += adv
			}
		}
		span_tail(s, check)
		return peek(s)
	}
}
