package schema

import "base:runtime"
import core "../"
import "../rules"
import "../typed"
import "../records"

// What a check of a root array's entries on the threads of a pool needs: the plan an entry is checked with, the path and
// keyword steps a check of the whole array puts before an entry's own, and the array's item counts, which the entries'
// number is judged by, with `counts`, the plan of the array that judges them alone over the arrays it is made from. The path
// is a placeholder for the entry's index.
@(private)
Elements :: struct {
	plan:   typed.Plan,
	counts: typed.Plan,
	arrays: [dynamic]rules.Array,
	outer:  typed.Outer,
	min:    u64,
	max:    Maybe(u64),
}

// The plan of the entries of `c`'s root when the root's rules are per entry: an array that takes `items` and counts, and
// no other rule of the array. Nil for any other root, which is checked in one pass.
@(private)
elements_of :: proc(c: ^Compiled, as: core.As, reads: ^typed.Format_Reads, allocator: runtime.Allocator) -> ^Elements {
	d := c.description
	node, hops := d.root, 0
	for node != rules.NONE && rules.ref_only(&d.nodes[node]) && hops <= len(d.nodes) {
		node = d.nodes[node].ref.?
		hops += 1
	}
	if node == rules.NONE || hops > len(d.nodes) {
		return nil
	}
	n := d.nodes[node]
	counts := n.rules
	counts.min_items, counts.max_items = 0, nil
	if .Array not_in n.kinds || n.array < 0 || counts != {} || n.has_enum || n.const_of != nil || len(n.any_of) + len(n.all_of) + len(n.one_of) > 0 || n.not != nil || n.cond != {} || n.ref != nil || n.dynamic_ref != nil || n.unevaluated_items != nil || n.unevaluated_properties != nil {
		return nil
	}
	a := d.arrays[n.array]
	if len(a.prefix) > 0 || a.contains != nil || a.min_contains != nil || a.max_contains != nil || a.items == rules.NONE {
		return nil
	}
	view := d^
	view.root = a.items
	e, made := new(Elements, allocator)
	if made != nil {
		return nil
	}
	planned: core.Error
	e.plan, planned = typed.plan_of(&view, as, reads, {checking = true}, allocator)
	if planned != nil || e.plan.check == nil {
		if planned == nil {
			typed.plan_destroy(&e.plan)
		}
		free(e, allocator)
		return nil
	}
	e.min, e.max = n.rules.min_items, n.rules.max_items
	if e.min > 0 || e.max != nil {
		// The array with its entries passed, whose check says only that its count fails.
		e.arrays.allocator = allocator
		if _, grown := append(&e.arrays, ..d.arrays[:]); grown != nil {
			elements_destroy(e, allocator)
			return nil
		}
		e.arrays[n.array].items = rules.NONE
		counted := d^
		counted.arrays = e.arrays
		counts, counted_err := typed.plan_of(&counted, as, reads, {checking = true}, allocator)
		if counted_err != nil {
			elements_destroy(e, allocator)
			return nil
		}
		e.counts = counts
	}
	path, pathed := make([]core.Step, 1, allocator)
	words, worded := make([]core.Step, hops + 1, allocator)
	if pathed != nil || worded != nil {
		delete(path, allocator)
		delete(words, allocator)
		elements_destroy(e, allocator)
		return nil
	}
	path[0] = core.Index(0)
	for i in 0 ..< hops {
		words[i] = core.Name("$ref")
	}
	words[hops] = core.Name("items")
	e.outer = {path, words}
	return e
}

@(private)
elements_destroy :: proc(e: ^Elements, allocator: runtime.Allocator) {
	if e != nil {
		typed.plan_destroy(&e.plan)
		typed.plan_destroy(&e.counts)
		delete(e.arrays)
		delete(e.outer.path, allocator)
		delete(e.outer.words, allocator)
		free(e, allocator)
	}
}

// Checks `src` as one text on the threads of `runner` when it is an array whose entries are checked alone. False when it is
// not, which includes an object that holds the array, or when the answer is the one-pass check's to give: a text that does
// not parse. A failing entry's path starts with its index, as the one pass has it.
@(private)
check_elements :: proc(b: ^Bound, src: []u8, sink: ^typed.Sink, runner: ^core.Runner) -> (err: core.Error, done: bool) {
	e := b.elements
	whole, at, cut := records.entries_of(src, b.plan.as)
	if !cut || at != 0 {
		return
	}
	mark := typed.sink_mark(sink)
	count, failure, fatal, failed := records.check_each(src, whole, .Entries, &e.plan, &e.outer, sink, runner, at)
	if fatal.kind != .None {
		typed.sink_restore(sink, mark)
		return
	}
	// The entries took the placeholder of their index, which their record is.
	if sink != nil {
		for &entry in sink.entries[mark.entries:] {
			entry.path[0], entry.record = core.Index(entry.record), 0
		}
	}
	if failure.kind != .None {
		if int(failure.n_steps) < core.MAX_ERROR_STEPS {
			copy(failure.steps[1:], failure.steps[:failure.n_steps])
			failure.steps[0] = core.Index(failed)
			failure.n_steps += 1
		} else {
			failure.truncated = true
		}
	}
	most, limited := e.max.?
	if (u64(count) < e.min || limited && u64(count) > most) && (sink != nil || failure.kind == .None) {
		// The count is the array's own failure, after those of its entries.
		counted := outcome(core.error_of(check_text(&e.counts, src, sink)), sink)
		if failure.kind == .None || sink.fatal.kind != .None {
			return counted, true
		}
	}
	return core.error_of(failure), true
}

// Checks each record of `src`, NDJSON or RFC 7464 under `framing`, against the schema `b` is bound to, on the threads of
// `runner` when it is given. Every failure goes to `sink` with its record's index in `record`, up to its `max_errors`,
// and the result is the fault that ends the records when there is one, else the first failure. With no sink the check
// stops at the first failure. The result's first value is the number of records read. A sink with an allocator of its own is checked on this thread.
check_records :: proc(b: ^Bound, src: []u8, framing := core.Framing.Lines, sink: ^typed.Sink = nil, runner: ^core.Runner = nil) -> (count: i64, err: core.Error) {
	if b.plan.check == nil {
		return 0, core.error_of(core.Typed_Error{kind = .Plan_Mismatch})
	}
	failure, fatal: core.Typed_Error
	count, failure, fatal, _ = records.check_each(src, b.plan.as, framing, &b.plan, nil, sink, runner)
	return count, core.error_of(fatal if fatal.kind != .None else failure)
}
