package query

import "stury:lib/core/tape"
import "stury:lib/ops/diff"

// RFC 6902 JSON Patch (`apply_patch`) and RFC 7396 JSON Merge Patch (`apply_merge_patch`, `diff_merge_patch`).
// All traversals use explicit heap stacks (zero native recursion). `apply_patch` is atomic: any failing op leaves
// the caller's `target` untouched.

apply_patch :: proc {
	apply_patch_ops,
	apply_patch_value,
}

@(private = "file")
reject_partial :: proc(h: ^Heap, v: Value) -> Status {
	if value_has_partial(v) {
		h.tainted = true
		return fail(h, .Range, .Pointer, detail = "cannot patch partial document")
	}
	return .Ok
}

// Applies a sequence of RFC 6902 `diff.Patch_Op` operations atomically to `target` (borrowed).
// Returns a newly retained patched value, or `.Error` with `target` unmodified.
@(require_results)
apply_patch_ops :: proc(h: ^Heap, target: Value, ops: []diff.Patch_Op) -> (res: Value, status: Status) {
	reject_partial(h, target) or_return
	cur := retain(target)
	defer if status != .Ok {
		release(h, cur)
	}
	for op in ops {
		val := ABSENT
		need_val := op.op == .Add || op.op == .Replace || op.op == .Test
		if need_val {
			val = materialize_op_val(h, op) or_return
		}
		next, s := apply_one_op(h, cur, op.op, op.path, op.from, val)
		release(h, val)
		if s != .Ok {
			cur = ABSENT // `apply_one_op` released `cur` on error
			return NULL, s
		}
		cur = next
	}
	if h.tainted {
		return NULL, fail(h, .Range, .Pointer, detail = "cannot patch partial document")
	}
	return cur, .Ok
}

// Applies an RFC 6902 JSON Patch document (an array of op objects `{"op", "path", ...}`) atomically to `target`.
@(require_results)
apply_patch_value :: proc(h: ^Heap, target: Value, patch: Value) -> (res: Value, status: Status) {
	reject_partial(h, target) or_return
	reject_partial(h, patch) or_return
	if type_of(patch) != .Array {
		return NULL, fail(h, .Types, .Pointer, patch, detail = "JSON Patch must be an array")
	}
	cur := retain(target)
	defer if status != .Ok {
		release(h, cur)
	}
	c := cursor_open(h, patch) or_return
	defer cursor_close(&c)
	for {
		_, item, more, cs := cursor_next(h, &c)
		if cs != .Ok {
			return NULL, cs
		}
		if !more {
			break
		}
		defer release(h, item)
		if type_of(item) != .Object {
			return NULL, fail(h, .Types, .Pointer, item, detail = "patch operation must be an object")
		}
		op_v := member(h, item, "op") or_return
		defer release(h, op_v)
		if !is_text(op_v) {
			return NULL, fail(h, .Parse, .Pointer, item, detail = "patch operation missing string 'op'")
		}
		kind, ok_kind := parse_patch_op(text_of(op_v))
		if !ok_kind {
			return NULL, fail(h, .Parse, .Pointer, op_v, detail = "unknown patch op")
		}
		path_v := member(h, item, "path") or_return
		defer release(h, path_v)
		if !is_text(path_v) {
			return NULL, fail(h, .Parse, .Pointer, item, detail = "patch operation missing string 'path'")
		}
		from_v := ABSENT
		defer release(h, from_v)
		from_s := ""
		if kind == .Move || kind == .Copy {
			from_v = member(h, item, "from") or_return
			if !is_text(from_v) {
				return NULL, fail(h, .Parse, .Pointer, item, detail = "move/copy operation missing string 'from'")
			}
			from_s = text_of(from_v)
		}
		val_v := ABSENT
		defer release(h, val_v)
		if kind == .Add || kind == .Replace || kind == .Test {
			val_v = member(h, item, "value") or_return
			if val_v.kind == .Absent {
				return NULL, fail(h, .Parse, .Pointer, item, detail = "patch operation missing 'value'")
			}
		}
		next, s := apply_one_op(h, cur, kind, text_of(path_v), from_s, val_v)
		if s != .Ok {
			cur = ABSENT
			return NULL, s
		}
		cur = next
	}
	if h.tainted {
		return NULL, fail(h, .Range, .Pointer, detail = "cannot patch partial document")
	}
	return cur, .Ok
}

