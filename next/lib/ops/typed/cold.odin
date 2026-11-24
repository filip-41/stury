package typed

import "base:intrinsics"
import "base:runtime"
import "core:strconv"
import "core:time"
import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The read's cold paths: keys out of the struct's order and a map's keys, the kinds the hook's hot cases do not take,
// the growth of lists and frames, and the closes that check or publish.

// A key the struct did not expect next, or a map's.
@(private)
key_miss :: #force_no_inline proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if h.dead {
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
// every later key of the object comes here. Under `.Last` a repeat is reset before it is read again.
@(private)
struct_key :: proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token, f: ^Frame, owner: ^Record) -> (hook.Regs, hook.Action) {
	s := s
	m := &h.plan.meta[owner.meta]
	i := member_index(h, owner, m, t)
	if i < 0 {
		if h.unknown {
			return refuse_at(h, s, t, .Unknown_Field, t.lo, h.sp, nil, key_span(h, t))
		}
		return s, .Skip
	}
	if f.seen == 0 && !seen_start(h, f, m) {
		return refuse_memory(h, s, t)
	}
	mark_run(h, f, owner, s.b)
	member := &([^]Record)(owner.first)[i]
	if seen_set(f, i) {
		if h.first {
			return s, .Skip
		}
		reset(h, member, uintptr(s.c) + uintptr(member.offset))
	}
	if h.first {
		s.b = u64(uintptr(&h.plan.records[h.plan.meta[member.meta].solo]))
	} else {
		s.b = u64(uintptr(member)) + size_of(Record)
		f.run = u64(i + 1)
	}
	return s, .Next
}

// The member of struct `owner` whose name key `t` reads as, -1 for none.
@(private)
member_index :: proc "contextless" (h: ^Reader, owner: ^Record, m: ^Meta, t: tape.Token) -> int #no_bounds_check {
	src := h.base[:h.len]
	mask := m.slots_n - 1
	at := h.format.key_hash(src, t) & mask
	members := ([^]Record)(owner.first)
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

// The bits of `Frame.seen` past the members' own: `SEEN_ON` once the struct's members are tracked, `SEEN_WIDE` when
// members from `SEEN_BITS` on are tracked in the words at `Frame.data`.
@(private)
SEEN_WIDE :: u64(1) << 62

@(private)
SEEN_BITS :: 62

// Starts tracking which members of the struct in frame `f` were read, false when memory is refused.
@(private)
seen_start :: proc "contextless" (h: ^Reader, f: ^Frame, m: ^Meta) -> bool {
	context = h.ctx
	f.seen, f.run = SEEN_ON, 0
	if m.count <= SEEN_BITS {
		return true
	}
	words, err := runtime.mem_alloc(int(wide_words(m)) * size_of(u64), align_of(u64), h.allocator)
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
		runtime.mem_free_with_size(f.data, int(wide_words(&h.plan.meta[owner.meta])) * size_of(u64), h.allocator)
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

// A container about to be read into a struct's member after the struct's keys came out of order, which under `.Last`
// is reset when it was read before, as its later occurrence replaces it whole.
@(private)
revisit :: #force_no_inline proc "contextless" (h: ^Reader, s: hook.Regs, rec: ^Record, dest: uintptr) {
	f := &h.frames[h.sp - 1]
	owner := frame_owner(f)
	if h.first || owner.kind != .Struct && owner.kind != .Required {
		return
	}
	first := uintptr(owner.first)
	count := uintptr(h.plan.meta[owner.meta].count)
	if uintptr(rec) < first || uintptr(rec) >= first + count * size_of(Record) {
		return
	}
	mark_run(h, f, owner, u64(uintptr(rec)))
	i := index_in(rec, owner.first)
	if seen_set(f, i) {
		reset(h, rec, dest)
	}
	f.run = u64(i + 1)
}

// Resets record `rec`'s value at `dest` before a repeat reads it again: a text the read copied is freed, a list's
// elements are freed, and a container is zeroed, as a scalar's store replaces it whole. What the replaced value's
// elements and members hold stays allocated.
@(private)
reset :: proc "contextless" (h: ^Reader, rec: ^Record, dest: uintptr) {
	context = h.ctx
	#partial switch rec.kind {
	case .String, .Raw:
		release_text(h, dest)
	case .Slice, .Dynamic:
		// A slice's room is not kept, so the budget counts its block held until the read ends.
		room := (^runtime.Raw_Dynamic_Array)(dest).cap if rec.kind == .Dynamic else 0
		if data := (^runtime.Raw_Slice)(dest).data; data != nil {
			runtime.mem_free_with_size(data, room * int(h.plan.meta[rec.meta].size), h.allocator)
		}
		intrinsics.mem_zero(rawptr(dest), type_info_of(h.plan.meta[rec.meta].type).size)
	case .Struct, .Required, .Map, .Array, .Bit_Set, .Maybe, .Union, .Ptr:
		intrinsics.mem_zero(rawptr(dest), type_info_of(h.plan.meta[rec.meta].type).size)
	}
}

// Frees the text at `dest` when this read copied it, not when it is a span of the text.
@(private)
release_text :: proc "contextless" (h: ^Reader, dest: uintptr) {
	context = h.ctx
	text := (^runtime.Raw_String)(dest)^
	at := uintptr(text.data)
	if text.len != 0 && (at < uintptr(h.base) || at >= uintptr(h.base) + uintptr(h.len)) {
		runtime.mem_free_with_size(text.data, text.len, h.allocator)
	}
	(^runtime.Raw_String)(dest)^ = {}
}

// The key `t` as written, for a path or a refusal.
@(private)
key_span :: #force_inline proc "contextless" (h: ^Reader, t: tape.Token) -> string {
	return string(h.base[t.lo:][:t.n])
}

