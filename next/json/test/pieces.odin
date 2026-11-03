package json_tests

import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import host "../../host"
import typed "../../core/typed"
import records "../../core/records"
import json ".."
import walktest "../../walktest"

// A text read in pieces on threads against the same text read on one: the same faults at the same bytes, at every
// width. The tests build pieces of one byte, so every byte is a cut.

@(private = "file")
WIDTHS :: [?]int{1, 2, 6, 18}

@(private = "file")
whole_fault :: proc(src: []u8, spec: json.Spec) -> Maybe(core.Fault) {
	switch spec {
	case .Json:  return json.validate(src, .Json)
	case .Jsonc: return json.validate(src, .Jsonc)
	case .Json5: return json.validate(src, .Json5)
	}
	return nil
}

@(private = "file")
expect_chain_law :: proc(t: ^testing.T, pools: []host.Pool, src: string, framing: core.Framing, spec: json.Spec) -> bool {
	text := transmute([]u8)src
	serial, _ := records.check(text, json.as(spec), framing, context.temp_allocator)
	whole := whole_fault(text, spec)
	if !testing.expectf(t, records.validate(text, json.as(spec)) == whole, "%v %q: validate %v, want %v", spec, src, records.validate(text, json.as(spec)), whole) {
		return false
	}
	for &pool in pools {
		got, _ := records.check(text, json.as(spec), framing, context.temp_allocator, &pool.runner)
		if !testing.expectf(t, slice.equal(got, serial), "%v %v %q at width %d: %v, want %v", framing, spec, src, pool.runner.threads + 1, got, serial) {
			return false
		}
		if v := records.validate(text, json.as(spec), &pool.runner); !testing.expectf(t, v == whole, "%v %q at width %d: validate %v, want %v", spec, src, pool.runner.threads + 1, v, whole) {
			return false
		}
	}
	if !walktest.expect_each_law(t, pools, text, json.as(spec), framing) {
		return false
	}
	entries, at, ok := json.spine(text, json.as(spec))
	return framing != .Entries || !ok || walktest.expect_each_law(t, pools, text, entries, .Entries, at)
}

// Strings of commas and brackets, arrays inside entries and faults near either end.
@(private = "file", rodata)
CHAIN_PIECES := []string{`",,,,"`, `[1,[2,[3,",]"]],4]`, `{"a":",","b":[",",","]}`, `"\",\n"`, `[]`, `{}`, `1`, `"x"`, `[1,,2]`, `{"a" 1}`}

@(test)
records_check_on_threads :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	pools: [len(WIDTHS)]host.Pool
	for w, i in WIDTHS {
		host.pool_init(&pools[i], w)
	}
	defer for &p in pools {
		host.pool_destroy(&p)
	}
	breakers := []string{"x", "\"", "]", "}", ",", "\n", "\x1e", "\\", "["}
	buf := make([dynamic]u8, context.temp_allocator)
	for seed in u64(1) ..= 3 {
		state := rand.create(seed)
		gen := rand.default_random_generator(&state)
		for round in 0 ..< 16 {
			framing := core.Framing(round % 4)
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, seeded_text(gen, framing))
			if framing == .Lines {
				for _ in 0 ..< 4 {
					strings.write_string(&b, rand.choice(CHAIN_PIECES, gen))
					strings.write_byte(&b, '\n')
				}
			}
			src := strings.to_string(b)
			for i in 0 ..= len(src) {
				clear(&buf)
				append(&buf, src[:i])
				if i < len(src) {
					append(&buf, rand.choice(breakers, gen))
					append(&buf, src[i + 1:])
				}
				for spec in json.Spec {
					if !expect_chain_law(t, pools[:], string(buf[:]), framing, spec) {
						return
					}
				}
			}
		}
	}
	// Root arrays of the pieces, each cut at every byte.
	for n in 1 ..= 8 {
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		for k in 0 ..< n {
			strings.write_string(&b, CHAIN_PIECES[(k * 7 + n) % len(CHAIN_PIECES)])
			strings.write_string(&b, ",\n" if k < n - 1 else "]")
		}
		src := strings.to_string(b)
		for cut in 0 ..= len(src) {
			for spec in json.Spec {
				if !expect_chain_law(t, pools[:], src[:cut], .Entries, spec) {
					return
				}
			}
		}
	}
}

