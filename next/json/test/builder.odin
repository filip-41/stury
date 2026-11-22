package json_tests

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// Checks that the nodes of a built document nest as a tree: each container's subtree ends where its last child does,
// its `spelling` is its child count saturated at `MAX_CHILDREN`, and `counts` holds the true count of each container
// whose count reached it, in node order.
expect_well_formed :: proc(t: ^testing.T, doc: ^tape.Document, name := "", loc := #caller_location) -> bool {
	saturated := 0
	for node, i in doc.nodes {
		if node.kind < .Array {
			continue
		}
		end, count := i + int(node.n), 0
		ok := end <= len(doc.nodes)
		for k := i + 1; ok && k < end; {
			child := doc.nodes[k]
			if child.role == .Key {
				ok = node.kind == .Object && k + 1 < end
				k += 1
				child = doc.nodes[k]
			}
			ok &&= child.role == .Value
			count += 1
			k += int(child.n) if child.kind > .Plain else 1
			ok &&= k <= end
		}
		if !testing.expectf(t, ok, "%s: node %d is a container whose children do not end with it", name, i, loc = loc) {
			return false
		}
		if !testing.expectf(t, int(node.spelling) == min(count, int(tape.MAX_CHILDREN)), "%s: node %d holds %d children and spells %d", name, i, count, node.spelling, loc = loc) {
			return false
		}
		if count >= int(tape.MAX_CHILDREN) {
			if !testing.expectf(t, saturated < len(doc.counts) && int(doc.counts[saturated].node) == i && int(doc.counts[saturated].count) == count, "%s: node %d holds %d children, counts %v", name, i, count, doc.counts, loc = loc) {
				return false
			}
			saturated += 1
		}
	}
	return testing.expectf(t, saturated == len(doc.counts), "%s: %d saturated containers, counts %v", name, saturated, doc.counts, loc = loc)
}

// Whether documents `a` and `b` hold the same tree: the same kinds, roles, child counts and sizes, and the same text in
// each scalar.
same_tree :: proc(a, b: ^tape.Document) -> bool {
	if len(a.nodes) != len(b.nodes) {
		return false
	}
	for x, i in a.nodes {
		y := b.nodes[i]
		if x.kind != y.kind || x.role != y.role || x.n != y.n || x.spelling != y.spelling {
			return false
		}
		if x.kind <= .Plain && string(a.src[x.lo:][:x.n]) != string(b.src[y.lo:][:y.n]) {
			return false
		}
	}
	return true
}

// A container of `count` children of `kind`, an array of 0s or an object of members `k<i>`, in JSON.
container_of :: proc(kind: tape.Kind, count: int, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '[' if kind == .Array else '{')
	for i in 0 ..< count {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		if kind == .Array {
			strings.write_byte(&b, '0')
		} else {
			fmt.sbprintf(&b, `"k%d":0`, i)
		}
	}
	strings.write_byte(&b, ']' if kind == .Array else '}')
	return strings.to_string(b)
}

// A container's child count saturates at `MAX_CHILDREN`, and the document keeps the true count of each that reached
// it, for arrays and objects, alone and inside one another, on each side of the edge.
@(test)
child_counts_saturate_at_the_edge :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	MAX := int(tape.MAX_CHILDREN)
	for count in ([]int{0, 1, MAX - 1, MAX, MAX + 1, 2 * MAX, 2 * MAX + 1}) {
		for kind in ([]tape.Kind{.Array, .Object}) {
			inner := container_of(kind, count, context.temp_allocator)
			for text in ([]string{inner, strings.concatenate({"[", inner, ",", inner, "]"}, context.temp_allocator)}) {
				doc, err := json.build(transmute([]u8)text)
				defer tape.destroy(&doc)
				testing.expectf(t, err == nil, "%v %d: %v", kind, count, err)
				name := fmt.tprintf("%v %d", kind, count)
				if expect_well_formed(t, &doc, name) {
					n, p, _ := tape.length({doc = &doc}, tape.Node_Index(0 if len(text) == len(inner) else 1), context.temp_allocator)
					testing.expectf(t, p == .Found && n == count, "%s: length %d %v", name, n, p)
				}
			}
		}
	}
}

