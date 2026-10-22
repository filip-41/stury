package scan

import c "../../core"
import "base:intrinsics"
import "base:runtime"
import lex "lex"
import number "./number"

// The typed descent: a read shape whose every op is a plain struct, list or scalar (`Read_Shape.descends`)
// read by one recursive decoder per container, cursor and record state in locals, with no walk frames and no
// hook round trips. It takes only the common case: a well-formed document read without a repeated known key,
// an unknown key under `.Refuse`, a typed fault or a container at the depth cap. On anything else it gives up,
// and the shape walk reads the document again from its start, so every refusal, offset and path is the
// walk's. What the descent wrote before it gave up the walk writes again, at the same targets, before any
// fault of its own: the descent stops at the first byte the walk could refuse at, never past it. Only what it
// allocated is lost, and a read frees nothing anyway. An allocation it cannot make is the one fault it
// answers itself: a walk reading again would allocate again, so the result would hang on what the allocator
// does next. It is the walk's `Out_Of_Memory` at the same value, each container it unwinds through writing
// the frame the walk's error path reads.
//
// It checks what the walk checks, with the walk's own lexers and leaves: the same tokens, caps and values.
// A member nothing reads is checked by `walk_value`. `Shape_Run.fault` may hold a leaf's fault it gave up on.
// The walk sets its own. `dest` nil checks only, as the walk does for `unmarshal_check`.
//
// Each container proc reads from a copy of the caller's scanner, synced around its calls out of line, so the
// copy never escapes and its position stays in a register. What stores through `q` or `dest` could alias
// (the shape's ops and fields, the caps) is loaded into locals first.

// Read `src` into `root` along `run.shape` by descent: true, or false for the walk to read it, or the
// `Out_Of_Memory` typed fault the walk would answer, `run.fault_steps` frames of `run.frames` deep.
shape_descend :: proc(src: []byte, run: ^c.Shape_Run, root: rawptr, limits: Limits) -> (bool, Maybe(Error)) #no_bounds_check {
	Q :: bit_set[Walk_Kind]{.Shape}
	ctx_words: [size_of(Query_Ctx) / 8]u64 = ---
	q := (^Query_Ctx)(&ctx_words)
	c.query_ctx_zero(q, Q)
	q.hooks = &FORMAT_HOOKS
	q.shape = run
	run.ops, run.fields = raw_data(run.shape.ops), raw_data(run.shape.fields)
	s := enter_document(src, limits, MAX_DEPTH)
	q.max_depth = s.limits.max_depth
	lex.skip_ws(&s)
	walk_s := s
	op_i := run.shape.root
	if !descend_member(&s, &walk_s, q, op_i, &run.ops[op_i], root, 0) {
		if run.fault == .Out_Of_Memory {
			return false, Error{offset = run.fault_at, kind = TYPED_FAULT}
		}
		return false, nil
	}
	return finish(&s) == nil, nil
}

// The allocation the value at `at`, at walk depth `steps`, needs failed: the walk's fault there. Each container
// the descent unwinds through then writes its frame (`descend_frame_out_of_memory`).
@(private = "file")
descend_out_of_memory :: #force_no_inline proc(r: ^c.Shape_Run, at, steps: u64) -> bool {
	r.fault, r.fault_steps, r.fault_at = .Out_Of_Memory, u32(steps), at
	return false
}

// A leaf's fault at the value at `at`, at walk depth `sp`: the walk's to answer, but for `Out_Of_Memory`.
@(private = "file")
descend_leaf_fault :: #force_no_inline proc(r: ^c.Shape_Run, fault: c.Shape_Fault, at, sp: u64) -> bool {
	if fault == .Out_Of_Memory {
		descend_out_of_memory(r, at, sp)
	}
	return false
}

