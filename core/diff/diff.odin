// The value diff: the changes that turn one value into another, path by path, over documents of any format. Objects
// match by member name, arrays by sequence, by a key the caller names, as a set or by position. Equality is
// `core.equal`, so a number is its value and a member's order does not count.
package diff

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import core ".."

Op :: enum u8 {
	Added,
	Removed,
	Changed,
	// A fact of `role` on the node changed: a comment, an attribute.
	Fact,
}

// How the elements of two arrays are matched.
Arrays :: enum u8 {
	// The longest common subsequence of equal elements, so one inserted element is one change.
	Sequence,
	// Equal elements pair up wherever they stand, so a reordering is no change.
	Set,
	// The elements at one index pair up.
	Position,
}

// Elements of the array at `at` are matched by the value of their member `member`, and a pair that match are compared
// in depth. `at` holds names, indexes and `All`, and is empty for a root array.
Key_Rule :: struct {
	at:     []core.Step,
	member: string,
}

@(private)
DEFAULT_MAX_EDITS :: 1 << 12

// The steps of the searches for common subsequences that a whole diff makes, past which every array not yet matched is
// reported replaced.
@(private)
MAX_WORK :: 1 << 26

Options :: struct {
	arrays:     Arrays,
	keys:       []Key_Rule,
	// Facts count as changes when this is set. A fact counts only where both documents' formats carry its role.
	facts:      bool,
	// The most edits one array of `Sequence` reports, 4,096 for 0. An array past it is one change, the array replaced,
	// and the result is `truncated`, as it is when the arrays of a diff together take more than a fixed number of steps
	// to match.
	max_edits:  int,
}

// One change. `path` places it in the new value, and in the old one for a removal. `old_path` is the place in the old
// value of a change inside an array that moved its elements, and is `path` itself otherwise. `old` is absent for an
// addition and `new` for a removal. A fact change holds the facts' texts as strings.
Change :: struct {
	path:         []core.Step,
	old_path:     []core.Step,
	op:           Op,
	old, new:     core.Value,
	// The two values are of different kinds: null, boolean, number, string, array or object.
	kind_changed: bool,
	role:         core.Role,
}

// The changes in the order of the new value's walk. The steps and strings of a change live in `arena`.
Result :: struct {
	changes:   []Change,
	truncated: bool,
	// The indexes of the `Options.keys` that named no array present in both values.
	unused_keys: []int,
	arena:     virtual.Arena,
}

result_destroy :: proc(r: ^Result) {
	virtual.arena_destroy(&r.arena)
	r^ = {}
}

@(private)
Differ :: struct {
	opts:      Options,
	allocator: mem.Allocator,
	old, new:  [dynamic]core.Step,
	changes:   [dynamic]Change,
	truncated: bool,
	memos:    [dynamic]Memo,
	// The steps left for matching arrays.
	work:      int,
	// Whether each of `opts.keys` has named an array.
	named:     []bool,
}

// The changes from `a` to `b`, any values: nodes of documents, a built array among them. The scratch of the search is
// freed before the call returns.
values :: proc(a, b: core.Value, opts := Options{}) -> (r: Result, err: runtime.Allocator_Error) {
	virtual.arena_init_growing(&r.arena) or_return
	scratch: virtual.Arena
	if err = virtual.arena_init_growing(&scratch); err != nil {
		virtual.arena_destroy(&r.arena)
		return {}, err
	}
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	d := Differ {
		opts      = opts,
		allocator = virtual.arena_allocator(&r.arena),
		old       = make([dynamic]core.Step, context.temp_allocator),
		new       = make([dynamic]core.Step, context.temp_allocator),
		memos    = make([dynamic]Memo, context.temp_allocator),
		work      = MAX_WORK,
		named     = make([]bool, len(opts.keys), context.temp_allocator),
	}
	d.changes = make([dynamic]Change, d.allocator)
	if d.opts.max_edits <= 0 {
		d.opts.max_edits = DEFAULT_MAX_EDITS
	}
	walk(&d, a, b, 0)
	r.changes, r.truncated = d.changes[:], d.truncated
	unused := make([dynamic]int, d.allocator)
	for named, i in d.named {
		if !named {
			append(&unused, i)
		}
	}
	r.unused_keys = unused[:]
	return
}

@(private)
Class :: enum u8 {
	Null,
	Bool,
	Number,
	String,
	Array,
	Object,
}

@(private)
class_of :: proc(v: core.Value) -> Class {
	#partial switch core.kind(v) {
	case .False, .True:
		return .Bool
	case .Number:
		return .Number
	case .String, .Bytes, .Plain:
		return .String
	case .Array:
		return .Array
	case .Object:
		return .Object
	}
	return .Null
}

