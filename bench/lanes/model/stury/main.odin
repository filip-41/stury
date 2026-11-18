// `model <logs|twitter> <file> <load|first|dump>`: the file holds one JSON record per line, each loaded into a model whose
// rules sit in its struct tags, as the other libraries' arms judge the same rules. `load` collects every refusal of a
// record in a sink, `first` stops at a record's first, and `dump` writes each loaded record back as compact text. A call
// does every record of the file, on an arena freed before the next call. `check` folds the number of accepted records, the
// sum of one number member over them, and for `load` how many records refused each member path, in path order.
package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import core "../../../../core"
import "../../../timing"
import typed "../../../../core/typed"
import write "../../../../core/write"
import json "../../../../json"
import model "../../../../core/model"

Log_Record :: struct {
	ts:          string `model:"pattern=^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$"`,
	level:       string `model:"pattern=^(trace|debug|info|warn|error)$"`,
	service:     string `model:"len>=1,len<=16"`,
	msg:         string `model:"len>=1,len<=200"`,
	status:      i64 `model:">=100,<=599"`,
	bytes:       i64 `model:">=0"`,
	duration_ms: f64 `model:">=0,<=60000"`,
	id:          string `model:"pattern=^req-[0-9a-f]{8}$"`,
	region:      string `model:"len<=16"`,
}

Tweet_Metadata :: struct {
	result_type:       string `model:"pattern=^(recent|popular|mixed)$"`,
	iso_language_code: string `model:"pattern=^[a-z]{2,3}$"`,
}

Twitter_User :: struct {
	id:               i64 `model:">=1"`,
	id_str:           string `model:"pattern=^[0-9]{1,19}$"`,
	name:             string `model:"len>=1,len<=50"`,
	screen_name:      string `model:"pattern=^[A-Za-z0-9_]{1,15}$"`,
	location:         string `model:"len<=100"`,
	description:      string `model:"len<=200"`,
	created_at:       string `model:"pattern=^[A-Z][a-z]{2} [A-Z][a-z]{2} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \+0000 [0-9]{4}$"`,
	followers_count:  i64 `model:">=0"`,
	friends_count:    i64 `model:">=0"`,
	listed_count:     i64 `model:">=0"`,
	favourites_count: i64 `model:">=0"`,
	statuses_count:   i64 `model:">=0"`,
	lang:             string `model:"pattern=^[a-z]{2}(-[a-z]{2})?$"`,
	verified:         bool,
	protected:        bool,
}

Tweet :: struct {
	metadata:       Tweet_Metadata,
	created_at:     string `model:"pattern=^[A-Z][a-z]{2} [A-Z][a-z]{2} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \+0000 [0-9]{4}$"`,
	id:             i64 `model:">=1"`,
	id_str:         string `model:"pattern=^[0-9]{1,19}$"`,
	text:           string `model:"len>=1,len<=140"`,
	source:         string `model:"len>=1,len<=200"`,
	truncated:      bool,
	retweet_count:  i64 `model:">=0"`,
	favorite_count: i64 `model:">=0"`,
	lang:           string `model:"pattern=^[a-z]{2,3}$"`,
	user:           Twitter_User,
	reviewed:       bool,
}

ARENA_BYTES :: 512 << 20

// The number each accepted record adds to the check.
tally :: proc(v: ^$T) -> u64 {
	when T == Log_Record {
		return u64(v.bytes)
	} else {
		return u64(v.retweet_count)
	}
}

// The records of `src`, a slice of each line that holds anything.
split_records :: proc(src: []u8) -> [][]u8 {
	lines := make([dynamic][]u8)
	rest := src
	for len(rest) > 0 {
		end := len(rest)
		for i in 0 ..< len(rest) {
			if rest[i] == '\n' {
				end = i
				break
			}
		}
		if end > 0 {
			append(&lines, rest[:end])
		}
		rest = rest[min(end + 1, len(rest)):]
	}
	return lines[:]
}

// The member of a refusal as a dotted path from the record, `user.followers_count`, in the temp allocator.
member_path :: proc(e: core.Error_Entry) -> string {
	pointer := write.report_pointer(e)
	path, _ := strings.replace_all(strings.trim_prefix(pointer, "/"), "/", ".", context.temp_allocator)
	return path
}

Counted :: struct {
	accepted: u64,
	sum:      u64,
	refused:  map[string]u64,
}

// Loads every record once more and counts what the check folds. A record counts each member path it refused once.
count_pass :: proc(m: ^model.Model($T), lines: [][]u8, sink: ^typed.Sink, alloc: runtime.Allocator) -> (c: Counted) {
	for line in lines {
		defer free_all(context.temp_allocator)
		v: T
		if sink != nil {
			clear(&sink.entries)
		}
		if model.load(m, line, &v, sink, allocator = alloc) == nil {
			c.accepted += 1
			c.sum += tally(&v)
			continue
		}
		if sink == nil {
			continue
		}
		seen := make([dynamic]string, context.temp_allocator)
		for e in sink.entries {
			path := member_path(e)
			if !slice.contains(seen[:], path) {
				append(&seen, path)
				if path in c.refused {
					c.refused[path] += 1
				} else {
					c.refused[strings.clone(path)] = 1
				}
			}
		}
	}
	return
}

