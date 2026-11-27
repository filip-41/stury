package diff

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import "stury:lib/core/tape"

// RFC 6901 JSON Pointer encoding/decoding and RFC 6902 JSON Patch generation from two `tape.Document`s.
// Explicit heap stack throughout (zero native recursion).

// ---- RFC 6901 JSON Pointer

Pointer_Error :: enum u8 {
	None,
	Missing_Slash,
	Bad_Escape,
	Out_Of_Memory,
}

// Encodes `steps` (`tape.Name` and `tape.Index`) as an RFC 6901 JSON Pointer (`~` -> `~0`, `/` -> `~1`).
// Empty `steps` encodes to `""` (root).
@(private = "file", require_results)
encode_pointer :: proc(steps: []tape.Step, allocator := context.allocator) -> (res: string, err: runtime.Allocator_Error) {
	if len(steps) == 0 {
		return "", nil
	}
	ibuf: [24]u8 = ---
	total := 0
	for s in steps {
		total += 1
		#partial switch step in s {
		case tape.Name:
			for b in transmute([]u8)string(step) {
				total += 2 if (b == '~' || b == '/') else 1
			}
		case tape.Index:
			total += len(strconv.write_int(ibuf[:], i64(step), 10))
		}
	}
	buf := make([]u8, total, allocator) or_return
	w := 0
	for s in steps {
		buf[w] = '/'
		w += 1
		#partial switch step in s {
		case tape.Name:
			for b in transmute([]u8)string(step) {
				switch b {
				case '~':
					buf[w], buf[w + 1] = '~', '0'
					w += 2
				case '/':
					buf[w], buf[w + 1] = '~', '1'
					w += 2
				case:
					buf[w] = b
					w += 1
				}
			}
		case tape.Index:
			idx := strconv.write_int(ibuf[:], i64(step), 10)
			copy(buf[w:], idx)
			w += len(idx)
		}
	}
	return string(buf), nil
}

// Decodes an RFC 6901 JSON Pointer into its unescaped reference tokens (`~1` -> `/`, `~0` -> `~`).
// `""` decodes to an empty slice. Non-empty pointers must start with `'/'`.
// Caller frees each token and the returned slice (or allocates into an arena).
@(require_results)
decode_pointer :: proc(ptr: string, allocator := context.allocator) -> (tokens: []string, err: Pointer_Error) {
	if len(ptr) == 0 {
		return nil, .None
	}
	if ptr[0] != '/' {
		return nil, .Missing_Slash
	}
	count := 0
	for b in transmute([]u8)ptr {
		if b == '/' {
			count += 1
		}
	}
	out, aerr := make([]string, count, allocator)
	if aerr != nil {
		return nil, .Out_Of_Memory
	}
	filled := 0
	defer if err != .None {
		for k in 0 ..< filled {
			delete(out[k], allocator)
		}
		delete(out, allocator)
	}

	i := 1
	for t in 0 ..< count {
		start := i
		escapes := 0
		for i < len(ptr) && ptr[i] != '/' {
			if ptr[i] == '~' {
				if i + 1 >= len(ptr) || (ptr[i + 1] != '0' && ptr[i + 1] != '1') {
					return nil, .Bad_Escape
				}
				escapes += 1
				i += 2
				continue
			}
			i += 1
		}
		raw := ptr[start:i]
		if escapes == 0 {
			cloned, cerr := strings.clone(raw, allocator)
			if cerr != nil {
				return nil, .Out_Of_Memory
			}
			out[t] = cloned
		} else {
			buf, berr := make([]u8, len(raw) - escapes, allocator)
			if berr != nil {
				return nil, .Out_Of_Memory
			}
			w := 0
			for j := 0; j < len(raw); {
				if raw[j] == '~' {
					buf[w] = '~' if raw[j + 1] == '0' else '/'
					w += 1
					j += 2
				} else {
					buf[w] = raw[j]
					w += 1
					j += 1
				}
			}
			out[t] = string(buf)
		}
		filled += 1
		if i < len(ptr) {
			i += 1
		}
	}
	return out, .None
}

// Frees a token slice returned by `decode_pointer`.
destroy_pointer_tokens :: proc(tokens: []string, allocator := context.allocator) {
	for tok in tokens {
		delete(tok, allocator)
	}
	delete(tokens, allocator)
}

// Parses an RFC 6901 array index token: `"-"` sets `append_end = true`; `"0"` or non-zero-prefixed unsigned decimal
// sets `index`; leading zeros (e.g. `"01"`, `"00"`) or non-digits return `ok = false`.
@(require_results)
parse_array_index :: proc "contextless" (token: string) -> (index: int, append_end: bool, ok: bool) {
	if len(token) == 0 {
		return 0, false, false
	}
	if token == "-" {
		return 0, true, true
	}
	if token == "0" {
		return 0, false, true
	}
	if token[0] == '0' {
		return 0, false, false
	}
	val := 0
	for c in transmute([]u8)token {
		if c < '0' || c > '9' {
			return 0, false, false
		}
		d := int(c - '0')
		if val > (max(int) - d) / 10 {
			return 0, false, false
		}
		val = val * 10 + d
	}
	return val, false, true
}