// A counting allocator, for the blocks a build takes.
Counting :: struct {
	backing: runtime.Allocator,
	calls:   int,
}

counting_allocator :: proc(c: ^Counting) -> runtime.Allocator {
	return {
		procedure = proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
			c := (^Counting)(data)
			c.calls += 1
			return c.backing.procedure(c.backing.data, mode, size, alignment, old_memory, old_size, loc)
		},
		data = c,
	}
}

// A build's room for nodes grows by doubling, so the allocator is asked a number of times that is a logarithm of the
// nodes, and a text of past 100,000 nodes gives one document.
@(test)
build_room_grows_by_doubling :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := transmute([]u8)container_of(.Array, 100_000, context.temp_allocator)
	defer free_all(context.temp_allocator)
	c := Counting{backing = context.allocator}
	doc, err := json.build(text, allocator = counting_allocator(&c))
	defer tape.destroy(&doc)
	testing.expectf(t, err == nil && len(doc.nodes) == 100_001, "%v %d", err, len(doc.nodes))
	testing.expectf(t, c.calls < 40, "%d allocator calls for 100,001 nodes", c.calls)
	testing.expect(t, expect_well_formed(t, &doc))
}

// A model of a value with repeated keys: its text, and the texts a build under `.First` and under `.Last` keeps.
Model :: struct {
	full, first, last: string,
}

// A random value of at most `depth` more levels, whose objects repeat keys, some spelled with an escape.
model_value :: proc(depth: int) -> Model {
	if depth == 0 || rand.int_max(3) == 0 {
		s := fmt.tprint(rand.int_max(1000))
		return {s, s, s}
	}
	if rand.int_max(3) == 0 {
		return model_members(depth, false, rand.int_max(4))
	}
	return model_members(depth, true, 1 + rand.int_max(7) if rand.int_max(6) != 0 else 20 + rand.int_max(30))
}

// The last two keys have one hash, so a build compares keys of one hash that differ.
MODEL_KEYS := [?][2]string{{"a", "a"}, {"b", "\\u0062"}, {"c", "c"}, {"key_of_sixteen_b", "key_of_sixteen_b"}, {"k", "\\u006b"}, {"é", "\\u00e9"}, {"exactly8", "exactly8"}, {"sixteen_bytes_16", "sixteen_bytes_16"}, {"c44611", "c44611"}, {"c98702", "c98702"}}

// An array or object of `width` members whose children are `model_value`s, and for an object keys `MODEL_KEYS` gives.
model_members :: proc(depth: int, object: bool, width: int) -> Model {
	full := strings.builder_make(context.temp_allocator)
	first := strings.builder_make(context.temp_allocator)
	last := strings.builder_make(context.temp_allocator)
	canonical := make([]int, width, context.temp_allocator)
	spelled := make([]string, width, context.temp_allocator)
	members := make([]Model, width, context.temp_allocator)
	for i in 0 ..< width {
		members[i] = model_value(depth - 1)
		if object {
			k := rand.int_max(len(MODEL_KEYS))
			canonical[i], spelled[i] = k, MODEL_KEYS[k][rand.int_max(2)]
		}
	}
	for b in ([]^strings.Builder{&full, &first, &last}) {
		strings.write_byte(b, '{' if object else '[')
	}
	counts := [3]int{}
	for i in 0 ..< width {
		keeps := [3]bool{true, true, true}
		for j in 0 ..< width {
			if object && j != i && canonical[j] == canonical[i] {
				keeps[1] &&= j > i
				keeps[2] &&= j < i
			}
		}
		for b, k in ([]^strings.Builder{&full, &first, &last}) {
			if !keeps[k] {
				continue
			}
			if counts[k] > 0 {
				strings.write_byte(b, ',')
			}
			counts[k] += 1
			if object {
				fmt.sbprintf(b, `"%s":`, spelled[i])
			}
			strings.write_string(b, ([]string{members[i].full, members[i].first, members[i].last})[k])
		}
	}
	for b in ([]^strings.Builder{&full, &first, &last}) {
		strings.write_byte(b, '}' if object else ']')
	}
	return {strings.to_string(full), strings.to_string(first), strings.to_string(last)}
}

