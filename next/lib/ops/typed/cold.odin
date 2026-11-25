package typed

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The read's cold paths: a map's keys, the kinds the hook's hot cases do not take, the growth of lists and frames,
// and the closes that check or publish.

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
	if h.path != nil {
		note_map_key(h, h.sp - 1, t)
	}
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
		detail: Typed_Refusal
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
	met := false
	if f.seen != 0 {
		err: runtime.Allocator_Error
		if met, err = first_met(h, f, key_span(h, t)); err != nil {
			free_held(h, owned)
			return refuse_memory(h, s, t)
		}
		if met && .First in h.flags {
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
		if .First in h.flags && f.seen == 0 {
			return s, .Skip
		}
		// An entry of a map empty at its open, or one this object met before, is this read's, so a repeat frees what
		// the earlier one allocated, and an entry the target held is replaced whole.
		if f.seen != 0 && !met {
			intrinsics.mem_zero(slot, int(m.map_info.vs.size_of_type))
		} else if !reset(h, (^Record)(uintptr(owner.first) - size_of(Record)), uintptr(slot), false) {
			return refuse_memory(h, s, t)
		}
	}
	h.key = k
	if inserted {
		h.flags += {.Fresh}
	} else {
		h.flags -= {.Fresh}
	}
	s.c = u64(uintptr(slot))
	return s, .Next
}

// Records the last key `t` of the open map at frame `idx` when `h.path != nil`. A refusal to grow leaves the slot
// unrecorded, matching `fill_path`.
@(private = "file", cold)
note_map_key :: #force_no_inline proc "contextless" (h: ^Reader, idx: int, t: tape.Token) {
	if idx >= len(h.map_keys) {
		context = h.ctx
		alloc := h.path.allocator if h.path.allocator.procedure != nil else h.caller
		wide := max(16, max(len(h.map_keys) * 2, idx + 1))
		block, err := runtime.non_zero_mem_resize(raw_data(h.map_keys), len(h.map_keys) * size_of(tape.Token), wide * size_of(tape.Token), align_of(tape.Token), alloc)
		if err != nil || len(block) < wide * size_of(tape.Token) {
			return
		}
		h.map_keys = ([^]tape.Token)(raw_data(block))[:wide]
	}
	h.map_keys[idx] = t
}

