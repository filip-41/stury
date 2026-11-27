package cbor_tests

import "core:fmt"
import "core:math/rand"
import "stury:cbor"

// Random items of every kind and their mutations, and the texts the laws read in pieces.

// Appends the head of an item of `major` and argument `arg`, in the shortest form or, with `wide`, a longer one.
put_head :: proc(b: ^[dynamic]u8, major: u8, arg: u64, wide := false) {
	m := major << 5
	switch {
	case arg < 24 && !wide:
		append(b, m | u8(arg))
	case arg <= 0xff:
		append(b, m | 24, u8(arg))
	case arg <= 0xffff:
		append(b, m | 25, u8(arg >> 8), u8(arg))
	case arg <= 0xffff_ffff:
		append(b, m | 26, u8(arg >> 24), u8(arg >> 16), u8(arg >> 8), u8(arg))
	case:
		append(b, m | 27)
		for k := 56; k >= 0; k -= 8 {
			append(b, u8(arg >> uint(k)))
		}
	}
}

// Appends a random key: an integer, a text or a byte string, from few enough that a map often repeats one.
put_key :: proc(b: ^[dynamic]u8) {
	switch rand.int_max(6) {
	case 0:
		put_head(b, u8(rand.int_max(2)), u64(rand.int_max(30)))
	case 1:
		append(b, 0x41, u8('a' + rand.int_max(3)))
	case 2:
		append(b, 0x7f, 0x61, u8('a' + rand.int_max(3)), 0xff)
	case:
		append(b, 0x61, u8('a' + rand.int_max(6)))
	}
}

// Appends a random item of at most `depth` levels: every major type, definite and indefinite lengths, tags of the
// kinds the walk reads and folds, floats of every width and simple values.
put_item :: proc(b: ^[dynamic]u8, depth: int) {
	pick := rand.int_max(16 if depth > 0 else 10)
	switch pick {
	case 0:
		put_head(b, 0, rand.uint64() >> uint(rand.int_max(64)), rand.int_max(4) == 0)
	case 1:
		put_head(b, 1, u64(rand.int_max(1000)))
	case 2:
		n := rand.int_max(20)
		put_head(b, 3, u64(n))
		for _ in 0 ..< n {
			append(b, u8('a' + rand.int_max(26)))
		}
		if rand.int_max(3) == 0 {
			append(b, 0x62, 0xc3, 0xa9)
		}
	case 3:
		n := rand.int_max(6)
		put_head(b, 2, u64(n))
		for _ in 0 ..< n {
			append(b, u8(rand.int_max(256)))
		}
	case 4:
		append(b, 0xf4 + u8(rand.int_max(4)))
	case 5:
		switch rand.int_max(3) {
		case 0:
			append(b, 0xf9, 0x3c, 0x00)
		case 1:
			append(b, 0xfa, 0x47, 0xc3, 0x50, 0x00)
		case:
			append(b, 0xfb, 0x3f, 0xf1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9a)
		}
	case 6:
		append(b, 0xc2 + u8(rand.int_max(2)), 0x49, 1, 0, 0, 0, 0, 0, 0, 0, u8(rand.int_max(256)))
	case 7:
		append(b, 0xc4, 0x82, 0x21, 0x19, 0x6a, 0xb3)
	case 8:
		append(b, 0x7f, 0x62, 0x68, 0x69, 0x61, 0x21, 0xff)
	case 9:
		append(b, 0xf0 + u8(rand.int_max(4)))
	case 10, 11:
		n := rand.int_max(6)
		indefinite := rand.int_max(4) == 0
		if indefinite {
			append(b, 0x9f)
		} else {
			put_head(b, 4, u64(n))
		}
		for _ in 0 ..< n {
			put_item(b, depth - 1)
		}
		if indefinite {
			append(b, 0xff)
		}
	case 12, 13:
		n := rand.int_max(6)
		indefinite := rand.int_max(4) == 0
		if indefinite {
			append(b, 0xbf)
		} else {
			put_head(b, 5, u64(n))
		}
		for _ in 0 ..< n {
			put_key(b)
			put_item(b, depth - 1)
		}
		if indefinite {
			append(b, 0xff)
		}
	case 14:
		put_head(b, 6, u64(rand.int_max(2) * 55799 + 100))
		put_item(b, depth - 1)
	case:
		append(b, 0xd8, 0x18)
		put_head(b, 2, 0)
	}
}

// A random item whose root is a container, in the context's allocator.
random_item :: proc() -> []u8 {
	b := make([dynamic]u8)
	if rand.int_max(2) == 0 {
		put_head(&b, 5, 3)
		for _ in 0 ..< 3 {
			put_key(&b)
			put_item(&b, 4)
		}
	} else {
		append(&b, 0x84)
		for _ in 0 ..< 4 {
			put_item(&b, 4)
		}
	}
	return b[:]
}