// Moves a map's value cursor to the entry of key `t`, made zero when it is new. Under `.Last` a key the map holds is
// read again from zero, and under `.First` a key this read met in the object before is passed.
@(private)
map_key :: proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token, f: ^Frame, owner: ^Record) -> (hook.Regs, hook.Action) {
	context = h.ctx
	s := s
	f.key = t
	m := &h.plan.meta[owner.meta]
	raw := (^runtime.Raw_Map)(f.data)
	k: [2]u64
	owned: []u8
	if m.key_kind == .String {
		if text, ok := store_text(h, t, uintptr(&k), true); !ok {
			return refuse_memory(h, s, t)
		} else {
			owned = text
		}
	} else {
		buf: [64]u8 = ---
		text, held, ok := token_text(h, t, buf[:])
		if !ok {
			return refuse_memory(h, s, t)
		}
		detail: Refusal
		if m.key_kind == .Enum {
			detail = store_enum_name(h, m.enum_info, text, uintptr(&k), int(m.map_info.ks.size_of_type))
		} else {
			n, number_ok := spell.number_strict(transmute([]u8)text, 0, u64(len(text)))
			detail = store_integer(n, number_ok, text, m.key_kind, uintptr(&k))
		}
		free_held(h, held)
		if detail != .None {
			return refuse_at(h, s, t, detail, t.lo, h.sp, nil, key_span(h, t))
		}
	}
	if h.first && f.seen != 0 {
		met, err := first_met(h, f, key_span(h, t))
		if err != nil {
			free_held(h, owned)
			return refuse_memory(h, s, t)
		}
		if met {
			free_held(h, owned)
			return s, .Skip
		}
	}
	if h.zero == nil || len(h.zero) < int(m.map_info.vs.size_of_type) {
		if h.zero != nil {
			runtime.mem_free_with_size(raw_data(h.zero), len(h.zero), h.allocator)
			h.zero = nil
		}
		zero, err := runtime.mem_alloc(max(int(m.map_info.vs.size_of_type), 16), 16, h.allocator)
		if err != nil {
			free_held(h, owned)
			return refuse_memory(h, s, t)
		}
		h.zero = zero
	}
	if !copy_pending(h) {
		free_held(h, owned)
		return refuse_memory(h, s, t)
	}
	// The map grows in the read's allocator, and keeps the caller's for its owner.
	if raw.allocator.procedure == nil {
		raw.allocator = h.caller
	}
	held := raw.allocator
	raw.allocator = h.allocator
	_, slot, inserted, err := runtime.__dynamic_map_entry(raw, m.map_info, &k, raw_data(h.zero))
	raw.allocator = held
	if err != nil || slot == nil {
		free_held(h, owned)
		return refuse_memory(h, s, t)
	}
	if !inserted {
		free_held(h, owned)
		if h.first && f.seen == 0 {
			return s, .Skip
		}
		// The entries of a map empty at its open are this read's, so a repeat frees what the earlier one allocated.
		if f.seen == 0 {
			reset(h, (^Record)(uintptr(owner.first) - size_of(Record)), uintptr(slot))
		}
		intrinsics.mem_zero(slot, int(m.map_info.vs.size_of_type))
	}
	h.key, h.fresh = k, inserted
	s.c = u64(uintptr(slot))
	return s, .Next
}

// Whether a map's frame met key `key` before in this object under `.First`, adding it when not. A map that held
// entries at its open keeps the keys it met in a set of its own, as an entry it holds may be the destination's.
@(private)
first_met :: proc(h: ^Reader, f: ^Frame, key: string) -> (met: bool, err: runtime.Allocator_Error) {
	if f.run == 0 {
		set := new(map[string]struct {}, h.allocator) or_return
		set.allocator = h.allocator
		f.run = u64(uintptr(set))
	}
	set := (^map[string]struct {})(uintptr(f.run))
	if key in set {
		return true, nil
	}
	_, err = map_insert(set, key, struct {}{})
	return false, err
}

// Frees the set of keys a map's frame met under `.First`.
@(private)
first_end :: proc "contextless" (h: ^Reader, f: ^Frame) {
	if f.run != 0 {
		context = h.ctx
		set := (^map[string]struct {})(uintptr(f.run))
		delete(set^)
		free(set, h.allocator)
		f.run = 0
	}
}

// Frees a block `token_text` or `store_text` allocated.
@(private)
free_held :: #force_inline proc "contextless" (h: ^Reader, held: []u8) {
	context = h.ctx
	if held != nil {
		runtime.mem_free_with_size(raw_data(held), len(held), h.allocator)
	}
}

// The text of scalar token `t`: its bytes in the text, or its decode in `buf`, or in a block of the read's allocator,
// `held`, when `buf` is too short. False when memory is refused.
@(private)
token_text :: proc "contextless" (h: ^Reader, t: tape.Token, buf: []u8) -> (s: string, held: []u8, ok: bool) {
	context = h.ctx
	src := h.base[:h.len]
	if s, ok = tape.node_text_of(h.format, src, t, buf); ok {
		return
	}
	room := h.format.room(src, t)
	err: runtime.Allocator_Error
	if held, err = runtime.mem_alloc_non_zeroed(room, 1, h.allocator); err != nil {
		return "", nil, false
	}
	s, ok = tape.node_text_of(h.format, src, t, held)
	return s, held, ok
}

// Stores the text of string token `t` at `dest`: a span of the text when the read borrows and it has nothing to decode,
// else a copy in the read's allocator, returned too when `held` asks for it. False when memory is refused.
@(private)
store_text :: proc "contextless" (h: ^Reader, t: tape.Token, dest: uintptr, $held: bool) -> ([]u8, bool) {
	if t.spelling & tape.SPELLING_DECODE == 0 && h.borrow {
		(^runtime.Raw_String)(dest)^ = {h.base[t.lo:], int(t.n)}
		return nil, true
	}
	if !store_string(h, t, dest) {
		return nil, false
	}
	when held {
		text := (^runtime.Raw_String)(dest)^
		return text.data[:text.len], true
	} else {
		return nil, true
	}
}

