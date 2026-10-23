package scan

import core_pkg "../../core"
import "walk"
import "base:intrinsics"
import "base:runtime"
import lex "lex"

// The shape walk: `walk_value_q` over `{.Shape}`, whose hooks read each value into the target its read shape
// names (`walk.Shape_Run`). The hooks act only on values at the run's depth. Anything deeper is inside a
// container nothing reads, and the walk checks it (or, under `.Lazy`, skips it) without the hooks.
//
// The unchecked accesses rest on the walk and the plan. A frame is pushed only below the walk's depth cap,
// which `resolve` holds to MAX_DEPTH, the slots `r.frames` has. A target is the root the plan was made for
// (`plan_for` refuses another type's), a field at its type-info offset, an element below an array's `count`
// or a list buffer's `cap`, or a nil target, checked only. `shape_key` and `shape_scalar` see a token only
// once the walk has checked it. `shape_tag_arm`, which reads an object before the walk does, keeps its bounds
// checks. `$unique` adds the key set, `$dialect` the JSONC walk, and `$vc` a scalar's class. The differential
// tests against a reference decoder check it.

// The destination `off` bytes into `dest`. A checked-only container's children are checked only.
shape_at :: #force_inline proc(dest: rawptr, off: uintptr) -> rawptr {
	return nil if dest == nil else rawptr(uintptr(dest) + off)
}

// `n` bytes at `p` zeroed. Up to SHAPE_ZERO_INLINE in place: below it `mem_zero`'s call, and the walk's
// constants rebuilt after it, cost more than the stores.
shape_zero :: #force_inline proc(p: rawptr, n: u32) {
	if n < 8 || n > SHAPE_ZERO_INLINE {
		runtime.mem_zero(p, int(n))
		return
	}
	a := uintptr(p)
	last := a + uintptr(n) - 8
	for ; a < last; a += 8 {
		intrinsics.unaligned_store((^u64)(a), 0)
	}
	intrinsics.unaligned_store((^u64)(last), 0)
}
SHAPE_ZERO_INLINE :: 128

// Memory the walk writes in full, or zeroes itself. An allocator that has no non-zeroed mode gets the zeroing
// one. Its zeros are not relied on.
shape_alloc :: proc(size, align: int, allocator: runtime.Allocator) -> ([]byte, runtime.Allocator_Error) {
	buf, err := runtime.mem_alloc_non_zeroed(size, align, allocator)
	if err == .Mode_Not_Implemented {
		return runtime.mem_alloc(size, align, allocator)
	}
	return buf, err
}

// `shape_alloc` for a list's growth: the bytes kept are copied, the rest left as the allocator left them.
shape_resize :: proc(ptr: rawptr, old_size, new_size, align: int, allocator: runtime.Allocator) -> ([]byte, runtime.Allocator_Error) {
	buf, err := runtime.non_zero_mem_resize(ptr, old_size, new_size, align, allocator)
	if err == .Mode_Not_Implemented {
		return runtime.mem_resize(ptr, old_size, new_size, align, allocator)
	}
	return buf, err
}

TYPED_FAULT :: walk.TYPED_FAULT

// The shape walk's one way out on a typed fault. Cold: a refusal happens at most once per call.
shape_fault :: #force_no_inline proc(r: ^walk.Shape_Run, kind: core_pkg.Shape_Fault, at: u64, steps: u64) -> Maybe(Error) {
	r.fault = kind
	r.fault_steps = u32(steps)
	return Error{offset = at, kind = TYPED_FAULT}
}

// The ops whose value is an array.
SHAPE_SEQUENCES :: bit_set[core_pkg.Shape_Kind]{.Slice, .Dynamic, .Array, .Fixed_List}
// The ops whose value is a container: a scalar token on one is the wrong kind.
SHAPE_CONTAINERS :: SHAPE_SEQUENCES + {.Struct, .Map, .Bit_Set}

