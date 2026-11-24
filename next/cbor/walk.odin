package cbor

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The walk of a CBOR data item (RFC 8949). One loop reads the item and every item inside it, judges each byte it reads
// and gives tokens to the hook. A tag is a fact before its content, and tags 2 to 5 are folded into the one number they
// spell.

// Open levels a read keeps in its frame. A deeper item moves them to memory from the read's allocator, so a `validate`
// within this depth allocates nothing.
WALK_LEVELS :: 1024

// Open levels a walk read again keeps in its frame, which is small as it borrows the walk it runs in.
@(private)
REWALK_LEVELS :: 64

// The most levels a walk holds, whose bytes an `int` counts.
@(private)
MAX_LEVELS :: u64(max(int) / size_of(Level(.Length_First)))

// The bytes of a walk's frame, its open levels and its state, which stay under `READ_STACK` with room for the reads'
// own calls. A replay's frame holds `REWALK_LEVELS` levels and no state.
#assert(size_of(Walk(.Length_First, hook.No_Hooks, true, hook.NO_HOOKS_CAPS)) + WALK_LEVELS * size_of(Level(.Length_First)) <= 32 * 1024)

// The stack each read needs below its caller's frame, from its entry to its deepest call, with room for an allocator's
// calls. A thread with less faults on its guard page, as a read first reads this much of it a page at a time.
READ_STACK :: 48 * 1024

// The frame of an open item: the items it still waits for in the low 56 bits, and flags. A map waits for two items per
// pair, so its key is due while the count is even. An indefinite item holds `INDEF_COUNT` and its break ends it. A tag
// waits for its one content item. In a spec that orders keys, `prev` is the span of the map's last key, zero before
// its first.
@(private)
Level :: struct($S: Spec) {
	frame: u64,
	prev:  [int(S >= .Deterministic)][2]u64,
}

// The kinds a token is cast from a head's bits: a boolean is the `Kind` its initial byte less 0xf3 names, and a map
// follows an array.
#assert(tape.Kind.False == tape.Kind(1) && tape.Kind.True == tape.Kind(2))
#assert(tape.Kind.Object == tape.Kind(u8(tape.Kind.Array) + 1))

@(private)
FLAG_OBJECT :: u64(1) << 62
@(private)
FLAG_INDEF :: u64(1) << 61
@(private)
FLAG_TAG :: u64(1) << 60
// The count of items a frame waits for, and `INDEF_COUNT` for an indefinite item, which no count reaches.
@(private)
COUNT_MASK :: u64(1) << 56 - 1
@(private)
INDEF_COUNT :: u64(1) << 55
#assert(FLAG_OBJECT & FLAG_INDEF == 0 && FLAG_INDEF & FLAG_TAG == 0)
#assert((FLAG_OBJECT | FLAG_INDEF | FLAG_TAG) & COUNT_MASK == 0)
#assert(INDEF_COUNT & COUNT_MASK == INDEF_COUNT)

// The frame of an array or map of `arg` items or pairs, `pair` for a map: it waits for `arg` items, or twice that, and
// an empty one for the one item its count supplies at once.
@(private)
frame_of :: #force_inline proc "contextless" (arg, pair: u64) -> u64 {
	return max(arg << pair, 1) | pair << 62
}

// The frame of an indefinite array or map.
@(private)
indefinite_frame :: #force_inline proc "contextless" (pair: u64) -> u64 {
	return FLAG_INDEF | INDEF_COUNT | pair << 62
}

// Whether the item that frame `top` waits for is a key of a map.
@(private)
key_is_due :: #force_inline proc "contextless" (top: u64) -> bool {
	return top & (FLAG_OBJECT | 1) == FLAG_OBJECT
}

// Whether a break may not end frame `top`: it holds no indefinite item, or a map's key has no value yet. A break ends
// an indefinite item where its next item could start, which in a map is before a key.
@(private)
break_refused :: #force_inline proc "contextless" (top: u64) -> bool {
	return top & FLAG_INDEF == 0 || top & (FLAG_OBJECT | 1) == FLAG_OBJECT | 1
}

