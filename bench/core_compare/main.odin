package main

// Times stury against Odin's core:encoding/json in one process, on the same fixtures and the same arena.
// Each lane alternates the two arms' order every round so load drift affects both equally, and prints the
// median of the timed rounds as a markdown table.
//
//   odin build bench/core_compare -o:speed -collection:stury=. -out:build/core_compare
//   build/core_compare [fixtures_dir] [rounds]

import "base:runtime"
import core_json "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"
import json "stury:json"

// Reserve of the static arena every arm uses. A reset faults no pages in, and a lane that outgrows the reserve
// fails instead of growing without bound.
ARENA_RESERVE :: 4 << 30
WARMUP :: 2

Log_Record :: struct {
	ts, level, service, msg: string,
	status, bytes:           i64,
	duration_ms:             f64,
	id:                      string,
}

Logs_Doc :: struct {
	logs: []Log_Record,
}

Nested_B :: struct {
	c: i64,
}

Nested_Inner :: struct {
	a: []f64,
	b: Nested_B,
}

Nested_Rec :: struct {
	id:     i64,
	name:   string,
	tags:   []i64,
	nested: Nested_Inner,
	ok:     bool,
}

// An arm runs one iteration over `src` into `alloc` and reports whether it succeeded.
Arm :: #type proc(src: []byte, alloc: runtime.Allocator) -> bool

Lane :: struct {
	name:        string,
	stury, core: Arm,
}

arena: virtual.Arena

main :: proc() {
	dir := len(os.args) > 1 ? os.args[1] : "bench/fixtures"
	rounds := 11
	if len(os.args) > 2 {
		n, ok := strconv.parse_int(os.args[2])
		if !ok || n < 1 {
			fmt.eprintln("rounds must be a positive integer")
			os.exit(2)
		}
		rounds = n
	}
	if virtual.arena_init_static(&arena, ARENA_RESERVE) != nil {
		fmt.eprintln("cannot reserve the arena")
		os.exit(1)
	}
	defer virtual.arena_destroy(&arena)

	fmt.printf("rounds: %d (median), warm-up: %d\n\n", rounds, WARMUP)
	fmt.println("| Job | Input | stury ms | core:encoding/json ms | stury speedup |")
	fmt.println("| --- | --- | ---: | ---: | ---: |")
	ok := true
	ok &= run_fixture(dir, "logs.json", rounds, agrees(Logs_Doc), {
		{"Validate", stury_validate, core_validate},
		{"Load (DOM)", stury_load, core_load},
		{"Unmarshal", stury_unmarshal(Logs_Doc), core_unmarshal(Logs_Doc)},
		{"Marshal", stury_marshal(Logs_Doc), core_marshal(Logs_Doc)},
	})
	ok &= run_fixture(dir, "nested.json", rounds, agrees([]Nested_Rec), {
		{"Validate", stury_validate, core_validate},
		{"Load (DOM)", stury_load, core_load},
		{"Unmarshal", stury_unmarshal([]Nested_Rec), core_unmarshal([]Nested_Rec)},
		{"Marshal", stury_marshal([]Nested_Rec), core_marshal([]Nested_Rec)},
	})
	if !ok {
		os.exit(1)
	}
}

run_fixture :: proc(dir, name: string, rounds: int, agree: proc(src: []byte) -> (decodes_same, round_trips: bool), lanes: []Lane) -> bool {
	path := fmt.tprintf("%s/%s", dir, name)
	src, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintf("cannot read %s: %v (run `python3 bench/gen.py` first)\n", path, err)
		return false
	}
	defer delete(src)
	decodes_same, round_trips := agree(src)
	if !decodes_same {
		fmt.eprintf("%s: stury and core:encoding/json do not agree on the decoded value, or one failed; no lane timed\n", name)
		return false
	}
	if !round_trips {
		fmt.eprintf("%s: core:encoding/json's marshal output reads back to a different value (float digits lost)\n", name)
	}
	label := fmt.tprintf("%s, %.1f MB", name, f64(len(src)) / 1e6)
	ok := true
	for lane in lanes {
		s, c, lane_ok := time_lane(src, lane, rounds)
		if !lane_ok {
			fmt.eprintf("%s on %s failed\n", lane.name, name)
			ok = false
			continue
		}
		fmt.printf("| %s | %s | %.2f | %.2f | %.1f× |\n", lane.name, label, ms(s), ms(c), f64(c) / f64(s))
	}
	return ok
}

