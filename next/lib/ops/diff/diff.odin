package diff

import "base:runtime"
import "core:mem"
import "core:strings"
import "stury:lib/core/tape"

// Structural diff over `tape.Document` values of any format. Objects match by decoded member key, arrays by Myers LCS
// sequence, keyed member, unordered set (`Arrays.Set` / `ignore_order`), or position. All tree traversals, hashing,
// equality, and sequence LCS use explicit heap stacks (zero native recursion) and `mem.Dynamic_Arena` (no virtual mem).

Op :: enum u8 {
	Added,
	Removed,
	Changed,
	Fact,
}

// How the elements of two arrays are matched.
Arrays :: enum u8 {
	Sequence, // Myers LCS of equal elements
	Set,      // Unordered multiset matching (reordering is no change)
	Position, // Pair elements by identical index
}

// Match elements of the array at `at` by the value of their member `member`.
// `at` holds `tape.Name`, `tape.Index`, and `tape.All`; empty matches a root array.
Key_Rule :: struct {
	at:     []tape.Step,
	member: string,
}

@(private)
DEFAULT_MAX_EDITS :: 1 << 12

@(private)
MAX_WORK :: 1 << 26

Options :: struct {
	arrays:       Arrays,
	ignore_order: bool, // shorthand for `arrays = .Set` when `arrays == .Sequence`
	keys:         []Key_Rule,
	facts:        bool, // compare comments, tags, anchors, attributes carried by both formats
	max_edits:    int,  // per-array Myers edit cap; 0 defaults to 4096
	max_changes:  int,  // stop after this many emitted changes; 0 for unlimited
	max_depth:    int,  // max nesting depth; 0 defaults to `tape.DEFAULT_DEPTH`
}

// One structural or fact change between two documents.
// `path` places it in `b` (or in `a` for `.Removed`). `old_path` places it in `a` when an array moved elements, and
// aliases `path` otherwise. `old_node` / `new_node` reference nodes in `a` / `b` (`tape.NO_NODE` when absent).
Change :: struct {
	path:         []tape.Step,
	old_path:     []tape.Step,
	op:           Op,
	old_node:     tape.Node_Index,
	new_node:     tape.Node_Index,
	old_text:     string,
	new_text:     string,
	kind_changed: bool,
	fact_kind:    tape.Fact_Kind,
}

// The result of `diff_documents`. All steps and strings live in `arena`; free with `destroy_result`.
Result :: struct {
	changes:     []Change,
	truncated:   bool,
	too_deep:    bool,
	unused_keys: []int,
	arena:       ^mem.Dynamic_Arena,
}

Error :: runtime.Allocator_Error

destroy_result :: proc(r: ^Result) {
	if r == nil {
		return
	}
	if r.arena != nil {
		alloc := r.arena.block_allocator
		mem.dynamic_arena_destroy(r.arena)
		free(r.arena, alloc)
	}
	r^ = {}
}

@(private)
Differ :: struct {
	opts:      Options,
	docs:      [2]^tape.Document,
	indexes:   [2]tape.Doc_Index,
	readers:   [2]tape.Reader,
	hashes:    [2][]u64,
	carries:   [2][len(FACT_KINDS)]bool,
	allocator: runtime.Allocator,
	scratch:   runtime.Allocator,
	old, new:  [dynamic]tape.Step,
	changes:   [dynamic]Change,
	truncated: bool,
	too_deep:  bool,
	work:      int,
	named:     []bool,
}

@(private = "file")
Walk_Task_Kind :: enum u8 {
	Compare,
	Pop,
}

@(private = "file")
Walk_Task :: struct {
	kind:     Walk_Task_Kind,
	a, b:     Val,
	has_old:  bool,
	has_new:  bool,
	old_step: tape.Step,
	new_step: tape.Step,
	depth:    int,
}

