package tape_test

import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"

// The elements of an array of `count` the slice `s` takes, by the definition the rule gives: from `lo` up to `hi`, each
// counted from the end when negative and held to the array, and the first `limit` of them.
slice_elements :: proc(s: tape.Slice, count: int) -> (taken: [dynamic]int) {
	taken.allocator = context.temp_allocator
	from := int(s.lo) + count if s.lo < 0 else int(s.lo)
	from = max(from, 0)
	to := count
	if hi, bounded := s.hi.?; bounded {
		to = int(hi) + count if hi < 0 else min(int(hi), count)
	}
	for e in from ..< to {
		if s.limit > 0 && len(taken) == int(s.limit) {
			break
		}
		append(&taken, e)
	}
	return
}

slices :: proc() -> (all: [dynamic]tape.Slice) {
	all.allocator = context.temp_allocator
	for lo in -4 ..= 4 {
		for hi in -4 ..= 5 {
			for limit in 0 ..= 3 {
				append(&all, tape.Slice{i32(lo), nil if hi == 5 else Maybe(i32)(i32(hi)), i32(limit)})
			}
		}
	}
	return
}

// `slice_takes` over a known count takes the elements the definition gives, and over an unknown one takes each element
// some array of more elements takes, and no other unless its end counts from the end.
@(test)
slice_takes_what_the_definition_gives :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for s in slices() {
		for count in 1 ..= 9 {
			taken := slice_elements(s, count)
			for e in 0 ..< 10 {
				want := false
				for k in taken {
					want ||= k == e
				}
				testing.expectf(t, tape.slice_takes(s, u64(e), u64(count)) == want, "%v of %d elements, element %d: %v", s, count, e, !want)
			}
		}
		for e in 0 ..< 10 {
			possible := false
			for count in e + 1 ..= e + 20 {
				for k in slice_elements(s, count) {
					possible ||= k == e
				}
			}
			// An end counted from the end may take any element once the array is long enough, which the rule allows
			// whatever the arrays are, so only a slice with no such end is exact.
			hi, bounded := s.hi.?
			takes := tape.slice_takes(s, u64(e), 0)
			testing.expectf(t, takes || !possible, "%v of an unknown count, element %d: not taken", s, e)
			testing.expectf(t, takes == possible || bounded && hi < 0, "%v of an unknown count, element %d: %v", s, e, takes)
		}
	}
}

// `slice_cut` is `max(u64)` for a slice counted from the end, and else the index past the last element any array
// gives, the one past the slice's last element when it takes any.
@(test)
slice_cuts_past_its_last_element :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for s in slices() {
		cut := tape.slice_cut(s)
		hi, bounded := s.hi.?
		if s.lo < 0 || bounded && hi < 0 {
			testing.expectf(t, cut == max(u64), "%v: %d", s, cut)
			continue
		}
		last := -1
		for e in 0 ..< 64 {
			for k in slice_elements(s, 200) {
				if k == e {
					last = e
				}
			}
		}
		for e in int(min(cut, 64)) ..< 64 {
			testing.expectf(t, !tape.slice_takes(s, u64(e), 0), "%v cut at %d takes %d", s, cut, e)
		}
		if last >= 0 && last < 63 {
			testing.expectf(t, cut == u64(last + 1), "%v takes up to %d, cut at %d", s, last, cut)
		}
		if last == 63 {
			testing.expectf(t, cut == max(u64), "%v takes every element, cut at %d", s, cut)
		}
	}
}

@(test)
step_reach_counts_back_from_the_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	N :: tape.Name
	cases := [?]struct {
		step:  tape.Step,
		reach: u64,
	}{{N("a"), 0}, {tape.All{}, 0}, {tape.Index(0), 0}, {tape.Index(5), 0}, {tape.Index(-1), 1}, {tape.Index(-7), 7}, {tape.Slice{0, nil, 0}, 0}, {tape.Slice{2, 5, 0}, 0}, {tape.Slice{-3, nil, 0}, 3}, {tape.Slice{1, -2, 0}, 2}, {tape.Slice{-3, -5, 0}, 5}, {tape.Slice{-5, -3, 0}, 5}, {tape.Slice{-1, 4, 2}, 1}}
	for c in cases {
		testing.expectf(t, tape.step_reach(c.step) == c.reach, "%v: %d", c.step, tape.step_reach(c.step))
	}
}

