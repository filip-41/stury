package msgpack

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Iterative zero-recursion walk of a MessagePack item, checking wire validity, UTF-8, `.Compact` rules,
// timestamps, and depth/node/step budgets while feeding tokens to the hook.

// Inline open container stack capacity in the walk's stack frame before heap spill.
WALK_LEVELS :: 1024

// Inline stack capacity for rewalks inside `find` / `scan`.
@(private)
REWALK_LEVELS :: 64

@(private)
MAX_LEVELS :: u64(max(int) / size_of(Level))

#assert(size_of(Walk(.Msgpack, hook.No_Hooks, true, hook.NO_HOOKS_CAPS)) + WALK_LEVELS * size_of(Level) <= 32 * 1024)

// Guaranteed stack budget below caller frame.
READ_STACK :: 48 * 1024

// Open container frame holding remaining item slots in bits 0..55 and `FLAG_OBJECT` in bit 62.
@(private)
Level :: struct {
	frame: u64,
}

#assert(tape.Kind.False == tape.Kind(1) && tape.Kind.True == tape.Kind(2))
#assert(tape.Kind.Object == tape.Kind(u8(tape.Kind.Array) + 1))

@(private)
FLAG_OBJECT :: u64(1) << 62
@(private)
COUNT_MASK :: u64(1) << 56 - 1
#assert(FLAG_OBJECT & COUNT_MASK == 0)

@(private)
frame_of :: #force_inline proc "contextless" (arg, pair: u64) -> u64 {
	return max(arg << pair, 1) | pair << 62
}

@(private)
key_is_due :: #force_inline proc "contextless" (top: u64) -> bool {
	return top & (FLAG_OBJECT | 1) == FLAG_OBJECT
}

@(private)
Walk :: struct($S: Spec, $H: typeid, $LAX: bool, $C: hook.Capabilities) {
	src:       []u8,
	whole:     u64,
	hooks:     ^H,
	rooms:     uintptr,
	stack:     [^]Level,
	allocator: runtime.Allocator,
	ctx:       ^runtime.Context,
	depth:     u64,
	limit:     u64,
	room:      u64,
	owned:     bool,
	lax_utf8:  bool,
	tolerated: bool,
	steps:     [int(LAX)]u64,
	piece:     [1]^Piece,
}

@(private)
walk_init :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), src: []u8, h: ^H, stack: [^]Level, limit, room: u64, opts: Options) {
	w.src, w.hooks, w.stack, w.limit, w.room = src, h, stack, limit, room
	w.lax_utf8 = .Invalid_Utf8 in opts.tolerate
}

@(private)
WINDOWS :: hook.Capabilities{.Windows}

@(private)
Class :: enum u8 {
	Fixint,      // 0x00..0x7f, 0xe0..0xff
	Fixmap,      // 0x80..0x8f
	Fixarray,    // 0x90..0x9f
	Fixstr,      // 0xa0..0xbf
	Nil,         // 0xc0
	Reserved,    // 0xc1
	False,       // 0xc2
	True,        // 0xc3
	Bin_N,       // 0xc4..0xc6
	Ext_N,       // 0xc7..0xc9
	Float,       // 0xca..0xcb
	Uint_N,      // 0xcc..0xcf
	Int_N,       // 0xd0..0xd3
	Fixext,      // 0xd4..0xd8
	Str_N,       // 0xd9..0xdb
	Container_N, // 0xdc..0xdf
}

@(private, rodata)
CLASS := [256]Class {
	0x00 ..= 0x7f = .Fixint,
	0x80 ..= 0x8f = .Fixmap,
	0x90 ..= 0x9f = .Fixarray,
	0xa0 ..= 0xbf = .Fixstr,
	0xc0 = .Nil,
	0xc1 = .Reserved,
	0xc2 = .False,
	0xc3 = .True,
	0xc4 ..= 0xc6 = .Bin_N,
	0xc7 ..= 0xc9 = .Ext_N,
	0xca ..= 0xcb = .Float,
	0xcc ..= 0xcf = .Uint_N,
	0xd0 ..= 0xd3 = .Int_N,
	0xd4 ..= 0xd8 = .Fixext,
	0xd9 ..= 0xdb = .Str_N,
	0xdc ..= 0xdf = .Container_N,
	0xe0 ..= 0xff = .Fixint,
}