@(private = "file")
parse_patch_op :: proc "contextless" (name: string) -> (diff.Patch_Op_Kind, bool) {
	switch name {
	case "add":
		return .Add, true
	case "remove":
		return .Remove, true
	case "replace":
		return .Replace, true
	case "move":
		return .Move, true
	case "copy":
		return .Copy, true
	case "test":
		return .Test, true
	}
	return .Add, false
}

// Applies a single RFC 6902 op to `cur` (consumed; released on error). `val` is borrowed (retained if inserted).
@(private = "file", require_results)
apply_one_op :: proc(h: ^Heap, cur: Value, kind: diff.Patch_Op_Kind, path, from: string, val: Value) -> (res: Value, status: Status) {
	switch kind {
	case .Add:
		return ptr_mutate(h, cur, path, .Add, retain(val))
	case .Remove:
		return ptr_mutate(h, cur, path, .Remove, ABSENT)
	case .Replace:
		return ptr_mutate(h, cur, path, .Replace, retain(val))
	case .Test:
		got, s := ptr_get(h, cur, path)
		if s != .Ok {
			release(h, cur)
			return NULL, s
		}
		defer release(h, got)
		eq, es := equal(h, got, val)
		if es != .Ok {
			release(h, cur)
			return NULL, es
		}
		if !eq {
			release(h, cur)
			return NULL, fail(h, .Raised, .Pointer, got, val, "patch test failed")
		}
		return cur, .Ok
	case .Copy:
		copied, s := ptr_get(h, cur, from)
		if s != .Ok {
			release(h, cur)
			return NULL, s
		}
		return ptr_mutate(h, cur, path, .Add, copied)
	case .Move:
		if is_proper_prefix(from, path) {
			release(h, cur)
			return NULL, fail(h, .Range, .Pointer, detail = "move 'from' cannot be a proper prefix of 'path'")
		}
		moved, gs := ptr_get(h, cur, from)
		if gs != .Ok {
			release(h, cur)
			return NULL, gs
		}
		if from == path {
			release(h, moved)
			return cur, .Ok
		}
		after_rm, rs := ptr_mutate(h, cur, from, .Remove, ABSENT)
		if rs != .Ok {
			release(h, moved)
			return NULL, rs
		}
		return ptr_mutate(h, after_rm, path, .Add, moved)
	}
	release(h, cur)
	return NULL, fail(h, .Parse, .Pointer, detail = "invalid patch op")
}

@(private = "file")
is_proper_prefix :: proc "contextless" (from, path: string) -> bool {
	if len(from) == 0 {
		return len(path) > 0
	}
	return len(path) > len(from) && path[:len(from)] == from && path[len(from)] == '/'
}

@(private = "file")
decode_ptr :: proc(h: ^Heap, ptr: string) -> (tokens: []string, status: Status) {
	alloc := heap_allocator(h)
	toks, perr := diff.decode_pointer(ptr, alloc)
	switch perr {
	case .None:
		if len(toks) > depth_limit(h) {
			diff.destroy_pointer_tokens(toks, alloc)
			return nil, fail(h, .Depth, .Pointer)
		}
		return toks, .Ok
	case .Out_Of_Memory:
		return nil, fail_memory(h)
	case .Missing_Slash:
		return nil, fail(h, .Parse, .Pointer, detail = "JSON Pointer must be empty or start with '/'")
	case .Bad_Escape:
		return nil, fail(h, .Parse, .Pointer, detail = "invalid JSON Pointer '~' escape")
	}
	return nil, fail(h, .Parse, .Pointer)
}

// Resolves `ptr` in `root` (borrowed), returning a retained value or `.Error` if missing/invalid.
@(private = "file", require_results)
ptr_get :: proc(h: ^Heap, root: Value, ptr: string) -> (res: Value, status: Status) {
	alloc := heap_allocator(h)
	tokens := decode_ptr(h, ptr) or_return
	defer diff.destroy_pointer_tokens(tokens, alloc)

	cur := retain(root)
	for tok in tokens {
		next: Value
		s: Status
		#partial switch type_of(cur) {
		case .Object:
			next, s = member(h, cur, tok)
			if s == .Ok && next.kind == .Absent {
				release(h, cur)
				return NULL, fail(h, .Range, .Pointer, detail = "pointer target member not found")
			}
		case .Array:
			idx, is_dash, ok := diff.parse_array_index(tok)
			if !ok || is_dash || idx < 0 || idx >= length_of(h, cur) {
				release(h, cur)
				return NULL, fail(h, .Range, .Pointer, detail = "pointer array index out of bounds")
			}
			next, s = element(h, cur, idx)
		case:
			release(h, cur)
			return NULL, fail(h, .Types, .Pointer, detail = "cannot traverse scalar with JSON Pointer")
		}
		release(h, cur)
		if s != .Ok {
			return NULL, s
		}
		cur = next
	}
	return cur, .Ok
}

