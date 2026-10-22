package scan

import c "../../core"
import "base:intrinsics"
import lex "lex"
import number "./number"

// The shape walk's fused loops: the members of a struct, or the elements of a sequence of scalars, read in one
// loop each instead of one hook round trip per value. Each loop does what the walk and its hooks would do, in
// the same order, so it reaches every result at the same byte with the same frames. A loop raises only a
// leaf's fault on a well-formed token and a list's failed growth. Every syntax fault is left to the walk: one
// in a key or colon, or in an unread member's value, at the member's key, untouched, and one in a value read
// at that value, its key latched or its slot not yet taken. Byte cursor only, in a walk that does not skip.
//
// Its unchecked reads stay inside `src`: the predicted key's two 8-byte words load only with 16 bytes left,
// and the compact `,"` pair only with 2. A fused struct has at most 64 fields and plain ASCII names. A leaf
// writes to a field at its type-info offset or a list slot below the buffer's `cap`, grown first, and only
// after the walk's lexer checked its token. `$unique` leaves unknown keys to the walk's key set, and
// `$pass_unread` passes an unread string unchecked. The differential tests read fused
// structs and a fused `[]i16` against a reference decoder.

// Where a fused loop left the walk. No loop returns the walk's `Error`: carried out of every value, it would
// cost the loop its registers.
Shape_Take :: enum u8 {
	Key,   // on a member's key, untouched, for the walk to read
	Value, // on a value, its key latched or its slot not yet taken, for the walk to read
	After, // past a value, on the comma or close after it
	Fault, // on a value its leaf refused, or on an element its list could not grow for. The fault already in the run
}

