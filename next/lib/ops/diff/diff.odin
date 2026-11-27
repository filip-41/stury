package diff

import "base:runtime"
import "core:mem"
import "core:strings"
import "stury:lib/core/tape"

// Structural diff over `tape.Document` values of any format. Objects match by decoded member key, arrays by Myers LCS
// sequence, keyed member, unordered set (`Arrays.Set`), or position. All tree traversals, hashing, equality, and
// sequence LCS use explicit heap stacks (zero native recursion) and `mem.Dynamic_Arena` (no virtual mem).

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

@(private = "file")
DEFAULT_MAX_EDITS :: 1 << 12

@(private = "file")
MAX_WORK :: 1 << 26

Options :: struct {
	keys:        []Key_Rule,
	max_edits:   int,    // per-array Myers edit cap; <= 0 defaults to `DEFAULT_MAX_EDITS`
	max_changes: int,    // stop after this many emitted changes; <= 0 for unlimited
	max_depth:   int,    // max nesting depth; <= 0 defaults to `tape.DEFAULT_DEPTH`
	arrays:      Arrays,
	facts:       bool,   // compare comments, tags, anchors, attributes carried by both formats
}

when size_of(int) == 8 {
	#assert(size_of(Options) == 48)
}

// One structural or fact change between two documents.
// `path` places it in `b` (or in `a` for `.Removed`). `old_path` places it in `a` when an array moved elements, and
// aliases `path` otherwise. `old_node` / `new_node` reference nodes in `a` / `b` (`tape.NO_NODE` when absent).
Change :: struct {
	path:         []tape.Step,
	old_path:     []tape.Step,
	old_text:     string,
	new_text:     string,
	old_node:     tape.Node_Index,
	new_node:     tape.Node_Index,
	op:           Op,
	kind_changed: bool,
	fact_kind:    tape.Fact_Kind,
}

when size_of(int) == 8 {
	#assert(size_of(Change) == 80)
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
	destroy_arena(&r.arena)
	r^ = {}
}

// Wraps `Differ.scratch_arena` so OOM anywhere inside non-error-returning hot paths (`hash_node`, `vals_equal_exact`,
// `scalars_equal`, map inserts) latches `failed` without adding error branches to the hot loops.
@(private)
Scratch_Gate :: struct {
	inner:  runtime.Allocator,
	failed: bool,
}

@(private = "file")
scratch_gate_allocator :: proc "contextless" (g: ^Scratch_Gate) -> runtime.Allocator {
	return {procedure = scratch_gate_proc, data = g}
}

@(private = "file")
scratch_gate_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_ptr: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	g := (^Scratch_Gate)(data)
	res, err := g.inner.procedure(g.inner.data, mode, size, alignment, old_ptr, old_size, loc)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if err != nil || (size > 0 && len(res) < size) {
			g.failed = true
			return nil, err if err != nil else .Out_Of_Memory
		}
	}
	return res, err
}

@(private)
Differ :: struct {
	opts:          Options,
	docs:          [2]^tape.Document,
	indexes:       [2]tape.Doc_Index,
	readers:       [2]tape.Reader,
	hashes:        [2][]u64,
	scratch_arena: mem.Dynamic_Arena,
	scratch_gate:  Scratch_Gate,
	allocator:     runtime.Allocator,
	scratch:       runtime.Allocator,
	old, new:      [dynamic]tape.Step,
	changes:       [dynamic]Change,
	hash_stack:    [dynamic]Hash_Frame,
	eq_stack:      [dynamic]Eq_Frame,
	named:         []bool,
	work:          int,
	active_facts:  tape.Facts,
	truncated:     bool,
	too_deep:      bool,
}

@(private = "file")
Walk_Task_Kind :: enum u8 {
	Compare,
	Pop,
}

