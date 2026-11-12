package json_tests

import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import diff "../../core/diff"
import write "../../core/write"
import json ".."

// The value diff over JSON and JSONC documents: objects, the four ways arrays match, numbers, facts and a longer
// sequence against a brute-force one.

@(private = "file")
build_text :: proc(t: ^testing.T, text: string, spec := json.Spec.Json) -> (doc: core.Document, ok: bool) {
	err: core.Error
	doc, err = core.build(transmute([]u8)text, json.as(spec))
	return doc, testing.expectf(t, err == nil, "%s: %v", text, err)
}

@(private = "file")
step_text :: proc(sb: ^strings.Builder, steps: []core.Step) {
	for s in steps {
		switch v in s {
		case core.Name:
			fmt.sbprintf(sb, ".%s", string(v))
		case core.Index:
			fmt.sbprintf(sb, "[%d]", int(v))
		case core.All, core.Slice, core.Descend, core.Index_Or_Name:
			strings.write_string(sb, "?")
		}
	}
}

@(private = "file")
value_text :: proc(v: core.Value) -> string {
	if s, is_text := v.(string); is_text {
		return s
	}
	text, _ := write.write_value(v, json.as(.Json), allocator = context.temp_allocator)
	return string(text)
}

// One line per change: the operator, the path, then the old and new values.
@(private = "file")
render :: proc(r: diff.Result) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for c, i in r.changes {
		if i > 0 {
			strings.write_byte(&sb, ';')
		}
		switch c.op {
		case .Added:
			strings.write_byte(&sb, '+')
		case .Removed:
			strings.write_byte(&sb, '-')
		case .Changed:
			strings.write_byte(&sb, '~')
		case .Fact:
			strings.write_byte(&sb, '#')
		}
		step_text(&sb, c.path)
		if c.op != .Added {
			strings.write_string(&sb, " ")
			strings.write_string(&sb, value_text(c.old))
		}
		if c.op != .Removed {
			strings.write_string(&sb, " > ")
			strings.write_string(&sb, value_text(c.new))
		}
	}
	return strings.to_string(sb)
}

@(private = "file")
expect_diff :: proc(t: ^testing.T, old, new, want: string, opts := diff.Options{}, spec := json.Spec.Json) -> bool {
	a, a_ok := build_text(t, old, spec)
	defer core.destroy(&a)
	b, b_ok := build_text(t, new, spec)
	defer core.destroy(&b)
	if !a_ok || !b_ok {
		return false
	}
	r, _ := diff.values(core.Node_Ref{&a, core.ROOT}, core.Node_Ref{&b, core.ROOT}, opts)
	defer diff.result_destroy(&r)
	defer free_all(context.temp_allocator)
	return testing.expectf(t, render(r) == want, "%s against %s: got %q, want %q", old, new, render(r), want)
}

@(test)
diff_objects :: proc(t: ^testing.T) {
	expect_diff(t, `{"a":1,"b":2,"c":3}`, `{"b":2,"a":5,"d":4}`, `~.a 1 > 5;-.c 3;+.d > 4`)
	expect_diff(t, `{"a":{"x":[1]}}`, `{"a":{"x":[1]}}`, ``)
	expect_diff(t, `{"a":{"x":[1,2]}}`, `{"a":{"x":[1,3]}}`, `~.a.x[1] 2 > 3`)
}

@(test)
diff_kinds_and_numbers :: proc(t: ^testing.T) {
	expect_diff(t, `1`, `"1"`, `~ 1 > "1"`)
	expect_diff(t, `[1.0,1e2]`, `[1,100]`, ``)
	expect_diff(t, `{"a":null}`, `{"a":[]}`, `~.a null > []`)
	a, ok := build_text(t, `{"a":null}`)
	defer core.destroy(&a)
	b, b_ok := build_text(t, `{"a":false}`)
	defer core.destroy(&b)
	if !ok || !b_ok {
		return
	}
	r, _ := diff.values(core.Node_Ref{&a, core.ROOT}, core.Node_Ref{&b, core.ROOT})
	defer diff.result_destroy(&r)
	testing.expect(t, len(r.changes) == 1 && r.changes[0].kind_changed)
}

