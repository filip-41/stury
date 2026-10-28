# The kernel package

`core/kernel` holds the vector code that every format's scanner is built on. It knows nothing about any formats, it
loads input 64 bytes at a time, compares bytes, sorts them into sets, packs per-byte results into 64-bit masks, follows
quoted strings and runs of bytes across blocks, lists the positions in a mask, and validates UTF-8. A format's walk
calls these kernels in its hot loop and does the rest with scalar bit operations on the masks.

This document explains how the package is split across files and CPUs, and why it has that shape. Most of the shape is
forced by what Odin and LLVM do with vector code: the reasons are here so that a change does not undo one by accident.

## Files

| File | Builds on | Holds |
|---|---|---|
| `kernel.odin` | every target | `Block`, tails, `align`, the nibble table and `classes`, `string_region`, `run_bytes`, `FLATTEN_STEP` |
| `arm64.odin` | arm64 | the block operations on NEON, one 16-byte register at a time |
| `lanes64.odin` | everything but arm64 | the same operations on one 64-lane vector that LLVM splits to the target's width |
| `amd64.odin` | x86-64 | `Tier` with v2, v3 and v4, `tier()`, and the kernels whose instructions differ by tier |
| `single_tier.odin` | everything but x86-64 | `Tier` with one member, and the same tier-dependent kernels in portable or arm64 form |
| `utf8.odin` | every target | UTF-8 validation |

There are two independent splits. The block operations (`load`, `eq`, `below`, `either`, `has`, `pack`, `pack_n`,
`is_ascii`, `any_lane`, `any_below`) split by how the target packs a mask. The kernels that take a tier (`lookup`,
`prefix_xor`, `flatten`, `load_tail`, `load_padded`) split by whether the target has several instruction sets to choose
between at run time. A target with neither NEON nor x86 vectors, such as riscv64, gets `lanes64.odin` and
`single_tier.odin`, which is portable code that LLVM lowers as it can.

Shared code goes in `kernel.odin` and is written once. A file per architecture holds only what has to differ.

## Block

```odin
Block :: [4]#simd[16]u8
```

A block is 64 input bytes, or the 64 lane masks (0x00 or 0xFF) a compare made from them. It is an array of four 16-byte
vectors on every target, not one `#simd[64]u8`.

The reason is the x86 tiers. A caller's hot loop for v4 is compiled with AVX-512, and the kernel it calls, if not
inlined, may be compiled with the build's default features. A 64-lane vector is returned in one zmm register by an
AVX-512 procedure and in four xmm registers by an SSE one, so the two sides read different registers and the block comes
back wrong. An array of 16-byte vectors crosses the call in the same registers on both sides. This only shows where a
kernel is not inlined, which is -o:none and -o:minimal, so the tests run there too.

Inside a kernel the block is reinterpreted as whatever shape suits the work: `W :: #simd[64]u8` in `lanes64.odin`, four
`V :: #simd[16]u8` in `arm64.odin`, or `64 / N` vectors of the tier's register width in `classes` and the UTF-8 code.

## Tiers

x86-64 machines differ in their vector instructions, and one binary has to run on all of them. The package names three
tiers:

| Tier | Instructions | Register |
|---|---|---|
| `.V2` | SSE4.2, SSSE3, POPCNT, PCLMULQDQ | 16 bytes |
| `.V3` | AVX2, BMI2 | 32 bytes |
| `.V4` | AVX-512BW, mask registers | 64 bytes |

`tier()` reads the CPU through `core:sys/info`, which reports AVX and AVX-512 only where the OS saves their registers.
`FEATURES[T]` is the feature string for a tier and `VECTOR_BYTES[T]` its register width. On other targets `Tier` has the
one member `.Base`, `FEATURES[.Base]` is empty and `VECTOR_BYTES[.Base]` is 16, so a caller's code is the same on every
target.

### How a caller uses them

