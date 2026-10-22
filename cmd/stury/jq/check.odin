package jq

// Name resolution before running: a call to an undefined function or a use of an undefined variable is
// a compile error in jq, reported before any input is read, in the order jq's compiler meets them.
//
// jq first drops each definition nothing calls (block_bind_referenced), so an unused definition may name
// anything. It then compiles a function level by level: the instructions of the body, in order, and
// then, only if those had no error, each subfunction as a level of its own (a definition's body, and the
// arguments of a call to a function written in jq). The arguments of a builtin that takes values are
// instructions of the caller's level.

import "core:fmt"
import "core:slice"
import "core:strings"

@(private)
Scope :: struct {
	parent: ^Scope,
	name:   string,
	arity:  int, // -1 for a variable, -2 for a label
	env:    ^Env, // a prelude definition's own entry
	fn:     ^Func, // the function a definition's entry names, or whose parameter a parameter's names
	param:  int, // which parameter, -1 for a definition
	def:    ^Lib_Def, // a module's definition
}

@(private = "file")
Checker :: struct {
	errors: [dynamic]Compile_Error,
	vars:   []string, // those the command line defines
	// The module whose definition is being checked, by its path and text, "" for the program.
	file, src: string,
	// Only finding the module definitions the program reaches: no errors, and every level walked.
	reach:  bool,
}

// A subfunction met on a level, to check as a level of its own.
@(private = "file")
Later :: struct {
	n: ^Node,
	s: ^Scope,
}

// `n` without its unused definitions, and its undefined names as jq reports them. `vars` are the variables the
// command line defines, `linked`, the modules the program imports. Each call to a prelude definition, a module's
// definition or a builtin is bound to it on the way.
check :: proc(n: ^Node, vars: []string, linked: Linked = {}) -> (pruned: ^Node, errors: []Compile_Error, prelude: ^Env) {
	pruned = prune(n)
	calls: [dynamic]string
	globals := needs_globals(pruned, &calls)
	for lib in linked.libs {
		for d in lib.defs {
			d.env.fn.body = prune(d.env.fn.body)
			globals |= needs_globals(d.env.fn.body, &calls)
		}
	}
	names: ^Scope
	if globals {
		prelude, names = load_prelude(calls[:])
	}
	for lib in linked.libs {
		bind_library(lib, names)
	}
	root := import_scope(names, linked.imports)
	c := Checker{vars = vars}
	if len(linked.libs) == 0 {
		check_level(&c, pruned, root)
	} else {
		check_program(&c, pruned, root, linked.libs)
	}
	if len(c.errors) == 0 {
		mark_single(pruned, linked.libs, prelude)
	}
	return pruned, c.errors[:], prelude
}

// The scopes of a module's definitions, each over those before it and the module's imports.
@(private = "file")
bind_library :: proc(lib: ^Library, prelude_names: ^Scope) {
	s := import_scope(prelude_names, lib.imports)
	top := bind_data(nil, lib.imports)
	lib.bottom = top
	for lib.bottom != nil && lib.bottom.parent != nil {
		lib.bottom = lib.bottom.parent
	}
	for &d in lib.defs {
		d.env.parent = top
		top = d.env
		if lib.bottom == nil {
			lib.bottom = d.env
		}
		inner: ^Scope
		inner, d.body = def_scope(s, d.env.fn)
		inner.env, inner.def = d.env, &d
		s = inner
	}
}

// What `imports` bind over the scope `s`: each module's definitions under its name, a data file's variables.
@(private = "file")
import_scope :: proc(s: ^Scope, imports: []Import) -> ^Scope {
	s := s
	for imp in imports {
		switch {
		case imp.lib == nil:
		case imp.lib.is_data:
			s = new_scope(s, data_name(imp.name), -1)
			s = new_scope(s, imp.name, -1)
		case:
			for &d in imp.lib.defs {
				name := d.env.name if imp.name == "" else strings.concatenate({imp.name, "::", d.env.name})
				s = new_scope(s, name, d.env.arity)
				s.env, s.fn, s.param, s.def = d.env, d.env.fn, -1, &d
			}
		}
	}
	return s
}

// The data files of `imports` bound over `env`, at run time: `$name::name` and `$name` to each.
bind_data :: proc(env: ^Env, imports: []Import) -> ^Env {
	env := env
	for imp in imports {
		if imp.lib != nil && imp.lib.is_data {
			for name in ([2]string{data_name(imp.name), imp.name}) {
				e := new(Env)
				e^ = {parent = env, kind = .Var, name = name, value = imp.lib.data}
				env = e
			}
		}
	}
	return env
}

@(private = "file")
data_name :: proc(name: string) -> string {
	return strings.concatenate({name, "::", name})
}

