package yaml

import "base:intrinsics"
import core "../core"

// A collection the walk has open. `first` is the index in `Parser.keys` of the first key of a mapping. A mapping's `<<`
// member under `merge_keys` is the range `merge_lo ..< merge_hi` of `Parser.merges`, its key and its value's tokens.
@(private)
Key_Frame :: struct {
	first:    u32,
	object:   bool,
	merge_lo: u32,
	merge_hi: u32,
}

// A key a mapping holds, in the order the walk met it. `next` is the key that headed its slot of `Parser.heads` before
// it, so the keys of a slot form a chain whose indexes fall, and closing a mapping restores each slot it took.
@(private)
Key :: struct {
	lo:       u64,
	n:        u32,
	spelling: u16,
	hash:     u64,
	next:     u32,
}

@(private)
NO_KEY :: max(u32)

// The fewest slots the key table starts with, a power of two.
@(private)
KEY_SLOTS :: 64

// Opens a collection for the repeat test of its keys.
@(private)
keys_open :: #force_inline proc(p: ^Parser, object: bool) {
	append(&p.frames, Key_Frame{first = u32(len(p.keys)), object = object})
}

// Closes the innermost collection and forgets its keys, newest first, so each slot gets back the key it held before.
@(private)
keys_close :: #force_inline proc(p: ^Parser) {
	f := pop(&p.frames)
	if !f.object || int(f.first) == len(p.keys) {
		return
	}
	mask := u64(len(p.heads) - 1)
	#reverse for k in p.keys[f.first:] {
		p.heads[k.hash & mask] = k.next
	}
	resize(&p.keys, int(f.first))
}

// Judges key `t`, a scalar, against the keys of its mapping: a text that repeats one is a fault.
@(private)
keys_add :: #force_inline proc(p: ^Parser, t: core.Token) -> bool {
	if key_enter(p, t) {
		return fault(p, t.lo, .Bad_Char, .Duplicate_Key)
	}
	return true
}

// Adds key `t`, a scalar, to the keys of the innermost mapping, and returns whether its text repeats one of them, which
// is then not added. A key is the text it decodes to, so `1` and `"1"` repeat each other.
@(private)
key_enter :: proc(p: ^Parser, t: core.Token) -> (repeated: bool) {
	f := p.frames[len(p.frames) - 1]
	if !f.object {
		return false
	}
	if 2 * (len(p.keys) + 1) > len(p.heads) {
		keys_grow(p)
	}
	if t.spelling & core.SPELLING_DECODE == 0 {
		return key_judge(p, f, t, string(p.src[t.lo:t.lo + u64(t.n)]))
	}
	stack: [256]u8 = ---
	text, fits := key_text(t, p.src, stack[:])
	if fits {
		return key_judge(p, f, t, text)
	}
	heap := make([]u8, 3 * int(t.n) + 4)
	defer delete(heap)
	text, _ = key_text(t, p.src, heap)
	return key_judge(p, f, t, text)
}

// Whether key `t`, whose text is `text`, repeats a key of mapping `f`, else adds it.
@(private)
key_judge :: #force_inline proc(p: ^Parser, f: Key_Frame, t: core.Token, text: string) -> (repeated: bool) {
	h := key_hash(text)
	slot := h & u64(len(p.heads) - 1)
	head := p.heads[slot]
	for i := head; i != NO_KEY && i >= f.first; i = p.keys[i].next {
		k := p.keys[i]
		if k.hash == h && key_repeats(k, p.src, text) {
			return true
		}
	}
	p.heads[slot] = u32(len(p.keys))
	append(&p.keys, Key{t.lo, t.n, t.spelling, h, head})
	return false
}

// Doubles the slots and chains the keys again in the order they came.
@(private)
keys_grow :: proc(p: ^Parser) {
	// Every slot is written again, so the old table is freed rather than resized, which would copy it.
	n := max(KEY_SLOTS, 2 * len(p.heads))
	delete(p.heads)
	p.heads = make([dynamic]u32, n)
	for &h in p.heads {
		h = NO_KEY
	}
	mask := u64(len(p.heads) - 1)
	for &k, i in p.keys {
		k.next = p.heads[k.hash & mask]
		p.heads[k.hash & mask] = u32(i)
	}
}

@(private)
key_repeats :: proc(k: Key, src: []u8, text: string) -> bool {
	if k.spelling & core.SPELLING_DECODE == 0 {
		return string(src[k.lo:k.lo + u64(k.n)]) == text
	}
	other: [256]u8 = ---
	prior, fits := key_text(core.Token{k.lo, k.n, .Plain, .Key, k.spelling}, src, other[:])
	if fits {
		return prior == text
	}
	buf := make([]u8, 3 * int(k.n) + 4)
	defer delete(buf)
	prior, _ = key_text(core.Token{k.lo, k.n, .Plain, .Key, k.spelling}, src, buf)
	return prior == text
}

// A hash of `text` eight bytes at a time.
@(private)
key_hash :: #force_inline proc "contextless" (text: string) -> u64 #no_bounds_check {
	K :: 0x9e3779b97f4a7c15
	h := u64(len(text)) * K
	b := raw_data(text)
	n := len(text)
	i := 0
	for ; i + 8 <= n; i += 8 {
		h = (h ~ intrinsics.unaligned_load((^u64)(b[i:]))) * K
		h ~= h >> 29
	}
	if i < n {
		last: u64
		for j := n - 1; j >= i; j -= 1 {
			last = last << 8 | u64(b[j])
		}
		h = (h ~ last) * K
		h ~= h >> 29
	}
	h *= K
	return h ~ h >> 32
}

@(private)
key_text :: proc "contextless" (t: core.Token, src: []u8, buf: []u8) -> (string, bool) {
	span := src[t.lo:t.lo + u64(t.n)]
	if t.spelling & core.SPELLING_DECODE == 0 {
		return string(span), true
	}
	return decode(span, t.spelling, buf)
}
