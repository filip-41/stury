package typed

import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:strconv"
import "core:strings"
import spell "../spell"
import core ".."

// A value whose token the record's kind does not read at once. The element of a `Ptr`, a `Maybe`, a `Union` or an `Any`
// reads through the hook with registers of its own, and a container it opens returns to this record.
@(cold)
@(private)
indirect :: #force_no_inline proc "contextless" (h: ^$H, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	context = h.ctx
	fld := field_at(regs.b)
	dest := uintptr(regs.c) + uintptr(fld.offset)
	m := &h.plan.meta[fld.meta]
	reason: core.Typed_Error_Kind
	#partial switch fld.kind {
	case .Inside:
		if t.kind == .Object || t.kind == .Array {
			h.frames[h.sp - 1].seen += 1
		}
		return regs, .Next
	case .Ptr, .Maybe, .Union, .Any:
		return wrapped(h, regs, t, fld, m, dest)
	case .Raw, .Hook:
		if t.kind == .Object || t.kind == .Array {
			f := &h.frames[h.sp]
			h.sp += 1
			f.a, f.b, f.c, f.data, f.seen, f.kind = regs.a, regs.b, regs.c, rawptr(uintptr(t.lo)), 0, t.kind
			return {NO_LIMIT, u64(uintptr(&h.plan.fields[3])), 0}, .Next
		}
		lo, hi := core.scalar_ends(t)
		reason = store_whole(h, fld, m, dest, t.kind, lo, hi, t)
	case .Enum:
		reason = store_enum(h, t, m.enum_info, dest, m.size)
	case .Cstring:
		reason = store_cstring(h, t, dest)
	case .Number_Text:
		reason = .Wrong_Kind
		if t.kind == .Number {
			reason = store_span(h, t.lo, u64(t.n), (^string)(dest))
		} else if t.kind == .Null {
			// The empty text, which a write spells `null`.
			(^string)(dest)^, reason = "", .None
		}
	case .Number:
		reason = .Wrong_Kind
		if t.kind == .Number {
			if n, ok := h.plan.spelling.number(&h.view, t); ok {
				(^core.Number)(dest)^ = n
				reason = .None
			}
		}
	case .Scalar:
		reason = store_decoded(h, t, (^Scalar)(dest))
	case .Bool_Wide:
		reason = .Wrong_Kind
		if t.kind == .True || t.kind == .False {
			mem.zero(rawptr(dest), int(m.size))
			(^u8)(dest)^ = u8(t.kind == .True)
			reason = .None
		}
	case .Bit_Elem:
		reason = store_bit(h, t, m, dest)
	case:
		reason = .Wrong_Kind
	}
	if reason != .None {
		return refuse_value(h, regs, t, reason)
	}
	regs := regs
	regs.c += u64(fld.stride)
	return regs, .Next
}