A kernel that depends on the tier takes it as a compile-time parameter, `$T: Tier`. The caller writes its hot loop once,
generic over `$T`, and wraps it in one procedure per tier that carries the tier's features. At run time it calls the
wrapper that `tier()` picks:

```odin
count :: #force_inline proc "contextless" ($T: kernel.Tier, src: []u8, t: kernel.Nibble_Table, bits: u8) -> (n: int) {
	// the loop over blocks, calling kernel.classes(T, ...), kernel.load_tail(T, ...) and the block operations
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

The dispatch is one switch per call of the whole loop, not per block, so it costs nothing measurable. The wrappers are
`#force_no_inline` so that each one stays a separate function with its own features.

The tests and the bench do not dispatch: `-define:TIER=n` picks the tier at place `n` of `Tier`, and every test and
bench loop is compiled with `FEATURES[T]`.

### Why the code has this shape

Each rule below answers something Odin or LLVM does:

- **A tier's instructions live in a small plain procedure with the tier's features** (`lookup_v2`, `lookup_v3`,
  `lookup_v4`, `clmul_prefix_xor`, `masked_tail`, `paged_tail_v3`). The generic kernel (`lookup`) picks one with
  `when T == ...`. LLVM inlines the small procedure into the caller's wrapper, which has the same features.
- **Those procedures are not `#force_inline`.** Odin refuses to force-inline a procedure with target features into one
  without them, and the generic kernels in between have none.
- **The tier's instructions are not written in the generic kernel itself.** Where the generic procedure is not inlined
  (-o:none), LLVM compiles it without the features and fails with "Do not know how to split".
- **The caller writes one wrapper per tier by hand.** `@(enable_target_feature = FEATURES[T])` on a procedure generic
  over `$T` compiles, but ignores `$T` and gives every instance the same features.
- **The small procedures take and return arrays of 16-byte vectors** (`[2]V`, `Block`), for the reason `Block` is an
  array: at -o:none they are real calls across a feature boundary.
- **Feature strings list every feature an intrinsic checks.** Odin's check is literal: `_mm_shuffle_epi8` needs `ssse3`
  named, even though SSE4.2 implies it.
- **v3 and v4 add `-slow-unaligned-mem-32`.** Features add instructions to the build's CPU without changing how LLVM
  tunes for it, and Odin's default CPU, x86-64-v2, splits every unaligned 32-byte load in two.
- **Two shuffles are declared as LLVM intrinsics** (`llvm.x86.avx2.pshuf.b`, `llvm.x86.avx512.pshuf.b.512`).
  `core:simd/x86` in Odin dev-2026-10 lacks them.
- **Kernels that index arrays are `#no_bounds_check`.** The LLVM that dev-2026-10 links keeps a bounds check on indexing
  inside `#unroll` even where the index is a constant.

## The block operations

`lanes64.odin` writes every operation on all 64 lanes at once. LLVM splits a 64-lane vector into four registers on SSE,
two on AVX2 and one on AVX-512. On AVX-512 a compare then writes a mask register and `pack` is one `kmovq` out of it,
where code written 16 lanes at a time would merge four 16-bit masks with ORs. On SSE and AVX2 `pack` is a `pmovmskb` per
register.

`arm64.odin` works one 16-byte register at a time, because NEON has no instruction that gathers the top bit of each
lane. Instead:

- **`pack`** weights each lane by its bit in a byte (1, 2 ... 128) and folds the 64 lanes into 8 bytes with three rounds
  of pairwise adds (`addp`). The bits never overlap, so the adds act as ORs. LLVM's own lowering of the portable
  `extract_msbs` sums each register across its lanes and moves it out on its own, which is slower.
- **The weights are applied with `min`, not `and`.** A lane mask is 0x00 or 0xFF, so both give the same bytes. With
  `and`, LLVM merges the weighting into the compare that made the mask, and `has` becomes and, cmeq and bic per register
  instead of one cmtst.
- **`pack_n`** packs two to four masks with the last round of adds shared between two masks. The walk packs its masks
  together for this reason.
