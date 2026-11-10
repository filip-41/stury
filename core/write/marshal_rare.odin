package write

// The typed write's cold side: the kinds the loop leaves its switch for, what opens an object listed as entries, what a
// frame needs to enter or leave a side plan, and the path of a refusal.

import "base:intrinsics"
import "base:runtime"
import "core:reflect"
import "core:strings"
import "../spell"
import core ".."
import "../typed"

// Writes a value with no frame of its own: the rarer scalars and a bit set. `top` counts the open frames, of which
// `w.n_ptrs` are pointers' and `any`s', which no depth counts.
@(private)
leaf :: #force_no_inline proc(w: ^Walker, f: ^typed.Field, v: uintptr, top, nest: int, $P: bool, $T: Tree, $put: Put) -> core.Typed_Error_Kind #no_bounds_check {
	out := &w.out
	m := &w.meta[f.meta]
	p := room(out, LEAF_ROOM)
	#partial switch f.kind {
	case .I8, .I16, .I32, .U8, .U16, .U32, .U64:
		out.cursor += int_text(p, f.kind, v)
	case .F32:
		x := (^f32)(v)^
		if x - x != 0 {
			return .Non_Finite
		}
		out.cursor += spell.f32_text(p, x)
	case .Bool_Wide:
		out.cursor += put_bool(p, loaded(v, int(m.size)) != 0, T)
	case .Cstring:
		cs := (^cstring)(v)^
		if cs == nil {
			out.cursor += put_word(p, T[.Null])
			return .None
		}
		return put(out, p, string(cs), &w.opts)
	case .Enum:
		return put_enum(w, m.enum_info, enum_value(m.enum_info, v), put)
	case .Raw:
		return put_raw(w, string((^typed.Raw)(v)^), top - w.n_ptrs, T)
	case .Number_Text:
		return put_number_text(w, string((^typed.Number_Text)(v)^), top - w.n_ptrs, T)
	case .Number:
		return put_number(&w.out, (^core.Number)(v)^)
	case .Scalar:
		s := (^typed.Scalar)(v)^
		if text, is_text := s.(typed.Number_Text); is_text {
			return put_number_text(w, string(text), top - w.n_ptrs, T)
		}
		// Every other arm is written as an `any` of its type.
		_, k := any_value(w, any{rawptr(v), scalar_type(s)}, T, put)
		return k
	case .Bit_Set:
		return put_bit_set(w, m, v, top - w.n_ptrs, nest, P, T, put)
	case:
		return .Unsupported
	}
	return .None
}

// The integer of `kind` at `v` as text at `p`, under `spell.INT_ROOM` bytes, and its length.
int_text :: proc(p: [^]u8, kind: typed.Read_Kind, v: uintptr) -> int {
	if kind == .I64 {
		return spell.i64_text(p, (^i64)(v)^)
	}
	if kind < .I64 {
		return spell.i64_text(p, i64(loaded(v, 1 << (uint(kind) - uint(typed.Read_Kind.I8)), true)))
	}
	return spell.u64_text(p, loaded(v, 1 << (uint(kind) - uint(typed.Read_Kind.U8))))
}

// The `size` bytes at `v`, 8 at most, as an integer, sign extended when `signed`.
loaded :: proc "contextless" (v: uintptr, size: int, signed := false) -> (bits: u64) {
	runtime.mem_copy_non_overlapping(&bits, rawptr(v), size)
	shift := 64 - 8 * uint(size)
	return u64(i64(bits << shift) >> shift) if signed else bits
}

// The enum value at `v`, as many bytes wide as the enum, extended as its base type says.
enum_value :: proc "contextless" (info: ^runtime.Type_Info_Enum, v: uintptr) -> i64 {
	base, _ := runtime.type_info_base(info.base).variant.(runtime.Type_Info_Integer)
	return i64(loaded(v, info.base.size, base.signed))
}

// The enum value `value` as `plan` writes it: its member's name, or under `Plan.enums == .Int` its integer, written at
// `p`, which holds `spell.INT_ROOM` bytes. A value no member has is refused either way, as a read refuses it.
enum_spelled :: proc(plan: ^typed.Plan, info: ^runtime.Type_Info_Enum, value: i64, p: [^]u8) -> (string, core.Typed_Error_Kind) {
	k := typed.enum_member(info, value)
	if k < 0 {
		return "", .Not_A_Member
	}
	if plan.enums != .Int {
		return info.names[k], .None
	}
	if base, ok := runtime.type_info_base(info.base).variant.(runtime.Type_Info_Integer); ok && !base.signed {
		return string(p[:spell.u64_text(p, u64(value))]), .None
	}
	return string(p[:spell.i64_text(p, value)]), .None
}

