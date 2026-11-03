// `records <frame|check|read> <file> <iters>`: reads the NDJSON records of the file and prints best and median GB/s.
// `frame` frames each record and reads no value, `check` judges each one, `read` reads each one of `logs.ndjson` into
// a `Log_Record`, strings borrowed.
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"
import typed "../../core/typed"
import records "../../core/records"
import json "../../json"

frame :: proc(src: []u8) -> int {
	it := records.open(src, json.as(.Json))
	defer records.close(&it)
	n := 0
	for rec in records.next(&it) {
		n += len(rec.text) & 1
	}
	return n
}

check :: proc(src: []u8) -> int {
	faults, _ := records.check(src, json.as(.Json), .Lines, context.temp_allocator)
	defer free_all(context.temp_allocator)
	return len(faults)
}

Log_Record :: struct {
	ts, level, service, msg: string,
	status, bytes:           i64,
	duration_ms:             f64,
	id:                      string,
}

log_plan: typed.Plan

read :: proc(src: []u8) -> int {
	it := records.open(src, json.as(.Json))
	defer records.close(&it)
	n := 0
	for {
		v: Log_Record
		more, err := records.read(&it, &v, &log_plan, {borrow_strings = true})
		if !more {
			return n
		}
		n += int(err.kind != .None)
	}
}

main :: proc() {
	if len(os.args) != 4 {
		fmt.eprintln("usage: records <frame|check|read> <file> <iters>")
		os.exit(2)
	}
	src, err := os.read_entire_file(os.args[2], runtime.default_allocator())
	if err != nil {
		fmt.eprintln(err)
		os.exit(1)
	}
	iters, _ := strconv.parse_int(os.args[3])
	lane: proc(src: []u8) -> int
	switch os.args[1] {
	case "frame": lane = frame
	case "check": lane = check
	case "read":
		lane = read
		log_plan, _ = json.plan_make(Log_Record)
	case:
		fmt.eprintln("no lane", os.args[1])
		os.exit(2)
	}
	ts := make([]f64, iters)
	for i in 0 ..< iters {
		t0 := time.tick_now()
		n := lane(src)
		ts[i] = time.duration_seconds(time.tick_since(t0))
		if os.args[1] != "frame" && n != 0 {
			fmt.eprintln(n, "records refused")
			os.exit(1)
		}
	}
	slice.sort(ts)
	fmt.printf("%.3f %.3f\n", f64(len(src)) / ts[0] / 1e9, f64(len(src)) / ts[iters / 2] / 1e9)
}
