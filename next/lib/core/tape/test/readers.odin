package tape_test

import "core:testing"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:testkit"

// A format whose escaped scalars read as each of their bytes twice, so a decoded text is longer than its span, as a
// CBOR integer key's digits or an entity are.
@(rodata)
TWICE := tape.Format{name = "twice", decode = twice_decode, room = twice_room, number = twice_number, same_text = twice_same, key_hash = twice_hash}

twice_room :: proc "contextless" (src: []u8, t: tape.Node) -> int {
	return 2 * int(t.n)
}

twice_decode :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8) -> (string, bool) {
	if len(buf) < 2 * int(t.n) {
		return "", false
	}
	for b, i in src[t.lo:][:t.n] {
		buf[2 * i], buf[2 * i + 1] = b, b
	}
	return string(buf[:2 * t.n]), true
}

twice_number :: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number {
	return {bits = u64(src[t.lo] - '0'), kind = .Int}
}

// Byte `i` of the text of `t`, false past its end.
twice_text :: proc "contextless" (src: []u8, t: tape.Token, i: int) -> (u8, bool) {
	if t.spelling & tape.SPELLING_DECODE == 0 {
		return src[t.lo + u64(i)] if i < int(t.n) else 0, i < int(t.n)
	}
	return src[t.lo + u64(i / 2)] if i < 2 * int(t.n) else 0, i < 2 * int(t.n)
}

twice_same :: proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool {
	for i := 0; ; i += 1 {
		a, more := twice_text(src, t, i)
		b, other_more := twice_text(other, o, i)
		if more != other_more || a != b {
			return false
		}
		if !more {
			return true
		}
	}
}

twice_hash :: proc "contextless" (src: []u8, t: tape.Token) -> u32 {
	x := tape.text_hasher()
	for i := 0; i < 2 * int(t.n); i += 1 {
		b, more := twice_text(src, t, i)
		if !more {
			break
		}
		tape.text_hash_byte(&x, b)
	}
	return tape.text_hasher_end(&x)
}

scalar :: proc(lo, n: int, kind := tape.Kind.String, role := tape.Role.Value, spelling := u16(0)) -> tape.Node {
	return {lo = u64(lo), n = u32(n), kind = kind, role = role, spelling = spelling}
}

container :: proc(lo, nodes, children: int, kind: tape.Kind, role := tape.Role.Value) -> tape.Node {
	return {lo = u64(lo), n = u32(nodes), kind = kind, role = role, spelling = u16(children)}
}

// A key whose text is longer than its span is found by its text, and its text needs the room the format gives.
@(test)
readers_take_a_decode_past_its_span :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("ab1")
	nodes := []tape.Node{container(0, 3, 1, .Object), scalar(0, 2, role = .Key, spelling = tape.SPELLING_DECODE), scalar(2, 1, .Number)}
	doc := tape.Document{src = src, nodes = nodes, format = &TWICE}
	r := tape.Reader{&doc, nil}
	v, p := tape.member(r, tape.ROOT, "aabb")
	testing.expect(t, v == 2 && p == .Found)
	_, p = tape.member(r, tape.ROOT, "ab")
	testing.expect_value(t, p, tape.Presence.Missing)
	short: [2]u8
	_, ok := tape.node_text(&doc, 1, short[:])
	testing.expect(t, !ok)
	room := tape.text_room(&doc, 1)
	testing.expect_value(t, room, 4)
	buf: [4]u8
	text, fits := tape.node_text(&doc, 1, buf[:room])
	testing.expect(t, fits && text == "aabb")
}

