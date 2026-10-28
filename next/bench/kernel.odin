package bench

// Timings of `core/kernel`, one case per run: `bench <case> <reps> <arg>` prints a sink, the nanoseconds per unit
// and the units per rep, which run.py reads. Cases:
//   pack <per256>   eq and pack per block of an L1-resident buffer, `per256` quotes in 256 bytes, unit: a block.
//   skip <every>    blocks with no quote skipped by `any_lane`, one quote in `every` bytes, unit: a block.
//   json <per256>   JSON's four sets by the nibble table, packed together, `per256` of their bytes in 256, unit: a block.
//   csv <per256>    CSV's three sets by compares, packed together, `per256` of their bytes in 256, unit: a block.
//   str <every>     unescaped quotes and string bytes by `string_region`, JSON's bytes 16 in 256 and one backslash in
//                   `every` bytes, unit: a block.
//   utf8 <every>    JSON's sets as in `json`, and UTF-8 checked per block, ASCII blocks skipped, JSON's bytes 16 in 256
//                   and one three-byte character in `every` bytes, unit: a block.
//   utf8all <every> `utf8`, every block checked in full.
//   flatten <per256> the positions of the quotes listed by `flatten`, `per256` quotes in 256 bytes, unit: a block.
//   tail <len>      quotes counted in inputs of `len` bytes, the last partial block by `load_tail`, unit: an input.
// `-define:TIER=n` times the tier at place n of `k.Tier`, its loops compiled with the tier's features.

import "base:intrinsics"
import "core:fmt"
import "core:math/bits"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:time"
import k "../core/kernel"

T :: k.Tier(#config(TIER, 0))

L1_BYTES :: 32 * 1024
SKIP_BYTES :: 1 << 20
TAIL_BYTES :: 1 << 20
TAIL_INPUTS :: 4096

// `p`, read so that the compiler cannot prove it the same in every rep and hoist a rep's work out of the loop.
opaque :: #force_inline proc "contextless" (p: ^[^]u8) -> [^]u8 {
	return intrinsics.volatile_load(p)
}

@(enable_target_feature = k.FEATURES[T])
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

@(enable_target_feature = k.FEATURES[T])
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

JSON_SETS :: [4]string{"\"", "\\", ",:[]{}", " \t\n\r"}
CSV_BYTES :: ",\"\n\r"

// The masks folded into one word, so that every mask reaches the sink.
mix :: #force_inline proc "contextless" (m: [$N]u64) -> (x: u64) {
	#unroll for i in 0 ..< N {
		x ~= bits.rotate_left64(m[i], 16 * i)
	}
	return
}

@(enable_target_feature = k.FEATURES[T])
run_json :: #force_no_inline proc(buf: []u8, reps: int, t: k.Nibble_Table, s: [8]u8) -> (sink: u64) {
	p := raw_data(buf)
	for _ in 0 ..< reps {
		q := opaque(&p)
		for i := 0; i < len(buf); i += 64 {
			c := k.classes(T, k.load(q[i:]), t)
			sink += mix(k.pack_n([4]k.Block{k.has(c, s[0]), k.has(c, s[1]), k.has(c, s[2]), k.has(c, s[3])}))
		}
	}
	return
}

@(enable_target_feature = k.FEATURES[T])
run_csv :: #force_no_inline proc(buf: []u8, reps: int) -> (sink: u64) {
	p := raw_data(buf)
	for _ in 0 ..< reps {
		q := opaque(&p)
		for i := 0; i < len(buf); i += 64 {
			b := k.load(q[i:])
			sink += mix(k.pack_n([3]k.Block{k.eq(b, ','), k.eq(b, '"'), k.either(k.eq(b, '\n'), k.eq(b, '\r'))}))
		}
	}
	return
}

@(enable_target_feature = k.FEATURES[T])
run_str :: #force_no_inline proc(buf: []u8, reps: int) -> (sink: u64) {
	p := raw_data(buf)
	for _ in 0 ..< reps {
		q := opaque(&p)
		s: k.String_State
		for i := 0; i < len(buf); i += 64 {
			b := k.load(q[i:])
			m := k.pack_n([2]k.Block{k.eq(b, '"'), k.eq(b, '\\')})
			quotes, inside := k.string_region(T, m[0], m[1], &s)
			sink += quotes ~ inside
		}
	}
	return
}