@(private)
init_differ :: proc(d: ^Differ, a, b: ^tape.Document, opts: Options, out_alloc, scratch_alloc: runtime.Allocator) -> Error {
	d^ = {
		opts      = opts,
		docs      = {a, b},
		allocator = out_alloc,
		scratch   = scratch_alloc,
		work      = MAX_WORK,
	}
	if d.opts.ignore_order && d.opts.arrays == .Sequence {
		d.opts.arrays = .Set
	}
	if d.opts.max_edits <= 0 {
		d.opts.max_edits = DEFAULT_MAX_EDITS
	}
	if d.opts.max_depth <= 0 {
		d.opts.max_depth = tape.DEFAULT_DEPTH
	}
	for side in 0 ..< 2 {
		d.indexes[side] = {allocator = scratch_alloc}
		d.readers[side] = {doc = d.docs[side], index = &d.indexes[side]}
		d.hashes[side] = make([]u64, len(d.docs[side].nodes), scratch_alloc) or_return
		for kind, i in FACT_KINDS {
			d.carries[side][i] = doc_carries(d.docs[side], kind)
		}
	}
	d.old = make([dynamic]tape.Step, 0, 16, scratch_alloc) or_return
	d.new = make([dynamic]tape.Step, 0, 16, scratch_alloc) or_return
	d.changes = make([dynamic]Change, 0, 16, out_alloc) or_return
	d.named = make([]bool, len(opts.keys), scratch_alloc) or_return
	return nil
}

@(private)
destroy_differ :: proc(d: ^Differ) {
	tape.destroy_index(&d.indexes[0])
	tape.destroy_index(&d.indexes[1])
}

// Computes the structural diff turning document `a` into document `b`.
@(require_results)
diff_documents :: proc(a, b: ^tape.Document, opts := Options{}, allocator := context.allocator) -> (r: Result, err: Error) {
	if a == nil || b == nil {
		return {}, nil
	}
	r.arena = new(mem.Dynamic_Arena, allocator) or_return
	mem.dynamic_arena_init(r.arena, allocator, allocator)
	defer if err != nil {
		destroy_result(&r)
	}
	out_alloc := mem.dynamic_arena_allocator(r.arena)
	scratch_arena := new(mem.Dynamic_Arena, allocator) or_return
	mem.dynamic_arena_init(scratch_arena, allocator, allocator)
	defer {
		mem.dynamic_arena_destroy(scratch_arena)
		free(scratch_arena, allocator)
	}
	scratch_alloc := mem.dynamic_arena_allocator(scratch_arena)

	d: Differ
	init_differ(&d, a, b, opts, out_alloc, scratch_alloc) or_return
	defer destroy_differ(&d)

	ra, pa := tape.root(d.readers[0])
	rb, pb := tape.root(d.readers[1])
	switch {
	case pa != .Found && pb != .Found:
		// Both empty.
	case pa != .Found:
		emit_change(&d, .Added, tape.NO_NODE, rb, false) or_return
	case pb != .Found:
		emit_change(&d, .Removed, ra, tape.NO_NODE, false) or_return
	case:
		walk_diff(&d, ra, rb) or_return
	}

	r.changes = d.changes[:]
	r.truncated = d.truncated
	r.too_deep = d.too_deep
	unused := make([dynamic]int, out_alloc)
	for named, i in d.named {
		if !named {
			append(&unused, i) or_return
		}
	}
	r.unused_keys = unused[:]
	return r, nil
}

