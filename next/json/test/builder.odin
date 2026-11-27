package json_tests

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:mem"
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
		ok &&= testing.expectf(t, same_tree(&got, &want), "%s %v: %q builds %s, want %q", name, dups, m.full, testkit.render_doc(&got), want_text, loc = loc)
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
				want = strings.builder_len(b)
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

// Under `.Refuse` a repeated key before a fault of the walk comes first, as the first fault in the text wins, whether
// its object is closed or open at the fault. Under another policy the walk's fault is the error.
@(test)
build_refuses_a_repeat_before_a_fault :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := [?]struct {
		text:    string,
		refusing: bool,
	} {
		{`{"a":1,"a":2,]`, true},
		{`[{"a":1,"a":2},]`, true},
		{`{"a":1,"b":2,"a":,}`, true},
		{`{"a":1,"b":2 x`, false},
	}
	for c in cases {
		for dups in ([]tape.Duplicates{.Refuse, .Last}) {
			doc, err := json.build(transmute([]u8)c.text, opts = {dups = dups})
			tape.destroy(&doc)
			kind, _ := fault_of(err)
			repeat_first := c.refusing && dups == .Refuse
			testing.expectf(t, err != nil && (kind == .Duplicate_Key) == repeat_first, "%q %v: %v", c.text, dups, err)
		}
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

// A text that makes more nodes than `tape.MAX_CHILDREN` builds into an arena that holds its nodes and little more, though
// its first room is smaller: the child counts come before the nodes, so the arena grows the nodes in place.
@(test)
builds_fit_the_smallest_arena_past_the_child_count_limit :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := transmute([]u8)strings.concatenate({"[", strings.repeat("1,", 50_000, context.temp_allocator), "1]"}, context.temp_allocator)
	first, err := json.build(src)
	defer tape.destroy(&first)
	testing.expect_value(t, err, nil)
	testing.expect(t, len(first.nodes) > int(tape.MAX_CHILDREN) * 2)
	backing := make([]u8, len(first.nodes) * size_of(tape.Node) + ARENA_SLACK)
	defer delete(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	doc, derr := json.build(src, .Json, {}, mem.arena_allocator(&arena))
	testing.expectf(t, derr == nil, "%d bytes: %v", len(backing), derr)
	testing.expect_value(t, len(doc.nodes), len(first.nodes))
}

// The bytes past its nodes that a build takes from an arena: the child counts and the arena's alignment.
@(private = "file")
ARENA_SLACK :: 256

// An empty `runtime.Allocator{}` or `mem.nil_allocator()` refuses allocation without falling back to `context.allocator`,
// both on whole builds past 16 KiB and on streaming `so_far` builds with saturated open containers.
@(test)
empty_and_nil_allocators_never_fall_back_to_context :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	// > 16 KiB text so `wide_room(most) > 0` and > MAX_CHILDREN elements so `counts` is needed.
	src := transmute([]u8)container_of(.Array, int(tape.MAX_CHILDREN) + 64, context.temp_allocator)
	for bad in ([]runtime.Allocator{{}, mem.nil_allocator()}) {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		{
			context.allocator = mem.tracking_allocator(&track)
			doc, err := json.build(src, .Json, {}, bad)
			tape.destroy(&doc)
			ae, is_ae := err.(runtime.Allocator_Error)
			testing.expectf(t, is_ae && ae == .Out_Of_Memory, "whole build: got %v", err)
		}
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, track.total_memory_allocated, 0)
	}
	// Streaming `so_far` with a saturated open container (> MAX_CHILDREN elements before the cut).
	cut := len(src) - 1 // right before closing `]`
	for bad in ([]runtime.Allocator{{}, mem.nil_allocator()}) {
		pieces := tape.Pieces{so_far = true, allocator = context.allocator}
		defer tape.destroy(&pieces)
		// Feed the prefix with a real allocator for pieces state, but pass `bad` as the caller allocator for `so_far`.
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		pieces.more = true
		{
			context.allocator = mem.tracking_allocator(&track)
			doc, err := json.build(src[:cut], .Json, {pieces = &pieces}, bad)
			tape.destroy(&doc)
			ae, is_ae := err.(runtime.Allocator_Error)
			testing.expectf(t, is_ae && ae == .Out_Of_Memory, "so_far build: got %v", err)
		}
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, track.total_memory_allocated, 0)
	}
}

