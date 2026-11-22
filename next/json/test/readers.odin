package json_tests

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// A key of the object at `at` and the node of its value.
Naive_Member :: struct {
	key:   string,
	value: tape.Node_Index,
}

// The members of the object at `at` as written, read straight from the nodes.
naive_members :: proc(doc: ^tape.Document, at: tape.Node_Index) -> []Naive_Member {
	members := make([dynamic]Naive_Member, context.temp_allocator)
	end := at + tape.Node_Index(doc.nodes[at].n)
	for k := at + 1; k < end; {
		value := k + 1
		append(&members, Naive_Member{key_text(doc, k), value})
		k = value + tape.Node_Index(doc.nodes[value].n) if doc.nodes[value].kind > .Plain else value + 1
	}
	return members[:]
}

// The values of the elements of the array at `at`.
naive_elements :: proc(doc: ^tape.Document, at: tape.Node_Index) -> []tape.Node_Index {
	elements := make([dynamic]tape.Node_Index, context.temp_allocator)
	end := at + tape.Node_Index(doc.nodes[at].n)
	for k := at + 1; k < end; {
		append(&elements, k)
		k += tape.Node_Index(doc.nodes[k].n) if doc.nodes[k].kind > .Plain else 1
	}
	return elements[:]
}

// A random object or array of `width` children, whose keys repeat among `names`, some spelled with an escape, in an
// array that holds it twice, and its text.
random_container :: proc(object: bool, width, names: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{' if object else '[')
	for i in 0 ..< width {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		if object {
			n := rand.int_max(names)
			if n % 3 == 0 && rand.int_max(2) == 0 {
				fmt.sbprintf(&b, `"k%d":`, n)
			} else {
				fmt.sbprintf(&b, `"k%d":`, n)
			}
		}
		fmt.sbprint(&b, i)
	}
	strings.write_byte(&b, '}' if object else ']')
	return strings.to_string(b)
}

// Every reader over the whole container of any width gives what a read of its nodes gives, with and without an index,
// under each policy.
@(test)
readers_agree_with_a_read_of_the_nodes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x4ead)
	widths := [?]int{0, 1, 2, 3, 7, 8, 9, 10, 17, 18, 40, 100}
	for width in widths {
		for names in ([]int{1, 2, 5, 40}) {
			for _ in 0 ..< testkit.rounds(3) {
				for object in ([]bool{false, true}) {
					text := random_container(object, width, names)
					doc, err := json.build(transmute([]u8)text)
					defer tape.destroy(&doc)
					x := tape.index_of(&doc, context.allocator)
					defer tape.destroy_index(&x)
					if !testing.expectf(t, err == nil, "%s: %v", text, err) {
						continue
					}
					for r in ([]tape.Reader{{&doc, nil}, {&doc, &x}, {&doc, &x}}) {
						check_readers(t, r, text, object)
					}
				}
			}
		}
	}
}

