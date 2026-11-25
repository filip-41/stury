package typed

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The members a struct holds and the ones a read has set.

// A key the struct did not expect next, or a map's.
@(private)
key_miss :: #force_no_inline proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if .Dead in h.flags {
		return s, .Skip
	}
	f := &h.frames[h.sp - 1]
	owner := frame_owner(f)
	#partial switch owner.kind {
	case .Struct, .Required:
		return struct_key(h, s, t, f, owner)
	case .Map:
		return map_key(h, s, t, f, owner)
	}
	return s, .Skip
}

// Moves the cursor to the member named by key `t`. A member the type does not name is passed, or refused under
// `refuse_unknown`. Under `.First` a repeated member is passed and the cursor moves to the member's solo record, so
// every later key of the object comes here. Under `.Last` a repeat is reset before it is read again, and the cursor
// moves to the solo record when a member after this one was read, so a key the cursor matches is never a repeat.
@(private)
struct_key :: proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token, f: ^Frame, owner: ^Record) -> (hook.Regs, hook.Action) {
	s := s
	m := &h.plan.meta[owner.meta]
	i := member_index(h, owner, m, t)
	if i < 0 {
		if .Unknown in h.flags {
			return refuse_at(h, s, t, .Unknown_Field, t.lo, h.sp, nil, key_span(h, t))
		}
		return s, .Skip
	}
	if f.seen & SEEN_ON == 0 && !seen_start(h, f, m) {
		return refuse_memory(h, s, t)
	}
	mark_run(h, f, owner, s.b)
	member := &([^]Record)(owner.first)[i]
	if seen_set(f, i) {
		if .First in h.flags {
			return s, .Skip
		}
		if !reset(h, member, uintptr(s.c) + uintptr(member.offset), f.seen & SEEN_TARGET != 0) {
			return refuse_memory(h, s, t)
		}
	}
	if .First in h.flags || read_after(f, i, int(m.count)) {
		s.b = u64(uintptr(&h.plan.records[h.plan.meta[member.meta].solo]))
	} else {
		s.b = u64(uintptr(member)) + size_of(Record)
		f.run = u64(i + 1)
	}
	return s, .Next
}

// The most members of a struct whose names are compared one by one before its hash is taken.
@(private)
SCAN_MEMBERS :: 8

// The member of struct `owner` whose name key `t` reads as, -1 for none.
@(private)
member_index :: proc "contextless" (h: ^Reader, owner: ^Record, m: ^Meta, t: tape.Token) -> int #no_bounds_check {
	members := ([^]Record)(owner.first)
	if m.count <= SCAN_MEMBERS {
		for i in 0 ..< int(m.count) {
			if key_hit(h, &members[i], t) {
				return i
			}
		}
	}
	src := h.base[:h.len]
	mask := m.slots_n - 1
	at := h.format.key_hash(src, t) & mask
	for {
		k := h.plan.slots[m.slots + at]
		if k == 0 {
			return -1
		}
		if tape.key_names(h.format, src, t, h.plan.meta[members[k - 1].meta].name) {
			return int(k - 1)
		}
		at = (at + 1) & mask
	}
}

// Starts tracking which members of the struct in frame `f` were read, false when memory is refused.
@(private)
seen_start :: proc "contextless" (h: ^Reader, f: ^Frame, m: ^Meta) -> bool {
	context = h.ctx
	f.seen, f.run = f.seen | SEEN_ON, 0
	if m.count <= SEEN_BITS {
		return true
	}
	words, err := runtime.mem_alloc(int(wide_words(m)) * size_of(u64), align_of(u64), h.scratch)
	if err != nil {
		return false
	}
	f.data = raw_data(words)
	f.seen |= SEEN_WIDE
	return true
}

@(private)
wide_words :: #force_inline proc "contextless" (m: ^Meta) -> u32 {
	return (m.count - SEEN_BITS + 63) / 64
}

// Frees the words a struct's frame tracks its wide members in.
@(private)
seen_end :: proc "contextless" (h: ^Reader, f: ^Frame, owner: ^Record) {
	context = h.ctx
	if f.seen & SEEN_WIDE != 0 {
		runtime.mem_free_with_size(f.data, int(wide_words(&h.plan.meta[owner.meta])) * size_of(u64), h.scratch)
		f.seen &~= SEEN_WIDE
	}
}

// Sets member `i`'s mark in frame `f` and says whether it was set.
@(private)
seen_set :: proc "contextless" (f: ^Frame, i: int) -> bool {
	if i < SEEN_BITS {
		bit := u64(1) << uint(i)
		was := f.seen & bit != 0
		f.seen |= bit
		return was
	}
	words := ([^]u64)(f.data)
	bit := u64(1) << uint((i - SEEN_BITS) % 64)
	was := words[(i - SEEN_BITS) / 64] & bit != 0
	words[(i - SEEN_BITS) / 64] |= bit
	return was
}

// Whether a member after member `i` of the `count` in frame `f` was read, taken as so past the members `seen` holds.
@(private)
read_after :: proc "contextless" (f: ^Frame, i, count: int) -> bool {
	if i + 1 >= count {
		return false
	}
	return count > SEEN_BITS || f.seen & (u64(1) << SEEN_BITS - 1) >> uint(i + 1) != 0
}

@(private)
seen_has :: proc "contextless" (f: ^Frame, i: int) -> bool {
	if i < SEEN_BITS {
		return f.seen & (u64(1) << uint(i)) != 0
	}
	return ([^]u64)(f.data)[(i - SEEN_BITS) / 64] & (u64(1) << uint((i - SEEN_BITS) % 64)) != 0
}

// Marks the members the cursor `b` passed by their keys since `Frame.run`. A cursor outside the struct's block, at a
// solo record, passed none.
@(private)
mark_run :: proc "contextless" (h: ^Reader, f: ^Frame, owner: ^Record, b: u64) {
	first := u64(uintptr(owner.first))
	count := u64(h.plan.meta[owner.meta].count)
	if b < first || b > first + count * size_of(Record) {
		return
	}
	upto := (b - first) / size_of(Record)
	for i in f.run ..< upto {
		seen_set(f, int(i))
	}
	f.run = max(f.run, upto)
}
