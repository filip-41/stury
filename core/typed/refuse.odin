package typed

import "base:runtime"
import "core:strings"
import core ".."

// Where a read puts its refusals, and a read given one reads past a refusal. It adds each to `errors` up to
// `max_errors`, 100 for 0, and sets `truncated` past that, and passes over the refused value with the walk still judging
// it. A value read is left where the refused one was, so a member keeps what it held and a list's element is zero. A
// read of `Check` adds a `core.Error_Entry` to `entries` in place of the `Typed_Error`, with its path of any depth and
// its names copied, and `record` is the record index each entry takes. Both arrays allocate with their own allocator,
// the read's when it has none, and the caller frees them, `sink_destroy` freeing what an entry holds.
Sink :: struct {
	errors:     [dynamic]core.Typed_Error,
	entries:    [dynamic]core.Error_Entry,
	max_errors: int,
	record:     i64,
	truncated:  bool,
}

// What a collection held before a read, so a read taken back leaves it as it was. A nil collection's is zero.
Sink_Mark :: struct {
	errors:    int,
	entries:   int,
	truncated: bool,
}

sink_mark :: #force_inline proc(c: ^Sink) -> Sink_Mark {
	return {len(c.errors), len(c.entries), c.truncated} if c != nil else {}
}

// Takes back what the reads since `m` collected in `c`, nil for none.
sink_restore :: proc(c: ^Sink, m: Sink_Mark) {
	if c != nil {
		resize(&c.errors, m.errors)
		for &e in c.entries[m.entries:] {
			entry_destroy(&e, c.entries.allocator)
		}
		resize(&c.entries, m.entries)
		c.truncated = m.truncated
	}
}

// Frees the paths and names of the entries `c` holds and the arrays.
sink_destroy :: proc(c: ^Sink) {
	for &e in c.entries {
		entry_destroy(&e, c.entries.allocator)
	}
	delete(c.entries)
	delete(c.errors)
}

// An entry's path and names are the allocator of the sink's `entries`.
@(private)
entry_destroy :: proc(e: ^core.Error_Entry, allocator: runtime.Allocator) {
	for s in e.path {
		if name, named := s.(core.Name); named {
			delete(string(name), allocator)
		}
	}
	delete(e.path, allocator)
	e^ = {}
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
own_errors :: proc(e: ^core.Typed_Error, c: ^Sink) {
	own_names(e)
	if c != nil {
		for &x in c.errors {
			own_names(&x)
		}
	}
}

// The one refusal: records `e` and says how the walk goes on, which is `.Stop` unless a `Sink` reads on. The hot
// path has no branch on the sink.
@(cold)
refuse :: #force_no_inline proc "contextless" (h: ^Reader, regs: core.Hook_Regs, e: core.Typed_Error, end := u64(0)) -> (core.Hook_Regs, core.Action) {
	context = h.ctx
	note(h, regs, e, end)
	return regs, .Stop if h.sink == nil else .Skip
}

// Refuses the value `t`, which a collecting read then counts as read. A refusal of what the value is names the type the
// record reads and what the value holds.
@(cold)
refuse_value :: #force_no_inline proc "contextless" (h: ^Reader, regs_in: core.Hook_Regs, t: core.Token, kind: core.Typed_Error_Kind) -> (core.Hook_Regs, core.Action) {
	// `hi` is exact for a scalar, and a container's open token's end, as the skip that follows passes its close unseen.
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
	regs, action := refuse(h, regs_in, e, hi)
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

// Adds `e`, with the path to where the read stands, to the sink. A wide reader (a `Check`) adds a `core.Error_Entry`
// ending at `end`, with the path of any depth and its names copied.
@(private)
note :: proc(h: ^Reader, regs: core.Hook_Regs, e: core.Typed_Error, end: u64) {
	e := e
	held := e.n_steps > 0
	held_step := e.steps[0]
	path_of(h, regs, &e)
	if h.first.kind == .None {
		h.first = e
	}
	if !h.wide {
		sink_error(h.sink, e)
		return
	}
	c := h.sink
	if c == nil {
		return
	}
	if len(c.entries) >= (c.max_errors if c.max_errors != 0 else 100) {
		c.truncated = true
		return
	}
	if c.entries.allocator.procedure == nil {
		c.entries.allocator = h.ctx.allocator
	}
	if !entry_add(c, e, h, regs, held, held_step, end) {
		c.truncated = true
	}
}

// Appends the entry of `e`, whose path is copied to exactly the size it frees at, and says whether it fit in memory.
@(private)
entry_add :: proc(c: ^Sink, e: core.Typed_Error, h: ^Reader, regs: core.Hook_Regs, held: bool, held_step: core.Step, end: u64) -> bool {
	context.allocator = c.entries.allocator
	steps := make([dynamic]core.Step, context.temp_allocator)
	if held {
		if _, grown := append(&steps, held_step); grown != nil {
			return false
		}
	}
	steps_of(h, regs, held, &steps)
	n := len(steps)
	path, failed := make([]core.Step, n)
	if failed != nil {
		return false
	}
	for i in 0 ..< n {
		path[i] = steps[n - 1 - i]
		if name, named := path[i].(core.Name); named {
			text, cloned := strings.clone(string(name))
			if cloned != nil {
				entry_destroy(&core.Error_Entry{path = path[:i]}, c.entries.allocator)
				delete(path)
				return false
			}
			path[i] = core.Name(text)
		}
	}
	if _, grown := append(&c.entries, core.Error_Entry{kind = e.kind, start = e.at, end = max(end, e.at), record = c.record, path = path}); grown != nil {
		entry_destroy(&core.Error_Entry{path = path}, c.entries.allocator)
		return false
	}
	return true
}

// Adds a refusal found before a read starts (a duplicate key, a fault of the text) to `c`, as an entry when `wide`.
sink_refusal :: proc(c: ^Sink, e: core.Typed_Error, $wide: bool) {
	when wide {
		if c == nil {
			return
		}
		if len(c.entries) >= (c.max_errors if c.max_errors != 0 else 100) {
			c.truncated = true
			return
		}
		if c.entries.allocator.procedure == nil {
			c.entries.allocator = context.allocator
		}
		context.allocator = c.entries.allocator
		if _, grown := append(&c.entries, core.Error_Entry{kind = e.kind, start = e.at, end = e.at, record = c.record}); grown != nil {
			c.truncated = true
		}
	} else {
		sink_error(c, e)
	}
}

// Adds `e` to `c`, nil for none, and past its cap only marks it truncated.
sink_error :: proc(c: ^Sink, e: core.Typed_Error) {
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
	steps_of(h, regs, e.n_steps > 0, e)
	path_close(e)
}

// Walks the open frames outward from the registers, handing `add_step` each step, innermost first. `skip` drops the
// step of the innermost frame, which the caller already holds.
@(private)
steps_of :: proc(h: ^Reader, regs: core.Hook_Regs, skip_first: bool, out: ^$O) {
	cur := h.wrap^ if int(h.wrap_sp) == h.sp else regs
	skip := skip_first
	for i := h.sp - 1; i >= 1; i -= 1 {
		f := &h.frames[i]
		if !skip {
			if step, ok := step_at(h, f, cur); ok {
				add_step(out, step)
			}
		}
		skip = false
		cur = {f.a, f.b, f.c}
	}
}

@(private)
add_step :: proc {
	path_add,
	add_step_wide,
}

@(private)
add_step_wide :: proc(out: ^[dynamic]core.Step, s: core.Step) {
	append(out, s)
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
