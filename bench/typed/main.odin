// `typed <lane> <borrow|copy> <file>`: reads the file into the lane's type on an arena and prints the median and
// best GB/s, the median ns, and `check`, a fold of the value read: an object's members sorted by key, then each value's
// kind and bytes, as the other libraries' typed arms fold theirs. A plan is built once, so a read's time holds no plan
// work.
package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:time"
import core "../../core"
import "../timing"
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
lane :: proc($T: typeid, src: []u8, borrow: bool, $DSV: bool) {
	backing, failed := make([]u8, ARENA_BYTES)
	if failed != nil {
		fmt.eprintln("no arena")
		os.exit(1)
	}
	ar: mem.Arena
	mem.arena_init(&ar, backing)
	alloc := mem.arena_allocator(&ar)
	when DSV {
		plan, err := dsv.plan_make(T, .Csv)
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
	ts: [timing.TIMED]i64
	check: u64
	for i in 0 ..< timing.WARMUP + timing.TIMED {
		mem.arena_free_all(&ar)
		d: T
		t0 := time.tick_now()
		when DSV {
			e := dsv.unmarshal(src, .Csv, &d, &plan, read = read, opts = {}, allocator = alloc)
		} else {
			e := json.unmarshal(src, .Json, &d, &plan, read = read, opts = {}, allocator = alloc)
		}
		elapsed := i64(time.tick_since(t0))
		if e.kind != .None {
			core.render(os.to_writer(os.stderr), src, e)
			fmt.eprintln()
			os.exit(1)
		}
		if i >= timing.WARMUP {
			ts[i - timing.WARMUP] = elapsed
		}
		if i == timing.WARMUP + timing.TIMED - 1 {
			check = fold(CHECK_OFFSET, &d, type_info_of(T))
		}
	}
	median := timing.median(&ts)
	fmt.printfln("gb_per_s=%.4f best=%.4f ns=%d check=%d", f64(len(src)) / f64(median), f64(len(src)) / f64(ts[0]), median, check)
}

CHECK_OFFSET :: u64(14695981039346656037)
CHECK_PRIME :: u64(1099511628211)

fold_bytes :: proc(h: u64, p: []u8) -> u64 {
	h := h
	for b in p {
		h = (h ~ u64(b)) * CHECK_PRIME
	}
	return h
}

fold_u64 :: proc(h: u64, n: u64) -> u64 {
	n := n
	return fold_bytes(h, mem.ptr_to_bytes(&n))
}

fold_tag :: proc(h: u64, tag: u8) -> u64 {
	return (h ~ u64(tag)) * CHECK_PRIME
}

fold_text :: proc(h: u64, s: string) -> u64 {
	return fold_bytes(fold_u64(fold_tag(h, 's'), u64(len(s))), transmute([]u8)s)
}

Member :: struct {
	key:  string,
	data: rawptr,
	ti:   ^runtime.Type_Info,
}

fold_members :: proc(h: u64, members: []Member) -> u64 {
	slice.sort_by(members, proc(a, b: Member) -> bool {return a.key < b.key})
	out := fold_u64(fold_tag(h, 'o'), u64(len(members)))
	for m in members {
		out = fold(fold_text(out, m.key), m.data, m.ti)
	}
	return out
}

// Folds the value at `data` of type `ti`, of the kinds the lanes' types hold.
fold :: proc(h: u64, data: rawptr, ti: ^runtime.Type_Info) -> u64 {
	#partial switch info in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_String:
		return fold_text(h, (^string)(data)^)
	case runtime.Type_Info_Integer:
		return fold_u64(fold_tag(h, 'i'), u64((^i64)(data)^))
	case runtime.Type_Info_Float:
		return fold_u64(fold_tag(h, 'd'), transmute(u64)(^f64)(data)^)
	case runtime.Type_Info_Boolean:
		return fold_tag(h, 't' if (^bool)(data)^ else 'f')
	case runtime.Type_Info_Slice:
		raw := (^runtime.Raw_Slice)(data)^
		out := fold_u64(fold_tag(h, 'a'), u64(raw.len))
		for i in 0 ..< raw.len {
			out = fold(out, rawptr(uintptr(raw.data) + uintptr(i * info.elem_size)), info.elem)
		}
		return out
	case runtime.Type_Info_Struct:
		members := make([]Member, info.field_count, context.temp_allocator)
		for i in 0 ..< int(info.field_count) {
			members[i] = {info.names[i], rawptr(uintptr(data) + info.offsets[i]), info.types[i]}
		}
		return fold_members(h, members)
	case runtime.Type_Info_Map:
		members := make([dynamic]Member, context.temp_allocator)
		it := 0
		for k, v in reflect.iterate_map(any{data, ti.id}, &it) {
			append(&members, Member{(^string)(k.data)^, v.data, type_info_of(v.id)})
		}
		return fold_members(h, members[:])
	}
	fmt.eprintln("fold: no kind for", ti)
	os.exit(1)
}

main :: proc() {
	if len(os.args) != 4 {
		fmt.eprintln("usage: typed <lane> <borrow|copy> <file>")
		os.exit(2)
	}
	src, err := os.read_entire_file(os.args[3], runtime.default_allocator())
	if err != nil {
		fmt.eprintln(err)
		os.exit(1)
	}
	borrow := os.args[2] == "borrow"
	switch os.args[1] {
	case "logs": lane(Logs_Doc, src, borrow, false)
	case "twitter": lane(Twitter, src, borrow, false)
	case "citm": lane(CITM, src, borrow, false)
	case "table": lane([]Table_Row, src, borrow, true)
	case "text": lane([]Text_Row, src, borrow, true)
	case:
		fmt.eprintln("no lane", os.args[1], "(lanes: logs, twitter, citm, table, text)")
		os.exit(2)
	}
}