@(private = "file")
Walk_Task :: struct {
	a, b:     Val,
	old_step: tape.Step,
	new_step: tape.Step,
	depth:    u32,
	kind:     Walk_Task_Kind,
	has_old:  bool,
	has_new:  bool,
}

when size_of(int) == 8 {
	#assert(size_of(Walk_Task) == 104)
}

@(private = "file")
Index_Pair :: struct {
	i, j: int,
}

@(private)
Object_Member :: struct {
	name: string,
	vals: [2]Val,
	has:  [2]bool,
}

@(private)
destroy_arena :: proc(arena: ^^mem.Dynamic_Arena) {
	if arena^ != nil {
		alloc := arena^.block_allocator
		mem.dynamic_arena_destroy(arena^)
		free(arena^, alloc)
		arena^ = nil
	}
}

@(private)
close_differ :: proc(d: ^Differ) {
	mem.dynamic_arena_destroy(&d.scratch_arena)
}

@(private, require_results)
open_differ :: proc(d: ^Differ, a, b: ^tape.Document, opts: Options, allocator: runtime.Allocator) -> (out_arena: ^mem.Dynamic_Arena, err: Error) {
	if allocator.procedure == nil {
		return nil, .Out_Of_Memory
	}
	arena := new(mem.Dynamic_Arena, allocator) or_return
	if arena == nil {
		return nil, .Out_Of_Memory
	}
	mem.dynamic_arena_init(arena, allocator, allocator)
	defer if err != nil {
		destroy_arena(&arena)
	}

	d^ = {
		opts      = opts,
		docs      = {a, b},
		allocator = mem.dynamic_arena_allocator(arena),
		work      = MAX_WORK,
	}
	mem.dynamic_arena_init(&d.scratch_arena, allocator, allocator)
	defer if err != nil {
		mem.dynamic_arena_destroy(&d.scratch_arena)
	}
	d.scratch_gate = {inner = mem.dynamic_arena_allocator(&d.scratch_arena)}
	d.scratch = scratch_gate_allocator(&d.scratch_gate)

	if d.opts.max_edits <= 0 {
		d.opts.max_edits = DEFAULT_MAX_EDITS
	}
	if d.opts.max_depth <= 0 {
		d.opts.max_depth = tape.DEFAULT_DEPTH
	}
	if d.opts.facts {
		d.active_facts = init_facts(a, b)
	}
	for side in 0 ..< 2 {
		d.indexes[side] = {allocator = d.scratch}
		d.readers[side] = {doc = d.docs[side], index = &d.indexes[side]}
		d.hashes[side] = make([]u64, len(d.docs[side].nodes), d.scratch) or_return
	}
	d.old.allocator = d.scratch
	d.new.allocator = d.scratch
	d.changes.allocator = d.allocator
	d.hash_stack.allocator = d.scratch
	d.eq_stack.allocator = d.scratch
	if len(opts.keys) > 0 {
		d.named = make([]bool, len(opts.keys), d.scratch) or_return
	}
	return arena, nil
}

// Computes the structural diff turning document `a` into document `b`.
@(require_results)
diff_documents :: proc(a, b: ^tape.Document, opts := Options{}, allocator := context.allocator) -> (r: Result, err: Error) {
	if a == nil || b == nil {
		return {}, nil
	}
	d: Differ
	out_arena := open_differ(&d, a, b, opts, allocator) or_return
	defer close_differ(&d)
	defer if out_arena != nil {
		destroy_arena(&out_arena)
	}

	ra, pa := tape.root(d.readers[0])
	rb, pb := tape.root(d.readers[1])
	switch {
	case pa != .Found && pb != .Found:
		// Both empty.
	case pa != .Found:
		emit(&d, {op = .Added, old_node = tape.NO_NODE, new_node = rb}) or_return
	case pb != .Found:
		emit(&d, {op = .Removed, old_node = ra, new_node = tape.NO_NODE}) or_return
	case:
		walk_diff(&d, ra, rb) or_return
		if !d.too_deep && !d.truncated && !d.scratch_gate.failed {
			for rule, i in d.opts.keys {
				if d.named[i] {
					continue
				}
				in_a := probe_key_side(&d, 0, ra, rule.at) or_return
				if in_a {
					d.named[i] = probe_key_side(&d, 1, rb, rule.at) or_return
				}
			}
		}
	}

	if d.scratch_gate.failed {
		return {}, .Out_Of_Memory
	}

	unused: [dynamic]int
	unused.allocator = d.allocator
	for named, i in d.named {
		if !named {
			append(&unused, i) or_return
		}
	}
	if len(d.changes) == 0 && len(unused) == 0 {
		destroy_arena(&out_arena)
	}
	r = {
		changes     = d.changes[:],
		truncated   = d.truncated,
		too_deep    = d.too_deep,
		unused_keys = unused[:],
		arena       = out_arena,
	}
	out_arena = nil
	return r, nil
}