// Copies the strings held as spans of the text that `Reader.pending` names, false when memory is refused, which leaves
// the rest empty. A string a repeat replaced, holding no span then, is passed.
@(private)
copy_pending :: #force_no_inline proc "contextless" (h: ^Reader) -> bool {
	if h.pended == 0 {
		return true
	}
	context = h.ctx
	lo, hi := uintptr(h.base), uintptr(h.base) + uintptr(h.len)
	ok := true
	for dest in h.pending[:h.pended] {
		text := (^runtime.Raw_String)(dest)
		at := uintptr(text.data)
		if text.len == 0 || at < lo || at >= hi {
			continue
		}
		if !ok {
			text^ = {}
			continue
		}
		buf, err := h.allocator.procedure(h.allocator.data, .Alloc_Non_Zeroed, text.len, 1, nil, 0)
		if err != nil {
			text^ = {}
			ok = false
			continue
		}
		copy_short(raw_data(buf), text.data, text.len)
		text.data = raw_data(buf)
	}
	h.pended = 0
	return ok
}

// Copies `n` bytes from `src` to `dst`, a short run in overlapping loads of its first and last bytes.
@(private)
copy_short :: #force_inline proc "contextless" (dst, src: [^]u8, n: int) {
	switch {
	case n > 32:
		intrinsics.mem_copy_non_overlapping(dst, src, n)
	case n >= 16:
		a := intrinsics.unaligned_load((^[16]u8)(src))
		b := intrinsics.unaligned_load((^[16]u8)(src[n - 16:]))
		intrinsics.unaligned_store((^[16]u8)(dst), a)
		intrinsics.unaligned_store((^[16]u8)(dst[n - 16:]), b)
	case n >= 8:
		a := intrinsics.unaligned_load((^u64)(src))
		b := intrinsics.unaligned_load((^u64)(src[n - 8:]))
		intrinsics.unaligned_store((^u64)(dst), a)
		intrinsics.unaligned_store((^u64)(dst[n - 8:]), b)
	case n >= 4:
		a := intrinsics.unaligned_load((^u32)(src))
		b := intrinsics.unaligned_load((^u32)(src[n - 4:]))
		intrinsics.unaligned_store((^u32)(dst), a)
		intrinsics.unaligned_store((^u32)(dst[n - 4:]), b)
	case:
		for i in 0 ..< n {
			dst[i] = src[i]
		}
	}
}

// Stores a copy of the text of token `t` at `dest`, false when memory is refused. An empty text allocates nothing.
@(private)
store_string :: #force_no_inline proc "contextless" (h: ^Reader, t: tape.Token, dest: uintptr) -> bool {
	context = h.ctx
	src := h.base[:h.len]
	if t.spelling & tape.SPELLING_DECODE == 0 {
		if t.n == 0 {
			(^runtime.Raw_String)(dest)^ = {}
			return true
		}
		buf, err := runtime.mem_alloc_non_zeroed(int(t.n), 1, h.allocator)
		if err != nil {
			return false
		}
		intrinsics.mem_copy_non_overlapping(raw_data(buf), h.base[t.lo:], int(t.n))
		(^runtime.Raw_String)(dest)^ = {raw_data(buf), int(t.n)}
		return true
	}
	room := h.format.room(src, t)
	buf, err := runtime.mem_alloc_non_zeroed(room, 1, h.allocator)
	if err != nil {
		return false
	}
	text, _ := h.format.decode(src, t, buf)
	if len(text) == 0 {
		runtime.mem_free_with_size(raw_data(buf), room, h.allocator)
		text = ""
	}
	(^runtime.Raw_String)(dest)^ = transmute(runtime.Raw_String)text
	return true
}

// Gives the open list room for one more element, or refuses the element of a fixed array that has none. A refused read
// answers every value here, as its registers have no room.
@(private)
grow_list :: #force_no_inline proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action, bool) {
	context = h.ctx
	if h.dead {
		return dead_regs(), dead_action(t), false
	}
	f := &h.frames[h.sp - 1]
	owner := frame_owner(f)
	if owner.kind != .Slice && owner.kind != .Dynamic {
		r, a := refuse_value(h, s, t, .Too_Many)
		return r, a, false
	}
	if !copy_pending(h) {
		r, a := refuse_memory(h, s, t)
		return r, a, false
	}
	m := &h.plan.meta[owner.meta]
	stride := u64(m.size)
	data := u64(uintptr(f.data))
	n, room: u64
	if f.data != nil {
		n, room = (s.c - data) / stride, (s.a - data) / stride
	}
	wide := max(8, room * 2)
	bytes, err := runtime.non_zero_mem_resize(f.data, int(room * stride), int(wide * stride), int(m.align), h.allocator)
	if err != nil {
		r, a := refuse_memory(h, s, t)
		return r, a, false
	}
	if m.zeroed {
		intrinsics.mem_zero(raw_data(bytes)[room * stride:], int((wide - room) * stride))
	}
	f.data = raw_data(bytes)
	data = u64(uintptr(f.data))
	return {data + wide * stride, s.b, data + n * stride}, .Next, true
}

// Doubles the frames the read holds, false when memory is refused.
@(private)
frames_grow :: #force_no_inline proc "contextless" (h: ^Reader) -> bool {
	context = h.ctx
	wide := h.room * 2
	bytes, err := runtime.mem_alloc_non_zeroed(wide * size_of(Frame), align_of(Frame), h.allocator)
	if err != nil {
		return false
	}
	intrinsics.mem_copy_non_overlapping(raw_data(bytes), h.frames, h.room * size_of(Frame))
	if h.frames != h.home {
		runtime.mem_free_with_size(h.frames, h.room * size_of(Frame), h.allocator)
	}
	h.frames, h.room = ([^]Frame)(raw_data(bytes)), wide
	return true
}

