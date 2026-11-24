package toml_tests

import "base:runtime"
import "core:math"
import "core:strings"
import "core:testing"
import "core:time"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:toml"

// Typed reads of TOML texts: tables into structs, arrays of tables into slices, a table defined in pieces, date-times,
// numbers in every spelling and the refusals with their places.

// Expects `e` to be a refusal `want` at byte `at`.
expect_refusal :: proc(t: ^testing.T, e: tape.Error, want: toml.Refusal, at: u64, loc := #caller_location) {
	f, is_fault := e.(tape.Fault)
	if !testing.expectf(t, is_fault && f.kind == .Refused, "got %v, wanted a refusal %v", e, want, loc = loc) {
		return
	}
	testing.expect_value(t, toml.Refusal(f.detail), want, loc)
	testing.expect_value(t, f.at, at, loc)
}

// Expects `steps` to be the path `want`, a name for a string and an index for an int.
expect_path :: proc(t: ^testing.T, steps: []tape.Step, want: []union {
		int,
		string,
	}, loc := #caller_location) {
	if !testing.expect_value(t, len(steps), len(want), loc) {
		return
	}
	for w, i in want {
		switch v in w {
		case int:
			testing.expect_value(t, steps[i], tape.Step(tape.Index(v)), loc)
		case string:
			testing.expect_value(t, steps[i], tape.Step(tape.Name(v)), loc)
		}
	}
}

Server :: struct {
	host: string,
	port: u16,
	tls:  bool,
}

Config :: struct {
	title:   string,
	servers: []Server,
	owner:   struct {
		name: string,
		born: time.Time,
	},
	tags:    [dynamic]string,
	limits:  map[string]i64,
}

@(test)
tables_read_into_structs_and_arrays_of_tables_into_slices :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := `title = "stury"
tags = ["a", "b"]

[owner]
name = "Tom"
born = 1979-05-27T07:32:00-08:00

[limits]
rows = 10
bytes = 4_096

[[servers]]
host = "alpha"
port = 8080
tls = true

[[servers]]
host = "beta"
port = 9090
`
	got: Config
	e := toml.unmarshal(transmute([]u8)string(src), &got, allocator = context.temp_allocator)
	testing.expect_value(t, e, nil)
	testing.expect_value(t, got.title, "stury")
	testing.expect_value(t, len(got.tags), 2)
	testing.expect_value(t, got.owner.name, "Tom")
	testing.expect_value(t, time.to_unix_nanoseconds(got.owner.born), 296667120e9)
	testing.expect_value(t, got.limits["rows"], 10)
	testing.expect_value(t, got.limits["bytes"], 4096)
	if testing.expect_value(t, len(got.servers), 2) {
		testing.expect_value(t, got.servers[0], Server{"alpha", 8080, true})
		testing.expect_value(t, got.servers[1], Server{"beta", 9090, false})
	}
}

@(test)
inline_tables_and_dotted_keys_name_the_same_members :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Point :: struct {
		x, y: i64,
	}
	Shape :: struct {
		origin: Point,
		size:   Point,
		names:  []Point,
	}
	src := "origin = {x = 1, y = 2}\nsize.x = 3\nsize.y = 4\nnames = [{x = 5, y = 6}, {x = 7}]\n"
	got: Shape
	testing.expect_value(t, toml.unmarshal(transmute([]u8)string(src), &got, allocator = context.temp_allocator), nil)
	testing.expect_value(t, got.origin, Point{1, 2})
	testing.expect_value(t, got.size, Point{3, 4})
	if testing.expect_value(t, len(got.names), 2) {
		testing.expect_value(t, got.names[0], Point{5, 6})
		testing.expect_value(t, got.names[1], Point{7, 0})
	}
}