@(private = "file")
walk_diff :: proc(d: ^Differ, root_a, root_b: tape.Node_Index) -> Error {
	stack := make([dynamic]Walk_Task, 0, 32, d.scratch) or_return
	defer delete(stack)
	append(&stack, Walk_Task{kind = .Compare, a = val_node(root_a), b = val_node(root_b), depth = 0}) or_return

	for len(stack) > 0 {
		task := pop(&stack)
		if task.kind == .Pop {
			if task.has_old {
				pop(&d.old)
			}
			if task.has_new {
				pop(&d.new)
			}
			continue
		}
		if d.too_deep {
			return nil
		}
		if d.opts.max_changes > 0 && len(d.changes) >= d.opts.max_changes {
			d.truncated = true
			return nil
		}
		if task.has_old || task.has_new {
			append(&stack, Walk_Task{kind = .Pop, has_old = task.has_old, has_new = task.has_new}) or_return
			if task.has_old {
				append(&d.old, task.old_step) or_return
			}
			if task.has_new {
				append(&d.new, task.new_step) or_return
			}
		}

		if !val_empty(task.a) && val_empty(task.b) {
			emit_change(d, .Removed, val_first_node(task.a), tape.NO_NODE, false) or_return
			continue
		}
		if val_empty(task.a) && !val_empty(task.b) {
			emit_change(d, .Added, tape.NO_NODE, val_first_node(task.b), false) or_return
			continue
		}

		a, b, depth := task.a, task.b, task.depth
		ca, cb := val_class(d.docs[0], a), val_class(d.docs[1], b)
		if d.opts.facts && len(a.group) == 0 && len(b.group) == 0 {
			diff_facts(d, a.node, b.node) or_return
		}
		switch {
		case ca != cb:
			emit_change(d, .Changed, val_first_node(a), val_first_node(b), true) or_return
		case ca == .Object && depth < d.opts.max_depth:
			if vals_equal(d, a, b, depth) && (!d.opts.facts || quiet_val(d, a, b)) {
				continue
			}
			if d.too_deep {
				return nil
			}
			push_object_tasks(d, &stack, a.node, b.node, depth) or_return
		case ca == .Array && depth < d.opts.max_depth:
			_, _ = match_key_rule(d)
			if vals_equal(d, a, b, depth) && (!d.opts.facts || quiet_val(d, a, b)) {
				continue
			}
			if d.too_deep {
				return nil
			}
			push_array_tasks(d, &stack, a, b, depth) or_return
		case !vals_equal_exact(d, a, b, depth):
			emit_change(d, .Changed, val_first_node(a), val_first_node(b), false) or_return
		}
	}
	return nil
}

@(private)
emit_change :: proc(d: ^Differ, op: Op, a, b: tape.Node_Index, kind_changed: bool) -> Error {
	if d.opts.max_changes > 0 && len(d.changes) >= d.opts.max_changes {
		d.truncated = true
		return nil
	}
	c := Change {
		op           = op,
		old_node     = a if op != .Added else tape.NO_NODE,
		new_node     = b if op != .Removed else tape.NO_NODE,
		kind_changed = kind_changed,
	}
	if op == .Removed {
		c.path = clone_steps(d.old[:], d.allocator) or_return
		c.old_path = c.path
	} else {
		c.path = clone_steps(d.new[:], d.allocator) or_return
		if op == .Added || tape.steps_equal(d.old[:], d.new[:]) {
			c.old_path = c.path
		} else {
			c.old_path = clone_steps(d.old[:], d.allocator) or_return
		}
	}
	append(&d.changes, c) or_return
	return nil
}

@(private)
emit_fact :: proc(d: ^Differ, old_text, new_text: string, kind: tape.Fact_Kind) -> Error {
	if d.opts.max_changes > 0 && len(d.changes) >= d.opts.max_changes {
		d.truncated = true
		return nil
	}
	p := clone_steps(d.new[:], d.allocator) or_return
	op := p
	if !tape.steps_equal(d.old[:], d.new[:]) {
		op = clone_steps(d.old[:], d.allocator) or_return
	}
	append(&d.changes, Change {
		path      = p,
		old_path  = op,
		op        = .Fact,
		old_node  = tape.NO_NODE,
		new_node  = tape.NO_NODE,
		old_text  = old_text,
		new_text  = new_text,
		fact_kind = kind,
	}) or_return
	return nil
}

@(private)
clone_steps :: proc(steps: []tape.Step, alloc: runtime.Allocator) -> (out: []tape.Step, err: Error) {
	if len(steps) == 0 {
		return nil, nil
	}
	out = make([]tape.Step, len(steps), alloc) or_return
	for s, i in steps {
		if name, is_name := s.(tape.Name); is_name {
			cloned := strings.clone(string(name), alloc) or_return
			out[i] = tape.Name(cloned)
		} else {
			out[i] = s
		}
	}
	return out, nil
}

