package typed

import "base:runtime"
import "core:mem"
import "core:strings"
import core ".."

// A procedure of the model's user, reached through `call`, which judges the value at `value` and reports what is wrong
// with it. The same judgment runs at the close of a struct in a load and in `validate`, so both give the same entries.
Validator :: struct {
	call: proc(value, fn: rawptr, r: ^Report),
	fn:   rawptr,
}

// A member's validator: `member` is the member's place among its struct's members, `offset` its place in the struct and
// `size` its size, 0 for a required member, which a value always has.
@(private)
After :: struct {
	member: i32,
	name:   string,
	offset: uintptr,
	size:   int,
	v:      Validator,
}

// What a validator found. A failure names the value it judges, or with `fail_at` a member of it.
Report :: struct {
	failures: [dynamic]Failure,
}

@(private)
Failure :: struct {
	field:   string,
	message: string,
}

// Fails the value the validator judges with `message`, which has to outlive the load or validate.
fail :: proc(r: ^Report, message: string) {
	fail_at(r, "", message)
}

// Fails member `field` of the value the validator judges.
fail_at :: proc(r: ^Report, field, message: string) {
	append(&r.failures, Failure{field, message})
}

// A failure with the member that holds the value it judges, "" for a struct's own validator.
@(private)
Verdict :: struct {
	member:  string,
	failure: Failure,
}

// Runs the validators of the struct of `sm` at `base`, whose path from the root is `path`, and reports each failure at
// byte `at` to `first`, when it holds none, and to `sink`, whose entries from `floor` are what this read or visit
// reported. A member's validator runs when `seen` says the member was read and nothing under it failed, and under
// `whole` the struct's own when no member failed. Returns whether one failed and whether the sink takes more.
@(private)
close_struct :: proc(sm: ^Struct_Model, base: uintptr, path: []core.Step, seen: []bool, first: ^core.Typed_Refusal, sink: ^Sink, floor: int, at: u64, whole := true) -> (failed, more: bool) {
	entries := sink.entries[floor:] if sink != nil else nil
	verdicts := make([dynamic]Verdict, context.temp_allocator)
	r := Report{make([dynamic]Failure, context.temp_allocator)}
	for a, k in sm.afters {
		if !seen[k] || failed_under(entries, path, a.name) {
			continue
		}
		clear(&r.failures)
		a.v.call(rawptr(base + a.offset), a.v.fn, &r)
		for x in r.failures {
			append(&verdicts, Verdict{a.name, x})
		}
	}
	if whole && len(verdicts) == 0 && !failed_under(entries, path, "") {
		for c in sm.checks {
			clear(&r.failures)
			c.call(rawptr(base), c.fn, &r)
			for x in r.failures {
				append(&verdicts, Verdict{"", x})
			}
		}
	}
	more = sink != nil
	for v in verdicts {
		more = report_verdict(first, sink, path, v, at)
		if !more {
			break
		}
	}
	return len(verdicts) > 0, more
}

// The close of a struct a visit of a value reaches at its record `end` past the members, as a load closes it. A member
// counts as read when it is required, when the struct's `Fields_Set` holds it, or with no set when it is not zero.
// Returns whether the visit goes on.
visit_closed :: proc(plan: ^Plan, end: ^Field, base: uintptr, path: []core.Step, first: ^core.Typed_Refusal, sink: ^Sink, floor: int) -> bool {
	sm := plan.meta[end.meta].model
	if len(sm.afters) == 0 && len(sm.checks) == 0 {
		return true
	}
	seen := make([]bool, len(sm.afters), context.temp_allocator)
	for a, k in sm.afters {
		switch {
		case a.size == 0:
			seen[k] = true
		case sm.fields_set != 0:
			set := (^Fields_Set)(base + uintptr(sm.fields_set - 1))
			seen[k] = set.bits[a.member / 64] >> uint(a.member % 64) & 1 != 0
		case:
			seen[k] = !mem.check_zero(([^]u8)(rawptr(base + a.offset))[:a.size])
		}
	}
	_, more := close_struct(sm, base, path, seen, first, sink, floor, 0)
	return more
}

// Whether an entry lies under `path`, under its member `name` when that is not "". The entries of a subtree are the last
// ones reported, so the search ends at the first entry outside it.
@(private)
failed_under :: proc(entries: []core.Error_Entry, path: []core.Step, name: string) -> bool {
	#reverse for e in entries {
		p := e.path
		if len(p) < len(path) {
			break
		}
		for s, i in path {
			if p[i] != s {
				return false
			}
		}
		if len(p) > len(path) && (name == "" || p[len(path)] == core.Name(name)) {
			return true
		}
	}
	return false
}

// The steps of a verdict's path under the struct at `path`: its member, then the member of that value `fail_at` named.
@(private)
verdict_path :: proc(path: []core.Step, v: Verdict, allocator: runtime.Allocator) -> []core.Step {
	steps := make([dynamic]core.Step, 0, len(path) + 2, allocator)
	append(&steps, ..path)
	if v.member != "" {
		append(&steps, core.Name(v.member))
	}
	if v.failure.field != "" {
		append(&steps, core.Name(v.failure.field))
	}
	return steps[:]
}

// The refusal of `kind` at byte `at` whose path is `steps`, outermost first, and whose wanted text is `message`.
@(private)
refusal_at :: proc(kind: core.Typed_Error_Kind, steps: []core.Step, message: string, at: u64) -> core.Typed_Refusal {
	e := core.Typed_Refusal{kind = kind, at = at}
	e.want.text = message
	#reverse for s in steps {
		path_add(&e, s)
	}
	path_close(&e)
	return e
}

// Reports `v`, found at the close of a struct at `path`, as a `.Custom` refusal at byte `at`: to `first`, when it holds
// none, and to `sink` as an entry. Returns whether the sink takes more.
@(private)
report_verdict :: proc(first: ^core.Typed_Refusal, sink: ^Sink, path: []core.Step, v: Verdict, at: u64) -> bool {
	steps := verdict_path(path, v, context.temp_allocator)
	if first.kind == .None {
		first^ = refusal_at(.Custom, steps, v.failure.message, at)
	}
	if sink == nil || !sink_room(sink, context.allocator) {
		return false
	}
	context.allocator = sink.entries.allocator
	entry := core.Error_Entry{kind = .Custom, start = at, end = at, record = sink.record}
	if v.failure.message != "" {
		entry.operand = strings.clone(v.failure.message)
	}
	if !sink_entry(sink, entry, steps, nil, false) {
		sink.truncated = true
		return false
	}
	return true
}