// Reads the element of the wrapper `fld`, and sets the frame the element opens, if any, to return to this record.
@(private)
wrapped :: proc(h: ^$H, regs: core.Hook_Regs, t: core.Token, fld: ^Field, m: ^Meta, dest: uintptr) -> (core.Hook_Regs, core.Action) {
	regs := regs
	if t.kind == .Null {
		if fld.kind != .Union || !m.no_nil {
			mem.zero(rawptr(dest), int(m.size))
			regs.c += u64(fld.stride)
			return regs, .Next
		}
		return refuse_value(h, regs, t, .Wrong_Kind)
	}
	sp := h.sp
	parent := &h.frames[sp - 1]
	if parent.seen != 0 {
		revisit(h, parent, regs, fld, dest)
	}
	at, prior := dest, uintptr(0)
	rec := fld.first
	// A scalar element of a `Maybe` or a `Union` is staged in `scratch` and moved in once read, so a refused one leaves
	// the wrapper as it was. A container is not refused at its open, since the arm took its class.
	scalar := t.kind != .Object && t.kind != .Array
	scratch: [4]u128
	arm, size := 0, 0
	staged := false
	#partial switch fld.kind {
	case .Maybe, .Union:
		if fld.kind == .Union {
			reason: core.Typed_Error_Kind
			fault: core.Fault
			if arm, reason, fault = pick_arm(h, t, m); reason == .Walk {
				// A fault ends the read, so a collecting read does not pass over the object to fault on it again.
				note(h, regs, {kind = .Walk, at = fault.at, inner = fault}, fault.at)
				return regs, .Stop
			}
			if reason != .None {
				return refuse_value(h, regs, t, reason)
			}
			rec = &h.plan.fields[m.arms[arm].fields + 1]
		}
		if !scalar {
			present(dest, fld, m, arm)
		} else if size, staged = int(h.plan.meta[field_at(u64(uintptr(rec))).meta].size), true; size <= size_of(scratch) {
			at = uintptr(&scratch)
		} else {
			wide, err := runtime.mem_alloc(size, align_of(u128), context.temp_allocator)
			if err != nil {
				return refuse_value(h, regs, t, .No_Memory)
			}
			at = uintptr(raw_data(wide))
		}
	case .Ptr:
		// A pointer's element the destination already holds is read into.
		prior = (^uintptr)(dest)^
		if at = prior; at == 0 || m.whole {
			mem_, err := runtime.mem_alloc(max(int(m.elem_size), 1), int(m.align))
			if err != nil {
				return refuse_value(h, regs, t, .No_Memory)
			}
			at = uintptr(raw_data(mem_))
			(^uintptr)(dest)^ = at
		}
	case .Any:
		if scalar {
			reason := store_any(h, t, (^any)(dest))
			if reason != .None {
				return refuse_value(h, regs, t, reason)
			}
			regs.c += u64(fld.stride)
			return regs, .Next
		}
		ti := type_info_of(map[string]any) if t.kind == .Object else type_info_of([dynamic]any)
		box, err := runtime.mem_alloc(ti.size, ti.align)
		if err != nil {
			return refuse_value(h, regs, t, .No_Memory)
		}
		at = uintptr(raw_data(box))
		(^any)(dest)^ = any{rawptr(at), ti.id}
		if t.kind == .Array {
			rec = ([^]Field)(fld.first)[2:]
		}
	}
	// The element is no member of the frame below, whose repeats its own key tracks.
	seen := parent.seen
	parent.seen = 0
	held, held_sp := h.wrap, h.wrap_sp
	if held_sp != u32(sp) {
		h.wrap, h.wrap_sp = &regs, u32(sp)
	}
	inner, action := on_token_cold(h, {NO_LIMIT, u64(uintptr(rec)), u64(at)}, t)
	h.wrap, h.wrap_sp = held, held_sp
	parent = &h.frames[sp - 1]
	parent.seen = seen
	if h.sp == sp {
		if action == .Next {
			if staged {
				present(dest, fld, m, arm)
				mem.copy_non_overlapping(rawptr(dest), rawptr(at), size)
			}
			regs.c += u64(fld.stride)
			return regs, action
		}
		// A refused element leaves a member as it was and a list's element zero.
		if fld.kind == .Ptr && at != prior {
			runtime.mem_free(rawptr(at))
			(^uintptr)(dest)^ = prior
		}
		if fld.stride != 0 {
			mem.zero(rawptr(dest), int(m.size))
		}
		if action != .Stop {
			regs.c += u64(fld.stride)
		}
		return regs, action
	}
	if action == .Stop {
		return inner, action
	}
	// The hook saved the element's own registers, and its close must give back this record's.
	f := &h.frames[sp]
	if !wrapper(field_at(f.b)) {
		f.owner = field_at(f.b)
		f.target = uintptr(f.c) + uintptr(f.owner.offset)
	}
	f.a, f.b, f.c = regs.a, regs.b, regs.c
	return inner, action
}

// Zeroes the wrapper `fld` at `dest` and marks its element, the union's arm `arm`, present.
@(private)
present :: proc(dest: uintptr, fld: ^Field, m: ^Meta, arm: int) {
	mem.zero(rawptr(dest), int(m.size))
	mark_arm(dest, fld, m, arm)
}

// Marks the element of the wrapper `fld` at `dest`, the union's arm `arm`, present.
mark_arm :: proc(dest: uintptr, fld: ^Field, m: ^Meta, arm: int) {
	if fld.kind == .Maybe {
		(^u8)(dest + uintptr(m.tag))^ = 1
	} else if m.tag_size != 0 {
		write_uint(dest + uintptr(m.tag), u64(m.arms[arm].tag), u32(m.tag_size))
	}
}

// What `find_tag` finds of an object's tag member, and the walk's hook that finds it.
Tag_Scan :: struct {
	view:     core.Token_View,
	name:     string,
	depth:    int,
	on_tag:   bool,
	found:    int,
	value:    core.Token,
	fault:    Maybe(core.Fault),
}

on_tag_token :: proc "contextless" (s: ^Tag_Scan, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if t.role == .Key {
		if s.depth == 1 {
			s.on_tag = s.view.spelling.key_equals(&s.view, t, s.name)
			if s.on_tag {
				s.found += 1
				if s.found == 2 {
					return regs, .Stop
				}
			}
		}
		return regs, .Next
	}
	if t.role != .Value {
		return regs, .Next
	}
	if t.kind == .End {
		s.depth -= 1
		return regs, .Stop if s.depth == 0 else .Next
	}
	if s.depth == 1 && s.on_tag {
		s.value, s.on_tag = t, false
	}
	if t.kind == .Object || t.kind == .Array {
		s.depth += 1
	}
	return regs, .Next
}

// The arm a value picks: an object's by its tag member, any value's by its class.
@(private)
pick_arm :: proc(h: ^Reader, t: core.Token, m: ^Meta) -> (arm: int, reason: core.Typed_Error_Kind, fault: core.Fault) {
	if t.kind == .Object && m.tagged {
		s := h.find_tag(h, t.lo)
		// A text that breaks past the tag is the walk's to report, not a missing tag's.
		if f, faulted := s.fault.?; faulted {
			return 0, .Walk, f
		}
		if s.found == 0 {
			return 0, .Missing_Tag, {}
		}
		if s.found > 1 {
			return 0, .Repeated_Tag, {}
		}
		if s.value.kind == .String {
			name, ok := core.token_text(h.plan.spelling, &h.view, s.value, context.temp_allocator)
			if !ok {
				return 0, .No_Memory, {}
			}
			for &a, k in m.arms {
				if a.name == name {
					return k, .None, {}
				}
			}
		}
		return 0, .Not_A_Member, {}
	}
	class: Value_Class
	#partial switch t.kind {
	case .True, .False:
		class = .Bool
	case .Number:
		class = .Number
	case .String:
		class = .String
	case .Object:
		class = .Object
	case .Array:
		class = .Array
	}
	for &a, k in m.arms {
		if class in a.classes {
			return k, .None, {}
		}
	}
	return 0, .Wrong_Kind, {}
}