// An enum as `enum_spelled` spells it.
@(private)
put_enum :: proc(w: ^Walker, info: ^runtime.Type_Info_Enum, value: i64, $put: Put) -> core.Typed_Error_Kind {
	p := room(&w.out, LEAF_ROOM)
	name := enum_spelled(w.plan, info, value, p) or_return
	if w.plan.enums == .Int {
		w.out.cursor += len(name)
		return .None
	}
	return put(&w.out, p, name, &w.opts)
}

// A bit set as an array of its elements in ascending order: an enum's names, or integers. A bit no member stands for is
// refused, as a read refuses it. The array counts toward the depth.
@(private)
put_bit_set :: proc(w: ^Walker, m: ^typed.Meta, v: uintptr, top, nest: int, $P: bool, $T: Tree, $put: Put) -> core.Typed_Error_Kind #no_bounds_check {
	out := &w.out
	if top == core.MAX_DEPTH {
		return .Too_Deep
	}
	e := &w.meta[m.block]
	bits: u128
	runtime.mem_copy_non_overlapping(&bits, rawptr(v), int(m.size))
	put_byte(out, T[.Open_Array][0])
	written := 0
	for b := bits; b != 0; b &= b - 1 {
		value := e.lower + i64(intrinsics.count_trailing_zeros(b))
		p := room(out, 2 + LINE_ROOM + 16)
		if written > 0 {
			p[0] = T[.Comma][0]
			out.cursor += 1
			p = p[1:]
		}
		written += 1
		when P {
			line(w, p, nest + 1)
		}
		if e.enum_info == nil {
			out.cursor += spell.i64_text(room(out, LEAF_ROOM), value)
		} else {
			put_enum(w, e.enum_info, value, put) or_return
		}
	}
	p := room(out, 1 + LINE_ROOM + 16)
	when P {
		if written > 0 {
			p = line(w, p, nest)
		}
	}
	p[0] = T[.Close_Array][0]
	out.cursor += 1
	return .None
}

// A line break and `n` bytes of `fill`, at any length.
@(private)
put_fill :: proc(out: ^Out, n: int, fill: u8) {
	put_byte(out, '\n')
	for _ in 0 ..< n {
		put_byte(out, fill)
	}
}

// Writes the byte `b`.
put_byte :: #force_inline proc(out: ^Out, b: u8) {
	room(out, 1)[0] = b
	out.cursor += 1
}

// A line break and the indent of `depth` levels of `opts`, in pretty text. Compact text gets nothing.
put_line :: proc(out: ^Out, opts: core.Write_Options, depth: int) {
	if opts.pretty {
		put_fill(out, depth * (1 if opts.tab else int(opts.indent)), '\t' if opts.tab else ' ')
	}
}

// Copies `s` to the output in pieces `room` can hold.
put_text :: proc(out: ^Out, s: string) {
	for rest := s; len(rest) > 0; {
		take := min(len(rest), ROOM_MAX)
		intrinsics.mem_copy_non_overlapping(room(out, take), raw_data(rest), take)
		out.cursor += take
		rest = rest[take:]
	}
}

// A `Raw`, the text of one value of the format, checked and written as it is. An empty one is null. Text around the value
// is refused, since it is no part of one value. Its containers nest inside the `top` frames open.
@(private)
put_raw :: proc(w: ^Walker, s: string, top: int, $T: Tree) -> core.Typed_Error_Kind {
	if len(s) == 0 {
		put_text(&w.out, T[.Null])
		return .None
	}
	switch s[0] {
	case ' ', '\t', '\n', '\r':
		return .Bad_Raw
	case T[.Open_Object][0], T[.Open_Array][0]:
		if top == core.MAX_DEPTH {
			return .Too_Deep
		}
	}
	switch s[len(s) - 1] {
	case ' ', '\t', '\n', '\r':
		return .Bad_Raw
	}
	view := core.Token_View{as = {readers = w.plan.readers, max_depth = u32(core.MAX_DEPTH - top)}}
	if e := w.plan.raw(&view, transmute([]u8)s, context.allocator); e.kind != .None {
		return .Too_Deep if e.inner.kind == .Too_Deep else .Bad_Raw
	}
	put_text(&w.out, s)
	return .None
}

