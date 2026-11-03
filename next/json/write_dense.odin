package json

import "base:intrinsics"
import core "../core"
import kernel "../core/kernel"
import write "../core/write"

// The compact write of a strict JSON source that runs over the source's bytes in place of its rows: each 64-byte block
// drops the blanks outside strings and stores the rest. A source of dense tokens has more rows than a block has bytes
// to spare, and this is faster than one row at a time. The text is the one `rows` makes, since a strict source holds
// only a token, a blank or a punctuation byte outside a string.

// A source with fewer bytes than this per node is written by `write_dense` when its first blocks hold hardly any blank
// outside a string, see `dense_sample`. Past it the tokens are long enough that copying each is cheaper than testing
// each block.
@(private)
DENSE_BYTES_PER_NODE :: 26

// The same bound for a source with more blanks, where a block pays a compress for them.
@(private)
DENSE_BYTES_PER_NODE_BLANK :: 11

// The source bytes `write_dense` reserves output for at a time, a whole number of blocks.
@(private)
DENSE_SEGMENT :: 2048
#assert(DENSE_SEGMENT % 64 == 0 && DENSE_SEGMENT + 64 <= write.ROOM_MAX)

// The segments `write_dense` skips looking for a stretch without a space after one that has a space.
@(private)
DENSE_PROBE_GAP :: 64

// How `dense_run` reads a block: `Plain` takes the quotes it sees, `Escapes` also the backslashes that escape them, and
// `Blind` neither, stopping before the first block that holds a space.
@(private)
Dense_Mode :: enum {
	Plain,
	Escapes,
	Blind,
}

// What a block carries to the next: whether the block ended inside a string, as all ones or zero, and whether it ended
// in an odd run of backslashes. `escapes` is nonzero when the last run met a backslash, so the next takes the mask.
@(private)
Dense_State :: struct {
	in_string, odd, escapes: u64,
}

// Whether `src`, the text of `nodes` nodes of `doc`, is written by `write_dense` under `opts`. The source must be strict
// JSON that the document read in full under no tolerance, and the options must not spell anything again.
@(private)
dense_route :: #force_inline proc "contextless" (doc: ^core.Document, opts: core.Write_Options, src: []u8, nodes: int) -> bool {
	return !opts.pretty && copies_strings(opts) &&
		len(src) < DENSE_BYTES_PER_NODE * nodes &&
		Spec(doc.as.spec) == .Json && doc.as.tolerate == 0 && doc.spelling == &SPELLING &&
		(len(src) < DENSE_BYTES_PER_NODE_BLANK * nodes || dense_sample(src))
}

// Whether the blanks outside strings in the first `DENSE_SEGMENT` bytes of `src` are under a sixteenth of them, counted
// by running `dense_run` over them. A source that fits in the sample is dense whatever it holds, since counting its blanks
// costs as much as writing it.
@(private)
dense_sample :: proc "contextless" (src: []u8) -> bool {
	if len(src) <= DENSE_SEGMENT {
		return true
	}
	scratch: [DENSE_SEGMENT + 64]u8 = ---
	state: Dense_State
	hi := min(len(src), DENSE_SEGMENT)
	kept, _ := dense_run_tier(kernel.tier(), raw_data(scratch[:]), src, 0, hi, &state, .Escapes)
	return (hi - kept) * 16 < hi
}

// Stores the blocks of `src` from `lo` to `hi` without their blanks outside strings, at `out`, which has room for
// `hi - lo + 64` bytes. Returns the count of bytes stored and where the run stopped. `hi` is a whole number of blocks
// past `lo`, or `len(src)`, where the last block is the source's tail, padded with zeros that fall after the value and
// so are dropped. A block's string mask comes from its quotes that no backslash escapes. Inside a string a byte below
// 0x21 can only be a space, which the mask keeps. `Plain` skips the escape mask and stops before the first block that
// holds a backslash, and must start with `s.odd` clear. `Blind` reads no string mask and leaves `s` as it was: a block
// with no space drops every byte below 0x21, since only a space can be inside a string, and so its string state is
// owed to whoever runs the next block with a space.
@(private)
dense_run :: #force_inline proc "contextless" ($T: kernel.Tier, out: [^]u8, src: []u8, lo, hi: int, s: ^Dense_State, $MODE: Dense_Mode) -> (w, i: int) #no_bounds_check {
	in_string, odd, escapes := s.in_string, s.odd, u64(0)
	for i = lo; i < hi; i += 64 {
		b := kernel.load(raw_data(src)[i:]) if hi - i >= 64 else kernel.load_padded(T, src, i)
		drop: u64
		when MODE == .Blind {
			m := kernel.pack_n([2]kernel.Block{kernel.eq(b, ' '), kernel.below(b, ' ' + 1)})
			if m[0] != 0 {
				break
			}
			drop = m[1]
		} else {
			m := kernel.pack_n([3]kernel.Block{kernel.eq(b, '"'), kernel.eq(b, '\\'), kernel.below(b, ' ' + 1)})
			escapes |= m[1]
			if MODE == .Plain && escapes != 0 {
				break
			}
			quotes := m[0] &~ (kernel.escaped(m[1], &odd) if MODE == .Escapes else 0)
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
		s^ = {in_string, odd, escapes}
	} else {
		_, _, _ = in_string, odd, escapes
	}
	return
}

