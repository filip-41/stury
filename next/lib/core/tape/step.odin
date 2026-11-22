package tape

import "base:intrinsics"

// The rules of a path's steps, which the readers over a document, a find over a text and a scan all follow.

// The `Presence` for a value a step cannot enter: `.Missing` for null, as jq reads a member or element of null as
// null, and `.Wrong_Kind` for any other scalar.
step_refused :: #force_inline proc "contextless" (kind: Kind) -> Presence {
	return .Missing if kind == .Null else .Wrong_Kind
}

// The `Presence` when the step after the first `taken` steps meets null or a child its container lacks. After the
// path's last `All` jq reads the rest of the path through null, so the answer is `.Missing`. Before it the `All`
// cannot iterate null, so the answer is `.Wrong_Kind`.
path_refused :: #force_inline proc "contextless" (taken, alls_end: u64) -> Presence {
	return .Missing if taken >= alls_end else .Wrong_Kind
}

// Whether `step` goes on into a value of `kind`. An `All` with a limit that a demand reads as a slice of members goes
// into an object too, as `members` says.
step_enters :: #force_inline proc "contextless" (step: Step, kind: Kind, members := false) -> bool {
	switch _ in step {
	case Name:
		return kind == .Object
	case Index:
		return kind == .Array
	case All:
		return kind == .Array || kind == .Object
	case Slice:
		return kind == .Array || members && kind == .Object
	}
	return false
}

// The element `i` of an array of `count` elements, negative from the end, false past either end.
index_in :: #force_inline proc "contextless" (i: i64, count: u64) -> (u64, bool) {
	if i < 0 {
		from_end := u64(-i)
		return count - from_end, from_end <= count
	}
	return u64(i), u64(i) < count
}

// Whether an `All` with `limit` takes child `index`. Under `.First` an object's member is final once read, and under
// any other policy only at the object's close, so a limit cuts an object's members under `.First` only.
all_takes :: #force_inline proc "contextless" (limit: i32, index: u64, object: bool, dups: Duplicates) -> bool {
	return limit <= 0 || index < u64(limit) || object && dups != .First
}

// Whether `s` takes element `e` of an array of `count` elements. With `count` 0 the count is not known yet, and an
// element an end from the end may yet take is taken.
slice_takes :: proc "contextless" (s: Slice, e, count: u64) -> bool {
	hi, bounded := s.hi.?
	if count == 0 {
		if s.lo >= 0 && (e < u64(s.lo) || s.limit > 0 && e - u64(s.lo) >= u64(s.limit)) {
			return false
		}
		return !bounded || hi < 0 || e < u64(hi)
	}
	n := i64(count)
	from := max(i64(s.lo) + n if s.lo < 0 else i64(s.lo), 0)
	to := n
	if bounded {
		to = i64(hi) + n if hi < 0 else min(i64(hi), n)
	}
	if s.limit > 0 && to - from > i64(s.limit) {
		to = from + i64(s.limit)
	}
	return i64(e) >= from && i64(e) < to
}

// The first element past every one `s` takes, known with no count, else `max(u64)`.
slice_cut :: proc "contextless" (s: Slice) -> u64 {
	hi, bounded := s.hi.?
	if s.lo < 0 || bounded && hi < 0 {
		return max(u64)
	}
	cut := u64(hi) if bounded else max(u64)
	if s.limit > 0 {
		cut = min(cut, u64(s.lo) + u64(s.limit))
	}
	return cut
}

// The furthest back from the end of an array that `step` reaches, 0 for a step that counts from the start only. A read
// with no document keeps a ring of that many elements to take it.
step_reach :: #force_inline proc "contextless" (step: Step) -> u64 {
	#partial switch s in step {
	case Index:
		return u64(-i64(s)) if s < 0 else 0
	case Slice:
		reach := u64(0) if s.lo >= 0 else u64(-i64(s.lo))
		if hi, bounded := s.hi.?; bounded && hi < 0 {
			reach = max(reach, u64(-i64(hi)))
		}
		return reach
	}
	return 0
}

// Whether a container `step` goes on through can take back the answer a child gave for a later child's: a later member
// of the key under `.Last`, or a later element under a step from the end.
step_replaces :: #force_inline proc "contextless" (step: Step, dups: Duplicates) -> bool {
	#partial switch _ in step {
	case Name:
		return dups == .Last
	}
	return step_reach(step) > 0
}

// Whether `step` takes one child at most, by a key under `.First` or a place from the start, so that a path through it
// is spent once it took one.
step_takes_one :: #force_inline proc "contextless" (step: Step, dups: Duplicates) -> bool {
	#partial switch s in step {
	case Name:
		return dups == .First
	case Index:
		return s >= 0
	}
	return false
}

// Whether a find reads again the elements of an array its step `at` from the end picks, an `Index` or a `Slice` whose
// start is from the end, which its walk passed whole as it went: when a `Name` follows, as a key compared in each
// element is more work than passing it, and the format can walk a value alone. Elements before an `Index` or `All` are
// less work to walk into, a last step's answer is the element itself, and a `Slice` from the start answers from its
// first elements.
step_replays :: #force_inline proc "contextless" (steps: []Step, at: int, rewalks: bool) -> bool {
	if !rewalks || at + 1 == len(steps) {
		return false
	}
	#partial switch s in steps[at] {
	case Index:
		if s >= 0 {
			return false
		}
	case Slice:
		if s.lo >= 0 {
			return false
		}
	case:
		return false
	}
	_, named := steps[at + 1].(Name)
	return named
}

