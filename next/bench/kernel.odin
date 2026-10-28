package bench

// Timings of `core/kernel`, one case per run: `bench <case> <reps> <arg>` prints a sink, the nanoseconds per unit
// and the units per rep, which run.py reads. Cases:
//   pack <per256>   eq and pack per block of an L1-resident buffer, `per256` quotes in 256 bytes, unit: a block.
//   skip <every>    blocks with no quote skipped by `any_lane`, one quote in `every` bytes, unit: a block.
//   tail <len>      quotes counted in inputs of `len` bytes, the last partial block by `load_tail`, unit: an input.

import "base:intrinsics"
import "core:fmt"
import "core:math/bits"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:time"
import k "../core/kernel"

L1_BYTES :: 32 * 1024
SKIP_BYTES :: 1 << 20
TAIL_BYTES :: 1 << 20
TAIL_INPUTS :: 4096

// `p`, read so that the compiler cannot prove it the same in every rep and hoist a rep's work out of the loop.
opaque :: #force_inline proc "contextless" (p: ^[^]u8) -> [^]u8 {
	return intrinsics.volatile_load(p)
}

run_pack :: #force_no_inline proc(buf: []u8, reps: int) -> (sink: u64) {
	p := raw_data(buf)
	for _ in 0 ..< reps {
		q := opaque(&p)
		for i := 0; i < len(buf); i += 64 {
			sink += u64(bits.count_ones(k.pack(k.eq(k.load(q[i:]), '"'))))
		}
	}
	return
}

run_skip :: #force_no_inline proc(buf: []u8, reps: int) -> (sink: u64) {
	p := raw_data(buf)
	for _ in 0 ..< reps {
		q := opaque(&p)
		for i := 0; i < len(buf); i += 64 {
			m := k.eq(k.load(q[i:]), '"')
			if !k.any_lane(m) {
				continue
			}
			for b := k.pack(m); b != 0; b &= b - 1 {
				sink += u64(i) + u64(bits.count_trailing_zeros(b))
			}
		}
	}
	return
}

count_quotes :: #force_inline proc "contextless" (src: []u8) -> (n: u64) {
	lo := 0
	for ; lo + 64 <= len(src); lo += 64 {
		n += u64(bits.count_ones(k.pack(k.eq(k.load(raw_data(src[lo:])), '"'))))
	}
	if lo < len(src) {
		t := k.load_tail(src, lo)
		n += u64(bits.count_ones(k.align(k.pack(k.eq(t.block, '"')), t)))
	}
	return
}

run_tail :: #force_no_inline proc(buf: []u8, starts: []int, n, reps: int) -> (sink: u64) {
	p := raw_data(buf)
	for _ in 0 ..< reps {
		q := opaque(&p)
		for s in starts {
			sink += count_quotes(q[s:][:n])
		}
	}
	return
}

// `buf` filled with lowercase letters and, on average, `per256` quotes in every 256 bytes.
fill :: proc(buf: []u8, per256: int) {
	for &b in buf {
		b = rand.int_max(256) < per256 ? '"' : u8('a' + rand.int_max(26))
	}
}

main :: proc() {
	if len(os.args) != 4 {
		fmt.eprintln("usage: bench pack|skip|tail <reps> <arg>")
		os.exit(2)
	}
	reps, reps_ok := strconv.parse_int(os.args[2])
	arg, arg_ok := strconv.parse_int(os.args[3])
	if !reps_ok || !arg_ok || reps < 1 || arg < 1 {
		fmt.eprintln("reps and arg are positive integers")
		os.exit(2)
	}
	rand.reset(42)
	sink: u64
	units: int
	elapsed: time.Duration
	switch os.args[1] {
	case "pack":
		buf := make([]u8, L1_BYTES)
		fill(buf, arg)
		units = L1_BYTES / 64
		t := time.tick_now()
		sink = run_pack(buf, reps)
		elapsed = time.tick_since(t)
	case "skip":
		buf := make([]u8, SKIP_BYTES)
		fill(buf, 0)
		// Placed at random: at a fixed stride the branch predictor learns which blocks to skip.
		for _ in 0 ..< SKIP_BYTES / arg {
			buf[rand.int_max(SKIP_BYTES)] = '"'
		}
		units = SKIP_BYTES / 64
		t := time.tick_now()
		sink = run_skip(buf, reps)
		elapsed = time.tick_since(t)
	case "tail":
		if arg > TAIL_BYTES {
			fmt.eprintln("tail inputs are at most", TAIL_BYTES, "bytes")
			os.exit(2)
		}
		buf := make([]u8, TAIL_BYTES)
		fill(buf, 16)
		starts := make([]int, TAIL_INPUTS)
		for &s in starts {
			s = rand.int_max(TAIL_BYTES - arg + 1)
		}
		units = TAIL_INPUTS
		t := time.tick_now()
		sink = run_tail(buf, starts, arg, reps)
		elapsed = time.tick_since(t)
	case:
		fmt.eprintln("unknown case", os.args[1])
		os.exit(2)
	}
	fmt.printf("sink=%d ns=%.4f units=%d\n", sink, f64(elapsed) / f64(reps * units), units)
}
