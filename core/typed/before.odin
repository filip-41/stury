package typed

import "base:runtime"
import "core:strings"
import spell "../spell"
import core ".."
import rules "../rules"

// A member's `before`: a procedure of the model's user that rewrites the member's value as a `core.Value` before the load
// reads it as the member's type. The replacement is spelled as the format spells a value and read by `plan`, which holds
// the member's rules at its root, so the type, the rules and the validators judge the replacement and not the text.
Before :: struct {
	call:  proc(value: core.Value, fn: rawptr, r: ^Report) -> core.Value,
	fn:    rawptr,
	value: Before_Read, // `before_value`, which a registration or a first-match union names, so a load with neither links none of it
	rules: rules.Rules, // the member's, which the root of `plan` takes
	plan:  ^Plan, // reads the replacement as the member's type, which the model sets
	field: Field, // the member's record as it was before it became `.Before`, for a format that reads a cell by it
	// With a nil `call`, a union read by its first arm that reads its text whole, each arm by its own record.
	first_match: bool,
	// The check plan that judges the text of a value read with no refusal, the applicators of a model's type, nil for
	// none. With a nil `call` and no `first_match`, the value is read by `field` and then judged.
	judge:       ^Plan,
}

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
			report_verdict(h, member_steps(h, regs), Verdict{failure = x}, lo)
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

// The text a format that reads a cell takes for the scalar `v`, in `buf` when it is a number. A null spells an empty cell.
scalar_text :: proc "contextless" (v: core.Value, buf: ^[spell.F64_ROOM]u8) -> (text: string, ok: bool) {
	switch x in v {
	case nil:
		return "", true
	case string:
		return x, true
	case bool:
		return "true" if x else "false", true
	case ^core.Number_Text:
		return x.text, true
	case f64:
		if x != x || abs(x) > max(f64) {
			return "", false
		}
		return string(buf[:spell.f64_text(&buf[0], x)]), true
	case ^core.Array, ^core.Object, core.Node_Ref, ^core.Commented, core.Trail:
	}
	return "", false
}

Before_Read :: #type proc "contextless" (h: ^Check, regs: core.Hook_Regs, m: ^Meta, dest: uintptr, kind: core.Kind, lo, hi: u64) -> (core.Hook_Regs, core.Action)

// Reads the member at `dest`, whose value is the text `lo..hi` of a format that builds values and writes them back, as its
// `before` rewrote it. A replacement the member's type or rules refuse is refused at the member, with the path it
// refused at under the member.
@(cold)
before_value :: #force_no_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, m: ^Meta, dest: uintptr, kind: core.Kind, lo, hi: u64) -> (core.Hook_Regs, core.Action) {
	context = h.ctx
	b := m.before
	if b.call == nil && b.first_match {
		return first_match(h, regs, m, dest, kind, lo, hi)
	}
	if b.call == nil {
		return judged_value(h, regs, m, dest, lo, hi)
	}
	if h.plan.value_text == nil || b.plan == nil {
		return refuse(h, regs, {kind = .Unsupported, at = lo}, hi)
	}
	// The value, the replacement and its text live only for this member, so they are built in the temporary allocator and
	// given back when the member was read.
	// A load whose own allocator is the temporary one keeps what it stores there, so nothing is given back.
	own_temp := context.allocator == context.temp_allocator
	guard := runtime.default_temp_allocator_temp_begin()
	value: core.Value
	{
		context.allocator = context.temp_allocator
		if reason := store_value(h, lo, hi, &value); reason != .None {
			return refuse(h, regs, {kind = reason, at = lo}, hi)
		}
	}
	out, back, action, failed := run_before(h, regs, b, value, lo, hi)
	if failed {
		return back, action
	}
	text, err := h.plan.value_text(h.plan, out, context.temp_allocator)
	if err.kind != .None {
		return refuse(h, regs, {kind = err.kind, at = lo}, hi)
	}
	sub := Sink{max_errors = h.sink.max_errors if h.sink != nil else 1}
	sub.entries.allocator = context.allocator
	defer sink_destroy(&sub)
	dups := core.Duplicates.First if h.first_key else .Last
	if check_text(text, rawptr(dest), m.type, b.plan, {dups = dups, sink = &sub}, context.allocator) == nil {
		if !own_temp {
			runtime.default_temp_allocator_temp_end(guard)
		}
		return regs, .Next
	}
	return carry_entries(h, regs, &sub, lo, hi)
}

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

// Reports the entries `sub` collected reading a replacement as the member's at `regs`, with the member's path in front of
// each one's and the member's bytes in place of the replacement's.
@(private)
carry_entries :: proc(h: ^Check, regs: core.Hook_Regs, sub: ^Sink, lo, hi: u64) -> (core.Hook_Regs, core.Action) {
	member := member_steps(h, regs)
	if len(sub.entries) == 0 {
		kind := sub.fatal.kind
		return refuse(h, regs, {kind = kind if kind != .None else .Wrong_Kind, at = lo}, hi)
	}
	if h.sink == nil {
		return refuse(h, regs, {kind = sub.entries[0].kind, at = lo}, hi)
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
	if h.first.kind == .None {
		x := sub.entries[0]
		text, _ := x.operand.(string)
		full := make([dynamic]core.Step, context.temp_allocator)
		append(&full, ..member)
		append(&full, ..x.path)
		h.first = refusal_at(x.kind, full[:], text, lo)
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

// Reads the text `lo..hi` of the value at `dest` by the record its `.Before` keeps, then judges it by `judge`.
@(private)
judged_value :: proc(h: ^Check, regs: core.Hook_Regs, m: ^Meta, dest: uintptr, lo, hi: u64) -> (core.Hook_Regs, core.Action) {
	text := h.src[lo:hi]
	// What the read and the judge take of the temporary allocator is given back, unless the load or sink keeps it there.
	keep := context.allocator == context.temp_allocator || h.sink != nil && h.sink.entries.allocator == context.temp_allocator
	guard := runtime.default_temp_allocator_temp_begin()
	defer if !keep {
		runtime.default_temp_allocator_temp_end(guard)
	}
	// The kept record read as the root of a plan, at the value's own address. A read's root names the record after its own.
	root := [2]Field{m.before.field, {}}
	root[0].offset = 0
	view := h.plan^
	view.root, view.type = &root[1], m.type
	sub := Sink{max_errors = h.sink.max_errors if h.sink != nil else 1}
	sub.entries.allocator = context.temp_allocator
	dups := core.Duplicates.First if h.first_key else .Last
	if check_text(text, rawptr(dest), m.type, &view, {dups = dups, sink = &sub}, context.allocator) != nil {
		return carry_entries(h, regs, &sub, lo, hi)
	}
	return judge(h, regs, m.before.judge, text, lo, hi)
}

// Judges `text`, the value `lo..hi` read with no refusal, by the check plan `plan`, nil for none, and reports what it fails
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