@(private = "file")
Mut_Kind :: enum u8 {
	Add,
	Remove,
	Replace,
}

@(private = "file")
Chain_Step :: struct {
	parent: Value,
	is_arr: bool,
	key:    string, // borrowed from `tokens`
	idx:    int,
}

// Mutates `root` (consumed) at RFC 6901 `ptr` using `val` (consumed). Releases `root` and `val` on error.
@(private = "file", require_results)
ptr_mutate :: proc(h: ^Heap, root: Value, ptr: string, mut: Mut_Kind, val: Value) -> (res: Value, status: Status) {
	alloc := heap_allocator(h)
	tokens, ds := decode_ptr(h, ptr)
	if ds != .Ok {
		release(h, root)
		release(h, val)
		return NULL, ds
	}
	defer diff.destroy_pointer_tokens(tokens, alloc)

	if len(tokens) == 0 {
		if mut == .Remove {
			release(h, root)
			release(h, val)
			return NULL, fail(h, .Range, .Pointer, detail = "cannot remove root document")
		}
		release(h, root)
		return val, .Ok
	}

	chain := make([dynamic]Chain_Step, 0, len(tokens) - 1, alloc)
	defer {
		for st in chain {
			release(h, st.parent)
		}
		delete(chain)
	}

	cur := root
	for tok in tokens[:len(tokens) - 1] {
		child: Value
		s: Status
		is_arr := false
		idx := 0
		#partial switch type_of(cur) {
		case .Object:
			child, s = member(h, cur, tok)
			if s == .Ok && child.kind == .Absent {
				release(h, cur)
				release(h, val)
				return NULL, fail(h, .Range, .Pointer, detail = "intermediate object member missing")
			}
		case .Array:
			is_arr = true
			is_dash, ok: bool
			idx, is_dash, ok = diff.parse_array_index(tok)
			if !ok || is_dash || idx < 0 || idx >= length_of(h, cur) {
				release(h, cur)
				release(h, val)
				return NULL, fail(h, .Range, .Pointer, detail = "intermediate array index out of bounds")
			}
			child, s = element(h, cur, idx)
		case:
			release(h, cur)
			release(h, val)
			return NULL, fail(h, .Types, .Pointer, detail = "cannot traverse scalar with JSON Pointer")
		}
		if s != .Ok {
			release(h, cur)
			release(h, val)
			return NULL, s
		}
		if _, aerr := append(&chain, Chain_Step{parent = cur, is_arr = is_arr, key = tok, idx = idx}); aerr != nil {
			release(h, cur)
			release(h, child)
			release(h, val)
			return NULL, fail_memory(h)
		}
		cur = child
	}

	last := tokens[len(tokens) - 1]
	leaf, ls := mutate_leaf(h, cur, last, mut, val)
	if ls != .Ok {
		return NULL, ls
	}
	cur = leaf

	#reverse for &st in chain {
		parent := st.parent
		st.parent = ABSENT
		if parent.kind == .Node {
			b, bs := built(h, parent)
			release(h, parent)
			if bs != .Ok {
				release(h, cur)
				return NULL, bs
			}
			parent = b
		}
		if st.is_arr {
			if ps := array_put(h, &parent, st.idx, cur); ps != .Ok {
				release(h, parent)
				return NULL, ps
			}
		} else {
			kv, ks := text_value(h, st.key)
			if ks != .Ok {
				release(h, parent)
				release(h, cur)
				return NULL, ks
			}
			if ps := object_put(h, &parent, kv, cur); ps != .Ok {
				release(h, parent)
				return NULL, ps
			}
		}
		cur = parent
	}
	return cur, .Ok
}

