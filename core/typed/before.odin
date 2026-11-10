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
	rules: rules.Rules, // the member's, which the root of `plan` takes
	plan:  ^Plan, // reads the replacement as the member's type, which the model sets
	field: Field, // the member's record as it was before it became `.Before`, for a format that reads a cell by it
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
			e := core.Typed_Error{kind = .Custom, at = lo}
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

// Reads the member at `dest`, whose value is the text `lo..hi` of a format that builds values and writes them back, as its
// `before` rewrote it. A replacement the member's type or rules refuse is refused at the member, with the path it
// refused at under the member.
@(cold)
@(private)
before_value :: #force_no_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, m: ^Meta, dest: uintptr, lo, hi: u64) -> (core.Hook_Regs, core.Action) {
	context = h.ctx
	b := m.before
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
