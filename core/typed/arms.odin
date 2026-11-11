package typed

import "base:runtime"
import regex "../regex"
import core ".."
import rules "../rules"
import build "../build"
import "core:mem"
import "core:slice"
import "core:strings"

// A held record judges its value by its arms, each a record of the plan that a run reads beside the check, fed the
// value's tokens as the check reads them. Its first arm is the record of its node without the arms, which judges the rest.
@(private)
Apply :: struct {
	kind:     Apply_Kind,
	judge:    Judge,
	// The arm's record, -1 for an arm that reads none or a `.Choice` arm, and the keyword steps to it from the held record.
	rec:      i32,
	site:     []core.Step,
	// The member name a `.Dependent` arm is keyed by or `choices` are picked by, or a `.Pattern`'s expression.
	name:     string,
	// A `.Pattern`'s compiled `^regex.Regex`.
	pattern:  rawptr,
	// The names an `.Additional` arm leaves to the named members' records.
	names:    []string,
	// The operands an `.Equal` arm takes, a `const` when `constant` says so, which may be containers, in the order of
	// their `core.hash` in `hashes`.
	values:   []core.Value,
	hashes:   []u64,
	constant: bool,
	// The elements a `.Contains` arm wants to pass.
	min, max: u64,
	// What the held record evaluates, which an `.Unevaluated_Members` or `.Unevaluated_Items` arm judges the rest past.
	eval:     ^Evaluates,
	// What a verdict judges the arm by in place of a run, nil for none.
	by:       ^Judging,
}

// How a verdict judges an arm: by a run of its record, by the names its object has, by the arm its object's first
// member picks among those it stands for, or, for an unevaluated arm whose record takes no value, as failing each member
// or element it judges.
@(private)
Judge :: enum u8 {
	Run,
	Presence,
	Choice,
	Never,
}

// What `Judge` reads: the members an object must have to pass the arm's record when that is all the record judges, or
// the arms a `.Choice` arm stands for, each an object record whose member `name` has a `const` or `enum` no other
// choice has, with the operands' enum keys in `rules.enum_sort` order and the choice each is one of in `picks`.
@(private)
Judging :: struct {
	present: []string,
	choices: []Apply,
	keys:    []string,
	picks:   []i32,
}

// `.All`, `.Any` and `.One` come first, the kinds a run may take a value over under.
@(private)
Apply_Kind :: enum u8 {
	All, // the value passes the record, whose failures it reports
	Any, // one arm of a run of them passes
	One, // exactly one arm of a run of them passes
	Not, // the value fails the record
	If, // picks the `.Then` that follows when the value passes, else the `.Else`
	Then,
	Else,
	Dependent, // an object with the member `name` passes the record
	Pattern, // each member whose name the pattern matches passes the record
	Additional, // each member no name of `names` and no pattern matches passes the record
	Contains, // between `min` and `max` of an array's elements pass the record
	Unique, // no two of an array's elements are equal
	Equal, // the value equals one of `values`
	Unevaluated_Members, // each member `eval` does not evaluate passes the record
	Unevaluated_Items, // each element `eval` does not evaluate passes the record
	Names, // each member's name, read as a string, passes the record
}

// Whether a use of `n` with `edge` judges by arms.
@(private)
holds :: proc(b: ^Builder, d: ^rules.Description, node: rules.Node_Index, edge: rules.Rules) -> bool {
	n := &d.nodes[node]
	if len(n.any_of) > 0 || len(n.all_of) > 0 || len(n.one_of) > 0 || n.not != nil || n.ref != nil || n.dynamic_ref != nil || n.rules.unique || edge.unique || arm_operands(n) {
		return true
	}
	if n.cond.test != nil && (n.cond.then != nil || n.cond.other != nil) || n.unevaluated_items != nil || n.unevaluated_properties != nil {
		return true
	}
	if n.object >= 0 && (len(d.objects[n.object].patterns) > 0 && n.object not_in b.inline || dependent_schemas(&d.objects[n.object]) || names_hold(b, d, &d.objects[n.object])) {
		return true
	}
	return n.array >= 0 && d.arrays[n.array].contains != nil
}

// Whether `o`'s `propertyNames` is a schema with arms, which an arm judges each name by, where a leaf judges the rest in
// the walk.
@(private)
names_hold :: proc(b: ^Builder, d: ^rules.Description, o: ^rules.Object) -> bool {
	keys, _ := reached(d, o.keys)
	return keys != rules.NONE && holds(b, d, keys, {})
}

// Whether `o` has a `dependentSchemas` member, which an arm judges.
@(private)
dependent_schemas :: proc(o: ^rules.Object) -> bool {
	for x in o.dependents {
		if x.node != nil {
			return true
		}
	}
	return false
}

// Whether `n` with `edge` judges anything past its arms.
@(private)
bare_judges :: proc(b: ^Builder, d: ^rules.Description, n: ^rules.Node, edge: rules.Rules) -> bool {
	if edge != {} || n.kinds != rules.EVERY_KIND || n.rules != {} || n.has_enum || n.const_of != nil || n.object in b.inline {
		return true
	}
	if n.object >= 0 && (len(d.objects[n.object].members) > 0 || len(d.objects[n.object].dependents) > 0 || d.objects[n.object].additional != rules.NONE || d.objects[n.object].keys != rules.NONE) {
		return true
	}
	return n.array >= 0 && (len(d.arrays[n.array].prefix) > 0 || d.arrays[n.array].items != rules.NONE)
}

// Whether arms compare `n`'s `const` and `enum`: when one holds a container, as a leaf compares only scalars, or when
// both are present, as a leaf judges them as one and an arm each reports its own failure.
@(private)
arm_operands :: proc(n: ^rules.Node) -> bool {
	if n.const_of != nil && n.has_enum {
		return true
	}
	if c, has := n.const_of.?; has && core.value_kind(c) >= .Array {
		return true
	}
	for v in n.enum_of {
		if core.value_kind(v) >= .Array {
			return true
		}
	}
	return false
}

// The arms of a held use of `node` with `edge`, in `arena`, and those a check with no sink reads, nil for the same.
@(private)
checked_applies :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index, edge: rules.Rules) -> (applies, verdict: []Apply) {
	n := d.nodes[node]
	out := make([dynamic]Apply, arena)
	arm :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, out: ^[dynamic]Apply, kind: Apply_Kind, node: rules.Node_Index, site: ..core.Step) -> ^Apply {
		steps := make([]core.Step, len(site), arena)
		copy(steps, site)
		if _, failed := append(out, Apply{kind = kind, rec = arm_record(b, d, arena, node), site = steps, by = presence(d, node, arena)}); failed != nil {
			refuse_plan(b, .No_Memory)
			return nil
		}
		return &out[len(out) - 1]
	}
	// The record of the node without its arms, which only its uses with no rules of their own share, and none when it
	// judges nothing.
	key := Block_Key{typeid_of(rules.Rules), i32(node), b.scope} if edge == {} else Block_Key{typeid_of(Use), i32(len(b.fields)), 0}
	base, known := b.blocks[key]
	if !known && bare_judges(b, d, &n, edge) {
		if base = reserve_block(b, 1, key); base >= 0 {
			fill_checked(b, d, arena, int(base), node, "", edge, nil, true)
		}
	} else if !known {
		base = -1
	}
	append(&out, Apply{kind = .All, rec = base})
	if x, has := n.ref.?; has {
		arm(b, d, arena, &out, .All, x, core.Name("$ref"))
	}
	if x, has := n.dynamic_ref.?; has {
		arm(b, d, arena, &out, .All, dynamic_target(b, d, x), core.Name("$dynamicRef"))
	}
	places := b.all_of_at[node]
	for x, i in n.all_of {
		arm(b, d, arena, &out, .All, x, core.Name("allOf"), core.Index(places[i] if places != nil else i))
	}
	for x, i in n.any_of {
		arm(b, d, arena, &out, .Any, x, core.Name("anyOf"), core.Index(i))
	}
	for x, i in n.one_of {
		arm(b, d, arena, &out, .One, x, core.Name("oneOf"), core.Index(i))
	}
	if x, has := n.not.?; has {
		arm(b, d, arena, &out, .Not, x, core.Name("not"))
	}
	if x, has := n.cond.test.?; has && (n.cond.then != nil || n.cond.other != nil) {
		arm(b, d, arena, &out, .If, x, core.Name("if"))
		if y, then := n.cond.then.?; then {
			arm(b, d, arena, &out, .Then, y, core.Name("then"))
		}
		if y, other := n.cond.other.?; other {
			arm(b, d, arena, &out, .Else, y, core.Name("else"))
		}
	}
	if arm_operands(&n) {
		if c, constant := n.const_of.?; constant {
			values, hashes := by_hash([]core.Value{c}, arena)
			append(&out, Apply{kind = .Equal, rec = -1, values = values, hashes = hashes, constant = true})
		}
		if n.has_enum {
			values, hashes := by_hash(n.enum_of, arena)
			append(&out, Apply{kind = .Equal, rec = -1, values = values, hashes = hashes})
		}
	}
	if n.rules.unique || edge.unique {
		append(&out, Apply{kind = .Unique, rec = -1})
	}
	if n.object >= 0 && names_hold(b, d, &d.objects[n.object]) {
		keys, _ := reached(d, d.objects[n.object].keys)
		arm(b, d, arena, &out, .Names, keys, core.Name("propertyNames"))
	}
	if n.object >= 0 {
		o := d.objects[n.object]
		inline := n.object in b.inline
		for x in o.patterns[:0 if inline else len(o.patterns)] {
			re, err := rules.program_of(&b.programs, x.expression, arena)
			if err != "" {
				refuse_plan(b, .Unsupported, text = "patternProperties")
				return out[:], nil
			}
			if a := arm(b, d, arena, &out, .Pattern, x.node, core.Name("patternProperties"), core.Name(x.expression)); a != nil {
				a.name, a.pattern = x.expression, re
			}
		}
		if len(o.patterns) > 0 && !inline && o.additional != rules.NONE {
			names := make([dynamic]string, arena)
			for x in o.members {
				if !x.only_required {
					append(&names, x.name)
				}
			}
			word := "unevaluatedProperties" if b.unevaluated[{0, n.object}] else "additionalProperties"
			if a := arm(b, d, arena, &out, .Additional, o.additional, core.Name(word)); a != nil {
				a.names = names[:]
			}
		}
		for x in o.dependents {
			if y, has := x.node.?; has {
				if a := arm(b, d, arena, &out, .Dependent, y, core.Name("dependentSchemas"), core.Name(x.name)); a != nil {
					a.name = x.name
				}
			}
		}
	}
	if n.array >= 0 {
		a := d.arrays[n.array]
		if x, has := a.contains.?; has {
			if c := arm(b, d, arena, &out, .Contains, x, core.Name("contains")); c != nil {
				c.min, c.max = a.min_contains.? or_else 1, a.max_contains.? or_else max(u64)
			}
		}
	}
	if n.unevaluated_items != nil || n.unevaluated_properties != nil {
		e := evaluates(b, d, arena, node, own = true)
		e.wholes, e.elements = evaluated_records(e, arena)
		if e.fixed = fixed_part(b, d, arena, node); e.fixed == nil {
			return out[:], nil
		}
		if x, has := n.unevaluated_properties.?; has && !e.fixed.members {
			if a := arm(b, d, arena, &out, .Unevaluated_Members, x, core.Name("unevaluatedProperties")); a != nil {
				a.eval, a.judge = e, .Never if d.nodes[x].kinds == {} else .Run
			}
		}
		if x, has := n.unevaluated_items.?; has && !e.fixed.items {
			if a := arm(b, d, arena, &out, .Unevaluated_Items, x, core.Name("unevaluatedItems")); a != nil {
				a.eval, a.judge = e, .Never if d.nodes[x].kinds == {} else .Run
			}
		}
	}
	c, conjoined := b.conjoined[node]
	if !conjoined || edge != {} {
		return out[:], nil
	}
	v := make([dynamic]Apply, arena)
	if c.arms != nil {
		kind := Apply_Kind.Any if len(n.any_of) > 0 else .One
		for x in c.arms {
			append(&v, Apply{kind = kind, rec = verdict_record(b, d, arena, x), by = presence(d, x, arena)})
		}
		return out[:], v[:]
	}
	append(&v, Apply{kind = .All, rec = arm_record(b, d, arena, c.node)})
	for x in c.held {
		append(&v, Apply{kind = .All, rec = arm_record(b, d, arena, x)})
	}
	for x in c.lifted {
		y := d.nodes[x]
		if z, has := y.not.?; has {
			append(&v, Apply{kind = .Not, rec = arm_record(b, d, arena, z), by = presence(d, z, arena)})
		}
		if z, has := y.cond.test.?; has && (y.cond.then != nil || y.cond.other != nil) {
			append(&v, Apply{kind = .If, rec = arm_record(b, d, arena, z), by = presence(d, z, arena)})
			if w, then := y.cond.then.?; then {
				append(&v, Apply{kind = .Then, rec = arm_record(b, d, arena, w), by = presence(d, w, arena)})
			}
			if w, other := y.cond.other.?; other {
				append(&v, Apply{kind = .Else, rec = arm_record(b, d, arena, w), by = presence(d, w, arena)})
			}
		}
	}
	for a in out {
		if a.kind != .All {
			append(&v, a)
		}
	}
	return out[:], v[:]
}