@(private)
walk :: proc(d: ^Differ, a, b: core.Value, depth: int) {
	ca, cb := class_of(a), class_of(b)
	if d.opts.facts {
		facts(d, a, b)
	}
	switch {
	case ca != cb:
		emit(d, .Changed, a, b, true)
	case ca == .Object && depth < core.MAX_DEPTH:
		if equal(d, a, b) && (!d.opts.facts || quiet(a, b)) {
			return
		}
		objects(d, a, b, depth)
	case ca == .Array && depth < core.MAX_DEPTH:
		key_rule(d, a)
		if equal(d, a, b) && (!d.opts.facts || quiet(a, b)) {
			return
		}
		arrays(d, a, b, depth)
	case !core.equal(a, b):
		emit(d, .Changed, a, b, false)
	}
}

// Adds a change at the current place. A removal is placed in the old value, the rest in the new one.
@(private)
emit :: proc(d: ^Differ, op: Op, a, b: core.Value, kind_changed: bool, role := core.Role.Value) {
	c := Change {
		op           = op,
		old          = a if op != .Added else nil,
		new          = b if op != .Removed else nil,
		kind_changed = kind_changed,
		role         = role,
	}
	if op == .Removed {
		c.path = core.steps_clone(d.old[:], d.allocator)
		c.old_path = c.path
	} else {
		c.path = core.steps_clone(d.new[:], d.allocator)
		c.old_path = c.path if op == .Added || slice.equal(d.old[:], d.new[:]) else core.steps_clone(d.old[:], d.allocator)
	}
	append(&d.changes, c)
}

@(private)
in_both :: proc(d: ^Differ, step_old, step_new: core.Step, then: proc(d: ^Differ, a, b: core.Value, depth: int), a, b: core.Value, depth: int) {
	append(&d.old, step_old)
	append(&d.new, step_new)
	then(d, a, b, depth + 1)
	pop(&d.old)
	pop(&d.new)
}

@(private)
objects :: proc(d: ^Differ, a, b: core.Value, depth: int) {
	names := make([dynamic]string, context.temp_allocator)
	seen := make(map[string]struct{}, context.temp_allocator)
	for v in ([2]core.Value{a, b}) {
		it := core.pairs(v)
		for key, _ in core.pair_next(&it) {
			if key not_in seen {
				seen[key] = {}
				append(&names, key)
			}
		}
	}
	for name in names {
		va, in_a := core.member(a, name)
		vb, in_b := core.member(b, name)
		step := core.Step(core.Name(name))
		switch {
		case in_a && in_b:
			in_both(d, step, step, walk, va, vb, depth)
		case in_a:
			append(&d.old, step)
			emit(d, .Removed, va, nil, false)
			pop(&d.old)
		case:
			append(&d.new, step)
			emit(d, .Added, nil, vb, false)
			pop(&d.new)
		}
	}
}

// The elements of array `v`.
@(private)
elements :: proc(v: core.Value) -> []core.Value {
	items := make([dynamic]core.Value, 0, core.length(v), context.temp_allocator)
	it := core.children(v)
	for e in core.child_next(&it) {
		append(&items, e)
	}
	return items[:]
}

@(private)
arrays :: proc(d: ^Differ, a, b: core.Value, depth: int) {
	xs, ys := elements(a), elements(b)
	rule, keyed := key_rule(d, a)
	switch {
	case keyed:
		matched(d, xs, ys, rule.member, depth)
	case d.opts.arrays == .Position:
		for i in 0 ..< max(len(xs), len(ys)) {
			pair(d, xs, ys, i if i < len(xs) else -1, i if i < len(ys) else -1, depth)
		}
	case d.opts.arrays == .Set:
		matched(d, xs, ys, "", depth)
	case:
		by_sequence(d, a, b, xs, ys, depth)
	}
}

// Reports element `i` of `xs` and element `j` of `ys`, which is -1 where an array has none: compared in depth when both
// stand, else removed or added.
@(private)
pair :: proc(d: ^Differ, xs, ys: []core.Value, i, j, depth: int) {
	switch {
	case i >= 0 && j >= 0:
		in_both(d, core.Index(i), core.Index(j), walk, xs[i], ys[j], depth)
	case i >= 0:
		append(&d.old, core.Index(i))
		emit(d, .Removed, xs[i], nil, false)
		pop(&d.old)
	case:
		append(&d.new, core.Index(j))
		emit(d, .Added, nil, ys[j], false)
		pop(&d.new)
	}
}

