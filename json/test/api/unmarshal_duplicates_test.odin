package json_tests

// `Unmarshal_Opts.duplicates` on a member an object repeats: `.First` reads the first occurrence only, `.Last`
// resets the member and reads the last, `.All` reads each over the one before. Struct, slice, map, `any` and
// `Raw` members, a malformed repeat under `.Strict` and `.Lazy`, and documents around the lazy shape walk's gate.

import json "../.."
import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
Dup_Inner :: struct {
	a:    int,
	b:    string,
	tags: []int,
}

@(private = "file")
Dup_Doc :: struct {
	inner: Dup_Inner,
	list:  []int,
	m:     map[string]int,
	deep:  map[string]Dup_Inner,
	x:     any,
	r:     json.Raw,
}

@(private = "file")
DUP_TEXT :: `{"inner":{"a":1,"b":"x","tags":[1,2,3]},"list":[1,2,3],"m":{"p":1,"q":2},"deep":{"k":{"a":1,"b":"y"}},"x":{"k":1},"r":[1],` +
	`"inner":{"a":2,"tags":[9]},"list":[9],"m":{"q":5},"deep":{"k":{"a":5}},"x":{"j":2},"r":[2]}`

@(private = "file")
dup_read :: proc(t: ^testing.T, src: string, mode: json.Duplicates, strictness := json.Strictness.Strict, loc := #caller_location) -> (v: Dup_Doc) {
	um_ok(t, src, &v, {duplicates = mode, strictness = strictness}, loc = loc)
	return
}

@(private = "file")
dup_ints :: proc(t: ^testing.T, got: []int, want: []int, what: string, loc := #caller_location) {
	testing.expectf(t, fmt.tprint(got) == fmt.tprint(want), "%s: %v, want %v", what, got, want, loc = loc)
}

@(private = "file")
dup_any_key :: proc(t: ^testing.T, x: any, key: string, loc := #caller_location) {
	m, is_map := x.(map[string]any)
	testing.expectf(t, is_map && len(m) == 1 && key in m, "any: %v, want {%q}", x, key, loc = loc)
}

@(test)
test_unmarshal_duplicates_last_resets_each_member :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	v := dup_read(t, DUP_TEXT, .Last)
	testing.expect_value(t, v.inner.a, 2)
	testing.expect_value(t, v.inner.b, "")
	dup_ints(t, v.inner.tags, {9}, "inner.tags")
	dup_ints(t, v.list, {9}, "list")
	testing.expect_value(t, len(v.m), 1)
	testing.expect_value(t, v.m["q"], 5)
	testing.expect_value(t, v.deep["k"].a, 5)
	testing.expect_value(t, v.deep["k"].b, "")
	dup_any_key(t, v.x, "j")
	testing.expect_value(t, string(v.r), "[2]")
}

@(test)
test_unmarshal_duplicates_first_keeps_the_first :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	v := dup_read(t, DUP_TEXT, .First)
	testing.expect_value(t, v.inner.a, 1)
	testing.expect_value(t, v.inner.b, "x")
	dup_ints(t, v.inner.tags, {1, 2, 3}, "inner.tags")
	dup_ints(t, v.list, {1, 2, 3}, "list")
	testing.expect_value(t, len(v.m), 2)
	testing.expect_value(t, v.m["p"], 1)
	testing.expect_value(t, v.m["q"], 2)
	testing.expect_value(t, v.deep["k"].a, 1)
	testing.expect_value(t, v.deep["k"].b, "y")
	dup_any_key(t, v.x, "k")
	testing.expect_value(t, string(v.r), "[1]")
}

@(test)
test_unmarshal_duplicates_all_reads_over :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	v := dup_read(t, DUP_TEXT, .All)
	testing.expect_value(t, v.inner.a, 2)
	testing.expect_value(t, v.inner.b, "x")
	dup_ints(t, v.inner.tags, {9}, "inner.tags")
	dup_ints(t, v.list, {9}, "list")
	testing.expect_value(t, len(v.m), 2)
	testing.expect_value(t, v.m["p"], 1)
	testing.expect_value(t, v.m["q"], 5)
	testing.expect_value(t, v.deep["k"].a, 5)
	testing.expect_value(t, v.deep["k"].b, "y")
	dup_any_key(t, v.x, "j")
	testing.expect_value(t, string(v.r), "[2]")
}