// Sets in each verdict how its arms are judged: an arm whose record only requires members by the names, and the `.Any`
// arms, and apart from them the `.One` arms, that one member's `const` or `enum` tells apart gathered into one arm,
// which an object's first member, when it is that member, picks its choice by. Runs after every record is filled.
@(private)
choose_arms :: proc(b: ^Builder, arena: runtime.Allocator) {
	for &u in b.uses {
		list := u.verdict if u.verdict != nil else u.applies
		if len(list) == 0 || raw_data(list) == &FORKING[0] {
			continue
		}
		if judged := by_presence(list, arena); judged != nil {
			list, u.verdict = judged, judged
		}
		any := choices_of(b, arena, list, .Any)
		one := choices_of(b, arena, any if any != nil else list, .One)
		if one != nil {
			u.verdict = one
		} else if any != nil {
			u.verdict = any
		}
	}
}

// Gives each held use its `judging` and `judging_all` ids: uses whose arms, as a check with no sink and one with a sink
// read them, are alike in every part but their keyword steps share one. Runs after `choose_arms`.
@(private)
judging_ids :: proc(b: ^Builder, arena: runtime.Allocator) {
	ids := make(map[string]u32, arena)
	intern :: proc(ids: ^map[string]u32, arena: runtime.Allocator, list: []Apply, all: bool) -> u32 {
		key := strings.builder_make(arena)
		strings.write_byte(&key, 1 if all else 0)
		arms_key(&key, list)
		id, known := ids[strings.to_string(key)]
		if !known {
			id = u32(len(ids) + 1)
			ids[strings.to_string(key)] = id
		}
		return id
	}
	for &u in b.uses {
		if len(u.applies) == 0 || raw_data(u.applies) == &FORKING[0] {
			continue
		}
		u.judging = intern(&ids, arena, u.verdict if u.verdict != nil else u.applies, false)
		u.judging_all = intern(&ids, arena, u.applies, true)
	}
}

// Writes to `key` what judging by the arms `list` depends on, apart from their keyword steps.
@(private)
arms_key :: proc(key: ^strings.Builder, list: []Apply) {
	put :: proc(key: ^strings.Builder, x: $T) {
		x := x
		strings.write_bytes(key, mem.ptr_to_bytes(&x))
	}
	text :: proc(key: ^strings.Builder, s: string) {
		put(key, len(s))
		strings.write_string(key, s)
	}
	put(key, len(list))
	for &a in list {
		put(key, a.kind)
		put(key, a.judge)
		put(key, a.rec)
		put(key, a.constant)
		put(key, a.min)
		put(key, a.max)
		put(key, a.pattern)
		put(key, a.eval)
		put(key, raw_data(a.values))
		put(key, len(a.values))
		text(key, a.name)
		put(key, len(a.names))
		for x in a.names {
			text(key, x)
		}
		put(key, a.by != nil)
		if a.by == nil {
			continue
		}
		put(key, len(a.by.present))
		for x in a.by.present {
			text(key, x)
		}
		arms_key(key, a.by.choices)
		put(key, len(a.by.keys))
		for x in a.by.keys {
			text(key, x)
		}
		for x in a.by.picks {
			put(key, x)
		}
	}
}

// `list` with the arms whose verdict the names their `by` lists decide judged by presence, nil when it has none. An arm
// that reports through its run's failures keeps its run.
@(private)
by_presence :: proc(list: []Apply, arena: runtime.Allocator) -> []Apply {
	PRESENCE_ARMS :: bit_set[Apply_Kind]{.Any, .One, .Not, .If, .Then, .Else}
	out: []Apply
	for a, i in list {
		if a.by == nil || a.by.present == nil || a.kind not_in PRESENCE_ARMS || a.rec < 0 {
			continue
		}
		if out == nil {
			out = make([]Apply, len(list), arena)
			copy(out, list)
		}
		out[i].judge = .Presence
	}
	return out
}

// The members an object must have to pass `node` when that is all the node judges, nil otherwise. A value that is no
// object passes it.
@(private)
presence :: proc(d: ^rules.Description, node: rules.Node_Index, arena: runtime.Allocator) -> ^Judging {
	names := make([dynamic]string, arena)
	if node == rules.NONE || !judges_nothing(d, node, 0, &names) || len(names) == 0 {
		return nil
	}
	return new_clone(Judging{present = names[:]}, arena)
}

// `list` with its arms of `kind` that a member's enum tells apart gathered into one `.Choice` arm at the place of the
// first, nil when fewer than two are.
@(private)
choices_of :: proc(b: ^Builder, arena: runtime.Allocator, list: []Apply, kind: Apply_Kind) -> []Apply {
	runs :: proc(a: Apply, kind: Apply_Kind) -> bool {
		return a.kind == kind && a.judge == .Run && a.rec >= 0
	}
	first := -1
	for a, i in list {
		if runs(a, kind) {
			first = i
			break
		}
	}
	if first < 0 {
		return nil
	}
	// The member is one the first arm names, the one the most arms are told apart by.
	name, most := "", 0
	m := &b.meta[b.fields[list[first].rec].meta]
	for j in 0 ..< m.members {
		candidate := b.meta[b.fields[m.block + j].meta].name
		count := 0
		for a in list {
			count += int(runs(a, kind) && choice_keys(b, a.rec, candidate) != nil)
		}
		if count > most {
			name, most = candidate, count
		}
	}
	if most < 2 {
		return nil
	}
	choices := make([dynamic]Apply, arena)
	pick := make(map[string]i32, arena)
	out := make([dynamic]Apply, arena)
	head := -1
	for a in list {
		keys := choice_keys(b, a.rec, name) if runs(a, kind) else nil
		if keys == nil {
			append(&out, a)
			continue
		}
		if head < 0 {
			head = len(out)
			append(&out, Apply{kind = kind, judge = .Choice, rec = -1, name = name})
		}
		for k in keys {
			// An operand two choices have leaves the arms as they are.
			if k in pick {
				return nil
			}
			pick[k] = i32(len(choices))
		}
		append(&choices, a)
	}
	keys := make([]string, len(pick), arena)
	picks := make([]i32, len(pick), arena)
	i := 0
	for k in pick {
		keys[i] = k
		i += 1
	}
	rules.enum_sort(keys)
	for k, j in keys {
		picks[j] = pick[k]
	}
	out[head].by = new_clone(Judging{choices = choices[:], keys = keys, picks = picks}, arena)
	return out[:]
}

// The enum keys of the member `name` of the record `rec` when an object's first member that is it can kill the record
// by them: the record takes objects, waits for their first member, and the member's leaf has an enum and its record no
// arms. Nil otherwise.
@(private)
choice_keys :: proc(b: ^Builder, rec: i32, name: string) -> []string {
	arms :: proc(b: ^Builder, meta: u32) -> bool {
		return int(meta) < len(b.uses) && len(b.uses[meta].applies) > 0
	}
	at := b.fields[rec].meta
	m := &b.meta[at]
	if m.rule_set > 0 && .Object not_in b.leaves[m.rule_set - 1].kinds || m.members == 0 || arms(b, at) {
		return nil
	}
	for j in 0 ..< m.members {
		f := b.fields[m.block + j]
		x := &b.meta[f.meta]
		if x.name != name {
			continue
		}
		if x.rule_set == 0 || arms(b, f.meta) || !b.leaves[x.rule_set - 1].has_enum {
			return nil
		}
		return b.leaves[x.rule_set - 1].enum_keys
	}
	return nil
}

// The record of an arm that judges by `node`, which each use of the node by an arm in one scope shares. The keyword
// steps to it are the arm's.
@(private)
arm_record :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index) -> i32 {
	key := Block_Key{typeid_of(Apply), i32(node), b.scope}
	if at, ok := b.blocks[key]; ok {
		return at
	}
	at := reserve_block(b, 1, key)
	if at >= 0 {
		fill_checked(b, d, arena, int(at), node, "", {}, nil)
	}
	return at
}

// The record every value inside a held value reads with, which hands each token to the held value's runs. The record
// after it predicts no key, so each key reaches the fork.
@(private)
fork_record :: proc(b: ^Builder) -> i32 {
	key := Block_Key{typeid_of(Fork), 0, 0}
	if at, ok := b.blocks[key]; ok {
		return at
	}
	at := reserve_block(b, 2, key)
	if at >= 0 && resize(&b.uses, len(b.meta)) == nil {
		never(b, int(at))
		never(b, int(at) + 1)
		b.fields[at].kind, b.fields[at].meta = .Checked, u32(at)
		b.uses[at].applies = FORKING[:]
	}
	return at
}

@(private)
@(rodata)
FORKING := [1]Apply{{rec = -1}}


// Whether `v` equals one of `values`, a repeated key of each object counting with the value `dups` keeps. With their
// `hashes`, only the operands of `v`'s hash are compared, unless `v` holds a `Plain` node that `read_plain` reads as the
// kind of the operand, whose hash is its kind's only as an operand reads it. What a comparison takes in `space` is taken back.
@(private)
equals_one :: proc(v: core.Value, values: []core.Value, hashes: []u64 = nil, space: ^mem.Arena = nil, read_plain := false, dups := core.Duplicates.Last) -> bool {
	from := 0
	to := len(values)
	if hashes != nil && !(read_plain && holds_plain(v)) {
		mark := space.offset if space != nil else 0
		h := core.hash(v, dups = dups)
		if space != nil {
			space.offset = mark
		}
		from, _ = slice.binary_search(hashes, h)
		for to = from; to < len(hashes) && hashes[to] == h; to += 1 {}
	}
	for x in values[from:to] {
		mark := space.offset if space != nil else 0
		equal := core.equal(v, x, read_plain = read_plain, dups = dups)
		if space != nil {
			space.offset = mark
		}
		if equal {
			return true
		}
	}
	return false
}

// `values` sorted by their `core.hash`, and the hashes in that order.
@(private)
by_hash :: proc(values: []core.Value, arena: runtime.Allocator) -> (sorted: []core.Value, hashes: []u64) {
	Hashed :: struct {
		hash:  u64,
		value: core.Value,
	}
	all := make([]Hashed, len(values), arena)
	for x, i in values {
		all[i] = {core.hash(x), x}
	}
	slice.sort_by(all, proc(a, b: Hashed) -> bool {return a.hash < b.hash})
	sorted, hashes = make([]core.Value, len(values), arena), make([]u64, len(values), arena)
	for x, i in all {
		sorted[i], hashes[i] = x.value, x.hash
	}
	return
}

// Whether `v` is or holds a document's `Plain` node.
@(private)
holds_plain :: proc(v: core.Value) -> bool {
	r, is_node := v.(core.Node_Ref)
	if !is_node {
		return false
	}
	for n in r.doc.nodes[r.node:] {
		if n.kind == .Plain {
			return true
		}
	}
	return false
}

// One arm's judging of a held value beside the check that reads it: a check by the arm's record of the whole value, or
// of one member or element. `skip` is the depth of a value it passes over unread, -1 for the next value. `parent` is the
// check that reads the held value, at `at` with `below` frames under it, `site` the keyword steps from the held record to
// the arm's record, and `step` the member's or element's step from the held value.
@(private)
Run :: struct {
	c:        Check,
	regs:     core.Hook_Regs,
	room:     int,
	skip:     int,
	done:     bool,
	parent:   ^Check,
	at:       core.Hook_Regs,
	below:    int,
	site:     []core.Step,
	step:     Maybe(core.Step),
	// The failures of a run that reports only when its arm is chosen, made at its first such use.
	buffer:   ^Sink,
	// The readings the check takes when the run's arm is chosen, made at the first use of a check that keeps them.
	readings: ^Readings,
	// The forks that follow the fork of this run's check, which it hands its verdict or its fork as it is freed.
	followers: int,
	// The next free run, and the run made before this one.
	next:     ^Run,
	older:    ^Run,
	frames:   [4]Frame,
}

