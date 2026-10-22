package json_tests

// The typed descent (`json/scan.shape_descend`) against the shape walk it gives up to. `duplicates = .Refuse`
// always takes the walk, and on a document with no repeated key it reads exactly what the other policies do,
// so each case reads under both and must agree on the value, the capacity a dynamic array gets, and the
// refusal with its offset and path, `unmarshal_check` must refuse alike. The cases sit on the edges where the
// descent gives up: escaped keys, unknown members of every kind, the depth cap, a missing required field,
// length and range faults, and malformed text mid-record.

import json "../.."
import "core:fmt"
import "core:testing"

@(private = "file")
Descent_Inner :: struct {
	a: []f64,
	b: struct {
		c: i64,
	},
}

@(private = "file")
Descent_Rec :: struct {
	id:     i64,
	name:   string,
	tags:   []i32,
	dyn:    [dynamic]u8,
	pair:   [2]i16,
	few:    [dynamic; 3]i64,
	inner:  Descent_Inner,
	ok:     bool,
	always: int `json:",required"`,
}

@(private = "file")
descent_same :: proc(t: ^testing.T, src: string, opts := json.Unmarshal_Opts{}, loc := #caller_location) {
	walk_opts := opts
	walk_opts.duplicates = .Refuse
	got, want: []Descent_Rec
	got_err := json.unmarshal(transmute([]byte)src, &got, opts, nil, context.temp_allocator)
	want_err := json.unmarshal(transmute([]byte)src, &want, walk_opts, nil, context.temp_allocator)
	testing.expectf(t, fmt.tprint(got_err) == fmt.tprint(want_err), "%s: refused %v, the walk %v", src, got_err, want_err, loc = loc)
	testing.expectf(t, fmt.tprint(got) == fmt.tprint(want), "%s: read %v, the walk %v", src, got, want, loc = loc)
	if len(got) == len(want) {
		for g, i in got {
			testing.expectf(t, cap(g.dyn) == cap(want[i].dyn), "%s: dyn cap %d, the walk %d", src, cap(g.dyn), cap(want[i].dyn), loc = loc)
		}
	}
	check_err := json.unmarshal_check(transmute([]byte)src, []Descent_Rec, opts)
	testing.expectf(t, fmt.tprint(check_err) == fmt.tprint(want_err), "%s: checked %v, the walk %v", src, check_err, want_err, loc = loc)
}

@(private = "file")
DESCENT_REC :: `{"id":7,"name":"x","tags":[1,2],"dyn":[1,2,3,4,5,6,7,8,9],"pair":[3,4],"few":[5],"inner":{"a":[0.1,1e-7,-0],"b":{"c":9}},"ok":true,"always":1}`

@(test)
test_unmarshal_descent_reads_as_the_walk :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	descent_same(t, `[]`)
	descent_same(t, `[` + DESCENT_REC + `,` + DESCENT_REC + `]`)
	descent_same(t, ` [ {"always" : 1 , "tags" : [ 1 ] , "inner" : { "b" : { } } } ] `)
	// Keys out of order, escaped, or spelled past sixteen bytes.
	descent_same(t, `[{"ok":false,"always":2,"id":1}]`)
	descent_same(t, `[{"name":"y","id":3,"always":1}]`)
	descent_same(t, `[{"a_name_well_past_sixteen":1,"always":1}]`)
	// Members nothing reads, of every kind.
	descent_same(t, `[{"z":{"q":[1,{"r":null}]},"y":[],"x":"s","w":true,"v":null,"u":-1.5e3,"always":1}]`)
	// Floats at the edges of exactness and range.
	descent_same(t, `[{"inner":{"a":[1.7976931348623157e308,4.9e-324,123456789012345678901234567890.5,9007199254740993,0.30000000000000004]},"always":1}]`)
}