// A `Number_Text`, checked as a `Raw` is and refused unless it is a number. An empty one is null.
@(private)
put_number_text :: proc(w: ^Walker, s: string, top: int, $T: Tree) -> core.Typed_Error_Kind {
	if len(s) != 0 && s[0] != '-' && (s[0] < '0' || s[0] > '9') {
		return .Bad_Raw
	}
	return put_raw(w, s, top, T)
}

// The text of `n` at `p`, under a reservation of `LEAF_ROOM`, and its length. A `.Wide` number holds no value to write.
number_text :: proc(p: [^]u8, n: core.Number) -> (size: int, kind: core.Typed_Error_Kind) {
	switch n.kind {
	case .Int:
		return spell.i64_text(p, i64(n.bits)), .None
	case .Uint:
		return spell.u64_text(p, n.bits), .None
	case .Float:
		x := transmute(f64)n.bits
		if x - x != 0 {
			return 0, .Non_Finite
		}
		return spell.f64_text(p, x), .None
	case .Wide:
	}
	return 0, .Non_Finite
}

// A `core.Number` by its value.
put_number :: proc(out: ^Out, n: core.Number) -> core.Typed_Error_Kind {
	size, kind := number_text(room(out, LEAF_ROOM), n)
	out.cursor += size
	return kind
}

// Number token text `lit`, of token spelling `spelling`, whose kind is not the format's plain decimal, as a JSON number:
// a decimal with a sign or a point of its own as JSON writes it (`+1` as `1`, `.5` as `0.5`, `5.` as `5`), and a hex
// integer as the exact decimal it spells. Any other text, an infinity or a NaN, is `.Non_Finite`.
put_decimal :: proc(out: ^Out, lit: string, spelling: u16) -> core.Typed_Error_Kind {
	kind := spelling & core.NUMBER_KIND_MASK
	p := 1 if lit[0] == '+' || lit[0] == '-' else 0
	hex := kind != core.NUMBER_DECIMAL && p + 1 < len(lit) && lit[p] == '0' && lit[p + 1] | 0x20 == 'x'
	if kind != core.NUMBER_DECIMAL && !hex {
		return .Non_Finite
	}
	if lit[0] == '-' {
		put_byte(out, '-')
	}
	if hex {
		return .None if put_hex_decimal(out, lit[p + 2:]) else .No_Memory
	}
	if lit[p] == '.' {
		put_byte(out, '0')
	}
	for k in p ..< len(lit) {
		if lit[k] != '.' || k + 1 < len(lit) && lit[k + 1] - '0' < 10 {
			put_byte(out, lit[k])
		}
	}
	return .None
}

// Writes the hex digits `hex` as the exact decimal integer they spell, at any length, kept in base 10^9 words with the
// least significant first. Returns false when the words cannot be held.
@(private)
put_hex_decimal :: proc(out: ^Out, hex: string) -> bool {
	BASE :: 1_000_000_000
	words, failed := make([dynamic]u32, 0, len(hex) / 7 + 1)
	if failed != nil {
		return false
	}
	defer delete(words)
	for c in transmute([]u8)hex {
		carry := u64(spell.HEX_NIBBLE[c])
		for &w in words {
			x := u64(w) * 16 + carry
			w, carry = u32(x % BASE), x / BASE
		}
		if carry > 0 {
			if _, no_word := append(&words, u32(carry)); no_word != nil {
				return false
			}
		}
	}
	if len(words) == 0 {
		put_byte(out, '0')
		return true
	}
	buf: [spell.INT_ROOM]u8
	put_text(out, string(buf[:spell.u64_text(&buf[0], u64(words[len(words) - 1]))]))
	#reverse for w in words[:len(words) - 1] {
		size := spell.u64_text(&buf[0], u64(w))
		for _ in size ..< 9 {
			put_byte(out, '0')
		}
		put_text(out, string(buf[:size]))
	}
	return true
}

// Writes a member whose name has no key text in the plan, or a long one, through the string writer, up to the colon's end.
@(cold)
@(private)
member_key :: proc(w: ^Walker, r: ^typed.Field, $T: Tree, $put: Put) -> core.Typed_Error_Kind {
	out := &w.out
	put(out, room(out, 18), w.meta[r.meta].name, &w.opts) or_return
	put_byte(out, T[.Colon][0])
	return .None
}

