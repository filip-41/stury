// A float written as TOML reads back as a float, an integer as an integer, through the typed write and the token write.
package toml_tests

import "core:math"
import "core:testing"
import core "../../core"
import write "../../core/write"
import toml ".."

@(private)
FLOATS := [?]f64{0, 1, -1, 2, 0.5, -0.0, 1e300, -1e300, 1e16, 1e17, 1e-7, 123456789012, 5e-324, math.inf_f64(1), math.inf_f64(-1), math.nan_f64()}

Floats :: struct {
	f: f64,
	i: int,
}

// The style the reader gives the member `name` of the written text, and its value.
@(private)
style_of_member :: proc(t: ^testing.T, text: string, name: string) -> (style: string, n: core.Number) {
	doc, err := toml.build(transmute([]u8)text, .Toml_1_0)
	if !testing.expectf(t, err == nil, "%q does not read: %v", text, err) {
		return
	}
	defer core.destroy(&doc)
	node := node_at(t, &doc, name)
	fv, _ := core.fact_value(&doc, node, .Style)
	n, _ = core.number(&doc, node)
	return fv.text, n
}

@(private)
float_kind_ok :: proc(t: ^testing.T, text: string, x: f64) {
	style, n := style_of_member(t, text, "f")
	want := "float"
	if math.is_inf(x) {
		want = "inf"
	} else if math.is_nan(x) {
		want = "nan"
	}
	testing.expectf(t, style == want, "%v is written as %q, a %s", x, text, style)
	got := transmute(f64)n.bits
	if n.kind != .Float {
		got = f64(i64(n.bits))
	}
	testing.expectf(t, math.is_nan(x) || got == x && math.sign_bit(got) == math.sign_bit(x), "%v is written as %q and reads %v", x, text, got)
}

@(test)
typed_write_keeps_each_float_a_float :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for x in FLOATS {
		text, err := toml.marshal(Floats{f = x, i = 3}, allocator = context.temp_allocator)
		if !testing.expectf(t, err == nil, "%v: %v", x, err) {
			continue
		}
		float_kind_ok(t, string(text), x)
		style, _ := style_of_member(t, string(text), "i")
		testing.expectf(t, style == "integer", "an int is written as %q", text)
	}
}

@(test)
token_write_keeps_each_float_a_float :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for x in FLOATS {
		w: write.Tokens
		write.tokens_init(&w, toml.as(.Toml_1_0), allocator = context.temp_allocator)
		write.open_object(&w)
		write.key(&w, "f")
		write.value_float(&w, x)
		write.key(&w, "i")
		write.value_int(&w, 3)
		write.close(&w)
		bytes, err := write.tokens_finish(&w)
		if !testing.expectf(t, err.kind == .None, "%v: %v", x, err.kind) {
			continue
		}
		float_kind_ok(t, string(bytes), x)
		style, _ := style_of_member(t, string(bytes), "i")
		testing.expectf(t, style == "integer", "an int is written as %q", bytes)
	}
}