@(enable_target_feature = k.FEATURES[T])
run_utf8 :: #force_no_inline proc(buf: []u8, reps: int, t: k.Nibble_Table, s: [8]u8, skip_ascii: bool) -> (sink: u64) {
	p := raw_data(buf)
	for _ in 0 ..< reps {
		q := opaque(&p)
		u: k.Utf8_State
		for i := 0; i < len(buf); i += 64 {
			b := k.load(q[i:])
			c := k.classes(T, b, t)
			sink += mix(k.pack_n([4]k.Block{k.has(c, s[0]), k.has(c, s[1]), k.has(c, s[2]), k.has(c, s[3])}))
			if skip_ascii && k.is_ascii(b) {
				k.utf8_ascii_block(T, &u)
			} else {
				k.utf8_block(T, b, &u)
			}
		}
		sink += u64(k.utf8_ok(u))
	}
	return
}

@(enable_target_feature = k.FEATURES[T])
run_flatten :: #force_no_inline proc(buf: []u8, out: []u16, reps: int) -> (sink: u64) {
	p := raw_data(buf)
	for _ in 0 ..< reps {
		q := opaque(&p)
		n := 0
		for i := 0; i < len(buf); i += 64 {
			n = k.flatten(raw_data(out), n, k.pack(k.eq(k.load(q[i:]), '"')), u16(i))
		}
		sink += u64(n) + u64(out[n / 2])
	}
	return
}

count_quotes :: #force_inline proc "contextless" (src: []u8) -> (n: u64) {
	lo := 0
	for ; lo + 64 <= len(src); lo += 64 {
		n += u64(bits.count_ones(k.pack(k.eq(k.load(raw_data(src[lo:])), '"'))))
	}
	if lo < len(src) {
		t := k.load_tail(T, src, lo)
		n += u64(bits.count_ones(k.align(k.pack(k.eq(t.block, '"')), t)))
	}
	return
}

@(enable_target_feature = k.FEATURES[T])
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

// `buf` filled with lowercase letters and, on average, `per256` bytes of `from` in every 256 bytes.
fill :: proc(buf: []u8, per256: int, from: string) {
	for &b in buf {
		b = rand.int_max(256) < per256 ? from[rand.int_max(len(from))] : u8('a' + rand.int_max(26))
	}
}

main :: proc() {
	if len(os.args) != 4 {
		fmt.eprintln("usage: bench pack|json|csv|str|utf8|utf8all|flatten|skip|tail <reps> <arg>")
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
	case "pack", "json", "csv":
		json_sets := JSON_SETS
		table, set_bits := k.nibble_table(json_sets[:])
		buf := make([]u8, L1_BYTES)
		fill(buf, arg, os.args[1] == "pack" ? "\"" : os.args[1] == "json" ? "\"\\,:[]{} \t\n\r" : CSV_BYTES)
		units = L1_BYTES / 64
		t := time.tick_now()
		switch os.args[1] {
		case "pack": sink = run_pack(buf, reps)
		case "json": sink = run_json(buf, reps, table, set_bits)
		case "csv": sink = run_csv(buf, reps)
		}
		elapsed = time.tick_since(t)
	case "str":
		buf := make([]u8, L1_BYTES)
		fill(buf, 16, "\"\",:[]{} \t\n\r")
		for _ in 0 ..< L1_BYTES / arg {
			buf[rand.int_max(L1_BYTES)] = '\\'
		}
		units = L1_BYTES / 64
		t := time.tick_now()
		sink = run_str(buf, reps)
		elapsed = time.tick_since(t)
	case "utf8", "utf8all":
		json_sets := JSON_SETS
		table, set_bits := k.nibble_table(json_sets[:])
		buf := make([]u8, L1_BYTES)
		fill(buf, 16, "\"\\,:[]{} \t\n\r")
		for _ in 0 ..< L1_BYTES / arg {
			copy(buf[rand.int_max(L1_BYTES - 2):], "\u20ac")
		}
		units = L1_BYTES / 64
		t := time.tick_now()
		sink = run_utf8(buf, reps, table, set_bits, os.args[1] == "utf8")
		elapsed = time.tick_since(t)
	case "flatten":
		buf := make([]u8, L1_BYTES)
		fill(buf, arg, "\"")
		out := make([]u16, L1_BYTES + k.FLATTEN_STEP)
		units = L1_BYTES / 64
		t := time.tick_now()
		sink = run_flatten(buf, out, reps)
		elapsed = time.tick_since(t)
	case "skip":
		buf := make([]u8, SKIP_BYTES)
		fill(buf, 0, "")
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
		fill(buf, 16, "\"")
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