// A value opens at walk depth `sp`: take its target, check its kind against the bracket, and push a frame
// for a container or latch a scalar for `shape_scalar`.
shape_value_open :: #force_inline proc(s: ^Scanner, q: ^Query_Ctx, sp: u64, vc: u8) -> Maybe(Error) #no_bounds_check {
	r := q.shape
	if sp != r.sp {
		r.reads = r.raw_open
		return nil
	}
	if vc == VC_NONE {
		// Not a value: the walk faults at this byte, a syntax result before any kind or length.
		return nil
	}
	if vc <= VC_ARRAY && sp >= q.max_depth {
		// A container past the cap: the walk refuses it as `Too_Deep` before any kind or length, and
		// `frames` has no slot for it. Read, so a lazy walk descends straight to that result.
		r.reads = true
		if sp > 0 && r.ops[r.frames[sp - 1].op].kind in SHAPE_SEQUENCES {
			// Counted, so the path names the element, as it names a member by its key.
			r.frames[sp - 1].n += 1
		}
		return nil
	}
	op_i: u32
	dest: rawptr
	if sp == 0 || r.ops[r.frames[sp - 1].op].kind not_in SHAPE_SEQUENCES {
		// The root, or a member of a struct or map: its key (or `scan_shape`) latched the target.
		if !r.pend_live {
			r.reads = false
			return nil
		}
		op_i, dest = r.pend_op, r.pend_dest
		r.pend_live = false
	} else {
		// An element: the next slot of the sequence open above.
		f := &r.frames[sp - 1]
		fop := &r.ops[f.op]
		if fop.kind == .Array || fop.kind == .Fixed_List {
			if f.n == fop.count {
				// Counted, so the path names the element too many.
				f.n += 1
				return shape_fault(r, .Wrong_Length, s.pos, sp)
			}
			dest = shape_at(f.dest, uintptr(f.n) * uintptr(fop.stride))
		} else {
			if f.n == f.cap {
				if err := shape_list_grow(r, f, fop, s.pos, sp); err != nil {
					return err
				}
			}
			dest = shape_at(f.data, uintptr(f.n) * uintptr(fop.stride))
		}
		// A list is replaced, its elements starting from zero: a grown slot holds what the allocator left (an
		// allocator's zeroing is not relied on), and a fixed-capacity one what the list held before. A fixed
		// array's element is read over in place, as Go's is.
		if dest != nil && fop.kind != .Array && r.ops[fop.elem].kind not_in SHAPE_WHOLE_LEAVES {
			shape_zero(dest, fop.stride)
		}
		f.n += 1
		op_i = fop.elem
	}
	op := &r.ops[op_i]
	// A pointer holding a value reads it into its pointee, a fresh zeroed one when it is nil, as Go's does. A
	// union reads into the arm its class picks (at offset 0), zeroed first. `null` is their own leaf, and unwrapping
	// pushes no frame, so it takes no depth.
	tagged := false
	aside: rawptr
	for (op.kind == .Pointer || op.kind == .Union) && !(vc == VC_LITERAL && s.src[s.pos] == 'n') {
		if op.kind == .Pointer {
			if dest != nil && (^rawptr)(dest)^ != nil {
				dest = (^rawptr)(dest)^
			} else if dest != nil {
				// At least one byte: an allocator answers nil for zero, and nil would read as absent.
				buf, aerr := shape_alloc(max(int(op.stride), 1), int(op.align), r.allocator)
				if aerr != nil || raw_data(buf) == nil {
					return shape_fault(r, .Out_Of_Memory, s.pos, sp)
				}
				runtime.mem_zero(raw_data(buf), len(buf))
				(^rawptr)(dest)^ = raw_data(buf)
				dest = raw_data(buf)
			}
			op_i = op.elem
		} else {
			arm, fault := shape_union_arm(r, op, dest, vc, s.pos)
			if fault != .None {
				// A scalar no arm takes is refused by the union's leaf, once the walk has checked its syntax.
				if vc >= VC_STRING {
					break
				}
				return shape_fault(r, fault, s.pos, sp)
			}
			op_i = arm
			// A tagged union reads every object by its tag.
			tagged = vc == VC_OBJECT && op.tagged
		}
		op = &r.ops[op_i]
	}
	r.reads = true
	switch vc {
	case VC_OBJECT: // `{`
		// A struct is read over in place: a member the object lacks keeps its field's value, as Go's and
		// core's do. A map keeps the entries it holds, as theirs do.
		#partial switch op.kind {
		case .Struct:
		case .Map:
			if dest != nil {
				m := (^runtime.Raw_Map)(dest)
				if m.allocator.procedure == nil {
					m.allocator = r.allocator
				}
				if r.keep_first && m.len > 0 {
					aside = dest
					if dest = shape_map_aside(r); dest == nil {
						return shape_fault(r, .Out_Of_Memory, s.pos, sp)
					}
				}
			}
		case .Raw, .Any, .Hook:
			shape_raw_open(r, s.pos, sp, dest, op_i)
			return nil
		case:
			return shape_fault(r, .Wrong_Kind, s.pos, sp)
		}
	case VC_ARRAY: // `[`
		if op.kind == .Raw || op.kind >= .Any {
			shape_raw_open(r, s.pos, sp, dest, op_i)
			return nil
		}
		if op.kind not_in SHAPE_SEQUENCES {
			return shape_fault(r, .Wrong_Kind, s.pos, sp)
		}
	case:
		if op.kind in SHAPE_CONTAINERS {
			return shape_fault(r, .Wrong_Kind, s.pos, sp)
		}
		r.cur_op, r.cur_dest, r.cur_live = op_i, dest, true
		return nil
	}
	r.frames[sp] = walk.Shape_Frame{dest = dest, data = aside, op = op_i, field = core_pkg.NO_FIELD, n = u32(tagged)}
	r.sp = sp + 1
	return nil
}