// A 1 MiB single string (1 node = 16 B) builds under a tight 256-byte memory budget without `counts = most`
// pre-reservation exceeding the budget.
@(test)
budgeted_large_single_string_skips_counts_prereservation :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := transmute([]u8)strings.concatenate({`"`, strings.repeat("a", 1 << 20, context.temp_allocator), `"`}, context.temp_allocator)
	doc, err := json.build(src, .Json, {budget = {memory = 256}})
	defer tape.destroy(&doc)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(doc.nodes), 1)
}

// `builder_grow_facts` respects `Budget.memory` and backs off down to +1 fact instead of failing at the 16-fact minimum.
@(test)
budgeted_facts_back_off_under_tight_memory :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	// 1 node (16 B) + 1 comment fact (24 B) = 40 B total; 64 B budget is well below 16 * 24 = 384 B.
	doc, err := json.build(transmute([]u8)string("// hi\n1"), .Jsonc, {budget = {memory = 64}})
	defer tape.destroy(&doc)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(doc.nodes), 1)
	testing.expect_value(t, len(doc.facts), 1)

	// 20 comments (480 B) + initial node room (7 * 16 = 112 B) = 592 B; 640 B budget is well below doubling to 32 facts
	// (112 + 32 * 24 = 880 B) and forces backoff down to what fits.
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 20 {
		fmt.sbprintf(&b, "// c%d\n", i)
	}
	strings.write_string(&b, "1")
	doc2, err2 := json.build(transmute([]u8)strings.to_string(b), .Jsonc, {budget = {memory = 640}})
	defer tape.destroy(&doc2)
	testing.expect_value(t, err2, nil)
	testing.expect_value(t, len(doc2.nodes), 1)
	testing.expect_value(t, len(doc2.facts), 20)
}

// Deep nesting past `FRAME_DEPTH` routes `Builder.stack` through `Options.scratch`, reducing peak memory taken from the
// document's arena against the opt-out (the arena itself as `scratch`), and respects `Budget.memory` without speculative `doc.nodes` doubling.
@(test)
deep_build_uses_scratch_and_tight_budget :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	DEPTH :: 1200
	src := transmute([]u8)strings.concatenate({strings.repeat("[", DEPTH, context.temp_allocator), strings.repeat("]", DEPTH, context.temp_allocator)}, context.temp_allocator)
	buf_no_scratch := make([]u8, 128 * 1024)
	defer delete(buf_no_scratch)
	arena_no_scratch: mem.Arena
	mem.arena_init(&arena_no_scratch, buf_no_scratch)
	doc0, err0 := json.build(src, .Json, {budget = {depth = DEPTH}, scratch = mem.arena_allocator(&arena_no_scratch)}, mem.arena_allocator(&arena_no_scratch))
	testing.expect_value(t, err0, nil)
	testing.expect_value(t, len(doc0.nodes), DEPTH)

	main_buf := make([]u8, 128 * 1024)
	defer delete(main_buf)
	scratch_buf := make([]u8, 64 * 1024)
	defer delete(scratch_buf)
	main_arena, scratch_arena: mem.Arena
	mem.arena_init(&main_arena, main_buf)
	mem.arena_init(&scratch_arena, scratch_buf)
	doc, err := json.build(src, .Json, {budget = {depth = DEPTH}, scratch = mem.arena_allocator(&scratch_arena)}, mem.arena_allocator(&main_arena))
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(doc.nodes), DEPTH)
	testing.expect(t, scratch_arena.offset >= DEPTH * size_of(u64))
	testing.expectf(t, main_arena.offset < arena_no_scratch.offset, "main=%d, without_scratch=%d", main_arena.offset, arena_no_scratch.offset)

	// Also succeeds under a tight shared budget where speculative node doubling would fail.
	doc2, err2 := json.build(src, .Json, {budget = {depth = DEPTH, memory = 64 * 1024}})
	defer tape.destroy(&doc2)
	testing.expect_value(t, err2, nil)
	testing.expect_value(t, len(doc2.nodes), DEPTH)
}