@(test)
diff_array_modes :: proc(t: ^testing.T) {
	expect_diff(t, `[1,2,3,4]`, `[1,3,4,5]`, `-[1] 2;+[3] > 5`)
	expect_diff(t, `[1,2,3]`, `[1,9,3]`, `~[1] 2 > 9`)
	expect_diff(t, `[3,1,2]`, `[1,2,3]`, `-[0] 3;+[2] > 3`)
	expect_diff(t, `[3,1,2]`, `[1,2,3]`, ``, {arrays = .Set})
	expect_diff(t, `[1,1,2]`, `[1,2,2]`, `+[2] > 2;-[1] 1`, {arrays = .Set})
	expect_diff(t, `[1,2,3]`, `[2,3]`, `~[0] 1 > 2;~[1] 2 > 3;-[2] 3`, {arrays = .Position})
}

@(test)
diff_keyed_arrays :: proc(t: ^testing.T) {
	old := `[{"id":1,"v":"a"},{"id":2,"v":"b"},{"id":3,"v":"c"}]`
	new := `[{"id":3,"v":"c"},{"id":2,"v":"B"},{"id":4,"v":"d"}]`
	keys := []diff.Key_Rule{{member = "id"}}
	expect_diff(t, old, new, `~[1].v "b" > "B";+[2] > {"id":4,"v":"d"};-[0] {"id":1,"v":"a"}`, {keys = keys})
	nested := []diff.Key_Rule{{at = {core.Name("rows")}, member = "id"}}
	expect_diff(t, `{"rows":[{"id":1,"v":1},{"id":2,"v":2}]}`, `{"rows":[{"id":2,"v":3},{"id":1,"v":1}]}`, `~.rows[0].v 2 > 3`, {keys = nested})
}

// Facts count only where both formats carry them: strict JSON has no comments, so a JSONC document against a JSON one
// differs by its values alone.
@(test)
diff_facts :: proc(t: ^testing.T) {
	expect_diff(t, `{"a":1 /*x*/}`, `{"a":1 /*y*/}`, `#.a x > y`, {facts = true}, .Jsonc)
	expect_diff(t, `{"a":1 /*x*/}`, `{"a":1 /*x*/}`, ``, {facts = true}, .Jsonc)
	expect_diff(t, `{"a":1 /*x*/}`, `{"a":1 /*y*/}`, ``, {}, .Jsonc)
	jsonc, ok := build_text(t, `{"a":1 /*x*/}`, .Jsonc)
	defer core.destroy(&jsonc)
	strict, s_ok := build_text(t, `{"a":1}`)
	defer core.destroy(&strict)
	if !ok || !s_ok {
		return
	}
	r, _ := diff.values(core.Node_Ref{&jsonc, core.ROOT}, core.Node_Ref{&strict, core.ROOT}, {facts = true})
	defer diff.result_destroy(&r)
	testing.expectf(t, len(r.changes) == 0, "a comment the other format cannot hold is a change: %v", render(r))
}

// An attribute fact no JSON reader produces, made by hand: a reader that takes the fact's span as `a=1`.
@(private = "file")
hand_attribute :: proc "contextless" (doc: ^core.Document, f: core.Fact) -> (name, value: core.Token) {
	return {lo = f.lo, n = 1, kind = .String, role = .Key}, {lo = f.lo + 2, n = u32(f.n - 2), kind = .String}
}