// Room for one more element in the full list open in `f`, at walk depth `sp - 1`, whose element opens at
// `at`. A fault names the element that found no room.
shape_list_grow :: proc(r: ^walk.Shape_Run, f: ^walk.Shape_Frame, fop: ^core_pkg.Shape_Op, at, sp: u64) -> Maybe(Error) {
	// `n` and `cap` are u32: a list that would outgrow them is refused, never wrapped, read or not.
	if f.cap > max(u32) / 2 {
		f.n += 1
		return shape_fault(r, .Out_Of_Memory, at, sp)
	}
	if f.dest == nil {
		// A checked-only list holds nothing. It takes the capacity a read list is refused at (8 << 28), so it
		// comes back only at that same element: `check` refuses where `unmarshal` does.
		f.cap = 1 << 31
		return nil
	}
	// Doubling, never shrunk.
	new_cap := max(8, 2 * f.cap)
	old_size, new_size := int(f.cap) * int(fop.stride), int(new_cap) * int(fop.stride)
	// The first buffer is allocated, not resized from nil: `_mem_resize`'s generic path costs a short list.
	buf: []byte
	aerr: runtime.Allocator_Error
	if f.data == nil {
		buf, aerr = shape_alloc(new_size, int(fop.align), r.allocator)
	} else {
		buf, aerr = shape_resize(f.data, old_size, new_size, int(fop.align), r.allocator)
	}
	if aerr != nil || (raw_data(buf) == nil && new_size > 0) {
		f.n += 1
		return shape_fault(r, .Out_Of_Memory, at, sp)
	}
	f.data, f.cap = raw_data(buf), new_cap
	return nil
}

// A container read whole into the `Raw`, `any`, bit_set or hooked value (op `op_i`) at `dest`. It pushes no frame, so `r.sp` stays
// put and nothing inside it is read on its own, while `raw_open` keeps `r.reads` set so the walk checks all of
// it. `shape_close` takes its span.
shape_raw_open :: #force_inline proc(r: ^walk.Shape_Run, lo, sp: u64, dest: rawptr, op_i: u32) {
	r.raw_open, r.raw_lo, r.raw_sp, r.cur_dest, r.cur_op = true, lo, sp, dest, op_i
}

// The arm of the union op `op` that a value of class `vc`, opening at `at`, reads into, tagged at `dest`: an
// object's by its tag member when it has one, else by the class. `.Wrong_Kind` when no arm takes the class.
// Out of line: a union is rare in a read shape, and the walk inlines its caller everywhere.
shape_union_arm :: #force_no_inline proc(r: ^walk.Shape_Run, op: ^core_pkg.Shape_Op, dest: rawptr, vc: u8, at: u64) -> (arm: u32, fault: core_pkg.Shape_Fault) {
	k := op.arm_of[vc]
	if vc == VC_OBJECT && op.tagged && len(r.union_tag) > 0 {
		tag_k, tag_fault := shape_tag_arm(r, op, at)
		if tag_fault != .None {
			return 0, tag_fault
		}
		if tag_k != 0 {
			k = tag_k
		} else if k == 0 {
			return 0, .Missing_Tag
		}
	}
	if k == 0 {
		return 0, .Wrong_Kind
	}
	f := r.fields[op.elem + u32(k) - 1]
	if dest != nil {
		// A union present is replaced, even one holding a pointer (Go would read through it): no arm reads over
		// another's bytes.
		runtime.mem_zero(dest, int(op.size))
		core_pkg.shape_union_tag(dest, op, f.offset)
	}
	return f.op, .None
}

