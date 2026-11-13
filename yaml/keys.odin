package yaml

import "base:intrinsics"
import "base:runtime"
import core "../core"

// The keys of the mappings a walk has open, which the walk under `merge_keys` keeps to leave out a merged member whose
// key the host holds, and a build keeps under `.Refuse` and to find a clash.
@(private)
Key_Table :: struct {
	frames: [dynamic]Key_Frame,
	keys:   [dynamic]Key,
	heads:  [dynamic]u32,
}

// A collection the walk has open. `first` is the index in `Key_Table.keys` of the first key of a mapping. A mapping's
// `<<` member under `merge_keys` is the range `merge_lo ..< merge_hi` of `Parser.merges`, its key and its value's tokens.
@(private)
Key_Frame :: struct {
	first:    u32,
	object:   bool,
	merge_lo: u32,
	merge_hi: u32,
}

// A key a mapping holds, in the order the walk met it, of core type `type` and `value`. A key that is not text is held
// twice: under the hash of its text, and with `by_value` set under the hash of its value, so `0x1` finds `1`. `next` is the key that
// headed its slot of `Key_Table.heads` before it, so the keys of a slot form a chain whose indexes fall, and closing a
// mapping restores each slot it took.
@(private)
Key :: struct {
	lo:       u64,
	n:        u32,
	spelling: u16,
	type:     Key_Type,
	by_value: bool,
	value:    core.Number,
	hash:     u64,
	next:     u32,
}

// The core type a key resolves to.
@(private)
Key_Type :: enum u8 {
	Str,
	Null,
	Bool,
	Int,
	Float,
}

// How a key stands to the keys before it in its mapping: a key of the same type and value `Repeat`s one, and a key of
// the same text and another type, as `1` is to `"1"`, `Clash`es with one, a different key a read by name cannot tell
// apart. A key of the same type and value and another text, as `0x1` is to `1`, does both, since a read by name
// sees two names.
@(private)
Key_Repeat :: enum u8 {
	Repeat,
	Clash,
}

// Bits 6 and 7 of a key's `spelling` hold what its tag says of its type, since a document keeps no fact of a key:
// `!!str` and a tag of no core type make it text, as `resolve` reads such a value, `!!float` a float, and `!!int`,
// `!!bool` and `!!null` the type its text resolves to whatever its style. A plain key with no tag that resolves to no
// string is `Resolved` too, so a key of 0 in these bits is a string.
@(private)
KEY_TAG_SHIFT :: 6
@(private)
KEY_TAGS :: u16(3) << KEY_TAG_SHIFT

@(private)
Key_Tag :: enum u8 {
	None,
	Text,
	Resolved,
	Float,
}

@(private)
key_tag_bits :: proc "contextless" (ct: Core_Type) -> u16 {
	tag := Key_Tag.Text
	#partial switch ct {
	case .Float:
		tag = .Float
	case .Int, .Bool, .Null:
		tag = .Resolved
	}
	return u16(tag) << KEY_TAG_SHIFT
}

@(private)
NO_KEY :: max(u32)

// The fewest slots the key table starts with, a power of two.
@(private)
KEY_SLOTS :: 64

// Opens a collection for the keys it holds.
@(private)
keys_open :: #force_inline proc(k: ^Key_Table, object: bool) {
	append(&k.frames, Key_Frame{first = u32(len(k.keys)), object = object})
}

// Closes the innermost collection and forgets its keys, newest first, so each slot gets back the key it held before.
@(private)
keys_close :: #force_inline proc(k: ^Key_Table) {
	f := pop(&k.frames)
	if !f.object || int(f.first) == len(k.keys) {
		return
	}
	mask := u64(len(k.heads) - 1)
	#reverse for key in k.keys[f.first:] {
		k.heads[key.hash & mask] = key.next
	}
	resize(&k.keys, int(f.first))
}

@(private)
keys_destroy :: proc(k: ^Key_Table) {
	delete(k.frames)
	delete(k.keys)
	delete(k.heads)
}

// Adds key `t`, a scalar, to the keys of the innermost mapping, and returns how it stands to them. A key that repeats
// one of the same text is not added, and one that repeats another text is added under its own text only.
@(private)
key_enter :: proc(k: ^Key_Table, t: core.Token, src: []u8) -> (judged: bit_set[Key_Repeat; u8]) {
	f := k.frames[len(k.frames) - 1]
	if !f.object {
		return
	}
	if 2 * (len(k.keys) + 2) > len(k.heads) {
		keys_grow(k)
	}
	stack: [256]u8 = ---
	text, owned := key_decoded(t, src, stack[:])
	defer delete(owned)
	type, value := key_type(t, text)
	h := key_hash(text)
	mask := u64(len(k.heads) - 1)
	for i := k.heads[h & mask]; i != NO_KEY && i >= f.first; i = k.keys[i].next {
		e := k.keys[i]
		if !e.by_value && e.hash == h && key_repeats(e, src, text) {
			if e.type == type {
				return judged + {.Repeat}
			}
			judged += {.Clash}
		}
	}
	key_add(k, Key{t.lo, t.n, t.spelling, type, false, value, h, 0})
	// Two keys of one type and text hold one value, so only a key with a value of its own is looked up by it.
	if type == .Str || value.kind == .Wide {
		return
	}
	vh := key_value_hash(type, value)
	for i := k.heads[vh & mask]; i != NO_KEY && i >= f.first; i = k.keys[i].next {
		if e := k.keys[i]; e.by_value && e.hash == vh && e.type == type && e.value == value {
			return judged + {.Repeat, .Clash}
		}
	}
	key_add(k, Key{t.lo, t.n, t.spelling, type, true, value, vh, 0})
	return
}

