package typed

import "base:runtime"
import "core:strings"
import core ".."

// A member's `before`: a procedure of the model's user that rewrites the member's value as a `core.Value` before the load
// reads it as the member's type. The replacement is spelled as the format spells a value and read through the same check
// by `field`, so the type, the rules and the validators judge the replacement and not the text.
Before :: struct {
	call:  proc(value: core.Value, fn: rawptr, r: ^Report) -> core.Value,
	fn:    rawptr,
	value: Before_Read, // `before_value`, which a registration or a first-match union names, so a load with neither links none of it
	field: Field, // the member's record as it was before it became `.Before`, which reads the value or its replacement
	// With a nil `call`, a union read by its first arm that reads its text whole, each arm by its own record.
	first_match: bool,
	// The check plan that judges a value's text once it is read, the applicators of a model's type, nil for none. With a
	// nil `call` and no `first_match`, the value is read by `field` as the read reads any value, and then judged.
	judge:       ^Plan,
}

// A format's read of `v`, the replacement a `before` answered, through the check `h` at `regs`, which stand at the
// member's kept record. The value is spelled as the format spells it, and that text is `h`'s source while it is read, so a
// refusal's offsets are the text's. Returns the text, which lives in the temporary allocator.
// The value nests at most `depth` levels, which the frames past `h.sp` hold.
Replacement_Read :: #type proc(h: ^Check, regs: core.Hook_Regs, v: core.Value, depth: u32) -> (text: []u8, back: core.Hook_Regs, action: core.Action)

// Makes record `at`, which `fill` has filled for its member's type, a `.Before` record that keeps the first.
@(private)
keep_before :: proc(b: ^Builder, at: int, x: ^Before) {
	kept, failed := new(Before)
	if failed != nil {
		refuse_plan(b, .No_Memory)
		return
	}
	kept^ = x^
	kept.field = b.fields[at]
	_ = owned(b, (cast([^]u8)kept)[:size_of(Before)])
	b.fields[at].kind, b.meta[at].before = .Before, kept
}

// Runs the `before` of `b` on `value`, which is the text `lo..hi` of the member at `regs`, and reports what it fails as the
// member's refusals. Returns the replacement, or on a failure the registers and action a refusal gives.
@(private)
run_before :: proc(h: ^Check, regs: core.Hook_Regs, b: ^Before, value: core.Value, lo, hi: u64) -> (out: core.Value, back: core.Hook_Regs, action: core.Action, failed: bool) {
	context = h.ctx
	r := Report{make([dynamic]Failure, context.temp_allocator)}
	{
		context.allocator = context.temp_allocator
		out = b.call(value, b.fn, &r)
	}
	back = regs
	for x in r.failures {
		if x.field != "" {
			report_verdict(&h.first, h.sink, member_steps(h, regs), Verdict{failure = x}, lo)
			back, action = regs, .Stop if h.sink == nil else .Skip
		} else {
			e := core.Typed_Refusal{kind = .Custom, at = lo}
			e.want.text = x.message
			back, action = refuse(h, back, e, hi)
		}
		if action == .Stop {
			return out, back, action, true
		}
	}
	return out, back, action, len(r.failures) > 0
}

Before_Read :: #type proc "contextless" (h: ^Check, regs: core.Hook_Regs, m: ^Meta, dest: uintptr, kind: core.Kind, lo, hi: u64) -> (core.Hook_Regs, core.Action)