// Stores a value read whole, `lo..hi` of the text.
store_whole :: proc(h: ^Reader, fld: ^Field, m: ^Meta, dest: uintptr, kind: core.Kind, lo, hi: u64, t: core.Token) -> core.Typed_Error_Kind {
	if fld.kind == .Raw {
		return store_span(h, lo, hi - lo, (^string)(dest))
	}
	v := Hook_Value{kind = kind, text = string(h.src[lo:hi])}
	v.decoded = v.text
	if kind == .String {
		ok: bool
		if v.decoded, ok = core.token_text(h.plan.spelling, &h.view, t, context.temp_allocator); !ok {
			return .No_Memory
		}
	}
	if m.read == nil {
		return .Unsupported
	}
	return m.read(v, rawptr(dest), context.allocator).? or_else .None
}

// A slice of `src`, or its copy when the read copies.
@(private)
store_span :: #force_inline proc(h: ^Reader, lo, n: u64, dest: ^string) -> core.Typed_Error_Kind {
	s := string(raw_data(h.src)[lo:][:n])
	if h.borrow {
		dest^ = s
		return .None
	}
	return store_copy(s, dest)
}

// A copy of `s`, with an empty one needing no allocation.
@(private)
store_copy :: #force_inline proc(s: string, dest: ^string) -> core.Typed_Error_Kind {
	if len(s) == 0 {
		dest^ = ""
		return .None
	}
	buf, err := runtime.mem_alloc_non_zeroed(len(s), 1)
	if err != nil {
		return .No_Memory
	}
	mem.copy_non_overlapping(raw_data(buf), raw_data(s), len(s))
	(^runtime.Raw_String)(dest)^ = {raw_data(buf), len(s)}
	return .None
}

store_cstring :: proc(h: ^Reader, t: core.Token, dest: uintptr) -> core.Typed_Error_Kind {
	if t.kind == .Null {
		(^cstring)(dest)^ = nil
		return .None
	}
	if t.kind != .String {
		return .Wrong_Kind
	}
	s, ok := core.token_text(h.plan.spelling, &h.view, t, context.temp_allocator)
	if !ok {
		return .No_Memory
	}
	return copy_cstring(s, dest)
}

@(private)
copy_cstring :: proc(s: string, dest: uintptr) -> core.Typed_Error_Kind {
	if strings.index_byte(s, 0) >= 0 {
		return .Out_Of_Range
	}
	c, err := strings.clone_to_cstring(s)
	if err != nil {
		return .No_Memory
	}
	(^cstring)(dest)^ = c
	return .None
}

@(private)
store_decoded :: proc(h: ^Reader, t: core.Token, dest: ^Scalar) -> core.Typed_Error_Kind {
	#partial switch t.kind {
	case .Null:
		dest^ = Null{}
	case .True, .False:
		dest^ = t.kind == .True
	case .String:
		s: string
		if reason := store_string(h, t, &s); reason != .None {
			return reason
		}
		dest^ = s
	case .Number:
		n, ok := h.plan.spelling.number(&h.view, t)
		if !ok {
			return .Wrong_Kind
		}
		switch n.kind {
		case .Int:
			// `-0` has no integer, and the float keeps its sign.
			if n.bits == 0 && raw_data(h.src)[t.lo] == '-' {
				dest^ = -0.0
			} else {
				dest^ = i64(n.bits)
			}
		case .Uint:
			dest^ = n.bits
		case .Float:
			x := transmute(f64)n.bits
			if past_binary64(x, t.spelling) {
				return .Out_Of_Range
			}
			dest^ = x
		case .Wide:
			s: string
			if reason := store_span(h, t.lo, u64(t.n), &s); reason != .None {
				return reason
			}
			dest^ = Number_Text(s)
		}
	case:
		return .Wrong_Kind
	}
	return .None
}

// A scalar into an `any`: a null as nil, any other as its `Scalar` arm, boxed.
@(private)
store_any :: proc(h: ^Reader, t: core.Token, dest: ^any) -> core.Typed_Error_Kind {
	if t.kind == .Null {
		dest^ = nil
		return .None
	}
	d: Scalar
	if reason := store_decoded(h, t, &d); reason != .None {
		return reason
	}
	id := reflect.union_variant_typeid(d)
	ti := type_info_of(id)
	box, err := runtime.mem_alloc(ti.size, ti.align)
	if err != nil {
		return .No_Memory
	}
	mem.copy_non_overlapping(raw_data(box), &d, ti.size)
	dest^ = any{raw_data(box), id}
	return .None
}