// Collects distinct member keys of object `a` then `b` in text order into `d.scratch`.
@(private)
collect_object_names :: proc(d: ^Differ, a, b: tape.Node_Index) -> (res: []string, err: Error) {
	names := make([dynamic]string, d.scratch)
	seen := make(map[string]struct{}, 16, d.scratch) or_return
	nodes := [2]tape.Node_Index{a, b}
	for side in 0 ..< 2 {
		c, p, cerr := tape.children(d.readers[side], nodes[side], d.scratch)
		if cerr != nil {
			return nil, cerr
		}
		if p != .Found {
			continue
		}
		defer tape.destroy_children(&c)
		dups := tape.Duplicates.First if is_grouped(d.docs[side]) else tape.Duplicates.Default
		for {
			kn, _, np := tape.next_child(d.readers[side], &c, dups)
			if np != .Found {
				break
			}
			buf: [256]u8
			ks, owned, ok := read_member_key(d, side, c, kn, buf[:])
			if !ok {
				if owned != nil {
					delete(owned, d.scratch)
				}
				continue
			}
			if ks not_in seen {
				kept := string(owned) if owned != nil else (strings.clone(ks, d.scratch) or_return)
				seen[kept] = {}
				append(&names, kept) or_return
			} else if owned != nil {
				delete(owned, d.scratch)
			}
		}
	}
	return names[:], nil
}

// Collects distinct member keys of object `a` then `b` (in text order) and schedules child tasks in reverse for LIFO.
@(private = "file")
push_object_tasks :: proc(d: ^Differ, stack: ^[dynamic]Walk_Task, a, b: tape.Node_Index, depth: int) -> Error {
	names := collect_object_names(d, a, b) or_return
	#reverse for name in names {
		va, in_a := member_val(d, 0, a, name) or_return
		vb, in_b := member_val(d, 1, b, name) or_return
		step := tape.Step(tape.Name(name))
		append(stack, Walk_Task {
			kind     = .Compare,
			a        = va if in_a else val_node(tape.NO_NODE),
			b        = vb if in_b else val_node(tape.NO_NODE),
			has_old  = in_a,
			has_new  = in_b,
			old_step = step,
			new_step = step,
			depth    = depth + 1,
		}) or_return
	}
	return nil
}

@(private)
val_elements :: proc(d: ^Differ, side: int, v: Val) -> ([]tape.Node_Index, Error) {
	if len(v.group) > 0 {
		return v.group, nil
	}
	return collect_elements(d, side, v.node)
}

@(private)
collect_elements :: proc(d: ^Differ, side: int, at: tape.Node_Index) -> (res: []tape.Node_Index, err: Error) {
	n, _, lerr := tape.length(d.readers[side], at, d.scratch)
	if lerr != nil {
		return nil, lerr
	}
	items := make([dynamic]tape.Node_Index, 0, max(n, 0), d.scratch) or_return
	c, p, cerr := tape.children(d.readers[side], at, d.scratch)
	if cerr != nil {
		return nil, cerr
	}
	if p != .Found {
		return nil, nil
	}
	defer tape.destroy_children(&c)
	for {
		_, v, np := tape.next_child(d.readers[side], &c)
		if np != .Found {
			break
		}
		append(&items, v) or_return
	}
	return items[:], nil
}

