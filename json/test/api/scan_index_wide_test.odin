#+build amd64
package json_tests

import "core:log"
import "core:testing"
import index "../../scan/index"

// Stage 1 in 64-byte and in 32-byte registers against the 16-byte windows, region by region: the same positions, carries and
// region flags, under every fact set. Documents are drawn from JSON-shaped pieces and from single bytes of a
// small alphabet, so quotes, backslash runs, faulty or cut UTF-8, control bytes and scalar runs land at every
// offset of a block and across its edges, and the source's last block takes every length. It runs only where
// the processor has a wide path, each one it has, and says so when it is skipped (STURY_REQUIRE_WIDE turns a
// missing path into a failure: scan_wide_required_test.odin).
@(test)
test_index_wide_against_narrow :: proc(t: ^testing.T) {
	if !index.wide_ok() && !index.avx2_ok() {
		log.info("no AVX2 or AVX-512BW here: the wide index is not compared")
		return
	}
	PIECES := [?]string{
		`"`, `\`, `\\`, `\"`, `"a b"`, `{`, `}`, `[`, `]`, `,`, `:`, " ", "\n", "\t", "12", "-0.5e+3", "true",
		"nul", "x1", "1x", "é", "€", "\U0001f600", "\xc3", "\x80", "\xe2\x82", "\xed\xa0\x80", "\xf4\x90\x80\x80",
		"\x01", "\x1f", "\x7f", "\xff",
	}
	BYTES := [?]u8{'"', '\\', '\\', ' ', 'a', '1', 'e', '-', '{', ']', ',', ':', 0x01, '\n', 0xc3, 0xa9, 0xe2, 0x80, 0xf0, 0xff}
	rng := u64(0x2545f4914f6cdd1d)
	next :: proc(r: ^u64) -> u64 {
		r^ ~= r^ << 13
		r^ ~= r^ >> 7
		r^ ~= r^ << 17
		return r^
	}
	src: [dynamic]u8
	defer delete(src)
	// A character cut by the first region's edge (64 bytes): its lead in each of the last three lanes, ASCII
	// after it, so only the carried bytes tell the next region to check.
	for lead in ([?]u8{0xc3, 0xe2, 0xf0}) {
		for k in 1 ..= 3 {
			clear(&src)
			for len(src) < 64 - k { append(&src, 'a') }
			append(&src, lead)
			for len(src) < 200 { append(&src, 'a') }
			if !compare_index(t, src[:], 0, false, index.Facts{}) {
				log.errorf("lead %x at %d: %q", lead, 64 - k, string(src[:]))
				return
			}
		}
	}
	for round in 0 ..< 4000 {
		clear(&src)
		// Every short length first, so the last block takes each of 0..63 bytes past whole blocks.
		want := round if round < 200 else int(next(&rng) % 3000)
		by_byte := next(&rng) % 2 == 0
		for len(src) < want {
			if by_byte {
				append(&src, BYTES[next(&rng) % len(BYTES)])
			} else {
				append(&src, PIECES[next(&rng) % len(PIECES)])
			}
		}
		// A document start past the source's start, sometimes, so the carried bytes before it are not zeros.
		lo := int(next(&rng) % 80) if len(src) > 80 && round % 3 == 0 else 0
		reads_all := round % 5 == 0
		ok := compare_index(t, src[:], lo, reads_all, index.Facts{}) &&
			compare_index(t, src[:], lo, reads_all, index.Facts{.Scalar_Shape}) &&
			compare_index(t, src[:], lo, reads_all, index.Facts{.Ctrl_In_String}) &&
			compare_index(t, src[:], lo, reads_all, index.Facts{.Scalar_Shape, .Ctrl_In_String})
		if !ok {
			log.errorf("round %d: %d bytes from %d, reads_all %v: %q", round, len(src), lo, reads_all, string(src[:]))
			return
		}
	}
}

// The wide index widths the processor has against the narrow one over `src` from `lo`, in the regions `refill`
// takes, compared after each.
@(private = "file")
compare_index :: proc(t: ^testing.T, src: []u8, lo: int, reads_all: bool, $F: index.Facts) -> bool {
	if index.wide_ok() && !compare_width(t, src, lo, reads_all, F, true) {
		return false
	}
	return !index.avx2_ok() || compare_width(t, src, lo, reads_all, F, false)
}

@(private = "file")
compare_width :: proc(t: ^testing.T, src: []u8, lo: int, reads_all: bool, $F: index.Facts, w512: bool) -> bool {
	wide, narrow := new(index.Index(F)), new(index.Index(F))
	defer free(wide)
	defer free(narrow)
	index.init(wide, src, lo, reads_all)
	index.init(narrow, src, lo, reads_all)
	for narrow.next_lo < len(src) {
		hi := min(narrow.next_lo + narrow.span, len(src))
		if w512 {
			index.classify_wide(wide, narrow.next_lo, hi)
		} else {
			index.classify_avx2(wide, narrow.next_lo, hi)
		}
		index.classify_narrow(narrow, narrow.next_lo, hi)
		narrow.span = min(narrow.span * 2, index.CHUNK)
		same := wide.n == narrow.n && wide.chunk_bs == narrow.chunk_bs && wide.chunk_wire_ok == narrow.chunk_wire_ok &&
			wide.chunk_scalar_ok == narrow.chunk_scalar_ok && wide.carry == narrow.carry && wide.next_lo == narrow.next_lo
		if same {
			for i in 0 ..< narrow.n {
				same &&= wide.buf[i] == narrow.buf[i]
			}
		}
		if !same {
			testing.expectf(t, false, "512-bit %v, facts %v, region [%d, %d): wide n=%d bs=%v wire=%v scalar=%v carry=%v; narrow n=%d bs=%v wire=%v scalar=%v carry=%v",
				w512, F, narrow.chunk_lo, hi, wide.n, wide.chunk_bs, wide.chunk_wire_ok, wide.chunk_scalar_ok, wide.carry,
				narrow.n, narrow.chunk_bs, narrow.chunk_wire_ok, narrow.chunk_scalar_ok, narrow.carry)
			return false
		}
	}
	return true
}
