# The kernel package

`core/kernel` is the vector code every format's scanner uses. It has no format knowledge. It loads input 64 bytes at a
time, compares bytes, sorts them into sets, packs per-byte results into 64-bit masks, finds the bytes an escape
escapes, and validates UTF-8. A walk calls these where it reads a block at a time and uses scalar bit operations on the
masks for the rest. `walk.md` describes the walks.

## Layout

The kernels are written once for every target except where the instructions differ. Two things vary:

- **How the target packs a mask.** The block operations (`load`, `eq`, `pack`, `pack_n`, `is_ascii`, `all_zero`,
  `first_lane16`) have one form for arm64, which works on four NEON registers, and one for everything else, which works
  on a single 64-lane vector that LLVM splits to the target's width. `below`, `either` and `has` are written on 64
  lanes for every target, since LLVM splits them to NEON registers as well as code written one register at a time.
- **Whether the target has more than one instruction set to choose at run time.** On x86-64 the kernels that take a tier
  (`lookup`, `load_padded`, the scan loops) have a form per tier. Elsewhere `Tier` has one member and the same kernels
  are portable or arm64 code. A target with neither NEON nor x86 vectors, such as riscv64, gets the portable forms.

The kernels fall in groups: block loads and compares, the tier-dependent lookups, byte-set classification, escape and
quote scanning, UTF-8 validation, and `compress`, which gathers the lanes a mask keeps.

## Block

```odin
Block :: [4]#simd[16]u8
```

A block is 64 input bytes, or the 64 lane masks (0x00 or 0xFF) a compare made from them. On every target it is an array
of four 16-byte vectors, not a `#simd[64]u8`.

The x86 tiers require the array. A caller's hot loop for `.V4` is compiled with AVX-512, and a kernel it calls without
inlining may be compiled with the build's default features. A procedure compiled with AVX-512 returns a 64-lane vector
in one zmm register, and one compiled for SSE returns it in four xmm registers, so the two sides read different
registers. An array of 16-byte vectors crosses the call in the same registers on both sides. The difference appears only
where a kernel is not inlined, at `-o:none` and `-o:minimal`, so the tests run at those levels.

Inside a kernel the block is reinterpreted as the shape the work needs: one 64-lane vector on x86 and portable targets,
four 16-byte vectors on arm64, or vectors of the tier's register width in `classes` and the UTF-8 code.

## Tiers

A binary must run on every x86-64 machine, and the machines differ in vector instructions. The package names three
tiers:

| Tier | Instructions | Register |
|---|---|---|
| `.V2` | SSE4.2, SSSE3, POPCNT (x86-64-v2, the floor) | 16 bytes |
| `.V3` | AVX2, BMI2, PCLMULQDQ | 32 bytes |
| `.V4` | AVX-512 (F, BW, VL), mask registers | 64 bytes |

`tier()` reads the CPU through `core:sys/info`, which reports AVX and AVX-512 only where the OS saves their registers.
`FEATURES[T]` is the feature string for a tier and `VECTOR_BYTES[T]` its register width. On other targets `Tier` has one
member, `.Base`, so a caller's code is the same on every target.

`-define:TIER=n` makes `tier()` return the tier at index `n` of `Tier`. The kernel tests and the bench do not dispatch:
the same define picks their tier, and every test and bench loop is compiled with `FEATURES[T]`.

### Calling a kernel

A kernel that depends on the tier takes it as a compile-time parameter, `$T: Tier`. The caller writes its hot loop once,
generic over `$T`, wraps it in a procedure per tier that carries the tier's features, and at run time calls the wrapper
`tier()` returns:

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

The switch runs once per call of the loop, not per block. `#force_no_inline` keeps each wrapper a separate function with
its own features. The dsv pass and the JSON block string reader have this shape, and so do the scan loops.

### Rules behind the shape

Each rule works around a behaviour of Odin or LLVM.

- **A tier's instructions are in a small plain procedure carrying the tier's features** (`lookup_v2`, `lookup_v3`,
  `lookup_v4` and the like). The generic kernel (`lookup`) picks one with `when T == ...`, and LLVM inlines the small
  procedure into the caller's wrapper, which has the same features.
