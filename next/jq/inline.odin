package jq

// Inlining of the prelude: replaces calls to small non-binding, non-recursive prelude functions.

@(private) INLINE_NODES :: 64
@(private) Inline_State :: enum u8 { Unknown, No, Yes }

@(private)
inline_prelude :: proc(prog: ^Program, first: int) {
	order := prog.unit.order[:]
	changed := false
	for i in 0 ..< len(order) {
		n := order[(first + i) % len(order)]
		if n.kind == .Call && n.ref.kind == .Def && n.callee != nil && inlinable(n.callee) {
			inline_call(&prog.unit, n)
			changed = true
		}
	}
	if changed {
		reorder(prog)
	}
}

@(private)
inlinable :: proc(fn: ^Func) -> bool {
	if fn.inline != .Unknown {
		return fn.inline == .Yes
	}
	fn.inline = .No
	if !fn.prelude || fn.body == nil {
		return false
	}
	stack := make([dynamic]^Node)
	defer delete(stack)
	append(&stack, fn.body)
	uses := make([]int, len(fn.params))
	defer delete(uses)
	for nodes := 0; len(stack) > 0; {
		n := pop(&stack)
		nodes += 1
		if nodes > INLINE_NODES {
			return false
		}
		#partial switch n.kind {
		case .Def, .Bind, .Reduce, .Foreach, .Label, .Break, .Var:
			return false
		case .Call:
			switch n.ref.kind {
			case .Param:
				uses[n.ref.slot] += 1
				if uses[n.ref.slot] > 1 || len(n.args) > 0 {
					return false
				}
			case .Def:
				if n.callee == fn {
					return false
				}
			case .None:
				if n.builtin == nil {
					return false
				}
			case .Var, .Label, .Global:
				return false
			}
		}
		for i in 0 ..< child_count(n) {
			if c := child(n, i); c != nil {
				append(&stack, c)
			}
		}
	}
	fn.inline = .Yes
	return true
}

@(private)
inline_call :: proc(u: ^Unit, call: ^Node) {
	fn := call.callee
	shift := i64(call.ref.hops) - i64(len(fn.params) > 0)
	Copy :: struct { from: ^Node, to: ^^Node }
	root: ^Node
	stack := make([dynamic]Copy)
	defer delete(stack)
	append(&stack, Copy{fn.body, &root})
	for len(stack) > 0 {
		w := pop(&stack)
		src := w.from
		if src.kind == .Call && src.ref.kind == .Param {
			w.to^ = call.args[src.ref.slot]
			continue
		}
		dst := new_clone(src^, u.allocator)
		if dst.ref.kind == .Def {
			dst.ref.hops = u32(i64(dst.ref.hops) + shift)
		}
		if len(src.args) > 0 {
			dst.args = make([]^Node, len(src.args), u.allocator)
			for a, i in src.args {
				if a != nil {
					append(&stack, Copy{a, &dst.args[i]})
				}
			}
		}
		for slot in ([4]^^Node{&dst.a, &dst.b, &dst.c, &dst.d}) {
			if slot^ != nil {
				append(&stack, Copy{slot^, slot})
			}
		}
		w.to^ = dst
		append(&u.order, dst)
	}
	loc, name := call.loc, call.name
	call^ = root^
	call.loc = loc
	if call.name == "" {
		call.name = name
	}
}

@(private)
reorder :: proc(prog: ^Program) {
	Visit :: struct { n: ^Node, i: int }
	u := &prog.unit
	order := make([dynamic]^Node, 0, len(u.order), u.allocator)
	stack := make([dynamic]Visit)
	defer delete(stack)
	roots := make([dynamic]^Node)
	defer delete(roots)
	append(&roots, prog.body)
	for fn in prog.funcs {
		append(&roots, fn.body)
	}
	for root in roots {
		append(&stack, Visit{root, 0})
		for len(stack) > 0 {
			top := &stack[len(stack) - 1]
			if top.i == child_count(top.n) {
				append(&order, top.n)
				pop(&stack)
				continue
			}
			c := child(top.n, top.i)
			top.i += 1
			if c != nil {
				append(&stack, Visit{c, 0})
			}
		}
	}
	delete(u.order)
	u.order = order
}