// Reads the member at `dest`, whose value is the text `lo..hi` of a format that builds values, as its `before` rewrote it.
@(cold)
before_value :: #force_no_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, m: ^Meta, dest: uintptr, kind: core.Kind, lo, hi: u64) -> (core.Hook_Regs, core.Action) {
	context = h.ctx
	b := m.before
	if b.call == nil && b.first_match {
		return first_match(h, regs, m, dest, kind, lo, hi)
	}
	if b.call == nil {
		return judge(h, regs, b.judge, h.src[lo:hi], lo, hi)
	}
	// The value, the replacement and its text live only for this member, so they are built in the temporary allocator and
	// given back when the member was read. A load whose own allocator is the temporary one keeps what it stores there.
	own_temp := context.allocator == context.temp_allocator
	guard := runtime.default_temp_allocator_temp_begin()
	value: core.Value
	{
		context.allocator = context.temp_allocator
		if reason := store_value(h, lo, hi, &value); reason != .None {
			return refuse(h, regs, {kind = reason, at = lo}, hi)
		}
	}
	back, action := read_replacement(h, regs, m, dest, value, lo, hi)
	// A refusal may hold the replacement's text, so only a member read whole gives its memory back.
	if !own_temp && action == .Next {
		runtime.default_temp_allocator_temp_end(guard)
	}
	return back, action
}

// Reads the member at `dest`, whose value `value` is the text `lo..hi`, as its `before` rewrote it: the replacement is
// read by the plan's `replace` through `h` at the member's kept record, so its refusals have the member's path, and they
// name the member's bytes. A judged type then judges the replacement's text.
read_replacement :: proc(h: ^Check, regs: core.Hook_Regs, m: ^Meta, dest: uintptr, value: core.Value, lo, hi: u64) -> (core.Hook_Regs, core.Action) {
	b := m.before
	if h.plan.replace == nil || b.first_match {
		return refuse(h, regs, {kind = .Unsupported, at = lo}, hi)
	}
	out, back, action, failed := run_before(h, regs, b, value, lo, hi)
	if failed {
		return back, action
	}
	sp := h.sp
	if sp + 3 > len(Replacement_Frames) {
		return refuse(h, regs, {kind = .Too_Deep, at = lo}, hi)
	}
	floor := len(h.sink.entries) if h.sink != nil else 0
	refused := h.first.kind != .None
	// The replacement nests in frames of its own, below which the read's open frames name the member's path. The
	// value is no member of the frame below, whose repeats its own key tracks.
	frames: Replacement_Frames = ---
	copy(frames[:sp], h.frames[:sp])
	held, home := h.frames, h.home
	h.frames, h.home = raw_data(frames[:]), raw_data(frames[:])
	frames[sp - 1].seen = 0
	text: []u8
	inner: core.Hook_Regs
	text, inner, action = h.plan.replace(h, {regs.a, u64(uintptr(&b.field)) + size_of(Field), u64(dest) - u64(b.field.offset)}, out, u32(len(frames) - sp - 2))
	if h.sp > sp {
		// A stop inside the replacement gives its open lists to their destinations, as `read_end` does.
		publish_open(h, inner, sp)
		h.sp = sp
	}
	seen := held[sp - 1].seen
	copy(held[:sp], frames[:sp])
	held[sp - 1].seen = seen
	h.frames, h.home = held, home
	failed = refused != (h.first.kind != .None)
	if h.sink != nil {
		failed ||= len(h.sink.entries) > floor
		for &e in h.sink.entries[floor:] {
			e.start, e.end = lo, max(hi, lo)
		}
	}
	if !refused && h.first.kind != .None {
		h.first.at = lo
	}
	switch {
	case action == .Stop:
		return regs, .Stop
	case failed:
		return regs, .Skip
	}
	return judge(h, regs, b.judge, text, lo, hi)
}

// The frames a replacement is read in, the read's open ones and as many as a text may nest.
@(private)
Replacement_Frames :: [core.MAX_DEPTH + 2]Frame

// The path of the member at `regs`, outermost step first.
@(private)
member_steps :: proc(h: ^Check, regs: core.Hook_Regs) -> []core.Step {
	inner := make([dynamic]core.Step, context.temp_allocator)
	steps_of(h, regs, false, &inner)
	member := make([dynamic]core.Step, context.temp_allocator)
	#reverse for s in inner {
		append(&member, s)
	}
	return member[:]
}