// A name or, under `.Int`, a backing integer into an enum of `size` bytes.
store_enum :: proc(h: ^Reader, t: core.Token, info: ^runtime.Type_Info_Enum, dest: uintptr, size: u32) -> core.Typed_Error_Kind {
	if h.plan.enums == .Int {
		if t.kind != .Number {
			return .Wrong_Kind
		}
		v := number_i64(h, t) or_return
		return store_enum_value(info, {u64(v), .Int}, dest, size)
	}
	if t.kind != .String {
		return .Wrong_Kind
	}
	name, ok := core.token_text(h.plan.spelling, &h.view, t, context.temp_allocator)
	if !ok {
		return .No_Memory
	}
	return enum_name_store(info, name, dest, size)
}

@(private)
enum_name_store :: proc(info: ^runtime.Type_Info_Enum, name: string, dest: uintptr, size: u32) -> core.Typed_Error_Kind {
	for member, i in info.names {
		if member == name {
			write_uint(dest, u64(info.values[i]), size)
			return .None
		}
	}
	return .Not_A_Member
}

// An integer into an enum of `size` bytes. One past `i64` is out of range.
store_enum_value :: proc(info: ^runtime.Type_Info_Enum, n: core.Number, dest: uintptr, size: u32) -> core.Typed_Error_Kind {
	if n.kind != .Int {
		return .Out_Of_Range
	}
	if enum_member(info, i64(n.bits)) < 0 {
		return .Not_A_Member
	}
	write_uint(dest, n.bits, size)
	return .None
}

// The member of `info` that has `value`, or -1.
enum_member :: proc "contextless" (info: ^runtime.Type_Info_Enum, value: i64) -> int {
	for x, i in info.values {
		if i64(x) == value {
			return i
		}
	}
	return -1
}

@(private)
write_uint :: proc "contextless" (dest: uintptr, v: u64, size: u32) {
	switch size {
	case 1: (^u8)(dest)^ = u8(v)
	case 2: (^u16)(dest)^ = u16(v)
	case 4: (^u32)(dest)^ = u32(v)
	case: (^u64)(dest)^ = v
	}
}

// An integer token as an i64.
@(private)
number_i64 :: proc(h: ^Reader, t: core.Token) -> (v: i64, reason: core.Typed_Error_Kind) {
	n, ok := h.plan.spelling.number(&h.view, t)
	if !ok {
		return 0, .Wrong_Kind
	}
	if n.kind == .Int {
		return i64(n.bits), .None
	}
	// An integer past `i64` reads as `.Uint`, a float or wide, as `store_number` judges it.
	return 0, .Out_Of_Range if core.number_shape(t.spelling) < 32 else .Wrong_Kind
}

// One element of a bit_set: a member's name, or an integer of its range or a member's.
@(private)
store_bit :: proc(h: ^Reader, t: core.Token, m: ^Meta, dest: uintptr) -> core.Typed_Error_Kind {
	v: i64
	reason: core.Typed_Error_Kind
	if m.enum_info != nil {
		reason = store_enum(h, t, m.enum_info, uintptr(&v), 8)
	} else if t.kind != .Number {
		reason = .Wrong_Kind
	} else {
		v, reason = number_i64(h, t)
	}
	if reason != .None {
		return reason
	}
	bit := v - m.lower
	if bit < 0 || bit >= i64(m.count) {
		return .Out_Of_Range
	}
	(^u8)(dest + uintptr(bit / 8))^ |= 1 << uint(bit % 8)
	return .None
}

@(private)
store_int :: #force_no_inline proc "contextless" (mag: u64, neg: bool, kind: Read_Kind, dest: uintptr) -> core.Typed_Error_Kind {
	signed := kind >= .I8 && kind <= .I64
	bits := u32(8) << (u32(kind) - u32(Read_Kind.I8 if signed else Read_Kind.U8))
	if signed {
		limit := u64(1) << (bits - 1)
		if mag > limit || (!neg && mag == limit) {
			return .Out_Of_Range
		}
	} else if neg {
		if mag != 0 {
			return .Out_Of_Range
		}
	} else if bits < 64 && mag >> bits != 0 {
		return .Out_Of_Range
	}
	write_uint(dest, 0 - mag if neg else mag, bits / 8)
	return .None
}

// Numbers the hot cases do not take.
@(cold)
@(private)
number_cold :: #force_no_inline proc "contextless" (h: ^Reader, t: core.Token, fld: ^Field, dest: uintptr) -> core.Typed_Error_Kind {
	context = h.ctx
	if frac, sum := core.number_digits(t.spelling); fld.kind > .U64 && sum <= 19 && t.spelling & core.NUMBER_KIND_MASK == 0 {
		// `mant` holds all the digits of a plain decimal, the one kind the walk folds.
		return store_number(spell.number_significand(h.mant, -i64(frac), raw_data(h.src)[t.lo] == '-', sum <= 15), false, h, t, fld, dest)
	}
	n, ok := h.plan.spelling.number(&h.view, t)
	if !ok {
		return .Wrong_Kind
	}
	return store_number(n, core.number_shape(t.spelling) < 32, h, t, fld, dest)
}

