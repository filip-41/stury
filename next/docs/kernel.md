# The kernel package

`core/kernel` holds the vector code that every format's scanner uses. The package has no format knowledge: it loads
input 64 bytes at a time, compares bytes, sorts them into sets, packs per-byte results into 64-bit masks, finds the
bytes an escape escapes, and validates UTF-8. A format's walk calls these kernels where it reads a block at a time and
uses scalar bit operations on the masks for everything else.

This document describes how the package is split across files and CPUs, and the Odin and LLVM behaviour that each
part of the shape works around.

## Files

| File | Builds on | Holds |
|---|---|---|
| `kernel.odin` | every target | `Block`, the copied tail, the nibble table and `classes`, `escaped` |
| `arm64.odin` | arm64 | the block operations on NEON, one 16-byte register at a time |
| `lanes64.odin` | everything but arm64 | the same operations on one 64-lane vector that LLVM splits to the target's width |
| `amd64.odin` | x86-64 | `Tier` with v2, v3 and v4, `tier()`, and the kernels whose instructions differ by tier |
| `single_tier.odin` | everything but x86-64 | `Tier` with one member, and the same tier-dependent kernels in portable or arm64 form |
| `utf8.odin` | every target | UTF-8 validation |

The package splits in two independent ways. The block operations (`load`, `eq`, `below`, `either`, `has`, `pack`,
`pack_n`, `is_ascii`, `any_lane`, `first_lane`) split by how the target packs a mask. The kernels that take a tier
(`lookup`, `prefix_xor`, `load_padded`) split by whether the target has more than one instruction set to choose at run
time. A target with neither NEON nor x86 vectors, such as riscv64, builds `lanes64.odin` and `single_tier.odin`,
portable code that LLVM lowers to the target.

Shared code is in `kernel.odin`. Each architecture file holds only what differs.

## Block

```odin
Block :: [4]#simd[16]u8
```

A block is 64 input bytes, or the 64 lane masks (0x00 or 0xFF) a compare made from them. On every target it is an array
of four 16-byte vectors, not a `#simd[64]u8`.

The x86 tiers require the array. A caller's hot loop for v4 is compiled with AVX-512, and a kernel it calls without
inlining may be compiled with the build's default features. A procedure compiled with AVX-512 returns a 64-lane vector
in one zmm register, and one compiled for SSE returns it in four xmm registers, so the two sides read different
registers and the block is wrong. An array of 16-byte vectors crosses the call in the same registers on both sides.
This difference appears only where a kernel is not inlined, at -o:none and -o:minimal, so the tests run at those
levels.

Inside a kernel the block is reinterpreted as the shape the work needs: `W :: #simd[64]u8` in `lanes64.odin`, four
`V :: #simd[16]u8` in `arm64.odin`, or `64 / N` vectors of the tier's register width in `classes` and the UTF-8 code.

## Tiers

x86-64 machines differ in their vector instructions, and a binary must run on all of them. The package names three
tiers:

| Tier | Instructions | Register |
|---|---|---|
| `.V2` | SSE4.2, SSSE3, POPCNT, PCLMULQDQ | 16 bytes |
| `.V3` | AVX2, BMI2 | 32 bytes |
| `.V4` | AVX-512BW, mask registers | 64 bytes |

`tier()` reads the CPU through `core:sys/info`, which reports AVX and AVX-512 only where the OS saves their registers.
`FEATURES[T]` is the feature string for a tier and `VECTOR_BYTES[T]` its register width. On other targets `Tier` has a
single member, `.Base`, `FEATURES[.Base]` is empty and `VECTOR_BYTES[.Base]` is 16, so a caller's code is the same on
every target.

### How a caller uses them

A kernel that depends on the tier takes it as a compile-time parameter, `$T: Tier`. The caller writes its hot loop
once, generic over `$T`, and wraps it in a procedure per tier that carries the tier's features. At run time it calls
the wrapper `tier()` returns:

```odin
count :: #force_inline proc "contextless" ($T: kernel.Tier, src: []u8, t: kernel.Nibble_Table, bits: u8) -> (n: int) {
	// the loop over blocks, calling kernel.classes(T, ...), kernel.load_padded(T, ...) and the block operations
}

when ODIN_ARCH == .amd64 {
	@(enable_target_feature = kernel.FEATURES[.V2])
	count_v2 :: #force_no_inline proc "contextless" (src: []u8, t: kernel.Nibble_Table, bits: u8) -> int {
		return count(.V2, src, t, bits)
	}
	// count_v3 and count_v4 alike

	count_any :: proc(src: []u8, t: kernel.Nibble_Table, bits: u8) -> int {
		switch kernel.tier() {
		case .V4: return count_v4(src, t, bits)
		case .V3: return count_v3(src, t, bits)
		case .V2: return count_v2(src, t, bits)
		}
		unreachable()
	}
} else {
	count_any :: proc(src: []u8, t: kernel.Nibble_Table, bits: u8) -> int {
		return count(.Base, src, t, bits)
	}
}
```

