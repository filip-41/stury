// Differential against Odin's `core:encoding/cbor`. Random items and mutations of them are read by both, and when both
// accept an item the two values written by `dump` must agree. Only that is a defect, the other classes are the ways
// the two decoders part: the stock decoder takes ill-formed UTF-8, bytes after the item and keys of any type, and refuses
// tags inside tags.
package cbor_tests

import "core:encoding/cbor"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import core "../../core"
import stury ".."

@(private)
Generator :: struct {
	rng: rand.Generator,
	out: [dynamic]u8,
}

@(private)
below :: proc(g: ^Generator, n: int) -> int {
	return int(rand.int_max(n, g.rng))
}

@(private)
put_head :: proc(g: ^Generator, major: u8, arg: u64) {
	// Widths beyond the shortest are well-formed and exercise every head length.
	width := 0
	switch {
	case arg < 24:
		width = 0
	case arg < 1 << 8:
		width = 1
	case arg < 1 << 16:
		width = 2
	case arg < 1 << 32:
		width = 4
	case:
		width = 8
	}
	if below(g, 4) == 0 && width < 8 {
		width = width == 0 ? 1 : width * 2
	}
	switch width {
	case 0:
		append(&g.out, major << 5 | u8(arg))
	case 1:
		append(&g.out, major << 5 | 24, u8(arg))
	case 2:
		append(&g.out, major << 5 | 25, u8(arg >> 8), u8(arg))
	case 4:
		append(&g.out, major << 5 | 26, u8(arg >> 24), u8(arg >> 16), u8(arg >> 8), u8(arg))
	case:
		append(&g.out, major << 5 | 27)
		for shift := 56; 0 <= shift; shift -= 8 {
			append(&g.out, u8(arg >> uint(shift)))
		}
	}
}

@(private)
put_text :: proc(g: ^Generator) {
	pieces := [?]string{"a", "key", "é", "€", "\U0001f600", "", "x y"}
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< below(g, 4) {
		strings.write_string(&b, pieces[below(g, len(pieces))])
	}
	s := strings.to_string(b)
	put_head(g, 3, u64(len(s)))
	append(&g.out, ..transmute([]u8)s)
}

@(private)
put_item :: proc(g: ^Generator, depth: int, key: bool) {
	choice := below(g, key ? 4 : 14)
	switch choice {
	case 0:
		put_head(g, 0, rand.uint64(g.rng) >> uint(below(g, 64)))
	case 1:
		put_head(g, 1, rand.uint64(g.rng) >> uint(below(g, 64)))
	case 2:
		count := below(g, 5)
		put_head(g, 2, u64(count))
		for _ in 0 ..< count {
			append(&g.out, u8(below(g, 256)))
		}
	case 3:
		put_text(g)
	case 4:
		if depth < 4 {
			count := below(g, 4)
			put_head(g, 4, u64(count))
			for _ in 0 ..< count {
				put_item(g, depth + 1, false)
			}
			return
		}
		append(&g.out, 0xf6)
	case 5:
		if depth < 4 {
			count := below(g, 4)
			put_head(g, 5, u64(count))
			for _ in 0 ..< count {
				put_item(g, depth + 1, true)
				put_item(g, depth + 1, false)
			}
			return
		}
		append(&g.out, 0xa0)
	case 6:
		append(&g.out, 0xf4 + u8(below(g, 3)))
	case 7:
		append(&g.out, 0xf7)
	case 8:
		append(&g.out, 0xf9, u8(below(g, 256)), u8(below(g, 256)))
	case 9:
		append(&g.out, 0xfa, u8(below(g, 256)), u8(below(g, 256)), u8(below(g, 256)), u8(below(g, 256)))
	case 10:
		append(&g.out, 0xfb)
		for _ in 0 ..< 8 {
			append(&g.out, u8(below(g, 256)))
		}
	case 11:
		append(&g.out, 0xf8, u8(32 + below(g, 224)))
	case 12:
		if depth < 4 {
			append(&g.out, 0x9f)
			for _ in 0 ..< below(g, 3) {
				put_item(g, depth + 1, false)
			}
			append(&g.out, 0xff)
			return
		}
		append(&g.out, 0x80)
	case:
		append(&g.out, 0x7f)
		for _ in 0 ..< below(g, 3) {
			put_text(g)
		}
		append(&g.out, 0xff)
	}
}

