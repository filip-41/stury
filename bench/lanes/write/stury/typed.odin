package write_bench

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:time"
import core "../../../../core"
import "../../../formats"
import "../../../timing"
import typed "../../../../core/typed"
import write "../../../../core/write"
import records "../../../../core/records"
import json "../../../../json"
import model "../../../../core/model"

Log_Record :: struct {
	ts, level, service, msg: string,
	status, bytes:           i64,
	duration_ms:             f64,
	id:                      string,
}
Logs :: struct {
	logs: []Log_Record,
}
// The records of logs.xml: a `logs` element of `log` elements.
Logs_Xml :: struct {
	logs: struct {
		log: []Log_Record,
	},
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

typed_lane :: proc(src: []u8, name: string, pretty, dump: bool, kind: formats.Kind) {
	switch name {
	case "logs":
		if kind == .Xml {
			lane(Logs_Xml, src, pretty, dump, kind)
		} else {
			lane(Logs, src, pretty, dump, kind)
		}
	case "twitter":
		lane(Twitter, src, pretty, dump, kind)
	case "citm_catalog":
		lane(Citm, src, pretty, dump, kind)
	case "canada":
		lane(Canada, src, pretty, dump, kind)
	case "nested":
		lane([]Nested_Record, src, pretty, dump, kind)
	case "wide":
		lane(map[string]i64, src, pretty, dump, kind)
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

// A writer that takes more than one block from its allocator, as TOML's does, gets each from the bytes in turn. A pass
// starts again at the first byte, so every pass writes over the same bytes.
Bump_Output :: struct {
	bytes: []u8,
	used:  int,
}

bump_output_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, align: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	b := (^Bump_Output)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		at := mem.align_forward_int(b.used, max(align, 1))
		if at + size > len(b.bytes) {
			return nil, .Out_Of_Memory
		}
		b.used = at + size
		block := b.bytes[at:at + size]
		if old != nil {
			copy(block, ([^]u8)(old)[:min(old_size, size)])
		}
		return block, nil
	}
	return nil, nil
}

// With `dump`, the pass is `model.dump` of the value by a model of `T` with no rules, in place of `write.marshal`.
lane :: proc($T: typeid, src: []u8, pretty, dump: bool, kind: formats.Kind) {
	value: T
	if kind == .Json {
		if err := json.unmarshal(src, .Json, &value); err != nil {
			fmt.eprintln("read:", err)
			os.exit(1)
		}
	} else {
		reading, rerr := formats.plan(T, kind)
		if rerr != nil {
			fmt.eprintln("plan:", rerr)
			os.exit(1)
		}
		if err := typed.unmarshal_text(src, &value, T, &reading, {}, context.allocator); err != nil {
			fmt.eprintln("read:", err)
			os.exit(1)
		}
	}
	plan: typed.Plan
	perr: core.Error
	if kind == .Json {
		plan, perr = json.plan_make(T, plan = {}, allocator = context.allocator)
	} else {
		plan, perr = formats.plan(T, kind, true)
	}
	if perr != nil {
		fmt.eprintln("plan:", perr)
		os.exit(1)
	}
	m, merr := model.compile(nil, T, json.checks(.Json))
	if merr != nil {
		fmt.eprintln("model:", merr)
		os.exit(1)
	}
	output := Fixed_Output{make([]u8, 16 * len(src) + 64 * mem.Kilobyte)}
	fixed := runtime.Allocator{fixed_output_proc, &output}
	bump := Bump_Output{bytes = output.bytes}
	if kind != .Json {
		fixed = runtime.Allocator{bump_output_proc, &bump}
	}
	opts := core.Write_Options{pretty = pretty, indent = 2}
	times: [timing.TIMED]i64
	text: []u8
	// The walk's own scratch, a map's sorted keys among it, comes from an arena emptied after each pass, so the lane's
	// resident memory is one pass's and not the allocator's lag in returning forty-three.
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	for i in 0 ..< timing.WARMUP + timing.TIMED {
		context.allocator = virtual.arena_allocator(&scratch)
		bump.used = 0
		start := time.tick_now()
		out: []u8
		err: core.Error
		if dump {
			out, err = model.dump(&m, &value, write = opts, allocator = fixed)
		} else {
			out, err = write.marshal(value, &plan, opts, fixed)
		}
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
	h := checksum(text) if kind == .Json else readback(text, kind)
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
	h: u64
	for i in 0 ..< timing.WARMUP + timing.TIMED {
		start := time.tick_now()
		text, err := records.marshal(value.logs, &plan, json.as(.Json), allocator = fixed)
		d := i64(time.tick_since(start))
		if i == 0 {
			h = checksum(text)
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