@(test)
steps_enter_the_values_they_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for kind in tape.Kind.Null ..= tape.Kind.Object {
		array, object := kind == .Array, kind == .Object
		testing.expect_value(t, tape.step_enters(tape.Name("a"), kind), object)
		testing.expect_value(t, tape.step_enters(tape.Index(0), kind), array)
		testing.expect_value(t, tape.step_enters(tape.All{}, kind), array || object)
		testing.expect_value(t, tape.step_enters(tape.Slice{}, kind), array)
		testing.expect_value(t, tape.step_enters(tape.Slice{}, kind, true), array || object)
		testing.expect_value(t, tape.step_enters(tape.Name("a"), kind, true), object)
		testing.expect_value(t, tape.step_refused(kind), tape.Presence.Missing if kind == .Null else .Wrong_Kind)
	}
	for taken in u64(0) ..= 4 {
		for alls_end in u64(0) ..= 4 {
			testing.expect_value(t, tape.path_refused(taken, alls_end), tape.Presence.Missing if taken >= alls_end else .Wrong_Kind)
		}
	}
}

@(test)
indexes_count_from_either_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for count in u64(0) ..= 4 {
		for i in i64(-6) ..= 6 {
			at, ok := tape.index_in(i, count)
			want := i >= 0 && u64(i) < count || i < 0 && u64(-i) <= count
			testing.expectf(t, ok == want, "%d of %d: %v", i, count, ok)
			if ok {
				testing.expectf(t, at == (u64(i) if i >= 0 else count - u64(-i)), "%d of %d: %d", i, count, at)
			}
		}
	}
}

@(test)
all_takes_by_limit_object_and_policy :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for limit in i32(-1) ..= 3 {
		for index in u64(0) ..= 4 {
			for object in ([]bool{false, true}) {
				for dups in tape.Duplicates.Default ..= tape.Duplicates.Group {
					want := limit <= 0 || index < u64(limit) || object && dups != .First
					testing.expectf(t, tape.all_takes(limit, index, object, dups) == want, "limit %d index %d object %v %v", limit, index, object, dups)
				}
			}
		}
	}
}

// Steps that take back, take one, replace and replay, each over the policies.
@(test)
steps_take_one_replace_and_replay :: proc(t: ^testing.T) {
	testkit.deadline(t)
	N :: tape.Name
	for dups in tape.Duplicates.Default ..= tape.Duplicates.Group {
		testing.expect_value(t, tape.step_takes_one(N("a"), dups), dups == .First)
		testing.expect_value(t, tape.step_replaces(N("a"), dups), dups == .Last)
		for step in ([]tape.Step{tape.All{}, tape.Index(0), tape.Index(-1), tape.Slice{1, nil, 0}, tape.Slice{-1, nil, 0}}) {
			_, is_index := step.(tape.Index)
			positive := is_index && step.(tape.Index) >= 0
			testing.expectf(t, tape.step_takes_one(step, dups) == positive, "%v %v", step, dups)
			negative := tape.step_reach(step) > 0
			testing.expectf(t, tape.step_replaces(step, dups) == negative, "%v %v", step, dups)
		}
	}
	// An element from the end is read again only when a name follows it and the format can walk a value alone.
	for rewalks in ([]bool{false, true}) {
		steps := [][]tape.Step{
			{tape.Index(-1), N("a")},
			{tape.Index(-1)},
			{tape.Index(0), N("a")},
			{tape.Index(-1), tape.All{}},
			{N("a"), tape.Index(-2), N("b")},
			{tape.Slice{-2, nil, 0}, N("a")},
			{tape.Slice{1, -1, 0}, N("a")},
			{tape.Slice{-2, nil, 0}},
		}
		wants := [][]bool{{true, false}, {false}, {false, false}, {false, false}, {false, true, false}, {true, false}, {false, false}, {false}}
		for path, i in steps {
			for at in 0 ..< len(path) {
				testing.expectf(t, tape.step_replays(path, at, rewalks) == (wants[i][at] && rewalks), "%v at %d rewalks %v", path, at, rewalks)
			}
		}
	}
	for dups in tape.Duplicates.Default ..= tape.Duplicates.Group {
		for own in tape.Duplicates.Last ..= tape.Duplicates.Group {
			f := tape.Format{dups = own}
			want := own if dups == .Default else dups
			if want == .All || want == .Refuse {
				want = .Last
			}
			testing.expectf(t, tape.read_dups(&f, dups) == want, "%v under a format of %v: %v", dups, own, tape.read_dups(&f, dups))
		}
	}
	d, _ := tape.demand_of({{tape.Index(0), tape.Name("a"), tape.All{}, tape.Index(-1)}}, allocator = context.temp_allocator)
	x := d.paths[0]
	testing.expect_value(t, tape.path_settles(x, .First), 2)
	testing.expect_value(t, tape.path_settles(x, .Last), 1)
	testing.expect_value(t, tape.path_settles(x, .Group), 1)
	testing.expect_value(t, tape.path_final(x, .Last), 1)
	testing.expect_value(t, tape.path_final(x, .First), 3)
	testing.expect_value(t, tape.path_final(x, .Group), 3)
}