@(private = "file")
walk_diff :: proc(d: ^Differ, root_a, root_b: tape.Node_Index) -> Error {
	stack := make([dynamic]Walk_Task, 0, 32, d.scratch) or_return
	append(&stack, Walk_Task{kind = .Compare, a = val_node(root_a), b = val_node(root_b), depth = 0}) or_return

	for len(stack) > 0 {
		if d.scratch_gate.failed {
			return .Out_Of_Memory
		}
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
		if d.too_deep || (d.truncated && d.opts.max_changes > 0 && len(d.changes) >= d.opts.max_changes) {
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

		if val_empty(task.a) && val_empty(task.b) {
			continue
		}
		if !val_empty(task.a) && val_empty(task.b) {
			emit(d, {op = .Removed, old_node = val_first_node(task.a), new_node = tape.NO_NODE}) or_return
			continue
		}
		if val_empty(task.a) && !val_empty(task.b) {
			emit(d, {op = .Added, old_node = tape.NO_NODE, new_node = val_first_node(task.b)}) or_return
			continue
		}

		a, b, depth := task.a, task.b, int(task.depth)
		ca, cb := val_class(d.docs[0], a), val_class(d.docs[1], b)
		if d.active_facts != {} && len(a.group) == 0 && len(b.group) == 0 {
			diff_facts(d, a.node, b.node) or_return
		}
		switch {
		case ca != cb:
			emit(d, {op = .Changed, old_node = val_first_node(a), new_node = val_first_node(b), kind_changed = true}) or_return
		case ca == .Object && depth < d.opts.max_depth:
			if vals_equal(d, a, b, depth) && (d.active_facts == {} || quiet(d, a, b)) {
				continue
			}
			if d.scratch_gate.failed {
				return .Out_Of_Memory
			}
			if d.too_deep {
				return nil
			}
			push_object_tasks(d, &stack, a.node, b.node, depth) or_return
		case ca == .Array && depth < d.opts.max_depth:
			rule, keyed := match_key_rule(d)
			if vals_equal(d, a, b, depth) && (d.active_facts == {} || quiet(d, a, b)) {
				continue
			}
			if d.scratch_gate.failed {
				return .Out_Of_Memory
			}
			if d.too_deep {
				return nil
			}
			push_array_tasks(d, &stack, a, b, depth, rule, keyed) or_return
		case !vals_equal_exact(d, a, b, depth):
			if d.scratch_gate.failed {
				return .Out_Of_Memory
			}
			if d.too_deep {
				return nil
			}
			emit(d, {op = .Changed, old_node = val_first_node(a), new_node = val_first_node(b)}) or_return
		}
	}
	return .Out_Of_Memory if d.scratch_gate.failed else nil
}

@(private)
emit :: proc(d: ^Differ, c: Change) -> Error {
	if d.opts.max_changes > 0 && len(d.changes) >= d.opts.max_changes {
		d.truncated = true
		return nil
	}
	c := c
	if c.op == .Removed {
		c.path = clone_steps(d.old[:], d.allocator) or_return
		c.old_path = c.path
	} else {
		c.path = clone_steps(d.new[:], d.allocator) or_return
		if c.op == .Added || tape.steps_equal(d.old[:], d.new[:]) {
			c.old_path = c.path
		} else {
			c.old_path = clone_steps(d.old[:], d.allocator) or_return
		}
	}
	append(&d.changes, c) or_return
	return nil
}

@(private = "file")
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

// Collects distinct members of objects `a` then `b` in text order into `d.scratch` in one pass, avoiding `2*K`
// `member_val` re-lookups on non-grouped objects and cloning only keys decoded into the stack buffer.
@(private)
collect_object_members :: proc(d: ^Differ, a, b: tape.Node_Index) -> (res: []Object_Member, err: Error) {
	nodes := [2]tape.Node_Index{a, b}
	est := max(int(d.docs[0].nodes[a].spelling & tape.MAX_CHILDREN), int(d.docs[1].nodes[b].spelling & tape.MAX_CHILDREN))
	members := make([dynamic]Object_Member, 0, est, d.scratch) or_return
	seen := make(map[string]int, est, d.scratch) or_return
	buf: [256]u8 = ---
	buf_lo := uintptr(&buf[0])
	buf_hi := buf_lo + uintptr(len(buf))
	for side in 0 ..< 2 {
		c, p := tape.children(d.readers[side], nodes[side], d.scratch) or_return
		if p != .Found {
			continue
		}
		defer tape.destroy_children(&c)
		grouped := is_grouped(d.docs[side])
		dups := tape.Duplicates.First if grouped else tape.Duplicates.Default
		for {
			kn, vn, np := tape.next_child(d.readers[side], &c, dups)
			if np != .Found {
				break
			}
			ks, owned, ok := read_member_key(d, side, c, kn, buf[:])
			if d.scratch_gate.failed {
				return nil, .Out_Of_Memory
			}
			if !ok {
				continue
			}
			val: Val
			if grouped && !c.once {
				mv, found := member_val(d, side, nodes[side], ks) or_return
				if !found {
					continue
				}
				val = mv
			} else {
				val = val_node(vn)
			}
			if idx, exists := seen[ks]; exists {
				members[idx].vals[side] = val
				members[idx].has[side] = true
			} else {
				// `ks` already slices `owned` (`d.scratch`) or `doc.src`; clone only when decoded into stack `buf`.
				kept := ks
				if owned == nil && len(ks) > 0 {
					ptr := uintptr(raw_data(ks))
					if ptr >= buf_lo && ptr < buf_hi {
						kept = strings.clone(ks, d.scratch) or_return
					}
				}
				idx = len(members)
				m := Object_Member{name = kept}
				m.vals[side] = val
				m.has[side] = true
				append(&members, m) or_return
				seen[kept] = idx
				if d.scratch_gate.failed {
					return nil, .Out_Of_Memory
				}
			}
		}
	}
	return members[:], nil
}

@(private = "file")
push_object_tasks :: proc(d: ^Differ, stack: ^[dynamic]Walk_Task, a, b: tape.Node_Index, depth: int) -> Error {
	members := collect_object_members(d, a, b) or_return
	#reverse for m in members {
		if !m.has[0] && !m.has[1] {
			continue
		}
		step := tape.Step(tape.Name(m.name))
		append(stack, Walk_Task {
			kind     = .Compare,
			a        = m.vals[0] if m.has[0] else val_node(tape.NO_NODE),
			b        = m.vals[1] if m.has[1] else val_node(tape.NO_NODE),
			has_old  = m.has[0],
			has_new  = m.has[1],
			old_step = step,
			new_step = step,
			depth    = u32(depth + 1),
		}) or_return
	}
	return nil
}

