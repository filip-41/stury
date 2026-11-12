// The walk of a CBOR data item (RFC 8949). One loop reads the item and every item inside it, judges each byte it
// reads and sends tokens to the hook. A tag is a fact before its content, and tags 2 to 5 are folded into the one
// number they spell.
package cbor

import "base:intrinsics"
import "base:runtime"
import "core:simd"
import spell "../core/spell"
import core "../core"
import kernel "../core/kernel"

// The rules an item is read and written by. `.Cbor` reads every well-formed item of RFC 8949. `.Preferred` refuses an
// item not in preferred serialization (section 4.1): a head argument wider than its value needs, a float that a
// narrower float holds exactly, an indefinite length, and a bignum that fits an integer. `.Deterministic` adds the
// sorted keys of section 4.2.1, with every key distinct and the one NaN `f97e00`, and `.Length_First` sorts the keys by
// length first, as section 4.2.3 does. A write writes what its spec reads. A sequence of items (RFC 8742) is a
// framing, not a spec.
Spec :: enum u8 {
	Cbor,
	Preferred,
	Deterministic,
	Length_First,
}

// `Options` holds a walk's run-time options. The zero value is the default.
Options :: struct {
	// The deepest nesting an item may have, 0 and any larger value for `MAX_DEPTH`. A tag counts as a level.
	max_depth: u32,
	// The rules an item may break, each with a fixed reading. `.Invalid_Utf8` reads an ill-formed text string with
	// each maximal subpart as U+FFFD.
	tolerate:  bit_set[core.Tolerance; u8],
	// How a typed write writes a struct. A typed read takes either form.
	structs:   Struct_Form,
}

// `Detail` holds CBOR's detail for a `core.Fault_Kind`, in `core.Fault.detail`.
Detail :: enum u8 {
	None,
	Reserved_Info, // `Bad_Char`: additional information 28 to 30, or 31 on an item that cannot be indefinite
	Bad_Simple, // `Bad_Char`: the two-byte simple value `f8` with a value below 32
	Bad_Break, // `Bad_Char`: a break outside an indefinite item, or where a map's value is due
	Bad_Chunk, // `Bad_Char`: a chunk of an indefinite string that is not a definite string of its major type
	Invalid_Utf8, // `Bad_Char`: a text string that is not UTF-8
	Bad_Key, // `Bad_Char`: a map key that is not an integer, a text string or a byte string
	Bad_Tag_Content, // `Bad_Char`: the content of a tag whose meaning the content does not fit
	Count_Too_Large, // `Truncated`: a count that the bytes left cannot hold, at its head
	Trailing, // `Bad_Char`: bytes after the item
	No_Item, // `Truncated`: no item
	Not_Preferred, // `Bad_Char`: an item not in preferred serialization
	Key_Order, // `Bad_Char`: a key that does not follow the one before it
	Bad_Nan, // `Bad_Char`: a NaN other than `f97e00`
}

// CBOR's rules, indexed by `Detail`. Every fault the walk returns points to this table.
@(rodata)
RULES := core.Rules{"cbor", {
	{},
	{"reserved_info", "Reserved additional information"},
	{"bad_simple", "Two-byte simple value below 32"},
	{"bad_break", "Break outside an indefinite item"},
	{"bad_chunk", "Chunk of an indefinite string is no definite string of its type"},
	{"invalid_utf8", "Text string is not UTF-8"},
	{"bad_key", "Map key is no integer, text string or byte string"},
	{"bad_tag_content", "Tag content does not fit the tag"},
	{"count_too_large", "Count larger than the bytes left"},
	{"trailing", "Bytes after the item"},
	{"no_item", "No data item"},
	{"not_preferred", "Item is not in preferred serialization"},
	{"key_order", "Map key out of order"},
	{"bad_nan", "NaN other than f97e00"},
}}

// The handle of a CBOR item of `spec` read or written with `opts`, which reaches every service of the format.
as :: proc "contextless" (spec: Spec, opts := Options{}) -> core.As {
	return as_of(&HANDLE if spec <= max(Spec) else nil, spec, opts)
}

// The walk's verdict on `src`, which is exactly one item, judged as `spec` says. Returns the fault, or nil. A constant
// `spec` links the walk alone. A `spec` chosen at run time is `core.validate` with `as(spec, opts)` and links every
// service of the format. The same holds for the other entry points of the package. A document that a constant `spec`
// builds holds no services, so `query`, `edit_list_init` and `write` of this package serve it where the same names of
// `core` serve a handle's.
validate :: proc {validate_bound, validate_chosen}

@(private)
validate_bound :: proc "contextless" (src: []u8, $S: Spec, opts := Options{}) -> core.Error {
	return core.error_of(validate_text(src, rules_of(S, opts)))
}

@(private)
validate_chosen :: #force_inline proc "contextless" (src: []u8, spec: Spec, opts := Options{}) -> core.Error {
	return core.validate(src, as(spec, opts))
}

// Reads the one item in `src` into a document, as `core.build` does with `as(spec, opts)`.
build :: proc {build_bound, build_chosen}

@(private)
build_bound :: proc(src: []u8, $S: Spec, opts := Options{}, dups := core.Duplicates.Last, allocator := context.allocator) -> (core.Document, core.Error) {
	doc, err := build_item(src, bound_as(S, opts), dups == .Refuse, allocator)
	return doc, core.error_of(err)
}

@(private)
build_chosen :: #force_inline proc(src: []u8, spec: Spec, opts := Options{}, dups := core.Duplicates.Last, allocator := context.allocator) -> (core.Document, core.Error) {
	return core.build(src, as(spec, opts), dups, allocator)
}

// Writes node `node` of `doc` as one CBOR item of `spec`, as `core.write` does with `as(spec)`.
write :: proc {write_bound, write_chosen}

