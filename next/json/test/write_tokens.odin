package json_tests

import "base:runtime"
import "core:bytes"
import "core:io"
import "core:math"
import "core:math/rand"
import "core:strings"
import "core:testing"
import core "../../core"
import write "../../core/write"
import json ".."
import walktest "../../walktest"

// The token write against `marshal`: the same value written call by call is the same bytes.

Token_Point :: struct {
	n: i64,
	f: f64,
}

Token_Sample :: struct {
	name:    string,
	count:   i64,
	big:     u64,
	ratio:   f64,
	on:      bool,
	off:     bool,
	nothing: ^int,
	list:    []i64,
	empty:   []i64,
	point:   Token_Point,
	rows:    []Token_Point,
}

// The calls that write `v` as `marshal` does.
write_sample :: proc(t: ^write.Tokens, v: Token_Sample) {
	write.open_object(t)
	write.key(t, "name")
	write.value_string(t, v.name)
	write.key(t, "count")
	write.value_int(t, v.count)
	write.key(t, "big")
	write.value_uint(t, v.big)
	write.key(t, "ratio")
	write.value_float(t, v.ratio)
	write.key(t, "on")
	write.value_bool(t, v.on)
	write.key(t, "off")
	write.value_bool(t, v.off)
	write.key(t, "nothing")
	write.value_null(t)
	write.key(t, "list")
	write.open_array(t)
	for x in v.list {
		write.value_int(t, x)
	}
	write.close(t)
	write.key(t, "empty")
	write.open_array(t)
	write.close(t)
	write.key(t, "point")
	write_point(t, v.point)
	write.key(t, "rows")
	write.open_array(t)
	for p in v.rows {
		write_point(t, p)
	}
	write.close(t)
	write.close(t)
}

write_point :: proc(t: ^write.Tokens, p: Token_Point) {
	write.open_object(t)
	write.key(t, "n")
	write.value_int(t, p.n)
	write.key(t, "f")
	write.value_float(t, p.f)
	write.close(t)
}

TOKEN_LIST := [?]i64{1, -2, 3}
TOKEN_ROWS := [?]Token_Point{{1, 1.5}, {2, -0.25}}

token_sample :: proc() -> Token_Sample {
	return {
		name = "café <b> & \"q\"  ",
		count = -42,
		big = max(u64),
		ratio = 0.1,
		on = true,
		list = TOKEN_LIST[:],
		point = {7, 2.5e300},
		rows = TOKEN_ROWS[:],
	}
}

token_text :: proc(v: Token_Sample, opts: core.Write_Options, allocator := context.allocator) -> ([]u8, core.Typed_Error) {
	tw: write.Tokens
	write.tokens_init(&tw, json.as(.Json), opts, allocator)
	write_sample(&tw, v)
	return write.tokens_finish(&tw)
}

@(test)
tokens_equal_marshal :: proc(t: ^testing.T) {
	v := token_sample()
	for opts in ([?]core.Write_Options {
			{},
			core.PRETTY,
			{pretty = true, indent = 4},
			{pretty = true, tab = true},
			{pretty = true, indent = 0},
			{ascii = true},
			{escape_html = true, pretty = true, indent = 2},
			{ascii = true, escape_html = true},
		}) {
		want, werr := json.marshal(v, opts, context.temp_allocator)
		testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
		got, err := token_text(v, opts)
		defer delete(got)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
		testing.expectf(t, string(got) == string(want), "%v: %q, want %q", opts, got, want)
		doc, derr := json.build(got, .Json)
		testing.expect_value(t, derr.kind, core.Document_Error_Kind.None)
		core.destroy(&doc)
	}
}