@(private)
val_elements :: proc(d: ^Differ, side: int, v: Val) -> (res: []tape.Node_Index, err: Error) {
	if len(v.group) > 0 {
		return v.group, nil
	}
	n, lp := tape.length(d.readers[side], v.node, d.scratch) or_return
	if lp == .Found && n == 0 {
		return nil, nil
	}
	items := make([dynamic]tape.Node_Index, 0, max(n, 0), d.scratch) or_return
	c, p := tape.children(d.readers[side], v.node, d.scratch) or_return
	if p != .Found {
		return nil, nil
	}
	defer tape.destroy_children(&c)
	for {
		_, elem, np := tape.next_child(d.readers[side], &c)
		if np != .Found {
			break
		}
		append(&items, elem) or_return
	}
	return items[:], nil
}

@(private = "file")
push_array_tasks :: proc(d: ^Differ, stack: ^[dynamic]Walk_Task, a, b: Val, depth: int, rule: Key_Rule, keyed: bool) -> Error {
	xs := val_elements(d, 0, a) or_return
	ys := val_elements(d, 1, b) or_return
	pairs := make([dynamic]Index_Pair, 0, max(len(xs), len(ys)), d.scratch) or_return

	switch {
	case keyed:
		collect_matched(d, xs, ys, rule.member, depth, &pairs) or_return
	case d.opts.arrays == .Position:
		for i in 0 ..< max(len(xs), len(ys)) {
			append(&pairs, Index_Pair{i if i < len(xs) else -1, i if i < len(ys) else -1}) or_return
		}
	case d.opts.arrays == .Set:
		collect_matched(d, xs, ys, "", depth, &pairs) or_return
	case:
		removed, added, ok := sequence_edits(d, xs, ys, depth) or_return
		if !ok {
			emit(d, {op = .Changed, old_node = val_first_node(a), new_node = val_first_node(b)}) or_return
			d.truncated = true
			return nil
		}
		i, j := 0, 0
		for i < len(xs) || j < len(ys) {
			if i < len(xs) && j < len(ys) && !removed[i] && !added[j] {
				if d.active_facts != {} && !quiet(d, val_node(xs[i]), val_node(ys[j])) {
					append(&pairs, Index_Pair{i, j}) or_return
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
				append(&pairs, Index_Pair {
					lo_i + k if lo_i + k < i else -1,
					lo_j + k if lo_j + k < j else -1,
				}) or_return
			}
		}
	}

	if d.too_deep {
		return nil
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
			depth    = u32(depth + 1),
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
			if !(all && indexed) && s != d.new[i] {
				continue next
			}
		}
		d.named[n] = true
		return r, true
	}
	return
}