// Gives the open list room for one more element, or refuses the element of a fixed array that has none. A refused read
// answers every value here, as its registers have no room.
@(private, cold)
grow_list :: #force_no_inline proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action, bool) {
	context = h.ctx
	if .Dead in h.flags {
		return dead_regs(), dead_action(t), false
	}
	f := &h.frames[h.sp - 1]
	owner := frame_owner(f)
	if owner.kind != .Slice && owner.kind != .Dynamic {
		r, a := refuse_value(h, s, t, .Too_Many)
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

// Doubles the frames the read holds through the read's allocator, false when memory is refused.
@(private, cold)
frames_grow :: #force_no_inline proc "contextless" (h: ^Reader) -> bool {
	if h.room > max(int) / (2 * size_of(Frame)) {
		return false
	}
	context = h.ctx
	wide := h.room * 2
	grown := h.frames != h.home
	block: []u8
	err: runtime.Allocator_Error
	if grown {
		block, err = runtime.non_zero_mem_resize(h.frames, h.room * size_of(Frame), wide * size_of(Frame), align_of(Frame), h.allocator)
	} else {
		block, err = runtime.mem_alloc_non_zeroed(wide * size_of(Frame), align_of(Frame), h.allocator)
	}
	if err != nil || len(block) < wide * size_of(Frame) {
		return false
	}
	if !grown {
		intrinsics.mem_copy_non_overlapping(raw_data(block), h.frames, h.room * size_of(Frame))
	}
	h.frames, h.room = ([^]Frame)(raw_data(block)), wide
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
	if .Dead in h.flags {
		h.sp = 1
		return dead_regs(), .Next
	}
	own := (^Record)(uintptr(f.b) - size_of(Record))
	owner := frame_owner(f)
	back := hook.Regs{f.a, f.b, f.c + u64(own.stride)}
	#partial switch owner.kind {
	case .Struct, .Required:
		missing := -1
		if f.seen & SEEN_ON != 0 {
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
@(private, cold)
indirect :: #force_no_inline proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number, $CELLS: bool) -> (hook.Regs, hook.Action) {
	s := s
	rec := (^Record)(uintptr(s.b) - size_of(Record))
	if rec.kind == .Dead {
		return s, dead_action(t)
	}
	if rec.kind == .Position {
		return positional(h, s, t, number, CELLS)
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
	held := h.frames[h.sp - 1].seen & SEEN_TARGET
	when CELLS {
		if t.kind == .Null {
			// An empty cell is absent: it leaves a list's element zero, a map no entry, and a `required` member missing.
			f := &h.frames[h.sp - 1]
			if m.must {
				return refuse_at(h, s, t, .Missing_Field, t.lo, h.sp, nil, member_name(h, m))
			} else if rec.stride != 0 {
				intrinsics.mem_zero(rawptr(dest), int(rec.stride))
			} else if frame_owner(f).kind == .Map && .Fresh in h.flags {
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
	detail := Typed_Refusal.None
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
	case .Struct, .Required:
		// A binary format writes a struct as an array of its members in order too, and a delimited record with no
		// header is one.
		if t.kind != .Array || !CELLS && .Binary not_in h.format.caps {
			detail = .Expected_Object
			break
		}
		f, ok := push(h, s, nil)
		if !ok {
			return refuse_memory(h, s, t)
		}
		f.seen = held
		if !seen_start(h, f, m) {
			return refuse_memory(h, s, t)
		}
		return {NO_LIMIT, u64(uintptr(&POSITION_BLOCK[1])), u64(dest)}, .Next
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
		f, ok := push(h, s, rawptr(dest))
		if !ok {
			return refuse_memory(h, s, t)
		}
		f.seen = held
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
		// A map that holds entries at its open tracks the keys `.First` met in a set of its own. One with a block is the
		// target's, as the read makes a map empty.
		f.seen = u64((^runtime.Raw_Map)(dest).len != 0)
		if .First not_in h.flags && runtime.map_data((^runtime.Raw_Map)(dest)^) != 0 && !hold_map(h, dest, m.map_info) {
			return refuse_memory(h, s, t)
		}
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

// Reads element `t` of an array a struct reads by position into the struct's next member, and passes an element past
// its last member. The frame's `run` counts the elements, and a container a member opens returns to the `Position`
// record, its frame naming its owner and destination.
@(private)
positional :: proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number, $CELLS: bool) -> (hook.Regs, hook.Action) {
	s := s
	f := &h.frames[h.sp - 1]
	owner := frame_owner(f)
	i := int(f.run)
	f.run += 1
	if i >= int(h.plan.meta[owner.meta].count) {
		if t.kind != .Array && t.kind != .Object {
			return s, .Next
		}
		passed, ok := push(h, s, nil)
		if !ok {
			return refuse_memory(h, s, t)
		}
		passed.owner = &POSITION_BLOCK[0]
		return s, .Skip
	}
	seen_set(f, i)
	member := &([^]Record)(owner.first)[i]
	sp, outer := h.sp, h.outer
	if outer == nil {
		h.outer = &s
	}
	inner, action := reader_hook(h, {NO_LIMIT, u64(uintptr(member)) + size_of(Record), s.c}, t, number, CELLS)
	h.outer = outer
	if .Dead in h.flags {
		return inner, action
	}
	if h.sp != sp {
		opened := &h.frames[sp]
		if !wrapper(member.kind) {
			opened.owner, opened.target = member, uintptr(s.c) + uintptr(member.offset)
		}
		opened.a, opened.b, opened.c = s.a, s.b, s.c
		return inner, action
	}
	return s, action
}

// The detail of a value of the wrong kind for a record of `kind`.
@(private)
expected :: proc "contextless" (kind: Read_Kind) -> Typed_Refusal {
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

// Reads the element of wrapper `rec` at `dest`, and sets the frame the element opens, if any, to return to this record.
@(private)
wrapped :: proc "contextless" (h: ^Reader, s: hook.Regs, t: tape.Token, rec: ^Record, m: ^Meta, dest: uintptr, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number, $CELLS: bool) -> (hook.Regs, hook.Action) {
	context = h.ctx
	s := s
	first := rec.first
	target := dest
	// The element is one the read made, a pointer's new block or a zeroed one, so it holds nothing of the target's.
	made, zeroed := false, false
	// The tag a `Maybe` or a union takes for a scalar, written once the scalar is read, so a refused one leaves the
	// wrapper as it was. A container's is written at its open.
	tag := max(u64)
	scalar := t.kind != .Object && t.kind != .Array
	#partial switch rec.kind {
	case .Maybe:
		if t.kind == .Null {
			intrinsics.mem_zero(rawptr(dest), int(m.size))
			if m.tag_size != 0 {
				write_size(dest + uintptr(m.tag), 0, int(m.tag_size))
			}
			s.c += u64(rec.stride)
			return s, .Next
		}
		if m.tag_size != 0 && read_size(dest + uintptr(m.tag), int(m.tag_size)) == 0 {
			if scalar {
				tag = 1
			} else {
				intrinsics.mem_zero(rawptr(dest), int(m.size))
				write_size(dest + uintptr(m.tag), 1, int(m.tag_size))
				zeroed = true
			}
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
		} else if .First not_in h.flags && !hold_pointee(h, uintptr((^rawptr)(dest)^), int(m.size)) {
			return refuse_memory(h, s, t)
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
		first = &h.plan.records[arm.first]
		if read_size(dest + uintptr(m.tag), int(m.tag_size)) != u64(arm.tag) {
			if scalar {
				tag = u64(arm.tag)
			} else {
				intrinsics.mem_zero(rawptr(dest), int(m.size))
				write_size(dest + uintptr(m.tag), u64(arm.tag), int(m.tag_size))
				zeroed = true
			}
		}
	}
	sp, outer := h.sp, h.outer
	if outer == nil {
		h.outer = &s
	}
	inner, action := reader_hook(h, {NO_LIMIT, u64(uintptr(first)), u64(target)}, t, number, CELLS)
	h.outer = outer
	if .Dead in h.flags {
		// The element was refused whole, so a pointer made for it is taken back, as a list does not count its place.
		if made {
			runtime.mem_free_with_size(rawptr(target), max(int(m.size), 1), h.allocator)
			(^rawptr)(dest)^ = nil
		}
		return inner, action
	}
	if h.sp == sp {
		if tag != max(u64) {
			// The bytes past the scalar may hold another arm's.
			size := type_info_of(h.plan.meta[([^]Record)(first)[-1].meta].type).size
			intrinsics.mem_zero(rawptr(dest + uintptr(size)), int(m.size) - size)
			write_size(dest + uintptr(m.tag), tag, int(m.tag_size))
		}
		s.c += u64(rec.stride)
		return s, action
	}
	// The element's frame holds the element's registers, and its close must give back this record's.
	f := &h.frames[sp]
	if elem := (^Record)(uintptr(f.b) - size_of(Record)); !wrapper(elem.kind) {
		f.owner, f.target = elem, uintptr(f.c) + uintptr(elem.offset)
		// A struct or fixed array in place takes the frame below's `SEEN_TARGET`, and one the target's pointer holds is
		// the target's.
		if elem.kind == .Struct || elem.kind == .Required || elem.kind == .Array {
			if made || zeroed {
				f.seen &~= SEEN_TARGET
			} else if rec.kind == .Ptr {
				f.seen |= SEEN_TARGET
			}
		}
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
