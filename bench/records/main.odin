// `records <frame|check|build|stream|read|refuse|write|cells|rows|text|threads|validate|each> <file> [width]`: reads the
// records of the file and prints best and median GB/s. A `.csv` file is read as CSV by `frame`, `check`, `threads`,
// `validate` and `each`. `frame` frames each record and reads no value, `check` judges each one, `build` builds the
// document of each, `threads` is `check` on a pool of `width` threads (6 by default), `stream` judges each one through a
// stream's window, `read` reads each one of `logs.ndjson` into a `Log_Record`, strings borrowed. `validate` judges a
// whole text on the pool, and `each` is `check` through `each` on the pool, a `.json` file read as the entries of its
// spine. On CSV, `cells` reads each row's first cell, and `rows` reads each row of `table.csv` into a `Table_Row`,
// strings borrowed. `write` reads the records of `logs.ndjson`, `table.csv` or `text.csv` into a list outside the clock,
// then times `records.marshal` of the list, and its GB/s counts the bytes written.
//
// It prints `gb_per_s=` (the median), `best=` and `check=`, the number of records of the file, which the peers' counts
// are compared with.
package main

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import core "../../core"
import "../timing"
import host "../../host"
import typed "../../core/typed"
import records "../../core/records"
import json "../../json"
import dsv "../../dsv"

// The handle every lane but `rows`, `text` and `cells` reads the file by.
handle: core.As

frame :: proc(src: []u8) -> int {
	it := records.open(src, handle)
	defer records.close(&it)
	n := 0
	for rec in records.next(&it) {
		n += len(rec.text) & 1
	}
	return n
}

// The number of records of `src`, for the peers' counts to be compared with.
count :: proc(src: []u8) -> int {
	it := records.open(src, handle, each_framing, each_at)
	defer records.close(&it)
	n := 0
	for _ in records.next(&it) {
		n += 1
	}
	return n
}

// The document of each record, dropped as the next is built.
build :: proc(src: []u8) -> int {
	it := records.open(src, handle)
	defer records.close(&it)
	n := 0
	for rec in records.next(&it) {
		doc, err := records.build(&it, rec)
		n += int(err.kind != .None)
		core.destroy(&doc)
	}
	return n
}

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
	return int(records.validate_parallel(src, handle, &pool.runner) != nil)
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
	return load(src, json.as(.Json), &log_plan, (^[dynamic]Log_Record)(nil))
}