// Under `.First`, a map that already holds entries reads the object into a fresh map, so that only the object's
// own repeats count as earlier occurrences. `shape_map_merge` sets its entries into the map at the close. Nil
// when the allocator refuses.
shape_map_aside :: #force_no_inline proc(r: ^walk.Shape_Run) -> rawptr {
	buf, aerr := shape_alloc(size_of(runtime.Raw_Map), align_of(runtime.Raw_Map), r.allocator)
	if aerr != nil || raw_data(buf) == nil {
		return nil
	}
	fresh := (^runtime.Raw_Map)(raw_data(buf))
	fresh^ = {allocator = r.allocator}
	return fresh
}

// Set every entry of the map `fresh` into the map `into`, over an entry it holds with the same key, then give
// back `fresh`'s storage and header (`shape_map_aside`'s): the entries are copied, so nothing points into them.
shape_map_merge :: #force_no_inline proc(op: ^core_pkg.Shape_Op, fresh, into: ^runtime.Raw_Map) -> core_pkg.Shape_Fault {
	info := op.map_info
	defer {
		allocator := fresh.allocator
		_ = runtime.map_free_dynamic(fresh^, info)
		runtime.mem_free_with_size(fresh, size_of(runtime.Raw_Map), allocator)
	}
	ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(fresh^, info)
	for i in 0 ..< uintptr(runtime.map_cap(fresh^)) {
		if !runtime.map_hash_is_valid(hs[i]) {
			continue
		}
		key := rawptr(runtime.map_cell_index_dynamic(ks, info.ks, i))
		value := rawptr(runtime.map_cell_index_dynamic(vs, info.vs, i))
		if _, aerr := runtime.__dynamic_map_set_without_hash(into, info, key, value); aerr != nil {
			return .Out_Of_Memory
		}
	}
	return .None
}

// 1 + the struct arm of the tagged union op `op` that the object at `at` names in its `r.union_tag` member, or 0
// when it has none. The walk has not checked the object yet: this pre-scan reads its members by their spans, and
// one it cannot read ends the scan as if the tag were absent, so the walk's own result on it comes next. A
// tag that is no arm's name is `.Not_A_Member`. The key and the name compare decoded, as every key does.
shape_tag_arm :: proc(r: ^walk.Shape_Run, op: ^core_pkg.Shape_Op, at: u64) -> (k: u8, fault: core_pkg.Shape_Fault) {
	p, end, found := shape_tag_span(r, at)
	if !found {
		return
	}
	for arm, i in r.fields[op.elem:][:op.count] {
		if len(arm.name) > 0 && name_equals(r.src, u64(p), u64(end), arm.name) {
			return u8(i + 1), .None
		}
	}
	return 0, .Not_A_Member
}

// The extent `src[p:end]` of the `r.union_tag` member's value in the object opening at `at`, read by spans.
shape_tag_span :: proc(r: ^walk.Shape_Run, at: u64) -> (p, end: int, found: bool) {
	src := r.src
	p = shape_skip_space(src, int(at) + 1)
	for p < len(src) && src[p] == '"' {
		key_end := lex.value_end(src, p, VC_STRING, 0)
		if key_end < 0 {
			return
		}
		is_tag := name_equals(src, u64(p), u64(key_end), r.union_tag)
		p = shape_skip_space(src, key_end)
		if p >= len(src) || src[p] != ':' {
			return
		}
		p = shape_skip_space(src, p + 1)
		if p >= len(src) || lex.VCLASS[src[p]] == VC_NONE {
			return
		}
		end = lex.value_end(src, p, lex.VCLASS[src[p]], walk.MAX_DEPTH)
		if end < 0 {
			return
		}
		if is_tag {
			return p, end, true
		}
		p = shape_skip_space(src, end)
		if p >= len(src) || src[p] != ',' {
			return
		}
		p = shape_skip_space(src, p + 1)
	}
	return
}