// Stores a number read from its span. `integer` says the span spells an integer: no fraction digit and no exponent.
store_number :: proc(n: core.Number, integer: bool, h: ^Reader, t: core.Token, fld: ^Field, dest: uintptr) -> core.Typed_Error_Kind {
	if fld.kind >= .I8 && fld.kind <= .U64 {
		if !integer {
			return .Wrong_Kind
		}
		// An integer past `u64` reads as a float or as wide.
		return store_integer(n, fld.kind, dest)
	}
	if fld.kind != .F64 && fld.kind != .F32 {
		return .Wrong_Kind
	}
	x: f64
	switch n.kind {
	case .Int:
		x = f64(i64(n.bits))
		// `-0` is the integer 0, and a float keeps its sign.
		if n.bits == 0 && raw_data(h.src)[t.lo] == '-' {
			x = -x
		}
	case .Uint:
		x = f64(n.bits)
	case .Float:
		x = transmute(f64)n.bits
	case .Wide:
		// Past the digit and scale caps the double may still exist, as for `1e-5000`, which is zero.
		parsed, ok := strconv.parse_f64(string(raw_data(h.src)[t.lo:][:t.n]))
		if !ok {
			return .Out_Of_Range
		}
		x = parsed
	}
	if past_binary64(x, t.spelling) {
		return .Out_Of_Range
	}
	if fld.kind == .F32 {
		// Every case rounds the exact value once.
		v: f32
		#partial switch n.kind {
		case .Int:
			v = f32(i64(n.bits)) if n.bits != 0 else f32(x)
		case .Uint:
			v = f32(n.bits)
		case:
			v = f32(x)
			if t.spelling & core.NUMBER_KIND_MASK <= core.NUMBER_DECIMAL {
				if f32_double_rounds(x) {
					// Rounds the decimal once. Past `max(f32)` it is infinity, refused below.
					v, _ = strconv.parse_f32(string(raw_data(h.src)[t.lo:][:t.n]))
				}
			} else if read := h.plan.spelling.number_f32; read != nil {
				if exact, ok := read(&h.view, t); ok {
					v = exact
				}
			}
		}
		if abs(v) > max(f32) && !spells_non_finite(x, t.spelling) {
			return .Out_Of_Range
		}
		(^f32)(dest)^ = v
	} else {
		(^f64)(dest)^ = x
	}
	return .None
}

// Whether `x`, read from a token with `spelling`, is a format's own `Infinity` or `NaN`. A float takes it, and a walk
// that refuses it has faulted before the token. A number past binary64 in a decimal spelling is not.
@(private)
spells_non_finite :: #force_inline proc "contextless" (x: f64, spelling: u16) -> bool {
	return spelling & core.NUMBER_KIND_MASK > core.NUMBER_DECIMAL && (x != x || abs(x) > max(f64))
}

// Whether `x`, read from a token with `spelling`, is past what a binary64 holds.
@(private)
past_binary64 :: #force_inline proc "contextless" (x: f64, spelling: u16) -> bool {
	return (x != x || abs(x) > max(f64)) && !spells_non_finite(x, spelling)
}

// A number whose spelling the walk does not fold: `+5` and `5.` spell an integer a plain decimal writes as `5`.
@(cold)
@(private)
spelled_number :: #force_no_inline proc "contextless" (h: ^$H, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	regs := regs
	if regs.c >= regs.a {
		reason: core.Typed_Error_Kind
		regs, reason = grow_list(h, regs)
		if reason != .None {
			return refuse_element(h, regs, t, reason)
		}
	}
	fld := field_at(regs.b)
	if fld.kind < .I8 || fld.kind > .F64 {
		return indirect(h, regs, t)
	}
	if reason := number_cold(h, t, fld, uintptr(regs.c) + uintptr(fld.offset)); reason != .None {
		return refuse_value(h, regs, t, reason)
	}
	regs.c += u64(fld.stride)
	return regs, .Next
}

@(cold)
@(private)
open_map :: #force_no_inline proc "contextless" (h: ^$H, regs: core.Hook_Regs, fld: ^Field, dest: uintptr, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if fld.kind != .Map {
		return indirect(h, regs, t)
	}
	f := push_member(h, regs, fld, dest)
	// A map that held no entry at its open holds only this read's, which a repeated key may free.
	f.extra, f.run, f.kind = nil, nil, .Object if (^runtime.Raw_Map)(dest).len == 0 else .Null
	return {NO_LIMIT, u64(uintptr(fld.first)), 0}, .Next
}

@(cold)
@(private)
open_array :: #force_no_inline proc "contextless" (h: ^$H, regs: core.Hook_Regs, fld: ^Field, dest: uintptr, t: core.Token) -> (core.Hook_Regs, core.Action) {
	m := &h.plan.meta[fld.meta]
	limit := u64(dest)
	#partial switch fld.kind {
	case .Array:
		limit += u64(m.count) * u64(m.elem_size)
	case .Fixed_List:
		limit += u64(m.count) * u64(m.elem_size)
		mem.zero(rawptr(dest), int(m.size))
	case .Bit_Set:
		limit = NO_LIMIT
		mem.zero(rawptr(dest), int(m.size))
	case:
		return indirect(h, regs, t)
	}
	push_member(h, regs, fld, dest)
	return {limit, u64(uintptr(fld.first)), u64(dest)}, .Next
}

