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

// `own_names` for a read's error and each error it collected.
own_errors :: proc(e: ^core.Typed_Error, c: ^Collected) {
	own_names(e)
	if c != nil {
		for &x in c.errors {
			own_names(&x)
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

// Refuses the value `t`, which a collecting read then counts as read. A refusal of what the value is names the type the
// record reads and what the value holds.
@(cold)
refuse_value :: #force_no_inline proc "contextless" (h: ^Reader, regs_in: core.Hook_Regs, t: core.Token, kind: core.Typed_Error_Kind) -> (core.Hook_Regs, core.Action) {
	lo, hi := core.scalar_ends(t)
	e := core.Typed_Error{kind = kind, at = lo}
	fld := field_at(regs_in.b)
	if kind == .Wrong_Kind || kind == .Out_Of_Range || kind == .Not_A_Member {
		e.found = t.kind
		e.want.type = h.plan.meta[fld.meta].type
		// A `Maybe` reads its element or null, and a null it takes, so its element is what the value failed.
		if ti := type_info_of(e.want.type); ti == nil {
		} else if u, maybe := runtime.type_info_base(ti).variant.(runtime.Type_Info_Union); maybe && len(u.variants) == 1 {
			e.want.type = u.variants[0].id
		}
		if t.kind != .Object && t.kind != .Array {
			e.want.text = string(h.src[lo:hi])
		}
	}
	regs, action := refuse(h, regs_in, e)
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
	collect_error(h.collect, e)
}

// Adds `e` to `c`, nil for none, and past its cap only marks it truncated.
collect_error :: proc(c: ^Collected, e: core.Typed_Error) {
	if c == nil {
		return
	}
	if len(c.errors) >= (c.max_errors if c.max_errors != 0 else 100) {
		c.truncated = true
	} else {
		append(&c.errors, e)
	}
}

// Builds `e`'s path from the open frames. A step `e` holds already is the last, in place of the step the registers stand
// at.
@(private)
path_of :: proc(h: ^Reader, regs: core.Hook_Regs, e: ^core.Typed_Error) {
	e.n_steps = min(e.n_steps, 1)
	cur := h.wrap^ if int(h.wrap_sp) == h.sp else regs
	skip := e.n_steps > 0
	for i := h.sp - 1; i >= 1; i -= 1 {
		f := &h.frames[i]
		if !skip {
			if step, ok := step_at(h, f, cur); ok {
				path_add(e, step)
			}
		}
		skip = false
		cur = {f.a, f.b, f.c}
	}
	path_close(e)
}

// Adds `s`, the next step out, to the path of `e`, which `path_close` turns to read from the outermost. The path keeps
// the innermost `MAX_ERROR_STEPS` steps, and `e.truncated` says when it dropped one.
path_add :: proc "contextless" (e: ^core.Typed_Error, s: core.Step) {
	if int(e.n_steps) == core.MAX_ERROR_STEPS {
		e.truncated = true
		return
	}
	e.steps[e.n_steps] = s
	e.n_steps += 1
}

// Turns the path `path_add` built from the innermost step to read from the outermost.
path_close :: proc "contextless" (e: ^core.Typed_Error) {
	for i in 0 ..< int(e.n_steps) / 2 {
		j := int(e.n_steps) - 1 - i
		e.steps[i], e.steps[j] = e.steps[j], e.steps[i]
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