// Whether a read or write leaves the member at `v` out under `omitempty`: a zero number, false, an empty string, a nil, an
// empty list or map or bit set. An enum, a struct and a fixed array are kept whatever they hold.
@(cold)
@(private)
is_empty :: proc(w: ^Walker, r: ^typed.Field, v: uintptr) -> bool {
	m := &w.meta[r.meta]
	kind := m.key_kind if r.kind == .Hook else r.kind
	#partial switch kind {
	case .Bool, .Bool_Wide, .I8, .I16, .I32, .I64, .U8, .U16, .U32, .U64:
		return loaded(v, int(m.size)) == 0
	case .F32:
		return (^f32)(v)^ == 0
	case .F64:
		return (^f64)(v)^ == 0
	case .Number:
		n := (^core.Number)(v)^
		return n.kind != .Wide && (n.bits == 0 || n.kind == .Float && transmute(f64)n.bits == 0)
	case .String, .Raw, .Number_Text:
		return len((^string)(v)^) == 0
	case .Cstring:
		cs := (^cstring)(v)^
		return cs == nil || len(cs) == 0
	case .Slice, .Dynamic:
		return (^runtime.Raw_Slice)(v).len == 0
	case .Fixed_List:
		return (^int)(v + uintptr(m.tag))^ == 0
	case .Map:
		return (^runtime.Raw_Map)(v).len == 0
	case .Bit_Set:
		bits: u128
		runtime.mem_copy_non_overlapping(&bits, rawptr(v), int(m.size))
		return bits == 0
	case .Ptr:
		return (^rawptr)(v)^ == nil
	case .Maybe:
		return !(^bool)(v + uintptr(m.tag))^
	case .Union:
		return union_arm(&w.meta[r.meta], v) == nil
	case .Any:
		a := (^any)(v)^
		return a.id == nil || a.data == nil
	case .Scalar:
		return scalar_type((^typed.Scalar)(v)^) == nil
	}
	return false
}

// The type of the arm `s` holds, nil for none and for `Null`.
@(private)
scalar_type :: proc(s: typed.Scalar) -> typeid {
	id := reflect.union_variant_typeid(s)
	return nil if id == typeid_of(typed.Null) else id
}

// The arm the union of meta `m` at `v` holds, nil for none.
union_arm :: proc(m: ^typed.Meta, v: uintptr) -> ^typed.Arm {
	if m.tag_size == 0 {
		return &m.arms[0] if (^rawptr)(v)^ != nil else nil
	}
	tag := u32(loaded(v + uintptr(m.tag), int(m.tag_size)))
	for &arm in m.arms {
		if arm.tag == tag {
			return &arm
		}
	}
	return nil
}

// Adds a member to the entries with its key written in `keys`.
@(private)
add_entry :: proc(w: ^Walker, name: string, value: uintptr, rec: ^typed.Field, $put: Put) -> core.Typed_Error_Kind {
	at := w.keys.cursor
	put(&w.keys, room(&w.keys, 18), name, &w.opts) or_return
	size := w.keys.cursor - at
	put_text(&w.keys, name)
	if _, failed := append(&w.entries, Entry{at = at, size = size, named = len(name), value = value, rec = rec}); failed != nil {
		return .No_Memory
	}
	return w.keys.err
}

@(private)
entry_name :: proc(w: ^Walker, e: Entry) -> string {
	return string(w.keys.buf[e.at + e.size:][:e.named])
}

// An entry's place while its object sorts: eight bytes of its key from the depth being compared, big-endian so that a
// compare of two words is a compare of those bytes, and the entry's index.
@(private)
Sort_Item :: struct {
	word:  u64,
	entry: u64,
}

// The eight bytes of `s` from `d`, zeros past its end.
@(private)
key_word :: #force_inline proc "contextless" (s: string, d: int) -> u64 #no_bounds_check {
	if d + 8 <= len(s) {
		return intrinsics.byte_swap(intrinsics.unaligned_load((^u64)(raw_data(s)[d:])))
	}
	word: u64
	for i := d; i < len(s); i += 1 {
		word |= u64(s[i]) << (56 - 8 * u64(i - d))
	}
	return word
}

