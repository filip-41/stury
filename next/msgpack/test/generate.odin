package msgpack_tests

import "core:encoding/endian"
import "core:math/rand"
import "stury:msgpack"

// Random MessagePack generators and mutations covering every wire type, non-compact encoding,
// ext/timestamp payloads, and piece-cut test inputs.

put_str :: proc(b: ^[dynamic]u8, s: string, wide := false) {
	n := len(s)
	switch {
	case n <= 31 && !wide:
		append(b, 0xa0 | u8(n))
	case n <= 0xff:
		append(b, 0xd9, u8(n))
	case n <= 0xffff:
		h := [3]u8{0xda, 0, 0}
		endian.unchecked_put_u16be(h[1:], u16(n))
		append(b, ..h[:])
	case:
		h := [5]u8{0xdb, 0, 0, 0, 0}
		endian.unchecked_put_u32be(h[1:], u32(n))
		append(b, ..h[:])
	}
	append(b, s)
}

put_bin :: proc(b: ^[dynamic]u8, data: []u8, wide := false) {
	n := len(data)
	switch {
	case n <= 0xff && !wide:
		append(b, 0xc4, u8(n))
	case n <= 0xffff:
		h := [3]u8{0xc5, 0, 0}
		endian.unchecked_put_u16be(h[1:], u16(n))
		append(b, ..h[:])
	case:
		h := [5]u8{0xc6, 0, 0, 0, 0}
		endian.unchecked_put_u32be(h[1:], u32(n))
		append(b, ..h[:])
	}
	append(b, ..data)
}

put_array_head :: proc(b: ^[dynamic]u8, n: u32, wide := false) {
	switch {
	case n <= 15 && !wide:
		append(b, 0x90 | u8(n))
	case n <= 0xffff:
		h := [3]u8{0xdc, 0, 0}
		endian.unchecked_put_u16be(h[1:], u16(n))
		append(b, ..h[:])
	case:
		h := [5]u8{0xdd, 0, 0, 0, 0}
		endian.unchecked_put_u32be(h[1:], n)
		append(b, ..h[:])
	}
}

put_map_head :: proc(b: ^[dynamic]u8, n: u32, wide := false) {
	switch {
	case n <= 15 && !wide:
		append(b, 0x80 | u8(n))
	case n <= 0xffff:
		h := [3]u8{0xde, 0, 0}
		endian.unchecked_put_u16be(h[1:], u16(n))
		append(b, ..h[:])
	case:
		h := [5]u8{0xdf, 0, 0, 0, 0}
		endian.unchecked_put_u32be(h[1:], n)
		append(b, ..h[:])
	}
}

put_key :: proc(b: ^[dynamic]u8) {
	switch rand.int_max(6) {
	case 0:
		v := rand.int_max(64) - 20
		if v >= 0 {
			append(b, u8(v))
		} else {
			append(b, u8(i8(v)))
		}
	case 1:
		append(b, 0xc4, 0x01, u8('a' + rand.int_max(3)))
	case:
		append(b, 0xa1, u8('a' + rand.int_max(6)))
	}
}