// Pushes the frame of a container that record `rec` reads at `dest` from registers `s`, false when memory is refused.
@(private)
push :: proc "contextless" (h: ^Reader, s: hook.Regs, data: rawptr) -> (^Frame, bool) {
	if h.sp == h.room && !frames_grow(h) {
		return nil, false
	}
	f := &h.frames[h.sp]
	h.sp += 1
	f^ = {a = s.a, b = s.b, c = s.c, data = data}
	return f, true
}

// The close of a container the hook's hot case does not take: a struct whose members were tracked or that has a
// `required` member the cursor did not pass, a list, a fixed array, a raw value or a wrapper's element.
@(private)
close_container :: #force_no_inline proc "contextless" (h: ^Reader, f: ^Frame, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	if h.dead {
		h.sp = 1
		return dead_regs(), .Next
	}
	own := (^Record)(uintptr(f.b) - size_of(Record))
	owner := frame_owner(f)
	back := hook.Regs{f.a, f.b, f.c + u64(own.stride)}
	#partial switch owner.kind {
	case .Struct, .Required:
		missing := -1
		if f.seen != 0 {
			mark_run(h, f, owner, s.b)
			if owner.kind == .Required {
				missing = missing_member(h, f, owner, 0)
			}
			seen_end(h, f, owner)
		} else if owner.kind == .Required {
			missing = missing_member(h, nil, owner, index_in((^Record)(uintptr(s.b)), owner.first))
		}
		if missing >= 0 {
			name := member_name(h, &h.plan.meta[([^]Record)(owner.first)[missing].meta])
			return refuse_at(h, back, t, .Missing_Field, t.lo, h.sp + 1, nil, name)
		}
	case .Slice, .Dynamic:
		publish_list(h, f, owner, s.a, s.c, false)
	case .Array:
		if s.c != s.a {
			return refuse_at(h, back, t, .Too_Few, t.lo, h.sp + 1, nil)
		}
	case .Map:
		first_end(h, f)
	case .Raw:
		if !store_raw(h, u64(uintptr(f.data)), t.lo + u64(t.n), list_dest(f, owner)) {
			return refuse_memory(h, back, t)
		}
	}
	return back, .Next
}

// Takes back the new entry the last key made in the map of frame `f`, for an empty cell.
@(private)
map_absent :: proc "contextless" (h: ^Reader, f: ^Frame) {
	m := &h.plan.meta[frame_owner(f).meta]
	key := h.key
	if k, _, ok := runtime.map_erase_dynamic((^runtime.Raw_Map)(f.data), m.map_info, uintptr(&key)); ok && m.key_kind == .String {
		release_text(h, k)
	}
}

// The first `required` member of the struct `owner` from `from` on that was not read, -1 for none. With no frame the
// members before `from` were read and none after.
@(private)
missing_member :: proc "contextless" (h: ^Reader, f: ^Frame, owner: ^Record, from: int) -> int {
	m := &h.plan.meta[owner.meta]
	members := ([^]Record)(owner.first)
	for i in from ..< int(m.required) {
		if h.plan.meta[members[i].meta].must && (f == nil || !seen_has(f, i)) {
			return i
		}
	}
	return -1
}

// Writes the list frame `f` holds to its destination, counting the element at `c` when `open` says it is being read.
@(private)
publish_list :: proc "contextless" (h: ^Reader, f: ^Frame, owner: ^Record, a, c: u64, open: bool) {
	dest := list_dest(f, owner)
	stride := u64(h.plan.meta[owner.meta].size)
	data := u64(uintptr(f.data))
	n, room: int
	if f.data != nil {
		n, room = int((c - data) / stride) + int(open), int((a - data) / stride)
	}
	if owner.kind == .Slice {
		(^runtime.Raw_Slice)(dest)^ = {f.data, n}
	} else {
		(^runtime.Raw_Dynamic_Array)(dest)^ = {f.data, n, room, h.caller}
	}
}

// Where the container of frame `f` goes. A wrapper's frame holds the address, as its registers are the wrapper's.
@(private)
list_dest :: #force_inline proc "contextless" (f: ^Frame, owner: ^Record) -> uintptr {
	if wrapper((^Record)(uintptr(f.b) - size_of(Record)).kind) {
		return f.target
	}
	return uintptr(f.c) + uintptr(owner.offset)
}

// Gives the lists open in the frames below `n` to their destinations, innermost first, so what a read ended early
// allocated is reachable from the target, and frees what the frames hold for themselves. `s` are the registers of the
// innermost frame's next value.
@(private)
settle_open :: proc "contextless" (h: ^Reader, s: hook.Regs, n: int) {
	top, child := s, false
	for i := n - 1; i >= 1; i -= 1 {
		f := &h.frames[i]
		owner := frame_owner(f)
		#partial switch owner.kind {
		case .Slice, .Dynamic:
			publish_list(h, f, owner, top.a, top.c, child)
		case .Struct, .Required:
			seen_end(h, f, owner)
		case .Map:
			first_end(h, f)
		}
		top, child = {f.a, f.b, f.c}, true
	}
}