The switch runs once per call of the whole loop, not per block. `#force_no_inline` keeps each wrapper a separate
function with its own features.

The tests and the bench do not dispatch: `-define:TIER=n` picks the tier at index `n` of `Tier`, and every test and
bench loop is compiled with `FEATURES[T]`.

### Why the code has this shape

Each rule below works around a behaviour of Odin or LLVM:

- **A tier's instructions are in a small plain procedure carrying the tier's features** (`lookup_v2`, `lookup_v3`,
  `lookup_v4`, `clmul_prefix_xor`, `masked_tail`). The generic kernel (`lookup`) picks one with `when T == ...`.
  LLVM inlines the small procedure into the caller's wrapper, which has the same features.
- **Those procedures are not `#force_inline`.** Odin refuses to force-inline a procedure with target features into one
  without them, and the generic kernels in between have none.
- **The tier's instructions are not written in the generic kernel itself.** Where the generic procedure is not
  inlined (-o:none), LLVM compiles it without the features and fails with "Do not know how to split".
- **The caller writes a wrapper per tier by hand.** `@(enable_target_feature = FEATURES[T])` on a procedure generic
  over `$T` compiles, but ignores `$T` and gives every instance the same features.
- **The small procedures take and return 16-byte vectors and arrays of them** (`V`, `[2]V`, `Block`), for the reason
  `Block` is an array: at -o:none they are real calls across a feature boundary.
- **Feature strings list every feature an intrinsic checks.** Odin's check is literal: `_mm_shuffle_epi8` needs
  `ssse3` named, even though SSE4.2 implies it.
- **v3 and v4 add `-slow-unaligned-mem-32`.** Features add instructions to the build's CPU without changing how LLVM
  tunes for it, and Odin's default CPU, x86-64-v2, splits every unaligned 32-byte load in two.
- **Two shuffles are declared as LLVM intrinsics** (`llvm.x86.avx2.pshuf.b`, `llvm.x86.avx512.pshuf.b.512`).
  `core:simd/x86` in Odin dev-2026-10 lacks them.
- **Kernels that index arrays are `#no_bounds_check`.** The LLVM that dev-2026-10 links keeps a bounds check on
  indexing inside `#unroll` even where the index is a constant.

## The block operations

`lanes64.odin` writes each operation on all 64 lanes at once. LLVM splits a 64-lane vector into four registers on SSE,
two on AVX2 and one on AVX-512. On AVX-512 a compare writes a mask register and `pack` moves it out with one `kmovq`,
where code written at 16 lanes would merge four 16-bit masks with ORs. On SSE and AVX2 `pack` is one `pmovmskb` per
register.

`arm64.odin` works one 16-byte register at a time, because NEON has no instruction that gathers the top bit of each
lane. Instead:

- **`pack`** weights each lane by its bit in a byte (1 to 128) and folds the 64 lanes into 8 bytes with three rounds
  of pairwise adds (`addp`). The bits do not overlap, so the adds act as ORs. LLVM's own lowering of the portable
  `extract_msbs` sums each register across its lanes and moves each out separately, which takes more instructions.
- **The weights are applied with `min`, not `and`.** A lane mask is 0x00 or 0xFF, so both give the same bytes. With
  `and`, LLVM merges the weighting into the compare that made the mask, and `has` becomes and, cmeq and bic per
  register instead of one cmtst.
- **`pack_n`** packs two to four masks, sharing the last round of adds between two masks. The walk packs its masks
  together for this reason.
- **`any_lane` and `is_ascii`** reduce with `umaxv`, one instruction per block after the ORs. On x86 `any_lane` uses
  `pack` instead, since a packed mask uses one instruction per register, the same as a vector test.
- **`first_lane`** finds the first set lane of one 16-byte mask, for a reader that looks at a short span before it
  takes a whole block. x86 gathers one bit per lane with `pmovmskb`. NEON has no such instruction, so a narrowing
  shift (`shrn`) keeps four bits per lane and the trailing zero count is divided by four.

## Tier-dependent kernels

**`lookup`** indexes a 16-entry table by the low four bits of each lane: `pshufb` on x86 (16, 32 or 64 bytes at once,
the table repeated in each 16-byte lane), `tbl` on arm64 through `simd.runtime_swizzle`. It is private: callers use it
through `classes` and the UTF-8 code.