// The syntax fault of the tag value in the object opening at `at`, or nil when it is well-formed (or there is
// none): the result a union's `.Not_A_Member` at its `{` gives way to, since a value that is read is checked
// before it is refused. The value is checked with the byte after it, which finishes a literal or a number as the
// walk sees it. A well-formed value there is only `.Trailing`. Called after the walk, with the refusal.
@(cold)
shape_tag_verdict :: proc(r: ^walk.Shape_Run, at: u64) -> Maybe(Error) {
	p, end, found := shape_tag_span(r, at)
	if !found {
		return nil
	}
	err, bad := scan_plain(r.src[p:min(end + 1, len(r.src))]).?
	if !bad || err.kind == .Trailing {
		return nil
	}
	err.offset += u64(p)
	return err
}

// A member key of the object open at walk depth `sp - 1`: latch the field it names as the target of the
// member value. The field after the last one matched is tried first, so keys in declaration order cost one
// compare each. Under `unique` (`.Unique`) a repeated key is `.Duplicate_Key`: a struct's known fields by
// their seen bits, every other key by the walk's key set.
shape_key :: #force_inline proc(s: ^Scanner, q: ^Query_Ctx, key_lo, key_hi: u64, sp: u64, $unique: bool) -> Maybe(Error) #no_bounds_check {
	r := q.shape
	if sp != r.sp {
		when unique {
			return shape_key_unique(r, q, key_lo, key_hi, sp)
		}
		return nil
	}
	f := &r.frames[sp - 1]
	f.key_lo, f.key_hi = key_lo, key_hi
	op := &r.ops[f.op]
	if op.kind == .Map {
		when unique {
			if uerr := shape_key_unique(r, q, key_lo, key_hi, sp); uerr != nil {
				return uerr
			}
		}
		return shape_map_key(r, q, f, op, key_lo, key_hi, sp)
	}
	fields := r.fields[op.elem:][:op.count]
	escaped := q.key_saw_escape
	i := -1
	if f.cap < op.count && walk.key_equals_hooked(q.hooks, r.src, key_lo, key_hi, escaped, fields[f.cap].name) {
		i = int(f.cap)
	} else if escaped || shape_first_has(op.first, r.src[key_lo + 1]) {
		for field, k in fields {
			if walk.key_equals_hooked(q.hooks, r.src, key_lo, key_hi, escaped, field.name) {
				i = k
				break
			}
		}
	}
	if i < 0 {
		f.field = core_pkg.NO_FIELD
		when unique {
			if uerr := shape_key_unique(r, q, key_lo, key_hi, sp); uerr != nil {
				return uerr
			}
		}
		// The tag that picked this arm is no field of it, and an object names its arm once: the pre-scan
		// took the first.
		if f.n != 0 && walk.key_equals_hooked(q.hooks, r.src, key_lo, key_hi, escaped, r.union_tag) {
			if f.n == 2 {
				return shape_fault(r, .Repeated_Tag, key_lo, sp)
			}
			f.n = 2
		} else if r.refuse_unknown {
			return shape_fault(r, .Unknown_Field, key_lo, sp)
		}
		r.pend_live = false
		return nil
	}
	bit := u64(1) << uint(i)
	repeat := f.seen & bit != 0
	f.seen |= bit
	if i >= 64 {
		fault: core_pkg.Shape_Fault
		if repeat, fault = shape_wide_seen(r, f, op, u32(i)); fault != .None {
			return shape_fault(r, fault, key_lo, sp)
		}
	}
	f.field = u32(i)
	when unique {
		if repeat {
			return Error{offset = key_lo, kind = .Duplicate_Key}
		}
	}
	f.cap = u32(i + 1)
	r.pend_op = fields[i].op
	r.pend_dest = shape_at(f.dest, uintptr(fields[i].offset))
	if repeat {
		shape_repeat(r, &fields[i])
	}
	r.pend_live = true
	return nil
}