@(test)
diff_attribute_facts :: proc(t: ^testing.T) {
	a, a_ok := build_text(t, `{"k":"a=1"}`)
	defer core.destroy(&a)
	b, b_ok := build_text(t, `{"k":"a=2"}`)
	defer core.destroy(&b)
	c, c_ok := build_text(t, `{"k":"a=1"}`)
	defer core.destroy(&c)
	if !a_ok || !b_ok || !c_ok {
		return
	}
	original := a.readers
	readers := original^
	readers.attribute = hand_attribute
	facts := [1]core.Fact{{lo = 6, node = core.ROOT, n = 3, role = .Attribute, kind = .Plain}}
	for doc in ([]^core.Document{&a, &b, &c}) {
		doc.readers = &readers
		doc.facts = facts[:]
	}
	same, _ := diff.values(core.Node_Ref{&a, core.ROOT}, core.Node_Ref{&c, core.ROOT}, {facts = true})
	defer diff.result_destroy(&same)
	testing.expectf(t, len(same.changes) == 0, "equal attributes differ: %v", render(same))
	r, _ := diff.values(core.Node_Ref{&a, core.ROOT}, core.Node_Ref{&b, core.ROOT}, {facts = true})
	defer diff.result_destroy(&r)
	testing.expectf(t, render(r) == `# a=1 > a=2;~.k "a=1" > "a=2"`, "got %v", render(r))
	for doc in ([]^core.Document{&a, &b, &c}) {
		doc.readers, doc.facts = original, nil
	}
}

@(private = "file")
lcs_length :: proc(xs, ys: []int) -> int {
	row := make([]int, len(ys) + 1, context.temp_allocator)
	for x in xs {
		diag := 0
		for y, j in ys {
			above := row[j + 1]
			row[j + 1] = diag + 1 if x == y else max(row[j + 1], row[j])
			diag = above
		}
	}
	return row[len(ys)]
}

@(private = "file")
array_text :: proc(xs: []int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '[')
	for x, i in xs {
		if i > 0 {
			strings.write_byte(&sb, ',')
		}
		fmt.sbprintf(&sb, "%d", x)
	}
	strings.write_byte(&sb, ']')
	return strings.to_string(sb)
}

// The edits of two sequences of scalars are as many as the brute-force longest common subsequence leaves out.
@(test)
diff_sequence_is_minimal :: proc(t: ^testing.T) {
	r := rand.create(0x5d1ff)
	context.random_generator = rand.default_random_generator(&r)
	for _ in 0 ..< 400 {
		xs := make([]int, rand.int_max(24), context.temp_allocator)
		ys := make([]int, rand.int_max(24), context.temp_allocator)
		alphabet := 2 + rand.int_max(5)
		for &x in xs {
			x = rand.int_max(alphabet)
		}
		for &y in ys {
			y = rand.int_max(alphabet)
		}
		a, a_ok := build_text(t, array_text(xs))
		b, b_ok := build_text(t, array_text(ys))
		if !a_ok || !b_ok {
			return
		}
		res, _ := diff.values(core.Node_Ref{&a, core.ROOT}, core.Node_Ref{&b, core.ROOT})
		removed, added := 0, 0
		for c in res.changes {
			switch c.op {
			case .Removed:
				removed += 1
			case .Added:
				added += 1
			case .Changed:
				removed, added = removed + 1, added + 1
			case .Fact:
			}
		}
		keep := lcs_length(xs, ys)
		ok := testing.expectf(t, removed == len(xs) - keep && added == len(ys) - keep, "%s against %s: removed %d added %d, want %d and %d", array_text(xs), array_text(ys), removed, added, len(xs) - keep, len(ys) - keep)
		diff.result_destroy(&res)
		core.destroy(&a)
		core.destroy(&b)
		free_all(context.temp_allocator)
		if !ok {
			return
		}
	}
}

// Arrays too different for the edit cap are one change, and the result says so.
@(test)
diff_edit_cap :: proc(t: ^testing.T) {
	a, a_ok := build_text(t, `[1,2,3,4,5,6]`)
	defer core.destroy(&a)
	b, b_ok := build_text(t, `[7,8,9,10,11,12]`)
	defer core.destroy(&b)
	if !a_ok || !b_ok {
		return
	}
	r, _ := diff.values(core.Node_Ref{&a, core.ROOT}, core.Node_Ref{&b, core.ROOT}, {max_edits = 4})
	defer diff.result_destroy(&r)
	testing.expectf(t, r.truncated && len(r.changes) == 1 && r.changes[0].op == .Changed, "got %v", render(r))
}