// A value the hook's hot cases do not take: a kind read through its own path, a wrapper's element, a delimited text's
// cell for a field other than a string, or a token the record refuses.
@(private)
indirect :: #force_no_inline proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number, $CELLS: bool) -> (hook.Regs, hook.Action) {
	s := s
	rec := (^Record)(uintptr(s.b) - size_of(Record))
	if rec.kind == .Dead {
		return s, dead_action(t)
	}
	dest := uintptr(s.c) + uintptr(rec.offset)
	if t.kind == .Bytes && byte_list(rec) {
		if !store_bytes(h, t, rec, dest) {
			return refuse_memory(h, s, t)
		}
		s.c += u64(rec.stride)
		return s, .Next
	}
	m := &h.plan.meta[rec.meta]
	container := t.kind == .Object || t.kind == .Array
	if container && h.frames[h.sp - 1].seen != 0 {
		revisit(h, s, rec, dest)
	}
	when CELLS {
		if t.kind == .Null {
			// An empty cell is absent: it leaves a list's element zero, a map no entry, and a `required` member missing.
			f := &h.frames[h.sp - 1]
			if m.must {
				return refuse_at(h, s, t, .Missing_Field, t.lo, h.sp, nil, member_name(h, m))
			} else if rec.stride != 0 {
				intrinsics.mem_zero(rawptr(dest), int(rec.stride))
			} else if frame_owner(f).kind == .Map && h.fresh {
				map_absent(h, f)
			}
			s.c += u64(rec.stride)
			return s, .Next
		}
		if t.kind == .String && rec.kind != .String && rec.kind != .Raw && rec.kind != .Time && !wrapper(rec.kind) {
			if cell, ok := cell_value(h, t); ok {
				return reader_hook(h, s, cell, number, CELLS)
			}
		} else if (t.kind == .Number || t.kind == .True || t.kind == .False) && rec.kind == .String {
			// A cell read as a number or a boolean is text for a string.
			if _, ok := store_text(h, t, dest, false); !ok {
				return refuse_memory(h, s, t)
			}
			s.c += u64(rec.stride)
			return s, .Next
		}
	}
	detail := Refusal.None
	#partial switch rec.kind {
	case .Maybe, .Ptr, .Union:
		return wrapped(h, s, t, rec, m, dest, number, CELLS)
	case .Raw:
		lo := t.lo
		if container {
			if _, ok := push(h, s, rawptr(uintptr(lo))); !ok {
				return refuse_memory(h, s, t)
			}
			return s, .Skip
		}
		head, tail := h.format.bounds(h.base[:h.len], t)
		if !store_raw(h, lo - u64(head), t.lo + u64(t.n) + u64(tail), dest) {
			return refuse_memory(h, s, t)
		}
	case .Array, .Bit_Set:
		if t.kind != .Array {
			detail = .Expected_Array
			break
		}
		limit := NO_LIMIT
		if rec.kind == .Array {
			limit = u64(dest) + u64(m.count) * u64(m.size)
		} else {
			intrinsics.mem_zero(rawptr(dest), type_info_of(m.type).size)
		}
		if _, ok := push(h, s, rawptr(dest)); !ok {
			return refuse_memory(h, s, t)
		}
		return {limit, u64(uintptr(rec.first)), u64(dest)}, .Next
	case .Map:
		if t.kind != .Object {
			detail = .Expected_Object
			break
		}
		f, ok := push(h, s, rawptr(dest))
		if !ok {
			return refuse_memory(h, s, t)
		}
		// A map that holds entries at its open tracks the keys `.First` met in a set of its own.
		f.seen = u64((^runtime.Raw_Map)(dest).len != 0)
		return {NO_LIMIT, u64(uintptr(rec.first)), 0}, .Next
	case .Enum:
		detail = store_enum(h, t, m, dest, number)
	case .Bit_Elem:
		detail = store_bit(h, t, m, dest, number)
	case .Bool_Wide:
		if t.kind != .True && t.kind != .False {
			detail = .Expected_Bool
			break
		}
		intrinsics.mem_zero(rawptr(dest), int(m.size))
		(^u8)(dest)^ = u8(t.kind == .True)
	case .Time:
		detail = store_time(h, t, dest, number)
	case:
		detail = expected(rec.kind)
	}
	if detail != .None {
		return refuse_value(h, s, t, detail)
	}
	s.c += u64(rec.stride)
	return s, .Next
}

// Whether `rec` reads a slice or dynamic array of `u8`, which takes a byte string's bytes.
@(private)
byte_list :: proc "contextless" (rec: ^Record) -> bool {
	return (rec.kind == .Slice || rec.kind == .Dynamic) && (^Record)(uintptr(rec.first) - size_of(Record)).kind == .U8
}

// Stores the bytes of byte string `t` as the list `rec` at `dest`: a span of the text when the read borrows and they
// have nothing to decode, else a copy. False when memory is refused.
@(private)
store_bytes :: proc "contextless" (h: ^Reader, t: tape.Token, rec: ^Record, dest: uintptr) -> bool {
	context = h.ctx
	buf: [64]u8 = ---
	text, held, ok := token_text(h, t, buf[:])
	if !ok {
		return false
	}
	defer free_held(h, held)
	// A dynamic array frees its block with its allocator, so it never borrows.
	data := raw_data(text)
	inside := uintptr(data) >= uintptr(h.base) && uintptr(data) < uintptr(h.base) + uintptr(h.len)
	if !(h.borrow && inside && rec.kind == .Slice) {
		data = nil
		if len(text) > 0 {
			block, err := runtime.mem_alloc_non_zeroed(len(text), 1, h.allocator)
			if err != nil {
				return false
			}
			copy(block, text)
			data = raw_data(block)
		}
	}
	if rec.kind == .Slice {
		(^runtime.Raw_Slice)(dest)^ = {data, len(text)}
	} else {
		(^runtime.Raw_Dynamic_Array)(dest)^ = {data, len(text), len(text), h.caller}
	}
	return true
}

// The detail of a value of the wrong kind for a record of `kind`.
@(private)
expected :: proc "contextless" (kind: Read_Kind) -> Refusal {
	#partial switch kind {
	case .String:
		return .Expected_String
	case .Bool, .Bool_Wide:
		return .Expected_Bool
	case .Struct, .Required, .Map:
		return .Expected_Object
	case .Slice, .Dynamic, .Array, .Bit_Set:
		return .Expected_Array
	case .I8 ..= .U64:
		return .Expected_Integer
	case .F32, .F64:
		return .Expected_Number
	}
	return .Expected_String
}

