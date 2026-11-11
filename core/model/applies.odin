package model

import "base:runtime"
import "core:slice"
import "core:strings"
import core ".."
import rules "../rules"
import typed "../typed"

// A rule on every value of `type` that one of JSON Schema's applicators states, beside what the type reads. Its operands
// are types, whose models judge: a value passes an operand when it would load as that type. A load reads the value and
// then judges its text by these rules, and `schema` writes them as their keywords. `validate` does not judge them. An
// operand whose rules reach back to itself through operands is refused by `compile` as `.Unsupported`, and
// so is any of them in a format that holds no value alone, a table's.
Applies_Rule :: struct {
	type:    typeid,
	applies: Applies,
}

Applies :: union {
	Contains,
	Conditional,
	Not,
	Pattern,
	Names,
	Dependent,
}

// A list holds between `min` (1 when nil) and `max` elements that load as `of`: `contains`, `minContains`, `maxContains`.
Contains :: struct {
	of:       typeid,
	min, max: Maybe(u64),
}

// A value that loads as `test` loads as `then`, and one that does not as `other`, nil for no rule: `if`, `then`, `else`.
Conditional :: struct {
	test, then, other: typeid,
}

// A value does not load as `of`: `not`.
Not :: struct {
	of: typeid,
}

// Each member whose name the ECMA-262 pattern `expression` matches loads as `of`: `patternProperties`.
Pattern :: struct {
	expression: string,
	of:         typeid,
}

// Each member's name, as a string, loads as `of`: `propertyNames`.
Names :: struct {
	of: typeid,
}

// An object with the member `name` has the members `requires` and loads as `of`, nil for no rule: `dependentRequired`
// and `dependentSchemas`.
Dependent :: struct {
	name:     string,
	requires: []string,
	of:       typeid,
}

// Adds an applicator to the rules of `rule.type`, beside those added before. The registry keeps copies of its texts.
register_applies :: proc(reg: ^Registry, rule: Applies_Rule) -> runtime.Allocator_Error {
	rule := rule
	rule.applies = applies_clone(rule.applies, context.allocator) or_return
	if _, err := append(&reg.applies, rule); err != nil {
		applies_destroy(rule.applies, context.allocator)
		return err
	}
	return nil
}

// `a` with copies of its texts from `allocator`.
@(private)
applies_clone :: proc(a: Applies, allocator: runtime.Allocator) -> (out: Applies, err: runtime.Allocator_Error) {
	context.allocator = allocator
	out = a
	#partial switch &x in out {
	case Pattern:
		x.expression = strings.clone(x.expression) or_return
	case Dependent:
		names := make([]string, len(x.requires)) or_return
		for &n, i in names {
			if n, err = strings.clone(x.requires[i]); err != nil {
				break
			}
		}
		x.requires = names
		if err == nil {
			x.name, err = strings.clone(x.name)
		}
		if err != nil {
			applies_destroy(out, allocator)
		}
	}
	return
}

@(private)
applies_destroy :: proc(a: Applies, allocator: runtime.Allocator) {
	context.allocator = allocator
	#partial switch x in a {
	case Pattern:
		delete(x.expression)
	case Dependent:
		delete(x.name)
		for n in x.requires {
			delete(n)
		}
		delete(x.requires)
	}
}

// What a model judges past its read: the types that applicators, `unique` or a `.One_Match` union judge, each with the
// check plan that judges its values' text, and the plans of their operands, which the descriptions borrow names from.
@(private)
Applied :: struct {
	rules:    []Applies_Rule, // copies of the registry's
	unions:   []typeid, // the `.One_Match` unions
	judged:   [dynamic]^Judged,
	operands: [dynamic]Operand,
}

@(private)
Judged :: struct {
	type:   typeid,
	unique: bool,
	d:      rules.Description,
	plan:   typed.Plan,
}

@(private)
Operand :: struct {
	type: typeid,
	plan: ^typed.Plan,
}

