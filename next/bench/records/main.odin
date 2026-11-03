// `records <frame|check|stream|read|cells|rows> <file> <iters>`: reads the records of the file and prints best and
// median GB/s. On NDJSON, `frame` frames each record and reads no value, `check` judges each one, `stream` judges each
// one through a stream's window, `read` reads each one of `logs.ndjson` into a `Log_Record`, strings borrowed. On CSV,
// `cells` reads each row's first cell, and `rows` reads each row of `table.csv` into a `Table_Row`, strings borrowed.
package main

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"
import typed "../../core/typed"
import records "../../core/records"
import json "../../json"
import dsv "../../dsv"

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

// `check`'s work on a stream of the text in memory, read through the 64 KiB window.
stream :: proc(src: []u8) -> int {
	r: bytes.Reader
	it := records.open_stream(bytes.reader_init(&r, src), json.as(.Json))
	defer records.close(&it)
	n := 0
	for rec in records.next(&it) {
		// `judge` takes offsets in the window.
		in_window := rec
		in_window.at -= it.base
		n += int(it.services.judge(&it, in_window) != nil)
	}
	return n
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

cells :: proc(src: []u8) -> int {
	it := records.open(src, dsv.as(.Csv))
	defer records.close(&it)
	buf: [256]u8
	n := 0
	for rec in records.next(&it) {
		text, _ := records.cell(&it, rec, 0, buf[:])
		n += len(text) & 1
	}
	return n
}

Table_Row :: struct {
	id, ts:       i64,
	lat, lon:     f64,
	qty:          i64,
	price, score: f64,
	ok:           bool,
	code:         string,
}

row_plan: typed.Plan

rows :: proc(src: []u8) -> int {
	it := records.open(src, dsv.as(.Csv))
	defer records.close(&it)
	n := 0
	for {
		v: Table_Row
		more, err := records.read(&it, &v, &row_plan, {borrow_strings = true})
		if !more {
			return n
		}
		n += int(err.kind != .None)
	}
}

main :: proc() {
	if len(os.args) != 4 {
		fmt.eprintln("usage: records <frame|check|stream|read|cells|rows> <file> <iters>")
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
	case "stream": lane = stream
	case "read":
		lane = read
		log_plan, _ = json.plan_make(Log_Record)
	case "cells": lane = cells
	case "rows":
		lane = rows
		row_plan, _ = dsv.plan_make(Table_Row, .Csv)
	case:
		fmt.eprintln("no lane", os.args[1])
		os.exit(2)
	}
	ts := make([]f64, iters)
	for i in 0 ..< iters {
		t0 := time.tick_now()
		n := lane(src)
		ts[i] = time.duration_seconds(time.tick_since(t0))
		if os.args[1] != "frame" && os.args[1] != "cells" && n != 0 {
			fmt.eprintln(n, "records refused")
			os.exit(1)
		}
	}
	slice.sort(ts)
	fmt.printf("%.3f %.3f\n", f64(len(src)) / ts[0] / 1e9, f64(len(src)) / ts[iters / 2] / 1e9)
}