@(private)
write_bound :: proc(doc: ^core.Document, $S: Spec, opts := core.Write_Options{}, node := core.ROOT, allocator := context.allocator) -> (text: []u8, dropped: int, err: core.Error) {
	if int(node) >= len(doc.nodes) || doc.nodes[node].role == .Key {
		return nil, 0, core.error_of(core.Typed_Refusal{kind = .Unsupported})
	}
	out, cut, refusal := document_write(doc, opts, bound_as(S), node, {}, allocator)
	return out, cut, core.error_of(refusal)
}

@(private)
write_chosen :: #force_inline proc(doc: ^core.Document, spec: Spec, opts := core.Write_Options{}, node := core.ROOT, allocator := context.allocator) -> (text: []u8, dropped: int, err: core.Error) {
	return core.write(doc, opts, as(spec), node, allocator)
}

// Reads the item at `lo` of spec `S` through the hook. Returns one past the item, or the fault. A hook that stops the
// walk ends the read with no fault, and `hi` is one past the token it stopped on. `regs` is passed to the first token
// and holds what the hook returned last, and a nil `regs` starts from zero registers and keeps none. A `lo` at the end
// of `src` reads no item and returns `hi` equal to it. With a `cursor`, a stop saves where the walk stood there for
// `walk_resume`.
walk :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^Cursor = nil) -> (hi: u64, fault: Maybe(core.Fault)) {
	if cursor != nil {
		cursor_destroy(cursor)
		cursor.src, cursor.n = raw_data(src), u64(len(src))
	}
	zero: core.Hook_Regs
	r := regs if regs != nil else &zero
	return cursor_result(run(src, lo, rules_of(S, opts), h, r, on, S != .Cbor, cursor), cursor)
}

// `Cursor` holds where a walk a hook stopped stands, for `walk_resume` to continue it: the text's address and length,
// and on the default heap the walk's frames, the place it stopped at and the hook's registers. The bytes past the stop
// are judged as the resumed walk reads them. A walk that ends frees what its cursor holds, and `cursor_destroy` frees
// a cursor no resume ended.
Cursor :: struct {
	src:  [^]u8,
	n:    u64,
	held: ^Held,
}

// What a cursor holds past a stop: the frames and, for a strict spec, the last key of each map, the place, and the
// hook's registers.
@(private)
Held :: struct {
	stack: [core.MAX_DEPTH]u64,
	prevs: [core.MAX_DEPTH][2]u64,
	place: Place,
	regs:  core.Hook_Regs,
}

// Where a stopped walk stands: `i` is past the token it stopped on, and the item at `start` waits for what `phase`
// names. Whether that item is a key follows from `top`, which no scalar changes and no container or tag leaves due.
// `start` is kept for a spec that orders keys alone.
@(private)
Place :: struct {
	fold:  core.Token,
	top:   u64,
	i:     int,
	start: int,
	d:     int,
	phase: Phase,
}

// What follows a stop: the next item, the end of the item at `start` with its key order checked when it is a key, or
// the folded number `fold` of a tag 2 to 5 whose tag token the walk stopped on.
@(private)
Phase :: enum u8 {
	Next,
	Ended,
	Fold,
}

// Whether `cursor` holds a stop that `walk_resume` continues, false once the walk it fills ended.
can_resume :: #force_inline proc "contextless" (cursor: ^Cursor) -> bool {
	return cursor.held != nil
}

// Continues the walk `cursor` holds a stop of, over the same `src`, from the token after the one it stopped on.
// `regs` is passed to the first token in place of the registers the stop saved, unless it is nil. The results are
// `walk`'s. A cursor that holds no stop, or that a walk of another text filled, is refused with `.Bad_Option`.
walk_resume :: proc "contextless" (src: []u8, cursor: ^Cursor, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	if cursor.held == nil || cursor.src != raw_data(src) || cursor.n != u64(len(src)) {
		return 0, core.Fault{rules = &RULES, kind = .Bad_Option}
	}
	r := regs if regs != nil else &cursor.held.regs
	return cursor_result(run(src, 0, rules_of(S, opts), h, r, on, S != .Cbor, cursor), cursor)
}

// Frees what `cursor` holds, a stop no resume ended. It is a member of `destroy`.
@(private)
cursor_destroy :: proc "contextless" (cursor: ^Cursor) {
	if cursor.held != nil {
		context = runtime.default_context()
		free(cursor.held)
		cursor.held = nil
	}
}

// The results of a walk's result word, freeing what `cursor` holds unless the walk stopped.
@(private)
cursor_result :: proc "contextless" (word: u64, cursor: ^Cursor) -> (hi: u64, fault: Maybe(core.Fault)) {
	stopped: bool
	hi, fault, stopped = core.result_of(word, &RULES)
	if !stopped && cursor != nil {
		cursor_destroy(cursor)
	}
	return
}

// Saves a stop at `at` in `cursor`, with the open frames and the last key of each open map, and returns `halt`, the
// stop's result word. A nil `cursor` saves nothing.
@(private)
hold :: #force_no_inline proc "contextless" (cursor: ^Cursor, halt: u64, at: Place, stack: []u64, prevs: [][2]u64, regs: core.Hook_Regs) -> u64 {
	if cursor == nil {
		return halt
	}
	if cursor.held == nil {
		context = runtime.default_context()
		if cursor.held = new(Held); cursor.held == nil {
			return fault(0, .No_Memory)
		}
	}
	s := cursor.held
	s.place, s.regs = at, regs
	copy(s.stack[:], stack)
	copy(s.prevs[:], prevs)
	return halt
}

// CBOR's `Readers.text`, exported so a caller that knows the format calls it without the table: the text of a string
// token or of a key, a text string, a byte string's payload, or an integer key's decimal digits. Returns the span as it
// stands for a string that needs no decode, else decodes it into `buf`, which `core.text_room` sizes. A container and
// a number return false.
text :: proc(v: ^core.Token_View, t: core.Token, buf: []u8) -> (s: string, ok: bool) {
	return decode(v.src, t, buf)
}