// A long array with scattered changes is diffed in one pass, and every change is found.
@(test)
diff_long_arrays :: proc(t: ^testing.T) {
	n := 100_000
	xs := make([]int, n, context.temp_allocator)
	ys := make([]int, n, context.temp_allocator)
	for i in 0 ..< n {
		xs[i], ys[i] = i, i
	}
	for i := 7; i < n; i += 1009 {
		ys[i] = -1 - i
	}
	a, a_ok := build_text(t, array_text(xs))
	defer core.destroy(&a)
	b, b_ok := build_text(t, array_text(ys))
	defer core.destroy(&b)
	if !a_ok || !b_ok {
		return
	}
	r, _ := diff.values(core.Node_Ref{&a, core.ROOT}, core.Node_Ref{&b, core.ROOT})
	defer diff.result_destroy(&r)
	testing.expectf(t, !r.truncated && len(r.changes) == (n - 7 + 1008) / 1009, "%d changes", len(r.changes))
	free_all(context.temp_allocator)
}

// The law of the diff: the changes of diff(a, b) applied to a give b. The values are random, and b is a that was edited
// by inserting, deleting and moving elements of arrays, adding and removing members and changing scalars, so the
// arrays include long ones with blocks that moved.

@(private = "file")
Gen :: struct {
	kind:  int, // 0 null, 1 integer, 2 string, 3 array, 4 object
	n:     int,
	items: [dynamic]^Gen,
	keys:  [dynamic]string,
}

@(private = "file")
GEN_KEYS := [?]string{"a", "b", "c", "d", "e", "f"}

@(private = "file")
gen_scalar :: proc(r: rand.Generator) -> ^Gen {
	context.allocator = context.temp_allocator
	g := new(Gen, context.temp_allocator)
	g.kind = rand.int_max(3, r)
	g.n = rand.int_max(6, r)
	return g
}

@(private = "file")
gen_value :: proc(r: rand.Generator, depth: int) -> ^Gen {
	context.allocator = context.temp_allocator
	if depth >= 3 || rand.int_max(3, r) == 0 {
		return gen_scalar(r)
	}
	g := new(Gen, context.temp_allocator)
	if rand.int_max(2, r) == 0 {
		g.kind = 3
		count := rand.int_max(7, r)
		if rand.int_max(8, r) == 0 {
			count = 150 + rand.int_max(400, r)
		}
		for i in 0 ..< count {
			if g.n == 0 && rand.int_max(5, r) > 0 {
				e := new(Gen, context.temp_allocator)
				e.kind, e.n = 1, i
				append(&g.items, e)
			} else {
				append(&g.items, gen_value(r, depth + 1))
			}
		}
	} else {
		g.kind = 4
		for key in GEN_KEYS {
			if rand.int_max(2, r) == 0 {
				append(&g.keys, key)
				append(&g.items, gen_value(r, depth + 1))
			}
		}
	}
	return g
}

@(private = "file")
gen_clone :: proc(g: ^Gen) -> ^Gen {
	context.allocator = context.temp_allocator
	c := new(Gen, context.temp_allocator)
	c^ = g^
	c.items = make([dynamic]^Gen, context.temp_allocator)
	c.keys = make([dynamic]string, context.temp_allocator)
	for it in g.items {
		append(&c.items, gen_clone(it))
	}
	append(&c.keys, ..g.keys[:])
	return c
}