// Allowed map key lead bytes (integers, strings, binaries). Non-(int|str|bin) keys are rejected cleanly as `.Bad_Key`
// while `0xc1` is checked first as `.Reserved_Type`.
@(private, rodata)
KEY_ALLOWED := [256]bool {
	0x00 ..= 0x7f = true,
	0xa0 ..= 0xbf = true,
	0xc4 ..= 0xc6 = true,
	0xcc ..= 0xd3 = true,
	0xd9 ..= 0xdb = true,
	0xe0 ..= 0xff = true,
}

// Width (in bytes) of the unsigned integer argument following each non-fix format byte, indexed by `0xc4..0xdf`.
// Indexed via `ARG_WIDTH[b]`: 1, 2, 4, or 8.
@(private, rodata)
ARG_WIDTH := [256]u8 {
	0xc4 = 1, 0xc5 = 2, 0xc6 = 4,
	0xc7 = 1, 0xc8 = 2, 0xc9 = 4,
	0xca = 4, 0xcb = 8,
	0xcc = 1, 0xcd = 2, 0xce = 4, 0xcf = 8,
	0xd0 = 1, 0xd1 = 2, 0xd2 = 4, 0xd3 = 8,
	0xd9 = 1, 0xda = 2, 0xdb = 4,
	0xdc = 2, 0xdd = 4, 0xde = 2, 0xdf = 4,
}

@(private, rodata)
WIDTH_SHIFT := [9]u8{1 = 56, 2 = 48, 4 = 32, 8 = 0}

@(private)
container_head_len :: #force_inline proc "contextless" (b: u8) -> u8 {
	if b == 0xdc || b == 0xde {
		return 3
	}
	if b == 0xdd || b == 0xdf {
		return 5
	}
	return 1
}

// Reads `wlen` big-endian argument bytes (`1`, `2`, `4`, or `8`) at `src[i + 1:]` and returns total header length `1 + wlen` (or `2 + wlen` for `ext 8/16/32` by caller).
@(private)
read_arg :: #force_inline proc "contextless" (src: []u8, i: u64, wlen: u8) -> (arg: u64, ok: bool) #no_bounds_check {
	w := u64(wlen)
	if i + 9 <= u64(len(src)) {
		val := intrinsics.byte_swap(intrinsics.unaligned_load((^u64)(raw_data(src)[i + 1:])))
		return val >> WIDTH_SHIFT[wlen], true
	}
	if w > u64(len(src)) - i - 1 {
		return 0, false
	}
	for k in u64(0) ..< w {
		arg = arg << 8 | u64(src[i + 1 + k])
	}
	return arg, true
}

@(private)
sign_extend :: #force_inline proc "contextless" (arg: u64, wlen: u8) -> i64 {
	switch wlen {
	case 1:
		return i64(i8(arg))
	case 2:
		return i64(i16(arg))
	case 4:
		return i64(i32(arg))
	}
	return i64(arg)
}

@(private)
fault :: #force_inline proc "contextless" (at: u64, kind: tape.Fault_Kind, detail := Detail.None) -> hook.Walk_Result {
	return hook.walk_result(at, u8(kind), u8(detail))
}

@(private)
give :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), hs: ^hook.Regs, t: tape.Token, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), d: u64 = 0) -> hook.Action {
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
		if s := w.piece[0]; s != nil && !piece_track(w, s, t, d) {
			return .Stop
		}
	}
	when H == hook.No_Hooks {
		return .Next
	} else {
		a: hook.Action
		hs^, a = on(w.hooks, hs^, t)
		return a
	}
}

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