// The frame the walk holds for the container op `op` at walk depth `sp` while it reads field `field` or
// element `n - 1`, when the descent unwinds from `Out_Of_Memory`, and false either way.
@(private = "file")
descend_frame_out_of_memory :: #force_no_inline proc(r: ^c.Shape_Run, op: ^c.Shape_Op, sp: u64, field, n: u32) -> bool {
	if r.fault == .Out_Of_Memory {
		r.frames[sp] = c.Shape_Frame{op = u32(intrinsics.ptr_sub(op, &r.ops[0])), field = field, n = n}
	}
	return false
}

// The value at `s.pos` as op `op_i` (`op`) reads it into `dest`, at walk depth `sp`, leaving `s.pos` past it. A scalar
// is read in place, since a call per scalar costs more than its leaf. A container is read by its own proc on
// `walk_s`, the scanner `s` copies.
@(private = "file")
descend_member :: #force_inline proc(s, walk_s: ^Scanner, q: ^Query_Ctx, op_i: u32, op: ^c.Shape_Op, dest: rawptr, sp: u64) -> bool #no_bounds_check {
	if s.pos >= u64(len(s.src)) {
		return false
	}
	vc := lex.VCLASS[s.src[s.pos]]
	kind := op.kind
	if vc >= VC_STRING {
		return kind not_in SHAPE_CONTAINERS && descend_scalar(s, walk_s, q, op_i, dest, vc, sp)
	}
	if vc == VC_NONE || sp >= q.max_depth {
		return false
	}
	walk_s.pos = s.pos
	ok: bool
	if vc == VC_OBJECT {
		ok = kind == .Struct && descend_struct(walk_s, q, op, dest, sp)
	} else {
		ok = kind in SHAPE_SEQUENCES && descend_list(walk_s, q, op, dest, sp)
	}
	s.pos = walk_s.pos
	return ok
}

// The scalar of class `vc` at `s.pos`, checked by the walk's lexer and read by its leaf.
@(private = "file")
descend_scalar :: #force_inline proc(s, walk_s: ^Scanner, q: ^Query_Ctx, op_i: u32, dest: rawptr, vc: u8, sp: u64) -> bool {
	v := s.pos
	fault: c.Shape_Fault
	switch vc {
	case VC_STRING:
		if lex.parse_string_q(s, q, v, false, {.Shape}) != nil {
			return false
		}
		fault = shape_leaf_token(q.shape, q, op_i, dest, v, s.pos, VC_STRING)
	case VC_LITERAL:
		if lex.parse_literal_q(s, q, v, {.Shape}) != nil {
			return false
		}
		// A one-byte bool, the common literal leaf, without `shape_decode_scalar`'s call and dispatch.
		op := &q.shape.ops[op_i]
		if op.kind == .Bool && op.width == 1 && s.src[v] != 'n' {
			if dest != nil {
				(^bool)(dest)^ = s.src[v] == 't'
			}
			return true
		}
		fault = shape_leaf_token(q.shape, q, op_i, dest, v, s.pos, VC_LITERAL)
	case:
		op := &q.shape.ops[op_i]
		if op.kind == .Int && op.width == 8 {
			mag: u64
			if end := descend_short_int(s.src, v, s.limits.max_scalar_digits, &mag); end != v {
				s.pos = end
				if dest != nil {
					(^u64)(dest)^ = mag
				}
				return true
			}
		}
		walk_s.pos = v
		ok := descend_number(walk_s, q, op_i, dest, sp)
		s.pos = walk_s.pos
		return ok
	}
	if fault != .None {
		return descend_leaf_fault(q.shape, fault, v, sp)
	}
	return true
}

// The number at `s.pos`, checked by the walk's lexer and read by its leaf. Out of line: the number
// `descend_short_int` leaves is the rarer member, and its lexer inline spills the member loop's state.
@(private = "file")
descend_number :: #force_no_inline proc(s: ^Scanner, q: ^Query_Ctx, op_i: u32, dest: rawptr, sp: u64) -> bool {
	v := s.pos
	if number.parse_number_q(s, q, v, {.Shape}) != nil {
		return false
	}
	fault := shape_leaf_token(q.shape, q, op_i, dest, v, s.pos, VC_NUMBER)
	if fault != .None {
		return descend_leaf_fault(q.shape, fault, v, sp)
	}
	return true
}