@(private = "file")
gen_edit :: proc(g: ^Gen, r: rand.Generator) {
	context.allocator = context.temp_allocator
	switch g.kind {
	case 0, 1, 2:
		g.n += 1 + rand.int_max(3, r)
		if rand.int_max(4, r) == 0 {
			g.kind = rand.int_max(3, r)
		}
	case 3:
		for _ in 0 ..< 1 + rand.int_max(3, r) {
			n := len(g.items)
			switch rand.int_max(5, r) {
			case 0:
				at := rand.int_max(n + 1, r)
				inject_at(&g.items, at, gen_scalar(r))
			case 1:
				if n > 0 {
					ordered_remove(&g.items, rand.int_max(n, r))
				}
			case 2:
				if n > 3 {
					lo := rand.int_max(n - 1, r)
					hi := lo + 1 + rand.int_max(min(n - lo, 80), r)
					block := make([dynamic]^Gen, context.temp_allocator)
					append(&block, ..g.items[lo:hi])
					remove_range(&g.items, lo, hi)
					at := rand.int_max(len(g.items) + 1, r)
					inject_at(&g.items, at, ..block[:])
				}
			case:
				if n > 0 {
					gen_edit(g.items[rand.int_max(n, r)], r)
				}
			}
		}
	case 4:
		switch rand.int_max(3, r) {
		case 0:
			key := GEN_KEYS[rand.int_max(len(GEN_KEYS), r)]
			if !slice.contains(g.keys[:], key) {
				append(&g.keys, key)
				append(&g.items, gen_scalar(r))
			}
		case 1:
			if len(g.keys) > 0 {
				i := rand.int_max(len(g.keys), r)
				ordered_remove(&g.keys, i)
				ordered_remove(&g.items, i)
			}
		case:
			if len(g.items) > 0 {
				gen_edit(g.items[rand.int_max(len(g.items), r)], r)
			}
		}
	}
}

@(private = "file")
gen_write :: proc(sb: ^strings.Builder, g: ^Gen) {
	switch g.kind {
	case 0:
		strings.write_string(sb, "null")
	case 1:
		fmt.sbprintf(sb, "%d", g.n)
	case 2:
		fmt.sbprintf(sb, `"s%d"`, g.n)
	case 3:
		strings.write_byte(sb, '[')
		for it, i in g.items {
			if i > 0 {
				strings.write_byte(sb, ',')
			}
			gen_write(sb, it)
		}
		strings.write_byte(sb, ']')
	case 4:
		strings.write_byte(sb, '{')
		for it, i in g.items {
			if i > 0 {
				strings.write_byte(sb, ',')
			}
			fmt.sbprintf(sb, `"%s":`, g.keys[i])
			gen_write(sb, it)
		}
		strings.write_byte(sb, '}')
	}
}

@(private = "file")
step_equal :: proc(a, b: core.Step) -> bool {
	#partial switch x in a {
	case core.Name:
		y, ok := b.(core.Name)
		return ok && x == y
	case core.Index:
		y, ok := b.(core.Index)
		return ok && x == y
	}
	return false
}

// Whether `path` is `prefix` followed by `last`, or `prefix` alone when `last` is nil.
@(private = "file")
path_is :: proc(path, prefix: []core.Step, last: Maybe(core.Step) = nil) -> bool {
	extra := 0 if last == nil else 1
	if len(path) != len(prefix) + extra {
		return false
	}
	for s, i in prefix {
		if !step_equal(path[i], s) {
			return false
		}
	}
	return last == nil || step_equal(path[len(prefix)], last.?)
}

@(private = "file")
removed_at :: proc(changes: []diff.Change, old_prefix: []core.Step, last: core.Step) -> bool {
	for c in changes {
		if c.op == .Removed && path_is(c.old_path, old_prefix, last) {
			return true
		}
	}
	return false
}