// A build under `.First` or `.Last` is the build of the text with the other members of each key left out, in every
// container, and `.Refuse` fails where a key repeats and gives a document where none does.
@(test)
build_policies_keep_one_member_of_each_key :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xd0b5)
	for _ in 0 ..< testkit.rounds(300) {
		m := model_members(4, true, 1 + rand.int_max(6))
		check_policies(t, m)
	}
}

// Wide objects of `total` members, `repeats` of which repeat a key of an earlier member, so that the count of the
// object leaves, reaches or stays past `MAX_CHILDREN` as the repeats go.
@(test)
build_policies_recount_wide_objects :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	MAX := int(tape.MAX_CHILDREN)
	for c in ([][2]int{{MAX + 1, 1}, {MAX + 2, 1}, {MAX + 2, 2}, {MAX, 1}, {MAX + 40, 40}, {MAX + 1000, 1000}, {2 * MAX, 3}}) {
		total, repeats := c[0], c[1]
		full, first, last := strings.builder_make(context.temp_allocator), strings.builder_make(context.temp_allocator), strings.builder_make(context.temp_allocator)
		for b in ([]^strings.Builder{&full, &first, &last}) {
			strings.write_byte(b, '{')
		}
		for i in 0 ..< total {
			member := fmt.tprintf(`%s"k%d":%d`, "," if i > 0 else "", i % (total - repeats), i)
			strings.write_string(&full, member)
			if i < total - repeats {
				strings.write_string(&first, member)
			}
			if i >= repeats {
				strings.write_string(&last, fmt.tprintf(`%s"k%d":%d`, "," if i > repeats else "", i % (total - repeats), i))
			}
		}
		for b in ([]^strings.Builder{&full, &first, &last}) {
			strings.write_byte(b, '}')
		}
		check_policies(t, {strings.to_string(full), strings.to_string(first), strings.to_string(last)}, fmt.tprintf("%d members, %d repeats", total, repeats))
	}
}

check_policies :: proc(t: ^testing.T, m: Model, name := "", loc := #caller_location) {
	text := transmute([]u8)m.full
	for dups in ([]tape.Duplicates{.First, .Last}) {
		want_text := m.first if dups == .First else m.last
		got, gerr := json.build(text, opts = {dups = dups})
		defer tape.destroy(&got)
		want, werr := json.build(transmute([]u8)want_text)
		defer tape.destroy(&want)
		ok := testing.expectf(t, gerr == nil && werr == nil, "%s %v %q: %v %v", name, dups, m.full, gerr, werr, loc = loc)
		ok &&= testing.expectf(t, same_tree(&got, &want), "%s %v: %q builds %s, want %q", name, dups, m.full, render_doc(&got), want_text, loc = loc)
		ok &&= expect_well_formed(t, &got, name, loc = loc)
		if ok {
			// The facts of a dropped member go with it.
			for f in got.facts {
				testing.expect(t, int(f.node) < len(got.nodes), loc = loc)
			}
		}
	}
	refused_doc, rerr := json.build(text, opts = {dups = .Refuse})
	defer tape.destroy(&refused_doc)
	repeats := m.full != m.first
	testing.expectf(t, (rerr != nil) == repeats, "%s refuse %q: %v, repeats %v", name, m.full, rerr, repeats, loc = loc)
	if fault, refused := rerr.(tape.Fault); refused {
		testing.expectf(t, fault.kind == .Duplicate_Key, "%s %q: %v", name, m.full, rerr, loc = loc)
	}
}