// A struct defined in pieces reads as one: a deeper header before the shallower one, dotted keys beside a header, and
// an array of tables with a table under it.
@(test)
a_table_in_pieces_defines_one_struct :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Inner :: struct {
		x: i64,
		c: struct {
			z: i64,
		},
	}
	Outer :: struct {
		b: Inner,
		y: i64,
	}
	Doc :: struct {
		a: Outer,
	}
	got: Doc
	src := "[a.b]\nx = 1\n[a]\ny = 2\n[a.b.c]\nz = 3\n"
	testing.expect_value(t, toml.unmarshal(transmute([]u8)string(src), &got, allocator = context.temp_allocator), nil)
	testing.expect_value(t, got.a.y, 2)
	testing.expect_value(t, got.a.b.x, 1)
	testing.expect_value(t, got.a.b.c.z, 3)

	got = {}
	src = "a.b.x = 1\na.y = 2\n[a.b.c]\nz = 3\n"
	testing.expect_value(t, toml.unmarshal(transmute([]u8)string(src), &got, allocator = context.temp_allocator), nil)
	testing.expect_value(t, got.a.b.x, 1)
	testing.expect_value(t, got.a.y, 2)
	testing.expect_value(t, got.a.b.c.z, 3)

	Sub :: struct {
		s: string,
	}
	Item :: struct {
		n:   i64,
		sub: Sub,
		k:   []Sub,
	}
	List :: struct {
		l: []Item,
	}
	list: List
	src = "[[l]]\nn = 1\n[l.sub]\ns = 'a'\n[[l]]\nn = 2\n[[l.k]]\ns = 'b'\n[[l.k]]\ns = 'c'\n"
	testing.expect_value(t, toml.unmarshal(transmute([]u8)string(src), &list, allocator = context.temp_allocator), nil)
	if testing.expect_value(t, len(list.l), 2) {
		testing.expect_value(t, list.l[0].n, 1)
		testing.expect_value(t, list.l[0].sub.s, "a")
		testing.expect_value(t, list.l[1].n, 2)
		if testing.expect_value(t, len(list.l[1].k), 2) {
			testing.expect_value(t, list.l[1].k[1].s, "c")
		}
	}
}

@(test)
date_times_read_as_an_instant_or_as_their_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Stamps :: struct {
		at:    time.Time,
		text:  string,
		local: string,
		day:   string,
		clock: string,
	}
	src := `at = 1979-05-27T00:32:00.5+07:00
text = 1979-05-27T07:32:00Z
local = 1979-05-27T07:32:00
day = 1979-05-27
clock = 07:32:00
`
	got: Stamps
	testing.expect_value(t, toml.unmarshal(transmute([]u8)string(src), &got, allocator = context.temp_allocator), nil)
	testing.expect_value(t, time.to_unix_nanoseconds(got.at), 296587920_500_000_000)
	testing.expect_value(t, got.text, "1979-05-27T07:32:00Z")
	testing.expect_value(t, got.local, "1979-05-27T07:32:00")
	testing.expect_value(t, got.day, "1979-05-27")
	testing.expect_value(t, got.clock, "07:32:00")
	// An offset date-time into a string is its text, whatever its spelling.
	spaced: struct {
		v: string,
		w: time.Time,
	}
	testing.expect_value(t, toml.unmarshal(transmute([]u8)string("v = 1979-05-27 07:32:00+01:00\nw = 1979-05-27 07:32:00+01:00\n"), &spaced, allocator = context.temp_allocator), nil)
	testing.expect_value(t, spaced.v, "1979-05-27 07:32:00+01:00")
	testing.expect_value(t, time.to_unix_nanoseconds(spaced.w), 296634720e9)
	// A date-time with no offset names no instant.
	only_time: struct {
		v: time.Time,
	}
	for text in ([]string{"v = 1979-05-27T07:32:00\n", "v = 1979-05-27\n", "v = 07:32:00\n"}) {
		e := toml.unmarshal(transmute([]u8)text, &only_time, allocator = context.temp_allocator)
		f, is_fault := e.(tape.Fault)
		testing.expectf(t, is_fault && f.kind == .Refused, "%q: %v", text, e)
	}
	expect_refusal(t, toml.unmarshal(transmute([]u8)string("v = true\n"), &only_time, allocator = context.temp_allocator), .Expected_Date_Time, 4)
	// A number is a count of seconds since the epoch.
	testing.expect_value(t, toml.unmarshal(transmute([]u8)string("v = 86400\n"), &only_time, allocator = context.temp_allocator), nil)
	testing.expect_value(t, time.to_unix_nanoseconds(only_time.v), 86400e9)
}

