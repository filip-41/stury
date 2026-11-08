package records_tests

import "core:bytes"
import "core:io"
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"
import core "../.."
import typed "../../typed"
import write "../../write"
import records ".."
import dsv "../../../dsv"
import json "../../../json"

// The record writer against the one-value writer: a list written as records is each value's text with its frame, and
// reads back as the list.

Entry :: struct {
	id:    i64,
	name:  string,
	ok:    bool,
	score: f64,
}

ENTRIES := [?]Entry{{1, "plain", true, 0.5}, {-2, "a,b \"q\"", false, -1e300}, {3, "café\n日本", true, 3}, {4, "", false, 0}}

@(test)
json_records_are_framed_values :: proc(t: ^testing.T) {
	plan, _ := json.plan_make(Entry)
	defer typed.plan_destroy(&plan)
	for framing in ([?]core.Framing{.Lines, .Seq, .Concatenated}) {
		want: strings.Builder
		defer strings.builder_destroy(&want)
		for v in ENTRIES {
			if framing == .Seq {
				strings.write_byte(&want, 0x1E)
			}
			text, _ := write.marshal(v, &plan, {}, context.temp_allocator)
			strings.write_string(&want, string(text))
			strings.write_byte(&want, '\n')
		}
		got, err := records.marshal(ENTRIES[:], &plan, json.as(.Json), framing, allocator = context.temp_allocator)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
		testing.expect_value(t, string(got), strings.to_string(want))

		buf: bytes.Buffer
		defer bytes.buffer_destroy(&buf)
		testing.expect_value(t, records.marshal_stream(bytes.buffer_to_stream(&buf), ENTRIES[:], &plan, json.as(.Json), framing).kind, core.Typed_Error_Kind.None)
		testing.expect_value(t, string(bytes.buffer_to_bytes(&buf)), string(got))

		// Read back, a record per frame.
		lines := strings.split(strings.trim_right(string(got), "\n"), "\n", context.temp_allocator)
		testing.expect_value(t, len(lines), len(ENTRIES))
		for line, i in lines {
			back: Entry
			text := strings.trim_prefix(line, "\x1e") if framing == .Seq else line
			testing.expect_value(t, json.unmarshal(transmute([]u8)text, .Json, &back, allocator = context.temp_allocator).kind, core.Typed_Error_Kind.None)
			testing.expect_value(t, back, ENTRIES[i])
		}
	}
}

@(test)
dsv_records_are_the_rows_text :: proc(t: ^testing.T) {
	row_plan, perr := dsv.plan_make(Entry, .Csv)
	testing.expect_value(t, perr.kind, core.Typed_Error_Kind.None)
	defer typed.plan_destroy(&row_plan)
	list_plan, _ := dsv.plan_make([]Entry, .Csv)
	defer typed.plan_destroy(&list_plan)
	want, _ := write.marshal(ENTRIES[:], &list_plan, {}, context.temp_allocator)
	got, err := records.marshal(ENTRIES[:], &row_plan, dsv.as(.Csv), allocator = context.temp_allocator)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(got), string(want))
	back: []Entry
	testing.expect_value(t, dsv.unmarshal(got, .Csv, &back, read = {}, opts = {}, allocator = context.temp_allocator).kind, core.Typed_Error_Kind.None)
	testing.expect(t, len(back) == len(ENTRIES))
	for v, i in back {
		testing.expect_value(t, v, ENTRIES[i])
	}

	// A list row has no header, and a map row's header is the first row's keys.
	cells := [][]string{{"a", "b"}, {"x,y", ""}}
	cells_plan, _ := dsv.plan_make([]string, .Csv)
	defer typed.plan_destroy(&cells_plan)
	text, cerr := records.marshal(cells, &cells_plan, dsv.as(.Csv), allocator = context.temp_allocator)
	testing.expect_value(t, cerr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), "a,b\n\"x,y\",\"\"\n")

	map_plan, _ := dsv.plan_make(map[string]string, .Csv)
	defer typed.plan_destroy(&map_plan)
	wr: records.Writer
	records.writer_init(&wr, {}, dsv.as(.Csv), allocator = context.temp_allocator)
	defer records.writer_destroy(&wr)
	maps: [3]map[string]string
	maps[0]["b"], maps[0]["a"], maps[1]["b"], maps[2]["c"] = "2", "1", "3", "4"
	defer for m in maps {
		delete(m)
	}
	testing.expect_value(t, records.write(&wr, maps[0], &map_plan), core.Typed_Error_Kind.None)
	testing.expect_value(t, records.write(&wr, maps[1], &map_plan), core.Typed_Error_Kind.None)
	testing.expect_value(t, records.write(&wr, maps[2], &map_plan), core.Typed_Error_Kind.Unwritable)
	text, cerr = records.writer_end(&wr)
	testing.expect_value(t, cerr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), "a,b\n1,2\n,3\n")
}

