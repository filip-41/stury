package json

import "base:intrinsics"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// The compact write of a strict JSON document read whole, which runs over the source's bytes in place of its nodes:
// each 64-byte block drops the blanks outside strings and stores the rest. A strict source holds only a token, a blank
// or a punctuation byte outside a string, so the text is the one the walk writes once each escape in a string is
// respelled as `put_escaped` spells it, which `respell_escapes` does.

// A source with fewer bytes than this per node is written by `write_dense` when its first blocks hold hardly any blank
// outside a string, see `dense_sample`. Past it the walk copies each token.
@(private)
DENSE_BYTES_PER_NODE :: 26

// The same bound for a source whose first blocks also hold no backslash.
@(private)
DENSE_BYTES_PER_NODE_PLAIN :: 128

// The same bound for a source with more blanks, where a block pays a compress for them.
@(private)
DENSE_BYTES_PER_NODE_BLANK :: 11

// The source bytes `write_dense` reserves output for at a time, a whole number of blocks.
@(private)
DENSE_SEGMENT :: 2048

// The longest escape, a surrogate pair, which `write_dense` carries whole into the next segment when a segment's end
// cuts it.
@(private)
DENSE_CARRY :: 12
#assert(DENSE_SEGMENT % 64 == 0 && DENSE_SEGMENT + 64 + DENSE_CARRY <= write.ROOM_MAX)

// The segments `write_dense` skips looking for a stretch without a space after one that has a space.
@(private)
DENSE_PROBE_GAP :: 64

// How `dense_run` reads a block: `Escapes` takes the quotes no backslash escapes, `Plain` every quote, stopping before
// the first block that holds a backslash, and `Blind` none, stopping before the first block that holds a space or a
// backslash.
@(private)
Dense_Mode :: enum {
	Escapes,
	Plain,
	Blind,
}

// What a block carries to the next: whether the block ended inside a string, as all ones or zero, and whether it ended
// in an odd run of backslashes.
@(private)
Dense_State :: struct {
	in_string, odd: u64,
}

// The source `write_dense` writes when the compact write of `doc` under `opts` is its, else nil: a strict JSON document
// of a whole text, whose nodes hold every value of its container root, written whole. Its text is the same in each
// JSON spec.
@(private)
dense_route :: proc "contextless" (doc: ^tape.Document, opts: Write_Options) -> []u8 {
	if !write.compact(opts) || opts.node != 0 || opts.sort_keys || opts.ascii || doc.format != &FORMATS[.Json] || doc.partial != nil || doc.flags & {.Stopped, .Tolerated, .Cut, .Held, .Dropped} != {} || len(doc.nodes) == 0 {
		return nil
	}
	root := doc.nodes[0]
	if root.kind < .Array || int(root.n) != len(doc.nodes) || doc.root_close > u64(len(doc.src)) || root.lo >= doc.root_close {
		return nil
	}
	src := doc.src[root.lo:doc.root_close]
	nodes := len(doc.nodes)
	if len(src) < DENSE_BYTES_PER_NODE_PLAIN * nodes && (len(src) < DENSE_BYTES_PER_NODE_BLANK * nodes || dense_sample(src, nodes)) {
		return src
	}
	return nil
}

// Whether the blanks outside strings in the first `DENSE_SEGMENT` bytes of `src` are under a sixteenth of them, and, in
// a source of `DENSE_BYTES_PER_NODE` bytes per node or more, hold no backslash. A source that fits in the sample is
// dense whatever it holds.
@(private)
dense_sample :: proc "contextless" (src: []u8, nodes: int) -> bool {
	if len(src) <= DENSE_SEGMENT {
		return true
	}
	scratch: [DENSE_SEGMENT + 64]u8 = ---
	state: Dense_State
	kept, _, escapes := dense_run_tier(kernel.tier(), raw_data(scratch[:]), src, 0, DENSE_SEGMENT, &state, .Escapes)
	return (DENSE_SEGMENT - kept) * 16 < DENSE_SEGMENT && (len(src) < DENSE_BYTES_PER_NODE * nodes || escapes == 0)
}

