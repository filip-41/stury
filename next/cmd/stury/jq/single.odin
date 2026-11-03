package jq

// Which nodes are single: each has at most one output and does nothing after it, so running one to its
// end and then the rest of the filter is the same as running the rest inside its output, as a sink does.
// The evaluator runs a single node that way where the rest is a tail (a pipe's right side, an `if`'s
// branch, a function's body) and loops into the tail instead of nesting it, which makes a tail call cost
// no stack, as jq's TAIL_CALL_JQ does.
//
// A call to a jq function is as single as its body. A recursive function is taken to be single until its
// body shows otherwise, a sound guess for "at most one output", which only a finite run can refute. A
// filter parameter is single when every argument any call passes to it is.

// Mark `root`'s nodes, and those of the prelude and the modules `libs`, whose results depend on the
// program's calls.
mark_single :: proc(root: ^Node, libs: []^Library = nil, prelude: ^Env = nil) {
	// Whether the program has a `?//`, which takes the break `first` and `isempty` make after an output as
	// an error and outputs again: then neither is single.
	alt := has_alternation(root)
	init_funcs(root)
	for e := prelude; e != nil; e = e.parent {
		init_func(e.fn)
	}
	// Only the module definitions the program reaches are bound, and run.
	for lib in libs {
		for d in lib.defs {
			if d.reached {
				alt |= has_alternation(d.env.fn.body)
				init_func(d.env.fn)
			}
		}
	}
	// Each pass only turns results from true to false, so this ends.
	for {
		changed := false
		single_node(root, alt, &changed)
		for e := prelude; e != nil; e = e.parent {
			single_node(e.fn.body, alt, &changed)
			changed |= settle(e.fn, e.fn.body.single)
		}
		for lib in libs {
			for d in lib.defs {
				if d.reached {
					single_node(d.env.fn.body, alt, &changed)
					changed |= settle(d.env.fn, d.env.fn.body.single)
				}
			}
		}
		if !changed {
			return
		}
	}
}

@(private = "file")
has_alternation :: proc(n: ^Node) -> bool {
	if n == nil {
		return false
	}
	return len(n.patterns) > 1 || n.kind == .Def && has_alternation(n.fn.body) ||
		any_child(n, 0, proc(sub: ^^Node, _: int) -> bool {return has_alternation(sub^)})
}

// Every function defined in `n` taken to be single, its parameters too.
@(private = "file")
init_funcs :: proc(n: ^Node) {
	if n == nil {
		return
	}
	if n.kind == .Def {
		init_func(n.fn)
	}
	any_child(n, 0, proc(sub: ^^Node, _: int) -> bool {
		init_funcs(sub^)
		return false
	})
}

@(private = "file")
init_func :: proc(fn: ^Func) {
	fn.single = true
	fn.params_single = make([]bool, len(fn.params))
	for &p in fn.params_single {
		p = true
	}
	init_funcs(fn.body)
}

// `fn` single only while its body is. Whether that took a result back.
@(private = "file")
settle :: proc(fn: ^Func, body: bool) -> bool {
	if fn.single && !body {
		fn.single = false
		return true
	}
	return false
}

// `n`'s result and those of the nodes in it, from the current results on functions and parameters,
// which the calls in it may take back (`changed`).
@(private = "file")
single_node :: proc(n: ^Node, alt: bool, changed: ^bool) -> bool {
	if n == nil {
		return true
	}
	a, b, c := single_node(n.a, alt, changed), single_node(n.b, alt, changed), single_node(n.c, alt, changed)
	single_node(n.d, alt, changed)
	args := true
	for x in n.args {
		args &= single_node(x, alt, changed)
	}
	keys := true
	for p in n.patterns {
		keys &= single_keys(p, alt, changed)
	}
	s := false
	switch n.kind {
	case .Identity, .Literal, .Array, .Var, .Break:
		s = true
	case .Field, .Format, .Neg, .Label:
		s = a
	case .Index, .Slice, .Pipe, .Binary, .And, .Or, .Alt, .Try, .If:
		s = a && b && c
	case .Bind:
		// `?//` takes an error raised after its body's output, downstream, as its cue to try the next
		// alternative, so the rest must run inside it.
		s = a && b && keys && len(n.patterns) == 1
	case .String, .Object:
		s = args
	case .Reduce:
		s = b
	case .Iterate, .Comma, .Foreach:
		s = false
	case .Def:
		changed^ |= settle(n.fn, single_node(n.fn.body, alt, changed))
		s = a
	case .Update:
		s = n.op == .Modify || b
	case .Call:
		s = single_call(n, args, alt, changed)
	}
	n.single = s
	return s
}

@(private = "file")
single_keys :: proc(p: ^Pattern, alt: bool, changed: ^bool) -> bool {
	s := true
	for e in p.elems {
		s &= single_keys(e, alt, changed)
	}
	for m in p.members {
		s &= single_node(m.key, alt, changed)
		if m.pattern != nil {
			s &= single_keys(m.pattern, alt, changed)
		}
	}
	p.single = s
	return s
}

@(private = "file")
single_call :: proc(n: ^Node, args, alt: bool, changed: ^bool) -> bool {
	if n.is_param {
		return n.callee.params_single[n.param]
	}
	if fn := n.callee; fn != nil {
		// A `$name` parameter runs the call once for each value of its argument.
		values := true
		for a, i in n.args {
			if a.single {
				continue
			}
			if fn.params_single[i] {
				fn.params_single[i] = false
				changed^ = true
			}
			if fn.params[i][0] == '$' {
				values = false
			}
		}
		return fn.single && values
	}
	b, bound := n.native.?
	if !bound {
		return false
	}
	if b.native == nil && b.gen == nil {
		return args // a value builtin: one output for each combination of its arguments' values
	}
	switch n.name {
	case "first", "isempty":
		return !alt
	case "empty", "error", "values", "nulls", "booleans", "numbers", "strings", "arrays", "objects", "iterables", "scalars",
	     "last", "input", "debug", "stderr", "halt", "halt_error", "sort_by", "group_by", "unique_by":
		return true
	case "select", "path", "getpath":
		return args
	}
	return false
}