// A walk's state outside its loop, for hook type `H` of capabilities `C`, its protocol's. A walk with `LAX` counts its
// containers within `Budget.steps`, and one without counts nothing, with no count in its code. Every walk takes the
// rules of `tolerate`, which it tests only at a byte it would refuse.
@(private)
Walk :: struct($S: Spec, $H: typeid, $LAX: bool, $C: hook.Capabilities) {
	src:       []u8,
	// The length of the text `src` is the start of, for a walk of a part that ends before the text does, else 0.
	whole:     u64,
	hooks:     ^H,
	// The address one past the hook's room for nodes, for a hook with `.Rooms`.
	rooms:     uintptr,
	stack:     [^]Level(S),
	allocator: runtime.Allocator, // what `stack` grows in past the frame's levels
	ctx:       ^runtime.Context, // the caller's, for the calls of `allocator`, nil only when the frame's levels suffice
	depth:     u64, // levels `stack` and the hook hold
	limit:     u64, // `Budget.depth`
	room:      u64, // levels `stack` holds
	owned:     bool, // `stack` is the allocator's
	lax_utf8:  bool, // `.Invalid_Utf8` is tolerated
	refuse:    bool, // `Options.dups` is `.Refuse`, which a key that repeats the one before it is a fault of
	tolerated: bool, // the walk took a rule of the tolerances
	// With `LAX`, one more than the containers the walk may still open within `Budget.steps`, 0 once it opened one past
	// it.
	steps:     [int(LAX)]u64,
	// With `LAX`, the text in pieces whose window the walk reads, nil for a whole text.
	piece:     [1]^Piece,
}

// Sets up walk `w` of `src` for hook `h`, with its levels in `stack`, which holds `room` of them, within `limit` levels
// and the rules of `opts`. The caller sets what the walk's kind adds, and its depth.
@(private)
walk_init :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), src: []u8, h: ^H, stack: [^]Level(S), limit, room: u64, opts: Options) {
	w.src, w.hooks, w.stack, w.limit, w.room = src, h, stack, limit, room
	w.lax_utf8, w.refuse = .Invalid_Utf8 in opts.tolerate, opts.dups == .Refuse
}

// The capability a walk of a text in windows adds to its hook's.
@(private)
WINDOWS :: hook.Capabilities{.Windows}

// What an initial byte starts. `Reserved` is additional information 28 to 30, and 31 on a major type that has no
// indefinite form.
@(private)
Class :: enum u8 {
	Int,
	Bytes,
	Text,
	Array,
	Map,
	Tag,
	False,
	True,
	Null,
	Simple,
	Simple_8,
	Float,
	Indefinite_String,
	Indefinite_Container,
	Break,
	Reserved,
}

@(private, rodata)
CLASS := [256]Class {
	0x00 ..= 0x1b = .Int,
	0x1c ..= 0x1f = .Reserved,
	0x20 ..= 0x3b = .Int,
	0x3c ..= 0x3f = .Reserved,
	0x40 ..= 0x5b = .Bytes,
	0x5c ..= 0x5e = .Reserved,
	0x5f = .Indefinite_String,
	0x60 ..= 0x7b = .Text,
	0x7c ..= 0x7e = .Reserved,
	0x7f = .Indefinite_String,
	0x80 ..= 0x9b = .Array,
	0x9c ..= 0x9e = .Reserved,
	0x9f = .Indefinite_Container,
	0xa0 ..= 0xbb = .Map,
	0xbc ..= 0xbe = .Reserved,
	0xbf = .Indefinite_Container,
	0xc0 ..= 0xdb = .Tag,
	0xdc ..= 0xdf = .Reserved,
	0xe0 ..= 0xf3 = .Simple,
	0xf4 = .False,
	0xf5 = .True,
	0xf6 = .Null,
	0xf7 = .Simple,
	0xf8 = .Simple_8,
	0xf9 ..= 0xfb = .Float,
	0xfc ..= 0xfe = .Reserved,
	0xff = .Break,
}

// The length of an item's head and the shift that leaves its argument in a byte-swapped 8-byte load after the initial
// byte, indexed by additional information up to 27.
@(private, rodata)
HEAD_LEN := [32]u8{0 ..= 23 = 1, 24 = 2, 25 = 3, 26 = 5, 27 = 9}
@(private, rodata)
ARG_SHIFT := [32]u8{24 = 56, 25 = 48, 26 = 32, 27 = 0}