// The runs and forks of one check and of the runs inside it: those free for reuse, the count of runs made, and the last
// run and fork made, which link every one made. They are made with `allocator`, the temp allocator when it is nil.
@(private)
Pool :: struct {
	free:       ^Run,
	forks:      ^Fork,
	made:       int,
	runs:       ^Run,
	held:       ^Fork,
	// The runs and forks an earlier value's check made that this one has not yet taken, along `older`.
	stale:      ^Run,
	stale_fork: ^Fork,
	allocator:  runtime.Allocator,
	// Whether a key repeats in the text of the value checked, nil until a refusal asks.
	repeated:   Maybe(bool),
	// The forks of runs opened at the container starting at `leads_at`, in the order the token reached them, which a fork
	// opened later at it may follow, the count of forks opened, and that count as the check of the current value began.
	leads:      [8]^Fork,
	n_leads:    int,
	leads_at:   u64,
	opened:     u64,
	begun:      u64,
}

// What checks keep of their arms' runs and held values from one value to the next, so a check of many values makes
// them once. It serves one check at a time, makes them with the context allocator of its first check, and is freed by
// `checker_destroy`.
Checker :: struct {
	pool: Pool,
}

checker_destroy :: proc(c: ^Checker) {
	p := &c.pool
	for r := p.runs; r != nil; {
		older := r.older
		free(r, p.allocator)
		r = older
	}
	for fk := p.held; fk != nil; {
		older := fk.older
		free(fk, p.allocator)
		fk = older
	}
	c^ = {}
}

// Gives back every run and fork of `p` for the check of a new value, whose parts the temp allocator holds afresh. Each
// is made fresh when the check first takes it.
@(private)
pool_begin :: proc(p: ^Pool) {
	p.free, p.forks, p.stale, p.stale_fork = nil, nil, p.runs, p.held
}

// A run of `p` for the check of the current value: one given back in it, or else one an earlier value's check made,
// fresh. Nil when there is neither.
@(private)
pool_run :: proc(p: ^Pool) -> ^Run {
	if r := p.free; r != nil {
		p.free = r.next
		return r
	}
	r := p.stale
	if r != nil {
		p.stale = r.older
		r.c.trackers, r.c.home, r.room, r.buffer, r.readings, r.c.fork, r.c.taken = {}, raw_data(r.frames[:]), len(r.frames), nil, nil, nil, nil
	}
	return r
}

// A fork of `p` for the check of the current value, as `pool_run` gives a run.
@(private)
pool_fork :: proc(p: ^Pool) -> ^Fork {
	if fk := p.forks; fk != nil {
		p.forks = fk.outer
		return fk
	}
	fk := p.stale_fork
	if fk != nil {
		p.stale_fork = fk.older
		fork_fresh(fk)
	}
	return fk
}

// Points the parts of `fk` that grow at the temp allocator, empty.
@(private)
fork_fresh :: proc(fk: ^Fork) {
	t := context.temp_allocator
	fk.arms, fk.names, fk.marks, fk.spans, fk.seen = {}, {}, {}, {}, {}
	fk.arms.allocator, fk.names.allocator, fk.marks.allocator, fk.spans.allocator, fk.seen.allocator = t, t, t, t, t
	fk.space, fk.spilled, fk.builder, fk.scratch, fk.open = {}, false, {}, {}, false
	temp_scratch(&fk.scratch)
}

// Whether a key repeats in the text `h` checks, asked once for every run of the check.
@(private)
pool_text_repeats :: proc(h: ^Check) -> bool {
	if known, asked := h.pool.repeated.?; asked {
		return known
	}
	repeated := text_repeats((^Reader)(h))
	h.pool.repeated = repeated
	return repeated
}

// The allocator `p` makes its runs and forks with.
@(private)
pool_allocator :: proc(p: ^Pool) -> runtime.Allocator {
	return p.allocator if p.allocator.procedure != nil else context.temp_allocator
}

// The held values a check judges one inside the other, past which a schema that applies itself to the same value
// without end fails as `.Too_Deep`.
@(private)
MAX_HELD :: 256

// The runs a check makes, past which it stops as `.No_Memory`.
@(private)
MAX_RUNS :: 1 << 16

// The held value a check reads: its record's use, its registers and those past it, its first byte and kind, the
// containers open in it, the check's frames below it, the state of each arm, its member names in order and its last
// key, and its build when an arm compares it whole. `takes` says whether one live run may take the value over, `taken`
// is the kind of the arm that took it, and `outer` the fork taken before it or the next free one.
@(private)
Fork :: struct {
	u:          ^Use,
	regs, next: core.Hook_Regs,
	lo:         u64,
	kind:       core.Kind,
	depth:      int,
	below:      int,
	open:       bool,
	arms:       [dynamic]Arm_Run,
	n:          int,
	names:      [dynamic]string,
	// Under `.Judge`, each name's member span, up to the next key, and past `SEEN_SCAN` names the latest index of each.
	spans:      [dynamic][2]u64,
	seen:       map[string]int,
	count:      int,
	key:        string,
	holds:      bool,
	builder:    build.Builder,
	built:      core.Hook_Regs,
	scratch:    regex.Scratch,
	takes:      bool,
	taken:      Apply_Kind,
	outer:      ^Fork,
	// The fork made before this one.
	older:      ^Fork,
	space:      mem.Arena,
	// Whether the space ran out since its last growth.
	spilled:    bool,
	marks:      [dynamic]bool,
	// The arms whose runs wait for the object's first member, its open token and first key, and the depth its runs nest at.
	waiting:    int,
	opened:     core.Token,
	first_key:  Maybe(core.Token),
	level:      int,
	// Whether an arm judges each member or element, which takes every value at depth one, and whether one judges each name.
	per_member: bool,
	names_arms: bool,
	// The run whose check holds the fork this one follows, nil for a fork that judges by runs of its own, the count of
	// the check's failures as the fork opened, and the start of the last token the fork skipped.
	follows:    ^Run,
	from:       int,
	skipped:    u64,
	// The check that holds the fork, the place of its open among the pool's forks, the start of the last token it was fed,
	// and, for a follower whose lead was freed after it closed or stopped, the lead's verdict.
	owner:      ^Check,
	order:      u64,
	fed:        u64,
	ruled:      bool,
	handed:     bool,
	rule_first: core.Typed_Refusal,
	rule_fatal: core.Typed_Error_Kind,
}

// An arm's state in a fork: the run of the whole value, or of the member or element being read, its verdict, and what
// a member arm keeps of each member: the count that passed, whether each one passed, or each failing one's first failure
// and its failures in `pending`. `apply` is nil for a record the evaluated set asks of, `.Any` for the whole value and
// `.Contains` for each element.
@(private)
Arm_Run :: struct {
	apply:   ^Apply,
	kind:    Apply_Kind,
	rec:     i32,
	run:     ^Run,
	passed:  bool,
	// An arm the value's kind or its object's first member fails, which takes no run, and one whose run waits for that member.
	dead:    bool,
	waiting: bool,
	count:   u64,
	passes:  [dynamic]bool,
	failed:  [dynamic]Failed,
	pending: ^Sink,
}

// A member or element that failed an arm: its place, its first failure, and its failures in the arm's `pending`.
@(private)
Failed :: struct {
	index:    int,
	first:    core.Typed_Refusal,
	from, to: int,
}

// The bytes of a fork's space, which each held value's names, build and comparisons take from first, at its first use
// and at most. The temp allocator's reset clears the space, so a small first space keeps a check of small values cheap.
@(private)
FORK_SPACE :: 1 << 16
@(private)
FORK_SPACE_FIRST :: 1 << 10

// The arms whose verdict alone counts, which a kind they refuse or a failing first member decides with no run.
@(private)
VERDICT_ARMS :: bit_set[Apply_Kind]{.Any, .One, .Not, .If}

@(private)
WHOLE_ARMS :: bit_set[Apply_Kind]{.All, .Any, .One, .Not, .If, .Then, .Else, .Dependent}

@(private)
MEMBER_ARMS :: bit_set[Apply_Kind]{.Pattern, .Additional, .Contains, .Unevaluated_Members, .Unevaluated_Items}

// The arms whose failures are the held value's as they happen, and those whose failures wait until the arm is chosen.
@(private)
REPORTING :: bit_set[Apply_Kind]{.All, .Pattern, .Additional, .Names}

@(private)
BUFFERED :: bit_set[Apply_Kind]{.Then, .Else, .Dependent, .Unevaluated_Members, .Unevaluated_Items}

// The value `t` at a held record, or at the fork record inside a held value.
@(cold)
@(private)
fork_value :: #force_no_inline proc "contextless" (h: ^Check, regs, next: core.Hook_Regs, u: ^Use, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if raw_data(u.applies) != &FORKING[0] {
		if t.kind != .Object && t.kind != .Array {
			if passed, judged, reading := scalar_verdict(h, u.verdict if h.sink == nil && u.verdict != nil else u.applies, t, 0); passed && judged {
				if h.readings != nil && reading != .Plain {
					reading_keep(h, t.lo, reading)
				}
				return next, .Next
			}
		} else if h.sink == nil {
			if taken, action, took := fork_read(h, regs, next, u, t); took {
				return taken, action
			}
		}
		return fork_open(h, regs, next, u, t)
	}
	fk := h.fork
	action := fork_token(h, t)
	if action == .Skip {
		return regs, .Skip
	}
	if t.kind == .Object || t.kind == .Array {
		return {NO_LIMIT, regs.b, 0}, action
	}
	if action == .Next && fk.open && fk.depth == 1 {
		if taken, took := fork_take(h, fk); took {
			return taken, .Next
		}
	}
	return regs, action
}

// Reads the held container `t` by the record of the one arm its verdict is, as `fork_take` hands a value to its one live
// run, but from the open and with no run: the arm is a `.Any` or `.One` arm that alone admits the container's kind, or the
// one `.All` arm with a record, and its record's own arms are followed the same way to a record with none. Says whether
// `t` is read so, which needs a check with no sink and no other arm that judges the value.
@(private)
fork_read :: #force_no_inline proc "contextless" (h: ^Check, regs, next: core.Hook_Regs, u: ^Use, t: core.Token) -> (core.Hook_Regs, core.Action, bool) {
	if h.find_tag == document_tag && (^Document_Read(Check))(h.format).doc.readers.attribute != nil {
		return {}, .Next, false
	}
	taken := Apply_Kind.All
	applies := u.verdict if u.verdict != nil else u.applies
	rec := i32(-1)
	for _ in 0 ..< MAX_HELD {
		live, any, one := -1, false, false
		for &a, i in applies {
			if a.judge != .Run || a.eval != nil || a.kind > .One || a.rec < 0 && a.kind != .All {
				return {}, .Next, false
			}
			any, one = any || a.kind == .Any, one || a.kind == .One
			if a.rec < 0 || a.kind != .All && !kind_admits(h, &h.plan.meta[h.plan.fields[a.rec].meta], t) {
				continue
			}
			if live >= 0 {
				return {}, .Next, false
			}
			live = i
		}
		if live < 0 || any && applies[live].kind != .Any || one && applies[live].kind != .One {
			return {}, .Next, false
		}
		if applies[live].kind != .All {
			taken = applies[live].kind
		}
		inner := &h.plan.uses[h.plan.fields[applies[live].rec].meta]
		if len(inner.applies) == 0 {
			rec = applies[live].rec
			break
		}
		if raw_data(inner.applies) == &FORKING[0] {
			return {}, .Next, false
		}
		applies = inner.verdict if inner.verdict != nil else inner.applies
	}
	if rec < 0 || h.plan.fields[rec].kind != .Checked {
		return {}, .Next, false
	}
	context = h.ctx
	if h.pool == nil {
		if h.pool = new(Pool, context.temp_allocator); h.pool == nil {
			return {}, .Next, false
		}
	}
	fk := pool_fork(h.pool)
	if fk == nil {
		if fk = new(Fork, pool_allocator(h.pool)); fk == nil {
			return {}, .Next, false
		}
		fork_fresh(fk)
		fk.older, h.pool.held = h.pool.held, fk
	}
	sp := h.sp
	inside, action := check_value(h, {NO_LIMIT, u64(uintptr(&([^]Field)(raw_data(h.plan.fields))[rec + 1])), 0}, t)
	if h.sp == sp {
		// The record reads nothing inside the container, which passes it.
		fk.outer, h.pool.forks = h.pool.forks, fk
		return next, action, true
	}
	h.frames[sp].c = regs.c
	fk.u, fk.regs, fk.next, fk.lo, fk.kind, fk.below, fk.open, fk.n, fk.taken = u, regs, next, t.lo, t.kind, sp, false, 0, taken
	fk.outer, h.taken = h.taken, fk
	return inside, action, true
}