- **`any_lane` and `is_ascii`** reduce with `umaxv`, one instruction per block after the ORs. **`any_below`** reduces
  with `uminv`. On x86 these go through `pack` instead: a packed mask costs one instruction per register, the same as a
  vector test, and x86 has no byte minimum across a register.

## Tier-dependent kernels

**`lookup`** indexes a 16-entry table by the low four bits of each lane: `pshufb` on x86 (16, 32 or 64 bytes at once,
the table repeated in each 16-byte lane), `tbl` on arm64 through `simd.runtime_swizzle`. It is private: callers use it
through `classes` and the UTF-8 code.

**`prefix_xor`** sets bit i where an odd number of the bits at or below i are set. With a block's quotes as input it
gives the bytes inside strings. On x86 it is one carry-less multiplication by all ones (`pclmulqdq`), which every tier
has. On arm64 a ladder of six shifts and XORs is faster than the carry-less multiply (`pmull`), which also needs the
value moved into a vector register and back.

**`flatten`** writes the positions of the set bits of a mask as `u16`s. On x86 it counts trailing zeros (`tzcnt`) and
clears the lowest bit each time. arm64 has no trailing zero count, and LLVM builds one from a bit reversal and a leading
zero count for every position, so the arm64 version reverses the mask once and counts leading zeros from then on. The
x86 stores are volatile only to stop LLVM, in an AVX-512 caller, from turning the counts into a vector popcount
sequence, which is slower. Both versions write positions in steps of `FLATTEN_STEP` slots, whatever the count. The
branch to a second step and the loop after it are then taken alike at sparse and dense rates, instead of a loop exit
that mispredicts once per mask. The cost is that the slots after the last position take junk, so the output buffer must
hold `FLATTEN_STEP` slots past the last position. A mask with very few bits pays for a step it does not fill: for those
a caller can loop on the mask directly.

**`load_tail` and `load_padded`** are below.

## The last partial block

An input rarely ends on a 64-byte boundary. Copying the last bytes into a buffer is slow when inputs are short and many,
so `load_tail` reads them in place where it can.

- **v4** uses a masked load: it reads only the input's bytes, zeros the other lanes and never faults.
- **The other tiers and arm64** use `paged_tail`. A 64-byte load from `lo` stays inside one 4 KiB page unless `lo` lies
  in the page's last 63 bytes. In that case the input itself reaches the next page, so the load that ends at the input's
  end, which starts in `lo`'s page, touches only pages the input touches. Either load may read bytes around the input,
  never a page the input does not touch. 4 KiB is the smallest page of any target. The result's `shift` says which load
  was taken and `live` which lanes are input.

`align(mask, tail)` shifts a mask packed from the tail block into place and clears the bits outside the input. Masks
from a tail go through `align` before anything that carries state from block to block reads them.

The details of `paged_tail`:

- **It is `#force_no_inline`.** Inlined where LLVM can see how large the input's allocation is, a load past its end is
  undefined behaviour, and LLVM deletes the stores that filled the allocation.
- **It is `no_sanitize_address`**, and the load is written in `read_paged_tail` rather than through `load`, so that ASan
  skips it at every optimization level. The read past the end is deliberate.
- **The load goes to a `#simd[64]u8` variable before the `transmute` to `Block`.** Odin folds a transmute of a load into
  a load of `Block` at its own 16-byte alignment, which is an aligned `movaps` on x86 and faults on an unaligned input.
  Rosetta does not fault on it, so the x86 tests under Rosetta cannot catch this.
- **The load is a vector load, not an array load.** Odin lowers an array load to a `memcpy` at -o:none, and ASan checks
  that.
- **v3 has its own copy, `paged_tail_v3`, compiled with AVX2.** The default copy, compiled for v2, stores the block 16
  bytes at a time, and the v3 caller reloads it 32 bytes at a time. A load that spans two stores cannot be forwarded
  from them and waits for both to reach the cache.

`load_padded` gives the tail followed by zeros, for a check that reads every lane, as UTF-8 validation does, where
`align` cannot clear what the lanes outside the input did. v4 uses the masked load, the others copy.