// The target of a member the object already had, which `shape_key` just latched in `r.pend_dest`. `.First` reads
// it nowhere, so the later occurrence is checked only. `.Last` zeroes it, so nothing of the earlier occurrence
// survives and the later one reads into a fresh value. `.All` leaves it, to be read over. Out of line: a repeat
// is rare, and the walk inlines its caller everywhere.
@(private = "file")
shape_repeat :: #force_no_inline proc(r: ^walk.Shape_Run, field: ^core_pkg.Shape_Field) {
	if r.keep_first {
		r.pend_dest = nil
	} else if !r.read_over && r.pend_dest != nil {
		runtime.mem_zero(r.pend_dest, int(r.ops[field.op].size))
	}
}

// `.Unique`'s check of a key no seen bit covers: one of a map, one the struct does not name, or one in a value
// the shape does not read (`sp > r.sp`). A refused spill is the shape's `.Out_Of_Memory`.
@(private = "file")
shape_key_unique :: proc(r: ^walk.Shape_Run, q: ^Query_Ctx, key_lo, key_hi: u64, sp: u64) -> Maybe(Error) {
	unique, oom := key_set_add(q.keys, r.src, key_lo, key_hi, q.key_saw_escape, u32(sp))
	if oom {
		return shape_fault(r, .Out_Of_Memory, key_lo, min(sp, r.sp))
	}
	if !unique {
		return Error{offset = key_lo, kind = .Duplicate_Key}
	}
	return nil
}

// Mark field `i`, past the first 64, of the struct frame `f` seen, claiming the frame's seen words on its first
// such field, and answers whether it was seen before.
shape_wide_seen :: proc(r: ^walk.Shape_Run, f: ^walk.Shape_Frame, op: ^core_pkg.Shape_Op, i: u32) -> (repeat: bool, fault: core_pkg.Shape_Fault) {
	if f.data == nil {
		n := (op.count - 1) / 64
		if int(r.wide_top + n) > len(r.wide) {
			return false, .Out_Of_Memory
		}
		f.data = &r.wide[r.wide_top]
		runtime.mem_zero(f.data, int(n) * size_of(u64))
		r.wide_top += n
	}
	words := ([^]u64)(f.data)
	k := i - 64
	bit := u64(1) << (k & 63)
	repeat = words[k >> 6] & bit != 0
	words[k >> 6] |= bit
	return repeat, .None
}

// At the close of a struct frame past 64 fields: the first required field past the first 64 it has not seen,
// or ok. Its seen words are given back.
shape_wide_close :: proc(r: ^walk.Shape_Run, f: ^walk.Shape_Frame, op: ^core_pkg.Shape_Op) -> (missing: u32, ok: bool) {
	n := (op.count - 1) / 64
	need := r.shape.wide[op.key:][:n]
	seen := ([^]u64)(f.data)
	if seen != nil {
		r.wide_top -= n
	}
	for w, j in need {
		lack := w if seen == nil else w &~ seen[j]
		if lack != 0 {
			return 64 + 64 * u32(j) + u32(intrinsics.count_trailing_zeros(lack)), false
		}
	}
	return 0, true
}

// A member key of a map: parse it into the key type, then insert it, so the member value fills the new
// entry. A repeat overwrites the entry with zero under `.Last`, is read over the entry under `.All`, and under
// `.First` is found and checked only.
shape_map_key :: proc(r: ^walk.Shape_Run, q: ^Query_Ctx, f: ^walk.Shape_Frame, op: ^core_pkg.Shape_Op, key_lo, key_hi, sp: u64) -> Maybe(Error) {
	// Wide and aligned enough for every key kind: a string's header, a cstring, or an integer up to 128 bits,
	// whose map compares keys as 16-aligned values.
	key: u128
	kop := &r.ops[op.key]
	escaped := q.key_saw_escape
	// Under `.First` an escape-free string key is looked up by its text in `src`, so a repeat copies
	// nothing. The key is copied only once it is new.
	plain := r.keep_first && f.dest != nil && kop.kind == .String && !escaped
	if plain {
		(^string)(&key)^ = string(r.src[key_lo + 1:key_hi - 1])
	} else if fault := shape_leaf_map_key(r, escaped, key_lo, key_hi, kop, rawptr(&key) if f.dest != nil else nil); fault != .None {
		return shape_fault(r, fault, key_lo, sp)
	}
	r.pend_op, r.pend_dest, r.pend_live = op.elem, nil, true
	if f.dest == nil {
		return nil
	}
	m := (^runtime.Raw_Map)(f.dest)
	if r.keep_first || r.read_over {
		h := op.map_info.key_hasher(&key, runtime.map_seed(m^))
		if slot := runtime.__dynamic_map_get(m, op.map_info, h, &key); slot != nil {
			// `.All` reads the later value over the entry's. `.First` checks it only.
			r.pend_dest = slot if r.read_over else nil
			return nil
		}
		if plain {
			if fault := shape_leaf_map_key(r, false, key_lo, key_hi, kop, &key); fault != .None {
				return shape_fault(r, fault, key_lo, sp)
			}
		}
	}
	slot, aerr := runtime.__dynamic_map_set_without_hash(m, op.map_info, &key, raw_data(r.shape.zero))
	if aerr != nil || slot == nil {
		return shape_fault(r, .Out_Of_Memory, key_lo, sp)
	}
	r.pend_dest = slot
	return nil
}