// Texts around a long array, which `@` stands for.
@(private = "file", rodata)
SPINES := [?]string{
	`{"meta":{"n":1},"logs":@,"tail":"x"}`,
	`{"d":{"x":[1],"items":@}}`,
	` {"a":1,"b":"[,]","c" : @ , "z" : null } `,
	`{"k":@,"k":[3]} x`,
	`{"a":{"b":{"c":{"d":{"e":@}}}}}`,
	`@`,
}

@(private = "file")
long_array :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for i in 0 ..< 300 {
		fmt.sbprintf(&b, `{{"a":%d,"s":",]"}},`, i)
	}
	strings.write_string(&b, "[1,[2]]]")
	return strings.to_string(b)
}

@(test)
records_validate_a_spine :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	pools: [len(WIDTHS)]host.Pool
	for w, i in WIDTHS {
		host.pool_init(&pools[i], w)
	}
	defer for &p in pools {
		host.pool_destroy(&p)
	}
	array := long_array()
	texts: [len(SPINES)]string
	for text, i in SPINES {
		texts[i], _ = strings.replace(text, "@", array, 1, context.temp_allocator)
	}
	entries, at, ok := json.spine(transmute([]u8)texts[0], json.as(.Json))
	testing.expect(t, ok && entries.opts[0] == 1 && at == 23)
	it := records.open(transmute([]u8)texts[0], entries, .Entries, at)
	defer records.close(&it)
	n := 0
	for rec in records.next(&it) {
		testing.expect(t, rec.at > at)
		n += 1
	}
	testing.expect(t, n == 301 && it.fault == nil)
	entries, _, ok = json.spine(transmute([]u8)texts[1], json.as(.Json))
	testing.expect(t, ok && entries.opts[0] == 2)
	_, _, ok = json.spine(transmute([]u8)texts[4], json.as(.Json))
	testing.expect(t, !ok)
	entries, at, ok = json.spine(transmute([]u8)texts[5], json.as(.Json))
	testing.expect(t, ok && entries.opts[0] == 0 && at == 0)
	_, _, ok = json.spine(transmute([]u8)string(`{"a":[1]}`), json.as(.Json))
	testing.expect(t, !ok)

	// Bytes near either end and through the middle each broken in turn, and the text cut there.
	breakers := []string{"x", "]", ","}
	buf := make([dynamic]u8, context.temp_allocator)
	for src in texts {
		for i in 0 ..= len(src) {
			if i > 16 && i < len(src) - 16 && i % 997 != 0 {
				continue
			}
			for c in breakers {
				clear(&buf)
				append(&buf, src[:i])
				if i < len(src) {
					append(&buf, c)
					append(&buf, src[i + 1:])
				}
				for spec in json.Spec {
					if !expect_chain_law(t, pools[:], string(buf[:]), .Entries, spec) {
						return
					}
				}
			}
			for spec in json.Spec {
				if !expect_chain_law(t, pools[:], src[:i], .Entries, spec) {
					return
				}
			}
		}
	}
	// A spine nested past the depth a text may open.
	deep := json.as(.Json)
	deep.max_depth = 2
	src := transmute([]u8)texts[1]
	testing.expect_value(t, records.validate(src, deep), json.validate(src, .Json, {max_depth = 2}))
}

// The duplicate check of a record's read builds its document on the reader's allocator, not the temporary one.
@(test)
records_refuse_duplicates_on_the_reader :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	Row :: struct {
		a: int,
	}
	plan, _ := json.plan_make(Row)
	defer typed.plan_destroy(&plan)
	src := transmute([]u8)string("{\"a\":1}\n{\"a\":2}\n[{\"a\":3}]")
	for framing in ([]core.Framing{.Lines, .Concatenated}) {
		it := records.open(src, json.as(.Json), framing)
		row: Row
		{
			context.temp_allocator = mem.tracking_allocator(&track)
			for {
				if more, _ := records.read(&it, &row, &plan, {refuse_duplicates = true}); !more {
					break
				}
			}
		}
		records.close(&it)
		testing.expectf(t, track.total_allocation_count == 0, "%v: %d temporary allocations", framing, track.total_allocation_count)
	}
}