@(test)
integers_read_in_every_radix :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Ints :: struct {
		hex, oct, bin, dec, sep, plus, minus, zero: i64,
		big:                                        u64,
		small:                                      i8,
	}
	src := "hex = 0xDEAD_beef\noct = 0o755\nbin = 0b1101_0101\ndec = 1_000_000\nsep = 5_0\nplus = +99\nminus = -16\nzero = -0\nbig = 9_223_372_036_854_775_807\nsmall = -128\n"
	got: Ints
	e := toml.unmarshal(transmute([]u8)string(src), &got, allocator = context.temp_allocator)
	testing.expect_value(t, e, nil)
	testing.expect_value(t, got.hex, 0xdeadbeef)
	testing.expect_value(t, got.oct, 0o755)
	testing.expect_value(t, got.bin, 0b11010101)
	testing.expect_value(t, got.dec, 1_000_000)
	testing.expect_value(t, got.sep, 50)
	testing.expect_value(t, got.plus, 99)
	testing.expect_value(t, got.minus, -16)
	testing.expect_value(t, got.zero, 0)
	testing.expect_value(t, got.big, u64(max(i64)))
	testing.expect_value(t, got.small, -128)
	// A value past the field's type is refused on its sign's side, and a float is no integer.
	one: struct {
		v: i8,
	}
	expect_refusal(t, toml.unmarshal(transmute([]u8)string("v = 0x80\n"), &one, allocator = context.temp_allocator), .Above_Maximum, 4)
	expect_refusal(t, toml.unmarshal(transmute([]u8)string("v = -129\n"), &one, allocator = context.temp_allocator), .Below_Minimum, 4)
	expect_refusal(t, toml.unmarshal(transmute([]u8)string("v = 1.0\n"), &one, allocator = context.temp_allocator), .Expected_Integer, 4)
	expect_refusal(t, toml.unmarshal(transmute([]u8)string("v = \"1\"\n"), &one, allocator = context.temp_allocator), .Expected_Integer, 4)
	// An integer past 64 bits is the walk's fault, which TOML's grammar gives, so no type holds it.
	big := transmute([]u8)string("v = 0xffff_ffff_ffff_ffff\n")
	wide: struct {
		v: u64,
	}
	e = toml.unmarshal(big, &wide, allocator = context.temp_allocator)
	f, is_fault := e.(tape.Fault)
	testing.expectf(t, is_fault && f.kind != .Refused, "got %v", e)
	testing.expect_value(t, e, toml.validate(big))
}

@(test)
floats_read_with_their_infinities :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Floats :: struct {
		a, b, c, d, e, f, g: f64,
		h:                   f32,
	}
	src := "a = 1.5\nb = -2e3\nc = 6.626_070e-34\nd = +inf\ne = -inf\nf = nan\ng = 7\nh = 0.1\n"
	got: Floats
	testing.expect_value(t, toml.unmarshal(transmute([]u8)string(src), &got, allocator = context.temp_allocator), nil)
	testing.expect_value(t, got.a, 1.5)
	testing.expect_value(t, got.b, -2000)
	testing.expect_value(t, got.c, 6.62607e-34)
	testing.expect(t, math.is_inf(got.d, 1))
	testing.expect(t, math.is_inf(got.e, -1))
	testing.expect(t, math.is_nan(got.f))
	testing.expect_value(t, got.g, 7)
	testing.expect_value(t, got.h, f32(0.1))
	nan: struct {
		v: f64,
	}
	testing.expect_value(t, toml.unmarshal(transmute([]u8)string("v = -nan\n"), &nan, allocator = context.temp_allocator), nil)
	testing.expect(t, math.is_nan(nan.v))
	expect_refusal(t, toml.unmarshal(transmute([]u8)string("v = 1e400\n"), &nan, allocator = context.temp_allocator), .Above_Maximum, 4)
	expect_refusal(t, toml.unmarshal(transmute([]u8)string("v = true\n"), &nan, allocator = context.temp_allocator), .Expected_Number, 4)
	narrow: struct {
		v: f32,
	}
	expect_refusal(t, toml.unmarshal(transmute([]u8)string("v = 1e300\n"), &narrow, allocator = context.temp_allocator), .Above_Maximum, 4)
}