@(test)
refused_record_is_taken_back :: proc(t: ^testing.T) {
	plan, _ := json.plan_make(Entry)
	defer typed.plan_destroy(&plan)
	wr: records.Writer
	records.writer_init(&wr, {}, json.as(.Json), .Seq, allocator = context.temp_allocator)
	defer records.writer_destroy(&wr)
	records.write(&wr, ENTRIES[0], &plan)
	testing.expect_value(t, records.write(&wr, Entry{name = "half", score = math.nan_f64()}, &plan), core.Typed_Error_Kind.Non_Finite)
	testing.expect_value(t, wr.err.n_steps, 1)
	testing.expect_value(t, records.write(&wr, 7, &plan), core.Typed_Error_Kind.Plan_Mismatch)
	records.write_text(&wr, transmute([]u8)string(`{"id":9}`))
	text, end := records.writer_end(&wr)
	testing.expect_value(t, end.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), "\x1e{\"id\":1,\"name\":\"plain\",\"ok\":true,\"score\":0.5}\n\x1e{\"id\":9}\n")
}

@(test)
refusal_after_a_flush_is_final :: proc(t: ^testing.T) {
	Long :: struct {
		text: string,
		bad:  f64,
	}
	plan, _ := json.plan_make(Long)
	defer typed.plan_destroy(&plan)
	long := strings.repeat("x", 100_000, context.temp_allocator)
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	wr: records.Writer
	records.writer_init(&wr, bytes.buffer_to_stream(&buf), json.as(.Json))
	defer records.writer_destroy(&wr)
	testing.expect_value(t, records.write(&wr, Long{long, math.nan_f64()}, &plan), core.Typed_Error_Kind.Non_Finite)
	testing.expect_value(t, records.write(&wr, Long{"ok", 1}, &plan), core.Typed_Error_Kind.Non_Finite)
	testing.expect_value(t, records.write_text(&wr, {'1'}), core.Typed_Error_Kind.Non_Finite)
	_, err := records.writer_end(&wr)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Non_Finite)
	testing.expect_value(t, err.n_steps, 1)

	records.writer_init(&wr, bytes.buffer_to_stream(&buf), dsv.as(.Csv))
	testing.expect_value(t, records.write_cells(&wr, {long, "\xff"}), core.Typed_Error_Kind.Invalid_Utf8)
	testing.expect_value(t, records.write_cells(&wr, {"a"}), core.Typed_Error_Kind.Invalid_Utf8)
	_, err = records.writer_end(&wr)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Invalid_Utf8)
}

BOM :: "\xEF\xBB\xBF"

@(test)
cells_keep_the_old_guards :: proc(t: ^testing.T) {
	wr: records.Writer
	records.writer_init(&wr, {}, dsv.as(.Csv), allocator = context.temp_allocator)
	defer records.writer_destroy(&wr)
	records.write_cells(&wr, {BOM + "a", "b"})
	records.write_cells(&wr, {"a", nil, "x,y"})
	testing.expect_value(t, records.write_cells(&wr, {nil}), core.Typed_Error_Kind.Unwritable)
	records.write_cells(&wr, {""})
	testing.expect_value(t, records.write_cells(&wr, {}), core.Typed_Error_Kind.Unwritable)
	testing.expect_value(t, records.write_cells(&wr, {"ok", "\xff"}), core.Typed_Error_Kind.Invalid_Utf8)
	records.write_cells(&wr, {BOM + "not first"})
	testing.expect_value(t, string(records.writer_take(&wr)), "\"" + BOM + "a\",b\na,,\"x,y\"\n\"\"\n" + BOM + "not first\n")
	// A refusal after a take goes back to its own record, which no take passed.
	testing.expect_value(t, records.write_cells(&wr, {"ok", "\xff"}), core.Typed_Error_Kind.Invalid_Utf8)
	records.write_text(&wr, transmute([]u8)string("p,q"))
	text, err := records.writer_end(&wr)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), "p,q\n")

	// Every record of a TSV text ends a line, and an empty one would vanish.
	records.writer_init(&wr, {}, dsv.as(.Tsv), allocator = context.temp_allocator)
	testing.expect_value(t, records.write_cells(&wr, {nil}), core.Typed_Error_Kind.Unwritable)
	testing.expect_value(t, records.write_cells(&wr, {"a\tb", nil}), core.Typed_Error_Kind.None)
	text, err = records.writer_end(&wr)
	testing.expect_value(t, string(text), "a\\tb\t\n")

	// A number by its text and the words keep their kind, and under `infer` a string that would read back as one of them
	// is quoted.
	records.writer_init(&wr, {}, dsv.as(.Csv, {infer = true}), allocator = context.temp_allocator)
	records.write_cells(&wr, {"2", write.Number_Literal{"2"}, write.Tree_Part.True, "true", "x", nil})
	testing.expect_value(t, records.write_cells(&wr, {write.Number_Literal{"2x"}}), core.Typed_Error_Kind.Bad_Raw)
	text, err = records.writer_end(&wr)
	testing.expect_value(t, string(text), "\"2\",2,true,\"true\",x,\n")
	records.writer_init(&wr, {}, dsv.as(.Csv), allocator = context.temp_allocator)
	records.write_cells(&wr, {"2", write.Number_Literal{"2"}, write.Tree_Part.True, "true"})
	text, err = records.writer_end(&wr)
	testing.expect_value(t, string(text), "2,2,true,true\n")
	records.writer_init(&wr, {}, dsv.as(.Tsv, {infer = true}), allocator = context.temp_allocator)
	testing.expect_value(t, records.write_cells(&wr, {"2"}), core.Typed_Error_Kind.Unwritable)
	records.writer_destroy(&wr)

	records.writer_init(&wr, {}, json.as(.Json), allocator = context.temp_allocator)
	testing.expect_value(t, records.write_cells(&wr, {"a"}), core.Typed_Error_Kind.Unsupported)
	text, err = records.writer_end(&wr)
	testing.expect_value(t, len(text), 0)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
}