// The rule that names the key of the array `a` stands at: the path of the new value so far.
@(private)
key_rule :: proc(d: ^Differ, a: core.Value) -> (rule: Key_Rule, ok: bool) {
	for r, n in d.opts.keys {
		if len(r.at) != len(d.new) {
			continue
		}
		matches := true
		for s, i in r.at {
			switch x in s {
			case core.Name:
				name, named := d.new[i].(core.Name)
				matches &&= named && name == x
			case core.Index:
				index, indexed := d.new[i].(core.Index)
				matches &&= indexed && index == x
			case core.All:
				_, indexed := d.new[i].(core.Index)
				matches &&= indexed
			case core.Slice, core.Descend, core.Index_Or_Name:
				matches = false
			}
		}
		if matches {
			d.named[n] = true
			return r, true
		}
	}
	return
}

// Elements pair up by their `member`, or by themselves when `member` is "", the first unpaired of the old array that
// equals first. A pair of keyed elements is compared in depth, and a pair of equal elements only where facts are told. An
// element that has no `member` is paired like the rest of its kind: with an equal one first, and then the keyless that
// are left with each other by position. An order different between the arrays is no change.
@(private)
matched :: proc(d: ^Differ, xs, ys: []core.Value, member: string, depth: int) {
	// An element's key, and whether it has one: a missing member or an element that is no object has the element itself.
	key_of :: proc(e: core.Value, member: string) -> (key: core.Value, keyed: bool) {
		if member == "" {
			return e, false
		}
		v, found := core.member(e, member)
		return v if found else e, found
	}
	kx, ky := make([]core.Value, len(xs), context.temp_allocator), make([]core.Value, len(ys), context.temp_allocator)
	hx, hy := make([]bool, len(xs), context.temp_allocator), make([]bool, len(ys), context.temp_allocator)
	// The elements of one hash form a chain in order, from the head in `first` through `next`, and a taken one leaves it.
	// The keyed and the keyless chain apart.
	first := [2]map[u64]int{make(map[u64]int, len(xs), context.temp_allocator), make(map[u64]int, context.temp_allocator)}
	next := make([]int, len(xs), context.temp_allocator)
	for i := len(xs) - 1; i >= 0; i -= 1 {
		kx[i], hx[i] = key_of(xs[i], member)
		chain := &first[int(hx[i])]
		h := hash_of(d, kx[i])
		next[i] = chain[h] if h in chain else -1
		chain[h] = i
	}
	taken := make([]bool, len(xs), context.temp_allocator)
	partner := make([]int, len(ys), context.temp_allocator)
	exact := make([]bool, len(ys), context.temp_allocator)
	for y, j in ys {
		ky[j], hy[j] = key_of(y, member)
		h := hash_of(d, ky[j])
		chain := &first[int(hy[j])]
		partner[j] = -1
		prev := -1
		head, listed := chain[h]
		for i := head if listed else -1; i >= 0 && partner[j] < 0; i = next[i] {
			if !taken[i] && equal(d, kx[i], ky[j]) {
				partner[j], exact[j], taken[i] = i, !hy[j], true
				if prev < 0 {
					chain[h] = next[i]
				} else {
					next[prev] = next[i]
				}
			} else {
				prev = i
			}
		}
	}
	if member != "" {
		left := 0
		for j in 0 ..< len(ys) {
			if partner[j] >= 0 || hy[j] {
				continue
			}
			for left < len(xs) && (taken[left] || hx[left]) {
				left += 1
			}
			if left == len(xs) {
				break
			}
			partner[j], taken[left] = left, true
		}
	}
	for y, j in ys {
		if partner[j] >= 0 && exact[j] && !(d.opts.facts && !quiet(xs[partner[j]], y)) {
			continue
		}
		pair(d, xs, ys, partner[j], j, depth)
	}
	for _, i in xs {
		if !taken[i] {
			pair(d, xs, ys, i, -1, depth)
		}
	}
}

// Elements in the order of a longest common subsequence: a run of removed elements followed by a run of added ones is
// reported as changes of the first pairs, and a removal or addition for the rest.
@(private)
by_sequence :: proc(d: ^Differ, a, b: core.Value, xs, ys: []core.Value, depth: int) {
	removed, added, ok := edits(d, xs, ys)
	if !ok {
		d.truncated = true
		emit(d, .Changed, a, b, false)
		return
	}
	i, j := 0, 0
	for i < len(xs) || j < len(ys) {
		if i < len(xs) && j < len(ys) && !removed[i] && !added[j] {
			if d.opts.facts && !quiet(xs[i], ys[j]) {
				pair(d, xs, ys, i, j, depth)
			}
			i, j = i + 1, j + 1
			continue
		}
		lo_i, lo_j := i, j
		for i < len(xs) && removed[i] {
			i += 1
		}
		for j < len(ys) && added[j] {
			j += 1
		}
		if i == lo_i && j == lo_j {
			break
		}
		for k in 0 ..< max(i - lo_i, j - lo_j) {
			pair(d, xs, ys, lo_i + k if lo_i + k < i else -1, lo_j + k if lo_j + k < j else -1, depth)
		}
	}
}