// The value `old` at `old_at` turned by `changes` into the value at `new_at`: a change at the place replaces it, the
// members and elements of a container are those that stay, in order, and those added.
@(private = "file")
apply_changes :: proc(changes: []diff.Change, old: core.Value, new_at, old_at: ^[dynamic]core.Step) -> core.Value {
	context.allocator = context.temp_allocator
	for c in changes {
		if (c.op == .Added || c.op == .Changed) && path_is(c.path, new_at[:]) {
			return c.new
		}
	}
	#partial switch core.kind(old) {
	case .Object:
		out := new(core.Object, context.temp_allocator)
		it := core.pairs(old)
		for k, v in core.pair_next(&it) {
			if removed_at(changes, old_at[:], core.Name(k)) {
				continue
			}
			append(new_at, core.Name(k))
			append(old_at, core.Name(k))
			append(&out.keys, k)
			append(&out.vals, apply_changes(changes, v, new_at, old_at))
			pop(new_at)
			pop(old_at)
		}
		for c in changes {
			if c.op == .Added && len(c.path) == len(new_at) + 1 && path_is(c.path[:len(new_at)], new_at[:]) {
				if name, named := c.path[len(new_at)].(core.Name); named {
					append(&out.keys, string(name))
					append(&out.vals, c.new)
				}
			}
		}
		return out
	case .Array:
		out := new(core.Array, context.temp_allocator)
		survivors := 0
		for j in 0 ..< core.length(old) {
			if !removed_at(changes, old_at[:], core.Index(j)) {
				survivors += 1
			}
		}
		added := 0
		for c in changes {
			if c.op == .Added && len(c.path) == len(new_at) + 1 && path_is(c.path[:len(new_at)], new_at[:]) {
				if _, indexed := c.path[len(new_at)].(core.Index); indexed {
					added += 1
				}
			}
		}
		j := 0
		for i in 0 ..< survivors + added {
			append(new_at, core.Index(i))
			defer pop(new_at)
			put := false
			for c in changes {
				if c.op == .Added && path_is(c.path, new_at[:]) {
					append(&out.items, c.new)
					put = true
					break
				}
			}
			if put {
				continue
			}
			for removed_at(changes, old_at[:], core.Index(j)) {
				j += 1
			}
			v, _ := core.child_at(old, j)
			append(old_at, core.Index(j))
			append(&out.items, apply_changes(changes, v, new_at, old_at))
			pop(old_at)
			j += 1
		}
		return out
	}
	return old
}

@(test)
diff_changes_turn_a_into_b :: proc(t: ^testing.T) {
	for seed in 0 ..< 400 {
		state := rand.create(u64(seed) + 1)
		r := rand.default_random_generator(&state)
		a := gen_value(r, 0)
		b := gen_clone(a)
		for _ in 0 ..< 1 + rand.int_max(3, r) {
			gen_edit(b, r)
		}
		if seed % 5 == 0 {
			b = gen_value(r, 0)
		}
		sa, sb := strings.builder_make(context.temp_allocator), strings.builder_make(context.temp_allocator)
		gen_write(&sa, a)
		gen_write(&sb, b)
		doc_a, a_ok := build_text(t, strings.to_string(sa))
		defer core.destroy(&doc_a)
		doc_b, b_ok := build_text(t, strings.to_string(sb))
		defer core.destroy(&doc_b)
		if !a_ok || !b_ok {
			return
		}
		for arrays in ([?]diff.Arrays{.Sequence, .Position}) {
			res, _ := diff.values(core.Node_Ref{&doc_a, core.ROOT}, core.Node_Ref{&doc_b, core.ROOT}, {arrays = arrays})
			defer diff.result_destroy(&res)
			new_at, old_at := make([dynamic]core.Step, context.temp_allocator), make([dynamic]core.Step, context.temp_allocator)
			got := apply_changes(res.changes, core.Node_Ref{&doc_a, core.ROOT}, &new_at, &old_at)
			if !testing.expectf(t, res.truncated || core.equal(got, core.Node_Ref{&doc_b, core.ROOT}), "seed %d %v: %s -> %s gives %s", seed, arrays, strings.to_string(sa), strings.to_string(sb), value_text(got)) {
				return
			}
		}
		free_all(context.temp_allocator)
	}
}