// The frame of an open item, one `u64` per level: the number of items it still waits for in the low 56 bits, and flags.
// A map waits for two items per pair, so its key is due while the count is even. An indefinite item holds
// `INDEF_COUNT` and the break byte ends it. A tag waits for its one content item.
@(private)
FLAG_OBJECT :: u64(1) << 62
@(private)
FLAG_INDEF :: u64(1) << 61
@(private)
FLAG_TAG :: u64(1) << 60
@(private)
COUNT_MASK :: u64(1) << 56 - 1
@(private)
INDEF_COUNT :: u64(1) << 55

// A string token's `spelling`: bit 0 `SPELLING_DECODE` when the text is not the span as it stands, bit 2 `SPELLING_LAX`
// for a tolerated ill-formed sequence, bit 3 `STR_INDEF` for a span that is the chunks of an indefinite string, bits 4 to 7
// the length of the string's head, and bit 8 `INT_KEY` for a key that is an integer, whose text is its decimal digits.
@(private)
STR_INDEF :: u16(8)
@(private)
HEAD_SHIFT :: 4
@(private)
INT_KEY :: u16(1 << 8)

// A number token's kind in `spelling`, above `core.NUMBER_DECIMAL`, so every CBOR number reads through `number`. `FRACTION`
// marks a number that is not spelled as an integer, a float, a decimal fraction and a bigfloat, in the bits
// `core.number_shape` reads as a fraction's, so a typed read takes it into no integer. `NEGATIVE` marks a bignum of tag
// 3, below those bits, so a negative bignum is an integer still.
@(private)
CN_INT :: u16(4)
@(private)
CN_FLOAT :: u16(6)
@(private)
CN_BIG :: u16(8)
@(private)
CN_DEC :: u16(10)
@(private)
CN_BIGFLOAT :: u16(12)
@(private)
FRACTION :: u16(1 << 9)
@(private)
NEGATIVE :: u16(1 << 4)

// The spelling of a simple value that is no boolean and no null, a `Null` token: the value plus one, shifted past bit 0.
@(private)
simple_spelling :: #force_inline proc "contextless" (v: u8) -> u16 {
	return (u16(v) + 1) << 1
}

@(private)
fault :: #force_inline proc "contextless" (at: int, kind: spell.Fault_Kind, detail: Detail = .None) -> u64 {
	return core.fault_at(u64(at), kind, u8(detail))
}

// Reads the head argument of an item whose first byte has additional information `ai` of at most 27. Returns false when
// the item is cut short.
@(private)
read_head :: #force_inline proc "contextless" (src: []u8, i: int, ai: u8) -> (arg: u64, hl: int, ok: bool) {
	if ai < 24 {
		return u64(ai), 1, true
	}
	hl = 1 + 1 << (ai - 24)
	if i + hl > len(src) {
		return 0, 0, false
	}
	for b in src[i + 1:i + hl] {
		arg = arg << 8 | u64(b)
	}
	return arg, hl, true
}

// Whether `arg` is the shortest argument additional information `ai` can carry.
@(private)
shortest :: #force_inline proc "contextless" (ai: u8, arg: u64) -> bool {
	switch ai {
	case 24:
		return arg >= 24
	case 25:
		return arg > 0xff
	case 26:
		return arg > 0xffff
	case 27:
		return arg > 0xffff_ffff
	}
	return true
}

// A walk's output state: the hook's registers, and the part of the item a `Skip` passes without tokens.
@(private)
Sending :: struct {
	regs:       core.Hook_Regs,
	mute_at:    int,
	muted:      bool,
	skip_value: bool,
}

// Gives token `t` to the hook unless a `Skip` mutes it, and applies the hook's action. `depth` is the depth a container
// `t` opens. Returns whether the hook stopped the walk.
@(private)
send :: #force_inline proc "contextless" (o: ^Sending, h: ^$H, t: core.Token, depth: int, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> bool {
	if o.muted {
		return false
	}
	if o.skip_value {
		if t.role == .Tag {
			return false
		}
		o.skip_value = false
		if t.kind == .Array || t.kind == .Object {
			o.muted, o.mute_at = true, depth
		}
		return false
	}
	a: core.Action
	o.regs, a = on(h, o.regs, t)
	switch a {
	case .Next, .Keep:
	case .Skip:
		if t.kind == .Array || t.kind == .Object {
			o.muted, o.mute_at = true, depth
		} else if t.role == .Key {
			o.skip_value = true
		}
	case .Stop:
		return true
	}
	return false
}

@(private)
stopped :: #force_inline proc "contextless" (t: core.Token) -> u64 {
	return core.fault_at(t.lo + u64(t.n), .None, core.STOPPED)
}

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

@(private)
Lanes :: #simd[16]u8

// The length of an item's head and the shift that leaves its argument in a byte-swapped 8-byte load after the initial
// byte, indexed by additional information up to 27.
@(private, rodata)
HEAD_LEN := [32]u8{0 ..= 23 = 1, 24 = 2, 25 = 3, 26 = 5, 27 = 9}
@(private, rodata)
ARG_SHIFT := [32]u8{24 = 56, 25 = 48, 26 = 32, 27 = 0}

// `read_head`. An argument the initial byte holds returns at once, and a wider one is one unaligned load with no
// branch on its width while 9 bytes remain at `i`.
@(private)
head :: #force_inline proc "contextless" (src: []u8, i: int, ai: u8) -> (arg: u64, hl: int, ok: bool) #no_bounds_check {
	// `ai` is at most 27, which every caller's class says.
	if ai < 24 {
		return u64(ai), 1, true
	}
	if i + 9 <= len(src) {
		w := intrinsics.byte_swap(intrinsics.unaligned_load((^u64)(raw_data(src)[i + 1:])))
		return w >> ARG_SHIFT[ai], int(HEAD_LEN[ai]), true
	}
	return read_head(src, i, ai)
}

