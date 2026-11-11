package typed

import "base:runtime"
import "core:reflect"
import "core:strings"
import core ".."

// Where a read puts its refusals, and a read given one reads past a refusal. It adds each to `errors` up to
// `max_errors`, 100 for 0, and sets `truncated` past that, and passes over the refused value with the walk still judging
// it. A value read is left where the refused one was, so a member keeps what it held and a list's element is zero. A
// read of `Check` adds a `core.Error_Entry` to `entries` in place of the `Typed_Refusal`, with its path of any depth and
// its names copied, and `record` is the record index each entry takes. Both arrays allocate with their own allocator,
// the read's when it has none, and the caller frees them, `sink_destroy` freeing what an entry holds.
Sink :: struct {
	errors:     [dynamic]core.Typed_Refusal,
	entries:    [dynamic]core.Error_Entry,
	max_errors: int,
	record:     i64,
	truncated:  bool,
	// The fault that ended a read, which is set whatever `max_errors` kept, so a text that does not parse is never an
	// entry a limit can drop.
	fatal:      core.Typed_Refusal,
}

// What a collection held before a read, so a read taken back leaves it as it was. A nil collection's is zero.
Sink_Mark :: struct {
	errors:    int,
	entries:   int,
	truncated: bool,
}

// How many entries or errors `c` keeps: its `max_errors`, 100 when that is 0.
@(private)
sink_limit :: #force_inline proc "contextless" (c: ^Sink) -> int {
	return c.max_errors if c.max_errors != 0 else 100
}

// Appends `e` to the entries of `c` unless it holds its limit, which it marks as truncated. Says whether `e` was added,
// and an error when memory ran out, which is no truncation.
sink_add :: proc(c: ^Sink, e: core.Error_Entry) -> (added: bool, err: runtime.Allocator_Error) {
	if len(c.entries) >= sink_limit(c) {
		c.truncated = true
		return
	}
	_, err = append(&c.entries, e)
	return err == nil, err
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
		c.fatal = {}
	}
}

// Marks the default temp allocator before the check of one record, for `temp_release` to give back what that check took
// from it, so a check of many records does not grow the temp allocator. A sink whose entries are in the temp allocator
// takes no mark, since the release would free them.
temp_mark :: proc(c: ^Sink) -> runtime.Arena_Temp {
	if c != nil && c.entries.allocator.procedure == context.temp_allocator.procedure {
		return {}
	}
	return runtime.default_temp_allocator_temp_begin()
}

// Gives back what the temp allocator gave since `m`, unless `keep`, which a record whose first failure is kept past it
// says, since that failure's path may name a key decoded into the temp allocator. Says whether it was given back.
temp_release :: proc(m: runtime.Arena_Temp, keep := false) -> bool {
	if m.arena == nil {
		return false
	}
	if keep {
		runtime.arena_temp_ignore(m)
		return false
	}
	runtime.default_temp_allocator_temp_end(m)
	return true
}

// Frees the paths and names of the entries `c` holds and the arrays.
sink_destroy :: proc(c: ^Sink) {
	for &e in c.entries {
		entry_destroy(&e, c.entries.allocator)
	}
	delete(c.entries)
	delete(c.errors)
}

// An entry's paths and their names are the allocator of the sink's `entries`.
@(private)
entry_destroy :: proc(e: ^core.Error_Entry, allocator: runtime.Allocator) {
	for s in e.path {
		if name, named := s.(core.Name); named {
			delete(string(name), allocator)
		}
	}
	for s in e.keyword_path {
		if name, named := s.(core.Name); named {
			delete(string(name), allocator)
		}
	}
	if name, named := e.operand.(string); named {
		delete(name, allocator)
	}
	delete(e.path, allocator)
	delete(e.keyword_path, allocator)
	e^ = {}
}

// Copies the names in `e`'s steps into the temp allocator, for an error that outlives the plan its names point into.
own_names :: proc(e: ^core.Typed_Refusal) {
	if e.kind == .Custom {
		text, failed := strings.clone(e.want.text, context.temp_allocator)
		e.want.text = text if failed == nil else ""
	}
	for &s in e.steps[:e.n_steps] {
		if name, named := s.(core.Name); named {
			text, failed := strings.clone(string(name), context.temp_allocator)
			s = core.Name(text if failed == nil else "")
		}
	}
}

