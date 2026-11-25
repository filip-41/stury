package jq

// Inlining of the prelude: a call of a prelude function that binds nothing and does not recur is replaced, once its names
// are bound, by a copy of the function's body with each filter argument in place of the call of its parameter. Such a
// call makes no scope at run time, so `map(f)` runs as `[.[] | f]` with no closure entry for each element. No pass
// recurses: copies and the order are made with stacks of their own.

// The most nodes a body may have and still be copied into each call of it.
@(private)
INLINE_NODES :: 64

// Replaces the inlinable calls of `prog`'s prelude functions, `first` the index in the unit's order of the prelude's
// first node. The prelude's nodes go first: its definitions are in order and each sees only the ones before it, so a body
// is final before any call copies it.
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
Inline_State :: enum u8 {
	Unknown,
	No,
	Yes,
}

// Whether the body of `fn` is made of nodes a call may copy: no binding, no variable, no label, no call of itself, each
// parameter called at most once, and few nodes.
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
	nodes := 0
	for len(stack) > 0 {
		n := pop(&stack)
		nodes += 1
		if nodes > INLINE_NODES {
			return false
		}
		switch n.kind {
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
		case .Identity, .Field, .Index, .Slice, .Iterate, .Literal, .String, .Format, .Array, .Object, .Neg, .Pipe, .Comma,
		     .Binary, .And, .Or, .Alt, .If, .Try, .Update:
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

// `call`, a call of an inlinable function, as a copy of the function's body. Its scopes are as the body's were, less the
// one a call with parameters makes and over the call's own distance to the prelude, which moves each function it calls.
@(private)
inline_call :: proc(u: ^Unit, call: ^Node) {
	fn := call.callee
	shift := i64(call.ref.hops)
	if len(fn.params) > 0 {
		shift -= 1
	}
	Copy :: struct {
		from: ^Node,
		to:   ^^Node,
	}
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

// The unit's order again, children first, from the program's body and every function's.
@(private)
reorder :: proc(prog: ^Program) {
	Visit :: struct {
		n: ^Node,
		i: int,
	}
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