// Returns where the text string key at `i` ends when it is the one `regs.b` points to, and moves `regs.b` to the next
// record, and 0 otherwise. The record holds a valid name and its shortest head, so a key that matches it is judged.
@(private)
expected_key :: #force_inline proc "contextless" (src: []u8, i: int, regs: ^core.Hook_Regs, $H: typeid) -> int #no_bounds_check {
	if i + 16 > len(src) {
		return 0
	}
	e := (^core.Expected_Key)(uintptr(regs.b))
	p := raw_data(src)[i:]
	w0 := u64(intrinsics.unaligned_load((^u64le)(p)))
	w1 := u64(intrinsics.unaligned_load((^u64le)(p[8:])))
	if (w0 ~ e.word[0]) & e.mask[0] | (w1 ~ e.word[1]) & e.mask[1] != 0 {
		return 0
	}
	if e.n > 16 {
		if i + int(e.n) > len(src) {
			return 0
		}
		for k in 0 ..< int(e.n) - 16 {
			if p[16 + k] != e.rest[k] {
				return 0
			}
		}
	}
	regs.b += u64(size_of(intrinsics.type_elem_type(intrinsics.type_field_type(H, "expect"))))
	return i + int(e.n)
}

// Whether the `n` bytes at `q`, at most 16, are ASCII by one 16-byte load, which needs 16 bytes left at `q`. A false is
// no fault: `text_fault` then judges them.
@(private)
ascii_16 :: #force_inline proc "contextless" (src: []u8, q: int, n: u64) -> bool #no_bounds_check {
	if n > 16 || q + 16 > len(src) {
		return false
	}
	v := intrinsics.unaligned_load((^Lanes)(raw_data(src)[q:]))
	live := simd.lanes_lt(simd.indices(Lanes), Lanes(u8(n)))
	return simd.reduce_max(simd.bit_and(v, live)) < 0x80
}

// What of a handle a walk reads, so an option only a write takes does not reach it.
@(private)
Walk_Rules :: struct {
	max_depth: u32,
	tolerate:  bit_set[core.Tolerance; u8],
	spec:      Spec,
}

@(private)
rules_of :: #force_inline proc "contextless" (spec: Spec, opts: Options) -> Walk_Rules {
	return {opts.max_depth, opts.tolerate, spec}
}