// The end of the positive integer of at most 18 digits at `v`, which every i64 holds, within the digit cap
// `max_digits`, its value in `mag`, or `v` for any other token. It is the token `parse_number_q` takes and
// `shape_leaf_number_int` reads, without the number latch's stores and loads. Anything else, a refusal
// included, is theirs.
@(private = "file")
descend_short_int :: #force_inline proc(src: []byte, v, max_digits: u64, mag: ^u64) -> u64 #no_bounds_check {
	n := u64(len(src))
	if src[v] - '1' >= 9 {
		return v
	}
	end := number.digit_run(src, v, mag, true)
	if end - v > min(18, max_digits) || end < n && (src[end] == '.' || src[end] | 0x20 == 'e') {
		return v
	}
	return end
}

// The end of the number at `v` with a fraction and no exponent, within the digit and scale caps, its binary64
// value in `x`, or `v` for any other token. It is the token `parse_number_q` takes and `shape_leaf_float`
// reads, without the number latch's stores and loads. Anything else, a refusal included, is theirs.
@(private = "file")
descend_plain_float :: #force_inline proc(src: []byte, v, max_digits, max_scale: u64, x: ^f64) -> u64 #no_bounds_check {
	n := u64(len(src))
	neg := src[v] == '-'
	int_at := v + u64(neg)
	if int_at >= n {
		return v
	}
	mant: u64
	p := int_at + 1
	if src[int_at] != '0' {
		p = number.digit_run(src, int_at, &mant, true)
		if p == int_at {
			return v
		}
	}
	if p >= n || src[p] != '.' {
		return v
	}
	frac_at := p + 1
	end := number.digit_run(src, frac_at, &mant, true)
	int_digits, frac_digits := p - int_at, end - frac_at
	if frac_digits == 0 || int_digits + frac_digits > max_digits || frac_digits > max_scale || end < n && src[end] | 0x20 == 'e' {
		return v
	}
	ok: bool
	x^, ok = number.f64_number_value(src, v, end, number.Number_Lex{
		int_at = int_at, int_digits = int_digits, frac_at = frac_at, frac_digits = frac_digits, mant = mant,
		spelling = {.Negative} if neg else {}, ok = true, whole = true,
	})
	return end if ok else v
}

// The number at `s.pos` lexed and read as `shape_leaf_float` reads it into an f64, or false. Out of line: the
// token `descend_plain_float` leaves is the rare one.
@(private = "file")
descend_float :: #force_no_inline proc(s: ^Scanner, q: ^Query_Ctx) -> (f64, bool) {
	v := s.pos
	if lex.VCLASS[s.src[v]] != VC_NUMBER || number.parse_number_q(s, q, v, {.Shape}) != nil {
		return 0, false
	}
	return number.f64_number_value(s.src, v, s.pos, shape_number_lexed(q.shape, v, s.pos, false))
}

// A value nothing reads, at walk depth `sp`, checked as the walk checks it.
@(private = "file")
descend_unread :: #force_inline proc(s, walk_s: ^Scanner, q: ^Query_Ctx, sp: u64) -> bool {
	v := s.pos
	if v >= u64(len(s.src)) {
		return false
	}
	switch lex.VCLASS[s.src[v]] {
	case VC_NONE:
		return false
	case VC_OBJECT, VC_ARRAY:
		if sp >= q.max_depth {
			return false
		}
		walk_s.pos = s.pos
		ok := descend_unread_container(walk_s, q.max_depth - sp)
		s.pos = walk_s.pos
		return ok
	case VC_STRING:
		return lex.parse_string_q(s, q, v, false, {.Shape}) == nil
	case VC_LITERAL:
		return lex.parse_literal_q(s, q, v, {}) == nil
	}
	if end, ok := number.plain_int_end(s.src, v, s.limits.max_scalar_digits); ok {
		s.pos = end
		return true
	}
	return number.parse_number_q(s, q, v, {}) == nil
}