// Opens the frame of the container `fld` reads at `dest`, resetting a member read before.
@(private)
push_member :: #force_inline proc "contextless" (h: ^Reader, regs: core.Hook_Regs, fld: ^Field, dest: uintptr) -> ^Frame {
	parent := &h.frames[h.sp - 1]
	if parent.seen != 0 {
		revisit(h, parent, regs, fld, dest)
	}
	f := &h.frames[h.sp]
	h.sp += 1
	f.a, f.b, f.c, f.data, f.seen = regs.a, regs.b, regs.c, rawptr(dest), 0
	return f
}

@(private)
is_struct :: #force_inline proc "contextless" (f: ^Field) -> bool {
	return f.kind == .Struct || f.kind == .Required
}

@(private)
wrapper :: #force_inline proc "contextless" (f: ^Field) -> bool {
	return f.kind >= .Ptr && f.kind <= .Any
}

// Sets member `i`'s bit in `f` and says whether it was set.
@(private)
seen_set :: proc "contextless" (h: ^Reader, f: ^Frame, owner: ^Field, i: int) -> bool {
	if i < 63 {
		bit := u64(1) << uint(i)
		was := f.seen & bit != 0
		f.seen |= bit
		return was
	}
	context = h.ctx
	if f.extra == nil {
		words, failed := make([]u64, (h.plan.meta[owner.meta].members - 63) / 64 + 1, context.temp_allocator)
		if failed != nil {
			return false
		}
		f.extra = raw_data(words)
	}
	past := i - 63
	bit := u64(1) << uint(past % 64)
	was := f.extra[past / 64] & bit != 0
	f.extra[past / 64] |= bit
	return was
}

// Marks the members the cursor read since `f.run`, each once. A cursor outside the block read nothing by its keys.
@(private)
mark_run :: proc "contextless" (h: ^Reader, f: ^Frame, owner: ^Field, upto: ^Field) {
	first := owner.first
	members := h.plan.meta[owner.meta].members
	if upto < first || upto > ([^]Field)(first)[members:] {
		return
	}
	if f.seen == 0 {
		f.extra = nil
	}
	at := int(uintptr(f.run) - uintptr(first)) / size_of(Field) if f.seen != 0 else 0
	end := int(uintptr(upto) - uintptr(first)) / size_of(Field)
	f.seen |= SEEN_ON
	for i in at ..< end {
		seen_set(h, f, owner, i)
	}
	f.run = upto
}

// A struct, map or fixed array about to be read into a member the cursor matched after a key arrived out of order. A
// member read before is reset first, since its later occurrence replaces it whole.
@(cold)
@(private)
revisit :: #force_no_inline proc "contextless" (h: ^Reader, parent: ^Frame, regs: core.Hook_Regs, fld: ^Field, dest: uintptr) {
	owner := frame_owner(parent)
	if !is_struct(owner) || h.first_key {
		return
	}
	at := (^Field)(uintptr(regs.b))
	if at <= parent.run {
		return
	}
	mark_run(h, parent, owner, ([^]Field)(at)[-1:])
	i := int(uintptr(fld) - uintptr(owner.first)) / size_of(Field)
	if seen_set(h, parent, owner, i) {
		mem.zero(rawptr(dest), int(h.plan.meta[fld.meta].size))
	}
	parent.run = at
}

// A key the cursor did not match, and every key of a map.
@(private)
on_key :: #force_no_inline proc "contextless" (h: ^Reader, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	f := &h.frames[h.sp - 1]
	owner := frame_owner(f)
	if !is_struct(owner) {
		if owner.kind == .Map {
			return map_key(h, regs, t, f, owner)
		}
		return regs, .Next
	}
	if t.spelling & core.SPELLING_DECODE != 0 {
		return key_decoded(h, regs, t, f, owner)
	}
	return find_member(h, regs, t, f, owner, string(raw_data(h.src)[t.lo:][:t.n]))
}

// Moves the cursor to the member named `key`, a key's text, which the type may not hold.
@(private)
find_member :: #force_inline proc "contextless" (h: ^Reader, regs: core.Hook_Regs, t: core.Token, f: ^Frame, owner: ^Field, key: string) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	m := &h.plan.meta[owner.meta]
	if len(key) != 0 && m.names & name_bit(key) == 0 {
		return unknown_key(h, regs, t, f, owner, key)
	}
	// A record that compares its name holds its length, so most members cost one compare.
	want := u32(len(key)) + h.plan.key_frame
	at := ([^]Field)(owner.first)
	for i in 0 ..< int(m.members) {
		if (at[i].n == want || at[i].n == 0) && h.plan.meta[at[i].meta].name == key {
			return member_found(h, regs, t, f, owner, i)
		}
	}
	return unknown_key(h, regs, t, f, owner, key)
}

// A key the type does not name.
@(private)
unknown_key :: proc "contextless" (h: ^Reader, regs: core.Hook_Regs, t: core.Token, f: ^Frame, owner: ^Field, key: string) -> (core.Hook_Regs, core.Action) {
	if owner.kind == .Required || h.refuse_unknown {
		return unknown_cold(h, regs, t, f, owner, key)
	}
	return regs, .Skip
}

