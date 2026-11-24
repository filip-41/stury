package typed

import "base:intrinsics"
import "base:runtime"

// A repeated key: what its first value held is released, and the target's own bytes set back.

// Resets record `rec`'s value at `dest` before a repeat reads it again: what the read put in it is freed, and it is set
// back to the bytes the target held, or zeroed when the read made it, so its later occurrence reads as if alone. `held`
// says the bytes at `dest` may be the target's or a block's it held. False when memory to free a deep value is refused,
// which leaves it allocated.
@(private)
reset :: proc "contextless" (h: ^Reader, rec: ^Record, dest: uintptr, held: bool) -> bool {
	ok := true
	was := held_bytes(h, dest) if held else 0
	if h.plan.meta[rec.meta].frees {
		ok = release(h, rec, dest, was) == nil
	}
	size := type_info_of(h.plan.meta[rec.meta].type).size
	if was != 0 {
		intrinsics.mem_copy_non_overlapping(rawptr(dest), rawptr(was), size)
	} else {
		intrinsics.mem_zero(rawptr(dest), size)
	}
	return ok
}

// Where the bytes at `at` were as the target held them: in `before` for the target's own, in a `Held` for a pointee it
// held, 0 when the read made them.
@(private)
held_bytes :: proc "contextless" (h: ^Reader, at: uintptr) -> uintptr {
	if k := at - h.target; k < uintptr(len(h.before)) {
		return uintptr(raw_data(h.before)) + k
	}
	for b in h.held {
		if k := at - b.at; k < uintptr(len(b.bytes)) {
			return uintptr(raw_data(b.bytes)) + k
		}
	}
	return 0
}

// The `Held` of the pointee or map at `at`, nil when the read keeps none.
@(private)
held_of :: proc "contextless" (h: ^Reader, at: uintptr, is_map: bool) -> ^Held {
	for &b in h.held {
		if b.at == at && (b.info != nil) == is_map {
			return &b
		}
	}
	return nil
}

// Keeps the `size` bytes of the pointee at `p` the target held, once, before the read goes into it. False when memory is
// refused.
@(private)
hold_pointee :: proc "contextless" (h: ^Reader, p: uintptr, size: int) -> bool {
	context = h.ctx
	if held_of(h, p, false) != nil {
		return true
	}
	bytes, err := runtime.mem_alloc_non_zeroed(size, 1, h.allocator)
	if err != nil {
		return false
	}
	intrinsics.mem_copy_non_overlapping(raw_data(bytes), rawptr(p), size)
	if h.held == nil {
		h.held.allocator = h.allocator
	}
	if _, err = append(&h.held, Held{at = p, bytes = bytes}); err != nil {
		runtime.mem_free_with_size(raw_data(bytes), size, h.allocator)
		return false
	}
	return true
}

// Keeps a copy of the entries of the map at `at` the target held, once, before the read goes into it, so a repeat tells
// the target's entries from the read's. False when memory is refused.
@(private)
hold_map :: proc "contextless" (h: ^Reader, at: uintptr, info: ^runtime.Map_Info) -> bool {
	context = h.ctx
	if held_of(h, at, true) != nil {
		return true
	}
	raw := (^runtime.Raw_Map)(at)^
	entries, err := runtime.map_alloc_dynamic(info, runtime.map_log2_cap(raw), h.allocator)
	if err != nil {
		return false
	}
	runtime.map_rehash_dynamic(raw, &entries, info)
	entries.len = raw.len
	if h.held == nil {
		h.held.allocator = h.allocator
	}
	if _, err = append(&h.held, Held{at = at, entries = entries, info = info}); err != nil {
		_ = runtime.map_free_dynamic(entries, info)
		return false
	}
	return true
}

// Frees the copies `Reader.held` keeps.
@(private)
held_free :: proc "contextless" (h: ^Reader) {
	context = h.ctx
	for b in h.held {
		if b.info == nil {
			runtime.mem_free_with_size(raw_data(b.bytes), len(b.bytes), h.allocator)
		} else {
			_ = runtime.map_free_dynamic(b.entries, b.info)
		}
	}
	delete(h.held)
}