// Out of line: the walk is large, and a container nothing reads is the rare member.
@(private = "file")
descend_unread_container :: #force_no_inline proc(s: ^Scanner, room: u64) -> bool {
	return walk_value(s, room, .Values) == nil
}

// The object at `walk_s.pos` into the struct op `op` at `dest`, at walk depth `sp`. Its keys are matched as
// `shape_take_members` matches them: the field after the last one matched first, by its compact `"name":`
// words, then by the decoded key.
@(private = "file")
descend_struct :: proc(walk_s: ^Scanner, q: ^Query_Ctx, op: ^c.Shape_Op, dest: rawptr, sp: u64) -> bool #no_bounds_check {
	sc := walk_s^
	defer walk_s.pos = sc.pos
	s := &sc
	r := q.shape
	ops := r.ops
	src := s.src
	n := u64(len(src))
	count, required := op.count, op.required
	fields := r.fields[op.elem:][:count]
	seen: u64
	next: u32
	s.pos += 1
	lex.skip_ws(s)
	if s.pos < n && src[s.pos] == '}' {
		s.pos += 1
		return required == 0
	}
	for {
		key_lo := s.pos
		if key_lo >= n || src[key_lo] != '"' {
			return false
		}
		i := -1
		key_hi: u64
		colon_taken := false
		if next < count {
			fl := &fields[next]
			key_hi = key_lo + 2 + u64(len(fl.name))
			spelled := key_lo + 16 > n || fl.colon_key[0] == 0
			if !spelled {
				w0 := intrinsics.unaligned_load((^u64)(&src[key_lo]))
				w1 := intrinsics.unaligned_load((^u64)(&src[key_lo + 8]))
				colon_taken = (w0 ~ fl.colon_key[0]) & fl.colon_mask[0] | (w1 ~ fl.colon_key[1]) & fl.colon_mask[1] == 0
			}
			if colon_taken || spelled && key_hi <= n && src[key_hi - 1] == '"' && c.key_equals_hooked(q.hooks, src, key_lo, key_hi, false, fl.name) {
				i = int(next)
			}
		}
		if i < 0 {
			walk_s.pos = key_lo
			i = descend_unread_members(walk_s, q, fields, op, sp)
			s.pos = walk_s.pos
			if i < 0 {
				return i == DESCEND_CLOSED && required &~ seen == 0
			}
			key_hi = s.pos
		}
		if colon_taken {
			s.pos = key_hi + 1
		} else {
			s.pos = key_hi
			lex.skip_ws(s)
			if s.pos >= n || src[s.pos] != ':' {
				return false
			}
			s.pos += 1
		}
		lex.skip_ws(s)
		bit := u64(1) << uint(i)
		if seen & bit != 0 {
			return false
		}
		seen |= bit
		next = u32(i + 1)
		f := &fields[i]
		if !descend_member(s, walk_s, q, f.op, &ops[f.op], shape_at(dest, uintptr(f.offset)), sp + 1) {
			return descend_frame_out_of_memory(r, op, sp, u32(i), 0)
		}
		// Compact: the comma and the next key's quote.
		if s.pos + 2 <= n && intrinsics.unaligned_load((^u16)(&src[s.pos])) == u16(',') | u16('"') << 8 {
			s.pos += 1
			continue
		}
		lex.skip_ws(s)
		if s.pos >= n {
			return false
		}
		if src[s.pos] == '}' {
			s.pos += 1
			return required &~ seen == 0
		}
		if src[s.pos] != ',' {
			return false
		}
		s.pos += 1
		lex.skip_ws(s)
	}
}

// `descend_unread_members` past the object's `}`, or at a member it refused.
DESCEND_CLOSED :: -1
DESCEND_REFUSED :: -2