@(private = "file")
push_array_tasks :: proc(d: ^Differ, stack: ^[dynamic]Walk_Task, a, b: Val, depth: int) -> Error {
	xs := val_elements(d, 0, a) or_return
	ys := val_elements(d, 1, b) or_return
	rule, keyed := match_key_rule(d)

	Pair :: struct {
		i, j: int,
	}
	pairs := make([dynamic]Pair, 0, max(len(xs), len(ys)), d.scratch) or_return

	switch {
	case keyed:
		collect_matched(d, xs, ys, rule.member, depth, &pairs) or_return
	case d.opts.arrays == .Position:
		for i in 0 ..< max(len(xs), len(ys)) {
			append(&pairs, Pair{i if i < len(xs) else -1, i if i < len(ys) else -1}) or_return
		}
	case d.opts.arrays == .Set:
		collect_matched(d, xs, ys, "", depth, &pairs) or_return
	case:
		removed, added, ok := sequence_edits(d, xs, ys, depth) or_return
		if !ok {
			d.truncated = true
			emit_change(d, .Changed, val_first_node(a), val_first_node(b), false) or_return
			return nil
		}
		i, j := 0, 0
		for i < len(xs) || j < len(ys) {
			if i < len(xs) && j < len(ys) && !removed[i] && !added[j] {
				if d.opts.facts && !quiet(d, xs[i], ys[j]) {
					append(&pairs, Pair{i, j}) or_return
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
				append(&pairs, Pair {
					lo_i + k if lo_i + k < i else -1,
					lo_j + k if lo_j + k < j else -1,
				}) or_return
			}
		}
	}

	#reverse for pr in pairs {
		in_a, in_b := pr.i >= 0, pr.j >= 0
		append(stack, Walk_Task {
			kind     = .Compare,
			a        = val_node(xs[pr.i] if in_a else tape.NO_NODE),
			b        = val_node(ys[pr.j] if in_b else tape.NO_NODE),
			has_old  = in_a,
			has_new  = in_b,
			old_step = tape.Index(pr.i) if in_a else tape.Index(0),
			new_step = tape.Index(pr.j) if in_b else tape.Index(0),
			depth    = depth + 1,
		}) or_return
	}
	return nil
}

@(private = "file")
match_key_rule :: proc(d: ^Differ) -> (rule: Key_Rule, ok: bool) {
	next: for r, n in d.opts.keys {
		if len(r.at) != len(d.new) {
			continue
		}
		for s, i in r.at {
			_, all := s.(tape.All)
			_, indexed := d.new[i].(tape.Index)
			if !(all && indexed) && !tape.step_equal(s, d.new[i]) {
				continue next
			}
		}
		d.named[n] = true
		return r, true
	}
	return
}

@(private = "file")
collect_matched :: proc(d: ^Differ, xs, ys: []tape.Node_Index, member: string, depth: int, pairs: ^$P) -> Error {
	key_of :: proc(d: ^Differ, side: int, e: tape.Node_Index, member: string) -> (key: Val, keyed: bool, err: Error) {
		if member == "" {
			return val_node(e), false, nil
		}
		v, found := member_val(d, side, e, member) or_return
		return v if found else val_node(e), found, nil
	}
	kx := make([]Val, len(xs), d.scratch) or_return
	ky := make([]Val, len(ys), d.scratch) or_return
	hx := make([]bool, len(xs), d.scratch) or_return
	hy := make([]bool, len(ys), d.scratch) or_return
	f0 := make(map[u64]int, len(xs), d.scratch) or_return
	f1 := make(map[u64]int, 0, d.scratch) or_return
	first := [2]map[u64]int{f0, f1}
	next := make([]int, len(xs), d.scratch) or_return
	for i := len(xs) - 1; i >= 0; i -= 1 {
		kx[i], hx[i] = key_of(d, 0, xs[i], member) or_return
		chain := &first[int(hx[i])]
		h := hash_val(d, 0, kx[i], depth + 1)
		next[i] = chain[h] if h in chain else -1
		chain[h] = i
	}
	taken := make([]bool, len(xs), d.scratch) or_return
	partner := make([]int, len(ys), d.scratch) or_return
	exact := make([]bool, len(ys), d.scratch) or_return
	for y, j in ys {
		ky[j], hy[j] = key_of(d, 1, y, member) or_return
		h := hash_val(d, 1, ky[j], depth + 1)
		chain := &first[int(hy[j])]
		partner[j] = -1
		prev := -1
		head, listed := chain[h]
		for i := head if listed else -1; i >= 0 && partner[j] < 0; i = next[i] {
			if !taken[i] && vals_equal(d, kx[i], ky[j], depth + 1) {
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
		if partner[j] >= 0 && exact[j] && !(d.opts.facts && !quiet(d, xs[partner[j]], y)) {
			continue
		}
		append(pairs, type_of(pairs[0]){partner[j], j}) or_return
	}
	for _, i in xs {
		if !taken[i] {
			append(pairs, type_of(pairs[0]){i, -1}) or_return
		}
	}
	return nil
}