// Sorts `items` by their entries' text from byte `d`, a three-way quicksort on eight bytes at a time. The items whose
// word equals the pivot go on from `d + 8`, so a long common prefix costs one pass per word.
@(private)
sort_words :: proc(items: []Sort_Item, entries: []Entry, d: int) #no_bounds_check {
	items, d := items, d
	for len(items) > 12 {
		n := len(items)
		a, b, c := items[0].word, items[n / 2].word, items[n - 1].word
		pivot := max(min(a, b), min(max(a, b), c))
		lt, i, gt := 0, 0, n
		for i < gt {
			word := items[i].word
			if word < pivot {
				items[i], items[lt] = items[lt], items[i]
				lt += 1
				i += 1
			} else if word > pivot {
				gt -= 1
				items[i], items[gt] = items[gt], items[i]
			} else {
				i += 1
			}
		}
		// The smaller outer side and the equal run recurse and the larger outer side loops, so the stack is logarithmic in
		// the items and linear in the key words.
		low, high := items[:lt], items[gt:]
		if len(low) > len(high) {
			low, high = high, low
		}
		sort_words(low, entries, d)
		mid := items[lt:gt]
		// A zero last byte says the keys end inside the word, or hold a NUL there. Their text is compared instead.
		if pivot & 0xFF == 0 {
			insertion_sort(mid, entries)
		} else {
			for &it in mid {
				it.word = key_word(entries[it.entry].text, d + 8)
			}
			sort_words(mid, entries, d + 8)
		}
		items = high
	}
	insertion_sort(items, entries)
}

@(private)
insertion_sort :: proc(items: []Sort_Item, entries: []Entry) #no_bounds_check {
	for i in 1 ..< max(len(items), 1) {
		it := items[i]
		j := i
		for ; j > 0; j -= 1 {
			prev := &items[j - 1]
			if prev.word < it.word || prev.word == it.word && entries[prev.entry].text <= entries[it.entry].text {
				break
			}
			items[j] = prev^
		}
		items[j] = it
	}
}

// Sorts the entries from `first` by their keys as the caller holds them, so a key's spelling moves no key. The sorted
// copy is appended after the entries and moved down over them.
@(private)
sort_entries :: proc(w: ^Walker, first: int) -> core.Typed_Error_Kind {
	n := len(w.entries) - first
	if n < 2 {
		return .None
	}
	if resize(&w.order, n) != nil {
		return .No_Memory
	}
	for &e, i in w.entries[first:] {
		e.text = entry_name(w, e)
		w.order[i] = {key_word(e.text, 0), u64(i)}
	}
	sort_words(w.order[:], w.entries[first:], 0)
	for it in w.order {
		if _, failed := append(&w.entries, w.entries[first + int(it.entry)]); failed != nil {
			resize(&w.entries, first + n)
			return .No_Memory
		}
	}
	copy(w.entries[first:], w.entries[first + n:])
	resize(&w.entries, first + n)
	return .None
}

// Lists a map's members in the order of their keys. An integer key is written as text and an enum's by name.
@(private)
list_map :: proc(w: ^Walker, f: ^typed.Field, v: uintptr, $put: Put) -> core.Typed_Error_Kind {
	w.mark = w.keys.cursor
	first := len(w.entries)
	add_map_entries(w, f, &w.meta[f.meta], v, put) or_return
	sort_entries(w, first) or_return
	w.listed = len(w.entries) - first
	return .None
}

@(private)
add_map_entries :: proc(w: ^Walker, f: ^typed.Field, m: ^typed.Meta, v: uintptr, $put: Put) -> core.Typed_Error_Kind #no_bounds_check {
	raw := (^runtime.Raw_Map)(v)^
	info := m.map_info
	if reserve(&w.entries, len(w.entries) + int(raw.len)) != nil {
		return .No_Memory
	}
	ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(raw, info)
	rec := elem_of(f)
	for i in 0 ..< uintptr(runtime.map_cap(raw)) {
		if !runtime.map_hash_is_valid(hs[i]) {
			continue
		}
		key := runtime.map_cell_index_dynamic(ks, info.ks, i)
		value := runtime.map_cell_index_dynamic(vs, info.vs, i)
		if m.key_kind == .String {
			add_entry(w, (^string)(key)^, value, rec, put) or_return
		} else {
			add_key_entry(w, m, key, value, rec, put) or_return
		}
	}
	return .None
}