// The members from the key at `walk_s.pos`, of the struct op `op` at walk depth `sp`, while no key names one
// of `fields`: checked, nothing read. Returns the index of the field the next key names, `walk_s.pos` past
// that key, DESCEND_CLOSED (past the object's `}`) or DESCEND_REFUSED. Out of line, since a key the
// prediction misses is the rare one in a struct read whole, and its lexer inline spills the member loop's
// state. One call takes a whole run of unknown members.
@(private = "file")
descend_unread_members :: #force_no_inline proc(walk_s: ^Scanner, q: ^Query_Ctx, fields: []c.Shape_Field, op: ^c.Shape_Op, sp: u64) -> int #no_bounds_check {
	sc := walk_s^
	defer walk_s.pos = sc.pos
	s := &sc
	src := s.src
	n := u64(len(src))
	when ODIN_ARCH == .amd64 {
		try_at := s.pos + UNREAD_RUN_AFTER if unread_run_ok() && s.limits.max_scalar_digits >= UNREAD_RUN_DIGITS else max(u64)
	}
	for {
		key_lo := s.pos
		when ODIN_ARCH == .amd64 {
			// A long run of compact members is passed a block at a time, once the loop below has gone a few
			// blocks' length unmatched. A run that never starts costs a call, so it waits longer to try again.
			if key_lo >= try_at {
				s.pos = unread_run_wide(src, key_lo, op.first)
				if s.pos == key_lo {
					try_at = key_lo + UNREAD_RUN_RETRY
				} else {
					lex.skip_ws(s)
					key_lo = s.pos
					try_at = key_lo + UNREAD_RUN_AFTER
				}
			}
		}
		if key_lo >= n || src[key_lo] != '"' {
			return DESCEND_REFUSED
		}
		q.key_esc_live, q.key_saw_escape = true, false
		kerr := lex.parse_string_q(s, q, key_lo, true, {.Shape})
		q.key_esc_live = false
		if kerr != nil {
			return DESCEND_REFUSED
		}
		escaped := q.key_saw_escape
		if escaped || shape_first_has(op.first, src[key_lo + 1]) {
			for field, k in fields {
				if c.key_equals_hooked(q.hooks, src, key_lo, s.pos, escaped, field.name) {
					return k
				}
			}
		}
		if q.shape.refuse_unknown {
			return DESCEND_REFUSED
		}
		lex.skip_ws(s)
		if s.pos >= n || src[s.pos] != ':' {
			return DESCEND_REFUSED
		}
		s.pos += 1
		lex.skip_ws(s)
		if !descend_unread(s, walk_s, q, sp + 1) {
			return DESCEND_REFUSED
		}
		// Compact: the comma and the next key's quote.
		if s.pos + 2 <= n && intrinsics.unaligned_load((^u16)(&src[s.pos])) == u16(',') | u16('"') << 8 {
			s.pos += 1
			continue
		}
		lex.skip_ws(s)
		if s.pos >= n {
			return DESCEND_REFUSED
		}
		if src[s.pos] == '}' {
			s.pos += 1
			return DESCEND_CLOSED
		}
		if src[s.pos] != ',' {
			return DESCEND_REFUSED
		}
		s.pos += 1
		lex.skip_ws(s)
	}
}

// The array at `walk_s.pos` into the sequence op `op` at `dest`, at walk depth `sp`. A list grows as
// `shape_list_grow` grows it, so a `[dynamic]T` gets the walk's capacity. A fixed array's elements are read
// over in place, and a list's start from zero unless their leaf writes every byte.
@(private = "file")
descend_list :: proc(walk_s: ^Scanner, q: ^Query_Ctx, op: ^c.Shape_Op, dest: rawptr, sp: u64) -> bool {
	elem := &q.shape.ops[op.elem]
	if elem.width == 8 {
		#partial switch elem.kind {
		case .Int:
			return descend_elements(walk_s, q, op, dest, sp, .Int)
		case .Float:
			return descend_elements(walk_s, q, op, dest, sp, .Float)
		}
	}
	return descend_elements(walk_s, q, op, dest, sp, .Unsupported)
}

