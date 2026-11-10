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
	// The arm's record, -1 for an arm that reads none, and the keyword steps to it from the held record.
	rec:      i32,
	site:     []core.Step,
	// The member name a `.Dependent` arm is keyed by, or a `.Pattern`'s expression.
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
}

// Whether a use of `n` with `edge` judges by arms.
@(private)
holds :: proc(b: ^Builder, d: ^rules.Description, node: rules.Node_Index, edge: rules.Rules) -> bool {
	n := &d.nodes[node]
	if len(n.any_of) > 0 || len(n.all_of) > 0 || len(n.one_of) > 0 || n.not != nil || n.ref != nil || n.dynamic_ref != nil || n.rules.unique || edge.unique || container_operands(n) {
		return true
	}
	if n.cond.test != nil && (n.cond.then != nil || n.cond.other != nil) || n.unevaluated_items != nil || n.unevaluated_properties != nil {
		return true
	}
	if n.object >= 0 && (len(d.objects[n.object].patterns) > 0 && n.object not_in b.inline || dependent_schemas(&d.objects[n.object])) {
		return true
	}
	return n.array >= 0 && d.arrays[n.array].contains != nil
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

// Whether `n`'s `const` or `enum` holds a container, which an arm compares, as a leaf compares only scalars.
@(private)
container_operands :: proc(n: ^rules.Node) -> bool {
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
		if _, failed := append(out, Apply{kind = kind, rec = arm_record(b, d, arena, node), site = steps}); failed != nil {
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
	for x, i in n.all_of {
		arm(b, d, arena, &out, .All, x, core.Name("allOf"), core.Index(i))
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
	if container_operands(&n) {
		// A `const` beside an `enum` is the enum narrowed to it, or to nothing when it is no member, as the leaf reads it.
		c, constant := n.const_of.?
		values := n.enum_of
		if constant {
			values = make([]core.Value, 1, arena)
			values[0] = c
			if n.has_enum && !equals_one(c, n.enum_of) {
				values = nil
			}
		}
		hashes: []u64
		values, hashes = by_hash(values, arena)
		append(&out, Apply{kind = .Equal, rec = -1, values = values, hashes = hashes, constant = constant && !n.has_enum})
	}
	if n.rules.unique || edge.unique {
		append(&out, Apply{kind = .Unique, rec = -1})
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
			if a := arm(b, d, arena, &out, .Additional, o.additional, core.Name("additionalProperties")); a != nil {
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
		if x, has := n.unevaluated_properties.?; has {
			if a := arm(b, d, arena, &out, .Unevaluated_Members, x, core.Name("unevaluatedProperties")); a != nil {
				a.eval = e
			}
		}
		if x, has := n.unevaluated_items.?; has {
			if a := arm(b, d, arena, &out, .Unevaluated_Items, x, core.Name("unevaluatedItems")); a != nil {
				a.eval = e
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
			append(&v, Apply{kind = kind, rec = verdict_record(b, d, arena, x)})
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
			append(&v, Apply{kind = .Not, rec = arm_record(b, d, arena, z)})
		}
		if z, has := y.cond.test.?; has && (y.cond.then != nil || y.cond.other != nil) {
			append(&v, Apply{kind = .If, rec = arm_record(b, d, arena, z)})
			if w, then := y.cond.then.?; then {
				append(&v, Apply{kind = .Then, rec = arm_record(b, d, arena, w)})
			}
			if w, other := y.cond.other.?; other {
				append(&v, Apply{kind = .Else, rec = arm_record(b, d, arena, w)})
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


// Whether `v` equals one of `values`. With their `hashes`, only the operands of `v`'s hash are compared, unless `v`
// holds a `Plain` node, whose hash is its kind's only as an operand reads it. What a comparison takes in `space` is taken back.
@(private)
equals_one :: proc(v: core.Value, values: []core.Value, hashes: []u64 = nil, space: ^mem.Arena = nil) -> bool {
	from := 0
	to := len(values)
	if hashes != nil && !holds_plain(v) {
		mark := space.offset if space != nil else 0
		h := core.hash(v)
		if space != nil {
			space.offset = mark
		}
		from, _ = slice.binary_search(hashes, h)
		for to = from; to < len(hashes) && hashes[to] == h; to += 1 {}
	}
	for x in values[from:to] {
		mark := space.offset if space != nil else 0
		equal := core.equal(v, x, read_plain = true)
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
	c:      Check,
	regs:   core.Hook_Regs,
	room:   int,
	skip:   int,
	done:   bool,
	parent: ^Check,
	at:     core.Hook_Regs,
	below:  int,
	site:   []core.Step,
	step:   Maybe(core.Step),
	// The failures of a run that reports only when its arm is chosen.
	buffer: Sink,
	next:   ^Run,
	frames: [8]Frame,
}

// The runs and forks of one check and of the runs inside it, in the temp allocator: those free for reuse and the count of
// runs made.
@(private)
Pool :: struct {
	free:  ^Run,
	forks: ^Fork,
	made:  int,
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
	count:      int,
	key:        string,
	holds:      bool,
	builder:    build.Builder,
	built:      core.Hook_Regs,
	scratch:    regex.Scratch,
	takes:      bool,
	taken:      Apply_Kind,
	outer:      ^Fork,
	space:      mem.Arena,
	marks:      [dynamic]bool,
	// The arms whose runs wait for the object's first member, its open token and first key, and the depth its runs nest at.
	waiting:    int,
	opened:     core.Token,
	first_key:  Maybe(core.Token),
	level:      int,
	// Whether an arm judges each member or element, which takes every value at depth one.
	per_member: bool,
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

// The bytes of a fork's space, which each held value's names, build and comparisons take from first.
@(private)
FORK_SPACE :: 1 << 16

// The arms whose verdict alone counts, which a kind they refuse or a failing first member decides with no run.
@(private)
VERDICT_ARMS :: bit_set[Apply_Kind]{.Any, .One, .Not, .If}

@(private)
WHOLE_ARMS :: bit_set[Apply_Kind]{.All, .Any, .One, .Not, .If, .Then, .Else, .Dependent}

@(private)
MEMBER_ARMS :: bit_set[Apply_Kind]{.Pattern, .Additional, .Contains, .Unevaluated_Members, .Unevaluated_Items}

// The arms whose failures are the held value's as they happen, and those whose failures wait until the arm is chosen.
@(private)
REPORTING :: bit_set[Apply_Kind]{.All, .Pattern, .Additional}

@(private)
BUFFERED :: bit_set[Apply_Kind]{.Then, .Else, .Dependent, .Unevaluated_Members, .Unevaluated_Items}

// The value `t` at a held record, or at the fork record inside a held value.
@(cold)
@(private)
fork_value :: #force_no_inline proc "contextless" (h: ^Check, regs, next: core.Hook_Regs, u: ^Use, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if raw_data(u.applies) != &FORKING[0] {
		if t.kind != .Object && t.kind != .Array {
			if passed, judged := scalar_verdict(h, u.verdict if h.sink == nil && u.verdict != nil else u.applies, t, 0); passed && judged {
				return next, .Next
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

// Whether the scalar `t` passes the arms `applies` by the leaves of their records and those records' own arms, and
// whether that judges it: not when an arm judges more than a scalar's leaves, which the fork then judges.
@(private)
scalar_verdict :: proc "contextless" (h: ^Check, applies: []Apply, t: core.Token, depth: int) -> (passed, judged: bool) {
	any, any_passed, ones, one, if_passed := false, false, false, 0, false
	for &a in applies {
		ok := true
		if a.kind in SCALAR_ARMS && a.eval == nil {
			if a.rec >= 0 {
				if ok, judged = record_passes(h, a.rec, t, depth); !judged {
					return
				}
			}
		} else if a.kind not_in OBJECT_ARRAY_ARMS {
			return false, false
		}
		switch a.kind {
		case .All:
			if !ok {
				return false, true
			}
		case .Any:
			any, any_passed = true, any_passed || ok
		case .One:
			ones, one = true, one + int(ok)
		case .Not:
			if ok {
				return false, true
			}
		case .If:
			if_passed = ok
		case .Then, .Else:
			if !ok && if_passed == (a.kind == .Then) {
				return false, true
			}
		case .Dependent, .Pattern, .Additional, .Contains, .Unique, .Equal, .Unevaluated_Members, .Unevaluated_Items:
		}
	}
	return (!any || any_passed) && (!ones || one == 1), true
}

// Whether the scalar `t` passes the record `rec`, and whether `scalar_verdict` judges that.
@(private)
record_passes :: proc "contextless" (h: ^Check, rec: i32, t: core.Token, depth: int) -> (passed, judged: bool) {
	fld := &h.plan.fields[rec]
	u := &h.plan.uses[fld.meta]
	if len(u.applies) > 0 {
		if depth == MAX_HELD || raw_data(u.applies) == &FORKING[0] {
			return false, false
		}
		if passed, judged = scalar_verdict(h, u.verdict if h.sink == nil && u.verdict != nil else u.applies, t, depth + 1); !passed || !judged {
			return
		}
	}
	if m := &h.plan.meta[fld.meta]; m.rule_set > 0 {
		l := &h.plan.leaves[m.rule_set - 1]
		return scalar_fails(h, plain_token(h, t, l) if t.kind == .Plain else t, l) == {}, true
	}
	return true, true
}

// The arms `scalar_verdict` judges a scalar by, and those a scalar passes as no object or array.
@(private)
SCALAR_ARMS :: bit_set[Apply_Kind]{.All, .Any, .One, .Not, .If, .Then, .Else}
@(private)
OBJECT_ARRAY_ARMS :: bit_set[Apply_Kind]{.Dependent, .Pattern, .Additional, .Contains, .Unique, .Unevaluated_Members, .Unevaluated_Items}

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
		h.fork = h.pool.forks
		if h.fork != nil {
			h.pool.forks = h.fork.outer
		} else if h.fork = new(Fork, context.temp_allocator); h.fork != nil {
			h.fork.arms.allocator, h.fork.names.allocator, h.fork.marks.allocator = context.temp_allocator, context.temp_allocator, context.temp_allocator
			temp_scratch(&h.fork.scratch)
		}
	}
	if h.pool == nil || h.fork == nil {
		return next, fork_fault(h, regs, .No_Memory, lo, hi)
	}
	fk := h.fork
	container := t.kind == .Object || t.kind == .Array
	fk.u, fk.regs, fk.next, fk.lo, fk.kind = u, regs, next, t.lo if container else lo, t.kind
	fk.depth, fk.below, fk.open, fk.n, fk.count, fk.key, fk.holds = 0, h.sp, true, 0, 0, "", false
	fk.takes, fk.outer = h.sink == nil && container, nil
	fk.waiting, fk.opened, fk.first_key, fk.level, fk.per_member = 0, t, nil, level, false
	clear(&fk.names)
	mem.arena_free_all(&fk.space)
	applies := u.verdict if h.sink == nil && u.verdict != nil else u.applies
	reserve(&fk.arms, len(applies))
	for &a in applies {
		fk.takes &&= a.kind <= .One && a.eval == nil
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
		// A record an arm already judges the value by answers the set's question.
		for &x in fk.arms[:fk.n] {
			if x.rec == rec && (x.kind == kind || kind == .Any && x.kind in WHOLE_ARMS) {
				return
			}
		}
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
	if a != nil && kind in VERDICT_ARMS && rec >= 0 {
		fld := &h.plan.fields[rec]
		m := &h.plan.meta[fld.meta]
		switch {
		case !kind_admits(h, m, t):
			x.dead = true
			return
		case t.kind == .Object && m.members > 0 && len(h.plan.uses[fld.meta].applies) == 0:
			x.waiting = true
			fk.waiting += 1
			return
		}
	}
	if kind in WHOLE_ARMS && rec >= 0 {
		x.run = run_start(h, fk, x, rec, level + 1, nil)
	}
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
	text, decoded := "", t.kind != .String
	if scalar && !decoded {
		text, decoded = decoded_text(h, t, buf[:])
	}
	for &x in fk.arms[:fk.n] {
		if !x.waiting {
			continue
		}
		x.waiting = false
		if scalar && decoded && fk.first_key != nil && member_fails(h, x.rec, fk.key, t, text) {
			x.dead = true
			continue
		}
		if x.run = run_start(h, fk, &x, x.rec, fk.level + 1, nil); x.run == nil {
			return .Stop
		}
		stopped := run_feed(h, x.run, fk.opened)
		if k, keyed := fk.first_key.?; keyed && !stopped {
			stopped = run_feed(h, x.run, k)
		}
		if stopped && arm_stopped(h, fk, &x) == .Stop {
			return .Stop
		}
	}
	fk.waiting = 0
	return .Next
}

// Whether the scalar `t`, the member `key` of an object, fails the leaf of that member's record in the object record
// `rec` by its kind or its enum. `text` is a string's decoded text. A number is left to the run.
@(private)
member_fails :: proc(h: ^Check, rec: i32, key: string, t: core.Token, text: string) -> bool {
	owner := &h.plan.fields[rec]
	i := member_index(h, owner, &h.plan.meta[owner.meta], key)
	if i < 0 {
		return false
	}
	fld := &([^]Field)(owner.first)[i]
	m := &h.plan.meta[fld.meta]
	if m.rule_set == 0 || len(h.plan.uses[fld.meta].applies) > 0 || t.kind == .Number || t.kind == .Plain {
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
	r := p.free
	if r != nil {
		p.free = r.next
	} else {
		if p.made == MAX_RUNS {
			h.fatal = .No_Memory
			return nil
		}
		if r = new(Run, context.temp_allocator); r == nil {
			h.fatal = .No_Memory
			return nil
		}
		p.made += 1
		r.c.home, r.room = raw_data(r.frames[:]), len(r.frames)
	}
	c := &r.c
	c.frames, c.sp = c.home, 1
	c.frames[0].seen = 0
	c.expect, c.borrow, c.first_key, c.refuse_unknown, c.wide, c.wrap_sp, c.wrap = h.expect, h.borrow, h.first_key, h.refuse_unknown, true, 0, nil
	c.view, c.plan, c.ctx, c.find_tag, c.format = h.view, h.plan, h.ctx, h.find_tag, h.format
	c.first, c.fatal, c.nest, c.pool, c.run, c.after, c.taken = {}, .None, nest, p, r, nil, nil
	c.sink = nil
	if h.sink != nil && x.apply != nil {
		switch {
		case x.kind in REPORTING:
			c.sink = h.sink
		case x.kind in BUFFERED:
			if step == nil {
				c.sink = &r.buffer
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
		}
	}
	r.regs = {NO_LIMIT, u64(uintptr(&([^]Field)(raw_data(h.plan.fields))[rec + 1])), 0}
	r.skip, r.done = 0, false
	r.parent, r.at, r.below, r.step = h, fk.regs, fk.below, step
	r.site = x.apply.site if x.apply != nil else nil
	return r
}

// Gives the run back to the pool, with the fork open in it.
@(private)
run_free :: proc(h: ^Check, r: ^Run) {
	if r.c.fork != nil && r.c.fork.open {
		fork_release(&r.c, r.c.fork)
	}
	clear(&r.buffer.entries)
	r.buffer.truncated = false
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

// Hands `t`, a token of the held value, to each live run, and to the value's build. Starts the runs of a member or an
// element as it opens and ends them as it closes, and judges the value by its arms as it closes.
@(cold)
@(private)
fork_token :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token) -> core.Action {
	context = h.ctx
	fk := h.fork
	value := t.role == .Value
	open := value && (t.kind == .Object || t.kind == .Array)
	end := value && t.kind == .End
	if fk.waiting > 0 && value && fk.depth == 1 && fork_wake(h, fk, t) == .Stop {
		fork_release(h, fk)
		return .Stop
	}
	if value && !end && fk.depth == 1 {
		member_start(h, fk)
	}
	for &x in fk.arms[:fk.n] {
		if x.run == nil {
			continue
		}
		stopped := run_feed(h, x.run, t)
		// A run that reports to the check's sink reports its failures as the check's, the first among them.
		if h.first.kind == .None && h.sink != nil && x.run.c.sink == h.sink {
			h.first = x.run.c.first
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
		return .Skip
	}
	if open {
		fk.depth += 1
	} else if end {
		fk.depth -= 1
	}
	switch {
	case t.role == .Key && fk.depth == 1:
		key, ok := core.token_text(h.plan.readers, &h.view, t, fork_space(fk))
		if _, failed := append(&fk.names, key); !ok || failed != nil {
			fork_release(h, fk)
			return fork_fault(h, fk.regs, .No_Memory, fk.lo, fk.lo)
		}
		fk.key = key
		if fk.first_key == nil {
			fk.first_key = t
		}
	case value && fk.depth == 1 && !open:
		member_end(h, fk)
	case fk.depth == 0:
		_, hi := core.scalar_ends(t)
		return fork_finish(h, fk, hi)
	}
	if h.fatal != .None {
		fork_release(h, fk)
		return fork_fault(h, fk.regs, h.fatal, fk.lo, fk.lo)
	}
	if t.role == .Key && fork_passes_over(fk, t) {
		return .Skip
	}
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
// reports elsewhere, and a failure of an arm that reports stops a check with no sink.
@(private)
arm_stopped :: proc(h: ^Check, fk: ^Fork, x: ^Arm_Run) -> core.Action {
	r := x.run
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
			h.first = r.c.first
		}
		return .Stop
	}
	return .Next
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

// Starts the runs of the member or element that opens at the held value's depth 1, for each arm that judges it.
@(private)
member_start :: proc(h: ^Check, fk: ^Fork) {
	array := fk.kind == .Array
	step := core.Step(core.Index(fk.count)) if array else core.Step(core.Name(fk.key))
	fk.count += 1
	for &x in fk.arms[:fk.n] {
		if x.kind not_in MEMBER_ARMS || array != (x.kind == .Contains || x.kind == .Unevaluated_Items) || x.rec < 0 {
			continue
		}
		if x.kind == .Pattern && !matches(x.apply.pattern, fk.key, &fk.scratch) || x.kind == .Additional && !additional(fk, x.apply, fk.key) {
			continue
		}
		x.run = run_start(h, fk, &x, x.rec, 0, step)
	}
}

// Ends the runs of the member or element that closed, keeping what each arm counts of it.
@(private)
member_end :: proc(h: ^Check, fk: ^Fork) {
	for &x in fk.arms[:fk.n] {
		if x.run == nil || x.kind not_in MEMBER_ARMS {
			continue
		}
		first := x.run.c.first
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
				h.first = first
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
				h.first = x.run.c.first
			}
		case .Any:
			any, any_passed = true, any_passed || x.passed
		case .One:
			ones, one = true, one + int(x.passed)
		case .Not:
			if x.passed {
				fork_note(h, fk, .Not_Allowed, hi, "not")
			}
		case .If:
			if_passed = x.passed
		case .Then, .Else:
			if if_passed == (a.kind == .Then) && x.run != nil {
				fork_deliver(h, x.run, x.run.buffer.entries[:])
			}
		case .Dependent:
			if fk.kind == .Object && x.run != nil && named(fk.names[:], a.name) {
				fork_deliver(h, x.run, x.run.buffer.entries[:])
			}
		case .Equal:
			context.allocator = fork_space(fk)
			if !equals_one(core.Node_Ref{&doc, core.ROOT}, a.values, a.hashes, &fk.space) {
				fork_note(h, fk, .Not_A_Member, hi, "const" if a.constant else "enum")
			}
		case .Unique:
			if fk.kind == .Array && !unique(&doc, fork_space(fk)) {
				fork_note(h, fk, .Not_Unique, hi, "uniqueItems")
			}
		case .Contains:
			switch {
			case fk.kind != .Array:
			case x.count < a.min:
				fork_note(h, fk, .Too_Few, hi, "contains" if a.min == 1 else "minContains")
			case x.count > a.max:
				fork_note(h, fk, .Too_Many, hi, "maxContains")
			}
		case .Unevaluated_Members, .Unevaluated_Items:
			if fk.kind == (.Array if a.kind == .Unevaluated_Items else .Object) {
				fork_unevaluated(h, fk, &x)
			}
		case .Pattern, .Additional:
		}
	}
	if any && !any_passed {
		fork_note(h, fk, .No_Arm, hi, "anyOf")
	}
	if ones && one != 1 {
		fork_note(h, fk, .No_Arm if one == 0 else .Many_Arms, hi, "oneOf")
	}
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
	first := first if r == nil else r.c.first
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
	if r != nil && r.buffer.truncated {
		c.truncated = true
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
// space is taken from the temp allocator at its first use, since the temp allocator clears what it gave at its reset.
@(private)
fork_space :: proc(fk: ^Fork) -> runtime.Allocator {
	space :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
		fk := (^Fork)(data)
		if fk.space.data == nil && mode != .Free && mode != .Free_All {
			if block, failed := runtime.mem_alloc_non_zeroed(FORK_SPACE, allocator = context.temp_allocator); failed == nil {
				mem.arena_init(&fk.space, block)
			}
		}
		return spill_proc(&fk.space, mode, size, alignment, old, old_size, loc)
	}
	return {space, fk}
}

// Gives back the fork's runs.
@(private)
fork_release :: proc(h: ^Check, fk: ^Fork) {
	for &x in fk.arms[:fk.n] {
		if x.run != nil {
			run_free(h, x.run)
			x.run = nil
		}
	}
	fk.n, fk.open = 0, false
}

// Whether no two elements of the root array of `doc` are equal, comparing those whose hashes agree.
@(private)
unique :: proc(doc: ^core.Document, allocator: runtime.Allocator) -> bool {
	context.allocator = allocator
	Hashed :: struct {
		hash: u64,
		node: core.Node_Index,
	}
	all := make([dynamic]Hashed)
	it := core.doc_children(doc, core.ROOT)
	for x in core.doc_child_next(&it) {
		append(&all, Hashed{core.hash(core.Node_Ref{doc, x}), x})
	}
	slice.sort_by(all[:], proc(a, b: Hashed) -> bool {return a.hash < b.hash})
	for i in 0 ..< len(all) {
		for j := i + 1; j < len(all) && all[j].hash == all[i].hash; j += 1 {
			if core.equal(core.Node_Ref{doc, all[i].node}, core.Node_Ref{doc, all[j].node}, read_plain = true) {
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
	f := r.c.frames[1]
	f.c = fk.regs.c
	h.frames[fk.below] = f
	regs := r.regs
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
// that applicator's, at the outermost such value.
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
	if top != nil && c.first.kind != .None && c.first.kind != .Walk && c.fatal == .None {
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