## Byte sets

A scanner needs to know which bytes of a block belong to which sets: JSON's structural characters, its quote and
backslash, whitespace. There are two ways:

- **Compares.** One `eq` per byte value and an `either` to join them. This is cheap for a few values, and it is what CSV
  uses (delimiter, quote, newline).
- **A nibble table.** `nibble_table` builds two 16-byte tables from up to eight sets, and `classes` looks up each byte's
  low and high nibble and ANDs the results. Then `has(c, bits[k])` gives set k's lanes. Each pair of a set and a high
  nibble owns one bit of the table, so membership is exact as long as the sets need at most eight such pairs between
  them. This costs two lookups per register whatever the number of sets, and JSON uses it.

`classes` works one vector register of the tier at a time (16, 32 or 64 bytes), because the lookup is one instruction
per register on every tier.

## Strings and runs

`string_region` takes a block's quote and escape masks and returns the quotes that no escape escapes and the bytes
inside strings, and carries in `String_State` whether the block ended inside a string or in an odd run of escapes. The
escape arithmetic is skipped for blocks without escapes, the common case. `escaped` finds the bytes after odd runs of
escapes with one add per parity, so a run of any length costs the same.

`run_bytes` gives the bytes of the runs in a mask that start at given bits, carrying a run across the block boundary.
Adding a run's first bit carries through the whole run, so the bits the sum clears are the run. A walk takes a span of
any length this way, without a loop per byte.

## UTF-8

`utf8.odin` follows Keiser and Lemire: three 16-entry tables, indexed by the high and low nibble of the byte before and
the high nibble of the byte itself, flag every error a pair of bytes can show. The bytes two and three before a byte say
whether it must be a continuation. A caller checks each block with `utf8_block`, or with `utf8_ascii_block` when
`is_ascii` says the block is all ASCII, and calls `utf8_ok` once at the end.

- **One tier register at a time.** Written on all 64 lanes, the 16-byte tiers keep every step's four registers live at
  once and spill to the stack.
- **`Utf8_State` holds `#simd[64]u8`, not `Block`.** LLVM carries a `Block` from one loop iteration to the next as four
  16-byte values and rebuilds the zmm register from them each time on v4.
- **`before`**, the vector of bytes K before each lane, is an explicit shuffle at 16 lanes and a select of two rotations
  at 32 and 64. At 16 lanes LLVM lowers the shuffle to one `ext`, and the select to an `ext` and a lane insert where the
  previous block comes from the loop before.
- **Errors accumulate** in the first register only, and `utf8_ok` reduces once.

## What the kernels leave to the walk

The kernels stop at masks. Deciding what a mask means, skipping string interiors, finding the end of a value and
building output are the walk's work, in each format's package. Two choices follow from that:

- Quote and escape masks are packed with `eq`, apart from `classes`. A block that lies wholly inside a string and holds
  no quote needs nothing else, so the walk can skip `classes` for it. With quote and escape folded into the nibble
  table, every block would pay for the lookups.
- Which blocks to skip is the walk's decision, so the skip itself is not a kernel.

## Verifying a change

From `next/`:

| Command | What it runs |
|---|---|
| `make test` | the tests on the host at -o:minimal and -o:speed |
| `make test-x86` | v2 and v3 under Rosetta at -o:none and -o:speed, in a build for Odin's default CPU |
| `make test-asan` | the tests under AddressSanitizer |
| `make lint` | vet on the host, x86-64 and riscv64, and a v4 object build at -o:none and -o:speed |
| `make bench TIER=n` | the kernel timings of tier n |

The tests run at -o:none or -o:minimal because the register and call rules above only break where kernels are not
inlined. They run at -o:speed because the optimizer reasons about loads past an input's end. Rosetta runs v2 and v3 but
has no AVX-512, and it does not fault on a misaligned `movaps`, so v4 and the alignment of loads are checked only on a
real x86-64 machine.