// Applies `mut` at the final token `tok` of container `parent` (consumed), with `val` (consumed).
@(private = "file", require_results)
mutate_leaf :: proc(h: ^Heap, parent: Value, tok: string, mut: Mut_Kind, val: Value) -> (res: Value, status: Status) {
	#partial switch type_of(parent) {
	case .Object:
		if mut == .Remove || mut == .Replace {
			if !has_member(h, parent, tok) {
				release(h, parent)
				release(h, val)
				return NULL, fail(h, .Range, .Pointer, detail = "target object member does not exist")
			}
		}
		out := parent
		if out.kind == .Node {
			b, bs := built(h, out)
			release(h, out)
			if bs != .Ok {
				release(h, val)
				return NULL, bs
			}
			out = b
		}
		if mut == .Remove {
			if ds := object_delete(h, &out, tok); ds != .Ok {
				release(h, out)
				return NULL, ds
			}
			return out, .Ok
		}
		kv, ks := text_value(h, tok)
		if ks != .Ok {
			release(h, out)
			release(h, val)
			return NULL, ks
		}
		if ps := object_put(h, &out, kv, val); ps != .Ok {
			release(h, out)
			return NULL, ps
		}
		return out, .Ok

	case .Array:
		n := length_of(h, parent)
		idx, is_dash, ok := diff.parse_array_index(tok)
		if !ok {
			release(h, parent)
			release(h, val)
			return NULL, fail(h, .Parse, .Pointer, detail = "invalid array index in JSON Pointer")
		}
		switch mut {
		case .Add:
			if is_dash {
				idx = n
			} else if idx < 0 || idx > n {
				release(h, parent)
				release(h, val)
				return NULL, fail(h, .Range, .Pointer, detail = "add array index out of bounds")
			}
		case .Remove, .Replace:
			if is_dash || idx < 0 || idx >= n {
				release(h, parent)
				release(h, val)
				return NULL, fail(h, .Range, .Pointer, detail = "array index out of bounds")
			}
		}
		out := parent
		if out.kind == .Node {
			b, bs := built(h, out)
			release(h, out)
			if bs != .Ok {
				release(h, val)
				return NULL, bs
			}
			out = b
		}
		switch mut {
		case .Add:
			if is := array_insert(h, &out, idx, val); is != .Ok {
				release(h, out)
				return NULL, is
			}
		case .Remove:
			if rs := array_remove(h, &out, idx); rs != .Ok {
				release(h, out)
				return NULL, rs
			}
		case .Replace:
			if ps := array_put(h, &out, idx, val); ps != .Ok {
				release(h, out)
				return NULL, ps
			}
		}
		return out, .Ok
	}
	release(h, parent)
	release(h, val)
	return NULL, fail(h, .Types, .Pointer, detail = "patch parent is not an object or array")
}

// Inserts `x` (consumed) at `idx` (`0 <= idx <= len`) in built array `a^`.
@(private = "file", require_results)
array_insert :: proc(h: ^Heap, a: ^Value, idx: int, x: Value) -> Status #no_bounds_check {
	if s := own_array(h, a, 1); s != .Ok {
		release(h, x)
		return s
	}
	b := (^Array_Block)(a.p)
	n := int(b.len)
	items := ([^]Value)(uintptr(b) + size_of(Array_Block))
	if idx < n {
		copy(items[idx + 1 : n + 1], items[idx:n])
	}
	items[idx] = x
	b.len = u32(n + 1)
	if x.held {
		b.flags |= BLOCK_HAS_HELD
	}
	if x.kind >= .Array {
		b.flags |= BLOCK_HAS_CONTAINER
		if value_has_partial(x) {
			b.flags |= BLOCK_HAS_PARTIAL
		}
	}
	return .Ok
}

// Removes element `idx` (`0 <= idx < len`) from built array `a^`.
@(private = "file", require_results)
array_remove :: proc(h: ^Heap, a: ^Value, idx: int) -> Status #no_bounds_check {
	own_array(h, a, 0) or_return
	b := (^Array_Block)(a.p)
	n := int(b.len)
	items := ([^]Value)(uintptr(b) + size_of(Array_Block))
	release(h, items[idx])
	if idx + 1 < n {
		copy(items[idx : n - 1], items[idx + 1 : n])
	}
	b.len = u32(n - 1)
	return .Ok
}

// ---- Materialization of a `diff.Patch_Op`'s `(doc, node / nodes)` via `built_deep`