// `descend_list` with its element read: by `descend_member`, or, for `$leaf` `.Int` or `.Float` (an
// 8-byte element), as a number in place. A list of numbers is the common one, and the general element read
// keeps every class's lexer live in the loop, spilling the list's own state around each element.
@(private = "file")
descend_elements :: proc(walk_s: ^Scanner, q: ^Query_Ctx, op: ^c.Shape_Op, dest: rawptr, sp: u64, $leaf: c.Shape_Kind) -> bool #no_bounds_check {
	sc := walk_s^
	defer walk_s.pos = sc.pos
	s := &sc
	r := q.shape
	src := s.src
	n := u64(len(src))
	kind, elem_i, stride, limit := op.kind, op.elem, uintptr(op.stride), op.count
	elem := &r.ops[elem_i]
	fixed := kind == .Array || kind == .Fixed_List
	zero := kind != .Array && elem.kind not_in c.SHAPE_WHOLE_LEAVES
	data := dest if fixed else nil
	count, cap: u32
	when leaf == .Int {
		max_digits := s.limits.max_scalar_digits
	} else when leaf == .Float {
		max_digits, max_scale := s.limits.max_scalar_digits, s.limits.max_scalar_scale
	}
	s.pos += 1
	lex.skip_ws(s)
	if s.pos < n && src[s.pos] == ']' {
		s.pos += 1
	} else {
		for {
			if fixed {
				if count == limit {
					return false
				}
			} else if count == cap {
				if cap > max(u32) / 2 {
					return false
				}
				if dest == nil {
					cap = 1 << 31
				} else {
					new_cap := max(8, 2 * cap)
					buf: []byte
					aerr: runtime.Allocator_Error
					if data == nil {
						buf, aerr = shape_alloc(int(new_cap) * int(stride), int(op.align), r.allocator)
					} else {
						buf, aerr = shape_resize(data, int(cap) * int(stride), int(new_cap) * int(stride), int(op.align), r.allocator)
					}
					if aerr != nil || raw_data(buf) == nil {
						descend_out_of_memory(r, s.pos, sp + 1)
						return descend_frame_out_of_memory(r, op, sp, c.NO_FIELD, count + 1)
					}
					data, cap = raw_data(buf), new_cap
				}
			}
			slot := shape_at(data, uintptr(count) * stride)
			if zero && slot != nil {
				shape_zero(slot, u32(stride))
			}
			when leaf == .Unsupported {
				if !descend_member(s, walk_s, q, elem_i, elem, slot, sp + 1) {
					return descend_frame_out_of_memory(r, op, sp, c.NO_FIELD, count + 1)
				}
			} else {
				v := s.pos
				if v >= n {
					return false
				}
				when leaf == .Int {
					mag: u64
					if end := descend_short_int(src, v, max_digits, &mag); end != v {
						s.pos = end
						if slot != nil {
							(^u64)(slot)^ = mag
						}
					} else if lex.VCLASS[src[v]] != VC_NUMBER || number.parse_number_q(s, q, v, {.Shape}) != nil {
						return false
					} else if shape_leaf_number_int(q.shape, v, s.pos, slot, 8, true) != .None {
						return false
					}
				} else {
					x: f64
					if end := descend_plain_float(src, v, max_digits, max_scale, &x); end != v {
						s.pos = end
					} else {
						walk_s.pos = v
						ok: bool
						if x, ok = descend_float(walk_s, q); !ok {
							return false
						}
						s.pos = walk_s.pos
					}
					if slot != nil {
						(^f64)(slot)^ = x
					}
				}
			}
			count += 1
			lex.skip_ws(s)
			if s.pos >= n {
				return false
			}
			if src[s.pos] == ']' {
				s.pos += 1
				break
			}
			if src[s.pos] != ',' {
				return false
			}
			s.pos += 1
			lex.skip_ws(s)
		}
	}
	if dest == nil {
		return !(kind == .Array && count != limit)
	}
	#partial switch kind {
	case .Array:
		return count == limit
	case .Fixed_List:
		(^int)(uintptr(dest) + uintptr(op.len_offset))^ = int(count)
	case .Slice:
		(^runtime.Raw_Slice)(dest)^ = {data, int(count)}
	case .Dynamic:
		(^runtime.Raw_Dynamic_Array)(dest)^ = {data, int(count), int(cap), r.allocator}
	}
	return true
}

