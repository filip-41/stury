package yaml

import "base:runtime"
import "stury:lib/core/tape"

// Open mapping key table used during `.Yaml_Merge` (`<<` merge keys) to deduplicate host vs merged member keys using
// v2 `tape.same_keys` and `key_hash`.

@(private)
Key_Table :: struct {
	frames: [dynamic]Key_Frame,
	keys:   [dynamic]Key_Entry,
	heads:  [dynamic]u32,
}

@(private)
Key_Frame :: struct {
	first:   u32,
	object:  bool,
	runs_lo: u32,
	runs_hi: u32,
}

@(private)
Key_Entry :: struct {
	tok:  tape.Token,
	hash: u32,
	next: u32,
}

@(private)
NO_KEY :: max(u32)

@(private)
KEY_SLOTS :: 64

@(private)
keys_init :: proc "contextless" (k: ^Key_Table, a: runtime.Allocator) {
	k.frames.allocator = a
	k.keys.allocator = a
	k.heads.allocator = a
}

@(private)
keys_destroy :: proc(k: ^Key_Table) {
	delete(k.frames)
	delete(k.keys)
	delete(k.heads)
}

@(private)
keys_reset :: proc(k: ^Key_Table) {
	clear(&k.frames)
	clear(&k.keys)
	clear(&k.heads)
}

@(private)
keys_open :: proc(k: ^Key_Table, object: bool, runs_lo: u32) -> bool {
	_, err := append(&k.frames, Key_Frame{first = u32(len(k.keys)), object = object, runs_lo = runs_lo, runs_hi = runs_lo})
	return err == nil
}

@(private)
keys_close :: proc(k: ^Key_Table) {
	f := pop(&k.frames)
	if !f.object || int(f.first) == len(k.keys) {
		return
	}
	mask := u32(len(k.heads) - 1)
	#reverse for entry in k.keys[f.first:] {
		k.heads[entry.hash & mask] = entry.next
	}
	resize(&k.keys, int(f.first))
}

@(private)
keys_grow :: proc(k: ^Key_Table) -> bool {
	n := max(KEY_SLOTS, 2 * len(k.heads))
	alloc := k.heads.allocator
	delete(k.heads)
	heads, err := make([dynamic]u32, n, alloc)
	if err != nil {
		return false
	}
	k.heads = heads
	for &h in k.heads {
		h = NO_KEY
	}
	mask := u32(len(k.heads) - 1)
	for &entry, i in k.keys {
		entry.next = k.heads[entry.hash & mask]
		k.heads[entry.hash & mask] = u32(i)
	}
	return true
}

// Enters key `t` into the innermost mapping table, returning `(repeated, ok)`.
@(private)
key_enter :: proc(k: ^Key_Table, t: tape.Token, src: []u8) -> (repeated, ok: bool) {
	f := k.frames[len(k.frames) - 1]
	if !f.object || t.kind > .Plain {
		return false, true
	}
	if 2 * (len(k.keys) + 2) > len(k.heads) {
		if !keys_grow(k) {
			return false, false
		}
	}
	h := key_hash(src, t)
	mask := u32(len(k.heads) - 1)
	for i := k.heads[h & mask]; i != NO_KEY && i >= f.first; i = k.keys[i].next {
		e := k.keys[i]
		if e.hash == h && tape.same_keys(&FORMATS[.Yaml_Merge], src, e.tok, src, t) {
			return true, true
		}
	}
	slot := h & mask
	idx := u32(len(k.keys))
	entry := Key_Entry{tok = t, hash = h, next = k.heads[slot]}
	if _, err := append(&k.keys, entry); err != nil {
		return false, false
	}
	k.heads[slot] = idx
	return false, true
}
