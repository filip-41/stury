package scan

import "base:intrinsics"
import "base:runtime"

// `.Unique`'s memory of the keys of every open object (`Key_Set`): the first KEY_SCRATCH live keys sit in
// the scan entry's stack scratch, more spill to its allocator. A refused spill is `.Out_Of_Memory`.
//
// Indexing is unchecked and rests on the table's shape: `slots` holds `2 * cap` words, `cap` a power of
// two, so a probe masked by `2 * cap - 1` stays in range, and at most `cap` keys leave a free slot that ends
// every probe. An entry is written only at `n < cap` (the inline route's gate, or `key_set_grow` first), and
// a slot's low bits are its entry's index + 1. Slots start zeroed. Key bytes load as unchecked words:
// `key_hash_short` reads 16 bytes from the key's first, which the inline gate's `lo + 17 <= len(src)`
// proves, and `key_hash` reads whole words before the closing quote, then one more only while eight bytes
// remain in `src`. A differential test against the reference refuse law checks it.

KEY_SCRATCH :: 64

// The scan entry's scratch for a `Key_Set`. Gap-free, so it is declared `---`. `key_set_init` clears the slots.
Key_Scratch :: struct {
	entries: [KEY_SCRATCH]Key_Entry,
	slots:   [2 * KEY_SCRATCH]u32,
}

key_set_init :: proc(ks: ^Key_Set, scratch: ^Key_Scratch, allocator: runtime.Allocator) {
	scratch.slots = {}
	ks^ = Key_Set{entries = &scratch.entries[0], slots = &scratch.slots[0], cap = KEY_SCRATCH, allocator = allocator}
	// Per scan, so a document cannot be crafted to collide its keys.
	ks.seed = u64(intrinsics.read_cycle_counter())
}

key_set_destroy :: proc(ks: ^Key_Set) {
	if ks.spilled {
		free(ks.entries, ks.allocator)
		free(ks.slots, ks.allocator)
	}
}

// The key `src[lo:hi]` of the object at walk depth `depth`: false when it repeats one of that object's keys,
// decoded, else remembered. `oom` when it could not be remembered, and it is then not.
//
// Inline, for the common key: escape-free, at most 16 bytes, no key in the table with its hash and room for
// it. A call from the walk costs it more than the check.
key_set_add :: #force_inline proc(ks: ^Key_Set, src: []byte, lo, hi: u64, escaped: bool, depth: u32) -> (unique: bool, oom: bool) #no_bounds_check {
	n, slots := ks.n, ks.slots
	if !escaped && hi - lo <= 18 && lo + 17 <= u64(len(src)) && n < ks.cap {
		h := key_hash_short(src, lo, hi, depth, ks.seed)
		mask := 2 * ks.cap - 1
		i := h & mask
		for e := slots[i]; e == 0 || e &~ mask != h &~ mask; e = slots[i] {
			if e == 0 {
				ks.entries[n] = Key_Entry{lo = lo, hi = hi, hash = h, depth = depth}
				slots[i] = h &~ mask | (n + 1)
				ks.n = n + 1
				return true, false
			}
			i = (i + 1) & mask
		}
	}
	return key_set_add_probed(ks, src, lo, hi, escaped, depth)
}

// `key_set_add` for any key.
@(cold)
@(private = "file")
key_set_add_probed :: proc(ks: ^Key_Set, src: []byte, lo, hi: u64, escaped: bool, depth: u32) -> (unique: bool, oom: bool) #no_bounds_check {
	h := key_hash(src, lo, hi, escaped, depth, ks.seed)
	mask := 2 * ks.cap - 1
	i := h & mask
	for e := ks.slots[i]; e != 0; e = ks.slots[i] {
		if e &~ mask == h &~ mask {
			o := &ks.entries[e & mask - 1]
			if o.depth &~ KEY_ESCAPED == depth && key_tokens_equal(src, o^, lo, hi, escaped) {
				return false, false
			}
		}
		i = (i + 1) & mask
	}
	if ks.n == ks.cap {
		if !key_set_grow(ks, key_set_estimate(ks, lo, u64(len(src)))) {
			return true, true
		}
		mask = 2 * ks.cap - 1
		i = key_set_free_slot(ks, h)
	}
	ks.entries[ks.n] = Key_Entry{lo = lo, hi = hi, hash = h, depth = depth | (KEY_ESCAPED if escaped else 0)}
	ks.n += 1
	ks.slots[i] = h &~ mask | ks.n
	return true, false
}

// The object at walk depth `depth` closed: forget its keys, the newest entries.
key_set_close :: #force_inline proc(ks: ^Key_Set, depth: u32) #no_bounds_check {
	quarter := ks.cap / 4
	if ks.n >= quarter && ks.entries[ks.n - quarter].depth &~ KEY_ESCAPED == depth {
		key_set_close_wide(ks, depth)
		return
	}
	n, mask := ks.n, 2 * ks.cap - 1
	for n > 0 && ks.entries[n - 1].depth &~ KEY_ESCAPED == depth {
		i := ks.entries[n - 1].hash & mask
		for ks.slots[i] & mask != n {
			i = (i + 1) & mask
		}
		ks.slots[i] = 0
		n -= 1
	}
	ks.n = n
}