- **Those procedures are not `#force_inline`.** Odin refuses to force-inline a procedure with target features into one
  without them, and the generic kernels in between have none.
- **The tier's instructions are not written in the generic kernel itself.** Where the generic procedure is not inlined
  (`-o:none`), LLVM compiles it without the features and fails with "Do not know how to split".
- **The caller writes a wrapper per tier by hand.** `@(enable_target_feature = FEATURES[T])` on a procedure generic over
  `$T` compiles but ignores `$T`, and gives every instance the same features.
- **The small procedures take and return 16-byte vectors and arrays of them**, for the reason `Block` is an array: at
  `-o:none` they are real calls across a feature boundary.
- **Feature strings list every feature an intrinsic checks.** Odin's check is literal: `_mm_shuffle_epi8` needs `ssse3`
  named, even though SSE4.2 implies it.
- **`.V3` and `.V4` add `-slow-unaligned-mem-32`.** Features add instructions to the build's CPU without changing how
  LLVM tunes for it, and Odin's default CPU, x86-64-v2, splits every unaligned 32-byte load in two.
- **The 64-byte shuffle is declared as an LLVM intrinsic** (`llvm.x86.avx512.pshuf.b.512`), because `core:simd/x86`
  lacks it.
- **Only `live16` and `compress` are `#no_bounds_check`.** Their table indices are computed at run time. A constant
  index, as `#unroll` gives, and a multi-pointer index carry no check.

## Block operations

On every target but arm64 each operation is written on all 64 lanes at once. LLVM splits a 64-lane vector into four registers on
SSE, two on AVX2 and one on AVX-512. On AVX-512 a compare writes a mask register and `pack` moves it out with one
`kmovq`, where code written at 16 lanes would merge four 16-bit masks with ORs. On SSE and AVX2 `pack` is one `pmovmskb`
per register.

On arm64 each operation works one 16-byte register at a time, because NEON has no instruction that gathers the top bit of each
lane:

- **`pack`** weights each lane by its bit in a byte (1 to 128) and folds the 64 lanes into 8 bytes with three rounds of
  pairwise adds (`addp`). The bits do not overlap, so the adds act as ORs. The weights are applied with `min`, not
  `and`: with `and`, LLVM merges the weighting into the compare that made the mask, and `has` becomes three
  instructions per register instead of one `cmtst`.
- **`pack_n`** packs two to four masks and shares the last round of adds between two masks. The walks pack their masks
  together for this reason.
- **`is_ascii`** reduces with `umaxv` on arm64. On x86 it tests the packed top bits, since an OR or max reduction is a
  shuffle tree there.
- **`first_lane16`** finds the first set lane of one 16-byte mask, for a reader that looks at a short span before it
  takes a whole block. NEON has no `pmovmskb`, so a narrowing shift (`shrn`) keeps four bits per lane and the trailing
  zero count is divided by four.

### compress

`compress` stores the lanes of a block that a 64-bit mask keeps, in order, and returns how many. It stores up to 64
bytes from its start. Per 8 lanes it makes one table shuffle half (`KEEP_LANES`, the positions of an 8-bit mask's set
bits) and one 8-byte store, and one vector popcount gives the eight counts. The shuffle is `lookup` at its 16-byte
width on every tier, since `vpcompressb` needs VBMI2, which `.V4` does not promise.

## Tier-dependent kernels

- **`lookup`** indexes a 16-entry table by the low four bits of each lane: `pshufb` on x86 (16, 32 or 64 bytes at once,
  the table repeated in each 16-byte lane), `tbl` on arm64. It is private. Callers use it through `classes` and the
  UTF-8 code.
- **`prefix_xor`** returns a mask with bit i set when an odd number of bits at or below i are set. Given a block's quote
  bits, the set bits are the bytes inside the strings. On `.V3` and `.V4` it is a carry-less multiplication by all ones
  (`pclmulqdq`). x86-64-v2 has no carry-less multiply, so `.V2` uses six shifts and XORs, as arm64 does to avoid `pmull`.
