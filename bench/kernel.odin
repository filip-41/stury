package bench

// Timings of `core/kernel` and of `core/spell`'s number text. `bench <case> <reps> <arg>` prints a sink, the nanoseconds
// per unit and the units per rep, which run.py reads. Cases:
//   pack <per256>   eq and pack per block of an L1-resident buffer, with `per256` quotes in 256 bytes, unit: a block.
//   skip <every>    blocks with no quote skipped by `any_lane`, with a quote in `every` bytes, unit: a block.
//   json <per256>   JSON's four sets by the nibble table, packed together, with `per256` of their bytes in 256, unit: a
//                   block.
//   csv <per256>    CSV's three sets by compares, packed together, with `per256` of their bytes in 256, unit: a block.
//   str <every>     the quotes no backslash escapes, by `escaped`, with JSON's 16 bytes in 256 and a backslash in
//                   `every` bytes, unit: a block.
//   utf8 <every>    JSON's sets as in `json`, and UTF-8 checked per block with ASCII blocks skipped, with JSON's 16
//                   bytes in 256 and a three-byte character in `every` bytes, unit: a block.
//   utf8all <every> `utf8` with every block checked in full.
//   float_random, float_canada, float_price, float_int   `f64_text` of random bit patterns, of the coordinates of
//                   canada.json, of two-decimal prices and of integral values, unit: a value. `arg` is unused.
//   int_random <digits>   `u64_text` of random integers of `digits` digits, unit: a value.
// The `json` and `utf8` cases time a table the kernel tests' `nibble_table` builds from JSON's sets. The walk builds
// no such table, it uses compares and its own constant class tables. `-define:TIER=n` times the tier at place n of
// `k.Tier`, with its loops compiled with the tier's features.

import "base:intrinsics"
import "core:fmt"
import "core:math/bits"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:time"
import "../core/spell"
import k "../core/kernel"
import kt "../core/kernel/test"

T :: k.Tier(#config(TIER, 0))

L1_BYTES :: 32 * 1024
SKIP_BYTES :: 1 << 20

// Reads `p` through a volatile load, so the compiler cannot prove it constant and hoist a rep's work out of the loop.
opaque :: #force_inline proc "contextless" (p: ^[^]$T) -> [^]T {
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

// Folds the masks into one word, so every mask reaches the sink.
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
		odd: u64
		for i := 0; i < len(buf); i += 64 {
			b := k.load(q[i:])
			m := k.pack_n([2]k.Block{k.eq(b, '"'), k.eq(b, '\\')})
			sink += m[0] &~ k.escaped(m[1], &odd)
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

// A rep writes `NUMBERS` values in batches that fit L1, each followed by a comma, as a writer lays them out.
NUMBERS :: 1 << 16
BATCH :: 1024

run_floats :: #force_no_inline proc(values: []f64, reps: int) -> (sink: u64) {
	out: [BATCH * (spell.F64_ROOM + 1)]u8
	p := raw_data(values)
	for _ in 0 ..< reps {
		q := opaque(&p)
		for i := 0; i < len(values); i += BATCH {
			w := 0
			for j in i ..< i + BATCH {
				w += spell.f64_text(raw_data(out[w:]), q[j])
				out[w] = ','
				w += 1
			}
			sink += u64(w) + u64(out[w - 2])
		}
	}
	return
}

run_ints :: #force_no_inline proc(values: []u64, reps: int) -> (sink: u64) {
	out: [BATCH * (spell.INT_ROOM + 1)]u8
	p := raw_data(values)
	for _ in 0 ..< reps {
		q := opaque(&p)
		for i := 0; i < len(values); i += BATCH {
			w := 0
			for j in i ..< i + BATCH {
				w += spell.u64_text(raw_data(out[w:]), q[j])
				out[w] = ','
				w += 1
			}
			sink += u64(w) + u64(out[w - 2])
		}
	}
	return
}