// A key is a name when its text is, whichever byte of a name of any length differs, and its kind is a scalar's.
@(test)
key_names_compare_every_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	f := tape.Format{same_text = twice_same}
	for n in 0 ..= 40 {
		name := make([]u8, n, context.temp_allocator)
		for &b, i in name {
			b = u8('a' + i % 26)
		}
		// The key sits in the middle of a longer text, so a compare reading past its span finds other bytes.
		src := make([]u8, n + 20, context.temp_allocator)
		for &b in src {
			b = 'z'
		}
		key := tape.Token{lo = 10, n = u32(n), kind = .String}
		for differs in -1 ..< n {
			copy(src[10:], name)
			if differs >= 0 {
				src[10 + differs] ~= 1
			}
			testing.expectf(t, tape.key_names(&f, src, key, string(name)) == (differs < 0), "%q, byte %d of %d differs", name, differs, n)
		}
		copy(src[10:], name)
		longer := tape.Token{lo = 10, n = u32(n + 1), kind = .String}
		testing.expectf(t, !tape.key_names(&f, src, longer, string(name)), "%q read as a name one byte longer", name)
		if n > 0 {
			shorter := tape.Token{lo = 10, n = u32(n - 1), kind = .String}
			testing.expectf(t, !tape.key_names(&f, src, shorter, string(name)), "%q read as a name one byte shorter", name)
		}
		testing.expect(t, !tape.key_names(&f, src, {lo = 10, n = u32(n), kind = .Array}, string(name)))
	}
}

@(test)
keys_are_one_by_kind_and_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	f := tape.Format{same_text = twice_same}
	src := transmute([]u8)string("abcdefgh abcdefgh abcdefgx")
	a := tape.Token{lo = 0, n = 8, kind = .String}
	testing.expect(t, tape.same_keys(&f, src, a, src, {lo = 9, n = 8, kind = .String}))
	testing.expect(t, !tape.same_keys(&f, src, a, src, {lo = 18, n = 8, kind = .String}))
	testing.expect(t, !tape.same_keys(&f, src, a, src, {lo = 9, n = 7, kind = .String}))
	testing.expect(t, !tape.same_keys(&f, src, a, src, {lo = 9, n = 8, kind = .Number}))
	// A key with an escape is one by the format's own comparison, whatever its bytes.
	decoded := tape.Token{lo = 0, n = 1, kind = .String, spelling = tape.SPELLING_DECODE}
	testing.expect(t, tape.same_keys(&f, src, decoded, src, {lo = 0, n = 1, kind = .String, spelling = tape.SPELLING_DECODE}))
	testing.expect(t, !tape.same_keys(&f, src, decoded, src, {lo = 1, n = 1, kind = .String, spelling = tape.SPELLING_DECODE}))
}

// A text's hash, taken whole or a byte at a time, is the same for the same text and moves with every byte.
@(test)
text_hashes_every_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for n in 0 ..= 40 {
		text := make([]u8, n, context.temp_allocator)
		for &b, i in text {
			b = u8('a' + i % 26)
		}
		hash := tape.text_hash(text)
		x := tape.text_hasher()
		for b in text {
			tape.text_hash_byte(&x, b)
		}
		testing.expectf(t, tape.text_hasher_end(&x) == hash, "%d bytes: whole %x, by byte %x", n, hash, tape.text_hasher_end(&x))
		for at in 0 ..< n {
			other := make([]u8, n, context.temp_allocator)
			copy(other, text)
			other[at] ~= 1
			testing.expectf(t, tape.text_hash(other) != hash, "%d bytes, byte %d changed: the hash does not move", n, at)
		}
	}
	testing.expect(t, tape.text_hash(transmute([]u8)string("ab")) != tape.text_hash(transmute([]u8)string("ab\x00")))
}

@(private = "file")
number_key_same :: proc "contextless" (src: []u8, a: tape.Token, other: []u8, b: tape.Token) -> bool {
	return true
}

@(private = "file")
number_key_room :: proc "contextless" (src: []u8, t: tape.Token) -> int {
	return 5
}

// A number key's number kind shares a bit with `SPELLING_DECODE`, and no kind changes how the key reads: each goes to
// the format's `same_text` and `room`.
@(test)
number_keys_read_the_same_for_every_number_kind :: proc(t: ^testing.T) {
	testkit.deadline(t)
	f := tape.Format{name = "numbers", same_text = number_key_same, room = number_key_room}
	src := []u8{0x01}
	for kind in 0 ..< u16(16) {
		key := tape.Token{lo = 0, n = 1, kind = .Number, role = .Key, spelling = tape.number_spelling(kind, 0, 0)}
		testing.expectf(t, tape.key_names(&f, src, key, "1"), "key_names, number kind %d", kind)
		testing.expectf(t, tape.same_keys(&f, src, key, src, key), "same_keys, number kind %d", kind)
		testing.expectf(t, tape.text_room(&f, src, key) == 5, "text_room, number kind %d", kind)
		value := key
		value.role = .Value
		testing.expectf(t, tape.text_room(&f, src, value) == 0, "text_room of a number value, kind %d", kind)
	}
}