// Whether the scalar `t` passes the arms `applies` by the leaves of their records and those records' own arms, and
// whether that judges it: not when an arm judges more than a scalar's leaves, which the fork then judges. `reading` is
// the kind a `Plain` value reads as in the arms that decide, `.Plain` when none reads it.
@(private)
scalar_verdict :: proc "contextless" (h: ^Check, applies: []Apply, t: core.Token, depth: int) -> (passed, judged: bool, reading: core.Kind) {
	any, any_passed, ones, one, if_passed := false, false, false, 0, false
	reading = .Plain
	for &a in applies {
		ok := true
		if a.judge == .Choice {
			// A choice is one `.Any` or `.One` arm of its own, which a scalar judges as it judges the others.
			for &c in a.by.choices {
				read: core.Kind
				if ok, judged, read = record_passes(h, c.rec, t, depth); !judged {
					return
				}
				if ok && read != .Plain && (a.kind == .One || !any_passed) {
					reading = read
				}
				any, any_passed = any || a.kind == .Any, any_passed || a.kind == .Any && ok
				ones, one = ones || a.kind == .One, one + int(a.kind == .One && ok)
			}
			continue
		}
		read := core.Kind.Plain
		if a.kind in SCALAR_ARMS && a.eval == nil {
			if a.rec >= 0 {
				if ok, judged, read = record_passes(h, a.rec, t, depth); !judged {
					return
				}
			}
		} else if a.kind not_in OBJECT_ARRAY_ARMS {
			return false, false, .Plain
		}
		decides := false
		switch a.kind {
		case .All:
			if !ok {
				return false, true, .Plain
			}
			decides = true
		case .Any:
			decides = ok && !any_passed
			any, any_passed = true, any_passed || ok
		case .One:
			ones, one, decides = true, one + int(ok), ok
		case .Not:
			if ok {
				return false, true, .Plain
			}
		case .If:
			if_passed = ok
		case .Then, .Else:
			if if_passed == (a.kind == .Then) {
				if !ok {
					return false, true, .Plain
				}
				decides = true
			}
		case .Dependent, .Pattern, .Additional, .Contains, .Unique, .Equal, .Unevaluated_Members, .Unevaluated_Items, .Names:
		}
		if decides && read != .Plain {
			reading = read
		}
	}
	return (!any || any_passed) && (!ones || one == 1), true, reading
}

// Whether the scalar `t` passes the record `rec`, and whether `scalar_verdict` judges that. `reading` is the kind a
// `Plain` value reads as by the record's leaf, else by its arms.
@(private)
record_passes :: proc "contextless" (h: ^Check, rec: i32, t: core.Token, depth: int) -> (passed, judged: bool, reading: core.Kind) {
	fld := &h.plan.fields[rec]
	u := &h.plan.uses[fld.meta]
	reading = .Plain
	if len(u.applies) > 0 {
		if depth == MAX_HELD || raw_data(u.applies) == &FORKING[0] {
			return false, false, .Plain
		}
		if passed, judged, reading = scalar_verdict(h, u.verdict if h.sink == nil && u.verdict != nil else u.applies, t, depth + 1); !passed || !judged {
			return
		}
	}
	if m := &h.plan.meta[fld.meta]; m.rule_set > 0 {
		l := &h.plan.leaves[m.rule_set - 1]
		value := plain_token(h, t, l) if t.kind == .Plain else t
		if t.kind == .Plain {
			reading = value.kind
		}
		return scalar_fails(h, value, l) == {}, true, reading
	}
	return true, true, reading
}

// The arms `scalar_verdict` judges a scalar by, and those a scalar passes as no object or array.
@(private)
SCALAR_ARMS :: bit_set[Apply_Kind]{.All, .Any, .One, .Not, .If, .Then, .Else}
@(private)
NAME_ARMS :: bit_set[Apply_Kind]{.Names}
@(private)
OBJECT_ARRAY_ARMS :: bit_set[Apply_Kind]{.Dependent, .Pattern, .Additional, .Contains, .Unique, .Unevaluated_Members, .Unevaluated_Items, .Names}

// Opens the fork of the held value `t` at `regs`: starts a run of the value for each arm that judges it whole, feeds
// them `t`, and for a container opens its frame, whose values read at the fork record. A scalar is judged at once.
@(private)
fork_open :: proc "contextless" (h: ^Check, regs, next: core.Hook_Regs, u: ^Use, t: core.Token) -> (core.Hook_Regs, core.Action) {
	context = h.ctx
	// A run at its own root judges the value its parent holds, so only there does the holding nest.
	level := h.nest if h.sp == 1 else 0
	lo, hi := core.scalar_ends(t)
	if level == MAX_HELD {
		return next, fork_fault(h, regs, .Too_Deep, lo, hi)
	}
	// A markup element reads as its record says, which a run of another record cannot follow.
	if h.find_tag == document_tag && (^Document_Read(Check))(h.format).doc.readers.attribute != nil {
		return next, fork_fault(h, regs, .Unsupported, lo, hi)
	}
	if h.pool == nil {
		h.pool = new(Pool, context.temp_allocator)
	}
	if h.fork == nil && h.pool != nil {
		if h.fork = pool_fork(h.pool); h.fork == nil {
			if h.fork = new(Fork, pool_allocator(h.pool)); h.fork != nil {
				fork_fresh(h.fork)
				h.fork.older, h.pool.held = h.pool.held, h.fork
			}
		}
	}
	if h.pool == nil || h.fork == nil {
		return next, fork_fault(h, regs, .No_Memory, lo, hi)
	}
	fk := h.fork
	container := t.kind == .Object || t.kind == .Array
	fk.u, fk.regs, fk.next, fk.lo, fk.kind = u, regs, next, t.lo if container else lo, t.kind
	fk.depth, fk.below, fk.open, fk.n, fk.count, fk.key, fk.holds = 0, h.sp, true, 0, 0, "", false
	fk.follows, fk.skipped, fk.from, fk.ruled, fk.handed = nil, max(u64), len(h.sink.entries) if h.sink != nil else 0, false, false
	fk.owner, fk.order, fk.fed = h, h.pool.opened, max(u64)
	h.pool.opened += 1
	if container {
		if lead := fork_lead(h, u, t, level); lead != nil {
			fk.follows, fk.depth, fk.takes, fk.waiting, fk.level = lead, lead.c.fork.depth, false, 0, level
			lead.c.fork.takes = false
			lead.followers += 1
			f := &h.frames[h.sp]
			h.sp += 1
			f.a, f.b, f.c, f.seen, f.run, f.extra = regs.a, regs.b, regs.c, 0, nil, nil
			f.data, f.kind, f.owner, f.target = rawptr(uintptr(t.lo)), t.kind, nil, 0
			return fork_regs(h), .Next
		}
	}
	fk.takes, fk.outer = h.sink == nil && container, nil
	fk.waiting, fk.opened, fk.first_key, fk.level, fk.per_member, fk.names_arms = 0, t, nil, level, false, false
	clear(&fk.names)
	clear(&fk.spans)
	clear(&fk.seen)
	mem.arena_free_all(&fk.space)
	applies := u.verdict if h.sink == nil && u.verdict != nil else u.applies
	reserve(&fk.arms, len(applies))
	for &a in applies {
		// An arm judged by the names waits for the close.
		fk.takes &&= a.kind <= .One && a.eval == nil && a.judge != .Presence
		arm_add(h, fk, &a, a.kind, a.rec, level, t)
		if a.eval != nil {
			for rec in a.eval.wholes {
				arm_add(h, fk, nil, .Any, rec, level, t)
			}
			for rec in a.eval.elements {
				arm_add(h, fk, nil, .Contains, rec, level, t)
			}
		}
		fk.holds ||= a.kind == .Equal || a.kind == .Unique && t.kind == .Array
		fk.per_member ||= a.kind in MEMBER_ARMS || a.eval != nil
		fk.names_arms ||= a.kind == .Names
	}
	if fk.holds {
		fk.builder, fk.built = build.builder_start(h.src, h.view.as, false, fork_space(fk), 16, 8), build.BUILDER_REGS
		if fk.builder.err.kind != .None {
			h.fatal = .No_Memory
		}
	}
	if h.fatal != .None {
		fork_release(h, fk)
		return next, fork_fault(h, regs, h.fatal, lo, hi)
	}
	action := fork_token(h, t)
	if !container || action == .Stop {
		return next, action
	}
	if fk.takes && fk.waiting == 0 && fork_live(fk) == -1 {
		// Every run is decided at the open, so the container is judged now and passed over.
		return next, .Skip if fork_finish(h, fk, t.lo) == .Next else .Stop
	}
	f := &h.frames[h.sp]
	h.sp += 1
	f.a, f.b, f.c, f.seen, f.run, f.extra = regs.a, regs.b, regs.c, 0, nil, nil
	f.data, f.kind, f.owner, f.target = rawptr(uintptr(t.lo)), t.kind, nil, 0
	if taken, took := fork_take(h, fk); took {
		return taken, .Next
	}
	if p := h.pool; h.run != nil && h.sink == nil && u.judging != 0 {
		if p.leads_at != t.lo {
			p.leads_at, p.n_leads = t.lo, 0
		}
		if p.n_leads < len(p.leads) {
			p.leads[p.n_leads] = fk
			p.n_leads += 1
		}
	}
	return fork_regs(h), .Next
}

// The registers of a value inside a held value, one past the fork record.
@(private)
fork_regs :: #force_inline proc "contextless" (h: ^Check) -> core.Hook_Regs {
	return {NO_LIMIT, u64(uintptr(&h.plan.fields[h.plan.fork + 1])), 0}
}

// Reports `kind` at the held value at `regs` and stops the check and every check it is an arm of.
@(private)
fork_fault :: proc(h: ^Check, regs: core.Hook_Regs, kind: core.Typed_Error_Kind, lo, hi: u64) -> core.Action {
	note(h, regs, {kind = kind, at = lo}, hi)
	h.fatal = kind
	return .Stop
}

// Adds the arm `a` of kind `kind` with record `rec` to the fork of the value `t`, with a run of the value when it judges
// the value whole. A record the evaluated set asks of is added once.
@(private)
arm_add :: proc(h: ^Check, fk: ^Fork, a: ^Apply, kind: Apply_Kind, rec: i32, level: int, t: core.Token) {
	if a == nil {
		// A record an arm already judges the value by answers the set's question, and so does a choice that may pick it,
		// which passes the records it does not pick by none.
		for &x in fk.arms[:fk.n] {
			if x.rec == rec && (x.kind == kind || kind == .Any && x.kind in WHOLE_ARMS) || kind == .Any && x.waiting && chooses(x.apply, rec) {
				return
			}
		}
	}
	// An object's first member decides an arm only when the first of its repeated keys is the one kept.
	first := t.kind == .Object && (h.repeats != .Judge || h.first_key)
	if a != nil && a.judge == .Choice && !first {
		for &c in a.by.choices {
			arm_add(h, fk, &c, c.kind, c.rec, level, t)
		}
		return
	}
	if fk.n == len(fk.arms) {
		if _, failed := append(&fk.arms, Arm_Run{}); failed != nil {
			h.fatal = .No_Memory
			return
		}
		x := &fk.arms[fk.n]
		x.passes.allocator, x.failed.allocator = context.temp_allocator, context.temp_allocator
	}
	x := &fk.arms[fk.n]
	fk.n += 1
	x.apply, x.kind, x.rec, x.run, x.passed, x.count, x.dead, x.waiting = a, kind, rec, nil, true, 0, false, false
	clear(&x.passes)
	clear(&x.failed)
	x.pending = nil
	judge := a.judge if a != nil else .Run
	switch judge {
	case .Choice:
		x.waiting = true
		fk.waiting += 1
		return
	case .Presence:
		return
	case .Run, .Never:
	}
	if a != nil && kind in VERDICT_ARMS && rec >= 0 {
		fld := &h.plan.fields[rec]
		m := &h.plan.meta[fld.meta]
		switch {
		case !kind_admits(h, m, t):
			x.dead = true
			return
		case first && m.members > 0 && len(h.plan.uses[fld.meta].applies) == 0:
			x.waiting = true
			fk.waiting += 1
			return
		}
	}
	if kind in WHOLE_ARMS && rec >= 0 {
		x.run = run_start(h, fk, x, rec, level + 1, nil)
	}
}