// Reads the one item at `lo` and sends its tokens to `on`, with `STRICT` compiling in the encoding rules of `opts.spec`.
// Returns the result word of `core.result_of`: the end of the item, or the fault. The initial byte's class picks the
// item's case, and every case but a tag's sends its token with no call. An item that finishes counts down the frames
// it completes. A `cursor` that holds a stop resumes it in place of reading at `lo`, and a stop saves in a `cursor`.
// A stop leaves the loop once its case has moved past its token and opened its frame, so `Place` holds where the walk
// stands.
@(private)
run :: proc "contextless" (src: []u8, lo: u64, opts: Walk_Rules, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $STRICT: bool, cursor: ^Cursor = nil) -> u64 #no_bounds_check {
	n := len(src)
	resuming := cursor != nil && cursor.held != nil
	if lo >= u64(n) && !resuming {
		return u64(n) << 16
	}
	o := Sending{regs = regs^}
	defer regs^ = o.regs
	limit := int(opts.max_depth) if 0 < opts.max_depth && opts.max_depth < core.MAX_DEPTH else core.MAX_DEPTH
	tolerate := .Invalid_Utf8 in opts.tolerate
	enc := opts.spec if STRICT else .Cbor
	// `stack[k]` holds the frame of depth k while a deeper item is open. Depth 0's frame is 0, so no key is due there
	// and a break there faults. `d` stays below `limit`, so every slot read was written.
	stack: [core.MAX_DEPTH]u64 = ---
	when STRICT {
		prevs: [core.MAX_DEPTH][2]u64 = ---
		kept := prevs[:]
	} else {
		kept: [][2]u64
	}
	top: u64
	d := 0
	i := int(lo)
	start: int
	fold: core.Token
	halt: u64
	phase := Phase.Ended
	if resuming {
		s := cursor.held
		top, i, start, d, phase, fold = s.place.top, s.place.i, s.place.start, s.place.d, s.place.phase, s.place.fold
		intrinsics.mem_copy_non_overlapping(&stack, &s.stack, d * size_of(u64))
		when STRICT {
			intrinsics.mem_copy_non_overlapping(&prevs, &s.prevs, d * size_of([2]u64))
		}
		if phase == .Fold {
			phase = .Ended
			if send(&o, h, fold, d, on) {
				return hold(cursor, stopped(fold), {fold, top, i, start if STRICT else 0, d, phase}, stack[:d], kept[:d] if STRICT else nil, o.regs)
			}
		}
		if phase == .Ended {
			when STRICT {
				key_due := top & (FLAG_OBJECT | 1) == FLAG_OBJECT
				if key_due && enc >= .Deterministic && !keys_ordered(src, &prevs[d - 1], start, i, enc) {
					return fault(start, .Bad_Char, .Key_Order)
				}
			}
			switch close_frames(&o, h, i, &d, &top, &stack, on) {
			case .Open:
			case .Done:
				return u64(i) << 16
			case .Stopped:
				return hold(cursor, stopped(core.Token{lo = u64(i), kind = .End}), {fold, top, i, start if STRICT else 0, d, phase}, stack[:d], kept[:d] if STRICT else nil, o.regs)
			}
		}
		phase = .Ended
	}
	walk: for {
		if i >= n {
			return fault(n, .Truncated)
		}
		start = i
		b := src[i]
		ai := b & 31
		key_due := top & (FLAG_OBJECT | 1) == FLAG_OBJECT
		role := core.Role.Key if key_due else .Value
		if key_due && b - 0x80 < 0x7f {
			return fault(i, .Bad_Char, .Bad_Key)
		}
		switch CLASS[b] {
		case .Int:
			arg, hl, ok := head(src, i, ai)
			if !ok {
				return fault(n, .Truncated)
			}
			if enc != .Cbor && !shortest(ai, arg) {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			t := core.Token{lo = u64(i), n = u32(hl), kind = .Number, role = role, spelling = CN_INT}
			if key_due {
				t.kind, t.spelling = .String, core.SPELLING_DECODE | core.SPELLING_LAX | INT_KEY
			}
			i += hl
			if send(&o, h, t, d, on) {
				halt = stopped(t)
				break walk
			}
		case .Text:
			when intrinsics.type_has_field(H, "expect") {
				if key_due && !o.muted {
					if r := expected_key(src, i, &o.regs, H); r != 0 {
						i = r
						break
					}
				}
			}
			arg, hl, ok := head(src, i, ai)
			if !ok || arg > u64(n - i - hl) {
				return fault(n, .Truncated)
			}
			if arg > u64(max(u32)) {
				return fault(i, .Too_Wide)
			}
			q := i + hl
			t := core.Token{lo = u64(q), n = u32(arg), kind = .String, role = role, spelling = u16(hl) << HEAD_SHIFT}
			if !ascii_16(src, q, arg) {
				bad, lax := text_fault(src, q, int(arg), tolerate)
				if bad >= 0 {
					return fault(q + bad, .Bad_Char, .Invalid_Utf8)
				}
				if lax {
					t.spelling |= core.SPELLING_DECODE | core.SPELLING_LAX
				}
			}
			if enc != .Cbor && !shortest(ai, arg) {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			i = q + int(arg)
			if send(&o, h, t, d, on) {
				halt = stopped(t)
				break walk
			}
		case .Bytes:
			arg, hl, ok := head(src, i, ai)
			if !ok || arg > u64(n - i - hl) {
				return fault(n, .Truncated)
			}
			if arg > u64(max(u32)) {
				return fault(i, .Too_Wide)
			}
			if enc != .Cbor && !shortest(ai, arg) {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			q := i + hl
			t := core.Token{lo = u64(q), n = u32(arg), kind = .Bytes, role = role, spelling = u16(hl) << HEAD_SHIFT}
			i = q + int(arg)
			if send(&o, h, t, d, on) {
				halt = stopped(t)
				break walk
			}
		case .Array, .Map:
			if d >= limit {
				return fault(i, .Too_Deep)
			}
			arg, hl, ok := head(src, i, ai)
			if !ok {
				return fault(n, .Truncated)
			}
			if enc != .Cbor && !shortest(ai, arg) {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			// A map's count is of pairs, two items each, and every item takes at least a byte.
			pair := u64(b >> 5) & 1
			if arg > u64(n - i - hl) >> pair {
				return fault(i, .Truncated, .Count_Too_Large)
			}
			t := core.Token{lo = u64(i), n = u32(hl), kind = core.Kind(u8(core.Kind.Array) + u8(pair)), role = role}
			stop := send(&o, h, t, d + 1, on)
			stack[d] = top
			d += 1
			when STRICT {
				prevs[d - 1] = {}
			}
			i += hl
			// An empty container waits for one item, which the count below supplies at once.
			top = max(arg << pair, 1) | pair << 62
			if stop {
				halt = stopped(t)
				phase = .Next if arg != 0 else .Ended
				break walk
			}
			if arg != 0 {
				continue
			}
		case .False, .True, .Null:
			t := core.Token{lo = u64(i), n = 1, kind = .Null if b == 0xf6 else core.Kind(b - 0xf3), role = role}
			i += 1
			if send(&o, h, t, d, on) {
				halt = stopped(t)
				break walk
			}
		case .Float:
			w := 1 << (ai - 24)
			if i + 1 + w > n {
				return fault(n, .Truncated)
			}
			if enc != .Cbor {
				if f := float_fault(src[i + 1:i + 1 + w], enc); f != .None {
					return fault(i, .Bad_Char, f)
				}
			}
			t := core.Token{lo = u64(i), n = u32(1 + w), kind = .Number, role = role, spelling = CN_FLOAT | FRACTION}
			i += 1 + w
			if send(&o, h, t, d, on) {
				halt = stopped(t)
				break walk
			}
		case .Simple:
			t := core.Token{lo = u64(i), n = 1, kind = .Null, role = role, spelling = simple_spelling(ai)}
			i += 1
			if send(&o, h, t, d, on) {
				halt = stopped(t)
				break walk
			}
		case .Simple_8:
			if i + 1 >= n {
				return fault(n, .Truncated)
			}
			if src[i + 1] < 32 {
				return fault(i, .Bad_Char, .Bad_Simple)
			}
			t := core.Token{lo = u64(i), n = 2, kind = .Null, role = role, spelling = simple_spelling(src[i + 1])}
			i += 2
			if send(&o, h, t, d, on) {
				halt = stopped(t)
				break walk
			}
		case .Tag:
			tag, hl, ok := read_head(src, i, ai)
			if !ok {
				return fault(n, .Truncated)
			}
			if enc != .Cbor && !shortest(ai, tag) {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			if i + hl >= n {
				return fault(n, .Truncated)
			}
			t := core.Token{lo = u64(i), n = u32(hl), kind = .Number, role = .Tag}
			i += hl
			switch tag {
			case 2, 3, 4, 5:
				r := resolved(src, i, tag, enc != .Cbor)
				if r.fault != 0 {
					return r.fault
				}
				v := core.Token{lo = u64(i), n = u32(r.end - i), kind = .Number, role = role, spelling = r.spelling}
				i = r.end
				if send(&o, h, t, d, on) {
					halt, phase, fold = stopped(t), .Fold, v
					break walk
				}
				if send(&o, h, v, d, on) {
					halt = stopped(v)
					break walk
				}
			case:
				if at := tag_content_fault(src, i, tag); at >= 0 {
					return fault(at, .Bad_Char, .Bad_Tag_Content)
				}
				if d >= limit {
					return fault(start, .Too_Deep)
				}
				stack[d] = top
				d += 1
				top = FLAG_TAG | 1
				if send(&o, h, t, d, on) {
					halt, phase = stopped(t), .Next
					break walk
				}
				continue
			}
		case .Indefinite_String:
			major := b >> 5
			s := string_item(src, i, major, tolerate)
			if s.fault != 0 {
				return s.fault
			}
			if enc != .Cbor {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			t := core.Token{lo = s.lo, n = u32(s.n), kind = .Bytes if major == 2 else .String, role = role, spelling = s.spelling}
			i = s.end
			if send(&o, h, t, d, on) {
				halt = stopped(t)
				break walk
			}
		case .Indefinite_Container:
			if d >= limit {
				return fault(i, .Too_Deep)
			}
			if enc != .Cbor {
				return fault(i, .Bad_Char, .Not_Preferred)
			}
			pair := u64(b >> 5) & 1
			t := core.Token{lo = u64(i), n = 1, kind = core.Kind(u8(core.Kind.Array) + u8(pair)), role = role}
			stop := send(&o, h, t, d + 1, on)
			stack[d] = top
			d += 1
			when STRICT {
				prevs[d - 1] = {}
			}
			i += 1
			top = FLAG_INDEF | INDEF_COUNT | pair << 62
			if stop {
				halt, phase = stopped(t), .Next
				break walk
			}
			continue
		case .Break:
			// A break ends an indefinite item where its next item could start, which in a map is before a key.
			if top & FLAG_INDEF == 0 || top & (FLAG_OBJECT | 1) == FLAG_OBJECT | 1 {
				return fault(i, .Bad_Char, .Bad_Break)
			}
			i += 1
			top = top & ~COUNT_MASK | 1
		case .Reserved:
			if b >> 5 == 4 || b >> 5 == 5 {
				if d >= limit {
					return fault(i, .Too_Deep)
				}
			}
			return fault(i, .Bad_Char, .Reserved_Info)
		}
		when STRICT {
			if key_due && enc >= .Deterministic && !keys_ordered(src, &prevs[d - 1], start, i, enc) {
				return fault(start, .Bad_Char, .Key_Order)
			}
		}
		switch close_frames(&o, h, i, &d, &top, &stack, on) {
		case .Open:
		case .Done:
			return u64(i) << 16
		case .Stopped:
			halt = stopped(core.Token{lo = u64(i), kind = .End})
			break walk
		}
	}
	return hold(cursor, halt, {fold, top, i, start if STRICT else 0, d, phase}, stack[:d], kept[:d] if STRICT else nil, o.regs)
}

// What `close_frames` leaves: a frame still waiting for an item, the item read whole, or a stop on an `End`.
@(private)
Close :: enum u8 {
	Open,
	Done,
	Stopped,
}

// Counts down the frames the item that ended at `i` completes, sending an `End` for each container it closes. A stop
// on an `End` leaves the walk past the container it closes, as if that item had just ended.
@(private)
close_frames :: #force_inline proc "contextless" (o: ^Sending, h: ^$H, i: int, d: ^int, top: ^u64, stack: ^[core.MAX_DEPTH]u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> Close #no_bounds_check {
	for {
		if d^ == 0 {
			return .Done
		}
		top^ -= 1
		if top^ & COUNT_MASK != 0 {
			return .Open
		}
		stop := false
		if top^ & FLAG_TAG == 0 {
			if o.muted {
				o.muted = o.mute_at != d^
			} else {
				stop = send(o, h, core.Token{lo = u64(i), kind = .End}, d^, on)
			}
		}
		d^ -= 1
		top^ = stack[d^]
		if stop {
			return .Stopped
		}
	}
}

// Whether the key at `src[start:i]` may follow `prev`, the last key of its map, which it then becomes.
@(private)
keys_ordered :: #force_inline proc "contextless" (src: []u8, prev: ^[2]u64, start, i: int, enc: Spec) -> bool {
	if prev[0] != 0 && !key_before(src[prev[0]:prev[1]], src[start:i], enc) {
		return false
	}
	prev^ = {u64(start), u64(i)}
	return true
}

// Whether the encoded key `before` sorts before the encoded key `key` in a map of spec `enc`.
@(private)
key_before :: proc "contextless" (before, key: []u8, enc: Spec) -> bool {
	if enc == .Length_First && len(before) != len(key) {
		return len(before) < len(key)
	}
	c := runtime.memory_compare(raw_data(before), raw_data(key), min(len(before), len(key)))
	return c < 0 || c == 0 && len(before) < len(key)
}

// The deterministic encoding's fault, if any, for the float `payload` of 2, 4 or 8 bytes: a NaN other than `f97e00` when
// keys are sorted, and a float a narrower one holds exactly.
@(private)
float_fault :: proc "contextless" (payload: []u8, enc: Spec) -> Detail {
	bits: u64
	for b in payload {
		bits = bits << 8 | u64(b)
	}
	switch len(payload) {
	case 2:
		if enc >= .Deterministic && bits & 0x7c00 == 0x7c00 && bits & 0x3ff != 0 && bits != 0x7e00 {
			return .Bad_Nan
		}
	case 4:
		if enc >= .Deterministic && bits & 0x7f80_0000 == 0x7f80_0000 && bits & 0x7f_ffff != 0 {
			return .Bad_Nan
		}
		if single_fits_half(u32(bits)) {
			return .Not_Preferred
		}
	case:
		if enc >= .Deterministic && bits & 0x7ff0_0000_0000_0000 == 0x7ff0_0000_0000_0000 && bits & 0xf_ffff_ffff_ffff != 0 {
			return .Bad_Nan
		}
		if double_fits_single(bits) {
			return .Not_Preferred
		}
	}
	return .None
}

@(private)
single_fits_half :: proc "contextless" (bits: u32) -> bool {
	if bits >> 23 & 0xff == 0xff {
		return bits & 0x7f_ffff == 0 || bits & 0x1fff == 0
	}
	return transmute(u32)f32(f16(transmute(f32)bits)) == bits
}

@(private)
double_fits_single :: proc "contextless" (bits: u64) -> bool {
	if bits >> 52 & 0x7ff == 0x7ff {
		return bits & 0xf_ffff_ffff_ffff == 0 || bits & 0x1fff_ffff == 0
	}
	return transmute(u64)f64(f32(transmute(f64)bits)) == bits
}

// A string item read: where it ends, its span, spelling and fault word.
@(private)
Str :: struct {
	end:      int,
	lo, n:    u64,
	spelling: u16,
	fault:    u64,
}

// Reads the byte or text string of `major` at `i`, definite or in chunks, and judges its text.
@(private)
string_item :: proc "contextless" (src: []u8, i: int, major: u8, tolerate: bool) -> (s: Str) {
	n := len(src)
	ai := src[i] & 31
	if ai == 31 {
		pos := i + 1
		lax := false
		for {
			if pos >= n {
				s.fault = fault(n, .Truncated)
				return
			}
			if src[pos] == 0xff {
				break
			}
			cai := src[pos] & 31
			if src[pos] >> 5 != major || cai > 27 {
				s.fault = fault(pos, .Bad_Char, .Bad_Chunk)
				return
			}
			arg, hl, ok := read_head(src, pos, cai)
			if !ok || arg > u64(n - pos - hl) {
				s.fault = fault(n, .Truncated)
				return
			}
			if major == 3 {
				bad, tolerated := text_fault(src, pos + hl, int(arg), tolerate)
				if bad >= 0 {
					s.fault = fault(pos + hl + bad, .Bad_Char, .Invalid_Utf8)
					return
				}
				lax ||= tolerated
			}
			pos += hl + int(arg)
		}
		if pos - (i + 1) > int(max(u32)) {
			s.fault = fault(i, .Too_Wide)
			return
		}
		s.lo, s.n, s.end = u64(i + 1), u64(pos - i - 1), pos + 1
		s.spelling = core.SPELLING_DECODE | STR_INDEF | 1 << HEAD_SHIFT
		if lax {
			s.spelling |= core.SPELLING_LAX
		}
		return
	}
	if ai > 27 {
		s.fault = fault(i, .Bad_Char, .Reserved_Info)
		return
	}
	arg, hl, ok := read_head(src, i, ai)
	if !ok || arg > u64(n - i - hl) {
		s.fault = fault(n, .Truncated)
		return
	}
	if arg > u64(max(u32)) {
		s.fault = fault(i, .Too_Wide)
		return
	}
	s.lo, s.n, s.end, s.spelling = u64(i + hl), arg, i + hl + int(arg), u16(hl) << HEAD_SHIFT
	if major == 3 {
		bad, lax := text_fault(src, int(s.lo), int(arg), tolerate)
		if bad >= 0 {
			s.fault = fault(i + hl + bad, .Bad_Char, .Invalid_Utf8)
		} else if lax {
			s.spelling |= core.SPELLING_DECODE | core.SPELLING_LAX
		}
	}
	return
}

// Judges the `n` bytes of text at `q` as UTF-8. Returns the offset of the first ill-formed byte, or -1, and whether a
// tolerated ill-formed sequence was passed. Text of 16 bytes or more is first tested for ASCII by 16-byte loads. The
// kernel's UTF-8 blocks judge the rest, and only text they refuse is read a sequence at a time, to find the fault.
@(private)
text_fault :: #force_no_inline proc "contextless" (src: []u8, q, n: int, tolerate: bool) -> (bad: int, lax: bool) #no_bounds_check {
	// The caller has checked that `src` holds the `n` bytes at `q`.
	text := src[q:q + n]
	if n >= 16 {
		p := raw_data(text)
		acc: Lanes
		j := 0
		for ; j + 16 <= n; j += 16 {
			acc |= intrinsics.unaligned_load((^Lanes)(p[j:]))
		}
		acc |= intrinsics.unaligned_load((^Lanes)(p[n - 16:]))
		if simd.reduce_max(acc) < 0x80 {
			return -1, false
		}
	}
	if utf8_valid(text) {
		return -1, false
	}
	return utf8_fault(text, tolerate)
}

// Whether `text` is UTF-8, by the kernel's blocks for this CPU's tier.
@(private)
utf8_valid :: #force_inline proc "contextless" (text: []u8) -> bool {
	when ODIN_ARCH == .amd64 {
		switch kernel.tier() {
		case .V4:
			return utf8_valid_v4(text)
		case .V3:
			return utf8_valid_v3(text)
		case .V2:
			return utf8_valid_v2(text)
		}
		return false
	} else {
		return utf8_blocks(.Base, text)
	}
}

when ODIN_ARCH == .amd64 {
	@(private, enable_target_feature = kernel.FEATURES[.V2])
	utf8_valid_v2 :: #force_no_inline proc "contextless" (text: []u8) -> bool {
		return utf8_blocks(.V2, text)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V3])
	utf8_valid_v3 :: #force_no_inline proc "contextless" (text: []u8) -> bool {
		return utf8_blocks(.V3, text)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V4])
	utf8_valid_v4 :: #force_no_inline proc "contextless" (text: []u8) -> bool {
		return utf8_blocks(.V4, text)
	}
}