// Stores the blocks of `src` from `lo` to `hi` without their blanks outside strings, at `out`, which has room for `hi -
// lo + 64` bytes. Returns the count of bytes stored, where the run stopped and the backslashes it met. `hi` is a whole
// number of blocks past `lo`, or `len(src)`, where the last block is the source's tail, padded with zeros that fall
// after the value and so are dropped. A block's string mask comes from its quotes that no backslash escapes. Inside a
// string a byte below 0x21 can only be a space, which the mask keeps. `Blind` reads no string mask, meets no backslash
// and leaves `s` as it was: a block with no space drops every byte below 0x21, since only a space can be inside a
// string, and so its string state is owed to whoever runs the next block with a space or a backslash.
@(private)
dense_run :: #force_inline proc "contextless" ($T: kernel.Tier, out: [^]u8, src: []u8, lo, hi: int, s: ^Dense_State, $MODE: Dense_Mode) -> (w, i: int, escapes: u64) #no_bounds_check {
	in_string, odd := s.in_string, s.odd
	for i = lo; i < hi; i += 64 {
		b := kernel.load_block(T, src, i)
		drop: u64
		when MODE == .Blind {
			// A block with no blank and no backslash, nearly every block of a dense text, is stored with one test and
			// no mask: a space is a blank.
			blank := kernel.below(b, ' ' + 1)
			if !kernel.any_lane(kernel.either(blank, kernel.eq(b, '\\'))) {
				intrinsics.unaligned_store((^kernel.Block)(out[w:]), b)
				w += 64
				continue
			}
			m := kernel.pack_n([2]kernel.Block{kernel.either(kernel.eq(b, ' '), kernel.eq(b, '\\')), blank})
			if m[0] != 0 {
				break
			}
			drop = m[1]
		} else {
			m := kernel.pack_n([3]kernel.Block{kernel.eq(b, '"'), kernel.eq(b, '\\'), kernel.below(b, ' ' + 1)})
			escapes |= m[1]
			when MODE == .Plain {
				if escapes != 0 {
					break
				}
				quotes := m[0]
			} else {
				quotes := m[0] &~ kernel.escaped(m[1], &odd)
			}
			inside := kernel.prefix_xor(T, quotes) ~ in_string
			in_string = u64(i64(inside) >> 63)
			drop = m[2] &~ inside
		}
		if drop == 0 {
			intrinsics.unaligned_store((^kernel.Block)(out[w:]), b)
			w += 64
		} else {
			w += kernel.compress(b, ~drop, out[w:])
		}
	}
	when MODE != .Blind {
		s^ = {in_string, odd}
	} else {
		_, _ = in_string, odd
	}
	return
}

// `dense_run` has a copy per x86 tier, each out of line with the tier's target features, so its 64-lane operations use
// the tier's registers.
when ODIN_ARCH == .amd64 {
	@(private, enable_target_feature = kernel.FEATURES[.V2])
	dense_run_v2 :: #force_no_inline proc "contextless" (out: [^]u8, src: []u8, lo, hi: int, s: ^Dense_State, $E: Dense_Mode) -> (int, int, u64) {
		return dense_run(.V2, out, src, lo, hi, s, E)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V3])
	dense_run_v3 :: #force_no_inline proc "contextless" (out: [^]u8, src: []u8, lo, hi: int, s: ^Dense_State, $E: Dense_Mode) -> (int, int, u64) {
		return dense_run(.V3, out, src, lo, hi, s, E)
	}
} else {
	@(private, enable_target_feature = kernel.FEATURES[.Base])
	dense_run_base :: #force_no_inline proc "contextless" (out: [^]u8, src: []u8, lo, hi: int, s: ^Dense_State, $E: Dense_Mode) -> (int, int, u64) {
		return dense_run(.Base, out, src, lo, hi, s, E)
	}
}

