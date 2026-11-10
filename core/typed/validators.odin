package typed

import "base:runtime"
import "core:strings"
import core ".."

// A procedure of the model's user, reached through `call`, which judges the value at `value` and reports what is wrong
// with it. The same judgment runs at the close of a struct in a load and in `validate`, so both give the same entries.
Validator :: struct {
	call: proc(value, fn: rawptr, r: ^Report),
	fn:   rawptr,
}

// A member's validator: `member` is the member's place among its struct's members, `offset` its place in the struct.
After :: struct {
	member: i32,
	name:   string,
	offset: uintptr,
	v:      Validator,
}

// What a validator found. A failure names the value it judges, or with `fail_at` a member of it.
Report :: struct {
	failures: [dynamic]Failure,
}

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
Verdict :: struct {
	member:  string,
	failure: Failure,
}

// Runs the validators of the struct of `sm` that is at `base`, whose path from the root is `path`. `entries` holds what
// this read or visit has reported. A member's validator runs when `seen` says the member was read and nothing under it
// failed, and the struct's own when no member failed. Each failure is appended to `out`.
judge_struct :: proc(sm: ^Struct_Model, base: uintptr, path: []core.Step, entries: []core.Error_Entry, seen: []bool, out: ^[dynamic]Verdict) {
	r := Report{make([dynamic]Failure, context.temp_allocator)}
	for a, k in sm.afters {
		if !seen[k] || failed_under(entries, path, a.name) {
			continue
		}
		clear(&r.failures)
		a.v.call(rawptr(base + a.offset), a.v.fn, &r)
		for x in r.failures {
			append(out, Verdict{a.name, x})
		}
	}
	if len(sm.checks) == 0 || len(out) > 0 || failed_under(entries, path, "") {
		return
	}
	for c in sm.checks {
		clear(&r.failures)
		c.call(rawptr(base), c.fn, &r)
		for x in r.failures {
			append(out, Verdict{"", x})
		}
	}
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
			if !same_step(p[i], s) {
				return false
			}
		}
		if len(p) > len(path) && (name == "" || same_step(p[len(path)], core.Name(name))) {
			return true
		}
	}
	return false
}

@(private)
same_step :: proc(a, b: core.Step) -> bool {
	switch x in a {
	case core.Name:
		y, ok := b.(core.Name)
		return ok && x == y
	case core.Index:
		y, ok := b.(core.Index)
		return ok && x == y
	case core.All, core.Slice, core.Descend, core.Index_Or_Name:
		return false
	}
	return false
}

// The steps of a verdict's path under the struct at `path`: its member, then the member of that value `fail_at` named.
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
refusal_at :: proc(kind: core.Typed_Error_Kind, steps: []core.Step, message: string, at: u64) -> core.Typed_Refusal {
	e := core.Typed_Refusal{kind = kind, at = at}
	e.want.text = message
	#reverse for s in steps {
		path_add(&e, s)
	}
	path_close(&e)
	return e
}

// Reports `v`, found at the close of a struct at `path`, to the read `h` as a `.Custom` refusal at byte `at`.
@(cold, private)
report_verdict :: proc(h: ^Reader, path: []core.Step, v: Verdict, at: u64) {
	steps := verdict_path(path, v, context.temp_allocator)
	e := refusal_at(.Custom, steps, v.failure.message, at)
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
	context.allocator = c.entries.allocator
	entry := core.Error_Entry{kind = .Custom, start = at, end = at, record = c.record}
	if v.failure.message != "" {
		entry.operand = strings.clone(v.failure.message)
	}
	if !sink_entry(c, entry, steps, nil, false) {
		c.truncated = true
	}
}