@(private)
utf8_blocks :: #force_inline proc "contextless" ($T: kernel.Tier, text: []u8) -> bool #no_bounds_check {
	u: kernel.Utf8_State
	high: bool
	j := 0
	for ; j + 64 <= len(text); j += 64 {
		b := kernel.load(raw_data(text)[j:])
		kernel.utf8_next(T, b, kernel.is_ascii(b), &u, &high)
	}
	if j < len(text) {
		b := kernel.load_padded(T, text, j)
		kernel.utf8_next(T, b, kernel.is_ascii(b), &u, &high)
	}
	return kernel.utf8_ok(u)
}

// Judges `text` as UTF-8 a sequence at a time, for `text_fault`.
@(private)
utf8_fault :: proc "contextless" (text: []u8, tolerate: bool) -> (bad: int, lax: bool) {
	p := raw_data(text)
	end := p[len(text):]
	j := 0
	for j < len(text) {
		if text[j] < 0x80 {
			j += 1
			continue
		}
		q, kind := spell.utf8_char(p[j:], end)
		if kind != .None {
			if !tolerate {
				return j, false
			}
			lax = true
			q = spell.utf8_subpart(p[j:], end)
		}
		j = len(text) - int(uintptr(end) - uintptr(q))
	}
	return -1, lax
}

