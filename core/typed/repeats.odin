package typed

import "base:intrinsics"
import "base:runtime"
import spell "../spell"
import core ".."

// A typed read under `.Refuse`: the read `R`, a `Reader` or a `Check`, and the keys of the objects open in its walk, so
// a key repeated in any object of the text, inside a value the read skips too, is found in the walk that reads it. A
// walk gives this hook every key, the ones the cursor matches by their bytes included, and walks a skipped value with
// `on_open_key`. A read that stops goes on as a walk of the keys alone, since a repeat or a fault anywhere in the text
// refuses it first.
Refusing :: struct($R: typeid) {
	using read: R,
	open_keys:  Open_Keys,
}

// The keys of the objects open in a walk, in document order, each at its object's depth: the last `n` of `room` in use.
// An object's keys are judged at its close, and `repeat` is the first byte of the earliest repeated key, `NO_REPEAT` while
// none. `held` are the read's registers where it stopped, once `spent`.
Open_Keys :: struct {
	room:      []Open_Key,
	n:         int,
	depth:     u32,
	spent:     bool,
	repeat:    u64,
	held:      core.Hook_Regs,
	view:      ^core.Token_View,
	readers:   ^core.Readers,
	allocator: runtime.Allocator,
}

// A key's token and its object's depth, laid out with no gap, so room left unwritten is not zeroed.
Open_Key :: struct {
	using key: core.Token,
	depth:     u32,
	pad:       u32,
}

NO_REPEAT :: max(u64)

// A record no key matches by its bytes, since a key's first byte is never zero, which a spent read's cursor stands on.
@(private)
NO_KEY := Field{key = {mask = {0xff, 0}}}

// Starts `k` over `room`, which grows in `allocator`, for a read whose tokens `view` and `readers` spell.
open_keys_start :: proc "contextless" (k: ^Open_Keys, room: []Open_Key, view: ^core.Token_View, readers: ^core.Readers, allocator: runtime.Allocator) {
	k^ = {room = room, repeat = NO_REPEAT, view = view, readers = readers, allocator = allocator}
}

// Notes key `t` of the innermost open object.
key_met :: #force_inline proc "contextless" (k: ^Open_Keys, t: core.Token) #no_bounds_check {
	if k.n == len(k.room) && !keys_grow(k) {
		// With no room the read cannot say the text holds no repeat.
		k.repeat = min(k.repeat, t.lo)
		return
	}
	k.room[k.n] = {key = t, depth = k.depth}
	k.n += 1
}

// Notes token `t`'s part in the open objects: a key, a container's open or its close, which judges an object's keys.
keys_token :: #force_inline proc "contextless" (k: ^Open_Keys, t: core.Token) #no_bounds_check {
	if t.role == .Key {
		key_met(k, t)
	} else if t.role == .Value {
		#partial switch t.kind {
		case .Object, .Array:
			k.depth += 1
		case .End:
			if k.n > 0 && k.room[k.n - 1].depth == k.depth {
				keys_close(k)
			}
			k.depth -= 1
		}
	}
}

// Judges the keys of every object still open, as a walk that faulted leaves them: a key read before the fault is a
// repeat all the same.
keys_open_end :: proc "contextless" (k: ^Open_Keys) {
	for k.n > 0 {
		k.depth = k.room[k.n - 1].depth
		keys_close(k)
	}
}

// The hook of a walk over a value a read skips, which notes its keys alone.
on_open_key :: proc "contextless" (k: ^Open_Keys, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	keys_token(k, t)
	return regs, .Next
}

// The hook of a `Refusing` read of a `Reader`.
on_read_refusing :: proc "contextless" (h: ^Refusing(Reader), regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return refusing_token(h, regs, t, on_token_spelled)
}

// The hook of a `Refusing` read of a `Check`.
on_check_refusing :: proc "contextless" (h: ^Refusing(Check), regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return refusing_token(h, regs, t, on_token_check_spelled)
}

// Notes token `t`'s keys, then reads it with `read`, until the read stops or a repeat is found, past which the walk goes
// on for the keys and the faults alone.
refusing_token :: #force_inline proc "contextless" (h: ^Refusing($R), regs: core.Hook_Regs, t: core.Token, $read: proc "contextless" (h: ^R, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (core.Hook_Regs, core.Action) {
	k := &h.open_keys
	keys_token(k, t)
	if k.spent || k.repeat != NO_REPEAT {
		if !k.spent {
			k.spent, k.held = true, regs
		}
		return {regs.a, u64(uintptr(&NO_KEY)), regs.c}, .Next
	}
	out, action := read(&h.read, regs, t)
	if action == .Stop {
		k.spent, k.held = true, out
		return {out.a, u64(uintptr(&NO_KEY)), out.c}, .Next
	}
	return out, action
}