// Whether `a` is a `.Choice` arm that stands for an arm of record `rec`.
@(private)
chooses :: proc(a: ^Apply, rec: i32) -> bool {
	if a == nil || a.judge != .Choice {
		return false
	}
	for c in a.by.choices {
		if c.rec == rec {
			return true
		}
	}
	return false
}

// Whether a value of `t`'s kind can pass the record of `m`, which a held record's own leaf does not say.
@(private)
kind_admits :: proc "contextless" (h: ^Check, m: ^Meta, t: core.Token) -> bool {
	if m.rule_set == 0 {
		return true
	}
	kinds := h.plan.leaves[m.rule_set - 1].kinds
	#partial switch t.kind {
	case .Null:
		return .Null in kinds
	case .True, .False:
		return .Bool in kinds
	case .String:
		return .String in kinds
	case .Number:
		return kinds & {.Integer, .Number} != {}
	case .Object:
		return .Object in kinds
	case .Array:
		return .Array in kinds
	}
	return true
}

// Starts the runs that wait for the held object's first member, as `t`, its value or the object's close, arrives: an arm
// whose record fails a scalar first member by its kind or enum takes no run, and each other run is fed the object's open
// and its first key.
@(private)
fork_wake :: proc(h: ^Check, fk: ^Fork, t: core.Token) -> core.Action {
	scalar := t.kind != .Object && t.kind != .Array && t.kind != .End
	buf: [TEXT_ROOM]u8 = ---
	text, decoded := "", false
	if scalar {
		text, decoded = enum_text(h, t, buf[:])
	}
	// The choices of an arm its first member does not pick are added past the arms and woken in turn.
	for i := 0; i < fk.n; i += 1 {
		x := &fk.arms[i]
		if !x.waiting {
			continue
		}
		x.waiting = false
		// A picked choice passed its member's enum, which no other run judges before its run.
		picked := false
		if a := x.apply; a != nil && a.judge == .Choice {
			if !decoded || fk.first_key == nil || fk.key != a.name {
				x.dead = true
				for &c in a.by.choices {
					arm_add(h, fk, &c, c.kind, c.rec, fk.level, fk.opened)
				}
				continue
			}
			at, found := rules.enum_find(a.by.keys, t.kind, text)
			if !found {
				x.dead = true
				continue
			}
			c := &a.by.choices[a.by.picks[at]]
			x.apply, x.rec, picked = c, c.rec, true
		}
		if !picked && decoded && fk.first_key != nil && member_fails(h, x.rec, fk.key, t, text) {
			x.dead = true
			continue
		}
		if x.run = run_start(h, fk, x, x.rec, fk.level + 1, nil); x.run == nil {
			return .Stop
		}
		stopped := run_feed(h, x.run, fk.opened)
		if k, keyed := fk.first_key.?; keyed && !stopped {
			stopped = run_feed(h, x.run, k)
		}
		if stopped && arm_stopped(h, fk, x) == .Stop {
			return .Stop
		}
	}
	fk.waiting = 0
	return .Next
}

// The text an enum index keys the scalar `t` by, a string's decoded and a decimal's own, into `buf` when it fits there,
// and whether `t` has one.
@(private)
enum_text :: proc(h: ^Check, t: core.Token, buf: []u8) -> (string, bool) {
	#partial switch t.kind {
	case .String:
		return decoded_text(h, t, buf)
	case .Number:
		if t.spelling & core.NUMBER_KIND_MASK > core.NUMBER_DECIMAL {
			return "", false
		}
		return string(raw_data(h.src)[t.lo:][:t.n]), true
	case .Plain:
		return "", false
	}
	return "", true
}

// Whether the scalar `t`, the member `key` of an object, fails the leaf of that member's record in the object record
// `rec` by its kind or its enum. `text` is the text `enum_text` keys `t` by.
@(private)
member_fails :: proc(h: ^Check, rec: i32, key: string, t: core.Token, text: string) -> bool {
	owner := &h.plan.fields[rec]
	i := member_index(h, owner, &h.plan.meta[owner.meta], key)
	if i < 0 {
		return false
	}
	fld := &([^]Field)(owner.first)[i]
	m := &h.plan.meta[fld.meta]
	if m.rule_set == 0 || len(h.plan.uses[fld.meta].applies) > 0 {
		return false
	}
	if !kind_admits(h, m, t) {
		return true
	}
	l := &h.plan.leaves[m.rule_set - 1]
	if !l.has_enum {
		return false
	}
	return !rules.enum_has(l, t.kind, text)
}

// Starts a run of record `rec` for the arm `x` of the fork, of the held value or, under `step`, of its member or element.
@(private)
run_start :: proc(h: ^Check, fk: ^Fork, x: ^Arm_Run, rec: i32, nest: int, step: Maybe(core.Step)) -> ^Run {
	p := h.pool
	r := pool_run(p)
	if r == nil {
		if p.made == MAX_RUNS {
			h.fatal = .No_Memory
			return nil
		}
		if r = new(Run, pool_allocator(p)); r == nil {
			h.fatal = .No_Memory
			return nil
		}
		p.made += 1
		r.older, p.runs = p.runs, r
		r.c.home, r.room = raw_data(r.frames[:]), len(r.frames)
	}
	c := &r.c
	c.frames, c.sp = c.home, 1
	c.frames[0].seen = 0
	c.expect, c.borrow, c.first_key, c.refuse_unknown, c.wide, c.wrap_sp, c.wrap = h.expect, h.borrow, h.first_key, h.refuse_unknown, true, 0, nil
	c.view, c.plan, c.ctx, c.find_tag, c.format = h.view, h.plan, h.ctx, h.find_tag, h.format
	c.first, c.fatal, c.nest, c.pool, c.run, c.after, c.taken = {}, .None, nest, p, r, nil, nil
	// An arm's structs sit below a union, which `merge` replaces whole, so a partial load reads them in full.
	c.partial = false
	c.sink, c.repeats, c.tracked = nil, h.repeats, 0
	// A run that judges repeats takes back what a replaced member failed, so it keeps its failures even when no arm reports them.
	if h.sink != nil && (x.apply != nil || h.repeats == .Judge) {
		switch {
		case x.kind in REPORTING && x.apply != nil:
			c.sink = h.sink
		case x.kind in BUFFERED || h.repeats == .Judge:
			if step == nil {
				if r.buffer == nil {
					if r.buffer = new(Sink, context.temp_allocator); r.buffer == nil {
						h.fatal = .No_Memory
						return nil
					}
				}
				c.sink = r.buffer
				r.buffer.entries = nil
				r.buffer.entries.allocator = fork_space(fk)
			} else {
				if x.pending == nil {
					if x.pending = new(Sink, fork_space(fk)); x.pending == nil {
						h.fatal = .No_Memory
						return nil
					}
					x.pending.entries.allocator = fork_space(fk)
				}
				c.sink = x.pending
			}
			c.sink.max_errors, c.sink.record = h.sink.max_errors, h.sink.record
			if step != nil {
				// A candidate's failures wait until close delivers or discards them, so the limit applies there. A candidate
				// holds what the sink above can still take and one more, which tells the delivery it was cut.
				c.sink.max_errors = len(c.sink.entries) + sink_limit(h.sink) - len(h.sink.entries) + 1
			}
		}
	}
	c.floor = len(c.sink.entries) if c.sink != nil else 0
	c.readings = nil
	if h.readings != nil {
		if r.readings == nil {
			if r.readings = new(Readings, context.temp_allocator); r.readings == nil {
				h.fatal = .No_Memory
				return nil
			}
		}
		r.readings^ = {}
		r.readings.read.allocator = fork_space(fk)
		c.readings = r.readings
	}
	r.regs = {NO_LIMIT, u64(uintptr(&([^]Field)(raw_data(h.plan.fields))[rec + 1])), 0}
	r.skip, r.done, r.followers = 0, false, 0
	r.parent, r.at, r.below, r.step = h, fk.regs, fk.below, step
	r.site = x.apply.site if x.apply != nil else nil
	return r
}

// Gives the run back to the pool, with the fork open in it.
@(private)
run_free :: proc(h: ^Check, r: ^Run) {
	if r.followers > 0 {
		lead_free(r)
	}
	if r.c.fork != nil && r.c.fork.open {
		fork_release(&r.c, r.c.fork)
	}
	if r.buffer != nil {
		clear(&r.buffer.entries)
		r.buffer.truncated = false
	}
	r.next = h.pool.free
	h.pool.free = r
}

// Feeds `t` to the run, past the values it passes over. Says whether the run stopped on it.
@(private)
run_feed :: #force_inline proc(h: ^Check, r: ^Run, t: core.Token) -> bool {
	value := t.role == .Value
	open := value && (t.kind == .Object || t.kind == .Array)
	switch {
	case r.done:
		return false
	case r.skip < 0:
		if value {
			r.skip = 1 if open else 0
		}
		return false
	case r.skip > 0:
		if open {
			r.skip += 1
		} else if value && t.kind == .End {
			r.skip -= 1
		}
		return false
	}
	if open && r.c.sp + 2 > r.room {
		frames, failed := make([]Frame, 2 * r.room, context.temp_allocator)
		if failed != nil {
			r.c.fatal, r.done = .No_Memory, true
			return true
		}
		copy(frames, r.c.frames[:r.c.sp + 1])
		r.c.frames, r.c.home, r.room = raw_data(frames), raw_data(frames), len(frames)
	}
	r.c.mant = h.mant
	action: core.Action
	r.regs, action = on_token_check_spelled(&r.c, r.regs, t)
	#partial switch action {
	case .Skip:
		r.skip = -1 if t.role == .Key else 1
	case .Stop:
		taken_settle(&r.c)
		r.done = true
		return true
	}
	return false
}

// Hands `t`, a token of the held value, to the fork, which keeps what it gave for a fork that follows it.
@(cold)
@(private)
fork_token :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token) -> core.Action {
	fk := h.fork
	if fk.follows != nil || fk.ruled {
		return fork_follow(h, fk, t)
	}
	return fork_step(h, t)
}

// The fork of another run's check that judges the container `t` at a use `u` judges alike, which the token reached just
// before this check: the run of it, nil for none. Two arms that each read the value so then share one judging of it,
// which keeps arms that recurse through the same member from multiplying their runs at each level. Only checks with no
// readings follow. A sibling run's fork from the same frame leads a check with no sink, as then only the verdict and
// refusal count, or with a sink of the run's own that no chosen arm delivers, as then only the failures' kinds and places
// count, which the follower copies. Any earlier run's fork with no sink that does not hold this check leads one with no
// sink whose arm counts only by its verdict, as the refusal's steps are the lead's.
@(private)
fork_lead :: proc(h: ^Check, u: ^Use, t: core.Token, level: int) -> ^Run {
	r := h.run
	if r == nil || u.judging == 0 || h.readings != nil || r.parent.fork == nil {
		return nil
	}
	if h.sink == nil && h.first.kind != .None || h.sink != nil && h.sink != r.buffer {
		return nil
	}
	pf := r.parent.fork
	lead: ^Run
	for &x in pf.arms[:pf.n] {
		y := x.run
		if y == r {
			if h.sink != nil && x.kind in BUFFERED {
				return nil
			}
			if lead == nil && h.sink == nil && x.kind in VERDICT_ARMS {
				lead = earlier_lead(h, u, t)
			}
			return lead
		}
		if lead != nil || y == nil || y.done || y.step != r.step || y.below != r.below || y.c.nest != h.nest {
			continue
		}
		f := y.c.fork
		if f == nil || !f.open || f.follows != nil || f.ruled || f.lo != t.lo || f.below != h.sp || f.level != level || f.u.judging != u.judging || h.sink != nil && f.u.judging_all != u.judging_all {
			continue
		}
		if y.c.readings != nil || y.c.taken != nil || y.c.sink != (nil if h.sink == nil else y.buffer) {
			continue
		}
		if h.sink != nil || y.c.first.kind == .None {
			lead = y
		}
	}
	return nil
}

// The run of a fork the token opening `t` reached before this check, judging alike at `u` with no sink, that no check
// holding this one holds, nil for none.
@(private)
earlier_lead :: proc(h: ^Check, u: ^Use, t: core.Token) -> ^Run {
	p := h.pool
	if p.leads_at != t.lo {
		return nil
	}
	leads: for f in p.leads[:p.n_leads] {
		y := f.owner.run
		if !f.open || f.follows != nil || f.ruled || f.lo != t.lo || f.u.judging != u.judging || y == nil || y.c.fork != f || y.done {
			continue
		}
		if y.c.sink != nil || y.c.readings != nil || y.c.taken != nil || y.c.first.kind != .None {
			continue
		}
		for c := h; c.run != nil; c = c.run.parent {
			if c.run.parent == f.owner {
				continue leads
			}
		}
		return y
	}
	return nil
}