@(test)
strings_and_booleans_read_their_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Row :: struct {
		basic:   string,
		literal: string,
		multi:   string,
		ok:      bool,
		quoted:  string `toml:"a key"`,
		skipped: string `toml:"-"`,
	}
	src := "basic = \"x\\ty\\u00e9\"\nliteral = 'c:\\d'\nmulti = \"\"\"\nline\\\n   next\"\"\"\nok = true\n\"a key\" = \"found\"\nskipped = \"no\"\n"
	got: Row
	for borrow in ([]bool{false, true}) {
		got = {}
		testing.expect_value(t, toml.unmarshal(transmute([]u8)string(src), &got, read = {borrow_strings = borrow}, allocator = context.temp_allocator), nil)
		testing.expect_value(t, got.basic, "x\ty\u00e9")
		testing.expect_value(t, got.literal, `c:\d`)
		testing.expect_value(t, got.multi, "linenext")
		testing.expect_value(t, got.ok, true)
		testing.expect_value(t, got.quoted, "found")
		testing.expect_value(t, got.skipped, "")
	}
	expect_refusal(t, toml.unmarshal(transmute([]u8)string("ok = 1\n"), &got, allocator = context.temp_allocator), .Expected_Bool, 5)
	expect_refusal(t, toml.unmarshal(transmute([]u8)string("basic = 1\n"), &got, allocator = context.temp_allocator), .Expected_String, 8)
}

// A refused value names the tables and elements around it, through an array of tables.
@(test)
a_refusal_names_its_path_through_an_array_of_tables :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := "[[servers]]\nhost = \"a\"\nport = 1\n\n[[servers]]\nhost = \"b\"\nport = 2\n\n[[servers]]\nhost = \"c\"\nport = \"x\"\n"
	got: Config
	path := make([dynamic]tape.Step, context.temp_allocator)
	e := toml.unmarshal(transmute([]u8)string(src), &got, read = {path = &path}, allocator = context.temp_allocator)
	expect_refusal(t, e, .Expected_Integer, u64(len(src) - 4))
	expect_path(t, path[:], {"servers", 2, "port"})
	// A map's key and a nested table name their places too.
	path2 := make([dynamic]tape.Step, context.temp_allocator)
	e = toml.unmarshal(transmute([]u8)string("[limits]\nrows = 1\nbytes = 1.5\n"), &got, read = {path = &path2}, allocator = context.temp_allocator)
	expect_refusal(t, e, .Expected_Integer, 26)
	expect_path(t, path2[:], {"limits", "bytes"})
	path3 := make([dynamic]tape.Step, context.temp_allocator)
	e = toml.unmarshal(transmute([]u8)string("[owner]\nname = 1\n"), &got, read = {path = &path3}, allocator = context.temp_allocator)
	expect_refusal(t, e, .Expected_String, 15)
	expect_path(t, path3[:], {"owner", "name"})
}

// A key a text repeats is the walk's fault, so the read gives the error `validate` gives, with no policy to choose.
@(test)
a_repeated_key_is_refused_as_the_walk_refuses_it :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	One :: struct {
		a: i64,
	}
	Nest :: struct {
		t: One,
	}
	texts := [?]string{"a = 1\na = 2\n", "[t]\na = 1\n[t]\na = 2\n", "t.a = 1\n[t]\na = 2\n", "a = 1\na = \"x\"\n"}
	for text in texts {
		src := transmute([]u8)text
		want := toml.validate(src)
		testing.expectf(t, want != nil, "%q is valid", text)
		for dups in ([]toml.Duplicates{.Default, .Last, .First, .Refuse}) {
			nest: Nest
			e := toml.unmarshal(src, &nest, opts = {dups = dups}, allocator = context.temp_allocator)
			f, is_fault := e.(tape.Fault)
			w, _ := want.(tape.Fault)
			testing.expectf(t, is_fault && f.kind != .Refused && f.kind == w.kind && f.at == w.at, "%q under %v: %v, wanted %v", text, dups, e, want)
		}
	}
}