// `read` with a repeated key refused, which builds each record before it reads it.
refuse :: proc(src: []u8) -> int {
	return load(src, json.as(.Json), &log_plan, (^[dynamic]Log_Record)(nil), .Refuse)
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
text_plan: typed.Plan

Text_Row :: struct {
	id:                      i64,
	name, city, quote, note: string,
}

rows :: proc(src: []u8) -> int {
	return read_rows(src, Table_Row, &row_plan)
}

text :: proc(src: []u8) -> int {
	return read_rows(src, Text_Row, &text_plan)
}

read_rows :: proc(src: []u8, $T: typeid, plan: ^typed.Plan) -> int {
	return load(src, dsv.as(.Csv), plan, (^[dynamic]T)(nil))
}

// Reads every record of `src` into a `T`, strings borrowed, appending to `list` when it is not nil. The result is the
// number of refused records.
load :: proc(src: []u8, as: core.As, plan: ^typed.Plan, list: ^[dynamic]$T, dups := core.Duplicates.Default) -> int {
	it := records.open(src, as)
	defer records.close(&it)
	n := 0
	v: T
	for err in records.read(&it, &v, plan, {borrow_strings = true, dups = dups}) {
		n += int(err.kind != .None)
		if list != nil {
			append(list, v)
		}
		v = {}
	}
	return n
}

// The `write` lane's records, read once outside the clock, and the bytes one pass writes.
logs_list:  [dynamic]Log_Record
table_list: [dynamic]Table_Row
text_list:  [dynamic]Text_Row
written:    int

// Each pass writes into an arena emptied after it, so the lane's resident memory is one pass's.
output: virtual.Arena

// `records.marshal` of the list as records, one for each element.
write :: proc(list: []$T, plan: ^typed.Plan) -> int {
	text, err := records.marshal(list, plan, handle, allocator = virtual.arena_allocator(&output))
	written = len(text)
	virtual.arena_free_all(&output)
	return int(err.kind != .None)
}

write_logs :: proc(_: []u8) -> int { return write(logs_list[:], &log_plan) }
write_rows :: proc(_: []u8) -> int { return write(table_list[:], &row_plan) }
write_text :: proc(_: []u8) -> int { return write(text_list[:], &text_plan) }

main :: proc() {
	if len(os.args) != 3 && len(os.args) != 4 {
		fmt.eprintln("usage: records <frame|check|build|stream|read|refuse|write|cells|rows|text|threads|validate|each> <file> [width]")
		os.exit(2)
	}
	src, err := os.read_entire_file(os.args[2], runtime.default_allocator())
	if err != nil {
		fmt.eprintln(err)
		os.exit(1)
	}
	lane: proc(src: []u8) -> int
	handle = dsv.as(.Csv) if strings.has_suffix(os.args[2], ".csv") else json.as(.Json)
	switch os.args[1] {
	case "frame": lane = frame
	case "check": lane = check
	case "build": lane = build
	case "threads", "validate", "each":
		lane = threads if os.args[1] == "threads" else validate if os.args[1] == "validate" else each
		if lane == each && strings.has_suffix(os.args[2], ".json") {
			each_at, _, _ = json.spine(src, handle)
			each_framing = .Entries
		}
		width := 6
		if len(os.args) == 4 {
			width, _ = strconv.parse_int(os.args[3])
		}
		host.pool_init(&pool, width)
	case "stream": lane = stream
	case "read", "refuse":
		lane = read if os.args[1] == "read" else refuse
		log_plan, _ = json.plan_make(Log_Record)
	case "cells": lane = cells
	case "rows":
		lane = rows
		row_plan, _ = dsv.plan_make(Table_Row, .Csv)
	case "text":
		lane = text
		text_plan, _ = dsv.plan_make(Text_Row, .Csv)
	case "write":
		// One block holds a pass, so the output grows in place.
		_ = virtual.arena_init_growing(&output, uint(4 * len(src)))
		switch filepath.stem(os.args[2]) {
		case "logs":
			lane = write_logs
			log_plan, _ = json.plan_make(Log_Record)
			load(src, handle, &log_plan, &logs_list)
		case "table":
			lane = write_rows
			row_plan, _ = dsv.plan_make(Table_Row, .Csv)
			load(src, handle, &row_plan, &table_list)
		case "text":
			lane = write_text
			text_plan, _ = dsv.plan_make(Text_Row, .Csv)
			load(src, handle, &text_plan, &text_list)
		case:
			fmt.eprintln("no write lane for", os.args[2])
			os.exit(2)
		}
	case:
		fmt.eprintln("no lane", os.args[1], "(lanes: frame, check, build, stream, read, refuse, write, cells, rows, text, threads, validate, each)")
		os.exit(2)
	}
	ts: [timing.TIMED]i64
	for i in 0 ..< timing.WARMUP + timing.TIMED {
		t0 := time.tick_now()
		n := lane(src)
		d := i64(time.tick_since(t0))
		if i >= timing.WARMUP {
			ts[i - timing.WARMUP] = d
		}
		if os.args[1] != "frame" && os.args[1] != "cells" && n != 0 {
			fmt.eprintln(n, "records refused")
			os.exit(1)
		}
	}
	// The write lane counts the bytes it writes and every other lane the bytes it reads.
	size := f64(written if os.args[1] == "write" else len(src))
	median := timing.median(&ts)
	fmt.printf("gb_per_s=%.4f best=%.4f check=%d\n", size / f64(median), size / f64(ts[0]), count(src))
}
