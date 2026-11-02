// `typed <lane> <borrow|copy> <file> <iters>`: reads the file into the lane's type on an arena and prints best and median
// GB/s. A plan is built once, so a read's time holds no plan work.
package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"
import typed "../../core/typed"
import dsv "../../dsv"
import json "../../json"

Log_Record :: struct {
	ts, level, service, msg: string,
	status, bytes:           i64,
	duration_ms:             f64,
	id:                      string,
}
Logs_Doc :: struct {
	logs: []Log_Record,
}
Tweet_Metadata :: struct {
	result_type, iso_language_code: string,
}
Twitter_User :: struct {
	id:                                                                        i64,
	id_str, name, screen_name, location, description, created_at:              string,
	followers_count, friends_count, listed_count, favourites_count, statuses_count: i64,
	lang:                                                                      string,
	verified, protected:                                                       bool,
}
Tweet :: struct {
	metadata:                      Tweet_Metadata,
	created_at:                    string,
	id:                            i64,
	id_str, text, source:          string,
	truncated:                     bool,
	retweet_count, favorite_count: i64,
	lang:                          string,
	user:                          Twitter_User,
}
Twitter :: struct {
	statuses: []Tweet,
}
CITM_Event :: struct {
	id:                 i64,
	name:               string,
	subTopicIds, topicIds: []i64,
}
CITM_Price :: struct {
	amount, audienceSubCategoryId, seatCategoryId: i64,
}
CITM_Perf :: struct {
	eventId, id, start: i64,
	venueCode:          string,
	prices:             []CITM_Price,
}
CITM :: struct {
	areaNames, blockNames: map[string]string,
	events:                map[string]CITM_Event,
	performances:          []CITM_Perf,
	topicSubTopics:        map[string][]i64,
	venueNames:            map[string]string,
}

Table_Row :: struct {
	id, ts:              i64,
	lat, lon:            f64,
	qty:                 i64,
	price, score:        f64,
	ok:                  bool,
	code:                string,
}
Text_Row :: struct {
	id:                    i64,
	name, city, quote, note: string,
}

ARENA_BYTES :: 1 << 30

// A dsv lane's `T` is a list of rows.
lane :: proc($T: typeid, src: []u8, borrow: bool, iters: int, $DSV: bool) {
	backing, failed := make([]u8, ARENA_BYTES)
	if failed != nil {
		fmt.eprintln("no arena")
		os.exit(1)
	}
	ar: mem.Arena
	mem.arena_init(&ar, backing)
	alloc := mem.arena_allocator(&ar)
	when DSV {
		plan, err := dsv.plan_make(T)
	} else {
		plan, err := json.plan_make(T)
	}
	if err.kind != .None {
		fmt.eprintln(err.kind)
		os.exit(1)
	}
	read := typed.Read_Options {
		borrow_strings = borrow,
	}
	ts := make([]f64, iters)
	for i in 0 ..< iters {
		mem.arena_free_all(&ar)
		d: T
		t0 := time.tick_now()
		when DSV {
			e := dsv.unmarshal(src, .Csv, &d, &plan, read, {}, alloc)
		} else {
			e := json.unmarshal(src, .Json, &d, &plan, read, {}, alloc)
		}
		ts[i] = time.duration_seconds(time.tick_since(t0))
		if e.kind != .None {
			fmt.eprintln(e.kind, e.at)
			os.exit(1)
		}
	}
	slice.sort(ts)
	fmt.printf("%.3f %.3f\n", f64(len(src)) / ts[0] / 1e9, f64(len(src)) / ts[iters / 2] / 1e9)
}

main :: proc() {
	if len(os.args) != 5 {
		fmt.eprintln("usage: typed <lane> <borrow|copy> <file> <iters>")
		os.exit(2)
	}
	src, err := os.read_entire_file(os.args[3], runtime.default_allocator())
	if err != nil {
		fmt.eprintln(err)
		os.exit(1)
	}
	borrow := os.args[2] == "borrow"
	iters, _ := strconv.parse_int(os.args[4])
	switch os.args[1] {
	case "logs": lane(Logs_Doc, src, borrow, iters, false)
	case "twitter": lane(Twitter, src, borrow, iters, false)
	case "citm": lane(CITM, src, borrow, iters, false)
	case "table": lane([]Table_Row, src, borrow, iters, true)
	case "text": lane([]Text_Row, src, borrow, iters, true)
	}
}