@(test)
scalar_roots_and_empty_containers :: proc(t: ^testing.T) {
	for want, k in ([?]string{`1`, `"x"`, `null`, `true`, `[]`, `{}`, `[[],{}]`}) {
		tw: write.Tokens
		write.tokens_init(&tw, json.as(.Json))
		switch k {
		case 0:
			write.value_int(&tw, 1)
		case 1:
			write.value_string(&tw, "x")
		case 2:
			write.value_null(&tw)
		case 3:
			write.value_bool(&tw, true)
		case 4:
			write.open_array(&tw)
			write.close(&tw)
		case 5:
			write.open_object(&tw)
			write.close(&tw)
		case:
			write.open_array(&tw)
			write.open_array(&tw)
			write.close(&tw)
			write.open_object(&tw)
			write.close(&tw)
			write.close(&tw)
		}
		got, err := write.tokens_finish(&tw)
		defer delete(got)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
		testing.expect_value(t, string(got), want)
	}
}

// A misuse returns its kind from the call, keeps it, and finishes with it and no bytes.
expect_token_refused :: proc(t: ^testing.T, run: proc(tw: ^write.Tokens) -> core.Typed_Error_Kind, want: core.Typed_Error_Kind, loc := #caller_location) {
	tw: write.Tokens
	write.tokens_init(&tw, json.as(.Json))
	testing.expect_value(t, run(&tw), want, loc)
	testing.expect_value(t, write.value_int(&tw, 1), want, loc)
	got, err := write.tokens_finish(&tw)
	testing.expect_value(t, err.kind, want, loc)
	testing.expect_value(t, len(got), 0, loc)
}

@(test)
token_misuse_is_refused :: proc(t: ^testing.T) {
	W :: write
	expect_token_refused(t, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {return W.key(tw, "a")}, .Out_Of_Order)
	expect_token_refused(t, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {return W.close(tw)}, .Out_Of_Order)
	expect_token_refused(t, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {
			W.open_array(tw)
			return W.key(tw, "a")
		}, .Out_Of_Order)
	expect_token_refused(t, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {
			W.open_object(tw)
			return W.value_int(tw, 1)
		}, .Out_Of_Order)
	expect_token_refused(t, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {
			W.open_object(tw)
			return W.open_array(tw)
		}, .Out_Of_Order)
	expect_token_refused(t, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {
			W.open_object(tw)
			W.key(tw, "a")
			return W.key(tw, "b")
		}, .Out_Of_Order)
	expect_token_refused(t, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {
			W.open_object(tw)
			W.key(tw, "a")
			return W.close(tw)
		}, .Out_Of_Order)
	expect_token_refused(t, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {
			W.value_int(tw, 1)
			return W.value_int(tw, 2)
		}, .Out_Of_Order)
	expect_token_refused(t, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {
			W.open_array(tw)
			W.close(tw)
			return W.open_array(tw)
		}, .Out_Of_Order)
	expect_token_refused(t, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {return W.end_row(tw)}, .Unsupported)
	expect_token_refused(t, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {return W.value_float(tw, math.inf_f64(1))}, .Non_Finite)
	expect_token_refused(t, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {return W.value_float(tw, math.nan_f64())}, .Non_Finite)
	expect_token_refused(t, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {return W.value_string(tw, "\xff")}, .Bad_Utf8)
	expect_token_refused(t, proc(tw: ^W.Tokens) -> core.Typed_Error_Kind {
			W.open_object(tw)
			return W.key(tw, "\xff")
		}, .Bad_Utf8)
}

@(test)
unfinished_text_is_refused :: proc(t: ^testing.T) {
	for k in 0 ..< 4 {
		tw: write.Tokens
		write.tokens_init(&tw, json.as(.Json))
		switch k {
		case 1:
			write.open_array(&tw)
		case 2:
			write.open_object(&tw)
			write.key(&tw, "a")
		case 3:
			write.open_array(&tw)
			write.value_int(&tw, 1)
		}
		got, err := write.tokens_finish(&tw)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.Out_Of_Order)
		testing.expect_value(t, len(got), 0)
	}
}

@(test)
nesting_stops_at_max_depth :: proc(t: ^testing.T) {
	for levels in ([?]int{core.MAX_DEPTH, core.MAX_DEPTH + 1}) {
		tw: write.Tokens
		write.tokens_init(&tw, json.as(.Json))
		kind := core.Typed_Error_Kind.None
		for _ in 0 ..< levels {
			kind = write.open_array(&tw)
		}
		testing.expect_value(t, kind, core.Typed_Error_Kind.None if levels == core.MAX_DEPTH else .Too_Deep)
		for _ in 0 ..< levels {
			write.close(&tw)
		}
		got, err := write.tokens_finish(&tw)
		defer delete(got)
		if levels == core.MAX_DEPTH {
			testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
			testing.expect_value(t, len(got), 2 * levels)
		} else {
			testing.expect_value(t, err.kind, core.Typed_Error_Kind.Too_Deep)
		}
	}
}