// A table's rows read their cells by the header's keys, and the table its rows by place, the header no element.
@(test)
readers_read_tables :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// name,age / ann,3 / bob,4,9
	src := transmute([]u8)string("name,age\nann,3\nbob,4,9\n")
	nodes := []tape.Node{
		container(0, 11, 2, .Array),
		container(0, 3, 2, .Array, .Key),
		scalar(0, 4, .Plain, .Key),
		scalar(5, 3, .Plain, .Key),
		container(9, 3, 2, .Object),
		scalar(9, 3, .Plain),
		scalar(13, 1, .Plain),
		container(15, 4, 3, .Object),
		scalar(15, 3, .Plain),
		scalar(19, 1, .Plain),
		scalar(21, 1, .Plain),
	}
	for slotted in ([]bool{false, true}) {
		slots := make([]u16, 4 if slotted else 0, context.temp_allocator)
		for col in 0 ..< len(slots) / 2 {
			k := nodes[2 + col]
			mask := u32(len(slots) - 1)
			i := TWICE.key_hash(src, k) & mask
			for slots[i] != 0 {
				i = (i + 1) & mask
			}
			slots[i] = u16(col + 1)
		}
		ext := tape.Tabular_Ext{tables = {{node = 0, header = 1, first_row = 4, slots_len = u32(len(slots)), unique_keys = true}}, slots = slots}
		doc := tape.Document{src = src, nodes = nodes, format = &TWICE, ext = &ext}
		r := tape.Reader{&doc, nil}
		row, p := tape.element(r, tape.ROOT, 1)
		testing.expect(t, row == 7 && p == .Found)
		row, p = tape.element(r, tape.ROOT, -2)
		testing.expect(t, row == 4 && p == .Found)
		_, p = tape.element(r, tape.ROOT, 2)
		testing.expect_value(t, p, tape.Presence.Missing)
		v: tape.Node_Index
		v, p = tape.member(r, 7, "age")
		testing.expect(t, v == 9 && p == .Found)
		v, p = tape.member(r, 4, "name")
		testing.expect(t, v == 5 && p == .Found)
		_, p = tape.member(r, 4, "x")
		testing.expect_value(t, p, tape.Presence.Missing)
		n, _, _ := tape.length(r, 7, context.temp_allocator)
		testing.expect_value(t, n, 2)
		rows, _, _ := tape.children(r, tape.ROOT, context.temp_allocator)
		_, first, _ := tape.next_child(r, &rows)
		_, second, _ := tape.next_child(r, &rows)
		_, _, end := tape.next_child(r, &rows)
		testing.expect(t, first == 4 && second == 7 && end == .Missing)
		cells, _, _ := tape.children(r, 4, context.temp_allocator)
		k1, v1, _ := tape.next_child(r, &cells)
		k2, v2, _ := tape.next_child(r, &cells)
		_, _, done := tape.next_child(r, &cells)
		testing.expect(t, k1 == 2 && v1 == 5 && k2 == 3 && v2 == 6 && done == .Missing)
	}
}

// A header that repeats a key gives its row's first or last cell of it by the policy, and the key once.
@(test)
readers_read_tables_that_repeat_a_key :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a,a\n1,2\n")
	nodes := []tape.Node{
		container(0, 6, 1, .Array),
		container(0, 3, 2, .Array, .Key),
		scalar(0, 1, .Plain, .Key),
		scalar(2, 1, .Plain, .Key),
		container(4, 3, 2, .Object),
		scalar(4, 1, .Plain),
		scalar(6, 1, .Plain),
	}
	ext := tape.Tabular_Ext{tables = {{node = 0, header = 1, first_row = 4, width = 2}}}
	doc := tape.Document{src = src, nodes = nodes, format = &TWICE, ext = &ext}
	r := tape.Reader{&doc, nil}
	row, _ := tape.element(r, tape.ROOT, 0)
	testing.expect_value(t, row, 4)
	last, _ := tape.member(r, row, "a", .Last)
	first, _ := tape.member(r, row, "a", .First)
	testing.expect(t, last == 6 && first == 5)
	n, _, _ := tape.length(r, row, context.temp_allocator)
	testing.expect_value(t, n, 1)
	c, _, _ := tape.children(r, row, context.temp_allocator)
	k, v, _ := tape.next_child(r, &c, .Last)
	_, _, end := tape.next_child(r, &c, .Last)
	testing.expect(t, k == 2 && v == 6 && end == .Missing)
	g, gp := tape.named(r, row, "a")
	_, g1, _ := tape.next_child(r, &g)
	_, g2, _ := tape.next_child(r, &g)
	testing.expect(t, gp == .Found && g1 == 5 && g2 == 6)
}

// Keys of two kinds that read as one name make a read of it by name under `.Last` ambiguous, and `.First` and a
// group take them in document order.
@(test)
readers_refuse_a_clashing_name :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("1x1y")
	nodes := []tape.Node{
		container(0, 5, 2, .Object),
		scalar(0, 1, .Number, .Key),
		scalar(1, 1, .Plain),
		scalar(2, 1, .String, .Key),
		scalar(3, 1, .Plain),
	}
	ext := tape.Yaml_Ext{clash = 2}
	doc := tape.Document{src = src, nodes = nodes, format = &TWICE, ext = &ext}
	r := tape.Reader{&doc, nil}
	_, p := tape.member(r, tape.ROOT, "1")
	testing.expect_value(t, p, tape.Presence.Ambiguous)
	v, fp := tape.member(r, tape.ROOT, "1", .First)
	testing.expect(t, v == 2 && fp == .Found)
	g, gp := tape.named(r, tape.ROOT, "1")
	_, g1, _ := tape.next_child(r, &g)
	_, g2, _ := tape.next_child(r, &g)
	testing.expect(t, gp == .Found && g1 == 2 && g2 == 4)
	n, _, _ := tape.length(r, tape.ROOT, context.temp_allocator)
	testing.expect_value(t, n, 2)
	doc.ext = nil
	v, p = tape.member(r, tape.ROOT, "1")
	testing.expect(t, v == 4 && p == .Found)
}
