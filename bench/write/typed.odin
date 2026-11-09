package write_bench

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:time"
import core "../../core"
import "../timing"
import write "../../core/write"
import records "../../core/records"
import json "../../json"

Log_Record :: struct {
	ts, level, service, msg: string,
	status, bytes:           i64,
	duration_ms:             f64,
	id:                      string,
}
Logs :: struct {
	logs: []Log_Record,
}
Tweet_Metadata :: struct {
	result_type, iso_language_code: string,
}
Twitter_User :: struct {
	id:                                                                             i64,
	id_str, name, screen_name, location, description, created_at:                   string,
	followers_count, friends_count, listed_count, favourites_count, statuses_count: i64,
	lang:                                                                           string,
	verified, protected:                                                            bool,
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
Citm_Event :: struct {
	id:                    i64,
	name:                  string,
	subTopicIds, topicIds: []i64,
}
Citm_Price :: struct {
	amount, audienceSubCategoryId, seatCategoryId: i64,
}
Citm_Perf :: struct {
	eventId, id, start: i64,
	venueCode:          string,
	prices:             []Citm_Price,
}
Citm :: struct {
	areaNames, blockNames: map[string]string,
	events:                map[string]Citm_Event,
	performances:          []Citm_Perf,
	topicSubTopics:        map[string][]i64,
	venueNames:            map[string]string,
}
Canada_Geo :: struct {
	type:        string,
	coordinates: [][][2]f64,
}
Canada_Feat :: struct {
	type:     string,
	geometry: Canada_Geo,
}
Canada :: struct {
	type:     string,
	features: []Canada_Feat,
}
Nested_B :: struct {
	c: i64,
}
Nested_Inner :: struct {
	a: []f64,
	b: Nested_B,
}
Nested_Record :: struct {
	id:     i64,
	name:   string,
	tags:   []i64,
	nested: Nested_Inner,
	ok:     bool,
}

typed_lane :: proc(src: []u8, name: string, pretty: bool) {
	switch name {
	case "logs":
		lane(Logs, src, pretty)
	case "twitter":
		lane(Twitter, src, pretty)
	case "citm_catalog":
		lane(Citm, src, pretty)
	case "canada":
		lane(Canada, src, pretty)
	case "nested":
		lane([]Nested_Record, src, pretty)
	case "wide":
		lane(map[string]i64, src, pretty)
	case:
		fmt.eprintln("no type for", name)
		os.exit(2)
	}
}

// Every pass writes over the same bytes, which a resize never leaves.
Fixed_Output :: struct {
	bytes: []u8,
}

fixed_output_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, align: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	f := (^Fixed_Output)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if size > len(f.bytes) {
			return nil, .Out_Of_Memory
		}
		return f.bytes[:size], nil
	}
	return nil, nil
}

lane :: proc($T: typeid, src: []u8, pretty: bool) {
	value: T
	if err := json.unmarshal(src, .Json, &value); err != nil {
		fmt.eprintln("read:", err)
		os.exit(1)
	}
	plan, perr := json.plan_make(T, plan = {}, allocator = context.allocator)
	if perr != nil {
		fmt.eprintln("plan:", perr)
		os.exit(1)
	}
	output := Fixed_Output{make([]u8, 16 * len(src) + 64 * mem.Kilobyte)}
	fixed := runtime.Allocator{fixed_output_proc, &output}
	opts := core.Write_Options{pretty = pretty, indent = 2}
	times: [timing.TIMED]i64
	text: []u8
	// The walk's own scratch, a map's sorted keys among it, comes from an arena emptied after each pass, so the lane's
	// resident memory is one pass's and not the allocator's lag in returning forty-three.
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	for i in 0 ..< timing.WARMUP + timing.TIMED {
		context.allocator = virtual.arena_allocator(&scratch)
		start := time.tick_now()
		out, err := write.marshal(value, &plan, opts, fixed)
		d := i64(time.tick_since(start))
		virtual.arena_free_all(&scratch)
		if err != nil {
			fmt.eprintln("write:", err)
			os.exit(1)
		}
		text = out
		if i >= timing.WARMUP {
			times[i - timing.WARMUP] = d
		}
	}
	h := CHECK_OFFSET
	for b in text {
		h = (h ~ u64(b)) * CHECK_PRIME
	}
	median := timing.median(&times)
	fmt.printfln("gb_per_s=%.3f best=%.3f ns=%d out=%d check=%d", f64(len(text)) / f64(median), f64(len(text)) / f64(times[0]), median, len(text), h)
}

// `write records logs.json`: `records.marshal` of the file's records as NDJSON, and in the same pass `write.marshal` of
// the same list, which writes it as one array, under `list_`. GB/s counts output bytes.
records_lane :: proc(src: []u8) {
	value: Logs
	if err := json.unmarshal(src, .Json, &value); err != nil {
		fmt.eprintln("read:", err)
		os.exit(1)
	}
	plan, _ := json.plan_make(Log_Record)
	list_plan, _ := json.plan_make([]Log_Record)
	output := Fixed_Output{make([]u8, 2 * len(src) + 64 * mem.Kilobyte)}
	fixed := runtime.Allocator{fixed_output_proc, &output}
	times, list_times: [timing.TIMED]i64
	size, list_size: int
	h := CHECK_OFFSET
	for i in 0 ..< timing.WARMUP + timing.TIMED {
		start := time.tick_now()
		text, err := records.marshal(value.logs, &plan, json.as(.Json), allocator = fixed)
		d := i64(time.tick_since(start))
		if i == 0 {
			for b in text {
				h = (h ~ u64(b)) * CHECK_PRIME
			}
		}
		size = len(text)
		start = time.tick_now()
		list, lerr := write.marshal(value.logs, &list_plan, {}, fixed)
		ld := i64(time.tick_since(start))
		if err != nil || lerr != nil {
			fmt.eprintln("write:", err, lerr)
			os.exit(1)
		}
		list_size = len(list)
		if i >= timing.WARMUP {
			times[i - timing.WARMUP], list_times[i - timing.WARMUP] = d, ld
		}
	}
	median, list_median := timing.median(&times), timing.median(&list_times)
	fmt.printfln(
		"gb_per_s=%.3f best=%.3f ns=%d out=%d check=%d list_gb_per_s=%.3f list_best=%.3f",
		f64(size) / f64(median),
		f64(size) / f64(times[0]),
		median,
		size,
		h,
		f64(list_size) / f64(list_median),
		f64(list_size) / f64(list_times[0]),
	)
}