// Walks the item starting at `lo` iteratively. Returns one past the item's last byte, or fault/stop.
@(private)
run :: proc "contextless" (w: ^Walk($S, $H, $LAX, $C), lo, d0, top0: u64, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), passing0 := false) -> hook.Walk_Result #no_bounds_check {
	STRICT :: S == .Compact
	src := w.src
	n := u64(len(src))
	hs := regs^
	defer regs^ = hs
	i, d, top := lo, d0, top0
	passing := passing0
	for {
		if i >= n {
			return short(w, i, d, top, passing)
		}
		start := i
		b := src[i]
		key_due := key_is_due(top)
		role := tape.Role.Key if key_due else .Value
		a := hook.Action.Next
		when .Skips in C {
			if passing {
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
		if b == 0xc1 {
			return fault(i, .Bad_Char, .Reserved_Type)
		}
		if key_due && !KEY_ALLOWED[b] {
			return fault(i, .Bad_Char, .Bad_Key)
		}
		switch Class(u8(CLASS[b]) & 15) {
		case .Fixint:
			i += 1
			if a = give(w, &hs, {lo = start, n = 1, kind = .Number, role = role, spelling = NUMBER_INT}, on); a == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .Uint_N:
			wlen := ARG_WIDTH[b]
			arg, ok := read_arg(src, i, wlen)
			if !ok {
				return short(w, start, d, top, passing)
			}
			if STRICT && !compact_uint_ok(b, arg) {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			hl := u64(1 + wlen)
			i += hl
			if a = give(w, &hs, {lo = start, n = u32(hl), kind = .Number, role = role, spelling = NUMBER_INT}, on); a == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .Int_N:
			wlen := ARG_WIDTH[b]
			arg, ok := read_arg(src, i, wlen)
			if !ok {
				return short(w, start, d, top, passing)
			}
			if STRICT && !compact_int_ok(b, sign_extend(arg, wlen)) {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			hl := u64(1 + wlen)
			i += hl
			if a = give(w, &hs, {lo = start, n = u32(hl), kind = .Number, role = role, spelling = NUMBER_INT}, on); a == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .Fixstr:
			arg := u64(b & 0x1f)
			q := i + 1
			if arg > n - q {
				return short(w, start, d, top, passing)
			}
			t := tape.Token{lo = q, n = u32(arg), kind = .String, role = role, spelling = head_spelling(1)}
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
			i = q + arg
			when .Expects in C {
				if key_due && expected_text(hs.b, src, q, arg) {
					hs.b += hook.EXPECTED_STRIDE
					break
				}
			}
			if a = give(w, &hs, t, on); a == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .Str_N:
			wlen := ARG_WIDTH[b]
			arg, ok := read_arg(src, i, wlen)
			hl := u64(1 + wlen)
			if !ok || arg > n - i - hl {
				return short(w, start, d, top, passing)
			}
			if STRICT && !compact_str_ok(b, arg) {
				return fault(i, .Bad_Char, .Not_Preferred)
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
			i = q + arg
			when .Expects in C {
				if key_due && expected_text(hs.b, src, q, arg) {
					hs.b += hook.EXPECTED_STRIDE
					break
				}
			}
			if a = give(w, &hs, t, on); a == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .Bin_N:
			wlen := ARG_WIDTH[b]
			arg, ok := read_arg(src, i, wlen)
			hl := u64(1 + wlen)
			if !ok || arg > n - i - hl {
				return short(w, start, d, top, passing)
			}
			if STRICT && !compact_bin_ok(b, arg) {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			q := i + hl
			spelling := head_spelling(hl) | (tape.SPELLING_DECODE if key_due else 0)
			i = q + arg
			if a = give(w, &hs, {lo = q, n = u32(arg), kind = .Bytes, role = role, spelling = spelling}, on); a == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .Fixext, .Ext_N:
			arg, hl: u64
			if b >= 0xd4 {
				hl = 2
				arg = u64(1) << (b - 0xd4)
				if hl > n - i || arg > n - i - hl {
					return short(w, start, d, top, passing)
				}
			} else {
				wlen := ARG_WIDTH[b]
				ok: bool
				arg, ok = read_arg(src, i, wlen)
				hl = u64(2 + wlen)
				if !ok || hl > n - i || arg > n - i - hl {
					return short(w, start, d, top, passing)
				}
				if STRICT && !compact_ext_ok(b, arg) {
					return fault(start, .Bad_Char, .Not_Preferred)
				}
			}
			q := i + hl
			ext_type := i8(src[q - 1])
			vkind := tape.Kind.Bytes
			vspell := head_spelling(hl) | STR_EXT
			if ext_type == -1 {
				sec, nsec, ts_ok := timestamp_decode(src[q:q + arg])
				if !ts_ok {
					return fault(start, .Bad_Char, .Bad_Timestamp)
				}
				if STRICT && !timestamp_preferred(arg, sec, nsec) {
					return fault(start, .Bad_Char, .Not_Preferred)
				}
				vkind = .String
				vspell |= tape.SPELLING_DECODE | tape.SPELLING_LAX | STR_TIMESTAMP
			}
			i = q + arg
			if give(w, &hs, {lo = start, n = u32(hl), kind = .Number, role = .Tag}, on) == .Stop {
				return hook.walk_result(q, hook.WALK_STOPPED)
			}
			if give(w, &hs, {lo = q, n = u32(arg), kind = vkind, role = role, spelling = vspell}, on) == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .Fixarray, .Fixmap:
			if d >= w.depth {
				if k := deepen(w, &hs, i); k != 0 {
					return hook.walk_result(i, k)
				}
			}
			arg := u64(b & 0x0f)
			pair := u64(1) if b < 0x90 else u64(0)
			if arg > (n - i - 1) >> pair {
				if k := count_short(w, i, 1, arg, pair); k != 0 {
					return k
				}
			}
			t := tape.Token{lo = i, n = 1, kind = tape.Kind(u8(tape.Kind.Array) + u8(pair)), role = role}
			i += 1
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
		case .Container_N:
			wlen := ARG_WIDTH[b]
			arg, ok := read_arg(src, i, wlen)
			if !ok {
				return short(w, start, d, top, passing)
			}
			if d >= w.depth {
				if k := deepen(w, &hs, i); k != 0 {
					return hook.walk_result(i, k)
				}
			}
			if STRICT && !compact_container_ok(b, arg) {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			hl := u64(1 + wlen)
			pair := u64(b >= 0xde)
			if arg > (n - i - hl) >> pair {
				if k := count_short(w, i, hl, arg, pair); k != 0 {
					return k
				}
			}
			t := tape.Token{lo = i, n = u32(hl), kind = tape.Kind(u8(tape.Kind.Array) + u8(pair)), role = role}
			i += hl
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
		case .Nil:
			i += 1
			if give(w, &hs, {lo = start, n = 1, kind = .Null, role = role}, on) == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .False, .True:
			i += 1
			if give(w, &hs, {lo = start, n = 1, kind = tape.Kind(b - 0xc1), role = role}, on) == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .Float:
			wide := u64(ARG_WIDTH[b])
			if wide > n - i - 1 {
				return short(w, start, d, top, passing)
			}
			if STRICT && b == 0xcb {
				bits := intrinsics.byte_swap(intrinsics.unaligned_load((^u64)(raw_data(src)[i + 1:])))
				if double_fits_single(bits) {
					return fault(i, .Bad_Char, .Not_Preferred)
				}
			}
			i += 1 + wide
			if give(w, &hs, {lo = start, n = u32(1 + wide), kind = .Number, role = role, spelling = NUMBER_FLOAT}, on) == .Stop {
				return hook.walk_result(i, hook.WALK_STOPPED)
			}
		case .Reserved:
			return fault(i, .Bad_Char, .Reserved_Type)
		}
		when .Skips in C {
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
		if give(w, hs, end_token(i), on, d^) == .Stop {
			d^ -= 1
			return hook.walk_result(i, hook.WALK_STOPPED)
		}
		d^ -= 1
		top^ = w.stack[d^].frame
	}
}

@(private)
node_bound :: #force_inline proc "contextless" (src: []u8, depth: u64) -> u64 {
	_ = depth
	return u64(len(src)) + 16
}

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

@(private)
steps_of :: #force_inline proc "contextless" (opts: Options) -> u64 {
	return opts.budget.steps + 1 if opts.budget.steps != 0 && opts.budget.steps < max(u64) else max(u64)
}

@(private)
walk_item :: #force_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, $LAX: bool, opts: Options, limit, steps: u64, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (r: hook.Walk_Result, tolerated: bool, left: u64) {
	hook.check(H)
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	stack: [WALK_LEVELS]Level = ---
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
		r = hook.steps_result(r, w.steps[0])
		left = w.steps[0]
	} else {
		left = steps
	}
	if w.owned {
		hook.levels_free(&w)
	}
	return r, w.tolerated, left
}

@(private)
expected_text :: #force_inline proc "contextless" (b: u64, src: []u8, q, n: u64) -> bool #no_bounds_check {
	e := (^hook.Expected_Key)(uintptr(b))
	if e.word != tape.key_word(n) || q + 8 > u64(len(src)) {
		return false
	}
	p := raw_data(src)[q:]
	if n <= 8 {
		return (kernel.load8(p) ~ e.head) & e.tail == 0
	}
	return n <= 16 && kernel.load8(p) == e.head && kernel.load8(p[n - 8:]) == e.tail
}