// Iteratively checks whether `at` reaches an `.Array` on `side` within `d.opts.max_depth`, so `--key` rules inside
// equal subtrees skipped by `vals_equal` are not falsely reported as `unused_keys`.
@(private = "file")
probe_key_side :: proc(d: ^Differ, side: int, root: tape.Node_Index, at: []tape.Step) -> (found: bool, err: Error) {
	if len(at) >= d.opts.max_depth {
		return false, nil
	}
	Frame :: struct {
		val: Val,
		idx: int,
	}
	stack := make([dynamic]Frame, 0, len(at) + 1, d.scratch) or_return
	append(&stack, Frame{val = val_node(root)}) or_return
	for len(stack) > 0 {
		f := pop(&stack)
		if f.idx == len(at) {
			if val_class(d.docs[side], f.val) == .Array {
				return true, nil
			}
			continue
		}
		cls := val_class(d.docs[side], f.val)
		#partial switch step in at[f.idx] {
		case tape.Name:
			if cls != .Object {
				continue
			}
			mv, ok := member_val(d, side, f.val.node, string(step)) or_return
			if ok {
				append(&stack, Frame{val = mv, idx = f.idx + 1}) or_return
			}
		case tape.Index:
			if cls != .Array || int(step) < 0 {
				continue
			}
			elems := val_elements(d, side, f.val) or_return
			if int(step) < len(elems) {
				append(&stack, Frame{val = val_node(elems[int(step)]), idx = f.idx + 1}) or_return
			}
		case tape.All:
			if cls != .Array {
				continue
			}
			elems := val_elements(d, side, f.val) or_return
			#reverse for elem in elems {
				append(&stack, Frame{val = val_node(elem), idx = f.idx + 1}) or_return
			}
		}
	}
	return false, nil
}