// The head argument of the item at `i` whose initial byte has additional information `ai` of at most 27, and the
// head's length, false when the head is cut short.
@(private)
read_head :: #force_inline proc "contextless" (src: []u8, i: u64, ai: u8) -> (arg: u64, hl: u64, ok: bool) #no_bounds_check {
	if ai < 24 {
		return u64(ai), 1, true
	}
	hl = u64(HEAD_LEN[ai])
	if i + 9 <= u64(len(src)) {
		w := intrinsics.byte_swap(intrinsics.unaligned_load((^u64)(raw_data(src)[i + 1:])))
		return w >> ARG_SHIFT[ai], hl, true
	}
	if i + hl > u64(len(src)) {
		return 0, 0, false
	}
	for b in src[i + 1:i + hl] {
		arg = arg << 8 | u64(b)
	}
	return arg, hl, true
}

@(private)
fault :: #force_inline proc "contextless" (at: u64, kind: tape.Fault_Kind, detail := Detail.None) -> hook.Walk_Result {
	return hook.walk_result(at, u8(kind), u8(detail))
}

// Gives the hook token `t`, growing the hook's room first for a node it has no place for. With `LAX` the walk takes a
// step of `Budget.steps` per container, and stops at the first past it with no token. `.Stop` when the room cannot
// grow.
@(private)
give :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: ^hook.Regs, t: tape.Token, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Action {
	when .Rooms in C {
		if t.kind != .End && t.role <= .Key && uintptr(hs.a) == w.rooms && !grow_room(w, hs, t.lo) {
			return .Stop
		}
	}
	when LAX {
		if t.kind > .Plain && t.kind != .End {
			w.steps[0] -= 1
			if w.steps[0] == 0 {
				return .Stop
			}
		}
	}
	when .Windows in C {
		if w.piece[0] != nil && !piece_track(w, w.piece[0], t) {
			return .Stop
		}
	}
	// A walk with no hook keeps its registers as they are, which the optimizer cannot see from the call alone.
	when H == hook.No_Hooks {
		return .Next
	} else {
		a: hook.Action
		hs^, a = on(w.hooks, hs^, t)
		return a
	}
}

// `grow_room_cold` on a copy of the registers, so that the walk's own stay in machine registers.
@(private)
grow_room :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: ^hook.Regs, at: u64) -> bool {
	r := hs^
	ok := grow_room_cold(w, &r, at)
	hs^ = r
	return ok
}

@(private, cold)
grow_room_cold :: #force_no_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: ^hook.Regs, at: u64) -> bool {
	when .Rooms in C {
		if !hook.rooms_grow(w.hooks, hs, at) {
			return false
		}
		w.rooms = hook.rooms_end(w.hooks)
	}
	return true
}