// The first bytes of a number, a null and a bool.
@(private, rodata)
KEY_LEADS := [256]bool{'0' ..= '9' = true, '+' = true, '-' = true, '.' = true, '~' = true, 'n' = true, 'N' = true, 't' = true, 'T' = true, 'f' = true, 'F' = true}

// A plain scalar token at `lo`, `n` bytes long, whose first byte is `c`: a key with no tag that resolves to no string is
// marked `Resolved`, and noted in `Parser.typed`. A key that is not empty and whose first byte cannot start a number, a
// null or a bool is text.
@(private)
plain_token :: #force_inline proc(p: ^Parser, lo: u64, n: u32, role: core.Role, c: u8 = 0, spelling: u16 = 0) -> core.Token #no_bounds_check {
	t := core.Token{lo, n, .Plain, role, spelling}
	if role == .Key && (n == 0 || KEY_LEADS[c]) && p.tag.n == 0 && key_typed(t, p.src) {
		t.spelling |= u16(Key_Tag.Resolved) << KEY_TAG_SHIFT
		p.typed = true
	}
	return t
}

// Whether key `t`, which has no tag, is a plain scalar that resolves to no string. A word is decoded only when its first
// four bytes spell `null`, `true` or `fals` in any case.
@(private)
key_typed :: #force_no_inline proc "contextless" (t: core.Token, src: []u8) -> bool {
	if style_of(t.spelling) != .Plain || t.n == 0 {
		return t.n == 0
	}
	w := intrinsics.unaligned_load((^u32)(raw_data(src[t.lo:]))) | 0x20202020 if t.n >= 4 else 0
	if src[t.lo] | 0x20 >= 'a' && src[t.lo] != '~' && w != 0x6c6c756e && w != 0x65757274 && w != 0x736c6166 {
		return false
	}
	return key_resolves(t, src)
}

@(private)
key_resolves :: #force_no_inline proc "contextless" (t: core.Token, src: []u8) -> bool {
	context = runtime.default_context()
	stack: [256]u8 = ---
	text, owned := key_decoded(t, src, stack[:])
	defer delete(owned)
	type, _ := key_type(t, text)
	return type != .Str
}

@(private)
key_add :: #force_inline proc(k: ^Key_Table, key: Key) {
	key := key
	slot := key.hash & u64(len(k.heads) - 1)
	key.next = k.heads[slot]
	k.heads[slot] = u32(len(k.keys))
	append(&k.keys, key)
}

// Doubles the slots and chains the keys again in the order they came.
@(private)
keys_grow :: proc(k: ^Key_Table) {
	// Every slot is written again, so the old table is freed rather than resized, which would copy it.
	n := max(KEY_SLOTS, 2 * len(k.heads))
	delete(k.heads)
	k.heads = make([dynamic]u32, n)
	for &h in k.heads {
		h = NO_KEY
	}
	mask := u64(len(k.heads) - 1)
	for &key, i in k.keys {
		key.next = k.heads[key.hash & mask]
		k.heads[key.hash & mask] = u32(i)
	}
}

// The core type key `t`, whose text is `text`, resolves to, and its value when that is no text: a bool is 0 or 1, and
// a float is the bits of its binary64, an integer under `!!float` too.
@(private)
key_type :: proc(t: core.Token, text: string) -> (type: Key_Type, value: core.Number) {
	tag := Key_Tag(t.spelling >> KEY_TAG_SHIFT & 3)
	if tag == .Text || tag == .None && style_of(t.spelling) != .Plain {
		return .Str, {}
	}
	class, n, integer := scalar_value(transmute([]u8)text)
	switch class {
	case .Text:
		return .Str, {}
	case .Null:
		return .Null, {}
	case .False, .True:
		return .Bool, {u64(class == .True), .Int}
	case .Decimal, .Hex, .Octal:
		if tag != .Float && (class != .Decimal || integer) {
			return .Int, n
		}
	case .Inf, .Nan:
	}
	switch n.kind {
	case .Int:
		n = {transmute(u64)f64(i64(n.bits)), .Float}
	case .Uint:
		n = {transmute(u64)f64(n.bits), .Float}
	case .Float, .Wide:
	}
	return .Float, n
}

@(private)
key_repeats :: proc(e: Key, src: []u8, text: string) -> bool {
	if e.spelling & core.SPELLING_DECODE == 0 {
		return string(src[e.lo:e.lo + u64(e.n)]) == text
	}
	stack: [256]u8 = ---
	prior, owned := key_decoded(core.Token{e.lo, e.n, .Plain, .Key, e.spelling}, src, stack[:])
	defer delete(owned)
	return prior == text
}

// The text of key `t`, decoded into `stack` when it fits and else into `owned`, which the caller frees.
@(private)
key_decoded :: proc(t: core.Token, src: []u8, stack: []u8) -> (text: string, owned: []u8) {
	span := src[t.lo:t.lo + u64(t.n)]
	if t.spelling & core.SPELLING_DECODE == 0 {
		return string(span), nil
	}
	if s, fits := decode(span, t.spelling, stack); fits {
		return s, nil
	}
	owned = make([]u8, 3 * int(t.n) + 4)
	text, _ = decode(span, t.spelling, owned)
	return
}

// A hash of a key's type and value, which no text hash is meant to equal.
@(private)
key_value_hash :: #force_inline proc "contextless" (type: Key_Type, value: core.Number) -> u64 {
	K :: 0x9e3779b97f4a7c15
	h := (value.bits ~ u64(type) << 56 ~ u64(value.kind) << 48) * K
	h ~= h >> 29
	h *= K
	return h ~ h >> 32
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