// The numbers of canada.json, trimmed to whole batches.
canada_values :: proc() -> []f64 {
	data, err := os.read_entire_file(#directory + "fixtures/corpus/canada.json", context.allocator)
	if err != nil {
		fmt.eprintln("float_canada needs bench/fixtures/corpus/canada.json: run make fixtures")
		os.exit(2)
	}
	is_number_byte :: proc(c: u8) -> bool {
		return c == '-' || c == '.' || c == 'e' || c == 'E' || c == '+' || (c >= '0' && c <= '9')
	}
	values: [dynamic]f64
	text := string(data)
	for i := 0; i < len(text); {
		if text[i] != '-' && (text[i] < '0' || text[i] > '9') {
			i += 1
			continue
		}
		j := i
		for j < len(text) && is_number_byte(text[j]) {
			j += 1
		}
		if f, parsed := strconv.parse_f64(text[i:j]); parsed {
			append(&values, f)
		}
		i = j
	}
	return values[:len(values) / BATCH * BATCH]
}

// Fills `buf` with lowercase letters, and with a byte of `from` at `per256` of 256 positions on average.
fill :: proc(buf: []u8, per256: int, from: string) {
	for &b in buf {
		b = rand.int_max(256) < per256 ? from[rand.int_max(len(from))] : u8('a' + rand.int_max(26))
	}
}

main :: proc() {
	if len(os.args) != 4 {
		fmt.eprintln("usage: bench pack|json|csv|str|utf8|utf8all|skip|float_*|int_random <reps> <arg>")
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
		table, set_bits := kt.nibble_table(json_sets[:])
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
		table, set_bits := kt.nibble_table(json_sets[:])
		buf := make([]u8, L1_BYTES)
		fill(buf, 16, "\"\\,:[]{} \t\n\r")
		for _ in 0 ..< L1_BYTES / arg {
			copy(buf[rand.int_max(L1_BYTES - 2):], "\u20ac")
		}
		units = L1_BYTES / 64
		t := time.tick_now()
		sink = run_utf8(buf, reps, table, set_bits, os.args[1] == "utf8")
		elapsed = time.tick_since(t)
	case "skip":
		buf := make([]u8, SKIP_BYTES)
		fill(buf, 0, "")
		// Places the quotes at random, since at a fixed stride the branch predictor learns which blocks to skip.
		for _ in 0 ..< SKIP_BYTES / arg {
			buf[rand.int_max(SKIP_BYTES)] = '"'
		}
		units = SKIP_BYTES / 64
		t := time.tick_now()
		sink = run_skip(buf, reps)
		elapsed = time.tick_since(t)
	case "float_random", "float_canada", "float_price", "float_int":
		values: []f64
		if os.args[1] == "float_canada" {
			values = canada_values()
		} else {
			values = make([]f64, NUMBERS)
			for &v in values {
				r := rand.uint64()
				switch os.args[1] {
				case "float_random":
					for r >> 52 & 0x7ff == 0x7ff {
						r = rand.uint64()
					}
					v = transmute(f64)r
				case "float_price": v = f64(r % 10_000_000) / 100
				case "float_int": v = f64(r % 1_000_000)
				}
			}
		}
		units = len(values)
		t := time.tick_now()
		sink = run_floats(values, reps)
		elapsed = time.tick_since(t)
	case "int_random":
		if arg > 19 {
			fmt.eprintln("int_random takes 1 to 19 digits")
			os.exit(2)
		}
		low := u64(1)
		for _ in 1 ..< arg {
			low *= 10
		}
		values := make([]u64, NUMBERS)
		for &v in values {
			v = low + rand.uint64() % (9 * low)
		}
		units = len(values)
		t := time.tick_now()
		sink = run_ints(values, reps)
		elapsed = time.tick_since(t)
	case:
		fmt.eprintln("unknown case", os.args[1])
		os.exit(2)
	}
	fmt.printf("sink=%d ns=%.4f units=%d\n", sink, f64(elapsed) / f64(reps * units), units)
}