@(private = "file", require_results)
materialize_op_val :: proc(h: ^Heap, op: diff.Patch_Op) -> (res: Value, status: Status) {
	if op.doc == nil || (len(op.nodes) == 0 && op.node == tape.NO_NODE) {
		return NULL, fail(h, .Parse, .Pointer, detail = "patch op missing value")
	}
	if op.doc.partial != nil {
		h.tainted = true
		return NULL, fail(h, .Range, .Pointer, detail = "cannot patch from partial document")
	}
	b := alloc_block(h, size_of(Doc_Block)) or_return
	d := (^Doc_Block)(b)
	d.doc, d.owned = op.doc^, false
	d.index = {allocator = heap_allocator(h)}
	holder := Value{p = d, n = 0, kind = .Node, held = true}
	defer release(h, holder)

	if len(op.nodes) > 0 {
		arr := make_array(h, len(op.nodes)) or_return
		defer if status != .Ok {
			release(h, arr)
		}
		for at in op.nodes {
			if int(at) >= len(d.doc.nodes) {
				return NULL, fail(h, .Range, .Pointer, detail = "node index out of range")
			}
			ref := node_value(h, d, at) or_return
			v, vs := built_deep(h, ref)
			release(h, ref)
			if vs != .Ok {
				return NULL, vs
			}
			append_owned(h, &arr, v) or_return
		}
		return arr, .Ok
	}
	if int(op.node) >= len(d.doc.nodes) {
		return NULL, fail(h, .Range, .Pointer, detail = "node index out of range")
	}
	ref := node_value(h, d, op.node) or_return
	defer release(h, ref)
	return built_deep(h, ref)
}

// ---- RFC 7396 JSON Merge Patch (explicit heap stack, zero native recursion)

@(private = "file")
Merge_Frame :: struct {
	out:     Value,  // built object being assembled
	target:  Value,  // borrowed original target (`.Absent` if non-object or missing)
	patch:   Value,  // retained patch object
	c:       Cursor, // cursor over `patch`
	pending: Value,  // owned key waiting for child merge
}

// Applies RFC 7396 JSON Merge Patch `patch` to `target` (both borrowed), returning the merged value.
@(require_results)
apply_merge_patch :: proc(h: ^Heap, target, patch: Value) -> (res: Value, status: Status) {
	reject_partial(h, target) or_return
	reject_partial(h, patch) or_return
	if type_of(patch) != .Object {
		return retain(patch), .Ok
	}
	alloc := heap_allocator(h)
	stack := make([dynamic]Merge_Frame, 0, 16, alloc)
	defer {
		for &f in stack {
			cursor_close(&f.c)
			release(h, f.out)
			release(h, f.target)
			release(h, f.patch)
			release(h, f.pending)
		}
		delete(stack)
	}

	open_merge :: proc(h: ^Heap, stack: ^[dynamic]Merge_Frame, tgt, pat: Value) -> Status {
		if len(stack) >= depth_limit(h) {
			return fail(h, .Depth, .Merge)
		}
		out: Value
		if type_of(tgt) == .Object {
			out = built(h, tgt) or_return
		} else {
			out = make_object(h, max(length_of(h, pat), 1)) or_return
		}
		c, cs := cursor_open(h, pat)
		if cs != .Ok {
			release(h, out)
			return cs
		}
		f := Merge_Frame {
			out    = out,
			target = retain(tgt) if type_of(tgt) == .Object else ABSENT,
			patch  = retain(pat),
			c      = c,
		}
		if _, aerr := append(stack, f); aerr != nil {
			cursor_close(&f.c)
			release(h, f.out)
			release(h, f.target)
			release(h, f.patch)
			return fail_memory(h)
		}
		return .Ok
	}

	open_merge(h, &stack, target, patch) or_return
	for len(stack) > 0 {
		f := &stack[len(stack) - 1]
		key, pv, more, cs := cursor_next(h, &f.c)
		if cs != .Ok {
			return NULL, cs
		}
		if !more {
			done := f.out
			f.out = ABSENT
			cursor_close(&f.c)
			release(h, f.target)
			release(h, f.patch)
			f.target, f.patch = ABSENT, ABSENT
			pop(&stack)
			if len(stack) == 0 {
				return done, .Ok
			}
			parent := &stack[len(stack) - 1]
			pk := parent.pending
			parent.pending = ABSENT
			object_put(h, &parent.out, pk, done) or_return
			continue
		}

		pt := type_of(pv)
		if pt == .Null {
			release(h, pv)
			ds := object_delete(h, &f.out, text_of(key))
			release(h, key)
			if ds != .Ok {
				return NULL, ds
			}
			continue
		}
		if pt == .Object {
			existing := ABSENT
			if f.target.kind != .Absent {
				ex, ms := member(h, f.target, text_of(key))
				if ms != .Ok {
					release(h, key)
					release(h, pv)
					return NULL, ms
				}
				existing = ex
			}
			f.pending = key
			os := open_merge(h, &stack, existing, pv)
			release(h, existing)
			release(h, pv)
			if os != .Ok {
				return NULL, os
			}
			continue
		}
		object_put(h, &f.out, key, pv) or_return
	}
	return NULL, .Ok
}