// Members of a fused struct (`Shape_Op.members_fused`) open at walk depth `sp - 1`, read from the key at `s.pos`: key,
// colon, then a scalar into a field that holds one straight into the field. Any other value, and any scalar
// the walk refuses, is handed to the walk with its key latched (`.Value`), and a key the loop cannot take
// whole (escaped, repeated, unknown under `.Refuse` or `unique`, or malformed) is left to the walk untouched
// (`.Key`). Under `unique` (`.Unique`) a record chained in place forgets its keys as its close would.
shape_take_members :: #force_inline proc(walk_s: ^Scanner, q: ^Query_Ctx, sp: u64, $unique, $pass_unread: bool) -> Shape_Take #no_bounds_check {
	r := q.shape
	if sp != r.sp {
		return .Key
	}
	f := &r.frames[sp - 1]
	op := &r.ops[f.op]
	if !op.members_fused {
		return .Key
	}
	// A copy of the walk's scanner, so its position stays in a register across the loop's stores through `q`
	// and `f`.
	sc := walk_s^
	defer walk_s.pos = sc.pos
	s := &sc
	src := s.src
	n := u64(len(src))
	fields := r.fields[op.elem:][:op.count]
	for {
		key_lo := s.pos
		if key_lo >= n || src[key_lo] != '"' {
			return .Key
		}
		// The field is found as `shape_key` finds it, but not by it: `shape_key` latches the key before its colon
		// is seen, and a key the loop hands back must be untouched. The predicted field: a name written in plain ASCII and matched byte for
		// byte is the key's whole token.
		i := -1
		key_hi: u64
		// Past the colon already: the predicted member written compactly, `"name":`, matched as two words.
		colon_taken := false
		if f.cap < op.count {
			fl := &fields[f.cap]
			key_hi = key_lo + 2 + u64(len(fl.name))
			// Within sixteen bytes of the end, or for a name past thirteen bytes, the key token alone is
			// matched. A short name spaced from its colon is found by the lookup below.
			spelled := key_lo + 16 > n || fl.colon_key[0] == 0
			if !spelled {
				w0 := intrinsics.unaligned_load((^u64)(&src[key_lo]))
				w1 := intrinsics.unaligned_load((^u64)(&src[key_lo + 8]))
				colon_taken = (w0 ~ fl.colon_key[0]) & fl.colon_mask[0] | (w1 ~ fl.colon_key[1]) & fl.colon_mask[1] == 0
			}
			if colon_taken || spelled && key_hi <= n && src[key_hi - 1] == '"' && c.key_equals_hooked(q.hooks, src, key_lo, key_hi, false, fl.name) {
				i = int(f.cap)
			}
		}
		if i < 0 {
			q.key_esc_live, q.key_saw_escape = true, false
			kerr := lex.parse_string_q(s, q, key_lo, true, {.Shape})
			q.key_esc_live = false
			if kerr != nil || q.key_saw_escape {
				s.pos = key_lo
				return .Key
			}
			key_hi = s.pos
			if shape_first_has(op.first, src[key_lo + 1]) {
				for field, k in fields {
					if c.key_equals_hooked(q.hooks, src, key_lo, key_hi, false, field.name) {
						i = k
						break
					}
				}
			}
			if i < 0 && (r.refuse_unknown || unique) {
				s.pos = key_lo
				return .Key
			}
		}
		bit := u64(1) << uint(i) if i >= 0 else 0
		if f.seen & bit != 0 {
			s.pos = key_lo
			return .Key
		}
		if colon_taken {
			s.pos = key_hi + 1
		} else {
			s.pos = key_hi
			lex.skip_ws(s)
			if s.pos >= n || src[s.pos] != ':' {
				s.pos = key_lo
				return .Key
			}
			s.pos += 1
		}
		lex.skip_ws(s)
		// The key is latched as `shape_key` latches it.
		f.key_lo, f.key_hi = key_lo, key_hi
		op_i, dest := c.NO_FIELD, rawptr(nil)
		if i >= 0 {
			f.seen |= bit
			f.field = u32(i)
			f.cap = u32(i + 1)
			op_i, dest = fields[i].op, shape_at(f.dest, uintptr(fields[i].offset))
		} else {
			f.field = c.NO_FIELD
		}
		v := s.pos
		vc := lex.VCLASS[src[v]] if v < n else 0
		if vc < VC_STRING || (op_i != c.NO_FIELD && r.ops[op_i].kind not_in c.SHAPE_WHOLE_LEAVES) {
			r.pend_op, r.pend_dest, r.pend_live = op_i, dest, op_i != c.NO_FIELD
			return .Value
		}
		// A value nothing reads is checked as the walk checks it, a string by the walk's own `.Shape` lexer
		// and a number without the digits a leaf would decode from. Under `pass_unread` a string is passed to
		// its closing quote unchecked. One the walk refuses, or a string with no closing quote, is left to the
		// walk at its key, which latches an unknown key again exactly as the loop did.
		if op_i == c.NO_FIELD {
			ok: bool
			switch vc {
			case VC_STRING:
				when pass_unread {
					end := lex.string_end(src, int(v))
					if ok = end >= 0; ok {
						s.pos = u64(end)
					}
				} else {
					ok = lex.parse_string_q(s, q, v, false, {.Shape}) == nil
				}
			case VC_LITERAL: ok = lex.parse_literal_q(s, q, v, {}) == nil
			case: ok = number.parse_number_q(s, q, v, {}) == nil
			}
			if !ok {
				s.pos = key_lo
				return .Key
			}
		} else if took := shape_take_leaf(s, q, r, v, vc, op_i, dest, sp); took != .After {
			s.pos = v
			r.pend_op, r.pend_dest, r.pend_live = op_i, dest, true
			return took
		}
		// Compact: the comma and the next key's quote.
		if s.pos + 2 <= n && intrinsics.unaligned_load((^u16)(&src[s.pos])) == u16(',') | u16('"') << 8 {
			s.pos += 1
			continue
		}
		lex.skip_ws(s)
		if s.pos >= n || src[s.pos] != ',' {
			if s.pos < n && src[s.pos] == '}' && shape_next_record(s, r, f, sp) {
				when unique {
					key_set_close(q.keys, u32(sp))
				}
				continue
			}
			return .After
		}
		s.pos += 1
		lex.skip_ws(s)
	}
}