// Whether some field name of a struct op starts with byte `b`. An empty key's byte after the quote is the
// closing quote, which no other unescaped key starts with.
shape_first_has :: #force_inline proc(first: [4]u64, b: u8) -> bool {
	return first[b >> 6] & (u64(1) << (b & 63)) != 0
}

// The scalar token `src[lo:s.pos]` the walk just checked, a string (`vc` 3), a literal (4) or a number (5): decode
// it into the latched target.
shape_scalar :: #force_inline proc(s: ^Scanner, q: ^Query_Ctx, lo: u64, sp: u64, $vc: u8) -> Maybe(Error) #no_bounds_check {
	r := q.shape
	if !r.cur_live {
		return nil
	}
	r.cur_live = false
	if fault := shape_leaf_token(r, q, r.cur_op, r.cur_dest, lo, s.pos, vc); fault != .None {
		return shape_fault(r, fault, lo, sp)
	}
	return nil
}

// The scalar token `src[lo:hi]` of class `vc`, just checked by the walk, decoded into `dest` as op `op_i` reads
// it. The commonest leaf of the token's class is taken without the dispatch.
shape_leaf_token :: #force_inline proc(r: ^walk.Shape_Run, q: ^Query_Ctx, op_i: u32, dest: rawptr, lo, hi: u64, $vc: u8) -> core_pkg.Shape_Fault #no_bounds_check {
	when vc == VC_STRING {
		if r.ops[op_i].kind == .String && !q.str_escaped && r.borrow {
			if dest != nil {
				(^string)(dest)^ = string(r.src[lo + 1:hi - 1])
			}
			return .None
		}
	} else when vc == VC_NUMBER {
		op := &r.ops[op_i]
		#partial switch op.kind {
		case .Int:
			return shape_leaf_number_int(r, lo, hi, dest, op.width, true)
		case .Float:
			return shape_leaf_float(r, lo, hi, dest, op.width)
		}
	}
	return shape_decode_scalar(r, q, op_i, dest, lo, hi)
}