// A number folded from a tag.
@(private)
Resolved :: struct {
	end:      int,
	spelling: u16,
	fault:    u64,
}

// Reads the content of tag 2 to 5 at `i`, a byte string or a pair of an exponent and a mantissa.
@(private)
resolved :: proc "contextless" (src: []u8, i: int, tag: u64, strict: bool) -> (r: Resolved) {
	switch tag {
	case 2, 3:
		if src[i] >> 5 != 2 {
			r.fault = fault(i, .Bad_Char, .Bad_Tag_Content)
			return
		}
		s := string_item(src, i, 2, false)
		if s.fault != 0 {
			r.fault = s.fault
			return
		}
		if strict && (s.spelling & STR_INDEF != 0 || s.n <= 8 || src[s.lo] == 0) {
			r.fault = fault(i, .Bad_Char, .Not_Preferred)
			return
		}
		r.end, r.spelling = s.end, CN_BIG | NEGATIVE if tag == 3 else CN_BIG
	case:
		r.end, r.spelling, r.fault = decimal_item(src, i, strict)
		if tag == 5 && r.fault == 0 {
			r.spelling += CN_BIGFLOAT - CN_DEC
		}
	}
	return
}

// Reads the array of an exponent and a mantissa at `i` for tags 4 and 5.
@(private)
decimal_item :: proc "contextless" (src: []u8, i: int, strict: bool) -> (end: int, spelling: u16, f: u64) {
	n := len(src)
	b := src[i]
	if b >> 5 != 4 || b & 31 > 27 && b & 31 != 31 {
		return 0, 0, fault(i, .Bad_Char, .Bad_Tag_Content)
	}
	pos := i + 1
	indefinite := b & 31 == 31
	if !indefinite {
		arg, hl, ok := read_head(src, i, b & 31)
		if !ok {
			return 0, 0, fault(n, .Truncated)
		}
		if arg != 2 {
			return 0, 0, fault(i, .Bad_Char, .Bad_Tag_Content)
		}
		pos = i + hl
	} else if strict {
		return 0, 0, fault(i, .Bad_Char, .Not_Preferred)
	}
	spelling = CN_DEC | FRACTION
	for part in 0 ..< 2 {
		if pos >= n {
			return 0, 0, fault(n, .Truncated)
		}
		c := src[pos]
		mj := c >> 5
		switch {
		case mj <= 1 && c & 31 <= 27:
			arg, hl, ok := read_head(src, pos, c & 31)
			if !ok {
				return 0, 0, fault(n, .Truncated)
			}
			if strict && !shortest(c & 31, arg) {
				return 0, 0, fault(pos, .Bad_Char, .Not_Preferred)
			}
			pos += hl
		case mj == 6 && part == 1 && c & 31 <= 27:
			tag, hl, ok := read_head(src, pos, c & 31)
			if !ok {
				return 0, 0, fault(n, .Truncated)
			}
			if (tag != 2 && tag != 3) || pos + hl >= n {
				return 0, 0, fault(pos, .Bad_Char, .Bad_Tag_Content)
			}
			big := resolved(src, pos + hl, tag, strict)
			if big.fault != 0 {
				return 0, 0, big.fault
			}
			pos = big.end
		case:
			return 0, 0, fault(pos, .Bad_Char, .Bad_Tag_Content)
		}
	}
	if indefinite {
		if pos >= n {
			return 0, 0, fault(n, .Truncated)
		}
		if src[pos] != 0xff {
			return 0, 0, fault(pos, .Bad_Char, .Bad_Tag_Content)
		}
		pos += 1
	}
	return pos, spelling, 0
}