// Items whose windows end inside each kind of item: a head, a string's payload, a float, a tag and its folded number,
// a date text, an indefinite string's chunks, nested and indefinite containers, a sorted map's keys, and the faults a
// window may cut: a count past the text's end, bad UTF-8, a break out of place, bytes past the item, a cut item.
PIECE_HEX := [?]string {
	"a3 61 61 01 63 626262 82 f9 3c00 fb 3ff8000000000000 63 636363 a1 01 c1 1a 514b67b0",
	"84 78 20 6162636465666768696a6b6c6d6e6f707172737475767778797a303132333435 c2 49 010000000000000000 d8 18 43 010203 c0 74 323031332d30332d32315432303a30343a30305a",
	"9f 7f 63 616263 62 6465 ff 5f 42 0102 41 03 ff bf 61 6b 9f 01 02 ff ff 82 c4 82 21 19 6ab3 c5 82 20 03 ff",
	"a4 01 a1 61 78 83 01 02 03 02 82 a0 80 03 d9 d9f7 a2 61 61 f5 61 62 f6 04 9f 9f 9f 81 64 64656570 ff ff ff",
	"a2 61 61 01 61 62 a2 61 63 02 61 64 83 18 64 19 03e8 1a 000f4240",
	"9b 0000000000000100 01 02 03",
	"82 63 61 ff 62 01",
	"82 01 ff",
	"81 01 02",
	"83 61 61 62 62 62 a1 61",
	"c0 63 323031",
	"85 c2 41 01 c3 4a 0000000000000000000001 fa 7fc00000 f8 20 f7",
	"82 c0 7f 6b 323031332d30332d333154 69 32303a30343a30305a ff 01",
	"82 c0 7f 6b 323031332d30332d333154 69 32303a30343a36305a ff 01",
	"82 c4 82 20 c2 41 01 c5 82 20 c3 41 01",
	"c4 82 20 c2",
}

// Appends a nest of arrays and maps of few members each, so that a chunk's cut falls in a few definite containers at
// once and the items it completes close them.
put_nest :: proc(b: ^[dynamic]u8, depth: int) {
	if depth == 0 || rand.int_max(5) == 0 {
		put_head(b, 0, u64(rand.int_max(300)))
		return
	}
	n := 1 + rand.int_max(4)
	if rand.int_max(3) == 0 {
		put_head(b, 5, u64(n))
		for _ in 0 ..< n {
			put_key(b)
			put_nest(b, depth - 1)
		}
	} else {
		put_head(b, 4, u64(n))
		for _ in 0 ..< n {
			put_nest(b, depth - 1)
		}
	}
}

// Appends an item, a nest or now and then a long text string, which a chunk's cut falls inside and whose bytes read as
// the heads of other items.
put_value :: proc(b: ^[dynamic]u8) {
	switch rand.int_max(9) {
	case 0:
	case 1 ..< 5:
		put_nest(b, 5)
		return
	case:
		// An item the format reads, as a text with a fault ends its build at the first.
		item := make([dynamic]u8, context.temp_allocator)
		put_item(&item, 4)
		if cbor.validate(item[:]) == nil {
			append(b, ..item[:])
		} else {
			append(b, 0x01)
		}
		return
	}
	n := 200 + rand.int_max(1300)
	put_head(b, 3, u64(n))
	for _ in 0 ..< n {
		append(b, u8(0x20 + rand.int_max(0x60)))
	}
}

// A long text of `items` values in a container: an indefinite array, an array, an indefinite map or a map, and in a
// definite array with a tag before it, so a chunk of it starts inside any of them or inside an item of the values.
long_text :: proc(kind, items: int) -> []u8 {
	b := make([dynamic]u8)
	if kind == 4 {
		append(&b, 0xd9, 0xd9, 0xf7, 0x82, 0x01, 0xa1, 0x61, 'x')
	}
	switch kind {
	case 0, 4:
		append(&b, 0x9f)
	case 1:
		put_head(&b, 4, u64(items))
	case 2:
		append(&b, 0xbf)
	case:
		put_head(&b, 5, u64(items))
	}
	for _ in 0 ..< items {
		if kind == 2 || kind == 3 {
			put_key(&b)
		}
		put_value(&b)
	}
	if kind == 0 || kind == 2 || kind == 4 {
		append(&b, 0xff)
	}
	return b[:]
}

// Appends a nest of arrays and maps whose keys rise, so that a spec that orders keys reads it.
put_sorted :: proc(b: ^[dynamic]u8, depth: int) {
	if depth == 0 || rand.int_max(4) == 0 {
		if rand.int_max(3) == 0 {
			put_head(b, 3, 3)
			append(b, 'a', 'b', u8('a' + rand.int_max(26)))
		} else {
			put_head(b, 0, u64(rand.int_max(100_000)))
		}
		return
	}
	n := 1 + rand.int_max(4)
	if rand.int_max(2) == 0 {
		put_head(b, 5, u64(n))
		for k in 0 ..< n {
			append(b, 0x62, 'k', u8('0' + k))
			put_sorted(b, depth - 1)
		}
	} else {
		put_head(b, 4, u64(n))
		for _ in 0 ..< n {
			put_sorted(b, depth - 1)
		}
	}
}

// A long text of `items` values that a spec that orders keys reads, in an array (kind 0) or a map (1 and 2) whose keys
// rise.
sorted_text :: proc(kind, items: int) -> []u8 {
	b := make([dynamic]u8)
	put_head(&b, 4 if kind == 0 else 5, u64(items))
	for k in 0 ..< items {
		if kind != 0 {
			append(&b, 0x67, 'k')
			append(&b, ..transmute([]u8)fmt.tprintf("%06d", k))
		}
		if rand.int_max(9) == 0 {
			n := 200 + rand.int_max(1300)
			put_head(&b, 3, u64(n))
			for _ in 0 ..< n {
				append(&b, u8(0x20 + rand.int_max(0x60)))
			}
		} else {
			put_sorted(&b, 5)
		}
	}
	return b[:]
}