**`prefix_xor`** returns a mask with bit i set when an odd number of bits at or below i are set. Given a block's quote
bits, the set bits are the bytes inside the strings. On x86 it is a carry-less multiplication by all ones
(`pclmulqdq`), which every tier has. On arm64 six shifts and XORs avoid the carry-less multiply (`pmull`), which also
needs the value moved into a vector register and back.

**`load_padded`** is below.

## The last partial block

An input rarely ends on a 64-byte boundary. `load_padded` returns the bytes from `lo` to the input's end followed by
zeros, for a check that reads every lane, as UTF-8 validation does. v4 uses a masked load, which reads only the
input's bytes, zeroes the other lanes and does not fault on bytes past the end. The other x86 tiers and arm64 copy the
bytes into a zeroed buffer.

## Byte sets

A scanner maps the bytes of a block to sets, such as JSON's structural characters, its quote and backslash, and
whitespace. It has two ways:

- **Compares.** One `eq` per byte value joined with `either`. A small number of byte values avoids building a nibble
  table, and CSV uses this form for delimiter, quote and newline.
- **A nibble table.** `nibble_table` builds two 16-byte tables from up to 8 sets, and `classes` looks up each byte's
  low and high nibble and ANDs the results. Then `has(c, bits[k])` gives set k's lanes. Each pair of a set and a high
  nibble owns one bit of the table, so membership is exact while the sets need at most 8 such pairs between them. The
  cost is two lookups per register whatever the number of sets. Only the bench and the kernel tests call
  `nibble_table`. The walk's escape and surrogate classes are constant tables passed to `classes`.

`classes` works one vector register of the tier at a time (16, 32 or 64 bytes), because the lookup is one instruction
per register on every tier.

## Escapes

`escaped` reads a block's escape mask and returns a mask of the bytes after odd runs of escapes, and carries through
`odd` whether this block ended in such a run. It uses one add per parity, so a run of any length uses the same number
of instructions.

## UTF-8

`utf8.odin` follows Keiser and Lemire: three 16-entry tables, indexed by the high and low nibble of the byte before and
the high nibble of the byte itself, flag every error a pair of bytes can show. The bytes two and three before a byte
say whether it must be a continuation. A caller checks each block with `utf8_block`, or with `utf8_ascii_block` when
`is_ascii` says the block is all ASCII, and calls `utf8_ok` once at the end. A reader that stops inside a block, at a
string's closing quote, calls `utf8_clean` instead, which allows a sequence the last block leaves open because the
bytes past the stop are not the reader's to judge.

- **Validation works one register of the tier at a time.** Written on all 64 lanes, the 16-byte tiers keep four
  registers live at each step and spill to the stack.
- **`Utf8_State` holds `#simd[64]u8`, not `Block`.** LLVM carries a `Block` from one loop iteration to the next as four
  16-byte values and rebuilds the zmm register from them each time on v4.
- **`before`**, the vector of bytes K before each lane, is an explicit shuffle at 16 lanes and a select of two rotations
  at 32 and 64. At 16 lanes LLVM lowers the shuffle to one `ext`, and the select to an `ext` and a lane insert where the
  previous block comes from the loop before.
- **Errors accumulate** in the first register only, and `utf8_ok` reduces once.

## Work left in each format's walk

The kernels produce masks and no more. Interpreting a mask, skipping string interiors, finding the end of a value and
building output belong to each format's walk. Two choices follow:

- Quote and escape masks come from `eq`, not from `classes`. A block wholly inside a string with no quote needs no
  other test, so the walk can skip `classes` for it. Folding quote and escape into the nibble table would add the
  lookups to every block.
- The walk decides which blocks to skip, so the skip is not a kernel.

## Verifying a change

From `next/`:

| Command | What it runs |
|---|---|
| `make test` | the tests on the host at -o:minimal and -o:speed |
| `make test-x86` | v2 and v3 under Rosetta at -o:none and -o:speed, in a build for Odin's default CPU |
| `make test-asan` | the tests under AddressSanitizer |
| `make lint` | vet on the host, x86-64 and riscv64, and a v4 object build at -o:none and -o:speed |
| `make bench TIER=n` | the kernel timings of tier n |

The tests run at -o:none or -o:minimal because the register and call rules above break only where kernels are not
inlined. They also run at -o:speed because the optimizer reasons about loads past an input's end. Rosetta runs v2 and
v3 and has no AVX-512, and it does not fault on a misaligned `movaps`, so v4 and load alignment are checked only on a
real x86-64 machine.