// Under a key an element pairs with the one of its id wherever it stands, so a change inside it is told at the new index
// and `old_path` places it in the old value: the changes applied through `old_path` give the new value back.
@(test)
diff_keyed_changes_turn_a_into_b :: proc(t: ^testing.T) {
	keys := []diff.Key_Rule{{at = {core.Name("xs")}, member = "id"}}
	for seed in 0 ..< 200 {
		state := rand.create(u64(seed) + 7)
		r := rand.default_random_generator(&state)
		sa, sb := strings.builder_make(context.temp_allocator), strings.builder_make(context.temp_allocator)
		strings.write_string(&sa, `{"xs":[`)
		strings.write_string(&sb, `{"xs":[`)
		next_id, wrote := 100, 0
		for id in 0 ..< 1 + rand.int_max(14, r) {
			v := rand.int_max(5, r)
			fmt.sbprintf(&sa, `%s{{"id":%d,"v":%d}`, "," if id > 0 else "", id, v)
			if rand.int_max(4, r) == 0 {
				continue
			}
			if rand.int_max(4, r) == 0 {
				fmt.sbprintf(&sb, `%s{{"id":%d,"v":0}`, "," if wrote > 0 else "", next_id)
				next_id, wrote = next_id + 1, wrote + 1
			}
			fmt.sbprintf(&sb, `%s{{"id":%d,"v":%d}`, "," if wrote > 0 else "", id, v + int(rand.int_max(3, r) == 0))
			wrote += 1
		}
		strings.write_string(&sa, "]}")
		strings.write_string(&sb, "]}")
		doc_a, a_ok := build_text(t, strings.to_string(sa))
		defer core.destroy(&doc_a)
		doc_b, b_ok := build_text(t, strings.to_string(sb))
		defer core.destroy(&doc_b)
		if !a_ok || !b_ok {
			return
		}
		res, _ := diff.values(core.Node_Ref{&doc_a, core.ROOT}, core.Node_Ref{&doc_b, core.ROOT}, {keys = keys})
		defer diff.result_destroy(&res)
		new_at, old_at := make([dynamic]core.Step, context.temp_allocator), make([dynamic]core.Step, context.temp_allocator)
		got := apply_changes(res.changes, core.Node_Ref{&doc_a, core.ROOT}, &new_at, &old_at)
		if !testing.expectf(t, core.equal(got, core.Node_Ref{&doc_b, core.ROOT}), "seed %d: %s -> %s gives %s", seed, strings.to_string(sa), strings.to_string(sb), value_text(got)) {
			return
		}
		free_all(context.temp_allocator)
	}
}

// Many arrays that each need a long search together stop at the work the diff may spend and report the rest as
// replaced: the first arrays are matched element by element, and every array past the one the work ran out in is one
// change, so the search ends after a bounded number of arrays whatever their count.
@(test)
diff_work_is_bounded_across_arrays :: proc(t: ^testing.T) {
	sa, sb := strings.builder_make(context.temp_allocator), strings.builder_make(context.temp_allocator)
	strings.write_byte(&sa, '[')
	strings.write_byte(&sb, '[')
	for k in 0 ..< 120 {
		for part, i in ([2]^strings.Builder{&sa, &sb}) {
			if k > 0 {
				strings.write_byte(part, ',')
			}
			strings.write_byte(part, '[')
			for j in 0 ..< 2000 {
				if j > 0 {
					strings.write_byte(part, ',')
				}
				fmt.sbprintf(part, "%d", j * 2 + i)
			}
			strings.write_byte(part, ']')
		}
	}
	strings.write_byte(&sa, ']')
	strings.write_byte(&sb, ']')
	a, a_ok := build_text(t, strings.to_string(sa))
	defer core.destroy(&a)
	b, b_ok := build_text(t, strings.to_string(sb))
	defer core.destroy(&b)
	if !a_ok || !b_ok {
		return
	}
	r, _ := diff.values(core.Node_Ref{&a, core.ROOT}, core.Node_Ref{&b, core.ROOT})
	defer diff.result_destroy(&r)
	matched, replaced := 0, 0
	for c in r.changes {
		if len(c.path) == 1 {
			replaced += 1
		} else if c.path[1] == core.Index(0) {
			matched += 1
		}
	}
	testing.expectf(t, r.truncated && matched > 0 && matched + replaced == 120 && replaced > matched, "truncated %v, %d arrays matched, %d replaced", r.truncated, matched, replaced)
	free_all(context.temp_allocator)
}
