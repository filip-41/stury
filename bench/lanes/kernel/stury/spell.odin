package kernel_bench

// Timings of `core/spell`'s number text, run by kernel.odin's `main`. Cases:
//   float_random, float_canada, float_price, float_int   `f64_text` of random bit patterns, of the coordinates of
//                   canada.json, of two-decimal prices and of integral values, unit: a value. `arg` is unused.
//   int_random <digits>   `u64_text` of random integers of `digits` digits, unit: a value.

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:time"
import "../../../../core/spell"

run_spell :: proc(name: string, reps, arg: int) -> (sink: u64, units: int, elapsed: time.Duration) {
	switch name {
	case "float_random", "float_canada", "float_price", "float_int":
		values: []f64
		if name == "float_canada" {
			values = canada_values()
		} else {
			values = make([]f64, NUMBERS)
			for &v in values {
				r := rand.uint64()
				switch name {
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
	data, err := os.read_entire_file(#directory + "../../../fixtures/corpus/canada.json", context.allocator)
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