// Hands what the forks that follow the fork of `r`'s check need before `r` is freed: its verdict when the fork closed or
// the check stopped, else the open fork itself to the first of them, which the others then follow.
@(private)
lead_free :: proc(r: ^Run) {
	f := r.c.fork
	heir: ^Fork
	p := r.c.pool
	for x := p.held; x != nil; x = x.older {
		if x.follows != r || !x.open || x.order < p.begun {
			continue
		}
		if f == nil || !f.open || r.done {
			x.follows, x.ruled, x.rule_first, x.rule_fatal = nil, true, r.c.first, r.c.fatal
			if f == nil || f.open && r.c.fatal == .None && r.c.first.kind == .None {
				x.rule_fatal = .No_Memory
			}
			if c := r.c.sink; c != nil && f != nil && len(c.entries) > f.from {
				e := c.entries[f.from]
				x.rule_first = r.c.first if r.c.first.kind != .None && r.c.first.at >= f.lo else core.Typed_Refusal{kind = e.kind, at = e.start}
				fork_deliver(x.owner, nil, c.entries[f.from:], x.rule_first)
				x.owner.sink.truncated ||= c.truncated
			}
		} else if heir == nil || x.order < heir.order {
			heir = x
		}
	}
	if heir == nil {
		r.followers = 0
		return
	}
	hc := heir.owner
	f.u, f.regs, f.next, f.below, f.level, f.owner, f.order = heir.u, heir.regs, heir.next, heir.below, heir.level, hc, heir.order
	heir.follows, heir.open = nil, false
	f.ruled, f.handed = true, true
	r.c.fork, hc.fork = heir, f
	for &x in f.arms[:f.n] {
		if x.run != nil {
			x.run.parent, x.run.at, x.run.below = hc, f.regs, f.below
		}
	}
	for x := p.held; x != nil; x = x.older {
		if x.follows == r && x.open && x.order >= p.begun {
			x.follows = hc.run
			hc.run.followers += 1
		}
	}
	r.followers = 0
}

// The token `t` the fork `fk` follows its lead's fork on: what the lead gave for it, and, as the lead closes, its
// verdict: with no sink its refusal, as the lead then stops exactly when it holds a refusal or a fault, and with one the
// failures it added since its fork opened.
@(private)
fork_follow :: proc "contextless" (h: ^Check, fk: ^Fork, t: core.Token) -> core.Action {
	if fk.handed {
		// A fork handed over from a lead, which may have read the token already.
		fk.handed, fk.ruled = false, false
		if fk.fed == t.lo {
			return .Skip if fk.skipped == t.lo else .Next
		}
		return fork_step(h, t)
	}
	if fk.ruled {
		fk.ruled, fk.open = false, false
		if h.first.kind == .None {
			h.first = fk.rule_first
		}
		if fk.rule_fatal != .None {
			h.fatal = fk.rule_fatal
			return .Stop
		}
		return .Stop if h.sink == nil && h.first.kind != .None else .Next
	}
	lead := fk.follows
	f := lead.c.fork
	if f != nil && f.open && !lead.done {
		fk.depth = f.depth
		return .Skip if f.skipped == t.lo else .Next
	}
	fk.follows, fk.open = nil, false
	lead.followers -= 1
	if f == nil || f.open || lead.c.fatal != .None {
		h.fatal = lead.c.fatal if lead.c.fatal != .None else .No_Memory
		h.first = lead.c.first
		return .Stop
	}
	if c := lead.c.sink; c != nil {
		if len(c.entries) > f.from {
			context = h.ctx
			e := c.entries[f.from]
			first := lead.c.first if lead.c.first.kind != .None && lead.c.first.at >= fk.lo else core.Typed_Refusal{kind = e.kind, at = e.start}
			fork_deliver(h, nil, c.entries[f.from:], first)
		}
		h.sink.truncated ||= c.truncated
		return .Next
	}
	if lead.c.first.kind != .None {
		h.first = lead.c.first
		return .Stop
	}
	return .Next
}

// Hands `t`, a token of the held value, to each live run, and to the value's build. Starts the runs of a member or an
// element as it opens and ends them as it closes, and judges the value by its arms as it closes.
@(private)
fork_step :: #force_inline proc "contextless" (h: ^Check, t: core.Token) -> core.Action {
	context = h.ctx
	fk := h.fork
	fk.fed = t.lo
	value := t.role == .Value
	open := value && (t.kind == .Object || t.kind == .Array)
	end := value && t.kind == .End
	if fk.waiting > 0 && value && fk.depth == 1 && fork_wake(h, fk, t) == .Stop {
		fork_release(h, fk)
		return .Stop
	}
	if value && !end && fk.depth == 1 {
		member_start(h, fk, MEMBER_ARMS, at = t.lo)
	}
	if t.role == .Key && fk.depth == 1 {
		#partial switch fork_key(h, fk, t) {
		case .Stop:
			fork_release(h, fk)
			return fork_fault(h, fk.regs, h.fatal, fk.lo, fk.lo) if h.fatal != .None else .Stop
		case .Skip:
			fk.skipped = t.lo
			return .Skip
		}
	}
	for &x in fk.arms[:fk.n] {
		if x.run == nil {
			continue
		}
		stopped := run_feed(h, x.run, t)
		// A run that reports to the check's sink reports its failures as the check's, the first among them.
		if h.first.kind == .None && x.run.c.first.kind != .None && h.sink != nil && x.run.c.sink == h.sink {
			h.first = run_first(x.run)
		}
		if stopped && arm_stopped(h, fk, &x) == .Stop {
			fork_release(h, fk)
			return .Stop
		}
	}
	if fk.holds && t.role <= .Key && !fork_hold(fk, t) {
		fork_release(h, fk)
		return fork_fault(h, fk.regs, .No_Memory, fk.lo, fk.lo)
	}
	if open && fk.depth > 0 && fork_passes_over(fk, t) {
		fk.skipped = t.lo
		return .Skip
	}
	if open {
		fk.depth += 1
	} else if end {
		fk.depth -= 1
	}
	switch {
	case t.role == .Key && fk.depth == 1:
		if fk.names_arms && names_judge(h, fk, t) == .Stop {
			fork_release(h, fk)
			return .Stop
		}
	case value && fk.depth == 1 && !open:
		member_end(h, fk, MEMBER_ARMS)
	case fk.depth == 0:
		_, hi := core.scalar_ends(t)
		return fork_finish(h, fk, hi)
	}
	if h.fatal != .None {
		fork_release(h, fk)
		return fork_fault(h, fk.regs, h.fatal, fk.lo, fk.lo)
	}
	if t.role == .Key && fork_passes_over(fk, t) {
		fk.skipped = t.lo
		return .Skip
	}
	return .Next
}

// Names `name` as the operand of the entries `c` took from `from` on, which a name rule failed at the object's path.
@(private)
name_failed :: proc(c: ^Sink, from: int, name: string) {
	if c == nil || c.entries.allocator.procedure == nil {
		return
	}
	for &e in c.entries[min(from, len(c.entries)):] {
		if e.operand == nil {
			e.operand = strings.clone(name, c.entries.allocator)
		}
	}
}

// Judges the name `t` of a member of the held object by each `.Names` arm, as a string value.
@(private)
names_judge :: proc(h: ^Check, fk: ^Fork, t: core.Token) -> core.Action {
	name := t
	name.role = .Value
	before := len(h.sink.entries) if h.sink != nil else 0
	member_start(h, fk, NAME_ARMS, name)
	for &x in fk.arms[:fk.n] {
		if x.kind == .Names && x.run != nil && run_feed(h, x.run, name) && arm_stopped(h, fk, &x) == .Stop {
			return .Stop
		}
	}
	member_end(h, fk, NAME_ARMS)
	name_failed(h.sink, before, fk.key)
	return .Next
}

// Whether the walk passes over the value that the key or open `t` starts in the held value, which each run was just fed:
// no run reads it and nothing else of the fork takes its tokens. Each run then stands as past the value's close, which
// the walk does not give.
@(private)
fork_passes_over :: #force_inline proc "contextless" (fk: ^Fork, t: core.Token) -> bool {
	if fk.holds || fk.waiting > 0 || fk.per_member {
		return false
	}
	key := t.role == .Key
	for &x in fk.arms[:fk.n] {
		if r := x.run; r != nil && !r.done && (r.skip == 0 || !key && r.skip < 0) {
			return false
		}
	}
	for &x in fk.arms[:fk.n] {
		if r := x.run; r != nil && !r.done {
			if !key {
				r.skip -= 1
			} else if r.skip < 0 {
				r.skip = 0
			}
		}
	}
	return true
}

// What a run that stopped does to the fork: a stop past its sink stops the check, noted at the held value when the run
// reports elsewhere, a repeat a run noticed stops the check as its own, and a failure of an arm that reports stops a check
// with no sink.
@(private)
arm_stopped :: proc(h: ^Check, fk: ^Fork, x: ^Arm_Run) -> core.Action {
	r := x.run
	if r.c.first.kind == .Duplicate_Key && r.c.fatal == .None {
		h.first = r.c.first
		return .Stop
	}
	if r.c.fatal != .None || r.c.sink != nil {
		kind := r.c.fatal if r.c.fatal != .None else core.Typed_Error_Kind.No_Memory
		if r.c.sink != h.sink || h.sink == nil {
			note(h, fk.regs, {kind = kind, at = fk.lo}, fk.lo)
		}
		h.fatal = kind
		return .Stop
	}
	if h.sink == nil && x.apply != nil && x.kind in REPORTING {
		if h.first.kind == .None {
			h.first = run_first(r)
			// A later repeat of a key in an object the run or the check had open could take the refusal back, so the check
			// reads again. A run of a whole held value leaves the value's own keys to the fork it is an arm of, which reads on.
			from := 2 if h.run != nil && h.run.step == nil else 1
			if h.repeats == .Notice && h.first.kind != .Walk && h.first.kind != .No_Memory && (from == 1 && fk.kind == .Object || object_open((^Reader)(&r.c), 2) || object_open((^Reader)(h), from)) && pool_text_repeats(h) {
				h.first = {kind = .Duplicate_Key, at = h.first.at}
			}
		}
		return .Stop
	}
	return .Next
}

// Notes the key `t` of a member of the held object, the member a check that meets repeats keeps: a repeat ends a check
// that notices it, is skipped under `.First`, and under `.Last` takes back what the member it replaces failed.
@(private)
fork_key :: proc(h: ^Check, fk: ^Fork, t: core.Token) -> core.Action {
	key, ok := core.token_text(h.plan.readers, &h.view, t, fork_space(fk))
	if !ok {
		h.fatal = .No_Memory
		return .Stop
	}
	lo, _ := core.scalar_ends(t)
	if h.repeats == .Judge && len(fk.spans) > 0 {
		slice.last_ptr(fk.spans[:])[1] = lo
	}
	if h.repeats != .Ignore {
		if at := names_find(fk.names[:], &fk.seen, key); at >= 0 {
			if h.repeats == .Notice {
				return noticed(h, t)
			}
			if h.first_key {
				return .Skip
			}
			take_back(h, fk.spans[at])
			for &x in fk.arms[:fk.n] {
				if x.kind == .Unevaluated_Members {
					#reverse for f, i in x.failed {
						if f.index == at {
							ordered_remove(&x.failed, i)
						}
					}
				}
			}
		}
		if h.repeats == .Judge {
			if _, failed := append(&fk.spans, [2]u64{lo, max(u64)}); failed != nil {
				h.fatal = .No_Memory
				return .Stop
			}
		}
	}
	if _, failed := append(&fk.names, key); failed != nil {
		h.fatal = .No_Memory
		return .Stop
	}
	if h.repeats != .Ignore {
		names_index(fk.names[:], &fk.seen)
	}
	fk.key = key
	if fk.first_key == nil {
		fk.first_key = t
	}
	return .Next
}

// How many names of a held object a search for a repeat reads before it keeps them in a map.
@(private)
SEEN_SCAN :: 16

// The latest index of `key` among an object's `names`, read from `index` once it holds them, or -1.
@(private)
names_find :: proc(names: []string, index: ^map[string]int, key: string) -> int {
	if len(index) > 0 {
		return index[key] or_else -1
	}
	#reverse for name, i in names {
		if name == key {
			return i
		}
	}
	return -1
}