// A string cell as the value its text spells for a field other than a string: `true` and `false` as booleans, and a
// number as a number token. False for a cell that spells neither, which the field then refuses.
@(private)
cell_value :: proc "contextless" (h: ^Reader, t: tape.Token) -> (tape.Token, bool) {
	if t.spelling & tape.SPELLING_DECODE != 0 {
		return t, false
	}
	cell := t
	switch string(h.base[t.lo:][:t.n]) {
	case "true":
		cell.kind = .True
	case "false":
		cell.kind = .False
	case:
		if _, ok := spell.number_strict(h.base[:h.len], t.lo, t.lo + u64(t.n)); !ok {
			return t, false
		}
		cell.kind = .Number
		cell.spelling = 0
	}
	return cell, true
}

// Stores the span `lo` to `hi` of the text at `dest` as a `Raw`, borrowed or copied as the read keeps strings.
@(private)
store_raw :: proc "contextless" (h: ^Reader, lo, hi: u64, dest: uintptr) -> bool {
	_, ok := store_text(h, {lo = lo, n = u32(hi - lo), kind = .String, role = .Value}, dest, false)
	return ok
}

// Reads the element of wrapper `rec` at `dest`, and sets the frame the element opens, if any, to return to this record.
@(private)
wrapped :: proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token, rec: ^Record, m: ^Meta, dest: uintptr, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number, $CELLS: bool) -> (hook.Regs, hook.Action) {
	context = h.ctx
	s := s
	first := rec.first
	target := dest
	made := false
	#partial switch rec.kind {
	case .Maybe:
		if t.kind == .Null {
			intrinsics.mem_zero(rawptr(dest), int(m.size))
			write_size(dest + uintptr(m.tag), 0, int(m.tag_size))
			s.c += u64(rec.stride)
			return s, .Next
		}
		if read_size(dest + uintptr(m.tag), int(m.tag_size)) == 0 {
			intrinsics.mem_zero(rawptr(dest), int(m.size))
			write_size(dest + uintptr(m.tag), 1, int(m.tag_size))
		}
	case .Ptr:
		if t.kind == .Null {
			(^rawptr)(dest)^ = nil
			s.c += u64(rec.stride)
			return s, .Next
		}
		if (^rawptr)(dest)^ == nil {
			block, err := runtime.mem_alloc(max(int(m.size), 1), int(m.align), h.allocator)
			if err != nil {
				return refuse_memory(h, s, t)
			}
			(^rawptr)(dest)^ = raw_data(block)
			made = true
		}
		target = uintptr((^rawptr)(dest)^)
	case .Union:
		arms := h.plan.arms[m.arms:][:m.count]
		if t.kind == .Null {
			// A union with a nil numbers its arms from 1.
			if arms[0].tag == 0 {
				return refuse_value(h, s, t, .No_Arm)
			}
			intrinsics.mem_zero(rawptr(dest), int(m.size))
			s.c += u64(rec.stride)
			return s, .Next
		}
		arm := pick_arm(h, t, arms)
		if arm == nil {
			return refuse_value(h, s, t, .No_Arm)
		}
		if read_size(dest + uintptr(m.tag), int(m.tag_size)) != u64(arm.tag) {
			intrinsics.mem_zero(rawptr(dest), int(m.size))
			write_size(dest + uintptr(m.tag), u64(arm.tag), int(m.tag_size))
		}
		first = &h.plan.records[arm.first]
	}
	sp, outer := h.sp, h.outer
	if outer == nil {
		h.outer = &s
	}
	inner, action := reader_hook(h, {NO_LIMIT, u64(uintptr(first)), u64(target)}, t, number, CELLS)
	h.outer = outer
	if h.dead {
		// The element was refused whole, so a pointer made for it is taken back, as a list does not count its place.
		if made {
			runtime.mem_free_with_size(rawptr(target), max(int(m.size), 1), h.allocator)
			(^rawptr)(dest)^ = nil
		}
		return inner, action
	}
	if h.sp == sp {
		s.c += u64(rec.stride)
		return s, action
	}
	// The element's frame holds the element's registers, and its close must give back this record's.
	f := &h.frames[sp]
	if elem := (^Record)(uintptr(f.b) - size_of(Record)); !wrapper(elem.kind) {
		f.owner, f.target = elem, uintptr(f.c) + uintptr(elem.offset)
	}
	f.a, f.b, f.c = s.a, s.b, s.c
	return inner, action
}

// The arm of a union that takes a value of token `t`'s class, nil for none. A delimited text's cell is a string, and a
// byte string goes to a list of `u8`.
@(private)
pick_arm :: proc "contextless" (h: ^Reader, t: tape.Token, arms: []Arm) -> ^Arm {
	class: Class
	#partial switch t.kind {
	case .True, .False:
		class = .Bool
	case .Number:
		class = .Number
	case .String, .Plain:
		class = .String
	case .Object:
		class = .Object
	case .Array:
		class = .Array
	case .Bytes:
		class = .Bytes
	case:
		return nil
	}
	for &arm in arms {
		if class in arm.classes {
			return &arm
		}
	}
	return nil
}

// Reads the `size` bytes at `at` as an unsigned integer.
@(private)
read_size :: proc "contextless" (at: uintptr, size: int) -> u64 {
	switch size {
	case 1: return u64((^u8)(at)^)
	case 2: return u64((^u16)(at)^)
	case 4: return u64((^u32)(at)^)
	case 8: return (^u64)(at)^
	}
	return 0
}

// Writes the low `size` bytes of `v` at `at`.
@(private)
write_size :: proc "contextless" (at: uintptr, v: u64, size: int) {
	switch size {
	case 1: (^u8)(at)^ = u8(v)
	case 2: (^u16)(at)^ = u16(v)
	case 4: (^u32)(at)^ = u32(v)
	case 8: (^u64)(at)^ = v
	}
}