// The same text through `unmarshal_check`, which stores nothing, takes every mode.
@(test)
test_unmarshal_duplicates_check_takes_every_mode :: proc(t: ^testing.T) {
	for mode in ([]json.Duplicates{.First, .Last, .All}) {
		testing.expect_value(t, um_kind(json.unmarshal_check(raw(DUP_TEXT), Dup_Doc, {duplicates = mode})), nil)
	}
}

// A member that holds data before the read: `.Last` and `.All` read the first occurrence over it.
@(test)
test_unmarshal_duplicates_first_occurrence_reads_over_the_target :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for mode in ([]json.Duplicates{.Last, .All}) {
		v := Dup_Doc{inner = {a = 7, b = "old"}}
		um_ok(t, `{"inner":{"a":1}}`, &v, {duplicates = mode})
		testing.expect_value(t, v.inner.a, 1)
		testing.expect_value(t, v.inner.b, "old")
	}
}

// A repeat that is not well formed. A value that is read is checked under both strictnesses, `.First` stores
// nothing of the repeat, and under `.Lazy` may accept or refuse it.
@(test)
test_unmarshal_duplicates_malformed_repeat :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	srcs := []string{`{"a":1,"a":tru}`, `{"a":1,"a":[1,}`, `{"a":1,"a":"x"}`, `{"a":1,"a":01}`}
	for src in srcs {
		for strictness in ([]json.Strictness{.Strict, .Lazy}) {
			for mode in ([]json.Duplicates{.Last, .All}) {
				v: struct{ a: int }
				err := json.unmarshal(raw(src), &v, {duplicates = mode, strictness = strictness}, allocator = context.temp_allocator)
				testing.expectf(t, err != nil, "%s %v %v: accepted", src, strictness, mode)
			}
			v: struct{ a: int }
			err := json.unmarshal(raw(src), &v, {duplicates = .First, strictness = strictness}, allocator = context.temp_allocator)
			if strictness == .Strict {
				testing.expectf(t, err != nil, "%s Strict .First: accepted", src)
			}
			if err == nil {
				testing.expectf(t, v.a == 1, "%s %v .First: a = %d", src, strictness, v.a)
			}
		}
	}
}

// The lazy shape walk takes its skipping route from SHAPE_LAZY_MIN_BYTES (16 KiB) of document: documents just
// under, at and over it, padded with short values nothing reads and with white space, read alike.
@(test)
test_unmarshal_duplicates_around_the_lazy_gate :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	GATE :: 16 << 10
	for size in ([]int{GATE - 1, GATE, GATE + 1, 4 * GATE}) {
		for pad_kind in 0 ..< 2 {
			b: strings.Builder
			strings.builder_init(&b, context.temp_allocator)
			strings.write_string(&b, `{"inner":{"a":1,"b":"x","tags":[1,2,3]},"list":[1,2,3],"m":{"p":1},`)
			if pad_kind == 0 {
				strings.write_string(&b, `"pad":[`)
				for strings.builder_len(b) < size - 160 {
					strings.write_string(&b, `[0,1],`)
				}
				strings.write_string(&b, `0],`)
			}
			strings.write_string(&b, `"inner":{"a":2,"tags":[9]},"list":[9],"m":{"q":5}`)
			for strings.builder_len(b) < size - 1 {
				strings.write_byte(&b, ' ')
			}
			strings.write_byte(&b, '}')
			src := strings.to_string(b)
			testing.expect_value(t, len(src), size)
			for strictness in ([]json.Strictness{.Strict, .Lazy}) {
				last := dup_read(t, src, .Last, strictness)
				testing.expectf(t, last.inner.a == 2 && last.inner.b == "" && len(last.m) == 1, "Last %d %v: %v", size, strictness, last)
				dup_ints(t, last.inner.tags, {9}, "Last tags")
				first := dup_read(t, src, .First, strictness)
				testing.expectf(t, first.inner.a == 1 && first.inner.b == "x" && len(first.m) == 1, "First %d %v: %v", size, strictness, first)
				dup_ints(t, first.inner.tags, {1, 2, 3}, "First tags")
				all := dup_read(t, src, .All, strictness)
				testing.expectf(t, all.inner.a == 2 && all.inner.b == "x" && len(all.m) == 2, "All %d %v: %v", size, strictness, all)
				dup_ints(t, all.inner.tags, {9}, "All tags")
			}
		}
	}
}