// Reports the entries `sub` collected judging a value as the member's at `regs`, with the member's path in front of each
// one's and the member's bytes in place of the value's. With no sink the first is the read's refusal.
@(private)
carry_entries :: proc(h: ^Check, regs: core.Hook_Regs, sub: ^Sink, lo, hi: u64) -> (core.Hook_Regs, core.Action) {
	if len(sub.entries) == 0 {
		kind := sub.fatal.kind
		return refuse(h, regs, {kind = kind if kind != .None else .Wrong_Kind, at = lo}, hi)
	}
	member := member_steps(h, regs)
	if h.first.kind == .None {
		x := sub.entries[0]
		text, _ := x.operand.(string)
		full := make([dynamic]core.Step, context.temp_allocator)
		append(&full, ..member)
		append(&full, ..x.path)
		h.first = refusal_at(x.kind, full[:], text, lo)
	}
	if h.sink == nil {
		return regs, .Stop
	}
	for x in sub.entries {
		if !sink_room(h.sink, context.allocator) {
			break
		}
		entry := core.Error_Entry{kind = x.kind, start = lo, end = max(hi, lo), record = h.sink.record}
		if text, named := x.operand.(string); named {
			entry.operand = strings.clone(text, h.sink.entries.allocator)
		}
		full := make([dynamic]core.Step, context.temp_allocator)
		append(&full, ..member)
		append(&full, ..x.path)
		if !sink_entry(h.sink, entry, full[:], nil, false) {
			h.sink.truncated = true
			break
		}
	}
	return regs, .Skip
}

// Reads the text `lo..hi` of a union at `dest`, a value of `kind`, into its first arm that reads the text with no
// refusal, each tried into scratch first by the arm's record. A null is the union's nil where it has one. A text no arm
// reads is refused as `.No_Arm`, followed by each arm's refusals. What the tries allocate is given back once the union is
// read.
@(private)
first_match :: proc(h: ^Check, regs: core.Hook_Regs, m: ^Meta, dest: uintptr, kind: core.Kind, lo, hi: u64) -> (core.Hook_Regs, core.Action) {
	if kind == .Null && !m.no_nil {
		runtime.mem_zero(rawptr(dest), int(m.size))
		return judge(h, regs, m.before.judge, h.src[lo:hi], lo, hi)
	}
	// A load or sink whose allocator is the temporary one keeps what it stores there, so nothing is given back.
	keep := context.allocator == context.temp_allocator || h.sink != nil && h.sink.entries.allocator == context.temp_allocator
	guard := runtime.default_temp_allocator_temp_begin()
	defer if !keep {
		runtime.default_temp_allocator_temp_end(guard)
	}
	text := h.src[lo:hi]
	dups := core.Duplicates.First if h.first_key else .Last
	subs := make([]Sink, len(m.arms), context.temp_allocator)
	scratch, failed := runtime.mem_alloc(int(m.size), 16, context.temp_allocator)
	if failed != nil {
		return refuse(h, regs, {kind = .No_Memory, at = lo}, hi)
	}
	for arm, k in m.arms {
		// The plan read from the arm's record, as a plan of the arm's type. A read's root names the record after its own.
		view := h.plan^
		view.root, view.type = &h.plan.fields[arm.fields + 1], h.plan.meta[arm.fields].type
		subs[k] = {max_errors = h.sink.max_errors if h.sink != nil else 1}
		subs[k].entries.allocator = context.temp_allocator
		if check_text(text, raw_data(scratch), view.type, &view, {dups = dups, sink = &subs[k]}, context.temp_allocator) != nil {
			continue
		}
		// The text the arm read into scratch reads alike into the union, short of memory.
		if check_text(text, rawptr(dest), view.type, &view, {dups = dups}, context.allocator) != nil {
			return refuse(h, regs, {kind = .No_Memory, at = lo}, hi)
		}
		mark_arm(dest, &m.before.field, m, k)
		return judge(h, regs, m.before.judge, text, lo, hi)
	}
	back, action := refuse(h, regs, {kind = .No_Arm, at = lo}, hi)
	for &sub in subs {
		if action == .Stop || h.sink == nil {
			break
		}
		if len(sub.entries) > 0 || sub.fatal.kind != .None {
			back, action = carry_entries(h, back, &sub, lo, hi)
		}
	}
	return back, action
}