// A number the hot store did not take: an integer past `i64` or out of the field's range, a decimal for an integer, a
// float `f32` may round twice, or one past binary64.
@(private)
number_cold :: #force_no_inline proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token, n: spell.Number) -> (hook.Regs, hook.Action) {
	s := s
	rec := (^Record)(uintptr(s.b) - size_of(Record))
	dest := uintptr(s.c) + uintptr(rec.offset)
	buf: [128]u8 = ---
	text, held, ok := token_text(h, t, buf[:])
	if !ok {
		return refuse_memory(h, s, t)
	}
	detail: Refusal
	if rec.kind <= .U64 {
		detail = store_integer(n, true, text, rec.kind, dest)
	} else {
		detail = store_float(h, n, text, rec.kind == .F32, dest)
	}
	free_held(h, held)
	if detail != .None {
		return refuse_value(h, s, t, detail)
	}
	s.c += u64(rec.stride)
	return s, .Next
}

// Stores number `n`, spelled `text`, as an integer of `kind` at `dest`. A text that spells a fraction or an exponent is
// no integer, and one past what the type holds is refused on the side of its sign.
@(private)
store_integer :: proc "contextless" (n: spell.Number, ok: bool, text: string, kind: Read_Kind, dest: uintptr) -> Refusal {
	if !ok || !integer_text(text) {
		return .Expected_Integer
	}
	minus := len(text) > 0 && text[0] == '-'
	switch n.kind {
	case .Int:
		v := i64(n.bits)
		if v < INT_LO[kind] {
			return .Below_Minimum
		}
		if v > INT_HI[kind] {
			return .Above_Maximum
		}
	case .Uint:
		if kind != .U64 {
			return .Above_Maximum
		}
	case .Float, .Wide:
		// A format that reads an integer of a word as a float holds it as a fraction, as CBOR's bigfloat.
		if word_digits(text, minus) {
			return .Expected_Integer
		}
		return .Below_Minimum if minus else .Above_Maximum
	}
	write_int(dest, n.bits, kind)
	return .None
}

// Whether the decimal digits of `text` after its sign spell a value of `i64` or `u64`, `minus` saying its sign.
@(private)
word_digits :: proc "contextless" (text: string, minus: bool) -> bool {
	t := text[1:] if len(text) > 0 && (text[0] == '-' || text[0] == '+') else text
	v: u64
	for c in transmute([]u8)t {
		if c < '0' || c > '9' || v > (max(u64) - u64(c - '0')) / 10 {
			return false
		}
		v = v * 10 + u64(c - '0')
	}
	return len(t) > 0 && (!minus || v <= 1 << 63)
}

// Whether a number's text spells an integer: digits with a sign, or a radix prefix.
@(private)
integer_text :: proc "contextless" (text: string) -> bool {
	t := text
	if len(t) > 0 && (t[0] == '-' || t[0] == '+') {
		t = t[1:]
	}
	if len(t) > 2 && t[0] == '0' && (t[1] == 'x' || t[1] == 'o' || t[1] == 'b') {
		return true
	}
	for c in transmute([]u8)t {
		if (c < '0' || c > '9') && c != '_' {
			return false
		}
	}
	return len(t) > 0
}

// Stores number `n`, spelled `text`, as an `f32` when `narrow`, else an `f64`, at `dest`. A value past binary64, or past
// `f32` for one, is refused, and a format's own infinity and NaN are taken.
@(private)
store_float :: proc "contextless" (h: ^Reader, n: spell.Number, text: string, narrow: bool, dest: uintptr) -> Refusal {
	context = h.ctx
	minus := len(text) > 0 && text[0] == '-'
	x: f64
	switch n.kind {
	case .Int:
		x = f64(i64(n.bits))
		// `-0` is the integer 0, and a float keeps its sign.
		if n.bits == 0 && minus {
			x = -x
		}
	case .Uint:
		x = f64(n.bits)
	case .Float:
		x = transmute(f64)n.bits
	case .Wide:
		parsed, ok := strconv.parse_f64(text)
		if !ok || abs(parsed) > max(f64) {
			return .Below_Minimum if minus else .Above_Maximum
		}
		x = parsed
	}
	if !narrow {
		(^f64)(dest)^ = x
		return .None
	}
	v := f32(x)
	// An integer rounds to `f32` once, from its own value.
	if n.kind == .Int && n.bits != 0 {
		v = f32(i64(n.bits))
	} else if n.kind == .Uint {
		v = f32(n.bits)
	}
	if n.kind == .Float && .Binary not_in h.format.caps && f32_double_rounds(x) {
		// Rounds the decimal once. Past `max(f32)` it is infinity, refused below.
		v, _ = strconv.parse_f32(text)
	}
	if abs(v) > max(f32) && abs(x) <= max(f64) {
		return .Below_Minimum if v < 0 else .Above_Maximum
	}
	(^f32)(dest)^ = v
	return .None
}

