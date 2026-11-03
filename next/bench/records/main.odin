// `records <frame|check|stream|read|cells|rows|threads|validate|each> <file> <iters> [width]`: reads the records of the
// file and prints best and median GB/s. `check`, `threads` and `validate` read a `.csv` file as CSV. On NDJSON, `frame` frames each record and reads no value, `check` judges each
// one, `threads` is `check` on a pool of `width` threads (6 by default), `stream` judges each one through a stream's
// window, `read` reads each one of `logs.ndjson` into a `Log_Record`, strings borrowed. `validate` judges a whole
// text on the pool, and `each` is `check` through `each` on the pool, a `.json` file read as the entries of its spine. On
// CSV, `cells` reads each row's first cell, and `rows` reads each row of `table.csv` into a
// `Table_Row`, strings borrowed.
package main

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import core "../../core"
import host "../../host"
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

// The handle `check`, `threads` and `validate` read the file by.
handle: core.As

check :: proc(src: []u8) -> int {
	faults, _ := records.check(src, handle, .Lines, context.temp_allocator)
	defer free_all(context.temp_allocator)
	return len(faults)
}

pool: host.Pool

threads :: proc(src: []u8) -> int {
	faults, _ := records.check(src, handle, .Lines, context.temp_allocator, &pool.runner)
	defer free_all(context.temp_allocator)
	return len(faults)
}

validate :: proc(src: []u8) -> int {
	return int(records.validate(src, handle, &pool.runner) != nil)
}

// The framing `each` reads the file by, and the byte the records start at: a `.json` file's spine.
each_framing: core.Framing
each_at: u64

// `check`'s work through `each`, each piece's refused records counted by the piece.
each :: proc(src: []u8) -> int {
	judge_piece :: proc(n: ^int, piece: ^records.Reader, k: int) -> bool {
		bad := 0
		for rec in records.next(piece) {
			bad += int(piece.services.judge(piece, rec) != nil)
		}
		sync.atomic_add(n, bad)
		return true
	}
	n := 0
	n += int(records.each(src, handle, each_framing, judge_piece, &n, &pool.runner, each_at) != nil)
	return n
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
	if len(os.args) != 4 && len(os.args) != 5 {
		fmt.eprintln("usage: records <frame|check|stream|read|cells|rows|threads|validate|each> <file> <iters> [width]")
		os.exit(2)
	}
	src, err := os.read_entire_file(os.args[2], runtime.default_allocator())
	if err != nil {
		fmt.eprintln(err)
		os.exit(1)
	}
	iters, _ := strconv.parse_int(os.args[3])
	lane: proc(src: []u8) -> int
	handle = dsv.as(.Csv) if strings.has_suffix(os.args[2], ".csv") else json.as(.Json)
	switch os.args[1] {
	case "frame": lane = frame
	case "check": lane = check
	case "threads", "validate", "each":
		lane = threads if os.args[1] == "threads" else validate if os.args[1] == "validate" else each
		if lane == each && strings.has_suffix(os.args[2], ".json") {
			handle, each_at, _ = json.spine(src, handle)
			each_framing = .Entries
		}
		width := 6
		if len(os.args) == 5 {
			width, _ = strconv.parse_int(os.args[4])
		}
		host.pool_init(&pool, width)
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