// `dense_run` has a copy per x86 tier, each out of line with the tier's target features, so its 64-lane operations use
// the tier's registers.
when ODIN_ARCH == .amd64 {
	@(private, enable_target_feature = kernel.FEATURES[.V2])
	dense_run_v2 :: #force_no_inline proc "contextless" (out: [^]u8, src: []u8, lo, hi: int, s: ^Dense_State, $E: Dense_Mode) -> (int, int) {
		return dense_run(.V2, out, src, lo, hi, s, E)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V3])
	dense_run_v3 :: #force_no_inline proc "contextless" (out: [^]u8, src: []u8, lo, hi: int, s: ^Dense_State, $E: Dense_Mode) -> (int, int) {
		return dense_run(.V3, out, src, lo, hi, s, E)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V4])
	dense_run_v4 :: #force_no_inline proc "contextless" (out: [^]u8, src: []u8, lo, hi: int, s: ^Dense_State, $E: Dense_Mode) -> (int, int) {
		return dense_run(.V4, out, src, lo, hi, s, E)
	}
} else {
	@(private)
	dense_run_base :: #force_no_inline proc "contextless" (out: [^]u8, src: []u8, lo, hi: int, s: ^Dense_State, $E: Dense_Mode) -> (int, int) {
		return dense_run(.Base, out, src, lo, hi, s, E)
	}
}

@(private)
dense_run_tier :: #force_inline proc "contextless" (tier: kernel.Tier, out: [^]u8, src: []u8, lo, hi: int, s: ^Dense_State, $E: Dense_Mode) -> (int, int) {
	when ODIN_ARCH == .amd64 {
		switch tier {
		case .V4:
			return dense_run_v4(out, src, lo, hi, s, E)
		case .V3:
			return dense_run_v3(out, src, lo, hi, s, E)
		case .V2:
		}
		return dense_run_v2(out, src, lo, hi, s, E)
	} else {
		return dense_run_base(out, src, lo, hi, s, E)
	}
}

// Writes the compact text of `src`, a strict JSON document, into `out`. A leading byte order mark is left out. Blocks
// with no space are written blind, and the string state over them, owed from `owed`, is made up when the next block
// with a space needs it. After such a block the next `DENSE_PROBE_GAP` segments are written with the mask, since a text
// with spaces has them in most segments.
@(private)
write_dense :: proc(out: ^write.Out, src: []u8) {
	tier := kernel.tier()
	state: Dense_State
	i := 3 if len(src) >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF else 0
	owed, gap := i, 0
	for i < len(src) {
		hi := min(i + DENSE_SEGMENT, len(src))
		at, w := write.room(out, hi - i + 64), 0
		if gap > 0 {
			gap -= 1
		} else {
			w, i = dense_run_tier(tier, at, src, i, hi, &state, .Blind)
			gap = DENSE_PROBE_GAP if i < hi else 0
		}
		if i < hi {
			scratch: [DENSE_SEGMENT + 64]u8 = ---
			for ; owed < i; owed += DENSE_SEGMENT {
				dense_run_tier(tier, raw_data(scratch[:]), src, owed, min(owed + DENSE_SEGMENT, i), &state, .Escapes)
			}
			if state.escapes == 0 {
				n, j := dense_run_tier(tier, at[w:], src, i, hi, &state, .Plain)
				w, i = w + n, j
			}
			n, _ := dense_run_tier(tier, at[w:], src, i, hi, &state, .Escapes)
			w, owed = w + n, hi
		}
		out.cursor += w
		i = hi
	}
}