// Reads the value `t` opens or is at the judged record `fld`, at `dest`, by the record its `.Before` keeps, as the read reads
// any value. A scalar is judged at once, and a container's frame returns to `fld` and is judged at its close.
@(cold, private)
judged_open :: #force_no_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token, fld: ^Field, m: ^Meta, dest: uintptr) -> (core.Hook_Regs, core.Action) {
	context = h.ctx
	sp := h.sp
	parent := &h.frames[sp - 1]
	if parent.seen != 0 {
		revisit(h, parent, regs, fld, dest)
	}
	// The value is no member of the frame below, whose repeats its own key tracks.
	seen := parent.seen
	parent.seen = 0
	kept := &m.before.field
	inner, action := on_token_cold(h, {regs.a, u64(uintptr(kept)) + size_of(Field), regs.c}, t)
	h.frames[sp - 1].seen = seen
	if h.sp == sp {
		back := regs
		back.c += u64(fld.stride)
		if action == .Next {
			lo, hi := core.scalar_ends(t)
			_, action = m.before.value(h, regs, m, dest, t.kind, lo, hi)
		}
		return back, action
	}
	if action == .Stop {
		return inner, action
	}
	f := &h.frames[sp]
	if !wrapper(field_at(f.b)) {
		f.owner, f.target = field_at(f.b), dest
	}
	f.a, f.b, f.c = regs.a, regs.b, regs.c
	if h.opens.allocator.procedure == nil {
		h.opens.allocator = context.temp_allocator
	}
	if _, failed := append(&h.opens, Judged_Open{sp, t.lo, m}); failed != nil {
		return refuse(h, regs, {kind = .No_Memory, at = t.lo}, t.lo + u64(t.n))
	}
	return inner, action
}

// Closes the container of a judged type that `f` holds, as `close_read` closes it, then judges its text.
@(cold, private)
judged_close :: #force_no_inline proc "contextless" (h: ^Check, f: ^Frame, own, owner: ^Field, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	context = h.ctx
	#partial switch owner.kind {
	case .Raw, .Hook, .Value:
		// A container inside the value read whole closes no frame.
		if f.seen != 0 {
			return close_read(h, f, own, owner, regs, t)
		}
	}
	open := pop(&h.opens)
	// The value's frame holds the registers it opened at, which name its path. A patch's struct is judged once merged.
	at := core.Hook_Regs{f.a, f.b, f.c}
	patching := partial(h, owner)
	back, action := close_read(h, f, own, owner, regs, t)
	if action == .Stop || patching {
		return back, action
	}
	_, judged := open.m.before.value(h, at, open.m, 0, .Null, open.lo, t.lo + u64(t.n))
	return back, judged if judged == .Stop || action == .Next else action
}

// Judges `text`, the value `lo..hi` that was read, by the check plan `plan`, nil for none, and reports what it fails
// as the value's refusals.
@(private)
judge :: proc(h: ^Check, regs: core.Hook_Regs, plan: ^Plan, text: []u8, lo, hi: u64) -> (core.Hook_Regs, core.Action) {
	if plan == nil {
		return regs, .Next
	}
	sub := Sink{max_errors = h.sink.max_errors if h.sink != nil else 1}
	sub.entries.allocator = context.temp_allocator
	target: u8
	dups := core.Duplicates.First if h.first_key else .Last
	if check_text(text, &target, nil, plan, {dups = dups, sink = &sub, repeats = .Ignore}, context.temp_allocator) == nil {
		return regs, .Next
	}
	return carry_entries(h, regs, &sub, lo, hi)
}
