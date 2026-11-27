// Schema comparison, subset/equivalence proving, breaking-change classification, and counterexample witnesses.
// Zero `core:mem/virtual`, zero `context.temp_allocator`, WASM-clean.
package schema

import "base:runtime"
import "core:mem"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"

Verdict :: enum u8 { Yes, No, Unknown }

Inclusion :: struct {
	verdict: Verdict,
	witness: string,
	reason:  string,
}

Effect :: enum u8 { None, Widens, Narrows, Both, Unknown }

Change :: struct {
	path:    []tape.Step,
	keyword: string,
	old:     Maybe(rules.Value),
	new:     Maybe(rules.Value),
	effect:  Effect,
}

Compare_Options :: struct {
	format_assert: bool,
}

Comparison :: struct {
	old_in_new:  Inclusion,
	new_in_old:  Inclusion,
	changes:     []Change,
	truncated:   bool,
	arena:       mem.Dynamic_Arena,
	arena_ready: bool,
}

comparison_destroy :: proc(c: ^Comparison) {
	if c == nil {
		return
	}
	if c.arena_ready {
		mem.dynamic_arena_destroy(&c.arena)
	}
	c^ = {}
}

@(private)
MAX_JUDGES :: 64

@(private)
Side :: struct {
	d:         ^rules.Description,
	judges:    map[rules.Node_Index]^check.Plan,
	allocator: runtime.Allocator,
}

@(require_results)
compare :: proc(old, new: ^rules.Description, opts := Compare_Options{}, allocator := context.allocator) -> (r: Comparison, err: runtime.Allocator_Error) {
	if old == nil || new == nil {
		return {}, .None
	}
	mem.dynamic_arena_init(&r.arena, allocator, allocator)
	r.arena_ready = true
	out_alloc := mem.dynamic_arena_allocator(&r.arena)

	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)

	old_on := asserting(old, opts.format_assert, scratch)
	new_on := asserting(new, opts.format_assert, scratch)

	a := Side{d = &old_on, judges = make(map[rules.Node_Index]^check.Plan, 8, allocator), allocator = allocator}
	b := Side{d = &new_on, judges = make(map[rules.Node_Index]^check.Plan, 8, allocator), allocator = allocator}
	defer side_destroy(&a)
	defer side_destroy(&b)

	r.old_in_new = inclusion(&a, &b, out_alloc, scratch, allocator)
	r.new_in_old = inclusion(&b, &a, out_alloc, scratch, allocator)
	r.changes, r.truncated = changes_of(&a, &b, out_alloc, scratch, allocator)
	return r, .None
}

@(private = "file")
side_destroy :: proc(s: ^Side) {
	for _, j in s.judges {
		if j != nil {
			check.plan_destroy(j)
			free(j, s.allocator)
		}
	}
	delete(s.judges)
}

@(private = "file")
inclusion :: proc(from, to: ^Side, out_alloc, scratch, backing: runtime.Allocator) -> Inclusion {
	p := prover_of(from, to, scratch, backing)
	defer prover_destroy(&p)
	if included(&p, {from.d.root}, {to.d.root}, 0) && !p.exhausted {
		return {verdict = .Yes}
	}
	text, found, searched_out := refute(from, to, p.foci[:], scratch, backing)
	if found {
		return {verdict = .No, witness = strings.clone(text, out_alloc)}
	}
	return {verdict = .Unknown, reason = p.why if p.why != "" else ("search" if searched_out else "")}
}

@(private)
judge_of :: proc(s: ^Side, n: rules.Node_Index) -> ^check.Plan {
	if j, found := s.judges[n]; found {
		return j
	}
	if (n != s.d.root && len(s.d.anchors) > 0) || len(s.judges) >= MAX_JUDGES {
		return nil
	}
	root := s.d.root
	s.d.root = n
	defer s.d.root = root
	j, aerr := new(check.Plan, s.allocator)
	if aerr != nil {
		return nil
	}
	plan, cerr := check.compile(s.d, s.allocator)
	if cerr.kind != .None {
		free(j, s.allocator)
		s.judges[n] = nil
		return nil
	}
	j^ = plan
	s.judges[n] = j
	return j
}

@(private)
accepts_doc :: proc(s: ^Side, nodes: []rules.Node_Index, doc: ^tape.Document, scratch: runtime.Allocator) -> (bool, bool) {
	for n in nodes {
		j := judge_of(s, n)
		if j == nil {
			return false, false
		}
		res := check.check_document(doc, j, {}, nil, scratch)
		ok := res.valid
		check.result_destroy(&res)
		if !ok {
			return false, true
		}
	}
	return true, true
}

@(private)
accepts_value :: proc(s: ^Side, nodes: []rules.Node_Index, v: rules.Value, scratch: runtime.Allocator) -> (bool, bool) {
	tt: write.Token_Tape
	doc, ok := value_to_tape(v, &tt, scratch)
	if !ok {
		return false, false
	}
	defer write.token_tape_drop(&tt)
	return accepts_doc(s, nodes, &doc, scratch)
}