// The registers a `Refusing` read ends with: where it stopped, or `regs`, where its walk ended.
refusing_regs :: proc "contextless" (k: ^Open_Keys, regs: core.Hook_Regs) -> core.Hook_Regs {
	return k.held if k.spent else regs
}

// Gives `k` twice its room in its allocator.
@(cold, private)
keys_grow :: #force_no_inline proc "contextless" (k: ^Open_Keys) -> bool {
	context = runtime.default_context()
	wide, err := make([]Open_Key, max(64, 2 * len(k.room)), k.allocator)
	if err != nil {
		return false
	}
	copy(wide, k.room[:k.n])
	k.room = wide
	return true
}

// The keys an object's close judges two by two, past which they are judged by their hashes.
@(private)
KEYS_PAIRED :: 12

// Judges the keys of the innermost open object, at depth `k.depth`, and drops them: the first that repeats an earlier
// one lowers `k.repeat` to its first byte.
@(private)
keys_close :: #force_no_inline proc "contextless" (k: ^Open_Keys) #no_bounds_check {
	from := k.n - 1
	for from > 0 && k.room[from - 1].depth == k.depth {
		from -= 1
	}
	keys := k.room[from:k.n]
	k.n = from
	decoded := false
	for &e in keys {
		decoded ||= e.spelling & core.SPELLING_DECODE != 0
	}
	if decoded || len(keys) > KEYS_PAIRED {
		keys_hashed(k, keys)
		return
	}
	src := raw_data(k.view.src)
	for i in 1 ..< len(keys) {
		a := keys[i]
		for j in 0 ..< i {
			if keys[j].n == a.n && spell.bytes_equal(src[keys[j].lo:][:a.n], src[a.lo:][:a.n]) {
				k.repeat = min(k.repeat, key_start(a))
				return
			}
		}
	}
}

// Judges the keys of one object by a table of their hashes, decoding a key that holds an escape.
@(private)
keys_hashed :: proc "contextless" (k: ^Open_Keys, keys: []Open_Key) #no_bounds_check {
	context = runtime.default_context()
	size := 16
	for size < 2 * len(keys) {
		size <<= 1
	}
	small: [128]u32 = ---
	slots: []u32
	if size <= len(small) {
		slots = small[:size]
	} else {
		fresh, err := make([]u32, size, k.allocator)
		if err != nil {
			k.repeat = min(k.repeat, key_start(keys[0]))
			return
		}
		slots = fresh
	}
	for i in 0 ..< size {
		slots[i] = 0
	}
	mask := size - 1
	for &e, i in keys {
		s, ok := open_key_text(k, e)
		if !ok {
			k.repeat = min(k.repeat, key_start(e))
			return
		}
		at := int(key_code(s)) & mask
		for ; slots[at] != 0; at = (at + 1) & mask {
			if t, read := open_key_text(k, keys[slots[at] - 1]); !read || t == s {
				k.repeat = min(k.repeat, key_start(e))
				return
			}
		}
		slots[at] = u32(i + 1)
	}
}

// The text of key `e`, decoded in the keys' allocator when it holds an escape.
@(private)
open_key_text :: proc(k: ^Open_Keys, e: Open_Key) -> (string, bool) {
	return core.token_text(k.readers, k.view, e.key, k.allocator)
}

// The first byte of key `e`, its quote included.
@(private)
key_start :: #force_inline proc "contextless" (e: Open_Key) -> u64 {
	lo, _ := core.scalar_ends(e.key)
	return lo
}

// Hashes a key's text eight bytes at a time. Equal texts give equal codes.
@(private)
key_code :: #force_inline proc "contextless" (s: string) -> u64 {
	MUL :: 0x9E3779B97F4A7C15
	p := raw_data(s)
	n := len(s)
	h := u64(n) * MUL
	i := 0
	for ; i + 8 <= n; i += 8 {
		h = (h ~ intrinsics.unaligned_load((^u64)(&p[i]))) * MUL
		h ~= h >> 32
	}
	tail: u64
	for ; i < n; i += 1 {
		tail = tail << 8 | u64(p[i])
	}
	h = (h ~ tail) * MUL
	return h ~ h >> 29
}
