package index

// Stage 1: list where every token starts, one bounded region at a time, so a
// walk that stops early classifies only the regions it reached. Stage 2 pulls
// positions with `next`. The index never decides anything about the document's
// grammar.
//
// Wire faults (bad UTF-8, a control byte inside a string) are not reported as errors
// here: a region holding one is marked (`chunk_wire_ok`), and stage 2 reads its
// bytes, which own the exact offset.

import "core:simd"

// Source bytes per chunk, the largest region. For a walk that may stop,
// regions start at FIRST_SPAN and double, so a walk that stops at its first
// tokens classifies few bytes past them, and a walk that reads to the end takes
// whole chunks from the start. The position buffer holds one slot per byte
// plus the slack `flatten` writes past the last position. Positions are
// offsets into their region, so a region stays within u16 range.
CHUNK :: 16 * 1024
@(private = "file")
FIRST_SPAN :: 64
@(private = "file")
SLACK :: FLATTEN_STEP
#assert(CHUNK <= 1 << 16 && FIRST_SPAN % 64 == 0)

// What a consumer asks the index to record beyond token starts and the wire
// faults every walk needs. Each fact costs work per block, so an index is
// specialized to the facts its consumer requests.
Fact :: enum {
	Ctrl_In_String, // `chunk_wire_ok`, from `acc.ctrl`
	Scalar_Shape, // `chunk_scalar_ok`
}
Facts :: bit_set[Fact]

// Declared `---` by its consumers, so that only what a region writes is ever
// written. Odin zeroes a struct with padding even then, so no field leaves a
// gap: the flags are 64-bit booleans.
Index :: struct($F: Facts) {
	src:      []u8,
	chunk_lo: int, // first byte of the region in `buf`
	next_lo:  int, // first byte of the next region to classify
	span:     int, // bytes the next region takes
	carry:    Carry, // state at next_lo
	n:        int, // positions in `buf`
	// Whether the current region holds a backslash, which decides whether a
	// string there needs the escape-checking leaf, and whether its bytes passed
	// every wire check this index makes (UTF-8, and control bytes inside
	// strings when requested).
	chunk_bs:      b64,
	chunk_wire_ok: b64,
	// Whether every scalar run in the current region holds only the bytes its
	// first byte allows (`scalar_shape`). It is false unless requested.
	chunk_scalar_ok: b64,
	buf:      [CHUNK + SLACK]u16,
}

// Start at `lo`, a document start: no string, escape or scalar run is open
// there. `reads_all` says the consumer reads to the end of `src`.
init :: proc(ix: ^Index($F), src: []u8, lo: int, reads_all := false) {
	ix.src = src
	ix.next_lo = lo
	ix.span = CHUNK if reads_all else FIRST_SPAN
	ix.carry = Carry{prev = before16(src, lo)}
	ix.n = 0
	ix.chunk_bs = false
	ix.chunk_wire_ok = false
	ix.chunk_scalar_ok = false
}

// Where a consumer reads in the classified region. It lives with the consumer
// and comes back by value from the index, never through a pointer the index
// keeps, so the consumer's loop holds it in registers: held in memory, each
// token's load waits on the previous token's store.
Reader :: struct {
	i, n: int, // the next slot of `buf` to hand out, and the slots filled
	lo:   int, // first byte of the region in `buf`
}

// The next token start, or -1 past the last one.
next :: #force_inline proc(ix: ^Index($F), r: ^Reader) -> int {
	if r.i < r.n {
		#no_bounds_check p := ix.buf[r.i]
		r.i += 1
		return r.lo + int(p)
	}
	p: int
	p, r^ = refill(ix)
	return p
}

// True when the position `next` will hand out next is in the region already
// classified, so a string opened at the current position closes inside it.
next_is_buffered :: #force_inline proc(r: ^Reader) -> bool {
	return r.i < r.n
}

@(cold)
refill :: proc(ix: ^Index($F)) -> (int, Reader) {
	for ix.next_lo < len(ix.src) {
		classify(ix, ix.next_lo, min(ix.next_lo + ix.span, len(ix.src)))
		ix.span = min(ix.span * 2, CHUNK)
		if ix.n > 0 {
			return ix.chunk_lo + int(ix.buf[0]), Reader{i = 1, n = ix.n, lo = ix.chunk_lo}
		}
	}
	return -1, Reader{}
}

// "Wide" below is the AVX-512BW index working in 64-byte blocks. "avx2" works in 32-byte ones, and "narrow" is
// the portable 16-byte fallback.
classify :: proc(ix: ^Index($F), lo, hi: int) {
	when ODIN_ARCH == .amd64 {
		// The region's blocks run in 64-byte registers where the processor has them (block_wide.odin), else
		// in 32-byte ones (block_avx2.odin). A first region of one block stays narrow: the wide entry costs
		// more than its one block saves, as in a `GetOne` that stops in it.
		if hi - lo > FIRST_SPAN {
			if wide_ok() {
				classify_wide(ix, lo, hi)
				return
			}
			if avx2_ok() {
				classify_avx2(ix, lo, hi)
				return
			}
		}
	}
	classify_narrow(ix, lo, hi)
}

// `classify` in 16-byte windows: arm64, and amd64 without AVX2.
classify_narrow :: #force_inline proc(ix: ^Index($F), lo, hi: int) {
	acc: Chunk_Acc
	// A local copy: `buf` lives in the index, so through `&ix.carry` every
	// position store would force the carry back to memory between blocks.
	cy := ix.carry
	out := raw_data(ix.buf[:])
	at := raw_data(ix.src)
	n := 0
	p := lo
	for p + 64 <= hi {
		n = block(at[p:], u16(p - lo), &cy, &acc, out, n, F)
		p += 64
	}
	// Chunks are whole blocks, so only the source's last block is partial.
	if p < hi {
		pad: [64]u8 = ' '
		copy(pad[:], ix.src[p:hi])
		n = block(raw_data(pad[:]), u16(p - lo), &cy, &acc, out, n, F)
	}
	ix.carry = cy
	ix.n = flatten(out, n, acc.pend, acc.pend_base)
	ix.chunk_lo = lo
	ix.next_lo = hi
	ix.chunk_bs = acc.bs != 0
	ix.chunk_wire_ok = simd.reduce_or(acc.utf8_err) == 0 && acc.ctrl == 0
	ix.chunk_scalar_ok = .Scalar_Shape in F && acc.scalar_bad == 0
}