@(cold)
@(private)
unknown_cold :: #force_no_inline proc "contextless" (h: ^Reader, regs: core.Hook_Regs, t: core.Token, f: ^Frame, owner: ^Field, key: string) -> (core.Hook_Regs, core.Action) {
	context = h.ctx
	regs := regs
	m := &h.plan.meta[owner.meta]
	end := &h.plan.meta[int(m.block) + int(m.members)]
	if end.capture >= 0 {
		rec := &h.plan.fields[end.capture]
		if f.seen == 0 {
			f.data = rawptr(uintptr(regs.c))
		}
		mark_run(h, f, owner, (^Field)(uintptr(regs.b)))
		base := uintptr(f.data)
		slot: rawptr
		reason: core.Typed_Error_Kind
		// Under `.First` a repeat of a captured key is read into a scratch value, so it is judged and leaves the first.
		if captured := (^map[string]Raw)(base + uintptr(rec.offset)); h.first_key && key in captured^ {
			scratch, no_scratch := runtime.mem_alloc(size_of(Raw), align_of(Raw), context.temp_allocator)
			if no_scratch != nil {
				return refuse(h, regs, {kind = .No_Memory, at = t.lo}, t.lo + u64(t.n))
			}
			slot = raw_data(scratch)
		} else {
			slot, reason = map_slot(h, &h.plan.meta[rec.meta], (^runtime.Raw_Map)(captured), key, t, field_at(u64(uintptr(rec.first))), false)
		}
		if reason != .None {
			return refuse(h, regs, {kind = reason, at = t.lo}, t.lo + u64(t.n))
		}
		regs.b, regs.c = u64(uintptr(rec.first)), u64(uintptr(slot))
		return regs, .Next
	}
	if h.refuse_unknown && !(m.tagged && key == h.plan.union_tag) {
		return refuse(h, regs, {kind = .Unknown_Field, at = t.lo, steps = {0 = core.Name(key)}, n_steps = 1}, t.lo + u64(t.n))
	}
	return regs, .Skip
}

// Moves the cursor to member `i`, found out of order. A member read before is reset, since its later occurrence replaces
// it whole. Under `.First` a later occurrence is read into a scratch value, so it is judged and leaves no mark, and the
// cursor moves to a member's `solo` record, so no later key matches by its bytes and each comes here.
@(private)
member_found :: proc "contextless" (h: ^Reader, regs: core.Hook_Regs, t: core.Token, f: ^Frame, owner: ^Field, i: int) -> (core.Hook_Regs, core.Action) {
	regs := regs
	if f.seen == 0 {
		f.data = rawptr(uintptr(regs.c))
	} else {
		regs.c = u64(uintptr(f.data))
	}
	at := ([^]Field)(owner.first)
	mark_run(h, f, owner, (^Field)(uintptr(regs.b)))
	f.seen |= SEEN_ON
	was := seen_set(h, f, owner, i)
	size := h.plan.meta[at[i].meta].size
	if h.first_key {
		regs.b = u64(uintptr(&h.plan.solo[2 * (int(uintptr(&at[i]) - uintptr(raw_data(h.plan.fields))) / size_of(Field)) + 1]))
		if was {
			context = h.ctx
			scratch, err := runtime.mem_alloc(max(int(size), 1), 16, context.temp_allocator)
			if err != nil {
				return refuse(h, regs, {kind = .No_Memory, at = t.lo}, t.lo + u64(t.n))
			}
			regs.c = u64(uintptr(raw_data(scratch))) - u64(at[i].offset)
		}
		return regs, .Next
	}
	regs.b = u64(uintptr(&at[i + 1]))
	// A repeat is reset by `revisit`, as a repeat the cursor matched is, so it reads alike whichever way its key came.
	f.run = &at[i] if was else &at[i + 1]
	if was && at[i].kind == .String {
		context = h.ctx
		release_text(h, uintptr(regs.c) + uintptr(at[i].offset))
	}
	return regs, .Next
}

@(cold)
@(private)
key_decoded :: #force_no_inline proc "contextless" (h: ^Reader, regs: core.Hook_Regs, t: core.Token, f: ^Frame, owner: ^Field) -> (core.Hook_Regs, core.Action) {
	context = h.ctx
	key, ok := core.token_text(h.plan.spelling, &h.view, t, context.temp_allocator)
	if !ok {
		return refuse(h, regs, {kind = .No_Memory, at = t.lo}, t.lo + u64(t.n))
	}
	return find_member(h, regs, t, f, owner, key)
}

@(private)
map_key :: proc "contextless" (h: ^Reader, regs: core.Hook_Regs, t: core.Token, f: ^Frame, owner: ^Field) -> (core.Hook_Regs, core.Action) {
	context = h.ctx
	regs := regs
	f.extra, f.run = cast([^]u64)raw_data(h.src)[t.lo:], (^Field)(uintptr(t.n))
	key, ok := core.token_text(h.plan.spelling, &h.view, t, context.temp_allocator)
	if !ok {
		return refuse(h, regs, {kind = .No_Memory, at = t.lo}, t.lo + u64(t.n))
	}
	m := &h.plan.meta[owner.meta]
	if h.first_key {
		// The keys a map frame has met under `.First` are in the frame's `seen`, which a map does not use otherwise.
		if f.seen == 0 {
			fresh := new(map[string]struct {}, context.temp_allocator)
			fresh.allocator = context.temp_allocator
			f.seen = u64(uintptr(fresh))
		}
		if keys := (^map[string]struct {})(uintptr(f.seen)); key in keys^ {
			scratch, err := runtime.mem_alloc(max(int(m.elem_size), 1), 16, context.temp_allocator)
			if err != nil {
				return refuse(h, regs, {kind = .No_Memory, at = t.lo}, t.lo + u64(t.n))
			}
			regs.c = u64(uintptr(raw_data(scratch)))
			return regs, .Next
		} else {
			keys[key] = {}
		}
	}
	slot, reason := map_slot(h, m, (^runtime.Raw_Map)(f.data), key, t, field_at(regs.b), f.kind == .Object)
	if reason != .None {
		return refuse(h, regs, {kind = reason, at = t.lo}, t.lo + u64(t.n))
	}
	regs.c = u64(uintptr(slot))
	return regs, .Next
}