@(test)
tokens_to_a_stream :: proc(t: ^testing.T) {
	v := token_sample()
	v.list = make([]i64, 30000, context.temp_allocator)
	for &x, i in v.list {
		x = i64(i) * 1000003
	}
	for opts in ([?]core.Write_Options{{}, core.PRETTY}) {
		want, _ := json.marshal(v, opts, context.temp_allocator)
		buf: bytes.Buffer
		defer bytes.buffer_destroy(&buf)
		tw: write.Tokens
		write.tokens_init(&tw, json.as(.Json), opts, stream = bytes.buffer_to_stream(&buf))
		write_sample(&tw, v)
		got, err := write.tokens_finish(&tw)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
		testing.expect_value(t, len(got), 0)
		testing.expect(t, len(want) > 64 * 1024)
		testing.expect(t, string(bytes.buffer_to_bytes(&buf)) == string(want))
	}
}

@(test)
tokens_to_a_failing_stream :: proc(t: ^testing.T) {
	v := token_sample()
	tw: write.Tokens
	write.tokens_init(&tw, json.as(.Json), stream = io.Stream{procedure = refusing_stream})
	write_sample(&tw, v)
	_, err := write.tokens_finish(&tw)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.Write_Failed)
	testing.expect_value(t, err.cause, io.Error.Permission_Denied)
}

@(private)
Token_Try :: struct {
	value: Token_Sample,
	opts:  core.Write_Options,
}

@(private)
token_try :: proc(data: rawptr, allocator: runtime.Allocator) -> ([]u8, core.Typed_Error_Kind) {
	m := (^Token_Try)(data)
	text, err := token_text(m.value, m.opts, allocator)
	return text, err.kind
}

@(test)
tokens_under_failing_allocators :: proc(t: ^testing.T) {
	v := token_sample()
	for opts in ([?]core.Write_Options{{}, core.PRETTY}) {
		try := Token_Try{v, opts}
		want, _ := json.marshal(v, opts, context.temp_allocator)
		walktest.sweep_write(t, token_try, &try, string(want))
	}
}

// A random value written by calls is the bytes `marshal` makes of it.
@(test)
random_values_written_by_calls_equal_marshal :: proc(t: ^testing.T) {
	rand.reset(11)
	WORDS := [?]string{"", "a", "café", "<&>", "\"", "\\", "\n", "\U0001F600", " ", "plain text of some length 0123456789"}
	for round in 0 ..< 300 {
		v: Token_Sample
		v.name = rand.choice(WORDS[:])
		v.count = rand.int63() - rand.int63()
		v.big = rand.uint64()
		v.ratio = rand.float64_range(-1e9, 1e9) if round % 3 != 0 else f64(rand.int31())
		v.on, v.off = rand.int_max(2) == 0, rand.int_max(2) == 0
		v.list = make([]i64, rand.int_max(6), context.temp_allocator)
		for &x in v.list {
			x = rand.int63() - rand.int63()
		}
		v.rows = make([]Token_Point, rand.int_max(4), context.temp_allocator)
		for &p in v.rows {
			p = {rand.int63(), rand.float64()}
		}
		v.point = {rand.int63(), rand.float64()}
		opts := core.Write_Options {
			pretty      = rand.int_max(2) == 0,
			indent      = u8(rand.int_max(5)),
			ascii       = rand.int_max(3) == 0,
			escape_html = rand.int_max(3) == 0,
		}
		want, werr := json.marshal(v, opts, context.temp_allocator)
		got, err := token_text(v, opts)
		defer delete(got)
		testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
		if !testing.expectf(t, strings.compare(string(got), string(want)) == 0, "%v: %q, want %q", opts, got, want) {
			return
		}
	}
}