// `dense_run` under the kernel tier `tier`.
@(private)
dense_run_tier :: #force_inline proc "contextless" (tier: kernel.Tier, out: [^]u8, src: []u8, lo, hi: int, s: ^Dense_State, $E: Dense_Mode) -> (int, int, u64) {
	when ODIN_ARCH == .amd64 {
		if tier == .V3 {
			return dense_run_v3(out, src, lo, hi, s, E)
		}
		return dense_run_v2(out, src, lo, hi, s, E)
	} else {
		return dense_run_base(out, src, lo, hi, s, E)
	}
}

// Writes the compact text of `src`, a strict JSON value, into `out`. Blocks with no space or backslash are written
// blind, and the string state over them, owed from `owed`, is made up when the next block that has one needs it. After
// such a block the next `DENSE_PROBE_GAP` segments are written with the mask, since a text with spaces or escapes has
// them in most segments. From the first block with a backslash on, a segment's blocks are stored in `staged`, after the
// bytes of an escape the last segment's end cut, and respelled from there into `out`.
@(private)
write_dense :: proc(out: ^write.Out, src: []u8) #no_bounds_check {
	tier := kernel.tier()
	state: Dense_State
	staged: [DENSE_CARRY + DENSE_SEGMENT + 64]u8 = ---
	carried := 0
	i, owed, gap := 0, 0, 0
	// Whether a block with a backslash was read, after which every block takes the escape mask.
	escaped := false
	for i < len(src) {
		hi := min(i + DENSE_SEGMENT, len(src))
		at := write.room(out, hi - i + 64 + DENSE_CARRY)
		into := raw_data(staged[carried:]) if escaped else at
		w, n := 0, 0
		if gap > 0 {
			gap -= 1
		} else {
			n, i, _ = dense_run_tier(tier, into, src, i, hi, &state, .Blind)
			gap = DENSE_PROBE_GAP if i < hi else 0
		}
		if i < hi {
			scratch: [DENSE_SEGMENT + 64]u8 = ---
			for ; owed < i; owed += DENSE_SEGMENT {
				dense_run_tier(tier, raw_data(scratch[:]), src, owed, min(owed + DENSE_SEGMENT, i), &state, .Escapes)
			}
			if !escaped {
				k, j, e := dense_run_tier(tier, at[n:], src, i, hi, &state, .Plain)
				n, i, escaped = n + k, j, e != 0
				if escaped {
					w, n, into = n, 0, raw_data(staged[:])
				}
			}
			if i < hi {
				k, _, _ := dense_run_tier(tier, into[n:], src, i, hi, &state, .Escapes)
				n += k
			}
			owed = hi
		}
		if escaped {
			n += carried
			wrote, read := respell_escapes(at[w:], raw_data(staged[:]), n)
			w += wrote
			// Every escape of a strict text reads, so one that does not is cut by the segment's end.
			carried = n - read
			intrinsics.mem_copy(raw_data(staged[:]), raw_data(staged[read:]), carried)
		} else {
			w = n
		}
		out.cursor += w
		i = hi
	}
}