// The program's level, then, if it had no errors, the module definitions it reaches, each a level, in the order jq
// compiles them (modules as they finished loading, each in its order), then its own subfunctions.
@(private = "file")
check_program :: proc(c: ^Checker, n: ^Node, s: ^Scope, libs: []^Library) {
	reach := Checker{vars = c.vars, reach = true}
	check_level(&reach, n, s)
	later := make([dynamic]Later)
	walk(c, n, s, &later)
	if len(c.errors) > 0 {
		return
	}
	for lib in libs {
		for d in lib.defs {
			if d.reached {
				c.file, c.src = lib.path, lib.src
				check_level(c, d.env.fn.body, d.body)
			}
		}
	}
	c.file, c.src = "", ""
	for l in later {
		check_level(c, l.n, l.s)
	}
}

// Whether `n` calls a function or reads `$ENV`. A program that does neither needs neither the prelude nor the
// environment as a value. Each name `n` calls is added to `calls` when there is one.
needs_globals :: proc(n: ^Node, calls: ^[dynamic]string = nil) -> bool {
	if n == nil {
		return false
	}
	found := n.kind == .Call || n.kind == .Var && n.name == "ENV"
	if n.kind == .Call && calls != nil {
		append(calls, n.name)
	}
	if n.kind == .Def {
		found |= needs_globals(n.fn.body, calls)
	}
	Walk :: struct {
		found: bool,
		calls: ^[dynamic]string,
	}
	w := Walk{found, calls}
	any_child(n, &w, proc(sub: ^^Node, w: ^Walk) -> bool {
		w.found |= needs_globals(sub^, w.calls)
		return false
	})
	return w.found
}

@(private = "file")
new_scope :: proc(parent: ^Scope, name: string, arity: int) -> ^Scope {
	s := new(Scope)
	s^ = {parent = parent, name = name, arity = arity}
	return s
}

// Bind the calls in the body of `def`, the newest prelude definition. `top` holds those before it, and the result
// holds `def` too.
bind_prelude_def :: proc(def: ^Env, top: ^Scope) -> ^Scope {
	inner, body := def_scope(top, def.fn)
	inner.env = def
	c: Checker
	check_level(&c, def.fn.body, body)
	if len(c.errors) > 0 {
		panic(c.errors[0].msg)
	}
	return inner
}

@(private = "file")
lookup :: proc(s: ^Scope, name: string, arity: int) -> ^Scope {
	for e := s; e != nil; e = e.parent {
		if e.name == name && e.arity == arity {
			return e
		}
	}
	return nil
}

// The scope a definition of `fn` opens over `s`: `inner` sees the function, `body` its parameters too.
@(private = "file")
def_scope :: proc(s: ^Scope, fn: ^Func) -> (inner, body: ^Scope) {
	inner = new_scope(s, fn.name, len(fn.params))
	inner.fn, inner.param = fn, -1
	body = inner
	for p, i in fn.params {
		if p[0] == '$' {
			body = new_scope(body, p[1:], -1)
			body = new_scope(body, p[1:], 0)
		} else {
			body = new_scope(body, p, 0)
		}
		body.fn, body.param = fn, i
	}
	return
}

// ---- Unused definitions

// `n` with each definition that its scope does not call dropped, innermost first.
@(private = "file")
prune :: proc(n: ^Node) -> ^Node {
	if n == nil {
		return nil
	}
	any_child(n, 0, proc(sub: ^^Node, _: int) -> bool {
		sub^ = prune(sub^)
		return false
	})
	if n.kind != .Def {
		return n
	}
	n.fn.body = prune(n.fn.body)
	return n if calls(n.a, n.fn.name, len(n.fn.params)) else n.a
}

// Whether `n` calls `name/arity` where no definition or parameter in `n` hides it.
@(private = "file")
calls :: proc(n: ^Node, name: string, arity: int) -> bool {
	if n == nil {
		return false
	}
	switch {
	case n.kind == .Call && n.name == name && len(n.args) == arity:
		return true
	case n.kind == .Def && n.fn.name == name && len(n.fn.params) == arity:
		return false
	case n.kind == .Def && !hides(n.fn, name, arity) && calls(n.fn.body, name, arity):
		return true
	}
	Called :: struct {
		name:  string,
		arity: int,
	}
	return any_child(n, Called{name, arity}, proc(sub: ^^Node, c: Called) -> bool {return calls(sub^, c.name, c.arity)})
}

// Whether a parameter of `fn` is `name/arity`: each parameter is a filter of arity 0, `$p` too.
@(private = "file")
hides :: proc(fn: ^Func, name: string, arity: int) -> bool {
	if arity != 0 {
		return false
	}
	for p in fn.params {
		if p == name || (p[0] == '$' && p[1:] == name) {
			return true
		}
	}
	return false
}

// ---- Levels

@(private = "file")
check_level :: proc(c: ^Checker, n: ^Node, s: ^Scope) {
	later := make([dynamic]Later)
	errors := len(c.errors)
	walk(c, n, s, &later)
	if len(c.errors) > errors {
		return
	}
	for l in later {
		check_level(c, l.n, l.s)
	}
}

