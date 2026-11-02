// `time <lane> <file> <iters>`: prints best and median GB/s. `oracle <shape> <cases>`: reads each case of a file of
// u32-length-prefixed inputs and prints one line per case, `R` or the value. Both arms print the same text for the
// same result, so the oracle is a diff of the two outputs.
package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

Log_Record :: struct { ts, level, service, msg: string, status, bytes: i64, duration_ms: f64, id: string }
Logs_Doc :: struct { logs: []Log_Record }
Log_Narrow :: struct { ts, level, service, msg: string, status: i32, bytes: u32, duration_ms: f32, id: string }
Logs_Narrow :: struct { logs: []Log_Narrow }
Tweet_Metadata :: struct { result_type, iso_language_code: string }
Twitter_User :: struct {
	id: i64, id_str, name, screen_name, location, description, created_at: string,
	followers_count, friends_count, listed_count, favourites_count, statuses_count: i64,
	lang: string, verified, protected: bool,
}
Tweet :: struct {
	metadata: Tweet_Metadata, created_at: string, id: i64, id_str, text, source: string, truncated: bool,
	retweet_count, favorite_count: i64, lang: string, user: Twitter_User,
}
Twitter :: struct { statuses: []Tweet }
CITM_Event :: struct { id: i64, name: string, subTopicIds, topicIds: []i64 }
CITM_Price :: struct { amount, audienceSubCategoryId, seatCategoryId: i64 }
CITM_Perf :: struct { eventId, id, start: i64, venueCode: string, prices: []CITM_Price }
CITM :: struct {
	areaNames, blockNames: map[string]string, events: map[string]CITM_Event, performances: []CITM_Perf,
	topicSubTopics: map[string][]i64, venueNames: map[string]string,
}

// The oracle's shapes: every width, nesting, each list kind, a map, a recursive type, a key past the record's 13 bytes.
Rec :: struct { id: i64, small: i8, level: string, ok: bool, score: f64, u: u32 }
Inner :: struct { a: i16, b: [3]u8, c: []string }
Mix :: struct {
	r: Rec, i: Inner, xs: []Inner, ys: [dynamic]f32, m: map[string]Rec, grid: [2][2]i32,
	a_very_long_field_name: u16, w: u64, big: i64, f: f64,
}
Color :: enum u8 { Red, Green, Blue = 7 }
Point :: struct { x, y: i32 }
Opt :: struct {
	a: Maybe(i32), b: ^Rec, c: Maybe(string), d: ^[]i32, e: Color, f: Maybe(Point), g: []^Point, h: Maybe(^Point),
	i: []Maybe(i64), j: map[string]^Point, k: ^Opt, l: ^map[string]i32, m: Maybe([]string), n: [2]Maybe(u8),
}
Tree :: struct { v: i32, kids: []Tree, by: map[string]Tree }
Dir :: enum { North, South }
Base :: struct { base_id: i32, base_name: string }
Feat :: struct {
	using base: Base,
	renamed_src: i32 `json:"ren"`,
	skipped: i32 `json:"-"`,
	e: Color, es: bit_set[Color; u8], bs: bit_set[0 ..< 12], ca: [Dir]i32, cs: cstring,
	mi: map[i32]string, me: map[Color]i32, mu: map[u8]bool,
	bw: b32, bn: b8,
	u: union { i64, string, []i32 }, nn: union #no_nil { bool, string },
	r: Raw_T, rs: []Raw_T, dg: Digits_T,
}
Req :: struct { a: i32 `json:"a,required"`, b: string `json:"b,required"`, c: ^Req, d: []Req }
// Members past the width of one word of repeat tracking.
Wide :: struct {
	f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24, f25, f26, f27, f28, f29, f30, f31, f32, f33, f34, f35, f36, f37, f38, f39, f40, f41, f42, f43, f44, f45, f46, f47, f48, f49, f50, f51, f52, f53, f54, f55, f56, f57, f58, f59, f60, f61, f62, f63, f64, f65, f66, f67, f68: i32,
	f69: []i32,
	f70: Rec `json:"f70,required"`,
}
Tag_A :: struct { x: i32 }
Tag_B :: struct { y: string }
Tagged :: union { Tag_A, Tag_B }
Holder :: struct { t: Tagged, ts: []Tagged, p: ^Tagged }
Hex :: struct { n: i64 }
Hooked :: struct { v: Hex, vs: []Hex }
Anys :: struct { a: any, d: Decoded_T, l: []any }

