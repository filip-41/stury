package schema

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import core "../"
import "../rules"
import "../typed"
import "../write"

// Whether one description takes every value another takes. A `Yes` is a proof over the descriptions' structure, a `No`
// carries a value the first takes and the second refuses that the check of both confirmed, and anything between is an
// `Unknown` that names the keyword the proof stopped at.

Verdict :: enum u8 {
	Yes,
	No,
	Unknown,
}

// The answer for a pair of descriptions in one direction: does the second take every value the first takes?
Inclusion :: struct {
	verdict: Verdict,
	// For a `No`: a value the first takes and the second refuses, as text of the compared format.
	witness: string,
	// For an `Unknown`: the keyword of the facet the proof could not decide.
	reason:  string,
}

// What a change does to the values a description takes.
Effect :: enum u8 {
	None,
	Widens,
	Narrows,
	Both,
	Unknown,
}

// One difference between the descriptions at a place in a value: `path` names the place by member names and `All` for
// every element, `keyword` the part of the schema that differs, and `old` and `new` its two values, nil for none: a
// number for a bound or a count, a bool for `uniqueItems`, a `const` or an `enum` member as the schema holds it, and
// otherwise a word for the part, as `restricted` or `required`. The values of a `const` and an `enum` are the
// descriptions', and the rest the comparison's.
Change :: struct {
	path:    []core.Step,
	keyword: string,
	old:     Maybe(core.Value),
	new:     Maybe(core.Value),
	effect:  Effect,
}

Compare_Options :: struct {
	// The format a witness is written in and a check reads.
	as:            core.As,
	// The typed reads of `as`, as `bind` takes them.
	reads:         ^typed.Format_Reads,
	// Whether `format` asserts, as it does in a compile with the same option.
	format_assert: bool,
}

// `old_in_new` says whether the new description takes everything the old one takes, which keeps every reader of the new
// schema working on data written under the old one. `new_in_old` is the reverse.
Comparison :: struct {
	old_in_new: Inclusion,
	new_in_old: Inclusion,
	changes:    []Change,
	// Set when the walk for changes or the proof reached its bound, so the list may be missing some, and an effect told
	// after the proof ran out is `Unknown`.
	truncated:  bool,
	arena:      virtual.Arena,
}

comparison_destroy :: proc(c: ^Comparison) {
	virtual.arena_destroy(&c.arena)
	c^ = {}
}

// The checks one side binds, each of which holds a copy of the whole description.
@(private)
MAX_JUDGES :: 64

// A description with the checks bound to it, one per node used as a root.
@(private)
Side :: struct {
	d:      ^rules.Description,
	c:      Compiled,
	as:     core.As,
	reads:  ^typed.Format_Reads,
	judges: map[rules.Node_Index]^Bound,
}

// Compares `old` and `new`. Both are borrowed for the call: `format` assertion follows the options for the call and is
// restored after it. A check of a node temporarily makes it the root.
compare :: proc(old, new: ^rules.Description, opts := Compare_Options{}) -> (r: Comparison, err: runtime.Allocator_Error) {
	virtual.arena_init_growing(&r.arena) or_return
	scratch: virtual.Arena
	if err = virtual.arena_init_growing(&scratch); err != nil {
		virtual.arena_destroy(&r.arena)
		return {}, err
	}
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	old_on, new_on := asserting(old, opts.format_assert), asserting(new, opts.format_assert)
	defer asserted_restore(old, old_on)
	defer asserted_restore(new, new_on)
	a := Side{d = old, c = {description = old}, as = opts.as, reads = opts.reads}
	b := Side{d = new, c = {description = new}, as = opts.as, reads = opts.reads}
	defer side_destroy(&a)
	defer side_destroy(&b)
	arena := virtual.arena_allocator(&r.arena)
	r.old_in_new = inclusion(&a, &b, arena)
	r.new_in_old = inclusion(&b, &a, arena)
	r.changes, r.truncated = changes_of(&a, &b, arena)
	return
}

@(private = "file")
side_destroy :: proc(s: ^Side) {
	for _, j in s.judges {
		if j != nil {
			unbind(j)
			free(j)
		}
	}
	delete(s.judges)
}

// Whether `from` takes only values `to` takes.
@(private = "file")
inclusion :: proc(from, to: ^Side, allocator: mem.Allocator) -> (in_: Inclusion) {
	p := Prover {
		from    = from,
		to      = to,
		running = make(map[string]struct{}, context.temp_allocator),
	}
	if included(&p, {from.d.root}, {to.d.root}, 0) && !p.exhausted {
		return {verdict = .Yes}
	}
	text, found, searched_out := refute(from, to)
	switch {
	case found:        return {verdict = .No, witness = strings.clone(text, allocator)}
	case searched_out: return {verdict = .Unknown, reason = p.why if p.why != "" else "search"}
	}
	return {verdict = .Unknown, reason = p.why}
}

// The check bound to `n` as a root of `s`, nil where the description cannot be bound.
@(private)
judge_of :: proc(s: ^Side, n: rules.Node_Index) -> ^Bound {
	if j, found := s.judges[n]; found {
		return j
	}
	// A node judged as a root has the dynamic scope of its own resource, not the one it stands in.
	if (n != s.d.root && len(s.d.anchors) > 0) || len(s.judges) >= MAX_JUDGES {
		return nil
	}
	root := s.d.root
	s.d.root = n
	defer s.d.root = root
	j := new(Bound)
	err: core.Error
	j^, err = bind(&s.c, {s.reads, s.as})
	if err != nil {
		free(j)
		j = nil
	}
	s.judges[n] = j
	return j
}

// Whether `text` passes every node of `nodes` of `s`. `known` is false when a node's check could not be built.
@(private)
accepts :: proc(s: ^Side, nodes: []rules.Node_Index, text: []u8) -> (taken, known: bool) {
	for n in nodes {
		j := judge_of(s, n)
		if j == nil {
			return false, false
		}
		if !valid(j, text) {
			return false, true
		}
	}
	return true, true
}

// The text of `v` in the format of `s`. A flat format writes an array of objects as the rows of a table.
@(private)
text_of :: proc(s: ^Side, v: core.Value) -> (text: []u8, ok: bool) {
	if s.as.readers != nil && s.as.readers.flat {
		bytes, refusal := written(v, s.as, {}, context.temp_allocator)
		return bytes, refusal.kind == .None
	}
	written, err := write.write_value(v, s.as, allocator = context.temp_allocator)
	return written, err == nil
}
