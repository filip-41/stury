package json

import "base:intrinsics"
import "stury:lib/base/kernel"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// The compact write of a strict JSON document read whole, which runs over the source's bytes in place of its nodes:
// each 64-byte block drops the blanks outside strings and stores the rest. A strict source holds only a token, a blank
// or a punctuation byte outside a string, so the text is the source without them: a string's escapes are copied as
// written, as the walk does.

// A source with fewer bytes than this per node is written by `write_dense` when its first blocks hold hardly any blank
// outside a string, see `dense_sample`. Past it the walk copies each token.
@(private)
DENSE_BYTES_PER_NODE :: 128

// A source with fewer bytes than this per node is written by `write_dense` whatever its blanks, which a block drops with
// one compress, as the walk's tokens cost more.
@(private)
DENSE_BYTES_PER_NODE_BLANK :: 11

// The source bytes `write_dense` reserves output for at a time, a whole number of blocks.
@(private)
DENSE_SEGMENT :: 2048

#assert(DENSE_SEGMENT % 64 == 0 && DENSE_SEGMENT + 64 <= write.ROOM_MAX)

// The segments `write_dense` skips looking for a stretch without a space after one that has a space.
@(private)
DENSE_PROBE_GAP :: 64

// How `dense_run` reads a block: `Escapes` takes the quotes no backslash escapes, `Plain` every quote, stopping before
// the first block that holds a backslash, and `Blind` none, stopping before the first block that holds a space.
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
	if len(src) < DENSE_BYTES_PER_NODE * nodes && (len(src) < DENSE_BYTES_PER_NODE_BLANK * nodes || dense_sample(src)) {
		return src
	}
	return nil
}

// Whether the blanks outside strings in the first `DENSE_SEGMENT` bytes of `src` are under a sixteenth of them. A source
// that fits in the sample is dense whatever it holds.
@(private)
dense_sample :: proc "contextless" (src: []u8) -> bool {
	if len(src) <= DENSE_SEGMENT {
		return true
	}
	scratch: [DENSE_SEGMENT + 64]u8 = ---
	state: Dense_State
	kept, _, _ := dense_run_tier(kernel.tier(), raw_data(scratch[:]), src, 0, DENSE_SEGMENT, &state, .Escapes)
	return (DENSE_SEGMENT - kept) * 16 < DENSE_SEGMENT
}

// Stores the blocks of `src` from `lo` to `hi` without their blanks outside strings, at `out`, which has room for `hi -
// lo + 64` bytes. Returns the count of bytes stored, where the run stopped and the backslashes it met. `hi` is a whole
// number of blocks past `lo`, or `len(src)`, where the last block is the source's tail, padded with zeros that fall
// after the value and so are dropped. A block's string mask comes from its quotes that no backslash escapes. Inside a
// string a byte below 0x21 can only be a space, which the mask keeps. `Blind` reads no string mask and leaves `s` as it
// was: a block with no space drops every byte below 0x21, since only a space can be inside a string, and so its string
// state is owed to whoever runs the next block with a space.
@(private)
dense_run :: #force_inline proc "contextless" ($T: kernel.Tier, out: [^]u8, src: []u8, lo, hi: int, s: ^Dense_State, $MODE: Dense_Mode) -> (w, i: int, escapes: u64) #no_bounds_check {
	in_string, odd := s.in_string, s.odd
	for i = lo; i < hi; i += 64 {
		b := kernel.load_block(src, i)
		drop: u64
		when MODE == .Blind {
			// A block with no blank, nearly every block of a dense text, is stored with one test and no mask: a space is
			// a blank.
			blank := kernel.below(b, ' ' + 1)
			if !kernel.any_lane(blank) {
				intrinsics.unaligned_store((^kernel.Block)(out[w:]), b)
				w += 64
				continue
			}
			m := kernel.pack_n([2]kernel.Block{kernel.eq(b, ' '), blank})
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

// Writes the compact text of `src`, a strict JSON value, into `out`. Blocks with no space are written blind, and the
// string state over them, owed from `owed`, is made up when the next block that has one needs it. After such a block
// the next `DENSE_PROBE_GAP` segments are written with the mask, since a text with spaces has them in most segments.
@(private)
write_dense :: proc(out: ^write.Out, src: []u8) #no_bounds_check {
	tier := kernel.tier()
	state: Dense_State
	i, owed, gap := 0, 0, 0
	// Whether a block with a backslash was read, after which every block takes the escape mask.
	escaped := false
	for i < len(src) {
		hi := min(i + DENSE_SEGMENT, len(src))
		at := write.room(out, hi - i + 64)
		w := 0
		if gap > 0 {
			gap -= 1
		} else {
			w, i, _ = dense_run_tier(tier, at, src, i, hi, &state, .Blind)
			gap = DENSE_PROBE_GAP if i < hi else 0
		}
		if i < hi {
			scratch: [DENSE_SEGMENT + 64]u8 = ---
			for ; owed < i; owed += DENSE_SEGMENT {
				_, _, e := dense_run_tier(tier, raw_data(scratch[:]), src, owed, min(owed + DENSE_SEGMENT, i), &state, .Escapes)
				escaped ||= e != 0
			}
			if !escaped {
				k, j, e := dense_run_tier(tier, at[w:], src, i, hi, &state, .Plain)
				w, i, escaped = w + k, j, e != 0
			}
			if i < hi {
				k, _, _ := dense_run_tier(tier, at[w:], src, i, hi, &state, .Escapes)
				w += k
			}
			owed = hi
		}
		out.cursor += w
		i = hi
	}
}