// Stores an enum value of `m`'s type at `dest`: a member's name, or under `Plan_Options.enums` `.Int` a member's value.
@(private)
store_enum :: proc "contextless" (h: ^Reader, t: tape.Token, m: ^Meta, dest: uintptr, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> Refusal {
	v, detail := enum_value(h, t, m.enum_info, number)
	if detail == .None {
		write_size(dest, u64(v), int(m.size))
	}
	return detail
}

// The value of the member of enum `info` that token `t` names, by name or under `.Int` by value.
@(private)
enum_value :: proc "contextless" (h: ^Reader, t: tape.Token, info: ^runtime.Type_Info_Enum, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> (i64, Refusal) {
	if h.plan.options.enums == .Int {
		if t.kind != .Number {
			return 0, .Expected_Integer
		}
		n := number(h.base[:h.len], t)
		if n.kind != .Int {
			return 0, .Not_A_Member
		}
		for x in info.values {
			if i64(x) == i64(n.bits) {
				return i64(n.bits), .None
			}
		}
		return 0, .Not_A_Member
	}
	if t.kind != .String && t.kind != .Plain {
		return 0, .Expected_Name
	}
	buf: [128]u8 = ---
	text, held, ok := token_text(h, t, buf[:])
	if !ok {
		return 0, .Not_A_Member
	}
	defer free_held(h, held)
	for name, i in info.names {
		if name == text {
			return i64(info.values[i]), .None
		}
	}
	return 0, .Not_A_Member
}

// Stores enum `info`'s member named `text` as `size` bytes at `dest`, for a map's key.
@(private)
store_enum_name :: proc "contextless" (h: ^Reader, info: ^runtime.Type_Info_Enum, text: string, dest: uintptr, size: int) -> Refusal {
	for name, i in info.names {
		if h.plan.options.enums == .Name && name == text || h.plan.options.enums == .Int && enum_text(text) == i64(info.values[i]) {
			write_size(dest, u64(info.values[i]), size)
			return .None
		}
	}
	return .Not_A_Member
}

// The integer a map key's `text` spells, or a value no enum holds when it spells none.
@(private)
enum_text :: proc "contextless" (text: string) -> i64 {
	n, ok := spell.number_strict(transmute([]u8)text, 0, u64(len(text)))
	return i64(n.bits) if ok && n.kind == .Int else min(i64)
}

// Sets the element token `t` names in the bit set at `dest`: a member's name or value, or an integer of its range.
@(private)
store_bit :: proc "contextless" (h: ^Reader, t: tape.Token, m: ^Meta, dest: uintptr, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> Refusal {
	v: i64
	if m.enum_info != nil {
		detail: Refusal
		if v, detail = enum_value(h, t, m.enum_info, number); detail != .None {
			return detail
		}
	} else {
		if t.kind != .Number {
			return .Expected_Integer
		}
		n := number(h.base[:h.len], t)
		v = i64(n.bits)
		if n.kind != .Int {
			// The number's text tells an integer past `i64` from a fraction.
			buf: [128]u8 = ---
			text, held, ok := token_text(h, t, buf[:])
			if !ok {
				return .Expected_Integer
			}
			detail := store_integer(n, true, text, .I64, uintptr(&v))
			free_held(h, held)
			if detail != .None {
				return detail
			}
		}
	}
	bit := v - m.lower
	if bit < 0 {
		return .Below_Minimum
	}
	if bit >= i64(m.count) {
		return .Above_Maximum
	}
	(^u8)(dest + uintptr(bit / 8))^ |= 1 << uint(bit % 8)
	return .None
}

// Stores a `time.Time` at `dest`: an RFC 3339 date-time with an offset, in UTC, a space taken for its `T`, or a number of
// seconds since the Unix epoch, as CBOR's tag 1 holds.
@(private)
store_time :: proc "contextless" (h: ^Reader, t: tape.Token, dest: uintptr, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> Refusal {
	#partial switch t.kind {
	case .Number:
		n := number(h.base[:h.len], t)
		x := f64(i64(n.bits)) if n.kind == .Int else transmute(f64)n.bits if n.kind == .Float else max(f64)
		if n.kind == .Uint || abs(x) >= f64(max(i64)) / 1e9 {
			return .Out_Of_Range
		}
		if n.kind == .Int {
			(^time.Time)(dest)^ = {i64(n.bits) * 1e9}
		} else {
			(^time.Time)(dest)^ = {i64(x * 1e9)}
		}
		return .None
	case .String, .Plain:
		buf: [64]u8 = ---
		text, held, ok := token_text(h, t, buf[:])
		if !ok {
			return .Bad_Date_Time
		}
		defer free_held(h, held)
		utc, detail := date_time_nsec(text)
		if detail == .None {
			(^time.Time)(dest)^ = {utc}
		}
		return detail
	}
	return .Expected_Date_Time
}

// The nanoseconds since the Unix epoch in UTC of the RFC 3339 date-time `text`, a space taken for its `T`. A leap
// second is the second after it.
@(private)
date_time_nsec :: proc "contextless" (text: string) -> (i64, Refusal) {
	spaced: [64]u8 = ---
	s := text
	if len(s) > 10 && len(s) <= len(spaced) && s[10] == ' ' {
		intrinsics.mem_copy_non_overlapping(&spaced, raw_data(s), len(s))
		spaced[10] = 'T'
		s = string(spaced[:len(s)])
	}
	if !spell.is_date_time(s) {
		return 0, .Bad_Date_Time
	}
	digits :: proc "contextless" (s: string) -> i64 {
		n: i64
		for c in transmute([]u8)s {
			n = n * 10 + i64(c - '0')
		}
		return n
	}
	second := digits(s[17:19])
	nsec: i64
	rest := s[19:]
	if rest[0] == '.' {
		k := 1
		for k < len(rest) && rest[k] >= '0' && rest[k] <= '9' {
			if k <= 9 {
				nsec = nsec * 10 + i64(rest[k] - '0')
			}
			k += 1
		}
		for _ in k ..< 10 {
			nsec *= 10
		}
		rest = rest[k:]
	}
	offset: i64
	if rest[0] == '+' || rest[0] == '-' {
		offset = (digits(rest[1:3]) * 60 + digits(rest[4:6])) * (1 if rest[0] == '+' else -1)
	}
	t, in_range := time.components_to_time(digits(s[:4]), digits(s[5:7]), digits(s[8:10]), digits(s[11:13]), digits(s[14:16]), min(second, 59), nsec)
	utc, past := intrinsics.overflow_sub(t._nsec, offset * i64(time.Minute))
	if second == 60 && !past {
		utc, past = intrinsics.overflow_add(utc, i64(time.Second))
	}
	if !in_range || past {
		return 0, .Out_Of_Range
	}
	return utc, .None
}