@(test)
absent_and_unknown_members_follow_the_options :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Row :: struct {
		a: i64,
		b: string,
		c: i64 `toml:"c,required"`,
	}
	got := Row{7, "kept", 0}
	e := toml.unmarshal(transmute([]u8)string("c = 3\nzz = 1\n[other]\nq = [1, {r = 2}]\n"), &got, allocator = context.temp_allocator)
	testing.expect_value(t, e, nil)
	testing.expect_value(t, got, Row{7, "kept", 3})
	path := make([dynamic]tape.Step, context.temp_allocator)
	e = toml.unmarshal(transmute([]u8)string("c = 3\nzz = 1\n"), &got, read = {refuse_unknown = true, path = &path}, allocator = context.temp_allocator)
	expect_refusal(t, e, .Unknown_Field, 6)
	expect_path(t, path[:], {"zz"})
	e = toml.unmarshal(transmute([]u8)string("a = 1\n"), &got, read = {path = &path}, allocator = context.temp_allocator)
	expect_refusal(t, e, .Missing_Field, 6)
	expect_path(t, path[:], {"c"})
}

// The 1.1 spelling of a text reads as 1.0's does.
@(test)
the_specs_read_the_same_types :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Row :: struct {
		a: string,
		p: struct {
			x: i64,
			y: i64,
		},
	}
	src := "a = \"\\e\\x41\"\np = {x = 1,\n  y = 2,\n}\n"
	got: Row
	testing.expect_value(t, toml.unmarshal(transmute([]u8)string(src), &got, .Toml_1_1, allocator = context.temp_allocator), nil)
	testing.expect_value(t, got.a, "\x1bA")
	testing.expect_value(t, got.p.x, 1)
	testing.expect_value(t, got.p.y, 2)
	// 1.0 does not take that text, and the read says so as `validate` does.
	e := toml.unmarshal(transmute([]u8)string(src), &got, .Toml_1_0, allocator = context.temp_allocator)
	testing.expect_value(t, e, toml.validate(transmute([]u8)string(src), .Toml_1_0))
	testing.expect(t, e != nil)
}

// The typed read law over every case of the toml-test lists: a read into a `testkit.Value` is what the build
// converts to, and a text the build refuses is refused alike.
@(test)
unmarshal_agrees_with_the_build :: proc(t: ^testing.T) {
	testkit.deadline(t)
	read_value :: proc(f: ^tape.Format, src: []u8, v: ^testkit.Value, opts: tape.Options, allocator: runtime.Allocator) -> tape.Error {
		spec := toml.Spec.Toml_1_0 if f == toml.as(.Toml_1_0) else toml.Spec.Toml_1_1
		return toml.unmarshal(src, v, spec, opts = opts, allocator = allocator)
	}
	lists := [toml.Spec]string {
		.Toml_1_0 = LIST_1_0,
		.Toml_1_1 = LIST_1_1,
	}
	a: testkit.Typed_Agreement
	for list, spec in lists {
		rest := list
		for name in strings.split_lines_iterator(&rest) {
			if !strings.has_suffix(name, ".toml") {
				continue
			}
			data, found := case_data(name)
			if !found {
				continue
			}
			src := make([]u8, len(data))
			defer delete(src)
			copy(src, data)
			testkit.unmarshal_agrees(t, toml.reads(spec), toml.as(spec), read_value, src, {}, name, &a)
		}
	}
	testing.expectf(t, a.read > 400 && a.refused > 400, "%v", a)
}