// Takes out of the map `rec` at `at`, which the target held, what the read put in it: an entry it added is erased with
// what it holds, and an entry the target held is set back to its value, whose copy `entries` keeps.
@(private)
held_map_reset :: proc(h: ^Reader, rec: ^Record, at: uintptr, entries: ^runtime.Raw_Map) -> runtime.Allocator_Error {
	m := &h.plan.meta[rec.meta]
	info := m.map_info
	raw := (^runtime.Raw_Map)(at)
	value := &([^]Record)(rec.first)[-1]
	frees := h.plan.meta[value.meta].frees
	added := make([dynamic][2]u64, h.allocator)
	defer delete(added)
	ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(raw^, info)
	seed := runtime.map_seed(entries^)
	for i in 0 ..< uintptr(runtime.map_cap(raw^)) {
		if !runtime.map_hash_is_valid(hs[i]) {
			continue
		}
		k, v := runtime.map_cell_index_dynamic(ks, info.ks, i), runtime.map_cell_index_dynamic(vs, info.vs, i)
		if was := runtime.__dynamic_map_get(entries, info, info.key_hasher(rawptr(k), seed), rawptr(k)); was != nil {
			if frees {
				release(h, value, v, uintptr(was)) or_return
			}
			intrinsics.mem_copy_non_overlapping(rawptr(v), was, int(info.vs.size_of_type))
			continue
		}
		if frees {
			release(h, value, v, 0) or_return
		}
		key: [2]u64
		intrinsics.mem_copy_non_overlapping(&key, rawptr(k), int(info.ks.size_of_type))
		append(&added, key) or_return
	}
	for &key in added {
		if k, _, ok := runtime.map_erase_dynamic(raw, info, uintptr(&key)); ok && m.key_kind == .String {
			release_text(h, k)
		}
	}
	return nil
}

// A step of `release`: a value to free what it holds, a block or a map's cells to free, or a pointee to set back.
@(private)
Release :: struct {
	rec:  ^Record,
	at:   uintptr,
	was:  uintptr, // the value's bytes as the target held them, 0 for a value the read made
	size: int, // a block's, or the bytes `Back` copies
	step: Release_Step,
}

@(private)
Release_Step :: enum u8 {
	Value,
	Block,
	Cells,
	Back, // copies the bytes at `was` to `at`
}

// Frees what the read allocated in value `rec` at `at`, which held the bytes at `was` before the read, or which the read
// made when `was` is 0: in a value the target held only what differs from its bytes, as a string or list the read
// stored, is the read's.
// Fails when memory for the steps is refused.
@(private)
release :: proc "contextless" (h: ^Reader, rec: ^Record, at, was: uintptr) -> runtime.Allocator_Error {
	context = h.ctx
	steps := make([dynamic]Release, 0, 16, h.allocator)
	defer delete(steps)
	append(&steps, Release{rec = rec, at = at, was = was}) or_return
	for len(steps) > 0 {
		r := pop(&steps)
		switch r.step {
		case .Block:
			free_block(h, rawptr(r.at), r.size)
		case .Cells:
			raw := (^runtime.Raw_Map)(r.at)^
			raw.allocator = h.allocator
			_ = runtime.map_free_dynamic(raw, h.plan.meta[r.rec.meta].map_info)
		case .Back:
			intrinsics.mem_copy_non_overlapping(rawptr(r.at), rawptr(r.was), r.size)
		case .Value:
			release_value(h, &steps, r) or_return
		}
	}
	return nil
}