// `add_entry` for a key that is not a string. Its text is held in the call, which `put` copies.
@(private)
add_key_entry :: proc(w: ^Walker, m: ^typed.Meta, key, value: uintptr, rec: ^typed.Field, $put: Put) -> core.Typed_Error_Kind {
	text: [spell.INT_ROOM]u8
	name: string
	#partial switch m.key_kind {
	case .Cstring:
		name = string((^cstring)(key)^)
	case .Enum:
		name = enum_spelled(w.plan, m.enum_info, enum_value(m.enum_info, key), &text[0]) or_return
	case:
		name = string(text[:int_text(&text[0], m.key_kind, key)])
	}
	return add_entry(w, name, value, rec, put)
}

// Lists a struct's members, for a struct the loop's member path does not write: under `sort_keys`, with a captured map,
// or as the arm of a union with its tag `tag`. The tag comes first and a captured map's members last, in the order of
// their keys, unless `sort_keys` sorts them all together.
@(private)
list_struct :: proc(w: ^Walker, f: ^typed.Field, v: uintptr, tag: ^string, $put: Put) -> core.Typed_Error_Kind #no_bounds_check {
	w.mark = w.keys.cursor
	first := len(w.entries)
	if tag != nil {
		add_entry(w, w.plan.union_tag, uintptr(tag), &w.tag_field, put) or_return
	}
	r := f.first
	for ; r.kind != .Never; r = intrinsics.ptr_offset(r, 1) {
		at := v + uintptr(r.offset)
		if !r.omit || !is_empty(w, r, at) {
			add_entry(w, w.meta[r.meta].name, at, r, put) or_return
		}
	}
	m := &w.meta[f.meta]
	if capture := w.meta[m.block + m.members].capture; capture >= 0 {
		rec := &w.plan.fields[capture]
		captured := len(w.entries)
		add_map_entries(w, rec, &w.meta[rec.meta], v + uintptr(rec.offset), put) or_return
		// A capture holds what the type does not name, so a key that also has a written member is no captured member.
		for e in w.entries[captured:] {
			for named in w.entries[first:captured] {
				if entry_name(w, e) == entry_name(w, named) {
					return .Unwritable
				}
			}
		}
		if !w.opts.sort_keys {
			sort_entries(w, captured) or_return
		}
	}
	if w.opts.sort_keys {
		sort_entries(w, first) or_return
	}
	w.listed = len(w.entries) - first
	return .None
}

// The frame of the object just listed, with its opening byte written.
@(private)
open_entries :: proc(w: ^Walker, $T: Tree) -> Frame {
	put_byte(&w.out, T[.Open_Object][0])
	return {at = uintptr(len(w.entries) - w.listed), left = w.listed, total = w.listed, step = w.mark, mode = .Entries}
}

// Writes what comes before an entry's value and returns the value.
@(private)
entry_key :: proc(w: ^Walker, at: int, first: bool, nest: int, $T: Tree) -> (^typed.Field, uintptr) #no_bounds_check {
	out := &w.out
	e := w.entries[at]
	if !first {
		put_byte(out, T[.Comma][0])
	}
	if w.opts.pretty {
		line(w, room(out, 1 + LINE_ROOM + 16), nest)
	}
	put_text(out, string(w.keys.buf[e.at:][:e.size]))
	p := room(out, 2 + LEAF_ROOM)
	p[0], p[1] = T[.Colon][0], T[.After_Colon][0]
	out.cursor += 2 if w.opts.pretty else 1
	return e.rec, e.value
}

// Puts `target` on the open path under `rec`, which may be neither on it nor past the depth.
@(private)
enter_target :: proc(w: ^Walker, target: rawptr, rec: ^typed.Field) -> core.Typed_Error_Kind #no_bounds_check {
	for i in 0 ..< w.n_ptrs {
		if w.ptrs[i] == {target, rec} {
			return .Cycle
		}
	}
	if w.n_ptrs == core.MAX_DEPTH {
		return .Too_Deep
	}
	w.ptrs[w.n_ptrs] = {target, rec}
	w.n_ptrs += 1
	return .None
}