@(test)
writer_refuses_what_no_record_holds :: proc(t: ^testing.T) {
	wr: records.Writer
	testing.expect_value(t, records.writer_init(&wr, {}, json.as(.Json), .Entries), core.Typed_Error_Kind.Unsupported)
	testing.expect_value(t, records.write_text(&wr, {'1'}), core.Typed_Error_Kind.Unsupported)
	_, err := records.writer_end(&wr)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Unsupported)
	testing.expect_value(t, records.writer_init(&wr, {}, dsv.as(.Csv), .Seq), core.Typed_Error_Kind.Unsupported)
	records.writer_destroy(&wr)
	testing.expect_value(t, records.writer_init(&wr, {}, json.as(.Json), .Lines, core.PRETTY), core.Typed_Error_Kind.Bad_Option)
	records.writer_destroy(&wr)
	testing.expect_value(t, records.writer_init(&wr, {}, json.as(.Json), .Seq, core.PRETTY), core.Typed_Error_Kind.None)
	records.writer_destroy(&wr)

	// A plan of another format, or of a list where a row is due.
	json_plan, _ := json.plan_make(Entry)
	defer typed.plan_destroy(&json_plan)
	list_plan, _ := dsv.plan_make([]Entry, .Csv)
	defer typed.plan_destroy(&list_plan)
	_, err = records.marshal(ENTRIES[:], &json_plan, dsv.as(.Csv))
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Plan_Mismatch)
	_, err = records.marshal([][]Entry{ENTRIES[:]}, &list_plan, dsv.as(.Csv))
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Plan_Mismatch)
}

@(private)
refusing_stream :: proc(_: rawptr, mode: io.Stream_Mode, _: []byte, _: i64, _: io.Seek_From) -> (i64, io.Error) {
	return 0, .Permission_Denied
}

@(test)
failed_stream_is_final :: proc(t: ^testing.T) {
	plan, _ := json.plan_make(Entry)
	defer typed.plan_destroy(&plan)
	list := make([]Entry, 2000, context.temp_allocator)
	err := records.marshal_stream(io.Stream{procedure = refusing_stream}, list, &plan, json.as(.Json))
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Write_Failed)
	testing.expect_value(t, err.cause, io.Error.Permission_Denied)
}

// The bytes a failed output was given go nowhere: a take after the failure has none.
@(test)
failed_buffer_takes_nothing :: proc(t: ^testing.T) {
	plan, _ := json.plan_make(Entry)
	defer typed.plan_destroy(&plan)
	storage: [8192]u8
	arena: mem.Arena
	mem.arena_init(&arena, storage[:])
	wr: records.Writer
	records.writer_init(&wr, {}, json.as(.Json), allocator = mem.arena_allocator(&arena))
	kind := core.Typed_Error_Kind.None
	for i := 0; kind == .None && i < 10_000; i += 1 {
		kind = records.write(&wr, ENTRIES[i % len(ENTRIES)], &plan)
	}
	testing.expect_value(t, kind, core.Typed_Error_Kind.No_Memory)
	testing.expect_value(t, len(records.writer_take(&wr)), 0)
	_, end := records.writer_end(&wr)
	testing.expect_value(t, end.kind, core.Typed_Error_Kind.No_Memory)
	testing.expect_value(t, len(records.writer_take(&wr)), 0)
}