// Computes an RFC 7396 JSON Merge Patch transforming `a` into `b` (both borrowed), using an explicit heap stack.
@(require_results)
diff_merge_patch :: proc(h: ^Heap, a, b: Value) -> (res: Value, status: Status) {
	reject_partial(h, a) or_return
	reject_partial(h, b) or_return
	if type_of(a) != .Object || type_of(b) != .Object {
		return retain(b), .Ok
	}
	Diff_Merge_Frame :: struct {
		a, b:    Value,
		out:     Value,
		c:       Cursor,
		pending: Value,
	}
	alloc := heap_allocator(h)
	stack := make([dynamic]Diff_Merge_Frame, 0, 16, alloc)
	defer {
		for &f in stack {
			cursor_close(&f.c)
			release(h, f.a)
			release(h, f.b)
			release(h, f.out)
			release(h, f.pending)
		}
		delete(stack)
	}

	open_diff :: proc(h: ^Heap, stack: ^[dynamic]Diff_Merge_Frame, va, vb: Value) -> Status {
		if len(stack) >= depth_limit(h) {
			return fail(h, .Depth, .Merge)
		}
		out := make_object(h, 4) or_return
		// Emit `null` for any member present in `a` and absent in `b`.
		ca, cas := cursor_open(h, va)
		if cas != .Ok {
			release(h, out)
			return cas
		}
		for {
			k, x, more, ns := cursor_next(h, &ca)
			release(h, x)
			if ns != .Ok {
				release(h, k)
				cursor_close(&ca)
				release(h, out)
				return ns
			}
			if !more {
				break
			}
			if !has_member(h, vb, text_of(k)) {
				if ps := object_put(h, &out, k, NULL); ps != .Ok {
					cursor_close(&ca)
					release(h, out)
					return ps
				}
			} else {
				release(h, k)
			}
		}
		cursor_close(&ca)

		cb, cbs := cursor_open(h, vb)
		if cbs != .Ok {
			release(h, out)
			return cbs
		}
		f := Diff_Merge_Frame {
			a   = retain(va),
			b   = retain(vb),
			out = out,
			c   = cb,
		}
		if _, aerr := append(stack, f); aerr != nil {
			cursor_close(&f.c)
			release(h, f.a)
			release(h, f.b)
			release(h, f.out)
			return fail_memory(h)
		}
		return .Ok
	}

	open_diff(h, &stack, a, b) or_return
	for len(stack) > 0 {
		f := &stack[len(stack) - 1]
		key, bv, more, cs := cursor_next(h, &f.c)
		if cs != .Ok {
			return NULL, cs
		}
		if !more {
			done := f.out
			f.out = ABSENT
			cursor_close(&f.c)
			release(h, f.a)
			release(h, f.b)
			f.a, f.b = ABSENT, ABSENT
			pop(&stack)
			if len(stack) == 0 {
				return done, .Ok
			}
			parent := &stack[len(stack) - 1]
			pk := parent.pending
			parent.pending = ABSENT
			object_put(h, &parent.out, pk, done) or_return
			continue
		}

		av, ms := member(h, f.a, text_of(key))
		if ms != .Ok {
			release(h, key)
			release(h, bv)
			return NULL, ms
		}
		if av.kind == .Absent {
			if type_of(bv) == .Null {
				release(h, key)
				release(h, bv)
				continue
			}
			object_put(h, &f.out, key, bv) or_return
			continue
		}
		eq, es := equal(h, av, bv)
		if es != .Ok {
			release(h, av)
			release(h, key)
			release(h, bv)
			return NULL, es
		}
		if eq {
			release(h, av)
			release(h, key)
			release(h, bv)
			continue
		}
		if type_of(av) == .Object && type_of(bv) == .Object {
			f.pending = key
			os := open_diff(h, &stack, av, bv)
			release(h, av)
			release(h, bv)
			if os != .Ok {
				return NULL, os
			}
			continue
		}
		release(h, av)
		object_put(h, &f.out, key, bv) or_return
	}
	return NULL, .Ok
}