- **`load_padded`** returns the bytes from `lo` to the input's end followed by zeros, for a check that reads every lane,
  as UTF-8 validation does. `.V4` uses a masked load, which reads only the input's bytes and does not fault on bytes
  past the end. The other tiers copy the bytes into a zeroed buffer.

## Byte sets

A scanner maps the bytes of a block to sets, such as JSON's structural characters, its quote and backslash, and
whitespace. It has two ways:

- **Compares.** One `eq` per byte value, joined with `either`. A small number of byte values avoids building a nibble
  table. dsv uses this form for delimiter, quote, newline and backslash.
- **A nibble table.** `Nibble_Table` is two 16-byte tables that sort bytes into up to 8 sets. `classes` looks up each
  byte's low and high nibble and ANDs the results, then `has(c, bits[k])` gives set k's lanes. Each pair of a set and a
  high nibble owns one bit of the table, so membership is exact while the sets need at most 8 such pairs between them.
  The cost is two lookups per register whatever the number of sets. The walks use constant tables: JSON's escape and
  surrogate classes, dsv's escape letters and HTML's tokenizer.

`classes` works one vector register of the tier at a time (16, 32 or 64 bytes), because the lookup is one instruction per
register on every tier.

## Escapes

`escaped` reads a block's escape mask and returns a mask of the bytes after odd runs of escapes, and carries through
`odd` whether this block ended in such a run. One subtract borrows through every run at once, as in simdjson's escape
scanner, so a run of any length uses the same number of instructions, and the carry into the next block passes through
no add.

## UTF-8

UTF-8 validation follows Keiser and Lemire: three 16-entry tables, indexed by the high and low nibble of the byte before and
the high nibble of the byte itself, flag every error a pair of bytes can show. The bytes two and three before a byte say
whether it must be a continuation.

A caller passes each block to `utf8_next`, skips an ASCII block after an ASCII block since it adds no error, and calls
`utf8_ok` once at the end. A reader that stops inside a block, at a string's closing quote, calls `utf8_stop`, which
allows a sequence the last block leaves open, because the bytes past the stop are not the reader's to judge.

- **Validation works one register of the tier at a time.** Written on all 64 lanes, the 16-byte tiers keep four registers
  live at each step and spill to the stack.
- **`Utf8_State` holds `#simd[64]u8`, not `Block`.** LLVM carries a `Block` from one loop iteration to the next as four
  16-byte values and rebuilds the zmm register from them each time on `.V4`.
- **Errors accumulate** in the first register only, and `utf8_ok` reduces once.

## What a walk keeps

The kernels produce masks and no more. Interpreting a mask, skipping string interiors, finding the end of a value and
building output belong to each format's walk. Quote and escape masks come from `eq`, not from `classes`: a block wholly
inside a string with no quote needs no other test, so the walk can skip `classes` for it, and folding quote and escape
into the nibble table would add the lookups to every block.

## Verifying a change

From the repository root:

| Command | What it runs |
|---|---|
| `make test-lib` | the library suites on the host at `-o:minimal` and `-o:speed` |
| `make test-x86` | v2 and v3 under Rosetta at `-o:none` and `-o:speed`, in a build for Odin's default CPU |
| `make test-wide` | every tier on a machine that lacks it, under Intel SDE |
| `make test-asan` | the library suites and the command line under AddressSanitizer |
| `make lint` | vet on the host, x86-64 and riscv64, and a v4 object build of the kernel tests at `-o:none` and `-o:speed` |
| `make bench TIER=n` | the kernel timings of tier n |

The tests run at `-o:none` or `-o:minimal` because the register and call rules above break only where kernels are not
inlined. They also run at `-o:speed` because the optimizer reasons about loads past an input's end. Rosetta runs v2 and
v3 and has no AVX-512, and it does not fault on a misaligned `movaps`, so v4 and load alignment are checked only on a
real x86-64 machine.