// One scalar leaf per op kind. Lowering refuses every kind without one.
shape_decode_scalar :: proc(r: ^walk.Shape_Run, q: ^Query_Ctx, op_i: u32, dest: rawptr, lo, hi: u64) -> core_pkg.Shape_Fault #no_bounds_check {
	op := &r.ops[op_i]
	// A token starting with `-` or a digit is a number the walk just checked, so `r.num` holds its digits.
	is_number := r.src[lo] == '-' || (r.src[lo] >= '0' && r.src[lo] <= '9')
	#partial switch op.kind {
	case .Bool:
		return shape_leaf_bool(r.src, lo, dest, op.width)
	case .Int, .Uint:
		if !is_number {
			return .Wrong_Kind
		}
		return shape_leaf_number_int(r, lo, hi, dest, op.width, op.kind == .Int)
	case .Float:
		return shape_leaf_float(r, lo, hi, dest, op.width)
	case .String:
		return shape_leaf_string(r, r.src, lo, hi, dest, q.str_escaped, u64(q.str_first_esc))
	case .Null:
		return .None if r.src[lo] == 'n' else .Wrong_Kind
	case .Enum_Int, .Enum_Uint:
		if !r.enum_ints {
			return shape_leaf_enum_name(r.src, lo, hi, dest, op)
		}
		return shape_leaf_enum(r.src, lo, hi, dest, op)
	case .Wide_Int, .Wide_Uint:
		return shape_leaf_wide(r.src, lo, hi, dest, op.kind == .Wide_Int)
	case .Cstring:
		return shape_leaf_cstring(r, r.src, lo, hi, dest, q.str_escaped, u64(q.str_first_esc))
	case .Rune:
		return shape_leaf_rune(r.src, lo, hi, dest, q.str_escaped)
	case .Raw:
		return shape_leaf_raw(r, lo, hi, dest)
	case .Hook:
		return shape_leaf_hook(r, lo, hi, dest, op)
	case .Decoded:
		return shape_leaf_decoded(r, r.src, lo, hi, dest, q.str_escaped, u64(q.str_first_esc), true)
	case .Number:
		return shape_leaf_number(r, lo, hi, dest)
	case .Digits:
		if !is_number {
			return .Wrong_Kind
		}
		return shape_leaf_raw(r, lo, hi, dest)
	case .Any:
		return shape_leaf_any(r, r.src, lo, hi, dest, q.str_escaped, u64(q.str_first_esc), true)
	case .Pointer, .Union:
		// Only `null` gets here, or a scalar no union arm takes: any other token was unwrapped at its open. A
		// `.Last` repeat may have filled the target before.
		if r.src[lo] != 'n' {
			return .Wrong_Kind
		}
		if op.kind == .Union && op.arm_of[0] != 0 {
			if op.arm_of[0] == core_pkg.UNION_NO_NIL {
				return .Wrong_Kind
			}
			if dest != nil {
				core_pkg.shape_union_tag(dest, op, r.fields[op.elem + u32(op.arm_of[0]) - 1].offset)
			}
			return .None
		}
		if dest != nil {
			runtime.mem_zero(dest, int(op.size))
		}
		return .None
	}
	unreachable()
}

// The container open at walk frame `idx` closed. A container read whole is its `Raw`'s span. A live struct
// must have seen every required field, and a fixed array every element. A list's header is written now that
// its length is known.
shape_close :: #force_inline proc(s: ^Scanner, q: ^Query_Ctx, idx: u64) -> Maybe(Error) #no_bounds_check {
	r := q.shape
	if r.raw_open && idx == r.raw_sp {
		r.raw_open = false
		if fault := shape_leaf_container(r, r.raw_lo, s.pos); fault != .None {
			return shape_fault(r, fault, r.raw_lo, idx)
		}
		return nil
	}
	if idx + 1 != r.sp {
		return nil
	}
	f := &r.frames[idx]
	op := &r.ops[f.op]
	#partial switch op.kind {
	case .Struct:
		if missing := op.required &~ f.seen; missing != 0 {
			f.field = u32(intrinsics.count_trailing_zeros(missing))
			return shape_fault(r, .Missing_Field, s.pos - 1, idx + 1)
		}
		if op.count > 64 {
			if missing, ok := shape_wide_close(r, f, op); !ok {
				f.field = missing
				return shape_fault(r, .Missing_Field, s.pos - 1, idx + 1)
			}
		}
	case .Map:
		if f.data != nil {
			if fault := shape_map_merge(op, (^runtime.Raw_Map)(f.dest), (^runtime.Raw_Map)(f.data)); fault != .None {
				return shape_fault(r, fault, s.pos - 1, idx)
			}
		}
	case .Array:
		// The path names the array, not an element.
		if f.n != op.count {
			return shape_fault(r, .Wrong_Length, s.pos - 1, idx)
		}
	case .Fixed_List:
		if f.dest != nil {
			(^int)(uintptr(f.dest) + uintptr(op.len_offset))^ = int(f.n)
		}
	case .Slice:
		if f.dest != nil {
			(^runtime.Raw_Slice)(f.dest)^ = {f.data, int(f.n)}
		}
	case .Dynamic:
		if f.dest != nil {
			(^runtime.Raw_Dynamic_Array)(f.dest)^ = {f.data, int(f.n), int(f.cap), r.allocator}
		}
	}
	r.sp = idx
	return nil
}