// `own_names` for a read's error and each error it collected.
own_errors :: proc(e: ^core.Typed_Refusal, c: ^Sink) {
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
refuse :: #force_no_inline proc "contextless" (h: ^Reader, regs: core.Hook_Regs, e: core.Typed_Refusal, end := u64(0)) -> (core.Hook_Regs, core.Action) {
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
	e := core.Typed_Refusal{kind = kind, at = lo}
	fld := field_at(regs_in.b)
	if kind == .Wrong_Kind || kind == .Out_Of_Range || kind == .Not_A_Member || kind == .Above_Maximum || kind == .Below_Minimum {
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

// Refuses an element no room was made for, which a collecting read does not count. A list past its fixed length is
// refused once, as the list's, and its frame's `seen` holds that it was.
@(cold)
refuse_element :: #force_no_inline proc "contextless" (h: ^Reader, regs: core.Hook_Regs, t: core.Token, kind: core.Typed_Error_Kind) -> (core.Hook_Regs, core.Action) {
	lo, hi := core.scalar_ends(t)
	if kind != .Too_Many {
		return refuse(h, regs, {kind = kind, at = lo})
	}
	f := &h.frames[h.sp - 1]
	if f.seen == 0 {
		context = h.ctx
		f.seen = 1
		h.sp -= 1
		note(h, {f.a, f.b, f.c}, {kind = kind, at = lo}, hi)
		h.sp += 1
	}
	return regs, .Stop if h.sink == nil else .Skip
}

// Adds `e`, with the path to where the read stands, to the sink. A wide reader, a check, adds a `core.Error_Entry`
// ending at `end`, with the path of any depth and its names copied, and under a `keyword` of a description's plan the
// keyword path to it.
@(private)
note :: proc(h: ^Reader, regs: core.Hook_Regs, e: core.Typed_Refusal, end: u64, keyword: Maybe(string) = nil, operand := "") {
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
	if c == nil || !sink_room(c, h.ctx.allocator) {
		return
	}
	if !entry_add(c, e, h, regs, held, held_step, end, keyword, operand) {
		c.truncated = true
	}
}

// Appends the entry of `e`, whose paths are copied to exactly the size they free at, and says whether it fit in memory.
// The keyword path is each open record's use site, then the value's, then `keyword`, for a description's plan.
@(private)
entry_add :: proc(c: ^Sink, e: core.Typed_Refusal, h: ^Reader, regs: core.Hook_Regs, held: bool, held_step: core.Step, end: u64, keyword: Maybe(string), operand: string) -> bool {
	context.allocator = c.entries.allocator
	// The paths are built in the sink's allocator and freed, so a sink a held value drops costs nothing that stays.
	steps, words := make([dynamic]core.Step), make([dynamic]core.Step)
	defer delete(steps)
	defer delete(words)
	if held {
		append(&steps, held_step)
	}
	steps_of(h, regs, held, &steps)
	if word, keyed := keyword.?; keyed && h.plan.checking {
		ck := (^Check)(h)
		if ck.run != nil {
			run_outer(ck.run, &steps, &words)
		} else {
			outer_add(ck, &steps, &words)
		}
		for i in 1 ..< h.sp {
			append(&words, ..h.plan.uses[field_at(h.frames[i].b).meta].site)
		}
		if !held {
			append(&words, ..h.plan.uses[field_at(regs.b).meta].site)
		}
		append(&words, ..ck.after)
		if word != "" {
			append(&words, core.Name(word))
		}
	}
	entry := core.Error_Entry{kind = e.kind, start = e.at, end = max(end, e.at), record = c.record}
	if (e.kind == .Missing_Field || e.kind == .Custom) && h.wide && e.want.text != "" {
		entry.operand = strings.clone(e.want.text)
	} else if operand != "" {
		entry.operand = strings.clone(operand)
	} else if e.kind == .Wrong_Kind && e.want.type != nil && !h.plan.checking {
		b := strings.builder_make(context.temp_allocator)
		reflect.write_typeid(strings.to_writer(&b), e.want.type)
		entry.operand = strings.clone(strings.to_string(b))
	}
	return sink_entry(c, entry, steps[:], words[:], true)
}

// Whether `c` has room for another entry, which it marks as truncated when it has none. Entries that have no allocator
// take `allocator`.
sink_room :: proc(c: ^Sink, allocator: runtime.Allocator) -> bool {
	if len(c.entries) >= sink_limit(c) {
		c.truncated = true
		return false
	}
	if c.entries.allocator.procedure == nil {
		c.entries.allocator = allocator
	}
	return true
}

// Appends `entry` to `c` with copies of the paths `steps`, read from the last when `reverse` says so, and `words`, and of
// their names. Says whether they fit in memory.
sink_entry :: proc(c: ^Sink, entry: core.Error_Entry, steps, words: []core.Step, reverse: bool) -> bool {
	context.allocator = c.entries.allocator
	entry := entry
	path_ok, words_ok := owned_steps(&entry.path, steps, reverse), owned_steps(&entry.keyword_path, words, false)
	if !path_ok || !words_ok {
		entry_destroy(&entry, c.entries.allocator)
		return false
	}
	if _, grown := append(&c.entries, entry); grown != nil {
		entry_destroy(&entry, c.entries.allocator)
		return false
	}
	return true
}

// Copies `steps`, read from the last when `reverse` says so, and their names into `out`, from the context allocator.
// Says whether they fit in memory, with what fit in `out`.
@(private)
owned_steps :: proc(out: ^[]core.Step, steps: []core.Step, reverse: bool) -> bool {
	if len(steps) == 0 {
		return true
	}
	path, failed := make([]core.Step, len(steps))
	if failed != nil {
		return false
	}
	for i in 0 ..< len(steps) {
		path[i] = steps[len(steps) - 1 - i] if reverse else steps[i]
		if name, named := path[i].(core.Name); named {
			text, cloned := strings.clone(string(name))
			if cloned != nil {
				out^ = path[:i]
				return false
			}
			path[i] = core.Name(text)
		}
	}
	out^ = path
	return true
}

// Adds a refusal found before a read starts (a duplicate key, a fault of the text) to `c`, as an entry when `wide`.
sink_refusal :: proc(c: ^Sink, e: core.Typed_Refusal, $wide: bool) {
	e := e
	when wide {
		if c == nil {
			return
		}
		if sink_room(c, context.allocator) && !sink_entry(c, core.Error_Entry{kind = e.kind, start = e.at, end = e.at, record = c.record}, e.steps[:e.n_steps], nil, false) {
			c.truncated = true
		}
	} else {
		sink_error(c, e)
	}
}

// Adds `e` to `c`, nil for none, and past its cap only marks it truncated.
sink_error :: proc(c: ^Sink, e: core.Typed_Refusal) {
	if c == nil {
		return
	}
	if len(c.errors) >= (sink_limit(c)) {
		c.truncated = true
	} else {
		append(&c.errors, e)
	}
}

// Builds `e`'s path from the open frames. A step `e` holds already is the last, in place of the step the registers stand
// at.
@(private)
path_of :: proc(h: ^Reader, regs: core.Hook_Regs, e: ^core.Typed_Refusal) {
	e.n_steps = min(e.n_steps, 1)
	steps_of(h, regs, e.n_steps > 0, e)
	path_close(e)
}

// Walks the open frames outward from the registers, handing `add_step` each step, innermost first, from the frame below
// `below` when it is set. `skip` drops the step of the innermost frame, which the caller already holds.
@(private)
steps_of :: proc(h: ^Reader, regs: core.Hook_Regs, skip_first: bool, out: ^$O, below := 0) {
	cur := h.wrap^ if int(h.wrap_sp) == h.sp else regs
	skip := skip_first
	for i := (below if below > 0 else h.sp) - 1; i >= 1; i -= 1 {
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
path_add :: proc "contextless" (e: ^core.Typed_Refusal, s: core.Step) {
	if int(e.n_steps) == core.MAX_ERROR_STEPS {
		e.truncated = true
		return
	}
	e.steps[e.n_steps] = s
	e.n_steps += 1
}

// Turns the path `path_add` built from the innermost step to read from the outermost.
path_close :: proc "contextless" (e: ^core.Typed_Refusal) {
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
	case .Checked:
		return checked_step(h, f, owner, at)
	}
	return
}

// Puts the entries of `c` from `from` on in the order a load, a check and a `validate` share: an entry before those of the
// same record that lie inside its value, and at one path a validator's `.Custom` after the rules' failures. Every other
// pair keeps the order it was reported in, which is the text's for a load or a check and the order a write of the value
// spells for `validate`, so a validate of a value and a load of its written text list the same entries alike. An entry of
// the fault that ended a walk stays where it is.
order_entries :: proc(c: ^Sink, from: int) {
	if c == nil {
		return
	}
	entries := c.entries[:]
	for i in from + 1 ..< len(entries) {
		e := entries[i]
		k := i
		for k > from && e.kind != .Walk && entries[k - 1].kind != .Walk && goes_after(entries[k - 1], e) {
			k -= 1
		}
		copy(entries[k + 1:i + 1], entries[k:i])
		entries[k] = e
	}
}

// Whether entry `a`, reported before `b`, is listed after it: it lies inside `b`'s value, or it is a validator's at
// `b`'s path and `b` is not.
@(private)
goes_after :: proc(a, b: core.Error_Entry) -> bool {
	if a.record != b.record || len(a.path) < len(b.path) {
		return false
	}
	for s, i in b.path {
		if a.path[i] != s {
			return false
		}
	}
	return len(a.path) > len(b.path) || a.kind == .Custom && b.kind != .Custom
}