// The record after the one open in `f` at walk depth `sp - 1`, from its `}` at `s.pos`. When `f` is an element
// of a list of structs with room for one more, its required fields seen, and `,`, the next element's `{` and
// a key follow, the record closes and the next opens in its frame, as `shape_close` and `shape_value_open`
// would close and open them, and `s.pos` is left on that key: the walk, which checks `}`, `,` and `{` as this
// does, keeps one frame for the run of records. Otherwise nothing changes, and the walk closes the record. A
// fused struct has at most 64 fields and is no tagged arm, so its frame holds no wide words and no tag count.
@(private = "file")
shape_next_record :: #force_inline proc(s: ^Scanner, r: ^c.Shape_Run, f: ^c.Shape_Frame, sp: u64) -> bool #no_bounds_check {
	if sp < 2 {
		return false
	}
	lf := &r.frames[sp - 2]
	lop := &r.ops[lf.op]
	if lop.kind != .Slice && lop.kind != .Dynamic || lop.elem != f.op || lf.n == lf.cap || lop.stride > SHAPE_ZERO_INLINE || r.ops[f.op].required &~ f.seen != 0 {
		return false
	}
	src := s.src
	n := u64(len(src))
	close := s.pos
	s.pos += 1
	lex.skip_ws(s)
	if s.pos < n && src[s.pos] == ',' {
		s.pos += 1
		lex.skip_ws(s)
		if s.pos < n && src[s.pos] == '{' {
			s.pos += 1
			lex.skip_ws(s)
			if s.pos < n && src[s.pos] == '"' {
				dest := shape_at(lf.data, uintptr(lf.n) * uintptr(lop.stride))
				if dest != nil {
					shape_zero(dest, lop.stride)
				}
				lf.n += 1
				f^ = c.Shape_Frame{dest = dest, op = f.op, field = c.NO_FIELD}
				return true
			}
		}
	}
	s.pos = close
	return false
}

// Elements of a fused list (`Shape_Op.elements_fused`) open at walk depth `sp - 1`, read from the element at `s.pos`:
// each scalar straight into the list's next slot. A container, and a scalar the walk refuses, is handed to the
// walk before its slot is taken (`.Value`), so the walk takes it as its own.
shape_take_elements :: #force_inline proc(walk_s: ^Scanner, q: ^Query_Ctx, sp: u64) -> Shape_Take #no_bounds_check {
	r := q.shape
	if sp != r.sp {
		return .Value
	}
	f := &r.frames[sp - 1]
	fop := &r.ops[f.op]
	if !fop.elements_fused {
		return .Value
	}
	sc := walk_s^
	defer walk_s.pos = sc.pos
	s := &sc
	src := s.src
	n := u64(len(src))
	for {
		v := s.pos
		vc := lex.VCLASS[src[v]] if v < n else 0
		if vc < VC_STRING {
			return .Value
		}
		// Grown before the element is checked, as `shape_value_open` grows it.
		if f.n == f.cap && shape_list_grow(r, f, fop, v, sp) != nil {
			return .Fault
		}
		#partial switch shape_take_leaf(s, q, r, v, vc, fop.elem, shape_at(f.data, uintptr(f.n) * uintptr(fop.stride)), sp) {
		case .Value:
			s.pos = v
			return .Value
		case .Fault:
			f.n += 1
			s.pos = v
			return .Fault
		case .After:
			f.n += 1
		}
		lex.skip_ws(s)
		if s.pos >= n || src[s.pos] != ',' {
			return .After
		}
		s.pos += 1
		lex.skip_ws(s)
	}
}

// The scalar at `v`, of class `vc`, checked as the walk checks it and read into `dest` as `shape_scalar` reads
// it as op `op_i`: `.After` past it, `.Value` for a token the walk refuses, or `.Fault` once its leaf's fault
// is in the run.
@(private = "file")
shape_take_leaf :: #force_inline proc(s: ^Scanner, q: ^Query_Ctx, r: ^c.Shape_Run, v: u64, vc: u8, op_i: u32, dest: rawptr, sp: u64) -> Shape_Take {
	fault: c.Shape_Fault
	switch vc {
	case VC_STRING:
		if lex.parse_string_q(s, q, v, false, {.Shape}) != nil {
			return .Value
		}
		fault = shape_leaf_token(r, q, op_i, dest, v, s.pos, VC_STRING)
	case VC_LITERAL:
		if lex.parse_literal_q(s, q, v, {.Shape}) != nil {
			return .Value
		}
		fault = shape_leaf_token(r, q, op_i, dest, v, s.pos, VC_LITERAL)
	case:
		if number.parse_number_q(s, q, v, {.Shape}) != nil {
			return .Value
		}
		fault = shape_leaf_token(r, q, op_i, dest, v, s.pos, VC_NUMBER)
	}
	if fault != .None {
		shape_fault(r, fault, v, sp)
		return .Fault
	}
	return .After
}