@(private = "file")
undefined :: proc(c: ^Checker, n: ^Node, format: string, args: ..any) {
	if !c.reach {
		append(&c.errors, Compile_Error{msg = fmt.aprintf(format, ..args), loc = n.loc, file = c.file, src = c.src})
	}
}

// The instructions of `n`, in jq's order. Its subfunctions go to `later`.
@(private = "file")
walk :: proc(c: ^Checker, n: ^Node, s: ^Scope, later: ^[dynamic]Later) {
	if n == nil {
		return
	}
	switch n.kind {
	case .Identity, .Literal:
	case .Field, .Iterate, .Format, .Array, .Neg:
		walk(c, n.a, s, later)
	case .Index:
		walk(c, n.b, s, later)
		walk(c, n.a, s, later)
	case .Slice:
		walk(c, n.b, s, later)
		walk(c, n.c, s, later)
		walk(c, n.a, s, later)
	case .String, .Object:
		for p in n.args {
			walk(c, p, s, later)
		}
	case .Pipe, .Comma, .Binary, .And, .Or, .Alt, .Try, .If:
		walk(c, n.a, s, later)
		walk(c, n.b, s, later)
		walk(c, n.c, s, later)
	case .Reduce, .Foreach:
		walk(c, n.b, s, later)
		walk(c, n.a, s, later)
		inner := walk_patterns(c, n.patterns, s, later)
		walk(c, n.c, inner, later)
		walk(c, n.d, inner, later)
	case .Bind:
		walk(c, n.a, s, later)
		walk(c, n.b, walk_patterns(c, n.patterns, s, later), later)
	case .Label:
		walk(c, n.a, new_scope(s, n.name, -2), later)
	case .Def:
		inner, body := def_scope(s, n.fn)
		append(later, Later{n.fn.body, body})
		walk(c, n.a, inner, later)
	case .Update:
		// `=` and `|=` call jq functions with both sides, `op=` and `//=` compute the right side first.
		if n.op == .Assign || n.op == .Modify {
			append(later, Later{n.a, s}, Later{n.b, s})
		} else {
			walk(c, n.b, s, later)
			append(later, Later{n.a, s})
		}
	case .Call:
		walk_call(c, n, s, later)
	case .Var:
		if lookup(s, n.name, -1) == nil && n.name != "ENV" && n.name != "ARGS" && !slice.contains(c.vars, n.name) {
			undefined(c, n, "$%s is not defined", n.name)
		}
	case .Break:
		if lookup(s, n.name, -2) == nil {
			undefined(c, n, "$*label-%s is not defined", n.name)
		}
	}
}

// A call: undefined (its arguments unchecked), to a jq function (its arguments are subfunctions), or to
// a builtin (its value arguments are instructions here).
@(private = "file")
walk_call :: proc(c: ^Checker, n: ^Node, s: ^Scope, later: ^[dynamic]Later) {
	found := lookup(s, n.name, len(n.args))
	native := false
	if found == nil {
		b, has := builtin(n.name, len(n.args))
		if !has && !c.reach {
			undefined(c, n, "%s/%d is not defined", n.name, len(n.args))
			return
		}
		n.native = b
		native = has && b.native == nil && !b.in_jq
	} else {
		if c.reach && found.def != nil && !found.def.reached {
			found.def.reached = true
			append(later, Later{found.def.env.fn.body, found.def.body})
		}
		n.def = found.env
		n.callee, n.param, n.is_param = found.fn, found.param, found.param >= 0
	}
	for a in n.args {
		if native {
			walk(c, a, s, later)
		} else {
			append(later, Later{a, s})
		}
	}
}

// The scope an `as` opens: each variable of its patterns. Without `?//` an object pattern's key reads only the scope
// outside. With it, keys and body see every variable of every alternative.
@(private = "file")
walk_patterns :: proc(c: ^Checker, pats: []^Pattern, s: ^Scope, later: ^[dynamic]Later) -> ^Scope {
	inner := s
	for p in pats {
		inner = bind_pattern_vars(p, inner)
	}
	keys := s if len(pats) == 1 else inner
	for p in pats {
		walk_keys(c, p, keys, later)
	}
	return inner
}

@(private = "file")
bind_pattern_vars :: proc(p: ^Pattern, s: ^Scope) -> ^Scope {
	s := s
	switch p.kind {
	case .Var:
		s = new_scope(s, p.name, -1)
	case .Array:
		for e in p.elems {
			s = bind_pattern_vars(e, s)
		}
	case .Object:
		for m in p.members {
			if m.var != "" {
				s = new_scope(s, m.var, -1)
			}
			if m.pattern != nil {
				s = bind_pattern_vars(m.pattern, s)
			}
		}
	}
	return s
}

@(private = "file")
walk_keys :: proc(c: ^Checker, p: ^Pattern, s: ^Scope, later: ^[dynamic]Later) {
	for e in p.elems {
		walk_keys(c, e, s, later)
	}
	for m in p.members {
		walk(c, m.key, s, later)
		if m.pattern != nil {
			walk_keys(c, m.pattern, s, later)
		}
	}
}