// ---- RFC 6902 JSON Patch

Patch_Op_Kind :: enum u8 {
	Add,
	Remove,
	Replace,
	Move,
	Copy,
	Test,
}

// One RFC 6902 JSON Patch operation.
// For `.Add`, `.Replace`, and `.Test`, `(doc, node)` references a single value in a `tape.Document`, or `(doc, nodes)`
// references a virtual grouped array of 2+ nodes (XML `.Group` repeated elements) backed by `Patch.arena`.
Patch_Op :: struct {
	path:  string,
	from:  string,
	nodes: []tape.Node_Index,
	doc:   ^tape.Document,
	node:  tape.Node_Index,
	op:    Patch_Op_Kind,
}

when size_of(int) == 8 {
	#assert(size_of(Patch_Op) == 64)
}

// A generated RFC 6902 JSON Patch. Paths live in `arena`; free with `destroy_patch`.
// `ops` borrow `b`'s nodes via `(op.doc, op.node / op.nodes)`, so `b` must outlive `Patch` while ops are read.
Patch :: struct {
	ops:       []Patch_Op,
	truncated: bool,
	too_deep:  bool,
	arena:     ^mem.Dynamic_Arena,
}

destroy_patch :: proc(p: ^Patch) {
	if p == nil {
		return
	}
	destroy_arena(&p.arena)
	p^ = {}
}

@(private = "file")
Patch_Task_Kind :: enum u8 {
	Diff,
	Emit_Op,
	Pop,
}

@(private = "file")
Patch_Task :: struct {
	a, b:  Val,
	step:  tape.Step,
	depth: u32,
	kind:  Patch_Task_Kind,
	op:    Patch_Op_Kind,
	has_s: bool,
}

when size_of(int) == 8 {
	#assert(size_of(Patch_Task) == 80)
}

@(private = "file")
emit_patch_op :: proc(d: ^Differ, ops: ^[dynamic]Patch_Op, op: Patch_Op_Kind, v: Val) -> Error {
	if d.opts.max_changes > 0 && len(ops) >= d.opts.max_changes {
		d.truncated = true
		return nil
	}
	ptr := encode_pointer(d.new[:], d.allocator) or_return
	po := Patch_Op{op = op, path = ptr, node = tape.NO_NODE}
	if op != .Remove {
		po.doc = d.docs[1]
		if len(v.group) > 0 {
			po.nodes = slice.clone(v.group, d.allocator) or_return
		} else {
			po.node = v.node
		}
	}
	append(ops, po) or_return
	return nil
}

// Generates a minimal sequential RFC 6902 JSON Patch turning document `a` into document `b`.
// Uses live array indices along Myers LCS so applying `patch.ops` in order to `a` always yields `b`.
// Honors `Options.max_edits`, `Options.max_changes`, and `Options.max_depth`; ignores `arrays`, `keys`, and `facts`.
@(require_results)
diff_to_patch :: proc(a, b: ^tape.Document, opts := Options{}, allocator := context.allocator) -> (p: Patch, err: Error) {
	if a == nil || b == nil {
		return {}, nil
	}
	d: Differ
	popts := Options{max_edits = opts.max_edits, max_changes = opts.max_changes, max_depth = opts.max_depth}
	out_arena := open_differ(&d, a, b, popts, allocator) or_return
	defer close_differ(&d)
	defer if out_arena != nil {
		destroy_arena(&out_arena)
	}

	ops: [dynamic]Patch_Op
	ops.allocator = d.allocator
	ra, pa := tape.root(d.readers[0])
	rb, pb := tape.root(d.readers[1])
	switch {
	case pa != .Found && pb != .Found:
	case pa != .Found:
		emit_patch_op(&d, &ops, .Add, val_node(rb)) or_return
	case pb != .Found:
		emit_patch_op(&d, &ops, .Remove, {}) or_return
	case:
		stack := make([dynamic]Patch_Task, 0, 32, d.scratch) or_return
		append(&stack, Patch_Task{kind = .Diff, a = val_node(ra), b = val_node(rb), depth = 0}) or_return

		patch_loop: for len(stack) > 0 {
			if d.scratch_gate.failed {
				return {}, .Out_Of_Memory
			}
			if d.too_deep || (d.truncated && d.opts.max_changes > 0 && len(ops) >= d.opts.max_changes) {
				break patch_loop
			}
			task := pop(&stack)
			switch task.kind {
			case .Pop:
				pop(&d.new)
			case .Emit_Op:
				if task.has_s {
					append(&d.new, task.step) or_return
				}
				emit_err := emit_patch_op(&d, &ops, task.op, task.b)
				if task.has_s {
					pop(&d.new)
				}
				if emit_err != nil {
					return {}, emit_err
				}
			case .Diff:
				if task.has_s {
					append(&stack, Patch_Task{kind = .Pop}) or_return
					append(&d.new, task.step) or_return
				}
				na, nb, depth := task.a, task.b, int(task.depth)
				ca, cb := val_class(a, na), val_class(b, nb)
				if ca != cb {
					emit_patch_op(&d, &ops, .Replace, nb) or_return
					continue
				}
				if ca != .Array && ca != .Object {
					if !scalars_equal(&d, na.node, nb.node) {
						if d.scratch_gate.failed {
							return {}, .Out_Of_Memory
						}
						emit_patch_op(&d, &ops, .Replace, nb) or_return
					}
					continue
				}
				if depth >= d.opts.max_depth {
					if !vals_equal_exact(&d, na, nb, depth) {
						if d.scratch_gate.failed {
							return {}, .Out_Of_Memory
						}
						if d.too_deep {
							break patch_loop
						}
						emit_patch_op(&d, &ops, .Replace, nb) or_return
					}
					continue
				}
				if vals_equal(&d, na, nb, depth) {
					continue
				}
				if d.scratch_gate.failed {
					return {}, .Out_Of_Memory
				}
				if d.too_deep {
					break patch_loop
				}
				if ca == .Object {
					push_patch_object(&d, &stack, na.node, nb.node, depth) or_return
				} else {
					push_patch_array(&d, &stack, na, nb, depth, &ops) or_return
				}
			}
		}
	}

	if d.scratch_gate.failed {
		return {}, .Out_Of_Memory
	}
	if len(ops) == 0 {
		destroy_arena(&out_arena)
	}
	p = {
		ops       = ops[:],
		truncated = d.truncated,
		too_deep  = d.too_deep,
		arena     = out_arena,
	}
	out_arena = nil
	return p, nil
}