Table_Row :: struct { id, ts: i64, lat, lon: f64, qty: i64, price, score: f64, ok: bool, code: string }
Text_Row :: struct { id: i64, name, city, quote, note: string }
Cell_Row :: struct {
	id: i64, small: i8, level: string, ok: bool, score: f64, u: f32, name_past_thirteen_bytes: u32,
	may: Maybe(i32), mays: Maybe(string), color: Color, cs: cstring, w: u16, hex: Hex,
}
Cell_Required :: struct { a: i32 `csv:"a,required"`, b: string `csv:"b,required"`, c: f64 }

// Why the last read of a delimited text was refused, the way each arm's `rd_cells` writes it.
why_refused: string

// `CELLS` picks the delimited text read.
read_any :: proc(src: []u8, d: ^$T, a: runtime.Allocator, $CELLS: bool) -> bool {
	when CELLS {
		return rd_cells(src, d, a)
	} else {
		return rd(src, d, a)
	}
}

time_lane :: proc($T: typeid, src: []u8, iters: int, $CELLS: bool) {
	backing, _ := make([]u8, 1 << 30, context.allocator)
	ar: mem.Arena
	mem.arena_init(&ar, backing)
	alloc := mem.arena_allocator(&ar)
	ts := make([]f64, iters)
	for i in 0 ..< iters {
		mem.arena_free_all(&ar)
		d: T
		t0 := time.tick_now()
		ok := read_any(src, &d, alloc, CELLS)
		ts[i] = time.duration_seconds(time.tick_since(t0))
		if !ok {
			fmt.println("REFUSED")
			os.exit(1)
		}
	}
	slice.sort(ts)
	fmt.printf("%.3f %.3f\n", f64(len(src)) / ts[0] / 1e9, f64(len(src)) / ts[iters / 2] / 1e9)
}

// Writes `v`, with a map's entries sorted, so two reads compare whatever order their maps hold entries in.
canon :: proc(b: ^strings.Builder, v: any) {
	ti := runtime.type_info_base(type_info_of(v.id))
	if arm_canon(b, v) {
		return
	}
	#partial switch t in ti.variant {
	case runtime.Type_Info_Any:
		a := (^any)(v.data)^
		if a.data == nil {
			strings.write_string(b, "nil")
		} else {
			canon(b, a)
		}
	case runtime.Type_Info_Struct:
		strings.write_byte(b, '{')
		for i in 0 ..< int(t.field_count) {
			canon(b, reflect.struct_field_value_by_name(v, t.names[i]))
			strings.write_byte(b, ',')
		}
		strings.write_byte(b, '}')
	case runtime.Type_Info_Slice, runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Array, runtime.Type_Info_Enumerated_Array:
		strings.write_byte(b, '[')
		n := reflect.length(v)
		for i in 0 ..< n {
			canon(b, reflect.index(v, i))
			strings.write_byte(b, ',')
		}
		strings.write_byte(b, ']')
	case runtime.Type_Info_Map:
		rows: [dynamic]string
		it: int
		for k, val in reflect.iterate_map(v, &it) {
			e := strings.builder_make(context.temp_allocator)
			canon(&e, k)
			strings.write_byte(&e, ':')
			canon(&e, val)
			append(&rows, strings.to_string(e))
		}
		slice.sort(rows[:])
		strings.write_byte(b, '<')
		for r in rows {
			strings.write_string(b, r)
			strings.write_byte(b, ',')
		}
		strings.write_byte(b, '>')
	case runtime.Type_Info_Pointer:
		p := (^rawptr)(v.data)^
		if p == nil {
			strings.write_string(b, "nil")
		} else {
			canon(b, any{p, t.elem.id})
		}
	case runtime.Type_Info_Union:
		e := reflect.get_union_variant(v)
		if e.data == nil {
			strings.write_string(b, "nil")
		} else {
			canon(b, e)
		}
	case runtime.Type_Info_Float:
		if f, ok := reflect.as_f64(v); ok {
			fmt.sbprintf(b, "%x", transmute(u64)f)
		}
	case:
		fmt.sbprintf(b, "%q" if ti.id == string else "%v", v)
	}
}