// Reads the item at `lo` and every item inside it, in the levels `d0` deep whose innermost frame is `top0`, and gives
// their tokens to `on` from registers `regs`, which hold the hook's last registers when it returns. The result's offset
// is one past the root item, with no look at what follows it, or the fault's or the stop's. A fresh item starts with
// `d0` and `top0` 0, where no key is due and a break faults. With `passing` the hook skipped the key before `lo`, whose
// value's tags are still given. In a window of a text in pieces that more bytes follow, an item the window does not
// hold whole ends the walk before it, as `piece_cut` says.
@(private)
run :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), lo, d0, top0: u64, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), passing0 := false) -> hook.Walk_Result #no_bounds_check {
	STRICT :: S != .Cbor
	src := w.src
	n := u64(len(src))
	hs := regs^
	defer regs^ = hs
	i, d, top := lo, d0, top0
	// The hook skipped the key whose value starts at `i`: its tags are given, and the value is judged with no token.
	passing := passing0
	for {
		if i >= n {
			return short(w, i, d, top, passing)
		}
		start := i
		b := src[i]
		ai := b & 31
		key_due := key_is_due(top)
		role := tape.Role.Key if key_due else .Value
		// What the hook answered a scalar, which on a key may be `Skip`.
		a := hook.Action.Next
		// A key is an integer, a byte string or a text string, or the break that ends an indefinite map, which is 0xff.
		if key_due && b - 0x80 < 0x7f {
			return fault(i, .Bad_Char, .Bad_Key)
		}
		when .Skips in C {
			if passing && CLASS[b] != .Tag {
				passing = false
				r := judge_item(w, i, d, 0, 0, hs)
				if u8(r) != 0 {
					return nested(w, r, .Pass, i, d, top)
				}
				i = u64(r) >> 16
				if end := count_down(w, &hs, i, &d, &top, on); end != 0 {
					return end
				}
				continue
			}
		}
		// `Class` has 16 values, which the mask tells the optimizer, so the jump table has no range test.
		switch Class(u8(CLASS[b]) & 15) {
		case .Int:
			arg, hl, ok := read_head(src, i, ai)
			if !ok {
				return short(w, start, d, top, passing)
			}
			if STRICT && !shortest(ai, arg) {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			i += hl
			if a = give(w, &hs, {lo = start, n = u32(hl), kind = .Number, role = role, spelling = NUMBER_INT}, on); a == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .Text:
			arg, hl, ok := read_head(src, i, ai)
			if !ok || arg > n - i - hl {
				return short(w, start, d, top, passing)
			}
			if arg > u64(max(u32)) {
				return fault(i, .Too_Wide)
			}
			q := i + hl
			t := tape.Token{lo = q, n = u32(arg), kind = .String, role = role, spelling = head_spelling(hl)}
			if !ascii_16(src, q, arg) {
				bad, lax := text_scan(src, q, arg, w.lax_utf8)
				if bad >= 0 {
					return fault(q + u64(bad), .Bad_Char, .Invalid_Utf8)
				}
				if lax {
					w.tolerated = true
					t.spelling |= tape.SPELLING_DECODE | tape.SPELLING_LAX
				}
			}
			if STRICT && !shortest(ai, arg) {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			i = q + arg
			if a = give(w, &hs, t, on); a == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .Bytes:
			arg, hl, ok := read_head(src, i, ai)
			if !ok || arg > n - i - hl {
				return short(w, start, d, top, passing)
			}
			if arg > u64(max(u32)) {
				return fault(i, .Too_Wide)
			}
			if STRICT && !shortest(ai, arg) {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			q := i + hl
			// A byte string key reads as the base64 of its payload.
			spelling := head_spelling(hl) | (tape.SPELLING_DECODE if key_due else 0)
			i = q + arg
			if a = give(w, &hs, {lo = q, n = u32(arg), kind = .Bytes, role = role, spelling = spelling}, on); a == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .Array, .Map:
			arg, hl, ok := read_head(src, i, ai)
			if !ok {
				return short(w, start, d, top, passing)
			}
			// The depth limit is judged before the head and its count.
			if d >= w.depth {
				if k := deepen(w, &hs, i); k != 0 {
					return hook.walk_result(i, k)
				}
			}
			if STRICT && !shortest(ai, arg) {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			// A map's count is of pairs, two items each, and every item takes at least a byte.
			pair := u64(b >> 5) & 1
			if arg > (n - i - hl) >> pair {
				if k := count_short(w, i, hl, arg, pair); k != 0 {
					return k
				}
			}
			t := tape.Token{lo = i, n = u32(hl), kind = tape.Kind(u8(tape.Kind.Array) + u8(pair)), role = role}
			i += hl
			// An empty container waits for one item, which the count below supplies at once.
			frame := frame_of(arg, pair)
			if a = give(w, &hs, t, on); a != .Next {
				end, done := opened(w, &hs, a, start, i, d, top, on)
				if done {
					return nested(w, end, nest_of(a), start, d, top)
				}
				i = u64(end) >> 16
				break
			}
			w.stack[d] = {frame = top}
			d += 1
			top = frame
			if arg != 0 {
				continue
			}
		case .False, .True, .Null:
			i += 1
			if give(w, &hs, {lo = start, n = 1, kind = .Null if b == 0xf6 else tape.Kind(b - 0xf3), role = role}, on) == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .Float:
			wide := u64(1) << (ai - 24)
			if i + 1 + wide > n {
				return short(w, start, d, top, passing)
			}
			if STRICT {
				if f := float_fault(src[i + 1:i + 1 + wide], S); f != .None {
					return fault(i, .Bad_Char, f)
				}
			}
			i += 1 + wide
			if give(w, &hs, {lo = start, n = u32(1 + wide), kind = .Number, role = role, spelling = NUMBER_FLOAT}, on) == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .Simple:
			i += 1
			if give(w, &hs, {lo = start, n = 1, kind = .Null, role = role, spelling = simple_spelling(ai)}, on) == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .Simple_8:
			if i + 1 >= n {
				return short(w, start, d, top, passing)
			}
			if src[i + 1] < 32 {
				return fault(i, .Bad_Char, .Bad_Simple)
			}
			i += 2
			if give(w, &hs, {lo = start, n = 2, kind = .Null, role = role, spelling = simple_spelling(src[start + 1])}, on) == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .Tag:
			tag, hl, ok := read_head(src, i, ai)
			if !ok {
				return short(w, start, d, top, passing)
			}
			if STRICT && !shortest(ai, tag) {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			if i + hl >= n || tag == 0 && date_short(w, i + hl) {
				return short(w, start, d, top, passing)
			}
			t := tape.Token{lo = i, n = u32(hl), kind = .Number, role = .Tag}
			i += hl
			if tag >= 2 && tag <= 5 {
				r := folded(src, i, tag, STRICT)
				if r.fault != 0 {
					return short_fault(w, r.fault, start, d, top, passing)
				}
				v := tape.Token{lo = i, n = u32(r.end - i), kind = .Number, role = role, spelling = r.spelling}
				i = r.end
				if give(w, &hs, t, on) == .Stop {
					return hook.walk_result(v.lo, hook.WALK_STOPPED)
				}
				when .Skips in C {
					if passing {
						passing = false
						break
					}
				}
				if give(w, &hs, v, on) == .Stop {
					return hook.walk_result(i, hook.WALK_STOPPED)
				}
				break
			}
			if at := tag_content_fault(src, i, tag); at != NO_FAULT {
				// An indefinite content is refused at its head, which comes first.
				if STRICT && src[i] & 31 == 31 && src[i] >> 5 >= 2 && src[i] >> 5 <= 5 {
					return fault(i, .Bad_Char, .Not_Preferred)
				}
				return fault(at, .Bad_Char, .Bad_Tag_Content)
			}
			if d >= w.depth {
				if k := deepen(w, &hs, start); k != 0 {
					return hook.walk_result(start, k)
				}
			}
			w.stack[d] = {frame = top}
			d += 1
			top = FLAG_TAG | 1
			if give(w, &hs, t, on) == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
			continue
		case .Indefinite_String:
			major := b >> 5
			when !STRICT {
				if end := one_chunk(src, i, major); end != 0 {
					t := tape.Token{lo = i + 1, n = u32(end - i - 2), kind = .Bytes if major == 2 else .String, role = role, spelling = tape.SPELLING_DECODE | STR_INDEF | head_spelling(1)}
					i = end
					if a = give(w, &hs, t, on); a == .Stop {
						return hook.walk_result(i, hook.WALK_STOPPED)
					}
					break
				}
			}
			from, lax := i + 1, false
			when .Windows in C {
				if p := w.piece[0]; p != nil && p.chunks.at == i && p.chunks.read > i {
					from, lax = p.chunks.read, p.chunks.lax
				}
			}
			s := string_item(src, i, major, w.lax_utf8, from, lax)
			if s.fault != 0 {
				when .Windows in C {
					if p := w.piece[0]; p != nil && p.more {
						p.chunks = {i, s.resume, s.lax}
					}
				}
				return short_fault(w, s.fault, start, d, top, passing)
			}
			if STRICT {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			spelling := s.spelling
			if s.spelling & tape.SPELLING_LAX != 0 {
				w.tolerated = true
			}
			if major == 2 && key_due {
				spelling |= tape.SPELLING_DECODE
			}
			i = s.end
			if a = give(w, &hs, {lo = s.lo, n = u32(s.n), kind = .Bytes if major == 2 else .String, role = role, spelling = spelling}, on); a == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .Indefinite_Container:
			if d >= w.depth {
				if k := deepen(w, &hs, i); k != 0 {
					return hook.walk_result(i, k)
				}
			}
			if STRICT {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			pair := u64(b >> 5) & 1
			t := tape.Token{lo = i, n = 1, kind = tape.Kind(u8(tape.Kind.Array) + u8(pair)), role = role, spelling = STYLE_INDEFINITE}
			i += 1
			if a = give(w, &hs, t, on); a != .Next {
				end, done := opened(w, &hs, a, start, i, d, top, on)
				if done {
					return nested(w, end, nest_of(a), start, d, top)
				}
				i = u64(end) >> 16
				break
			}
			w.stack[d] = {frame = top}
			d += 1
			top = indefinite_frame(pair)
			continue
		case .Break:
			if break_refused(top) {
				return fault(i, .Bad_Char, .Bad_Break)
			}
			i += 1
			top = top & ~COUNT_MASK | 1
		case .Reserved:
			if (b >> 5 == 4 || b >> 5 == 5) && d >= w.limit {
				return hook.walk_result(i, hook.WALK_TOO_DEEP)
			}
			return fault(i, .Bad_Char, .Reserved_Info)
		}
		when S >= .Deterministic {
			if key_due && !keys_ordered(src, &w.stack[d - 1].prev[0], start, i, S) {
				return key_fault(src, w.stack[d - 1].prev[0], start, i, w.refuse)
			}
		}
		when .Skips in C {
			// The key leaves its pair's value due, so it completes no frame.
			if a == .Skip && key_due {
				top -= 1
				passing = true
				continue
			}
		}
		if end := count_down(w, &hs, i, &d, &top, on); end != 0 {
			return end
		}
	}
}

// Counts down the frames that the item that ended at `i` completes, in the levels `d` deep whose innermost frame is
// `top`, giving an `End` for each container it closes. Returns the walk's result once the root item ends or the hook
// stops, and 0 while the walk goes on, as a result is never 0 past the first item. A bool beside it is not threaded by
// the optimizer.
@(private)
count_down :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: ^hook.Regs, i: u64, d, top: ^u64, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result #no_bounds_check {
	for {
		if d^ == 0 {
			return hook.walk_result(i, 0)
		}
		top^ -= 1
		if top^ & COUNT_MASK != 0 {
			return 0
		}
		if top^ & FLAG_TAG == 0 {
			if give(w, hs, end_token(i, top^ & FLAG_INDEF != 0), on) == .Stop {
				d^ -= 1
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		}
		d^ -= 1
		top^ = w.stack[d^].frame
	}
}

// The most nodes an item of `src` can make: every node is an item of at least one byte, plus 16 of slack.
@(private)
node_bound :: #force_inline proc "contextless" (src: []u8, depth: u64) -> u64 {
	return u64(len(src)) + 16
}

// Walks `src` and returns the end of its item or the error, and whether the walk used a rule of `opts.tolerate`. Only
// the one item may be in the text, and an empty text holds none.
@(private)
walk_text :: #force_inline proc "contextless" (src: []u8, $S: Spec, $LAX: bool, opts: Options, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	if len(src) == 0 {
		return 0, tape.Fault{rules = &RULES, kind = .Truncated, detail = u8(Detail.No_Item)}, false
	}
	r, took, _ := walk_item(src, 0, S, LAX, opts, build.read_depth(opts), steps_of(opts), h, regs, allocator, ctx, on)
	if u8(r) == 0 && u64(r) >> 16 < u64(len(src)) {
		r = fault(u64(r) >> 16, .Bad_Char, .Trailing)
	}
	at, e, _ := hook.walk_error(r, &RULES)
	return at, e, took
}

// The walk's count of `Budget.steps`, one more than the containers it may open.
@(private)
steps_of :: #force_inline proc "contextless" (opts: Options) -> u64 {
	return opts.budget.steps + 1 if opts.budget.steps != 0 && opts.budget.steps < max(u64) else max(u64)
}

// The result of walking the item at `lo` of `src` within `limit` levels and, with `LAX`, the count `steps` of
// `steps_of`, with the walk's levels in `allocator` past its frame, called in context `ctx`, whether it took a rule of
// `opts.tolerate`, and the steps it leaves. A hook with `.Walk` is given the walk, which its replays borrow. Its offset
// is where the item ends, unless the walk stopped or faulted.
@(private)
walk_item :: #force_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, $LAX: bool, opts: Options, limit, steps: u64, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, tolerated: bool, left: u64) {
	hook.check(H)
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	stack: [WALK_LEVELS]Level(S) = ---
	w: Walk(S, H, LAX, C)
	walk_init(&w, src, h, raw_data(stack[:]), min(limit, MAX_LEVELS), WALK_LEVELS, opts)
	w.allocator, w.ctx = allocator, ctx
	when LAX {
		w.steps[0] = steps
	}
	w.depth = hook.held_depth(h, regs, min(w.limit, WALK_LEVELS))
	when .Rooms in C {
		w.rooms = hook.rooms_end(h)
	}
	when .Walk in C {
		h.walk = &w
	}
	r = run(&w, lo, 0, 0, regs, on)
	when .Walk in C {
		h.walk = nil
	}
	when LAX {
		if u8(r) == hook.WALK_STOPPED && w.steps[0] == 0 {
			r = hook.walk_result(u64(r) >> 16, hook.WALK_STEPS)
		}
		left = w.steps[0]
	} else {
		left = steps
	}
	if w.owned {
		hook.levels_free(&w)
	}
	return r, w.tolerated, left
}