// The judging of the model whose plan is `whole`, nil when no value of it is judged past its read.
@(private)
judging_of :: proc(reg: ^Registry, whole: ^typed.Plan, reads: ^typed.Format_Reads, allocator: runtime.Allocator, layout: Maybe(core.As), hooks: []typed.Type_Hook) -> (j: ^Applied, err: core.Error) {
	if reg == nil {
		return
	}
	context.allocator = allocator
	unions := make([dynamic]typeid, context.temp_allocator)
	for x in reg.unions {
		if x.mode == .One_Match {
			append(&unions, x.type)
		}
	}
	probe := Applied{rules = reg.applies[:], unions = unions[:]}
	keys := judged_keys(&probe, whole, context.temp_allocator)
	if len(keys) == 0 {
		return
	}
	j = new(Applied) or_return
	j.unions = slice.clone(unions[:]) or_return
	j.judged.allocator, j.operands.allocator = allocator, allocator
	// The model keeps its rules past the registry, which `schema` reads.
	j.rules = make([]Applies_Rule, len(reg.applies)) or_return
	for x, i in reg.applies {
		j.rules[i].type = x.type
		cloned: runtime.Allocator_Error
		if j.rules[i].applies, cloned = applies_clone(x.applies, allocator); cloned != nil {
			judging_destroy(j)
			return nil, cloned
		}
	}
	if err = operand_plans(j, keys, reg, reads, allocator, layout, hooks); err != nil {
		judging_destroy(j)
		return nil, err
	}
	for k in keys {
		x := new(Judged) or_return
		append(&j.judged, x) or_return
		x.type, x.unique = k.type, k.unique
		if err = fragment(j, x, allocator); err != nil {
			break
		}
		x.plan, err = typed.plan_of(&x.d, whole.as, reads, {checking = true}, allocator)
		if err != nil {
			break
		}
	}
	if err != nil {
		judging_destroy(j)
		j = nil
	}
	return
}

@(private)
Judged_Key :: struct {
	type:   typeid,
	unique: bool,
}

// The types of `plan`'s records that `j` judges, each with whether its rules say `unique`.
@(private)
judged_keys :: proc(j: ^Applied, plan: ^typed.Plan, allocator: runtime.Allocator) -> []Judged_Key {
	keys := make([dynamic]Judged_Key, allocator)
	for m in plan.meta {
		if m.type == nil {
			continue
		}
		k := Judged_Key{m.type, m.rule_set > 0 && plan.rule_sets[m.rule_set - 1].unique}
		if (k.unique || judges(j, m.type)) && !slice.contains(keys[:], k) {
			append(&keys, k)
		}
	}
	return keys[:]
}

// Whether `j` judges values of `type` by an applicator or as a `.One_Match` union.
@(private)
judges :: proc(j: ^Applied, type: typeid) -> bool {
	for x in j.rules {
		if x.type == type {
			return true
		}
	}
	return one_match(j, type)
}

@(private)
one_match :: proc(j: ^Applied, type: typeid) -> bool {
	return j != nil && slice.contains(j.unions, type)
}

// Fills `x.d` with the description its check judges by: a root of any value holding `x`'s applicators, its `unique`,
// and for a `.One_Match` union the `oneOf` of its arms.
@(private)
fragment :: proc(j: ^Applied, x: ^Judged, allocator: runtime.Allocator) -> core.Error {
	x.d.allocator = allocator
	x.d.names = make(map[rules.Node_Index]string)
	root := rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1}
	root.rules.unique = x.unique
	r := Reading{d = &x.d, judging = j}
	_, _ = append(&x.d.nodes, root)
	if one_match(j, x.type) {
		sub := Reading{plan = operand_of(j, x.type), d = &x.d}
		at := node_of(&sub, 0)
		arms := x.d.nodes[at].any_of
		delete(sub.nodes)
		delete(sub.shapes)
		r.failed ||= sub.failed
		root.one_of = slice.clone(arms)
	}
	applies_into(&r, &root, j.rules, x.type)
	x.d.nodes[0] = root
	switch {
	case r.deep:
		return core.error_of(core.Typed_Refusal{kind = .Unsupported, want = {x.type, "applies"}})
	case r.failed:
		return runtime.Allocator_Error.Out_Of_Memory
	}
	return nil
}

// The types an applicator names, nil where it names none.
@(private)
operand_types :: proc(a: Applies) -> [3]typeid {
	switch x in a {
	case Contains:
		return {x.of, nil, nil}
	case Conditional:
		return {x.test, x.then, x.other}
	case Not:
		return {x.of, nil, nil}
	case Pattern:
		return {x.of, nil, nil}
	case Names:
		return {x.of, nil, nil}
	case Dependent:
		return {x.of, nil, nil}
	}
	return {}
}

// Builds the plan of each operand the rules of `keys`' types name, and of their operands' judged types in turn, and of
// each `.One_Match` union of `keys`, whose arms its `oneOf` describes.
@(private)
operand_plans :: proc(j: ^Applied, keys: []Judged_Key, reg: ^Registry, reads: ^typed.Format_Reads, allocator: runtime.Allocator, layout: Maybe(core.As), hooks: []typed.Type_Hook) -> core.Error {
	pending := make([dynamic]typeid, context.temp_allocator)
	for k in keys {
		append(&pending, k.type)
	}
	for len(pending) > 0 {
		type := pop(&pending)
		wanted := make([dynamic]typeid, context.temp_allocator)
		if one_match(j, type) {
			append(&wanted, type)
		}
		for a in j.rules {
			if a.type == type {
				operands := operand_types(a.applies)
				append(&wanted, ..operands[:])
			}
		}
		for t in wanted {
			if t == nil || operand_of(j, t) != nil {
				continue
			}
			p := new(typed.Plan, allocator) or_return
			err: core.Error
			if p^, err = plan_of(reg, t, reads, allocator, nil, nil, layout, hooks); err != nil {
				free(p, allocator)
				return err
			}
			append(&j.operands, Operand{t, p}) or_return
			for k in judged_keys(j, p, context.temp_allocator) {
				append(&pending, k.type)
			}
		}
	}
	return nil
}