// The zeroed value slot of map key `key`, spelled as the map's key type reads it. A repeated key frees this read's copy
// of it, and the earlier value's text when the map is `fresh`, holding only what this read put in it.
map_slot :: proc(h: ^Reader, m: ^Meta, raw: ^runtime.Raw_Map, key: string, t: core.Token, value: ^Field, fresh: bool) -> (slot: rawptr, reason: core.Typed_Error_Kind) {
	if raw.allocator.procedure == nil {
		raw.allocator = context.allocator
	}
	k: [2]u64
	#partial switch m.key_kind {
	case .String:
		// `key` is decoded already, in the temporary allocator.
		reason = store_copy(key, (^string)(&k)) if t.spelling & core.SPELLING_DECODE != 0 else store_span(h, t.lo, u64(t.n), (^string)(&k))
		if reason != .None {
			return
		}
	case .Cstring:
		if reason = copy_cstring(key, uintptr(&k)); reason != .None {
			return
		}
	case .Enum:
		if h.plan.enums == .Name {
			reason = enum_name_store(m.enum_info, key, uintptr(&k), 8)
		} else {
			reason = store_enum_value(m.enum_info, key_number(key), uintptr(&k), 8)
		}
		if reason != .None {
			return
		}
	case:
		if reason = store_integer(key_number(key), m.key_kind, uintptr(&k)); reason != .None {
			return
		}
	}
	_, s, inserted, err := runtime.__dynamic_map_entry(raw, m.map_info, &k, raw_data(h.plan.zero))
	if err != nil || s == nil || !inserted {
		// The map keeps its own copy of a repeated key.
		if m.key_kind == .String {
			release_text(h, uintptr(&k))
		} else if m.key_kind == .Cstring {
			runtime.mem_free((^rawptr)(&k)^)
		}
	}
	if err != nil || s == nil {
		return nil, .No_Memory
	}
	if !inserted {
		if fresh {
			release_text(h, uintptr(s), value.kind)
		}
		mem.copy_non_overlapping(s, raw_data(h.plan.zero), int(m.map_info.vs.size_of_type))
	}
	return s, .None
}

// Frees the text at `dest` this read copied, when `kind` is a kind stored as a string, for a repeat that replaces it.
// A text the read borrowed from `src` stays.
@(private)
release_text :: proc(h: ^Reader, dest: uintptr, kind := Read_Kind.String) {
	if kind != .String && kind != .Raw && kind != .Number_Text {
		return
	}
	text := (^runtime.Raw_String)(dest)^
	at := uintptr(text.data)
	if text.len != 0 && (at < uintptr(raw_data(h.src)) || at >= uintptr(raw_data(h.src)) + uintptr(len(h.src))) {
		runtime.mem_free(text.data)
	}
	(^runtime.Raw_String)(dest)^ = {}
}

// A map key's integer, `.Wide` for a key that spells none.
@(private)
key_number :: proc(key: string) -> core.Number {
	n, ok := spell.number_strict(transmute([]u8)key, 0, u64(len(key)))
	return n if ok && (n.kind == .Int || n.kind == .Uint) else {0, .Wide}
}

// Stores a number that reads as `.Int` or `.Uint`, and refuses any other as out of range.
@(private)
store_integer :: proc(n: core.Number, kind: Read_Kind, dest: uintptr) -> core.Typed_Error_Kind {
	if n.kind > .Uint {
		return .Out_Of_Range
	}
	if n.kind == .Uint {
		return store_int(n.bits, false, kind, dest)
	}
	neg := i64(n.bits) < 0
	return store_int(u64(-i64(n.bits)) if neg else n.bits, neg, kind, dest)
}

// The index of the first member from `from` on that `required` names and is absent, or -1. The first call passes 0, and a
// read that reports every absent member passes the index after the one it reported, with `regs` as before.
@(private)
missing_member :: proc "contextless" (h: ^Reader, f: ^Frame, owner: ^Field, regs: core.Hook_Regs, from: i32) -> i32 {
	m := &h.plan.meta[owner.meta]
	end := &h.plan.meta[int(m.block) + int(m.members)]
	if f.seen != 0 {
		if from == 0 {
			mark_run(h, f, owner, (^Field)(uintptr(regs.b)))
		}
		for at in end.required {
			if at >= from && !seen_set(h, f, owner, int(at)) {
				return at
			}
		}
		return -1
	}
	done := max(from, i32((uintptr(regs.b) - uintptr(owner.first)) / size_of(Field)))
	for at in end.required {
		if at >= done {
			return at
		}
	}
	return -1
}