// Matches `xs` against `ys` by decoded `member` value (or whole element when `member == ""`).
// `first[0]` chains unkeyed elements by whole-element hash and `first[1]` chains keyed elements by key hash; after
// hash matching, any remaining unkeyed elements under `member != ""` pair positionally.
@(private = "file")
collect_matched :: proc(d: ^Differ, xs, ys: []tape.Node_Index, member: string, depth: int, pairs: ^[dynamic]Index_Pair) -> Error {
	key_of :: proc(d: ^Differ, side: int, e: tape.Node_Index, member: string) -> (key: Val, keyed: bool, err: Error) {
		if member == "" {
			return val_node(e), false, nil
		}
		v, found := member_val(d, side, e, member) or_return
		return v if found else val_node(e), found, nil
	}
	kx := make([]Val, len(xs), d.scratch) or_return
	hx := make([]bool, len(xs), d.scratch) or_return
	hy := make([]bool, len(ys), d.scratch) or_return
	cap0 := 0 if member != "" else len(xs)
	cap1 := len(xs) if member != "" else 0
	f0 := make(map[u64]int, cap0, d.scratch) or_return
	f1 := make(map[u64]int, cap1, d.scratch) or_return
	first := [2]map[u64]int{f0, f1}
	next := make([]int, len(xs), d.scratch) or_return
	#reverse for x, i in xs {
		kx[i], hx[i] = key_of(d, 0, x, member) or_return
		chain := &first[int(hx[i])]
		h := hash_val(d, 0, kx[i], depth + (2 if hx[i] else 1))
		if d.scratch_gate.failed {
			return .Out_Of_Memory
		}
		if d.too_deep {
			return nil
		}
		next[i] = chain[h] if h in chain else -1
		chain[h] = i
		if d.scratch_gate.failed {
			return .Out_Of_Memory
		}
	}
	taken := make([]bool, len(xs), d.scratch) or_return
	partner := make([]int, len(ys), d.scratch) or_return
	exact := make([]bool, len(ys), d.scratch) or_return
	for y, j in ys {
		ky: Val
		ky, hy[j] = key_of(d, 1, y, member) or_return
		kdepth := depth + (2 if hy[j] else 1)
		h := hash_val(d, 1, ky, kdepth)
		if d.scratch_gate.failed {
			return .Out_Of_Memory
		}
		if d.too_deep {
			return nil
		}
		chain := &first[int(hy[j])]
		partner[j] = -1
		prev := -1
		head, listed := chain[h]
		for i := head if listed else -1; i >= 0; i = next[i] {
			if !taken[i] && vals_equal(d, kx[i], ky, kdepth) {
				partner[j], exact[j], taken[i] = i, !hy[j], true
				if prev < 0 {
					chain[h] = next[i]
				} else {
					next[prev] = next[i]
				}
				break
			}
			if d.scratch_gate.failed {
				return .Out_Of_Memory
			}
			if d.too_deep {
				return nil
			}
			prev = i
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
		if partner[j] >= 0 && exact[j] && (d.active_facts == {} || quiet(d, val_node(xs[partner[j]]), val_node(y))) {
			continue
		}
		append(pairs, Index_Pair{partner[j], j}) or_return
	}
	for _, i in xs {
		if !taken[i] {
			append(pairs, Index_Pair{i, -1}) or_return
		}
	}
	return nil
}
