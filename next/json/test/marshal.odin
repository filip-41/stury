package json_tests

import "core:math"
import "core:testing"
import "core:time"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:testkit"

// The typed write: a value written by its type's plan reads back as the value, through each option of the plan.

@(private = "file")
Mode :: enum u8 {
	Off,
	On,
	Auto = 5,
}

@(private = "file")
Flags :: bit_set[Mode]

@(private = "file")
Inner :: struct {
	a: int,
	b: string,
}

@(private = "file")
Either :: union {
	int,
	string,
}

@(private = "file")
Kitchen :: struct {
	name:    string,
	count:   i32,
	big:     u64,
	neg:     i8,
	ratio:   f64,
	small:   f32,
	ok:      bool,
	mode:    Mode,
	flags:   Flags,
	list:    []int,
	dyn:     [dynamic]string,
	fixed:   [3]u8,
	inner:   Inner,
	ptr:     ^Inner,
	maybe:   Maybe(int),
	either:  Either,
	table:   map[string]int,
	by_int:  map[int]bool,
	by_mode: map[Mode]string,
	renamed: int `json:"other"`,
	hidden:  int `json:"-"`,
	empty:   string `json:",omitempty"`,
	unset:   Maybe(int) `json:",omitunset"`,
	at:      time.Time,
	nested:  [][]Inner,
}

@(private = "file")
Chain :: struct {
	next: ^Chain,
}

@(private = "file")
marshal_text :: proc(t: ^testing.T, value: ^$T, opts := json.Write_Options{}, plan: ^json.Plan = nil) -> (text: string, ok: bool) {
	bytes, err := json.marshal(value, opts, plan, context.temp_allocator)
	testing.expectf(t, err == nil, "marshal: %v", err)
	return string(bytes), err == nil
}

@(test)
a_marshalled_value_reads_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	context.allocator = context.temp_allocator
	extra := Inner{7, "x\ny"}
	k := Kitchen{
		name = "kitchen \"sink\"", count = -5, big = max(u64), neg = -128, ratio = 0.1, small = 1.5, ok = true, mode = .Auto, flags = {.Off, .Auto},
		list = []int{1, 2, 3}, fixed = {9, 8, 7}, inner = {1, "in"}, ptr = &extra, maybe = 4, either = "s", renamed = 11, hidden = 99,
		at = time.unix(1_700_000_000, 5_000_000), nested = [][]Inner{{{1, "a"}}, {}},
	}
	append(&k.dyn, "p", "q")
	k.table["one"], k.table["two"] = 1, 2
	k.by_int[-3], k.by_int[40] = true, false
	k.by_mode[.On], k.by_mode[.Auto] = "on", "auto"
	plan, perr := json.plan_make(Kitchen)
	testing.expectf(t, perr == nil, "%v", perr)
	for opts in ([?]json.Write_Options{{}, {indent = 2}, {tab = true}, {ascii = true}}) {
		text, ok := marshal_text(t, &k, opts, &plan)
		if !ok {
			return
		}
		back: Kitchen
		err := json.unmarshal(transmute([]u8)text, &back, .Json, {plan = &plan})
		testing.expectf(t, err == nil, "%v: %s", err, text)
		testing.expectf(t, back.name == k.name && back.count == k.count && back.big == k.big && back.neg == k.neg && back.ratio == k.ratio && back.small == k.small, "scalars: %s", text)
		testing.expectf(t, back.ok && back.mode == .Auto && back.flags == k.flags && back.fixed == k.fixed && back.inner == k.inner && back.renamed == 11, "values: %s", text)
		testing.expectf(t, back.hidden == 0 && back.ptr != nil && back.ptr^ == extra && back.maybe == 4 && back.either == "s", "wrappers: %s", text)
		testing.expectf(t, len(back.list) == 3 && back.list[2] == 3 && len(back.dyn) == 2 && back.dyn[1] == "q" && len(back.nested) == 2 && len(back.nested[1]) == 0, "lists: %s", text)
		testing.expectf(t, back.table["two"] == 2 && back.by_int[-3] && !back.by_int[40] && back.by_mode[.On] == "on" && len(back.by_mode) == 2, "maps: %s", text)
		testing.expectf(t, time.diff(back.at, k.at) == 0, "time: %s", text)
		again, _ := marshal_text(t, &back, opts, &plan)
		testing.expectf(t, len(again) == len(text), "a second write differs in length:\n%s\n%s", text, again)
	}
	text, _ := marshal_text(t, &k)
	testing.expectf(t, !contains(text, `"hidden"`) && !contains(text, `"empty"`) && !contains(text, `"unset"`) && contains(text, `"other":11`), "tags: %s", text)
	testing.expectf(t, contains(text, `"flags":["Off","Auto"]`) && contains(text, `"mode":"Auto"`) && contains(text, `"by_int":{`), "enums: %s", text)
}

@(private = "file")
contains :: proc(s, sub: string) -> bool {
	for i in 0 ..= len(s) - len(sub) {
		if s[i:][:len(sub)] == sub {
			return true
		}
	}
	return false
}

@(test)
enums_by_value_read_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	context.allocator = context.temp_allocator
	plan, perr := json.plan_make(Mode, {enums = .Int})
	testing.expect(t, perr == nil)
	mode := Mode.Auto
	text, _ := marshal_text(t, &mode, {}, &plan)
	testing.expect_value(t, text, "5")
	back: Mode
	err := json.unmarshal(transmute([]u8)text, &back, .Json, {plan = &plan})
	testing.expect(t, err == nil && back == .Auto)
}

@(test)
a_marshalled_chain_nests_without_recursion :: proc(t: ^testing.T) {
	testkit.deadline(t)
	context.allocator = context.temp_allocator
	head: Chain
	at := &head
	for _ in 0 ..< 4000 {
		at.next = new(Chain)
		at = at.next
	}
	text, ok := marshal_text(t, &head)
	if !ok {
		return
	}
	testing.expect_value(t, len(text), 4001 * len(`{"next":`) + len("null") + 4001)
	deep: Chain
	at = &deep
	for _ in 0 ..< 20000 {
		at.next = new(Chain)
		at = at.next
	}
	_, err := json.marshal(&deep, {}, nil, context.temp_allocator)
	refused, is_refused := err.(write.Refused)
	testing.expectf(t, is_refused && refused.why == .Malformed, "past the depth: %v", err)
}

@(test)
a_value_with_no_json_spelling_is_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	nan := math.nan_f64()
	_, err := json.marshal(&nan, {}, nil, context.temp_allocator)
	refused, ok := err.(write.Refused)
	testing.expectf(t, ok && refused.why == .No_Spelling, "%v", err)
	raw: struct {
		r: json.Raw,
	}
	_, err = json.marshal(&raw, {}, nil, context.temp_allocator)
	bad, is_bad := err.(tape.Bad_Option)
	testing.expectf(t, is_bad && bad.option == "raw", "%v", err)
}