// Judges the content of a tag that stays a frame, where the content is at `i`. Returns the offset of the first byte that
// breaks the tag's meaning, or -1.
@(private)
tag_content_fault :: proc "contextless" (src: []u8, i: int, tag: u64) -> int {
	b := src[i]
	switch tag {
	case 0:
		if b >> 5 != 3 {
			return i
		}
		if b & 31 > 27 {
			return -1
		}
		arg, hl, ok := read_head(src, i, b & 31)
		if ok && arg <= u64(len(src) - i - hl) && !datetime(src[i + hl:i + hl + int(arg)]) {
			return i
		}
	case 1:
		if b >> 5 > 1 && b != 0xf9 && b != 0xfa && b != 0xfb {
			return i
		}
	case 24:
		if b >> 5 != 2 {
			return i
		}
	}
	return -1
}

// Whether `s` is an RFC 3339 date and time with a zone.
@(private)
datetime :: proc "contextless" (s: []u8) -> bool {
	digits :: proc "contextless" (s: []u8, at, n: int) -> (v: int, ok: bool) {
		if at + n > len(s) {
			return 0, false
		}
		for c in s[at:at + n] {
			if c - '0' > 9 {
				return 0, false
			}
			v = v * 10 + int(c - '0')
		}
		return v, true
	}
	if len(s) < 20 || s[4] != '-' || s[7] != '-' || s[13] != ':' || s[16] != ':' {
		return false
	}
	if s[10] != 'T' && s[10] != 't' {
		return false
	}
	year, ok1 := digits(s, 0, 4)
	month, ok2 := digits(s, 5, 2)
	day, ok3 := digits(s, 8, 2)
	hour, ok4 := digits(s, 11, 2)
	minute, ok5 := digits(s, 14, 2)
	second, ok6 := digits(s, 17, 2)
	if !(ok1 && ok2 && ok3 && ok4 && ok5 && ok6) || month < 1 || month > 12 || hour > 23 || minute > 59 || second > 60 {
		return false
	}
	days := [12]int{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	leap := year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
	if day < 1 || day > days[month - 1] + (1 if leap && month == 2 else 0) {
		return false
	}
	at := 19
	if s[at] == '.' {
		at += 1
		from := at
		for at < len(s) && s[at] - '0' <= 9 {
			at += 1
		}
		if at == from {
			return false
		}
	}
	if at >= len(s) {
		return false
	}
	if s[at] == 'Z' || s[at] == 'z' {
		return at + 1 == len(s)
	}
	if s[at] != '+' && s[at] != '-' || len(s) != at + 6 || s[at + 3] != ':' {
		return false
	}
	zh, okh := digits(s, at + 1, 2)
	zm, okm := digits(s, at + 4, 2)
	return okh && okm && zh <= 23 && zm <= 59
}