fold_counted :: proc(c: Counted) -> u64 {
	h := timing.fnv_u64(timing.CHECK_OFFSET, c.accepted)
	h = timing.fnv_u64(h, c.sum)
	names := make([dynamic]string, context.temp_allocator)
	for name in c.refused {
		append(&names, name)
	}
	slice.sort(names[:])
	for name in names {
		h = timing.fnv_bytes(h, transmute([]u8)name)
		h = timing.fnv_u64(h, c.refused[name])
	}
	return h
}

arena_of :: proc(ar: ^mem.Arena) -> runtime.Allocator {
	backing, failed := make([]u8, ARENA_BYTES)
	if failed != nil {
		fmt.eprintln("no arena")
		os.exit(1)
	}
	mem.arena_init(ar, backing)
	return mem.arena_allocator(ar)
}

report :: proc(bytes: int, ts: ^[timing.TIMED]i64, check: u64) {
	median := timing.median(ts)
	fmt.printfln("gb_per_s=%.4f best=%.4f ns=%d check=%d", f64(bytes) / f64(median), f64(bytes) / f64(ts[0]), median, check)
}

fail :: proc(err: core.Error) -> ! {
	fmt.eprintln(err)
	os.exit(1)
}

run :: proc($T: typeid, mode: string, src: []u8, lines: [][]u8) {
	reg: model.Registry
	when T == Log_Record {
		model.register(&reg, T, "region", "local")
	} else {
		model.register(&reg, T, "reviewed", false)
	}
	m, err := model.compile(&reg, T, json.checks(.Json))
	if err != nil {
		fail(err)
	}
	ar: mem.Arena
	alloc := arena_of(&ar)
	values := make([]T, len(lines))
	ts: [timing.TIMED]i64
	if mode == "dump" {
		for line, i in lines {
			if e := model.load(&m, line, &values[i], allocator = alloc); e != nil {
				fail(e)
			}
			free_all(context.temp_allocator)
		}
		out := make([][]u8, len(lines))
		written: int
		dump_ar: mem.Arena
		dump_alloc := arena_of(&dump_ar)
		for i in 0 ..< timing.WARMUP + timing.TIMED {
			mem.arena_free_all(&dump_ar)
			t0 := time.tick_now()
			for &v, j in values {
				text, e := model.dump(&m, &v, allocator = dump_alloc)
				if e != nil {
					fail(e)
				}
				out[j] = text
				free_all(context.temp_allocator)
			}
			elapsed := i64(time.tick_since(t0))
			if i >= timing.WARMUP {
				ts[i - timing.WARMUP] = elapsed
			}
		}
		check := timing.CHECK_OFFSET
		for text in out {
			check = timing.fnv_bytes(check, text)
			written += len(text)
		}
		report(written, &ts, check)
		return
	}
	sink: typed.Sink
	collecting := mode == "load"
	judged: ^typed.Sink = &sink if collecting else nil
	for i in 0 ..< timing.WARMUP + timing.TIMED {
		mem.arena_free_all(&ar)
		if collecting {
			sink.entries = make([dynamic]core.Error_Entry, 0, 32, alloc)
		}
		t0 := time.tick_now()
		for line, j in lines {
			if collecting {
				clear(&sink.entries)
			}
			model.load(&m, line, &values[j], judged, allocator = alloc)
			free_all(context.temp_allocator)
		}
		elapsed := i64(time.tick_since(t0))
		if i >= timing.WARMUP {
			ts[i - timing.WARMUP] = elapsed
		}
	}
	mem.arena_free_all(&ar)
	if collecting {
		sink.entries = make([dynamic]core.Error_Entry, 0, 32, alloc)
	}
	counted := count_pass(&m, lines, judged, alloc)
	report(len(src), &ts, fold_counted(counted))
}

main :: proc() {
	if len(os.args) != 4 {
		fmt.eprintln("usage: model <logs|twitter> <file> <load|first|dump>")
		os.exit(2)
	}
	src, err := os.read_entire_file(os.args[2], runtime.default_allocator())
	if err != nil {
		fmt.eprintln(err)
		os.exit(1)
	}
	mode := os.args[3]
	if mode != "load" && mode != "first" && mode != "dump" {
		fmt.eprintln("no mode", mode, "(modes: load, first, dump)")
		os.exit(2)
	}
	lines := split_records(src)
	switch os.args[1] {
	case "logs": run(Log_Record, mode, src, lines)
	case "twitter": run(Tweet, mode, src, lines)
	case:
		fmt.eprintln("no shape", os.args[1], "(shapes: logs, twitter)")
		os.exit(2)
	}
}