oracle :: proc($T: typeid, cases: []u8, $CELLS: bool) {
	backing, _ := make([]u8, 1 << 26, context.allocator)
	ar: mem.Arena
	mem.arena_init(&ar, backing)
	out := strings.builder_make()
	// With a fifth argument `seed`, each read goes over the value the first case reads as: what a read keeps, merges and
	// replaces in a value that already holds data.
	prefill := len(os.args) > 4 && os.args[4] == "seed"
	first := cases[4:][:int((^u32le)(&cases[0])^)]
	i, at := 0, 0
	for at < len(cases) {
		n := int((^u32le)(&cases[at])^)
		// A copy at the end of its own allocation, so the sanitizer build sees a read past the text.
		src := make([]u8, n)
		copy(src, cases[at + 4:][:n])
		at += 4 + n
		if len(os.args) > 4 && !prefill {
			fmt.eprintln("case", i)
		}
		mem.arena_free_all(&ar)
		free_all(context.temp_allocator)
		d: T
		if prefill {
			// What a refused read leaves is not part of the contract the two share.
			if !read_any(first, &d, mem.arena_allocator(&ar), CELLS) {
				d = {}
			}
		}
		read := read_any(src, &d, mem.arena_allocator(&ar), CELLS)
		when CELLS {
			// A record separator ends each case, since a value may hold a line feed.
			strings.builder_reset(&out)
			canon(&out, d)
			fmt.printf("%s\x1e\n", strings.to_string(out) if read else why_refused)
		} else {
			if read {
				strings.builder_reset(&out)
				canon(&out, d)
				fmt.println(strings.to_string(out))
			} else {
				fmt.println("R")
			}
		}
		delete(src)
		i += 1
	}
}

main :: proc() {
	src, _ := os.read_entire_file(os.args[3], context.allocator)
	if os.args[1] == "time" {
		iters, _ := strconv.parse_int(os.args[4])
		switch os.args[2] {
		case "logs": time_lane(Logs_Doc, src, iters, false)
		case "narrow": time_lane(Logs_Narrow, src, iters, false)
		case "twitter": time_lane(Twitter, src, iters, false)
		case "citm": time_lane(CITM, src, iters, false)
		case "table": time_lane([]Table_Row, src, iters, true)
		case "text": time_lane([]Text_Row, src, iters, true)
		}
		return
	}
	switch os.args[2] {
	case "Opt": oracle(Opt, src, false)
	case "Rec": oracle(Rec, src, false)
	case "Recs": oracle([]Rec, src, false)
	case "Mix": oracle(Mix, src, false)
	case "Tree": oracle(Tree, src, false)
	case "Twitter": oracle(Twitter, src, false)
	case "CITM": oracle(CITM, src, false)
	case "Int": oracle(i32, src, false)
	case "Text": oracle(string, src, false)
	case "Grid": oracle([][]f64, src, false)
	case "Feat": oracle(Feat, src, false)
	case "Req": oracle(Req, src, false)
	case "Wide": oracle(Wide, src, false)
	case "Holder": oracle(Holder, src, false)
	case "Hooked": oracle(Hooked, src, false)
	case "Anys": oracle(Anys, src, false)
	case "Cell_Rec": oracle([]Cell_Row, src, true)
	case "Cell_Req": oracle([]Cell_Required, src, true)
	case "Cell_Table": oracle([]Table_Row, src, true)
	case "Cell_Dyn": oracle([dynamic]Cell_Required, src, true)
	case "Cell_List": oracle([][]string, src, true)
	case "Cell_Maybes": oracle([][]Maybe(i32), src, true)
	case "Cell_Map": oracle([]map[string]string, src, true)
	case "Cell_Ints": oracle([]map[string]i64, src, true)
	}
}