// `key_set_close` of an object holding a quarter of the table or more: the table is cleared whole and the
// older keys placed again, cheaper than finding each of the object's slots.
@(private = "file")
key_set_close_wide :: proc(ks: ^Key_Set, depth: u32) #no_bounds_check {
	// Depths only grow towards the newest entry: the object's first key is the first at its depth.
	lo, hi := u32(0), ks.n - ks.cap / 4
	for lo < hi {
		mid := (lo + hi) / 2
		if ks.entries[mid].depth &~ KEY_ESCAPED < depth {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	intrinsics.mem_zero(ks.slots, int(2 * ks.cap) * size_of(u32))
	ks.n = lo
	key_set_place_all(ks)
}

@(private = "file")
key_set_free_slot :: #force_inline proc(ks: ^Key_Set, h: u32) -> u32 #no_bounds_check {
	mask := 2 * ks.cap - 1
	i := h & mask
	for ks.slots[i] != 0 {
		i = (i + 1) & mask
	}
	return i
}

// Every live key into an empty table, in the order they were met, as if never removed.
@(private = "file")
key_set_place_all :: proc(ks: ^Key_Set) #no_bounds_check {
	mask := 2 * ks.cap - 1
	for k in 0 ..< ks.n {
		h := ks.entries[k].hash
		ks.slots[key_set_free_slot(ks, h)] = h &~ mask | (k + 1)
	}
}

// The room the set grows to when full at the key starting at `at` of `n` bytes: twice the room while the
// table is small, then the keys the rest of the document holds at the bytes per key so far, at least four and
// at most sixteen times the room. Fewer moves of every key, and shorter probes in a table that keeps growing.
@(private = "file")
key_set_estimate :: proc(ks: ^Key_Set, at, n: u64) -> u32 {
	if ks.cap < 512 {
		return 2 * ks.cap
	}
	rest := (n - at) / max(at / u64(ks.n), 1)
	return u32(min(clamp(u64(ks.n) + rest, 4 * u64(ks.cap), 16 * u64(ks.cap)), 1 << 31))
}

// Room for at least `want` keys, a power of two. Past 2^30 keys `2 * cap` slots no longer count in a u32, so
// the set refuses to grow.
@(cold)
@(private = "file")
key_set_grow :: proc(ks: ^Key_Set, want: u32) -> bool #no_bounds_check {
	if want > 1 << 30 {
		return false
	}
	cap := ks.cap
	for cap < want {
		cap *= 2
	}
	// The entries are copied over before any is read: no need to zero them.
	ebytes, eerr := runtime.mem_alloc_non_zeroed(int(cap) * size_of(Key_Entry), align_of(Key_Entry), ks.allocator)
	if eerr != nil {
		return false
	}
	entries := ([^]Key_Entry)(raw_data(ebytes))
	slots, serr := make([^]u32, 2 * cap, ks.allocator)
	if serr != nil {
		free(entries, ks.allocator)
		return false
	}
	intrinsics.mem_copy_non_overlapping(entries, ks.entries, int(ks.n) * size_of(Key_Entry))
	key_set_destroy(ks)
	ks.entries, ks.slots, ks.cap, ks.spilled = entries, slots, cap, true
	key_set_place_all(ks)
	return true
}

// A multiply-xor mix under a cycle-counter seed, not a keyed PRF.
//
// The hash under `seed` of a key's decoded text and its depth: its bytes taken eight at a time, little-endian,
// the last word zero-padded, then its length and the depth together. An escaped key's bytes are decoded first, so equal keys hash equal.
@(private = "file")
key_hash :: #force_inline proc(src: []byte, lo, hi: u64, escaped: bool, depth: u32, seed: u64) -> u32 #no_bounds_check {
	if escaped {
		return key_hash_escaped(src, lo, hi, depth, seed)
	}
	h := seed
	p, end := lo + 1, hi - 1
	for ; p + 8 <= end; p += 8 {
		h = key_mix(h, intrinsics.unaligned_load((^u64)(&src[p])))
	}
	if p < end {
		w: u64
		// Past the closing quote while eight bytes remain in `src`: one load, masked to the key's bytes.
		if p + 8 <= u64(len(src)) {
			w = intrinsics.unaligned_load((^u64)(&src[p])) & (u64(1) << (8 * (end - p)) - 1)
		} else {
			for k: u64 = 0; p + k < end; k += 1 {
				w |= u64(src[p + k]) << (8 * k)
			}
		}
		h = key_mix(h, w)
	}
	return u32(key_mix(h, end - lo - 1 | u64(depth) << 32))
}