put_item :: proc(b: ^[dynamic]u8, depth: int) {
	pick := rand.int_max(15 if depth > 0 else 11)
	switch pick {
	case 0: // uint variants
		switch rand.int_max(5) {
		case 0:
			append(b, u8(rand.int_max(128)))
		case 1:
			append(b, 0xcc, u8(rand.int_max(256)))
		case 2:
			h := [3]u8{0xcd, 0, 0}
			endian.unchecked_put_u16be(h[1:], u16(rand.int_max(65536)))
			append(b, ..h[:])
		case 3:
			h := [5]u8{0xce, 0, 0, 0, 0}
			endian.unchecked_put_u32be(h[1:], rand.uint32())
			append(b, ..h[:])
		case:
			h := [9]u8{0xcf, 0, 0, 0, 0, 0, 0, 0, 0}
			endian.unchecked_put_u64be(h[1:], rand.uint64())
			append(b, ..h[:])
		}
	case 1: // int variants
		switch rand.int_max(5) {
		case 0:
			append(b, u8(i8(-1 - rand.int_max(32))))
		case 1:
			append(b, 0xd0, u8(i8(-128 + rand.int_max(256))))
		case 2:
			h := [3]u8{0xd1, 0, 0}
			endian.unchecked_put_u16be(h[1:], u16(i16(-32768 + rand.int_max(1000))))
			append(b, ..h[:])
		case 3:
			h := [5]u8{0xd2, 0, 0, 0, 0}
			endian.unchecked_put_u32be(h[1:], transmute(u32)i32(-100_000))
			append(b, ..h[:])
		case:
			h := [9]u8{0xd3, 0, 0, 0, 0, 0, 0, 0, 0}
			endian.unchecked_put_u64be(h[1:], transmute(u64)min(i64))
			append(b, ..h[:])
		}
	case 2: // str
		n := rand.int_max(40)
		wide := rand.int_max(5) == 0
		tmp := make([dynamic]u8, context.temp_allocator)
		for _ in 0 ..< n {
			append(&tmp, u8('a' + rand.int_max(26)))
		}
		if rand.int_max(3) == 0 {
			append(&tmp, 0xc3, 0xa9)
		}
		put_str(b, string(tmp[:]), wide)
	case 3: // bin
		n := rand.int_max(12)
		tmp := make([]u8, n, context.temp_allocator)
		for i in 0 ..< n {
			tmp[i] = u8(rand.int_max(256))
		}
		put_bin(b, tmp, rand.int_max(5) == 0)
	case 4: // nil / false / true
		pick_simple := [3]u8{0xc0, 0xc2, 0xc3}
		append(b, pick_simple[rand.int_max(3)])
	case 5: // floats
		if rand.int_max(2) == 0 {
			append(b, 0xca, 0x3f, 0xc0, 0x00, 0x00) // 1.5 f32
		} else {
			append(b, 0xcb, 0x3f, 0xf1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9a) // ~1.1 f64
		}
	case 6: // timestamp 32
		h := [6]u8{0xd6, 0xff, 0, 0, 0, 0}
		endian.unchecked_put_u32be(h[2:], rand.uint32())
		append(b, ..h[:])
	case 7: // timestamp 64
		sec := u64(rand.uint32())
		ns := u64(rand.int_max(1_000_000_000))
		h := [10]u8{0xd7, 0xff, 0, 0, 0, 0, 0, 0, 0, 0}
		endian.unchecked_put_u64be(h[2:], (ns << 34) | sec)
		append(b, ..h[:])
	case 8: // timestamp 96 (including negative epoch)
		h := [15]u8{0xc7, 12, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
		endian.unchecked_put_u32be(h[3:7], u32(rand.int_max(1_000_000_000)))
		endian.unchecked_put_u64be(h[7:15], transmute(u64)i64(-86400 * 365 * 10))
		append(b, ..h[:])
	case 9: // general fixext
		types := [?]u8{1, 7, 42, 0x80}
		t := types[rand.int_max(len(types))]
		switch rand.int_max(3) {
		case 0:
			append(b, 0xd4, t, 0xaa)
		case 1:
			append(b, 0xd5, t, 0x11, 0x22)
		case:
			append(b, 0xd6, t, 1, 2, 3, 4)
		}
	case 10: // ext 8 (empty or 3 bytes)
		append(b, 0xc7, 0x03, 0x09, 0xde, 0xad, 0xbe)
	case 11, 12: // array
		n := u32(rand.int_max(6))
		put_array_head(b, n, rand.int_max(5) == 0)
		for _ in u32(0) ..< n {
			put_item(b, depth - 1)
		}
	case: // map
		n := u32(rand.int_max(6))
		put_map_head(b, n, rand.int_max(5) == 0)
		for _ in u32(0) ..< n {
			put_key(b)
			put_item(b, depth - 1)
		}
	}
}

random_item :: proc() -> []u8 {
	b := make([dynamic]u8)
	if rand.int_max(2) == 0 {
		put_map_head(&b, 3)
		for _ in 0 ..< 3 {
			put_key(&b)
			put_item(&b, 4)
		}
	} else {
		append(&b, 0x94)
		for _ in 0 ..< 4 {
			put_item(&b, 4)
		}
	}
	return b[:]
}

mutated :: proc(src: []u8) -> []u8 {
	b := make([dynamic]u8, len(src))
	copy(b[:], src)
	if len(b) == 0 {
		append(&b, 0xc1)
		return b[:]
	}
	at := rand.int_max(len(src))
	switch rand.int_max(3) {
	case 0:
		b[at] = u8(rand.int_max(256))
	case 1:
		ordered_remove(&b, at)
	case:
		resize(&b, at)
	}
	return b[:]
}

// Representative MessagePack wire items (valid and invalid) for piece, record, and thread laws.
PIECE_HEX := [?]string {
	"83 a1 61 01 a3 626262 92 ca 3f800000 cb 3ff8000000000000 a3 636363 81 01 d6 ff 514b67b0",
	"94 d9 20 6162636465666768696a6b6c6d6e6f707172737475767778797a303132333435 c4 03 010203 d7 ff 0000000100000005 c7 0c ff 3b9ac9ff ffffffffffffff00",
	"93 d4 2a 7f c5 0002 aabb c3",
	"84 01 81 a1 78 93 01 02 03 02 92 80 90 03 d5 07 cafe 04 91 91 91 81 a4 64656570 c2",
	"82 a1 61 01 a1 62 82 a1 63 02 a1 64 93 cc 64 cd 03e8 ce 000f4240",
	// Malformed items:
	"c1",
	"92 a3 61 ff 62 01",
	"91 01 02",
	"83 a1 61 62 a1 61",
	"d6 ff",
	"d7 ff 3b9aca00 00000000",
	"c7 0c ff 3b9aca00 0000000000000000",
	"dd ffffffff 01 02 03",
	"92 a1 01 c0 c1",
	"81 c0 01",
}

put_nest :: proc(b: ^[dynamic]u8, depth: int) {
	if depth == 0 || rand.int_max(5) == 0 {
		v := rand.int_max(200)
		if v < 128 {
			append(b, u8(v))
		} else {
			append(b, 0xcc, u8(v))
		}
		return
	}
	n := u32(1 + rand.int_max(4))
	if rand.int_max(3) == 0 {
		put_map_head(b, n)
		for _ in u32(0) ..< n {
			put_key(b)
			put_nest(b, depth - 1)
		}
	} else {
		put_array_head(b, n)
		for _ in u32(0) ..< n {
			put_nest(b, depth - 1)
		}
	}
}

put_value :: proc(b: ^[dynamic]u8) {
	switch rand.int_max(9) {
	case 0:
	case 1 ..< 5:
		put_nest(b, 5)
		return
	case:
		item := make([dynamic]u8, context.temp_allocator)
		put_item(&item, 4)
		if msgpack.validate(item[:]) == nil {
			append(b, ..item[:])
		} else {
			append(b, 0x01)
		}
		return
	}
	n := u32(200 + rand.int_max(1300))
	h := [3]u8{0xda, u8(n >> 8), u8(n)}
	append(b, ..h[:])
	for _ in u32(0) ..< n {
		append(b, u8(0x20 + rand.int_max(0x60)))
	}
}

long_text :: proc(kind, items: int) -> []u8 {
	b := make([dynamic]u8)
	if kind % 2 == 0 {
		put_array_head(&b, u32(items))
	} else {
		put_map_head(&b, u32(items))
	}
	for _ in 0 ..< items {
		if kind % 2 != 0 {
			put_key(&b)
		}
		put_value(&b)
	}
	return b[:]
}