@(test)
test_unmarshal_descent_refuses_as_the_walk :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	descent_same(t, `[{"id":1}]`) // required missing
	descent_same(t, `[{"always":1},{"id":1}]`)
	descent_same(t, `[{"id":"7","always":1}]`)
	descent_same(t, `[{"id":1.5,"always":1}]`)
	descent_same(t, `[{"tags":[2147483648],"always":1}]`)
	descent_same(t, `[{"inner":{"a":[1e400]},"always":1}]`)
	descent_same(t, `[{"pair":[1],"always":1}]`)
	descent_same(t, `[{"pair":[1,2,3],"always":1}]`)
	descent_same(t, `[{"few":[1,2,3,4],"always":1}]`)
	descent_same(t, `[{"inner":null,"always":1}]`)
	descent_same(t, `[{"tags":{},"always":1}]`)
	descent_same(t, `[{"zz":1,"always":1}]`, {unknown_fields = .Refuse})
	// Malformed text mid-record.
	descent_same(t, `[{"id":1,"always":1}`)
	descent_same(t, `[{"id":1,"always":1},]`)
	descent_same(t, `[{"id":1,,"always":1}]`)
	descent_same(t, `[{"id":tru,"always":1}]`)
	descent_same(t, `[{"id" 1,"always":1}]`)
	descent_same(t, `[{"z":[1,}],"always":1}]`)
	descent_same(t, `[{"name":"\x","always":1}]`)
	descent_same(t, `[{"always":1}] x`)
	descent_same(t, `[{"always":01}]`)
}

@(test)
test_unmarshal_descent_depth_cap_as_the_walk :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// The list, a record and `inner.b` open three deep. An unread member reaches as deep.
	for depth in 2 ..= 5 {
		opts := json.Unmarshal_Opts{limits = {max_depth = u64(depth)}}
		descent_same(t, `[{"inner":{"b":{"c":1}},"always":1}]`, opts)
		descent_same(t, `[{"z":[[1]],"always":1}]`, opts)
		descent_same(t, `[{"z":{"y":{}},"always":1}]`, opts)
		descent_same(t, `[{"tags":[1],"always":1}]`, opts)
	}
}

@(test)
test_unmarshal_descent_keeps_what_the_text_lacks :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Kept :: struct {
		a:    int,
		b:    string,
		list: []int,
	}
	v := Kept{a = 1, b = "kept", list = {4}}
	um_ok(t, `{"a":2}`, &v)
	testing.expect_value(t, v.a, 2)
	testing.expect_value(t, v.b, "kept")
	testing.expect_value(t, len(v.list), 1)
	// Given up at the repeat, then read whole by the walk: `.Last` resets the member.
	um_ok(t, `{"b":"x","a":3,"a":4}`, &v, {duplicates = .Last})
	testing.expect_value(t, v.a, 4)
	testing.expect_value(t, v.b, "x")
}

// Long runs of members nothing reads, which the descent passes a block at a time where the processor has
// 512-bit registers: compact integers mostly, with a member of every kind it must leave to the byte loop (a
// number it does not take whole, a key that is escaped, spaced or non-ASCII, a value of another kind, a field's
// own key) dropped in at random places, and the document cut short at random. Each key is its own, since the
// walk it is read against refuses a repeat.
@(test)
test_unmarshal_descent_unread_runs_as_the_walk :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	odd := [?]string{
		`"o%d":0`, `"o%d":-5`, `"o%d":1.5`, `"o%d":1e5`, `"o%d":1234567890123456`, `"o%d":123456789012345`,
		`"o%d":12345678901234567890`, `"o%d":"s"`, `"o%d":null`, `"o%d":true`, `"o%d":[1,2]`, `"o%d":{"p":1}`,
		`"o%d" :1`, `"o%d": 1`, `"o%d":1 `, "\"o%d\":1\n", `"o%d":1`, `"o%d\n":1`, `"é%d":1`, "\"o%d\x01\":1",
		`"o%d":01`, `"o%d":1,`, `"o%d"`, `"i%d":1`, `"na%d":1`, `"idx%d":1`,
	}
	fields := [?]string{`"id":9`, `"name":"y"`, `"ok":false`, `"":1`, `"tags":[2]`}
	state := u64(0x9e3779b97f4a7c15)
	next :: proc(state: ^u64) -> u64 {
		state^ = state^ * 6364136223846793005 + 1442695040888963407
		return state^ >> 33
	}
	for round in 0 ..< 600 {
		src := "[{"
		members := 4 + int(next(&state) % 200)
		field_at := int(next(&state) % u64(members)) if round % 2 == 0 else -1
		for k in 0 ..< members {
			member: string
			switch {
			case k == field_at:
				member = fields[next(&state) % len(fields)]
			case next(&state) % 24 == 0:
				member = fmt.tprintf(odd[next(&state) % len(odd)], k)
			case:
				member = fmt.tprintf(`"k%07d":%d`, k, 1 + next(&state) % 1_000_000_000)
			}
			src = fmt.tprint(src, member, ",", sep = "")
		}
		src = fmt.tprint(src, `"always":1}]`, sep = "")
		if round % 7 == 0 {
			src = src[:next(&state) % u64(len(src))]
		}
		descent_same(t, src)
	}
}