check_readers :: proc(t: ^testing.T, r: tape.Reader, text: string, object: bool, loc := #caller_location) {
	doc := r.doc
	if object {
		members := naive_members(doc, tape.ROOT)
		first := make(map[string]tape.Node_Index, context.temp_allocator)
		last := make(map[string]tape.Node_Index, context.temp_allocator)
		order := make([dynamic]string, context.temp_allocator)
		for m in members {
			if m.key not_in first {
				first[m.key] = m.value
				append(&order, m.key)
			}
			last[m.key] = m.value
		}
		n, p, _ := tape.length(r, tape.ROOT, context.temp_allocator)
		testing.expectf(t, p == .Found && n == len(order), "%s: length %d %v, want %d", text, n, p, len(order), loc = loc)
		for dups in ([]tape.Duplicates{.Default, .Last, .First}) {
			for name in ([]string{"k0", "k1", "k2", "k3", "k4", "k39", "zz", ""}) {
				got, gp := tape.member(r, tape.ROOT, name, dups)
				lookup := first if dups == .First else last
				want, present := lookup[name]
				if present {
					testing.expectf(t, gp == .Found && got == want, "%s %v %q: %v %v, want %v", text, dups, name, gp, got, want, loc = loc)
				} else {
					testing.expectf(t, gp == .Missing, "%s %v %q: %v", text, dups, name, gp, loc = loc)
				}
			}
			c, cp, _ := tape.children(r, tape.ROOT, context.temp_allocator)
			defer tape.destroy(&c)
			testing.expect(t, cp == .Found, loc = loc)
			for key in order {
				k, v, vp := tape.next_child(r, &c, dups)
				want := first[key] if dups == .First else last[key]
				testing.expectf(t, vp == .Found && key_text(doc, k) == key && v == want, "%s %v: child %q gives %q %v %v, want %v", text, dups, key, key_text(doc, k) if k != tape.NO_NODE else "", vp, v, want, loc = loc)
			}
			_, _, end := tape.next_child(r, &c, dups)
			testing.expectf(t, end == .Missing, "%s %v: %v past the last child", text, dups, end, loc = loc)
		}
		_, wp := tape.element(r, tape.ROOT, 0)
		testing.expectf(t, wp == .Wrong_Kind, "%s: element of an object %v", text, wp, loc = loc)
		return
	}
	elements := naive_elements(doc, tape.ROOT)
	n, p, _ := tape.length(r, tape.ROOT, context.temp_allocator)
	testing.expectf(t, p == .Found && n == len(elements), "%s: length %d %v", text, n, p, loc = loc)
	for i in -len(elements) - 2 ..= len(elements) + 1 {
		got, gp := tape.element(r, tape.ROOT, i)
		j := i if i >= 0 else len(elements) + i
		if j >= 0 && j < len(elements) {
			testing.expectf(t, gp == .Found && got == elements[j], "%s: element %d is %v %v, want %v", text, i, gp, got, elements[j], loc = loc)
		} else {
			testing.expectf(t, gp == .Missing, "%s: element %d is %v", text, i, gp, loc = loc)
		}
	}
	c, cp, _ := tape.children(r, tape.ROOT, context.temp_allocator)
	defer tape.destroy(&c)
	testing.expect(t, cp == .Found, loc = loc)
	for e in elements {
		k, v, vp := tape.next_child(r, &c)
		testing.expectf(t, vp == .Found && k == tape.NO_NODE && v == e, "%s: element child %v %v, want %v", text, vp, v, e, loc = loc)
	}
	_, _, end := tape.next_child(r, &c)
	testing.expectf(t, end == .Missing, "%s: %v past the last element", text, end, loc = loc)
	_, mp := tape.member(r, tape.ROOT, "k0")
	testing.expectf(t, mp == .Wrong_Kind, "%s: member of an array %v", text, mp, loc = loc)
}

// An index takes no memory for an element before the 16th, and takes some for the 16th and after.
@(test)
index_allocates_from_the_sixteenth_element :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := transmute([]u8)container_of(.Array, 100, context.temp_allocator)
	defer free_all(context.temp_allocator)
	doc, err := json.build(text)
	defer tape.destroy(&doc)
	testing.expect(t, err == nil)
	for i in ([]int{0, 1, 14, 15, 16, 17, 99}) {
		c := Counting{backing = context.allocator}
		x := tape.index_of(&doc, counting_allocator(&c))
		_, found := tape.element({&doc, &x}, 0, i)
		tape.destroy_index(&x)
		testing.expectf(t, found == .Found, "element %d: %v", i, found)
		testing.expectf(t, (c.calls > 0) == (i >= 16), "element %d: %d allocator calls", i, c.calls)
	}
}

// An index lists the members of an object of more than eight, and keeps only a mark for a smaller one, so the
// blocks an index takes differ at that size for every reader that lists them.
@(test)
index_lists_objects_of_more_than_eight_members :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	Probe :: enum {
		Member,
		Length,
		Children,
	}
	for probe in Probe {
		bytes: [dynamic]int
		defer delete(bytes)
		for n in 7 ..= 10 {
			b := strings.builder_make(context.temp_allocator)
			strings.write_byte(&b, '{')
			for i in 0 ..< n {
				fmt.sbprintf(&b, `%s"k%d":%d`, "," if i > 0 else "", i, i)
			}
			strings.write_byte(&b, '}')
			doc, err := json.build(transmute([]u8)strings.to_string(b))
			defer tape.destroy(&doc)
			testing.expect(t, err == nil)
			c := Counting{backing = context.allocator}
			x := tape.index_of(&doc, counting_allocator(&c))
			r := tape.Reader{&doc, &x}
			switch probe {
			case .Member:
				_, found := tape.member(r, 0, fmt.tprintf("k%d", n - 1))
				testing.expect_value(t, found, tape.Presence.Found)
			case .Length:
				got, found, lerr := tape.length(r, 0, context.allocator)
				testing.expectf(t, lerr == nil && found == .Found && got == n, "length %d: %d %v", n, got, found)
			case .Children:
				ch, found, cerr := tape.children(r, 0, context.allocator)
				testing.expectf(t, cerr == nil && found == .Found, "children %d: %v %v", n, found, cerr)
				tape.destroy_children(&ch)
			}
			tape.destroy_index(&x)
			append(&bytes, c.calls)
		}
		testing.expectf(t, bytes[0] == bytes[1] && bytes[2] != bytes[1] && bytes[2] <= bytes[3], "%v: index calls for 7 to 10 members %v", probe, bytes)
	}
}