// Writes an `any`, or a hook's stand-in, that holds a nil or a scalar, and returns nil. Any other value is left to a frame,
// and this enters the side plan of its type and returns the record to write it by.
@(private)
any_value :: proc(w: ^Walker, a: any, $T: Tree, $put: Put) -> (rec: ^typed.Field, kind: core.Typed_Error_Kind) {
	out := &w.out
	if a.id == nil || a.data == nil {
		put_text(out, T[.Null])
		return nil, .None
	}
	p := room(out, LEAF_ROOM)
	switch a.id {
	case typeid_of(string):
		return nil, put(out, p, (^string)(a.data)^, &w.opts)
	case typeid_of(bool):
		out.cursor += put_bool(p, (^bool)(a.data)^, T)
		return nil, .None
	case typeid_of(i64):
		out.cursor += spell.i64_text(p, (^i64)(a.data)^)
		return nil, .None
	case typeid_of(u64):
		out.cursor += spell.u64_text(p, (^u64)(a.data)^)
		return nil, .None
	case typeid_of(f64):
		return nil, put_number(out, {transmute(u64)(^f64)(a.data)^, .Float})
	}
	side := side_plan(&w.side, w.plan, a.id) or_return
	first := &side.fields[0]
	enter_target(w, a.data, first) or_return
	if _, failed := append(&w.plans, w.plan); failed != nil {
		return nil, .No_Memory
	}
	w.plan, w.meta = side, raw_data(side.meta)
	return first, .None
}

// The plan of `T` for a write whose plan is `parent`, built on first sight and kept in `side`, whose allocator owns
// the plans. A call needs no cache past its end, where `release_sides` frees it.
side_plan :: proc(side: ^map[typeid]^typed.Plan, parent: ^typed.Plan, T: typeid) -> (^typed.Plan, core.Typed_Error_Kind) {
	if p, ok := side[T]; ok {
		return p, .None
	}
	allocator := side.allocator
	p, failed := new(typed.Plan, allocator)
	if failed != nil {
		return nil, .No_Memory
	}
	made, err := typed.plan_build(T, parent.as, parent.options, allocator)
	if err.kind != .None {
		free(p, allocator)
		return nil, err.kind
	}
	p^ = made
	p.raw, p.tokens = parent.raw, parent.tokens
	_, slot, _, no_slot := map_entry(side, T)
	if no_slot != nil {
		typed.plan_destroy(p)
		free(p, allocator)
		return nil, .No_Memory
	}
	slot^ = p
	return p, .None
}

// Returns to the plan a `Side` frame interrupted.
@(private)
leave_side :: proc(w: ^Walker) {
	w.plan = pop(&w.plans)
	w.meta = raw_data(w.plan.meta)
}

// Frees the plans `side_plan` built and leaves `side` empty, with its allocator.
release_sides :: proc(side: ^map[typeid]^typed.Plan) {
	allocator := side.allocator
	for _, p in side {
		typed.plan_destroy(p)
		free(p, allocator)
	}
	delete(side^)
	side^ = nil
	side.allocator = allocator
}

// Frees what a walk holds but the output.
@(private)
release_walker :: proc(w: ^Walker) {
	release_sides(&w.side)
	delete(w.entries)
	delete(w.order)
	delete(w.plans)
	destroy(&w.keys)
	runtime.arena_destroy(&w.arena)
}

// Fills `w.err`'s path from the open frames and returns `kind`. Nothing on the hot path keeps a path: each frame already
// says where it is. Names are copied, since side plans and `keys` end with the walk.
@(cold)
@(private)
refused :: proc(w: ^Walker, open: Frame, top: int, kind: core.Typed_Error_Kind) -> core.Typed_Error_Kind {
	open := open
	w.err.n_steps, w.err.truncated = 0, false
	for i := top + 1; i >= 1; i -= 1 {
		f := &open if i == top + 1 else &w.frames[i]
		#partial switch f.mode {
		case .Members:
			r := intrinsics.ptr_offset(f.r, -1)
			typed.path_add(&w.err, core.Name(strings.clone(w.meta[r.meta].name, context.temp_allocator)))
		case .Elements:
			if f.left < f.total {
				typed.path_add(&w.err, core.Index(f.total - f.left - 1))
			}
		case .Entries:
			if f.left < f.total {
				typed.path_add(&w.err, core.Name(strings.clone(entry_name(w, w.entries[f.at - 1]), context.temp_allocator)))
			}
		case .Side:
			leave_side(w)
		}
	}
	typed.path_close(&w.err)
	return kind
}