// Both builds and scans that grow past `tape.MAX_CHILDREN` succeed on a tight bump arena: `counts` does not land after
// `doc.nodes` and block in-place node room growth, whether using default scratch or sharing the arena as scratch, and
// whether budgeted or unbudgeted.
@(test)
arena_build_and_scan_grow_past_max_children :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	n_elems := int(tape.MAX_CHILDREN) + 5000
	src := transmute([]u8)strings.concatenate({"[", strings.repeat("1,", n_elems - 1, context.temp_allocator), "1]"}, context.temp_allocator)
	ref, rerr := json.build(src)
	defer tape.destroy(&ref)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, len(ref.nodes), n_elems + 1)
	testing.expect_value(t, len(ref.counts), 1)
	testing.expect_value(t, ref.counts[0].count, u32(n_elems))

	need := len(ref.nodes) * size_of(tape.Node) + 1024
	backing := make([]u8, need)
	defer delete(backing)

	// Budgeted build on a tight bump arena (default scratch and shared arena scratch).
	for share_scratch in ([2]bool{false, true}) {
		arena: mem.Arena
		mem.arena_init(&arena, backing)
		a := mem.arena_allocator(&arena)
		opts := json.Options{budget = {memory = u64(need)}}
		if share_scratch {
			opts.scratch = a
		}
		doc, err := json.build(src, .Json, opts, a)
		testing.expectf(t, err == nil, "budgeted build (share=%v): %v (offset=%d/%d)", share_scratch, err, arena.offset, need)
		testing.expect_value(t, len(doc.nodes), n_elems + 1)
		testing.expect_value(t, len(doc.counts), 1)
		if len(doc.counts) == 1 {
			testing.expect_value(t, doc.counts[0].count, u32(n_elems))
		}
	}

	// Unbudgeted and budgeted scans keeping > MAX_CHILDREN nodes on a tight bump arena.
	d, derr := tape.demand_of({{}})
	defer tape.destroy(&d)
	testing.expect_value(t, derr, nil)
	for share_scratch in ([2]bool{false, true}) {
		for budget in ([2]u64{0, u64(need)}) {
			arena: mem.Arena
			mem.arena_init(&arena, backing)
			a := mem.arena_allocator(&arena)
			opts := json.Options{budget = {memory = budget}}
			if share_scratch {
				opts.scratch = a
			}
			doc, err := json.scan(src, &d, .Json, opts = opts, allocator = a)
			testing.expectf(t, err == nil, "scan (share=%v, budget=%d): %v (offset=%d/%d)", share_scratch, budget, err, arena.offset, need)
			testing.expect_value(t, len(doc.nodes), n_elems + 1)
			testing.expect_value(t, len(doc.counts), 1)
			if len(doc.counts) == 1 {
				testing.expect_value(t, doc.counts[0].count, u32(n_elems))
			}
		}
	}

	// Budgeted scan sharing `context.allocator` as scratch verifies `counts` handoff has zero leaks or mismatched frees.
	{
		doc, err := json.scan(src, &d, .Json, opts = {budget = {memory = u64(need)}, scratch = context.allocator}, allocator = context.allocator)
		defer tape.destroy(&doc)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, len(doc.nodes), n_elems + 1)
		testing.expect_value(t, len(doc.counts), 1)
		if len(doc.counts) == 1 {
			testing.expect_value(t, doc.counts[0].count, u32(n_elems))
		}
	}
}

// A scan of 70 elements that passes at a memory budget must pass at every larger memory budget (including 1400, 1600,
// and 2100 bytes), and list growth backs off under tight budgets instead of refusing above what the scan needs.
@(test)
scan_memory_budgets_are_monotonic_across_demands :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for i in 0 ..< 70 {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		fmt.sbprintf(&b, "%d", i)
	}
	strings.write_byte(&b, ']')
	src := transmute([]u8)strings.to_string(b)

	cases := [?]struct {
		steps:  []tape.Step,
		max_ok: u64,
	}{
		{{}, 1400},
		{{tape.All{}}, 4000},
		{{tape.Index(-3)}, 1400},
		{{tape.Slice{-5, nil, 0}}, 1400},
		{{tape.Slice{0, nil, 0}}, 5400},
		{{tape.Descend{}, tape.Name("a")}, 1400},
	}

	for c in cases {
		d, derr := tape.demand_of({c.steps})
		defer tape.destroy(&d)
		testing.expect_value(t, derr, nil)

		first_ok := u64(0)
		// Sweep coarsely across 100..6000 plus every 1-byte step across 1200..2200 (covering 1400, 1600, 2100).
		for memory := u64(100); memory <= 6000; {
			r, err := json.scan(src, &d, opts = {budget = {memory = memory}})
			tape.destroy(&r)
			if err == nil {
				if first_ok == 0 {
					first_ok = memory
				}
			} else if first_ok != 0 {
				testing.expectf(t, false, "%v: fit %d bytes but refused at %d bytes (%v)", c.steps, first_ok, memory, err)
				break
			}
			if memory >= 1200 && memory < 2200 {
				memory += 1
			} else {
				memory += 20
			}
		}
		testing.expectf(t, first_ok > 0 && first_ok <= c.max_ok, "%v: first_ok=%d exceeds %d", c.steps, first_ok, c.max_ok)
	}
}