@(test)
calls_after_the_end_are_out_of_order :: proc(t: ^testing.T) {
	plan, _ := json.plan_make(Entry)
	defer typed.plan_destroy(&plan)
	wr: records.Writer
	records.writer_init(&wr, {}, json.as(.Json), allocator = context.temp_allocator)
	records.write(&wr, ENTRIES[0], &plan)
	_, end := records.writer_end(&wr)
	testing.expect_value(t, end.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, records.write(&wr, ENTRIES[1], &plan), core.Typed_Error_Kind.Out_Of_Order)
	testing.expect_value(t, records.write_text(&wr, {'1'}), core.Typed_Error_Kind.Out_Of_Order)
	testing.expect_value(t, records.write_cells(&wr, {"a"}), core.Typed_Error_Kind.Out_Of_Order)
	_, end = records.writer_end(&wr)
	testing.expect_value(t, end.kind, core.Typed_Error_Kind.Out_Of_Order)
	records.writer_destroy(&wr)
}

@(test)
typed_row_after_written_cells_binds_without_a_header :: proc(t: ^testing.T) {
	plan, _ := dsv.plan_make(Entry, .Csv)
	defer typed.plan_destroy(&plan)
	wr: records.Writer
	records.writer_init(&wr, {}, dsv.as(.Csv), allocator = context.temp_allocator)
	records.write_cells(&wr, {"x", "y", "z", "w"})
	testing.expect_value(t, records.write(&wr, ENTRIES[0], &plan), core.Typed_Error_Kind.None)
	records.write_text(&wr, transmute([]u8)string("p,q"))
	testing.expect_value(t, records.write(&wr, ENTRIES[3], &plan), core.Typed_Error_Kind.None)
	text, _ := records.writer_end(&wr)
	testing.expect_value(t, string(text), "x,y,z,w\n1,plain,true,0.5\np,q\n4,\"\",false,0\n")
}

@(test)
plan_of_another_layout_is_a_mismatch :: proc(t: ^testing.T) {
	headless, _ := dsv.plan_make(Entry, .Csv, {no_header = true})
	defer typed.plan_destroy(&headless)
	tsv, _ := dsv.plan_make(Entry, .Tsv)
	defer typed.plan_destroy(&tsv)
	plain, _ := dsv.plan_make(Entry, .Csv)
	defer typed.plan_destroy(&plain)
	_, err := records.marshal(ENTRIES[:], &headless, dsv.as(.Csv), allocator = context.temp_allocator)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Plan_Mismatch)
	_, err = records.marshal(ENTRIES[:], &tsv, dsv.as(.Csv), allocator = context.temp_allocator)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Plan_Mismatch)
	_, err = records.marshal(ENTRIES[:], &plain, dsv.as(.Csv, {no_header = true}), allocator = context.temp_allocator)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Plan_Mismatch)
	text, ok := records.marshal(ENTRIES[:1], &headless, dsv.as(.Csv, {no_header = true}), allocator = context.temp_allocator)
	testing.expect_value(t, ok.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), "1,plain,true,0.5\n")
	text, ok = records.marshal(ENTRIES[:1], &plain, dsv.as(.Csv, {delimiter = ','}), allocator = context.temp_allocator)
	testing.expect_value(t, string(text), "id,name,ok,score\n1,plain,true,0.5\n")
}

@(test)
refused_first_row_lets_another_plan_in :: proc(t: ^testing.T) {
	first, _ := dsv.plan_make(Entry, .Csv)
	defer typed.plan_destroy(&first)
	second, _ := dsv.plan_make(Entry, .Csv)
	defer typed.plan_destroy(&second)
	wr: records.Writer
	records.writer_init(&wr, {}, dsv.as(.Csv), allocator = context.temp_allocator)
	testing.expect_value(t, records.write(&wr, Entry{score = math.inf_f64(1)}, &first), core.Typed_Error_Kind.Non_Finite)
	testing.expect_value(t, records.write(&wr, ENTRIES[0], &second), core.Typed_Error_Kind.None)
	text, _ := records.writer_end(&wr)
	testing.expect_value(t, string(text), "id,name,ok,score\n1,plain,true,0.5\n")
}
