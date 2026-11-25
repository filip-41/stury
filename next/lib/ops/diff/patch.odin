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
@(require_results)
encode_pointer :: proc(steps: []tape.Step, allocator := context.allocator) -> (res: string, err: runtime.Allocator_Error) {
	if len(steps) == 0 {
		return "", nil
	}
	sb := strings.builder_make(allocator)
	defer if err != nil {
		strings.builder_destroy(&sb)
	}
	for s in steps {
		strings.write_byte(&sb, '/') or_return
		#partial switch step in s {
		case tape.Name:
			write_escaped_token(&sb, string(step)) or_return
		case tape.Index:
			buf: [24]u8
			strings.write_string(&sb, strconv.write_int(buf[:], i64(step), 10)) or_return
		}
	}
	return strings.to_string(sb), nil
}

@(private = "file")
write_escaped_token :: proc(sb: ^strings.Builder, tok: string) -> runtime.Allocator_Error {
	for b in transmute([]u8)tok {
		switch b {
		case '~':
			strings.write_string(sb, "~0") or_return
		case '/':
			strings.write_string(sb, "~1") or_return
		case:
			strings.write_byte(sb, b) or_return
		}
	}
	return nil
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
		has_tilde := false
		for i < len(ptr) && ptr[i] != '/' {
			if ptr[i] == '~' {
				has_tilde = true
			}
			i += 1
		}
		raw := ptr[start:i]
		if !has_tilde {
			cloned, cerr := strings.clone(raw, allocator)
			if cerr != nil {
				return nil, .Out_Of_Memory
			}
			out[t] = cloned
		} else {
			buf, berr := make([]u8, len(raw), allocator)
			if berr != nil {
				return nil, .Out_Of_Memory
			}
			w := 0
			j := 0
			for j < len(raw) {
				if raw[j] == '~' {
					if j + 1 >= len(raw) {
						delete(buf, allocator)
						return nil, .Bad_Escape
					}
					switch raw[j + 1] {
					case '0':
						buf[w] = '~'
					case '1':
						buf[w] = '/'
					case:
						delete(buf, allocator)
						return nil, .Bad_Escape
					}
					w += 1
					j += 2
				} else {
					buf[w] = raw[j]
					w += 1
					j += 1
				}
			}
			exact, eerr := make([]u8, w, allocator)
			if eerr != nil {
				delete(buf, allocator)
				return nil, .Out_Of_Memory
			}
			copy(exact, buf[:w])
			delete(buf, allocator)
			out[t] = string(exact)
		}
		filled += 1
		if i < len(ptr) && ptr[i] == '/' {
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
	val: i64
	for c in transmute([]u8)token {
		if c < '0' || c > '9' {
			return 0, false, false
		}
		d := i64(c - '0')
		if val > (max(i64) - d) / 10 {
			return 0, false, false
		}
		val = val * 10 + d
	}
	if val > i64(max(int)) {
		return 0, false, false
	}
	return int(val), false, true
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
	op:    Patch_Op_Kind,
	path:  string,
	from:  string,
	doc:   ^tape.Document,
	node:  tape.Node_Index,
	nodes: []tape.Node_Index,
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
	if p.arena != nil {
		alloc := p.arena.block_allocator
		mem.dynamic_arena_destroy(p.arena)
		free(p.arena, alloc)
	}
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
	kind:  Patch_Task_Kind,
	op:    Patch_Op_Kind,
	a, b:  Val,
	step:  tape.Step,
	has_s: bool,
	depth: int,
}

@(private = "file")
make_patch_op :: proc(op: Patch_Op_Kind, ptr: string, doc: ^tape.Document, v: Val, out_alloc: runtime.Allocator) -> (res: Patch_Op, err: Error) {
	if op == .Remove {
		return Patch_Op{op = .Remove, path = ptr, doc = nil, node = tape.NO_NODE}, nil
	}
	if len(v.group) > 0 {
		cloned := slice.clone(v.group, out_alloc) or_return
		return Patch_Op{op = op, path = ptr, doc = doc, node = tape.NO_NODE, nodes = cloned}, nil
	}
	return Patch_Op{op = op, path = ptr, doc = doc, node = v.node}, nil
}

// Generates a minimal sequential RFC 6902 JSON Patch turning document `a` into document `b`.
// Uses live array indices along Myers LCS so applying `patch.ops` in order to `a` always yields `b`.
@(require_results)
diff_to_patch :: proc(a, b: ^tape.Document, opts := Options{}, allocator := context.allocator) -> (p: Patch, err: Error) {
	if a == nil || b == nil {
		return {}, nil
	}
	p.arena = new(mem.Dynamic_Arena, allocator) or_return
	mem.dynamic_arena_init(p.arena, allocator, allocator)
	defer if err != nil {
		destroy_patch(&p)
	}
	out_alloc := mem.dynamic_arena_allocator(p.arena)
	scratch_arena := new(mem.Dynamic_Arena, allocator) or_return
	mem.dynamic_arena_init(scratch_arena, allocator, allocator)
	defer {
		mem.dynamic_arena_destroy(scratch_arena)
		free(scratch_arena, allocator)
	}
	scratch_alloc := mem.dynamic_arena_allocator(scratch_arena)

	// Force sequence/position mode for valid sequential RFC 6902 patch generation.
	popts := opts
	popts.ignore_order = false
	if popts.arrays == .Set {
		popts.arrays = .Sequence
	}

	d: Differ
	init_differ(&d, a, b, popts, out_alloc, scratch_alloc) or_return
	defer destroy_differ(&d)

	ops := make([dynamic]Patch_Op, 0, 16, out_alloc) or_return
	ra, pa := tape.root(d.readers[0])
	rb, pb := tape.root(d.readers[1])
	if pa != .Found && pb != .Found {
		p.ops = ops[:]
		return p, nil
	}
	if pa != .Found {
		append(&ops, Patch_Op{op = .Add, path = "", doc = b, node = rb}) or_return
		p.ops = ops[:]
		return p, nil
	}
	if pb != .Found {
		append(&ops, Patch_Op{op = .Remove, path = "", doc = nil, node = tape.NO_NODE}) or_return
		p.ops = ops[:]
		return p, nil
	}

	stack := make([dynamic]Patch_Task, 0, 32, scratch_alloc) or_return
	defer delete(stack)
	append(&stack, Patch_Task{kind = .Diff, a = val_node(ra), b = val_node(rb), depth = 0}) or_return

	patch_loop: for len(stack) > 0 {
		if d.too_deep {
			break patch_loop
		}
		task := pop(&stack)
		switch task.kind {
		case .Pop:
			pop(&d.new)
		case .Emit_Op:
			if d.opts.max_changes > 0 && len(ops) >= d.opts.max_changes {
				d.truncated = true
				break patch_loop
			}
			if task.has_s {
				append(&d.new, task.step) or_return
			}
			ptr, perr := encode_pointer(d.new[:], out_alloc)
			if task.has_s {
				pop(&d.new)
			}
			if perr != nil {
				return {}, perr
			}
			po := make_patch_op(task.op, ptr, b, task.b, out_alloc) or_return
			append(&ops, po) or_return
		case .Diff:
			if d.opts.max_changes > 0 && len(ops) >= d.opts.max_changes {
				d.truncated = true
				break patch_loop
			}
			if task.has_s {
				append(&stack, Patch_Task{kind = .Pop}) or_return
				append(&d.new, task.step) or_return
			}
			na, nb, depth := task.a, task.b, task.depth
			ca, cb := val_class(a, na), val_class(b, nb)
			if ca != cb {
				ptr := encode_pointer(d.new[:], out_alloc) or_return
				po := make_patch_op(.Replace, ptr, b, nb, out_alloc) or_return
				append(&ops, po) or_return
				continue
			}
			if ca != .Array && ca != .Object {
				if !scalars_equal(&d, na.node, nb.node) {
					ptr := encode_pointer(d.new[:], out_alloc) or_return
					append(&ops, Patch_Op{op = .Replace, path = ptr, doc = b, node = nb.node}) or_return
				}
				continue
			}
			if depth >= d.opts.max_depth {
				if !vals_equal_exact(&d, na, nb, depth) {
					if d.too_deep {
						break patch_loop
					}
					ptr := encode_pointer(d.new[:], out_alloc) or_return
					po := make_patch_op(.Replace, ptr, b, nb, out_alloc) or_return
					append(&ops, po) or_return
				}
				continue
			}
			if vals_equal(&d, na, nb, depth) {
				continue
			}
			if d.too_deep {
				break patch_loop
			}
			if ca == .Object {
				push_patch_object(&d, &stack, na.node, nb.node, depth) or_return
			} else {
				push_patch_array(&d, &stack, na, nb, depth, &ops, out_alloc) or_return
			}
		}
	}

	p.ops = ops[:]
	p.truncated = d.truncated
	p.too_deep = d.too_deep
	return p, nil
}

@(private = "file")
push_patch_object :: proc(d: ^Differ, stack: ^[dynamic]Patch_Task, a, b: tape.Node_Index, depth: int) -> Error {
	names := collect_object_names(d, a, b) or_return
	#reverse for name in names {
		va, in_a := member_val(d, 0, a, name) or_return
		vb, in_b := member_val(d, 1, b, name) or_return
		step := tape.Step(tape.Name(name))
		switch {
		case in_a && in_b:
			append(stack, Patch_Task{kind = .Diff, a = va, b = vb, step = step, has_s = true, depth = depth + 1}) or_return
		case in_a:
			append(stack, Patch_Task{kind = .Emit_Op, op = .Remove, step = step, has_s = true}) or_return
		case in_b:
			append(stack, Patch_Task{kind = .Emit_Op, op = .Add, b = vb, step = step, has_s = true}) or_return
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
	out_alloc: runtime.Allocator,
) -> Error {
	xs := val_elements(d, 0, a) or_return
	ys := val_elements(d, 1, b) or_return
	removed, added, ok := sequence_edits(d, xs, ys, depth) or_return
	if !ok {
		d.truncated = true
		ptr := encode_pointer(d.new[:], out_alloc) or_return
		po := make_patch_op(.Replace, ptr, d.docs[1], b, out_alloc) or_return
		append(ops, po) or_return
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
				depth = depth + 1,
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