// Keeps `index` of an object's `names` once they pass `SEEN_SCAN`, after the last one was added.
@(private)
names_index :: proc(names: []string, index: ^map[string]int) {
	if len(names) <= SEEN_SCAN {
		return
	}
	if len(index) == 0 {
		for name, i in names {
			index[name] = i
		}
		return
	}
	index[names[len(names) - 1]] = len(names) - 1
}

// Whether `text` lies inside `src`.
@(private)
within :: #force_inline proc "contextless" (src: []u8, text: string) -> bool {
	at, lo := uintptr(raw_data(text)), uintptr(raw_data(src))
	return at >= lo && at + uintptr(len(text)) <= lo + uintptr(len(src))
}

// Adds `t` to the build of the held value.
@(private)
fork_hold :: proc(fk: ^Fork, t: core.Token) -> bool {
	b := &fk.builder
	if t.kind == .Object || t.kind == .Array {
		if int(fk.built.c) == len(b.stack) && !build.builder_deepen(b, len(b.stack)) {
			return false
		}
	}
	action: core.Action
	fk.built, action = build.builder_hook_grow(b, fk.built, t)
	return action != .Stop
}

// Starts the runs of the member or element that opens at the held value's depth 1, for each arm of `kinds` that judges
// it, or under `NAME_ARMS` of the member's `name`, which a record that judges a scalar by its leaves passes with no run.
// A check with no sink fails a member or element at `at` that a `.Never` arm judges with no run.
@(private)
member_start :: proc(h: ^Check, fk: ^Fork, kinds: bit_set[Apply_Kind], name := core.Token{}, at: u64 = 0) {
	array := fk.kind == .Array
	step: Maybe(core.Step)
	nest := fk.level + 1
	if kinds != NAME_ARMS {
		step = core.Step(core.Index(fk.count)) if array else core.Step(core.Name(fk.key))
		nest = 0
		fk.count += 1
	}
	for &x in fk.arms[:fk.n] {
		if x.kind not_in kinds || x.rec < 0 || step != nil && array != (x.kind == .Contains || x.kind == .Unevaluated_Items) {
			continue
		}
		if x.kind == .Pattern && !matches(x.apply.pattern, fk.key, &fk.scratch) || x.kind == .Additional && !additional(fk, x.apply, fk.key) {
			continue
		}
		if x.kind == .Unevaluated_Members && evaluates_name(x.apply.eval.fixed, fk.key, &fk.scratch) || x.kind == .Unevaluated_Items && fk.count <= x.apply.eval.fixed.prefix {
			continue
		}
		if x.apply != nil && x.apply.judge == .Never && h.sink == nil {
			from := slice.last(x.failed[:]).to if len(x.failed) > 0 else 0
			if _, failed := append(&x.failed, Failed{fk.count - 1, {kind = .Not_Allowed, at = at}, from, from}); failed != nil {
				h.fatal = .No_Memory
			}
			continue
		}
		if x.kind == .Names {
			if passed, judged, _ := record_passes(h, x.rec, name, 0); passed && judged {
				continue
			}
		}
		x.run = run_start(h, fk, &x, x.rec, nest, step)
	}
}

// Ends the runs of arms of `kinds` of the member or element that closed, keeping what each arm counts of it.
@(private)
member_end :: proc(h: ^Check, fk: ^Fork, kinds: bit_set[Apply_Kind]) {
	for &x in fk.arms[:fk.n] {
		if x.run == nil || x.kind not_in kinds {
			continue
		}
		first := x.run.c.first
		if x.kind != .Contains || first.kind == .None {
			readings_take(h, x.run)
		}
		#partial switch x.kind {
		case .Contains:
			x.count += u64(first.kind == .None)
			for len(x.passes) < fk.count - 1 {
				append(&x.passes, false)
			}
			append(&x.passes, first.kind == .None)
		case .Unevaluated_Members, .Unevaluated_Items:
			if first.kind != .None {
				from := slice.last(x.failed[:]).to if len(x.failed) > 0 else 0
				append(&x.failed, Failed{fk.count - 1, first, from, len(x.pending.entries) if x.pending != nil else from})
			}
		case:
			if first.kind != .None && h.first.kind == .None {
				h.first = run_first(x.run)
			}
		}
		run_free(h, x.run)
		x.run = nil
	}
}

// Whether the member `name` of the held object is one no name of `a.names` and no pattern of the held record matches.
@(private)
additional :: proc(fk: ^Fork, a: ^Apply, name: string) -> bool {
	if named(a.names, name) {
		return false
	}
	// The patterns are the arms before this one.
	for p := ([^]Apply)(a)[-1:]; p[0].kind == .Pattern; p = p[-1:] {
		if matches(p[0].pattern, name, &fk.scratch) {
			return false
		}
	}
	return true
}

// Judges the held value by its arms' verdicts, as it closes at `hi`, and gives back the fork's runs.
@(private)
fork_finish :: proc(h: ^Check, fk: ^Fork, hi: u64) -> core.Action {
	doc: core.Document
	if fk.holds {
		err: core.Document_Error
		if doc, err = build.builder_end(&fk.builder, fk.built, nil); err.kind != .None {
			fk.holds = false
			fork_release(h, fk)
			return fork_fault(h, fk.regs, .No_Memory, fk.lo, hi)
		}
		fk.holds = false
	}
	for &x in fk.arms[:fk.n] {
		x.passed = !x.dead && (x.run == nil || x.run.c.first.kind == .None)
		if a := x.apply; a != nil && a.judge == .Presence && fk.kind == .Object {
			for name in a.by.present {
				x.passed &&= named(fk.names[:], name)
			}
		}
	}
	any, any_passed, ones, one, if_passed := false, false, false, 0, false
	for &x in fk.arms[:fk.n] {
		if h.sink == nil && h.first.kind != .None {
			break
		}
		a := x.apply
		if a == nil {
			continue
		}
		switch a.kind {
		case .All:
			if !x.passed && h.first.kind == .None {
				h.first = run_first(x.run)
			}
			readings_take(h, x.run)
		case .Any:
			if x.passed && !any_passed {
				readings_take(h, x.run)
			}
			any, any_passed = true, any_passed || x.passed
		case .One:
			if x.passed {
				readings_take(h, x.run)
			}
			ones, one = true, one + int(x.passed)
		case .Not:
			if x.passed {
				fork_note(h, fk, .Not_Allowed, hi, "not")
			}
		case .If:
			if_passed = x.passed
		case .Then, .Else:
			if if_passed == (a.kind == .Then) && x.run != nil {
				fork_deliver(h, x.run, buffered(x.run))
				readings_take(h, x.run)
			} else if if_passed == (a.kind == .Then) && !x.passed && h.first.kind == .None {
				h.first = {kind = .Missing_Field, at = fk.lo}
			}
		case .Dependent:
			if fk.kind == .Object && x.run != nil && named(fk.names[:], a.name) {
				fork_deliver(h, x.run, buffered(x.run))
				readings_take(h, x.run)
			}
		case .Equal:
			context.allocator = fork_space(fk)
			if !equals_one(core.Node_Ref{&doc, core.ROOT}, a.values, a.hashes, &fk.space, h.readings != nil, held_dups(h)) {
				fork_note(h, fk, .Not_A_Member, hi, "const" if a.constant else "enum")
			}
		case .Unique:
			if fk.kind == .Array && !unique(&doc, fork_space(fk), h.readings != nil, held_dups(h)) {
				fork_note(h, fk, .Not_Unique, hi, "uniqueItems")
			}
		case .Contains:
			switch {
			case fk.kind != .Array:
			case x.count < a.min:
				fork_note(h, fk, .Too_Few, hi, "contains" if x.count == 0 else "minContains")
			case x.count > a.max:
				fork_note(h, fk, .Too_Many, hi, "maxContains")
			}
		case .Unevaluated_Members, .Unevaluated_Items:
			if fk.kind == (.Array if a.kind == .Unevaluated_Items else .Object) {
				fork_unevaluated(h, fk, &x)
			}
		case .Pattern, .Additional, .Names:
		}
	}
	if any && !any_passed {
		fork_note(h, fk, .No_Arm, hi, "anyOf")
	}
	if ones && one != 1 {
		fork_note(h, fk, .No_Arm if one == 0 else .Many_Arms, hi, "oneOf")
	}
	fk.open = false
	fork_release(h, fk)
	return .Stop if h.sink == nil && h.first.kind != .None || h.fatal != .None else .Next
}

// Adds a failure of kind `kind` under the keyword `word` of the held record to the sink.
@(private)
fork_note :: proc(h: ^Check, fk: ^Fork, kind: core.Typed_Error_Kind, hi: u64, word: string, operand := "") {
	e := core.Typed_Refusal{kind = kind, at = fk.lo}
	e.want.text = operand
	note(h, fk.regs, e, hi, word)
}

// Makes the failures `entries` of the chosen run `r` the held value's.
@(private)
fork_deliver :: proc(h: ^Check, r: ^Run, entries: []core.Error_Entry, first := core.Typed_Refusal{}) {
	first := first
	if r != nil {
		first = run_first(r) if r.c.first.kind != .None else {}
	}
	if first.kind == .None {
		return
	}
	if h.first.kind == .None {
		h.first = first
	}
	c := h.sink
	if c == nil {
		return
	}
	if c.entries.allocator.procedure == nil {
		c.entries.allocator = h.ctx.allocator
	}
	context.allocator = c.entries.allocator
	for e in entries {
		if len(c.entries) >= (c.max_errors if c.max_errors != 0 else 100) {
			c.truncated = true
			return
		}
		out := e
		out.path, out.keyword_path, out.operand = nil, nil, nil
		path_ok, words_ok := owned_steps(&out.path, e.path, false), owned_steps(&out.keyword_path, e.keyword_path, false)
		if name, named := e.operand.(string); named {
			out.operand = strings.clone(name)
		}
		if !path_ok || !words_ok {
			entry_destroy(&out, c.entries.allocator)
			c.truncated = true
			return
		}
		if _, grown := append(&c.entries, out); grown != nil {
			entry_destroy(&out, c.entries.allocator)
			c.truncated = true
			return
		}
	}
	if r != nil && r.buffer != nil && r.buffer.truncated {
		c.truncated = true
	}
}

// The failures the run `r` buffered.
@(private)
buffered :: proc(r: ^Run) -> []core.Error_Entry {
	return r.buffer.entries[:] if r.buffer != nil else nil
}

// Keeps the readings of the chosen run `r` as the held value's.
@(private)
readings_take :: proc(h: ^Check, r: ^Run) {
	if h.readings == nil || r == nil || r.readings == nil {
		return
	}
	if _, failed := append(&h.readings.read, ..r.readings.read[:]); failed != nil || r.readings.short {
		h.readings.short = true
	}
}

// Judges by the arm `x` each member or element of the held value that the held record does not evaluate.
@(private)
fork_unevaluated :: proc(h: ^Check, fk: ^Fork, x: ^Arm_Run) {
	if len(x.failed) == 0 {
		return
	}
	resize(&fk.marks, fk.count)
	slice.fill(fk.marks[:], false)
	ev := Evaluating{names = fk.names[:], count = fk.count, passes = fork_passes, data = fk, scratch = &fk.scratch}
	mark_evaluated(&ev, x.apply.eval, fk.marks[:], x.kind == .Unevaluated_Items)
	for f in x.failed {
		if !fk.marks[f.index] {
			fork_deliver(h, nil, x.pending.entries[f.from:f.to] if x.pending != nil else nil, f.first)
		}
	}
}

// Whether the held value, or with `index` its element of that place, passes record `rec`, which the fork judged.
@(private)
fork_passes :: proc(data: rawptr, index: int, rec: i32) -> bool {
	fk := (^Fork)(data)
	for &x in fk.arms[:fk.n] {
		if x.rec != rec {
			continue
		}
		if index < 0 && x.kind in WHOLE_ARMS {
			return x.passed
		}
		if index >= 0 && x.kind == .Contains {
			return index < len(x.passes) && x.passes[index]
		}
	}
	return false
}