// `key_hash` of an escape-free key of at most 16 bytes, with 16 bytes readable from its first: the same
// words, loaded without a loop.
@(private = "file")
key_hash_short :: #force_inline proc(src: []byte, lo, hi: u64, depth: u32, seed: u64) -> u32 #no_bounds_check {
	p, n := lo + 1, hi - lo - 2
	h := seed
	if n > 8 {
		h = key_mix(h, intrinsics.unaligned_load((^u64)(&src[p])))
		h = key_mix(h, intrinsics.unaligned_load((^u64)(&src[p + 8])) & (~u64(0) >> (128 - 8 * n)))
	} else if n > 0 {
		h = key_mix(h, intrinsics.unaligned_load((^u64)(&src[p])) & (~u64(0) >> (64 - 8 * n)))
	}
	return u32(key_mix(h, n | u64(depth) << 32))
}

@(private = "file")
key_hash_escaped :: proc(src: []byte, lo, hi: u64, depth: u32, seed: u64) -> u32 {
	h := seed
	n: u64
	it := Key_Bytes{p = lo + 1, end = hi - 1}
	w: u64
	k: u64
	for b in key_bytes_next(src, &it) {
		w |= u64(b) << (8 * k)
		k += 1
		n += 1
		if k == 8 {
			h = key_mix(h, w)
			w, k = 0, 0
		}
	}
	if k > 0 {
		h = key_mix(h, w)
	}
	return u32(key_mix(h, n | u64(depth) << 32))
}

@(private = "file")
key_mix :: #force_inline proc(h, w: u64) -> u64 {
	x := (h ~ w) * 0x9E3779B97F4A7C15
	return x ~ (x >> 32)
}

// Whether two key tokens decode to the same text.
@(private = "file")
key_tokens_equal :: proc(src: []byte, o: Key_Entry, lo, hi: u64, escaped: bool) -> bool {
	if !escaped && o.depth & KEY_ESCAPED == 0 {
		return string(src[lo + 1:hi - 1]) == string(src[o.lo + 1:o.hi - 1])
	}
	a := Key_Bytes{p = lo + 1, end = hi - 1}
	b := Key_Bytes{p = o.lo + 1, end = o.hi - 1}
	for {
		x, x_ok := key_bytes_next(src, &a)
		y, y_ok := key_bytes_next(src, &b)
		if x_ok != y_ok || x != y {
			return false
		}
		if !x_ok {
			return true
		}
	}
}

// A key's decoded bytes, one at a time. An escape the walk did not check (`.Locate` reads keys unchecked) and
// cannot decode stands for its backslash, so a key reads the same however often it is read.
@(private = "file")
Key_Bytes :: struct {
	p, end: u64,
	unit:   [4]u8,
	un, ui: int,
}

@(private = "file")
key_bytes_next :: proc(src: []byte, it: ^Key_Bytes) -> (b: u8, ok: bool) {
	if it.ui < it.un {
		b = it.unit[it.ui]
		it.ui += 1
		return b, true
	}
	if it.p >= it.end {
		return 0, false
	}
	b = src[it.p]
	if b == '\\' {
		if n, next, good := decode_escape_unit(src, it.p, it.end, it.unit[:]); good {
			it.p, it.un, it.ui = next, n, 1
			return it.unit[0], true
		}
	}
	it.p += 1
	return b, true
}

// The walk's hook for a key of an object a `.First` or `.Last` run reads through `Any` (`Query_Ctx.wild_keys`):
// a repeat is counted for the json layer (`Scan_Query_Sink.paths_unresolved`), as is a key the set could not
// remember. The keys leave with their object (`key_set_close`).
wild_key :: #force_no_inline proc(q: ^Query_Ctx, src: []byte, key_lo, key_hi, sp: u64) {
	unique, oom := key_set_add(q.keys, src, key_lo, key_hi, q.key_saw_escape, u32(sp))
	if !unique || oom {
		q.path_sink.paths_unresolved += 1
	}
}

// `key_set_close` for the run `wild_key` feeds, out of line: the walks share one copy of the hash.
wild_close :: #force_no_inline proc(q: ^Query_Ctx, depth: u32) {
	key_set_close(q.keys, depth)
}

// The walk's `.Unique` hook, at the key `src[key_lo:key_hi]` of the object open at walk depth `sp - 1`
// (`object_key`): a repeat is `.Duplicate_Key` at the key. A key the set could not remember is a refused
// append (`note_oom`), and the walk reads on.
walk_key_unique :: #force_inline proc(q: ^Query_Ctx, src: []byte, key_lo, key_hi, sp: u64) -> Maybe(Error) {
	unique, oom := key_set_add(q.keys, src, key_lo, key_hi, q.key_saw_escape, u32(sp))
	if oom {
		note_oom(q, .Unique)
	}
	if !unique {
		return Error{offset = key_lo, kind = .Duplicate_Key}
	}
	return nil
}