@(private = "file")
push_patch_object :: proc(d: ^Differ, stack: ^[dynamic]Patch_Task, a, b: tape.Node_Index, depth: int) -> Error {
	members := collect_object_members(d, a, b) or_return
	#reverse for m in members {
		step := tape.Step(tape.Name(m.name))
		switch {
		case m.has[0] && m.has[1]:
			append(stack, Patch_Task{kind = .Diff, a = m.vals[0], b = m.vals[1], step = step, has_s = true, depth = u32(depth + 1)}) or_return
		case m.has[0]:
			append(stack, Patch_Task{kind = .Emit_Op, op = .Remove, step = step, has_s = true}) or_return
		case m.has[1]:
			append(stack, Patch_Task{kind = .Emit_Op, op = .Add, b = m.vals[1], step = step, has_s = true}) or_return
		}
	}
	return nil
}

@(private = "file")
push_patch_array :: proc(
	d: ^Differ,
	stack: ^[dynamic]Patch_Task,
	a, b: Val,
	depth: int,
	ops: ^[dynamic]Patch_Op,
) -> Error {
	xs := val_elements(d, 0, a) or_return
	ys := val_elements(d, 1, b) or_return
	removed, added, ok := sequence_edits(d, xs, ys, depth) or_return
	if !ok {
		emit_patch_op(d, ops, .Replace, b) or_return
		d.truncated = true
		return nil
	}

	// Walk Myers edits left-to-right maintaining the live index invariant:
	// before each hunk, `live[0 ..< lo_j] == ys[0 ..< lo_j]` and `live[lo_j ..] == xs[lo_i ..]`.
	tasks := make([dynamic]Patch_Task, 0, max(len(xs), len(ys)), d.scratch) or_return
	i, j := 0, 0
	for i < len(xs) || j < len(ys) {
		if i < len(xs) && j < len(ys) && !removed[i] && !added[j] {
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
		rem_n := i - lo_i
		add_n := j - lo_j
		paired := min(rem_n, add_n)
		for k in 0 ..< paired {
			append(&tasks, Patch_Task {
				kind  = .Diff,
				a     = val_node(xs[lo_i + k]),
				b     = val_node(ys[lo_j + k]),
				step  = tape.Index(lo_j + k),
				has_s = true,
				depth = u32(depth + 1),
			}) or_return
		}
		// Excess removals: each removes at `lo_j + paired`, shifting subsequent elements left into place.
		for _ in paired ..< rem_n {
			append(&tasks, Patch_Task {
				kind  = .Emit_Op,
				op    = .Remove,
				step  = tape.Index(lo_j + paired),
				has_s = true,
			}) or_return
		}
		// Excess additions: insert sequentially at `lo_j + k` (`k = paired ..< add_n`).
		for k in paired ..< add_n {
			append(&tasks, Patch_Task {
				kind  = .Emit_Op,
				op    = .Add,
				b     = val_node(ys[lo_j + k]),
				step  = tape.Index(lo_j + k),
				has_s = true,
			}) or_return
		}
	}

	#reverse for t in tasks {
		append(stack, t) or_return
	}
	return nil
}