// Writes value `v` of the stock decoder the way `dump` writes a document node. Returns false for a value `dump` cannot
// spell: a tag, or a key that is not an integer, text or bytes.
@(private)
stock_dump :: proc(b: ^strings.Builder, v: cbor.Value, key := false) -> bool {
	spell_bytes :: proc(b: ^strings.Builder, p: []u8) {
		hex_text(b, p)
	}
	if key {
		#partial switch x in v {
		case ^cbor.Text:
			fmt.sbprintf(b, "%q", string(x^))
			return true
		case ^cbor.Bytes:
			spell_bytes(b, x^)
			return true
		case u8:
			fmt.sbprintf(b, `"%d"`, x)
			return true
		case u16:
			fmt.sbprintf(b, `"%d"`, x)
			return true
		case u32:
			fmt.sbprintf(b, `"%d"`, x)
			return true
		case u64:
			fmt.sbprintf(b, `"%d"`, x)
			return true
		case cbor.Negative_U8:
			fmt.sbprintf(b, `"%d"`, -1 - i128(x))
			return true
		case cbor.Negative_U16:
			fmt.sbprintf(b, `"%d"`, -1 - i128(x))
			return true
		case cbor.Negative_U32:
			fmt.sbprintf(b, `"%d"`, -1 - i128(x))
			return true
		case cbor.Negative_U64:
			fmt.sbprintf(b, `"%d"`, -1 - i128(x))
			return true
		}
		return false
	}
	switch x in v {
	case u8:
		fmt.sbprintf(b, "i:%d", x)
	case u16:
		fmt.sbprintf(b, "i:%d", x)
	case u32:
		fmt.sbprintf(b, "i:%d", x)
	case u64:
		fmt.sbprintf(b, "i:%d", x)
	case cbor.Negative_U8:
		fmt.sbprintf(b, "i:%d", -1 - i128(x))
	case cbor.Negative_U16:
		fmt.sbprintf(b, "i:%d", -1 - i128(x))
	case cbor.Negative_U32:
		fmt.sbprintf(b, "i:%d", -1 - i128(x))
	case cbor.Negative_U64:
		fmt.sbprintf(b, "i:%d", -1 - i128(x))
	case ^cbor.Bytes:
		spell_bytes(b, x^)
	case ^cbor.Text:
		fmt.sbprintf(b, "%q", string(x^))
	case ^cbor.Array:
		strings.write_byte(b, '[')
		for item, i in x^ {
			if 0 < i {
				strings.write_byte(b, ',')
			}
			stock_dump(b, item) or_return
		}
		strings.write_byte(b, ']')
	case ^cbor.Map:
		strings.write_byte(b, '{')
		for entry, i in x^ {
			if 0 < i {
				strings.write_byte(b, ',')
			}
			stock_dump(b, entry.key, true) or_return
			strings.write_byte(b, ':')
			stock_dump(b, entry.value) or_return
		}
		strings.write_byte(b, '}')
	case ^cbor.Tag:
		return false
	case cbor.Simple:
		fmt.sbprintf(b, "simple(%d)", u8(x))
	case f16:
		float_text(b, f64(x))
	case f32:
		float_text(b, f64(x))
	case f64:
		float_text(b, x)
	case bool:
		strings.write_string(b, "true" if x else "false")
	case cbor.Undefined:
		strings.write_string(b, "simple(23)")
	case cbor.Nil:
		strings.write_string(b, "null")
	}
	return true
}

@(private)
float_text :: proc(b: ^strings.Builder, f: f64) {
	if f != f {
		strings.write_string(b, "nan")
	} else {
		fmt.sbprintf(b, "f:%016x", transmute(u64)f)
	}
}

@(private)
Tally :: struct {
	compared:      int,
	mismatch:      int,
	stock_refuses: int,
	we_refuse:     int,
	both_refuse:   int,
	tagged:        int,
}

@(private)
compare :: proc(t: ^testing.T, tally: ^Tally, src: []u8, must_agree: bool) {
	ours, err := stury.build(src, .Cbor)
	stock, serr := cbor.decode(string(src), {}, context.temp_allocator)
	stock_ok := serr == nil
	our_ok := err == nil
	if !our_ok && !stock_ok {
		tally.both_refuse += 1
		testing.expect(t, !must_agree)
		return
	}
	if our_ok && !stock_ok {
		tally.stock_refuses += 1
		testing.expectf(t, !must_agree, "stock refuses %x: %v", src, serr)
		core.destroy(&ours)
		return
	}
	if !our_ok {
		tally.we_refuse += 1
		testing.expectf(t, !must_agree, "we refuse %x", src)
		return
	}
	defer core.destroy(&ours)
	a := strings.builder_make(context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	if !stock_dump(&b, stock) {
		tally.tagged += 1
		return
	}
	dump(&a, &ours, core.ROOT)
	tally.compared += 1
	if strings.to_string(a) != strings.to_string(b) {
		tally.mismatch += 1
		testing.expectf(t, false, "%x: stury %s, stock %s", src, strings.to_string(a), strings.to_string(b))
	}
}

// Items built from the grammar are read by both with the same value.
@(test)
generated_items_agree_with_the_stock_decoder :: proc(t: ^testing.T) {
	state := rand.create(0x5eed_cb02)
	g := Generator {
		rng = rand.default_random_generator(&state),
	}
	tally: Tally
	for _ in 0 ..< 4000 {
		g.out = make([dynamic]u8, context.temp_allocator)
		put_item(&g, 0, false)
		context.allocator = context.temp_allocator
		compare(t, &tally, g.out[:], true)
		free_all(context.temp_allocator)
	}
	testing.expect_value(t, tally.mismatch, 0)
	testing.expect(t, 3000 < tally.compared)
}

// A byte changed, an item cut short, or bytes added: where both read the item, they read the same value.
@(test)
mutated_items_agree_with_the_stock_decoder :: proc(t: ^testing.T) {
	state := rand.create(0x5eed_cb03)
	g := Generator {
		rng = rand.default_random_generator(&state),
	}
	tally: Tally
	for _ in 0 ..< 6000 {
		g.out = make([dynamic]u8, context.temp_allocator)
		put_item(&g, 0, false)
		src := g.out[:]
		switch below(&g, 3) {
		case 0:
			src[below(&g, len(src))] = u8(below(&g, 256))
		case 1:
			src = src[:below(&g, len(src))]
		case:
			append(&g.out, u8(below(&g, 256)))
			src = g.out[:]
		}
		context.allocator = context.temp_allocator
		compare(t, &tally, src, false)
		free_all(context.temp_allocator)
	}
	testing.expect_value(t, tally.mismatch, 0)
	testing.expect(t, 1000 < tally.compared)
	testing.expect(t, 0 < tally.both_refuse)
}