// Adds the steps that free what value `r` holds.
@(private)
release_value :: proc(h: ^Reader, steps: ^[dynamic]Release, r: Release) -> runtime.Allocator_Error {
	rec, at, was := r.rec, r.at, r.was
	m := &h.plan.meta[rec.meta]
	same :: proc "contextless" (at, was: uintptr, n: int) -> bool {
		return was != 0 && runtime.memory_compare(rawptr(at), rawptr(was), n) == 0
	}
	#partial switch rec.kind {
	case .String, .Raw:
		if text := (^runtime.Raw_String)(at)^; text.len != 0 && !same(at, was, size_of(string)) {
			free_block(h, text.data, text.len)
		}
	case .Slice, .Dynamic:
		list := (^runtime.Raw_Dynamic_Array)(at)
		if list.data == nil || same(at, was, size_of(rawptr)) {
			return nil
		}
		room := list.cap if rec.kind == .Dynamic else 0
		append(steps, Release{at = uintptr(list.data), size = room * int(m.size), step = .Block}) or_return
		elem := ([^]Record)(rec.first)[-1:]
		if h.plan.meta[elem[0].meta].frees {
			for i in 0 ..< list.len {
				append(steps, Release{rec = &elem[0], at = uintptr(list.data) + uintptr(i * int(m.size))}) or_return
			}
		}
	case .Map:
		raw := (^runtime.Raw_Map)(at)^
		if runtime.map_data(raw) == 0 {
			return nil
		}
		if b := held_of(h, at, true); b != nil {
			// A map the target held keeps its blocks and the target's entries, and the header it has now, as an insert
			// may have moved its cells.
			held_map_reset(h, rec, at, &b.entries) or_return
			if was != 0 {
				(^runtime.Raw_Map)(was)^ = (^runtime.Raw_Map)(at)^
			}
			return nil
		}
		if was != 0 && runtime.map_data((^runtime.Raw_Map)(was)^) == runtime.map_data(raw) {
			return nil
		}
		append(steps, Release{rec = rec, at = at, step = .Cells}) or_return
		value := ([^]Record)(rec.first)[-1:]
		ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(raw, m.map_info)
		for i in 0 ..< uintptr(runtime.map_cap(raw)) {
			if !runtime.map_hash_is_valid(hs[i]) {
				continue
			}
			if m.key_kind == .String {
				key := (^runtime.Raw_String)(runtime.map_cell_index_dynamic(ks, m.map_info.ks, i))^
				free_block(h, key.data, key.len)
			}
			if h.plan.meta[value[0].meta].frees {
				append(steps, Release{rec = &value[0], at = runtime.map_cell_index_dynamic(vs, m.map_info.vs, i)}) or_return
			}
		}
	case .Ptr:
		p := (^rawptr)(at)^
		if p == nil {
			return nil
		}
		if was != 0 && (^rawptr)(was)^ == p {
			// A pointee the target held is set back once what the read put in it is freed.
			if b := held_of(h, uintptr(p), false); b != nil {
				append(steps, Release{at = uintptr(p), was = uintptr(raw_data(b.bytes)), size = len(b.bytes), step = .Back}) or_return
				append(steps, Release{rec = &([^]Record)(rec.first)[-1], at = uintptr(p), was = uintptr(raw_data(b.bytes))}) or_return
			}
			return nil
		}
		append(steps, Release{at = uintptr(p), size = max(int(m.size), 1), step = .Block}) or_return
		append(steps, Release{rec = &([^]Record)(rec.first)[-1], at = uintptr(p)}) or_return
	case .Struct, .Required:
		members := ([^]Record)(rec.first)[:m.count]
		for &member in members {
			if h.plan.meta[member.meta].frees {
				append(steps, Release{rec = &member, at = at + uintptr(member.offset), was = was + uintptr(member.offset) if was != 0 else 0}) or_return
			}
		}
	case .Array:
		elem := &([^]Record)(rec.first)[-1]
		for i in 0 ..< uintptr(m.count) {
			k := i * uintptr(m.size)
			append(steps, Release{rec = elem, at = at + k, was = was + k if was != 0 else 0}) or_return
		}
	case .Maybe:
		tag := read_size(at + uintptr(m.tag), int(m.tag_size))
		if tag != 0 {
			// An element the target did not hold was zeroed when the read gave it its tag.
			held := was != 0 && read_size(was + uintptr(m.tag), int(m.tag_size)) != 0
			append(steps, Release{rec = &([^]Record)(rec.first)[-1], at = at, was = was if held else 0}) or_return
		}
	case .Union:
		tag := read_size(at + uintptr(m.tag), int(m.tag_size))
		for arm in h.plan.arms[m.arms:][:m.count] {
			if u64(arm.tag) == tag {
				// An arm the target did not hold was zeroed when the read picked it.
				held := was != 0 && read_size(was + uintptr(m.tag), int(m.tag_size)) == tag
				append(steps, Release{rec = &h.plan.records[arm.first - 1], at = at, was = was if held else 0}) or_return
			}
		}
	}
	return nil
}

// Frees block `p` of `n` bytes, which the read allocated unless it lies in the text, as a borrowed span does.
@(private)
free_block :: proc "contextless" (h: ^Reader, p: rawptr, n: int) {
	context = h.ctx
	if p != nil && uintptr(p) - uintptr(h.base) >= uintptr(h.len) {
		runtime.mem_free_with_size(p, n, h.allocator)
	}
}

// Frees the text at `dest` when this read copied it, not when it is a span of the text.
@(private)
release_text :: proc "contextless" (h: ^Reader, dest: uintptr) {
	text := (^runtime.Raw_String)(dest)^
	if text.len != 0 {
		free_block(h, text.data, text.len)
	}
	(^runtime.Raw_String)(dest)^ = {}
}

// Whether a map's frame met key `key` before in this object, adding it when not. A map that held entries at its open
// keeps the keys it met in a set of its own, as an entry it holds may be the destination's.
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

// Frees the set of keys a map's frame met.
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