// Writes the `n` bytes of strict JSON text at `src` to `dst` with each escape respelled as `put_escaped` spells its
// bytes. Returns the bytes written and the bytes read, fewer than `n` where an escape does not read whole. It reads up
// to 64 bytes past `n` and stores up to 64 past what it writes, and no escape's spelling is longer than its source's.
// Only a unicode escape or an escaped solidus is spelled anew, found by the byte after a backslash that no backslash
// escapes, and the bytes between two are copied as they are.
@(private)
respell_escapes :: proc "contextless" (dst, src: [^]u8, n: int) -> (w, i: int) #no_bounds_check {
	// A run of backslashes of odd length at the end leaves its last one an escape whose letter is past `n`.
	end := n
	for end > 0 && src[end - 1] == '\\' {
		end -= 1
	}
	end = n - (n - end) & 1
	// 1 when an odd run of backslashes ends the previous block, escaping the first byte of this one.
	odd: u64
	// The last block held no backslash, so a stretch with none may follow.
	plain := true
	for base := 0; base < end; base += 64 {
		// A stretch with no backslash is copied two blocks at a time.
		for plain && odd == 0 && i == base && base + 128 <= end {
			x, y := kernel.load(src[base:]), kernel.load(src[base + 64:])
			if kernel.any_lane(kernel.either(kernel.eq(x, '\\'), kernel.eq(y, '\\'))) {
				break
			}
			intrinsics.unaligned_store((^kernel.Block)(dst[w:]), x)
			intrinsics.unaligned_store((^kernel.Block)(dst[w + 64:]), y)
			w, i, base = w + 128, i + 128, base + 128
		}
		if base >= end {
			break
		}
		b := kernel.load(src[base:])
		backslashes := kernel.eq(b, '\\')
		letters: u64
		plain = odd == 0 && !kernel.any_lane(backslashes)
		if !plain {
			letters = kernel.escaped(kernel.pack(backslashes), &odd) & kernel.pack(kernel.either(kernel.eq(b, 'u'), kernel.eq(b, '/')))
		}
		if end - base < 64 {
			letters &= u64(1) << uint(end - base) - 1
		}
		// An escape whose backslash ends the last block, copied with its rest, is taken back.
		if letters & 1 != 0 && i == base {
			i -= 1
			w -= 1
		}
		for ; letters != 0; letters &= letters - 1 {
			e := base + int(intrinsics.count_trailing_zeros(letters)) - 1
			// The second half of a surrogate pair was read with the first.
			if e < i {
				continue
			}
			intrinsics.unaligned_store((^kernel.Block)(dst[w:]), kernel.load(src[i:]))
			w += e - i
			i = e
			if src[i + 1] == '/' {
				dst[w] = '/'
				w += 1
				i += 2
				continue
			}
			r, size := spell.unicode_escape(src[i:], end - i)
			if size == 0 {
				return w, i
			}
			i += size
			w += put_rune(dst[w:], u32(r))
		}
		// The rest of the block is copied, so every block starts at or before `i` and the bytes before an escape take
		// one store.
		if i < base + 64 {
			intrinsics.unaligned_store((^kernel.Block)(dst[w:]), kernel.load(src[i:]))
			w += base + 64 - i
			i = base + 64
		}
	}
	for k := 0; k < end - i; k += 64 {
		intrinsics.unaligned_store((^kernel.Block)(dst[w + k:]), kernel.load(src[i + k:]))
	}
	return w + end - i, end
}

// Writes code point `u` at `dst` as `put_escaped` spells it, and returns its length, at most 6.
@(private)
put_rune :: #force_inline proc "contextless" (dst: [^]u8, u: u32) -> int #no_bounds_check {
	switch {
	case u >= 0x10000:
		intrinsics.unaligned_store((^u32le)(dst), u32le(0xF0 | u >> 18 | (0x80 | u >> 12 & 0x3F) << 8 | (0x80 | u >> 6 & 0x3F) << 16 | (0x80 | u & 0x3F) << 24))
		return 4
	case u >= 0x800:
		intrinsics.unaligned_store((^u32le)(dst), u32le(0xE0 | u >> 12 | (0x80 | u >> 6 & 0x3F) << 8 | (0x80 | u & 0x3F) << 16))
		return 3
	case u >= 0x80:
		intrinsics.unaligned_store((^u16le)(dst), u16le(0xC0 | u >> 6 | (0x80 | u & 0x3F) << 8))
		return 2
	case ESCAPE_OF[u] != 0:
		return escape_into(dst, u8(u))
	}
	dst[0] = u8(u)
	return 1
}