// The policy a path read takes repeated keys by: the format's own for `.Default`, and the last for a build's `.All` and
// `.Refuse`, under which every member is a document's.
read_dups :: #force_inline proc "contextless" (f: ^Format, dups: Duplicates) -> Duplicates {
	d := f.dups if dups == .Default else dups
	return .Last if d == .All || d == .Refuse || d == .Default else d
}

// The step count of path `x` past which a walk back at that depth has made every answer of it final, with none to come.
path_settles :: #force_inline proc "contextless" (x: Demand_Path, dups: Duplicates) -> u32 {
	return x.repeats if dups == .First else min(x.repeats, x.named)
}

// Whether the scalar key `t` of `src`, a text of format `f`, reads as `name`. A `Name` takes a key of any scalar kind
// by its text, so YAML's `1` and `"1"` both read as `1`.
key_names :: #force_inline proc "contextless" (f: ^Format, src: []u8, t: Token, name: string) -> bool #no_bounds_check {
	if t.kind > .Plain {
		return false
	}
	if t.spelling & SPELLING_DECODE != 0 {
		return f.same_text(src, t, transmute([]u8)name, {n = u32(len(name)), kind = .String})
	}
	n := len(name)
	if int(t.n) != n {
		return false
	}
	a, b := raw_data(src[t.lo:]), raw_data(name)
	// A name shorter than a word is two loads that may overlap, each within both strings.
	switch {
	case n >= 8:
		return string(a[:n]) == name
	case n >= 4:
		head := intrinsics.unaligned_load((^u32)(a)) == intrinsics.unaligned_load((^u32)(b))
		return head && intrinsics.unaligned_load((^u32)(a[n - 4:])) == intrinsics.unaligned_load((^u32)(b[n - 4:]))
	case n >= 2:
		return intrinsics.unaligned_load((^u16)(a)) == intrinsics.unaligned_load((^u16)(b)) && a[n - 1] == b[n - 1]
	}
	return n == 0 || a[0] == b[0]
}

// Whether keys `a` of `src` and `b` of `other` are one key, of one kind and one text, as an object's repeated keys
// are. Kind is part of a key, so YAML's `1` and `"1"` are two.
same_keys :: #force_inline proc "contextless" (f: ^Format, src: []u8, a: Token, other: []u8, b: Token) -> bool #no_bounds_check {
	if a.kind != b.kind {
		return false
	}
	if (a.spelling | b.spelling) & SPELLING_DECODE == 0 {
		return a.n == b.n && string(src[a.lo:][:a.n]) == string(other[b.lo:][:b.n])
	}
	return f.same_text(src, a, other, b)
}

// The step count of path `x` past which a walk back at that depth has made every answer it made so far final, though
// more may come.
path_final :: #force_inline proc "contextless" (x: Demand_Path, dups: Duplicates) -> u32 {
	return x.takes_back if dups != .Last else min(x.takes_back, x.named)
}

// The hash of a key's text, which `Format.key_hash` gives for a key reading as `text`. Kind is left out, as a `Name`
// takes a key of any kind by its text, and the readers' tables compare kinds through `same_keys`.
text_hash :: proc "contextless" (text: []u8) -> u32 #no_bounds_check {
	p, n := raw_data(text), len(text)
	h := TEXT_SEED
	i := 0
	for ; i + 8 <= n; i += 8 {
		h = text_hash_word(h, intrinsics.unaligned_load((^u64)(p[i:])))
	}
	tail: u64
	for j in i ..< n {
		tail |= u64(p[j]) << (8 * uint(j - i))
	}
	return text_hash_end(h, tail, n)
}

// `text_hash` of a text given a byte at a time, for a format that decodes a key as it hashes it.
Text_Hasher :: struct {
	h, tail: u64,
	n:       int,
}

text_hasher :: #force_inline proc "contextless" () -> Text_Hasher {
	return {h = TEXT_SEED}
}

text_hash_byte :: #force_inline proc "contextless" (x: ^Text_Hasher, b: u8) {
	x.tail |= u64(b) << (8 * uint(x.n & 7))
	x.n += 1
	if x.n & 7 == 0 {
		x.h, x.tail = text_hash_word(x.h, x.tail), 0
	}
}

text_hasher_end :: #force_inline proc "contextless" (x: ^Text_Hasher) -> u32 {
	return text_hash_end(x.h, x.tail, x.n)
}

@(private)
TEXT_SEED :: u64(0x9E3779B97F4A7C15)

@(private)
text_hash_word :: #force_inline proc "contextless" (seed, word: u64) -> u64 {
	h := (seed ~ word) * TEXT_SEED
	return h ~ h >> 29
}

@(private)
text_hash_end :: #force_inline proc "contextless" (seed, tail: u64, n: int) -> u32 {
	h := (seed ~ tail ~ u64(n) << 56) * TEXT_SEED
	h ~= h >> 32
	h *= TEXT_SEED
	return u32(h >> 32)
}