// `.Refuse` fails at the first key in the text that repeats an earlier one of its object, whichever key of the object
// is repeated first in the order the build compares them, and in an object inside another that has repeats later.
@(test)
build_refuses_at_the_first_repeated_key :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x4ef05e)
	for _ in 0 ..< testkit.rounds(100) {
		// Each of `keys` keys appears twice, in a random order. The fault is at the first key seen a second time.
		keys := 2 + rand.int_max(8)
		order := make([]int, 2 * keys, context.temp_allocator)
		for &k, i in order {
			k = i / 2
		}
		rand.shuffle(order)
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"inner":{"x":1},"list":[],`)
		seen := make([]bool, keys, context.temp_allocator)
		want := -1
		for k, i in order {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			if seen[k] && want < 0 {
				want = strings.builder_len(b) + 1
			}
			seen[k] = true
			fmt.sbprintf(&b, `"key%d":%d`, k, i)
		}
		strings.write_string(&b, `,"tail":{"z":1,"z":2}}`)
		doc, err := json.build(transmute([]u8)strings.to_string(b), opts = {dups = .Refuse})
		tape.destroy(&doc)
		kind, at := fault_of(err)
		testing.expectf(t, kind == .Duplicate_Key && at == u64(want), "%s: %v at %d, want %d", strings.to_string(b), kind, at, want)
	}
}

// Two keys of one hash are two keys, in every order they come in among repeats of either.
@(test)
build_policies_tell_keys_of_one_hash_apart :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	f := json.as(.Json)
	a, b := "c44611", "c98702"
	hash := proc(f: ^tape.Format, key: string) -> u32 {
		return f.key_hash(transmute([]u8)key, {lo = 0, n = u32(len(key)), kind = .String})
	}
	testing.expect_value(t, hash(f, a), hash(f, b))
	orders := [][]string{{a, b, a, b}, {a, a, b, b}, {b, a, a, b}, {a, b, b, a}, {a, a, a, b}, {b, b, a, b, a}, {a, b, a, a, b, b, a}}
	for order in orders {
		first, last := strings.builder_make(context.temp_allocator), strings.builder_make(context.temp_allocator)
		full := strings.builder_make(context.temp_allocator)
		strings.write_byte(&full, '{')
		strings.write_byte(&first, '{')
		strings.write_byte(&last, '{')
		kept := [2]int{}
		for key, i in order {
			if i > 0 {
				strings.write_byte(&full, ',')
			}
			fmt.sbprintf(&full, `"%s":%d`, key, i)
		}
		for key, i in order {
			earlier, later := false, false
			for other, j in order {
				earlier ||= j < i && other == key
				later ||= j > i && other == key
			}
			if !earlier {
				fmt.sbprintf(&first, `%s"%s":%d`, "," if kept[0] > 0 else "", key, i)
				kept[0] += 1
			}
			if !later {
				fmt.sbprintf(&last, `%s"%s":%d`, "," if kept[1] > 0 else "", key, i)
				kept[1] += 1
			}
		}
		strings.write_byte(&full, '}')
		strings.write_byte(&first, '}')
		strings.write_byte(&last, '}')
		check_policies(t, {strings.to_string(full), strings.to_string(first), strings.to_string(last)}, "one hash")
	}
}

// A repeated key beside an array wider than the count's limit recounts the object without losing the array's count.
@(test)
build_policies_recount_beside_a_saturated_array :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for width in ([]int{int(tape.MAX_CHILDREN) - 1, int(tape.MAX_CHILDREN), int(tape.MAX_CHILDREN) + 1}) {
		array := strings.builder_make(context.temp_allocator)
		strings.write_string(&array, `{"arr":[0`)
		for _ in 1 ..< width {
			strings.write_string(&array, ",0")
		}
		strings.write_string(&array, `]`)
		full := fmt.tprintf(`%s,"k":1,"k":2}`, strings.to_string(array))
		for dups, kept in ([]tape.Duplicates{.First, .Last}) {
			want_text := fmt.tprintf(`%s,"k":%d}`, strings.to_string(array), kept + 1)
			got, gerr := json.build(transmute([]u8)full, opts = {dups = dups})
			defer tape.destroy(&got)
			want, werr := json.build(transmute([]u8)want_text)
			defer tape.destroy(&want)
			testing.expectf(t, gerr == nil && werr == nil, "width %d %v: %v %v", width, dups, gerr, werr)
			testing.expectf(t, same_tree(&got, &want), "width %d %v", width, dups)
			testing.expectf(t, expect_well_formed(t, &got), "width %d %v", width, dups)
		}
	}
}