time_lane :: proc(src: []byte, lane: Lane, rounds: int) -> (stury, core: time.Duration, ok: bool) {
	alloc := virtual.arena_allocator(&arena)
	st := make([]time.Duration, rounds)
	ct := make([]time.Duration, rounds)
	defer delete(st)
	defer delete(ct)
	for i in 0 ..< WARMUP + rounds {
		order := [2]Arm{lane.stury, lane.core}
		if i % 2 == 1 {
			order = {lane.core, lane.stury}
		}
		for arm in order {
			virtual.arena_free_all(&arena)
			start := time.tick_now()
			arm(src, alloc) or_return
			d := time.tick_since(start)
			if i >= WARMUP {
				if arm == lane.stury {st[i - WARMUP] = d} else {ct[i - WARMUP] = d}
			}
		}
	}
	virtual.arena_free_all(&arena)
	slice.sort(st)
	slice.sort(ct)
	return median(st), median(ct), true
}

// Returns the middle sample of `sorted`, or the mean of the two middle ones when the count is even.
median :: proc(sorted: []time.Duration) -> time.Duration {
	n := len(sorted)
	if n % 2 == 1 {
		return sorted[n / 2]
	}
	return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
}

ms :: proc(d: time.Duration) -> f64 {
	return time.duration_milliseconds(d)
}

stury_validate :: proc(src: []byte, _: runtime.Allocator) -> bool {
	return json.validate(src) == nil
}

core_validate :: proc(src: []byte, _: runtime.Allocator) -> bool {
	return core_json.is_valid(src, .JSON)
}

// Builds a `.Dom` and reads every value once, in document order. A `.Dom` scan checks every number's grammar
// but converts it only when read, and borrows an unescaped string, while core's parse converts every number
// and copies every string; the reads add the conversions. The strings stay borrowed.
stury_load :: proc(src: []byte, alloc: runtime.Allocator) -> bool {
	req: json.Request({.Dom})
	if json.request_init(&req, allocator = alloc) != nil || json.scan(src, &req) != nil {
		return false
	}
	for n := json.ROOT; ; n += 1 {
		kd := json.kind(&req.doc, n) or_break
		#partial switch kd {
		case .Number:
			_ = json.get_number(&req.doc, n) or_return
		case .String:
			_ = json.get_string(&req.doc, n) or_return
		}
	}
	return true
}

core_load :: proc(src: []byte, alloc: runtime.Allocator) -> bool {
	_, err := core_json.parse(src, .JSON, true, alloc)
	return err == nil
}

stury_unmarshal :: proc($T: typeid) -> Arm {
	return proc(src: []byte, alloc: runtime.Allocator) -> bool {
		v: T
		return json.unmarshal(src, &v, allocator = alloc) == nil
	}
}

core_unmarshal :: proc($T: typeid) -> Arm {
	return proc(src: []byte, alloc: runtime.Allocator) -> bool {
		v: T
		return core_json.unmarshal(src, &v, .JSON, alloc) == nil
	}
}

// The marshal arms write a value decoded once, outside the clock, so both arms write the same value.
stury_marshal :: proc($T: typeid) -> Arm {
	@(static) value: T
	@(static) decoded: bool
	return proc(src: []byte, alloc: runtime.Allocator) -> bool {
		if !decode_once(T, src, &value, &decoded) {
			return false
		}
		_, err := json.marshal(value, allocator = alloc)
		return err == .None
	}
}

core_marshal :: proc($T: typeid) -> Arm {
	@(static) value: T
	@(static) decoded: bool
	return proc(src: []byte, alloc: runtime.Allocator) -> bool {
		if !decode_once(T, src, &value, &decoded) {
			return false
		}
		_, err := core_json.marshal(value, {}, alloc)
		return err == nil
	}
}

// Decodes into the heap, which outlives every arena reset.
decode_once :: proc($T: typeid, src: []byte, value: ^T, decoded: ^bool) -> bool {
	if decoded^ {
		return true
	}
	if json.unmarshal(src, value, allocator = context.allocator) != nil {
		return false
	}
	decoded^ = true
	return true
}

// Reports whether both readers decode the same value (the lanes are timed only when they do) and whether
// core's marshal output reads back as that value. Values are compared by stury's marshal output, which is
// equal exactly when the values are.
agrees :: proc($T: typeid) -> proc(src: []byte) -> (decodes_same, round_trips: bool) {
	return proc(src: []byte) -> (decodes_same, round_trips: bool) {
		defer virtual.arena_free_all(&arena)
		alloc := virtual.arena_allocator(&arena)
		ours, theirs, back: T
		if json.unmarshal(src, &ours, allocator = alloc) != nil || core_json.unmarshal(src, &theirs, .JSON, alloc) != nil {
			return
		}
		want, werr := json.marshal(ours, allocator = alloc)
		got, gerr := json.marshal(theirs, allocator = alloc)
		if werr != .None || gerr != .None || string(want) != string(got) {
			return
		}
		written, cerr := core_json.marshal(ours, {}, alloc)
		if cerr != nil || json.unmarshal(written, &back, allocator = alloc) != nil {
			return true, false
		}
		again, aerr := json.marshal(back, allocator = alloc)
		return true, aerr == .None && string(again) == string(want)
	}
}
