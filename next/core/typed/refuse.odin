package typed

import "base:runtime"
import "core:strings"
import core ".."

// The sink that reads past a refusal. A read given one adds each refusal to `errors` up to `max_errors`, 100 for 0, and
// sets `truncated` past that, and passes over the refused value with the walk still judging it. A value read is left
// where the refused one was, so a member keeps what it held and a list's element is zero. `errors` allocates with its
// own allocator, the read's when it has none, and the caller frees it.
Collected :: struct {
	errors:     [dynamic]core.Typed_Error,
	max_errors: int,
	truncated:  bool,
}

// What a collection held before a read, so a read taken back leaves it as it was. A nil collection's is zero.
Collected_Mark :: struct {
	errors:    int,
	truncated: bool,
}

collected_mark :: #force_inline proc(c: ^Collected) -> Collected_Mark {
	return {len(c.errors), c.truncated} if c != nil else {}
}

// Takes back what the reads since `m` collected in `c`, nil for none.
collected_restore :: proc(c: ^Collected, m: Collected_Mark) {
	if c != nil {
		resize(&c.errors, m.errors)
		c.truncated = m.truncated
	}
}

// Copies the names in `e`'s steps into the temp allocator, for an error that outlives the plan its names point into.
own_names :: proc(e: ^core.Typed_Error) {
	for &s in e.steps[:e.n_steps] {
		if name, named := s.(core.Name); named {
			text, failed := strings.clone(string(name), context.temp_allocator)
			s = core.Name(text if failed == nil else "")
		}
	}
}

// `own_names` for each error a read collected.
own_collected :: proc(c: ^Collected) {
	if c != nil {
		for &e in c.errors {
			own_names(&e)
		}
	}
}

// The one refusal: records `e` and says how the walk goes on, which is `.Stop` unless a `Collected` reads on. The hot
// path has no branch on the sink.
@(cold)
refuse :: #force_no_inline proc "contextless" (h: ^Reader, regs: core.Hook_Regs, e: core.Typed_Error) -> (core.Hook_Regs, core.Action) {
	context = h.ctx
	note(h, regs, e)
	return regs, .Stop if h.collect == nil else .Skip
}

// Refuses the value `t`, which a collecting read then counts as read.
@(cold)
refuse_value :: #force_no_inline proc "contextless" (h: ^Reader, regs_in: core.Hook_Regs, t: core.Token, kind: core.Typed_Error_Kind) -> (core.Hook_Regs, core.Action) {
	lo, _ := core.scalar_ends(t)
	regs, action := refuse(h, regs_in, {kind = kind, at = lo})
	fld := field_at(regs.b)
	if fld.stride != 0 {
		runtime.mem_zero(rawptr(uintptr(regs.c)), int(fld.stride))
		regs.c += u64(fld.stride)
	}
	return regs, action
}

// Refuses an element no room was made for, which a collecting read does not count.
@(cold)
refuse_element :: #force_no_inline proc "contextless" (h: ^Reader, regs: core.Hook_Regs, t: core.Token, kind: core.Typed_Error_Kind) -> (core.Hook_Regs, core.Action) {
	lo, _ := core.scalar_ends(t)
	return refuse(h, regs, {kind = kind, at = lo})
}

// Adds `e`, with the path to where the read stands, to the sink.
@(private)
note :: proc(h: ^Reader, regs: core.Hook_Regs, e: core.Typed_Error) {
	e := e
	path_of(h, regs, &e)
	if h.first.kind == .None {
		h.first = e
	}
	if c := h.collect; c != nil {
		if len(c.errors) >= (c.max_errors if c.max_errors != 0 else 100) {
			c.truncated = true
		} else {
			append(&c.errors, e)
		}
	}
}

// Builds `e`'s path, the innermost `MAX_ERROR_STEPS` steps, from the open frames. A step `e` holds already is the last,
// in place of the step the registers stand at.
@(private)
path_of :: proc(h: ^Reader, regs: core.Hook_Regs, e: ^core.Typed_Error) {
	buf: [core.MAX_ERROR_STEPS]core.Step
	n := 0
	if e.n_steps > 0 {
		buf[0], n = e.steps[0], 1
	}
	cur := regs
	skip := e.n_steps > 0
	for i := h.sp - 1; i >= 1; i -= 1 {
		f := &h.frames[i]
		if !skip {
			step, ok := step_at(h, f, cur)
			if ok {
				if n == len(buf) {
					e.truncated = true
					break
				}
				buf[n] = step
				n += 1
			}
		}
		skip = false
		cur = {f.a, f.b, f.c}
	}
	e.n_steps = u8(n)
	for k in 0 ..< n {
		e.steps[k] = buf[n - 1 - k]
	}
}

// The step of the value the registers `at` stand at inside the container `f`.
@(private)
step_at :: proc(h: ^Reader, f: ^Frame, at: core.Hook_Regs) -> (s: core.Step, ok: bool) {
	owner := frame_owner(f)
	#partial switch owner.kind {
	case .Struct, .Required:
		name := h.plan.meta[field_at(at.b).meta].name
		return core.Name(name), len(name) > 0
	case .Map:
		return core.Name(string(([^]u8)(f.extra)[:uintptr(f.run)])), true
	case .Slice, .Dynamic, .Array, .Fixed_List:
		if f.data == nil {
			return core.Index(0), true
		}
		return core.Index((at.c - u64(uintptr(f.data))) / u64(h.plan.meta[owner.meta].elem_size)), true
	}
	return
}