// The plan of operand type `t`, nil when no rule names it.
@(private)
operand_of :: proc(j: ^Applied, t: typeid) -> ^typed.Plan {
	for x in j.operands {
		if x.type == t {
			return x.plan
		}
	}
	return nil
}

// The node of operand type `t` in `r`'s description.
@(private)
operand_node :: proc(r: ^Reading, t: typeid) -> Maybe(rules.Node_Index) {
	if t == nil {
		return nil
	}
	p := operand_of(r.judging, t)
	if p == nil || r.depth >= OPERAND_DEPTH {
		r.failed = true
		r.deep ||= p != nil
		return nil
	}
	sub := Reading{plan = p, d = r.d, direction = r.direction, judging = r.judging, depth = r.depth + 1}
	at := node_of(&sub, 0)
	delete(sub.nodes)
	delete(sub.shapes)
	r.failed ||= sub.failed
	r.deep ||= sub.deep
	return at
}

// How deep operands nest in operands, each described anew, which a rule that names its own type would pass.
@(private)
OPERAND_DEPTH :: 16

// Adds to `n` the applicators `all` holds of `type`, their operands described into `r`'s description. A list's or an
// object's applicators go on its block, which every node of the type shares, so they are set once.
@(private)
applies_into :: proc(r: ^Reading, n: ^rules.Node, all: []Applies_Rule, type: typeid) {
	patterns := make([dynamic]rules.Pattern, r.d.allocator)
	dependents := make([dynamic]rules.Dependent, r.d.allocator)
	contains: Maybe(Contains)
	names: Maybe(rules.Node_Index)
	for a in all {
		if a.type != type {
			continue
		}
		switch x in a.applies {
		case Contains:
			contains = x
		case Conditional:
			n.cond = {operand_node(r, x.test), operand_node(r, x.then), operand_node(r, x.other)}
		case Not:
			n.not = operand_node(r, x.of)
		case Pattern:
			append(&patterns, rules.Pattern{x.expression, operand_node(r, x.of).? or_else rules.NONE})
		case Names:
			names = operand_node(r, x.of)
		case Dependent:
			required, _ := slice.clone(x.requires, r.d.allocator)
			append(&dependents, rules.Dependent{x.name, required, operand_node(r, x.of)})
		}
	}
	if c, has := contains.?; has {
		if n.array < 0 {
			n.array = i32(add(r, &r.d.arrays, rules.Array{items = rules.NONE}))
		}
		a := &r.d.arrays[n.array]
		a.contains, a.min_contains, a.max_contains = operand_node(r, c.of), c.min, c.max
	}
	if len(patterns) == 0 && len(dependents) == 0 && names == nil {
		delete(patterns)
		delete(dependents)
		return
	}
	if n.object < 0 {
		n.object = i32(add(r, &r.d.objects, rules.Object{additional = rules.NONE, keys = rules.NONE}))
	}
	o := &r.d.objects[n.object]
	if o.patterns == nil && o.dependents == nil {
		o.patterns, o.dependents = patterns[:], dependents[:]
		o.keys = names.? or_else o.keys
	} else {
		delete(patterns)
		for x in dependents {
			delete(x.required, r.d.allocator)
		}
		delete(dependents)
	}
}

// The check plan that judges values of `type`, of `unique` rules when they say so, after a load read them.
@(private)
judge_plan :: proc(h: ^typed.Model_Rules, type: typeid, unique: bool) -> ^typed.Plan {
	j := (^Compiling)(h).judging
	for x in j.judged {
		if x.type == type && x.unique == unique {
			return &x.plan
		}
	}
	return nil
}

@(private)
judging_destroy :: proc(j: ^Applied) {
	if j == nil {
		return
	}
	allocator := j.judged.allocator
	for x in j.judged {
		typed.plan_destroy(&x.plan)
		rules.description_destroy(&x.d)
		free(x, allocator)
	}
	for x in j.operands {
		typed.plan_destroy(x.plan)
		free(x.plan, allocator)
	}
	for x in j.rules {
		applies_destroy(x.applies, allocator)
	}
	delete(j.rules, allocator)
	delete(j.judged)
	delete(j.operands)
	delete(j.unions, allocator)
	free(j, allocator)
}