// Notes the fault `e` at the innermost held value open in `c` by the check of the run that reads it, whose frames place
// it, as the outermost check's. Says whether a held value was open.
@(private)
fault_note :: proc(c: ^Check, regs: core.Hook_Regs, e: core.Typed_Refusal) -> bool {
	at, at_regs := c, regs
	for at.fork != nil && at.fork.open {
		r: ^Run
		for &x in at.fork.arms[:at.fork.n] {
			if x.run != nil && !x.run.done && x.run.skip == 0 && x.kind in WHOLE_ARMS {
				r = x.run
				break
			}
		}
		if r == nil {
			break
		}
		at, at_regs = &r.c, r.regs
	}
	if at == c {
		return false
	}
	steps, words := make([dynamic]core.Step, context.temp_allocator), make([dynamic]core.Step, context.temp_allocator)
	steps_of(at, at_regs, false, &steps)
	run_outer(at.run, &steps, &words)
	if c.first.kind == .None {
		c.first = e
		for x in steps {
			path_add(&c.first, x)
		}
		path_close(&c.first)
	}
	if k := c.sink; k != nil && len(k.entries) < sink_limit(k) {
		if k.entries.allocator.procedure == nil {
			k.entries.allocator = c.ctx.allocator
		}
		entry := core.Error_Entry{kind = e.kind, start = e.at, end = e.at, record = k.record}
		if !owned_steps(&entry.path, steps[:], true) {
			k.truncated = true
		} else if _, grown := append(&k.entries, entry); grown != nil {
			entry_destroy(&entry, k.entries.allocator)
			k.truncated = true
		}
	}
	return true
}

// The allocator of the fork's space, which spills to the temp allocator past it and is rewound at each held value. The
// space is taken from the temp allocator at its first use, since the temp allocator clears what it gave at its reset,
// and a held value that spilled makes the next one start on a space four times as large, up to `FORK_SPACE`.
@(private)
fork_space :: proc(fk: ^Fork) -> runtime.Allocator {
	space :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
		fk := (^Fork)(data)
		have := len(fk.space.data)
		if mode != .Free && mode != .Free_All && (have == 0 || fk.spilled && fk.space.offset == 0 && have < FORK_SPACE) {
			if block, failed := runtime.mem_alloc_non_zeroed(FORK_SPACE_FIRST if have == 0 else min(4 * have, FORK_SPACE), allocator = context.temp_allocator); failed == nil {
				mem.arena_init(&fk.space, block)
				fk.spilled = false
			}
		}
		got, err := spill_proc(&fk.space, mode, size, alignment, old, old_size, loc)
		base := uintptr(raw_data(fk.space.data))
		if len(got) > 0 && (uintptr(raw_data(got)) < base || uintptr(raw_data(got)) >= base + uintptr(len(fk.space.data))) {
			fk.spilled = true
		}
		return got, err
	}
	return {space, fk}
}

// Gives back the fork's runs.
@(private)
fork_release :: proc(h: ^Check, fk: ^Fork) {
	if fk.follows != nil {
		fk.follows.followers -= 1
		fk.follows = nil
	}
	for &x in fk.arms[:fk.n] {
		if x.run != nil {
			run_free(h, x.run)
			x.run = nil
		}
	}
	fk.n, fk.open = 0, false
}

// The member of a repeated key a held document's comparisons read: the build keeps every member, and the check keeps
// the first under `.First` and else the last.
@(private)
held_dups :: proc(h: ^Check) -> core.Duplicates {
	return .First if h.first_key else .Last
}

// Whether no two elements of the root array of `doc` are equal, comparing those whose hashes agree, with a `Plain` one read
// as the kind of the other when `read_plain`, and a repeated key of each object counting with the value `dups` keeps.
@(private)
unique :: proc(doc: ^core.Document, allocator: runtime.Allocator, read_plain: bool, dups: core.Duplicates) -> bool {
	context.allocator = allocator
	Hashed :: struct {
		hash: u64,
		node: core.Node_Index,
	}
	all := make([dynamic]Hashed)
	it := core.doc_children(doc, core.ROOT)
	for x in core.doc_child_next(&it) {
		append(&all, Hashed{core.hash(core.Node_Ref{doc, x}, dups = dups), x})
	}
	slice.sort_by(all[:], proc(a, b: Hashed) -> bool {return a.hash < b.hash})
	for i in 0 ..< len(all) {
		for j := i + 1; j < len(all) && all[j].hash == all[i].hash; j += 1 {
			if core.equal(core.Node_Ref{doc, all[i].node}, core.Node_Ref{doc, all[j].node}, read_plain = read_plain, dups = dups) {
				return false
			}
		}
	}
	return true
}

// Whether the compiled `^regex.Regex` at `p` matches in `name`.
@(private)
matches :: proc(p: rawptr, name: string, scratch: ^regex.Scratch) -> bool {
	found, err := regex.search((^regex.Regex)(p), name, 0, nil, scratch)
	return found && err == ""
}

// Whether `names` holds `name`.
@(private)
named :: proc(names: []string, name: string) -> bool {
	for x in names {
		if x == name {
			return true
		}
	}
	return false
}

// Points each of the scratch's buffers at the temp allocator.
@(private)
temp_scratch :: proc(s: ^regex.Scratch) {
	t := context.temp_allocator
	s.stack.allocator, s.slots.allocator, s.counts.allocator, s.seen.allocator, s.good.allocator, s.log.allocator = t, t, t, t, t, t
}

// Adds to `steps` and `words` the read's outer path and keyword steps of the outermost check `c`.
@(private)
outer_add :: proc(c: ^Check, steps, words: ^[dynamic]core.Step) {
	if c.outer != nil {
		#reverse for s in c.outer.path {
			append(steps, s)
		}
		append(words, ..c.outer.words)
	}
}

// Adds to `steps` and `words` what the path and the keyword path of a failure of the run `r` take outside it: the step
// to its member, the path to the held value and the keyword steps to the arm's record, with its parents' before them.
@(private)
run_outer :: proc(r: ^Run, steps, words: ^[dynamic]core.Step) {
	if s, has := r.step.?; has {
		append(steps, s)
	}
	p := r.parent
	steps_of(p, r.at, false, steps, r.below)
	if p.run != nil {
		run_outer(p.run, steps, words)
	} else {
		outer_add(p, steps, words)
	}
	for i in 1 ..< r.below {
		append(words, ..p.plan.uses[field_at(p.frames[i].b).meta].site)
	}
	append(words, ..p.plan.uses[field_at(r.at.b).meta].site)
	append(words, ..r.site)
}

// The first refusal of the run `r` as its parent check's, its path led by the steps to the value the run reads, which the
// run's own path starts inside. A path past `MAX_ERROR_STEPS` keeps its innermost steps.
@(private)
run_first :: proc(r: ^Run) -> core.Typed_Refusal {
	e := r.c.first
	if e.kind == .None || e.truncated {
		return e
	}
	outer: core.Typed_Refusal
	if s, has := r.step.?; has {
		path_add(&outer, s)
	}
	steps_of(r.parent, r.at, false, &outer, r.below)
	path_close(&outer)
	drop := max(int(outer.n_steps) + int(e.n_steps) - core.MAX_ERROR_STEPS, 0)
	out := e
	out.n_steps = 0
	out.truncated = drop > 0 || outer.truncated
	for x in outer.steps[min(drop, int(outer.n_steps)):outer.n_steps] {
		path_add(&out, x)
	}
	for x in e.steps[max(drop - int(outer.n_steps), 0):e.n_steps] {
		path_add(&out, x)
	}
	return out
}

// The close of a container in the held value, or of the held value, which gives back the registers past it.
@(private)
fork_close :: proc "contextless" (h: ^Check, f: ^Frame, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	fk := h.fork
	action := fork_token(h, t)
	if fk.open {
		h.sp += 1
		if action == .Next && fk.depth == 1 {
			if taken, took := fork_take(h, fk); took {
				return taken, .Next
			}
		}
		return fork_regs(h), action
	}
	return fk.next, action
}

// Hands the held container to its one live run when the value's verdict is that run's, as it stands between members:
// the run's frame of the value replaces the check's, and the check reads on by the run's records. The fork waits on
// `taken` for the value's close.
@(private)
fork_take :: proc "contextless" (h: ^Check, fk: ^Fork) -> (core.Hook_Regs, bool) {
	if !fk.takes || fk.waiting > 0 {
		return {}, false
	}
	live := fork_live(fk)
	if live < 0 {
		return {}, false
	}
	r := fk.arms[live].run
	if r.c.sp != 2 || r.c.fork != nil && r.c.fork.open || r.c.taken != nil || !fork_verdict(fk, live, true) || fork_verdict(fk, live, false) {
		return {}, false
	}
	context = h.ctx
	// The held object's keys go with its frame, so the check meets its repeats as the run would have. Under `.Notice` the
	// fork noted them in the run's place, and the check goes on from the names it met.
	notice := r.c.tracked == 0 && h.repeats == .Notice && fk.kind == .Object
	if notice && len(fk.names) > SEEN_SCAN {
		return {}, false
	}
	if r.c.tracked > 0 || notice {
		context.allocator = context.temp_allocator
		if h.tracked == len(h.trackers) {
			if _, grown := append(&h.trackers, Tracker{}); grown != nil {
				return {}, false
			}
		}
		t := &h.trackers[h.tracked]
		if r.c.tracked > 0 {
			t^, r.c.trackers[0] = r.c.trackers[0], t^
			r.c.tracked = 0
		} else {
			clear(&t.names)
			if len(t.keys) > 0 {
				clear(&t.keys)
			}
			clear(&t.spans)
			t.open, t.repeats = -1, 0
			for name in fk.names {
				// The fork's space goes back to the pool, so a name it decoded is copied.
				text := name
				cloned: runtime.Allocator_Error
				if !within(h.src, name) {
					text, cloned = strings.clone(name)
				}
				_, named := append(&t.names, text)
				_, grown := append(&t.spans, [2]u64{})
				if cloned != nil || named != nil || grown != nil {
					return {}, false
				}
			}
		}
		t.sp = fk.below
		h.tracked += 1
	}
	f := r.c.frames[1]
	f.c = fk.regs.c
	h.frames[fk.below] = f
	regs := r.regs
	readings_take(h, r)
	fk.taken = fk.arms[live].kind
	fork_release(h, fk)
	h.fork, fk.outer, h.taken = nil, h.taken, fk
	return regs, true
}

// The arm of the fork's one run that is neither done nor passing over the value, -1 for none, -2 for more than one.
@(private)
fork_live :: proc "contextless" (fk: ^Fork) -> int {
	live := -1
	for &x, i in fk.arms[:fk.n] {
		if x.run != nil && !x.run.done && x.run.skip == 0 {
			if live >= 0 {
				return -2
			}
			live = i
		}
	}
	return live
}

// The verdict of the fork's whole-value arms when its arm `live` passes as `assume` says and each other run that is not
// done passes.
@(private)
fork_verdict :: proc "contextless" (fk: ^Fork, live: int, assume: bool) -> bool {
	all, any, any_passed, ones, one := true, false, false, false, 0
	for &x, i in fk.arms[:fk.n] {
		passed := assume if i == live else !x.dead && (x.run == nil || !x.run.done)
		#partial switch x.kind {
		case .All:
			all &&= passed
		case .Any:
			any, any_passed = true, any_passed || passed
		case .One:
			ones, one = true, one + int(passed)
		}
	}
	return all && (!any || any_passed) && (!ones || one == 1)
}

// The close of a held container a run took over: judges it by the run's record, and gives back the registers past it.
@(private)
taken_close :: proc "contextless" (h: ^Check, f: ^Frame, owner: ^Field, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	fk := h.taken
	next := fk.next
	h.taken = nil
	_, action := check_close(h, f, owner, regs, t)
	h.taken = fk
	if h.first.kind != .None {
		taken_settle(h)
		return next, .Stop
	}
	h.taken, fk.outer, h.pool.forks = fk.outer, h.pool.forks, fk
	return next, action
}

// Ends the forks taken over in a check that failed. A failure inside an `anyOf` or `oneOf` arm that took its value over is
// that applicator's, at the outermost such value, and a repeat noticed inside one stays the check's, which reads it again.
@(private)
taken_settle :: proc "contextless" (c: ^Check) {
	if c.taken == nil {
		return
	}
	context = c.ctx
	top: ^Fork
	for fk := c.taken; fk != nil; fk = fk.outer {
		if fk.taken != .All {
			top = fk
		}
	}
	if top != nil && c.first.kind != .None && c.first.kind != .Walk && c.first.kind != .Duplicate_Key && c.fatal == .None {
		e := core.Typed_Refusal{kind = .No_Arm, at = top.lo}
		sp := c.sp
		c.sp = top.below
		path_of(c, top.regs, &e)
		c.sp, c.first = sp, e
	}
	for c.taken != nil {
		fk := c.taken
		c.taken, fk.outer, c.pool.forks = fk.outer, c.pool.forks, fk
	}
}

