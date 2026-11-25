package jq

import "core:fmt"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/query"

// Compiling a program: parse it and the prelude, bind every name to where it is defined, and mark what the evaluator
// may run natively. No pass recurses over the tree: binding walks it with a stack of its own, and the marking passes
// are loops over the nodes in the order they were made, children first.

// A compiled program, immutable once made, so runs on many threads may share it.
Program :: struct {
	unit:    Unit,
	body:    ^Node,
	globals: []string, // the variables a run binds, by slot: `$ENV`, `$__prog_args`, then the caller's
	funcs:   [dynamic]^Func, // every function the program reaches
	prelude: ^Node, // the definitions of `PRELUDE`, chained by `a`
	empty:   query.Value, // an empty array, frozen
	modules: Modules, // what `get_search_list`, `modulemeta` and the linker were given
}

Compile_Options :: struct {
	// The deepest the parse stack may go, bison's YYMAXDEPTH: 0 for `tape.DEFAULT_DEPTH`, jq's 10,000.
	max_depth: int,
	// The names of the variables a run binds beside `$ENV` and `$__prog_args`, without their `$`, by slot.
	variables: []string,
	// Where `import` and `include` find their files. Without a loader a program with one does not compile.
	modules: Modules,
}

// The global slots every program has.
@(private)
GLOBAL_ENV :: 0
@(private)
GLOBAL_PROG_ARGS :: 1

// `src` compiled, or the errors that keep it from compiling, as jq reports them, in `allocator`. The program is freed by
// `destroy_program`, the errors with it.
compile :: proc(src: string, opts: Compile_Options = {}, allocator := context.allocator) -> (prog: ^Program, errors: []Compile_Error) {
	prog = new(Program, allocator)
	unit_init(&prog.unit, allocator)
	context.allocator = prog.unit.allocator
	u := &prog.unit
	prog.modules = clone_modules(opts.modules)
	errs := make([dynamic]Compile_Error)
	depth := opts.max_depth if opts.max_depth > 0 else tape.DEFAULT_DEPTH
	text := strings.clone(src)
	parsed := parse(u, text, &errs, depth)
	if len(errs) > 0 {
		return prog, errs[:]
	}
	imports, libs := link(&prog.modules, u, parsed.deps, &errs, depth)
	if len(errs) > 0 {
		return prog, errs[:]
	}
	prelude_start := len(u.order)
	prelude := parse(u, PRELUDE, &errs, tape.DEFAULT_DEPTH, "<builtin>")
	if len(errs) > 0 {
		panic(errs[0].msg)
	}
	globals := make([]string, 2 + len(opts.variables))
	globals[GLOBAL_ENV], globals[GLOBAL_PROG_ARGS] = "ENV", "__prog_args"
	copy(globals[2:], opts.variables)
	prog.globals = globals
	prog.prelude = prelude.defs
	r := Resolver{prog = prog, errors = &errs}
	scope := prelude_scope(&r, prelude.defs)
	for lib in libs {
		bind_lib(&r, lib, scope)
	}
	scope = import_scope(&r, imports, scope)
	body := parsed.body
	if body == nil {
		// A program of definitions only is `.` after them, as jq runs one.
		body = mk_node(u, Node{kind = .Identity})
		if parsed.defs != nil {
			last := parsed.defs
			for last.a != nil {
				last = last.a
			}
			last.a = body
			body = parsed.defs
		}
	}
	prog.body = body
	resolve(&r, body, scope, 0)
	for &e in errs {
		if e.src == "" {
			e.src = text
		}
	}
	if len(errs) > 0 {
		return prog, errs[:]
	}
	inline_prelude(prog, prelude_start)
	mark(prog)
	empty, _ := query.make_array(&u.heap, 0)
	prog.empty = query.freeze(empty)
	return prog, nil
}

// `m` with its strings and lists in the program's arena, which outlives the caller's.
@(private)
clone_modules :: proc(m: Modules) -> Modules {
	out := m
	out.search = make([]string, len(m.search))
	for dir, i in m.search {
		out.search[i] = strings.clone(dir)
	}
	out.origin, out.jq_origin, out.home = strings.clone(m.origin), strings.clone(m.jq_origin), strings.clone(m.home)
	return out
}

destroy_program :: proc(prog: ^Program) {
	if prog == nil {
		return
	}
	allocator := prog.unit.arena.block_allocator
	unit_destroy(&prog.unit)
	free(prog, allocator)
}

// A node made after parsing, recorded in the unit's order.
@(private)
mk_node :: proc(u: ^Unit, n: Node) -> ^Node {
	x := new_clone(n, u.allocator)
	append(&u.order, x)
	return x
}

// What a name is bound to while binding: a variable, label or filter argument in the scope `depth` makes, or a function.
@(private)
Scope :: struct {
	parent: ^Scope,
	kind:   Ref_Kind,
	name:   string,
	arity:  int, // a function's or filter argument's
	value:  query.Value, // a data import's
	depth:  u32, // the run-time scope it is in, or for a function the one its definition is in
	slot:   u16,
	fn:     ^Func,
}

@(private)
Resolver :: struct {
	prog:      ^Program,
	errors:    ^[dynamic]Compile_Error,
	stack:     [dynamic]Work,
	file, src: string, // the module being bound, "" for the program
}

// A node to bind, in the scope its names are looked up in, `depth` run-time scopes deep.
@(private)
Work :: struct {
	n:     ^Node,
	scope: ^Scope,
	depth: u32,
}

// A function's definition: the scope its body sees, and whether the body was queued for binding.
@(private)
Def_Info :: struct {
	scope: ^Scope, // holds the function itself, so it can recur
	depth: u32,
	bound: bool,
}

@(private)
prelude_scope :: proc(r: ^Resolver, defs: ^Node) -> ^Scope {
	s: ^Scope
	for d := defs; d != nil; d = d.a {
		d.fn.prelude = true
		s = def_entry(r, d.fn, s, 0)
	}
	return s
}

// The entry for a definition of `fn` over `s`, at run-time depth `depth`.
@(private)
def_entry :: proc(r: ^Resolver, fn: ^Func, s: ^Scope, depth: u32) -> ^Scope {
	desugar_value_params(&r.prog.unit, fn)
	e := new(Scope)
	e^ = {parent = s, kind = .Def, name = fn.name, arity = len(fn.params), depth = depth, fn = fn}
	info := new(Def_Info)
	info^ = {scope = e, depth = depth}
	fn_info(fn)^ = info
	return e
}

// The `Def_Info` a function keeps while binding, in its `body`'s spare field.
@(private)
fn_info :: proc(fn: ^Func) -> ^^Def_Info {
	return (^^Def_Info)(&fn.info)
}

// `def f($a): body` as `def f(a): a as $a | body`: each `$name` parameter is a filter whose values the body binds.
@(private)
desugar_value_params :: proc(u: ^Unit, fn: ^Func) {
	#reverse for &p in fn.params {
		if len(p) == 0 || p[0] != '$' {
			continue
		}
		name := p[1:]
		p = name
		arg := mk_node(u, Node{kind = .Call, name = name, loc = fn.loc})
		pats := make([]^Pattern, 1)
		pats[0] = new_clone(Pattern{kind = .Var, name = name})
		fn.body = mk_node(u, Node{kind = .Bind, a = arg, b = fn.body, patterns = pats, loc = fn.loc})
	}
	fn.slots = u16(len(fn.params))
}

@(private)
lookup :: proc(s: ^Scope, kind: Ref_Kind, name: string, arity: int) -> ^Scope {
	for e := s; e != nil; e = e.parent {
		if e.name != name {
			continue
		}
		switch kind {
		case .Var, .Label:
			// A data import's entry is a `.Global`: a variable of a constant value.
			if e.kind == kind || (kind == .Var && e.kind == .Global) {
				return e
			}
		case .Def, .Param:
			if (e.kind == .Def || e.kind == .Param) && e.arity == arity {
				return e
			}
		case .None, .Global:
		}
	}
	return nil
}

@(private)
compile_error :: proc(r: ^Resolver, n: ^Node, format: string, args: ..any) {
	append(r.errors, Compile_Error{msg = fmt.aprintf(format, ..args), loc = n.loc, file = r.file, src = r.src})
}

// Binds every name in `root` and in the functions it reaches, with no recursion.
@(private)
resolve :: proc(r: ^Resolver, root: ^Node, scope: ^Scope, depth: u32) {
	append(&r.stack, Work{root, scope, depth})
	drain(r)
}

// Binds the nodes queued, and those their calls queue.
@(private)
drain :: proc(r: ^Resolver) {
	for len(r.stack) > 0 {
		w := pop(&r.stack)
		n := w.n
		if n == nil {
			continue
		}
		switch n.kind {
		case .Var:
			resolve_var(r, n, w)
		case .Break:
			if e := lookup(w.scope, .Label, n.name, 0); e != nil {
				n.ref = {hops = w.depth - e.depth, slot = e.slot, kind = .Label}
			} else {
				compile_error(r, n, "$*label-%s is not defined", n.name)
			}
		case .Call:
			resolve_call(r, n, w)
			#reverse for a in n.args {
				append(&r.stack, Work{a, w.scope, w.depth})
			}
		case .Def:
			e := def_entry(r, n.fn, w.scope, w.depth)
			append(&r.stack, Work{n.a, e, w.depth})
		case .Bind, .Reduce, .Foreach:
			inner := bind_scope(n, w.scope, w.depth + 1)
			// The source and a reduce's or foreach's start see the outer scope. Single-pattern keys see the outer
			// scope; `?//` alternative keys see `inner` so earlier members' bindings are visible to later keys.
			outer := 1 if n.kind == .Bind else 2
			key_scope := inner if len(n.patterns) > 1 else w.scope
			key_depth := w.depth + 1 if len(n.patterns) > 1 else w.depth
			#reverse for k in n.keys {
				append(&r.stack, Work{k, key_scope, key_depth})
			}
			for i := 3; i >= outer; i -= 1 {
				append(&r.stack, Work{child(n, i), inner, w.depth + 1})
			}
			for i := outer - 1; i >= 0; i -= 1 {
				append(&r.stack, Work{child(n, i), w.scope, w.depth})
			}
		case .Label:
			e := new(Scope)
			e^ = {parent = w.scope, kind = .Label, name = n.name, depth = w.depth + 1}
			append(&r.stack, Work{n.a, e, w.depth + 1})
		case .Identity, .Field, .Index, .Slice, .Iterate, .Literal, .String, .Format, .Array, .Object, .Neg, .Pipe, .Comma,
		     .Binary, .And, .Or, .Alt, .If, .Try, .Update:
			for i := child_count(n) - 1; i >= 0; i -= 1 {
				append(&r.stack, Work{child(n, i), w.scope, w.depth})
			}
		}
	}
}

@(private)
resolve_var :: proc(r: ^Resolver, n: ^Node, w: Work) {
	if e := lookup(w.scope, .Var, n.name, 0); e != nil {
		if e.kind == .Global {
			n.kind, n.value = .Literal, e.value
			return
		}
		n.ref = {hops = w.depth - e.depth, slot = e.slot, kind = .Var}
		return
	}
	for g, i in r.prog.globals {
		if g == n.name {
			n.ref = {slot = u16(i), kind = .Global}
			return
		}
	}
	compile_error(r, n, "$%s is not defined", n.name)
}

@(private)
resolve_call :: proc(r: ^Resolver, n: ^Node, w: Work) {
	if e := lookup(w.scope, .Def, n.name, len(n.args)); e != nil {
		if e.kind == .Param {
			n.ref = {hops = w.depth - e.depth, slot = e.slot, kind = .Param}
			n.callee = e.fn
			return
		}
		n.ref = {hops = w.depth - e.depth, kind = .Def}
		n.callee = e.fn
		queue_body(r, e.fn)
		return
	}
	if b := find_builtin(n.name, len(n.args)); b != nil {
		n.builtin = b
		return
	}
	compile_error(r, n, "%s/%d is not defined", n.name, len(n.args))
}

// Queues the body of `fn` for binding, once: in the scope its definition made, with a slot for each parameter.
@(private)
queue_body :: proc(r: ^Resolver, fn: ^Func) {
	info := fn_info(fn)^
	if info.bound {
		return
	}
	info.bound = true
	append(&r.prog.funcs, fn)
	s := info.scope
	d := info.depth
	if len(fn.params) > 0 {
		d += 1
		for p, i in fn.params {
			x := new(Scope)
			x^ = {parent = s, kind = .Param, name = p, arity = 0, depth = d, slot = u16(i), fn = fn}
			s = x
		}
	}
	append(&r.stack, Work{fn.body, s, d})
}

// The scope over `s` that `imports` make: each module's definitions under its name, a data file's values as variables.
@(private)
import_scope :: proc(r: ^Resolver, imports: []Import, s: ^Scope) -> ^Scope {
	top := s
	for imp in imports {
		lib := imp.lib
		switch {
		case lib == nil:
		case lib.is_data:
			for name in ([2]string{imp.name, strings.concatenate({imp.name, "::", imp.name})}) {
				top = new_clone(Scope{parent = top, kind = .Global, name = name, value = lib.data})
			}
		case:
			for e in lib.entries {
				name := e.name if imp.name == "" else strings.concatenate({imp.name, "::", e.name})
				top = new_clone(Scope{parent = top, kind = .Def, name = name, arity = e.arity, fn = e.fn})
			}
		}
	}
	return top
}

// Binds the definitions of module `lib` over the scope `base` and what it imports, and every name in their bodies, so
// that an error in them is the module's. A module's functions are bound whether or not the program reaches them.
@(private)
bind_lib :: proc(r: ^Resolver, lib: ^Lib, base: ^Scope) {
	s := import_scope(r, lib.imports, base)
	entries := make([dynamic]^Scope)
	for d := lib.defs; d != nil; d = d.a {
		s = def_entry(r, d.fn, s, 0)
		append(&entries, s)
	}
	lib.entries = entries[:]
	r.file, r.src = lib.path, lib.src
	for e in lib.entries {
		queue_body(r, e.fn)
	}
	drain(r)
	r.file, r.src = "", ""
}

// The scope a binding makes over `s` at depth `depth`: a slot for each variable its patterns bind, the same name in two
// alternatives of `?//` sharing one.
@(private)
bind_scope :: proc(n: ^Node, s: ^Scope, depth: u32) -> ^Scope {
	top := s
	slots: u16
	stack := make([dynamic]^Pattern, 0, 8)
	defer delete(stack)
	bind_name :: proc(top: ^^Scope, s: ^Scope, slots: ^u16, depth: u32, name: string) -> u16 {
		for e := top^; e != s; e = e.parent {
			if e.name == name {
				return e.slot
			}
		}
		x := new(Scope)
		x^ = {parent = top^, kind = .Var, name = name, depth = depth, slot = slots^}
		top^ = x
		slots^ += 1
		return x.slot
	}
	#reverse for p in n.patterns {
		append(&stack, p)
	}
	for len(stack) > 0 {
		p := pop(&stack)
		switch p.kind {
		case .Var:
			p.slot = bind_name(&top, s, &slots, depth, p.name)
		case .Array:
			#reverse for e in p.elems {
				append(&stack, e)
			}
		case .Object:
			for &m in p.members {
				if m.var != "" {
					m.slot = bind_name(&top, s, &slots, depth, m.var)
				}
			}
			#reverse for m in p.members {
				if m.pattern != nil {
					append(&stack, m.pattern)
				}
			}
		}
	}
	n.slots = slots
	return top
}

// ---- Marking

// Marks each node single, native and its height, from its children: one loop over the nodes in their order for each
// round of the functions' singles, which only turn from true to false, then one for native and height.
@(private)
mark :: proc(prog: ^Program) {
	order := prog.unit.order[:]
	// A program with a `?//` takes the break `first` and `isempty` make after an output as an error and outputs again.
	alt := false
	for n in order {
		alt ||= len(n.patterns) > 1
	}
	for fn in prog.funcs {
		fn.single = true
		fn.params_single = make([]bool, len(fn.params))
		for &p in fn.params_single {
			p = true
		}
	}
	for {
		changed := false
		for n in order {
			s := single_of(n, alt, &changed)
			if s {
				n.flags += {.Single}
			} else {
				n.flags -= {.Single}
			}
		}
		for fn in prog.funcs {
			if fn.single && .Single not_in fn.body.flags {
				fn.single = false
				changed = true
			}
		}
		if !changed {
			break
		}
	}
	for n in order {
		h := 0
		native := .Single in n.flags && native_kind(n)
		for i in 0 ..< child_count(n) {
			c := child(n, i)
			if c == nil {
				continue
			}
			h = max(h, int(c.height))
			native &&= .Native in c.flags
		}
		if n.kind == .Array && !native {
			_, _, native = map_parts(n.a)
		}
		if n.kind == .Object && has_distinct_literal_keys(n) {
			n.flags += {.Distinct_Keys}
		}
		n.height = u8(min(h + 1, 255))
		if native && int(n.height) <= NATIVE_HEIGHT {
			n.flags += {.Native}
		}
	}
}

@(private)
is_single :: #force_inline proc(n: ^Node) -> bool {
	return n == nil || .Single in n.flags
}

@(private)
single_of :: proc(n: ^Node, alt: bool, changed: ^bool) -> bool {
	a, b, c := is_single(n.a), is_single(n.b), is_single(n.c)
	args := true
	for x in n.args {
		args &&= is_single(x)
	}
	keys := true
	for x in n.keys {
		keys &&= is_single(x)
	}
	switch n.kind {
	case .Identity, .Literal, .Array, .Var, .Break:
		return true
	case .Field, .Format, .Neg, .Label:
		return a
	case .Index, .Slice, .Pipe, .Binary, .And, .Or, .Alt, .Try, .If:
		return a && b && c
	case .Bind:
		// `?//` takes an error raised after its body's output, downstream, as its cue to try the next alternative, so
		// the rest must run inside it.
		return a && b && keys && len(n.patterns) == 1
	case .String, .Object:
		return args
	case .Reduce:
		return b
	case .Iterate, .Comma, .Foreach:
		return false
	case .Def:
		return a
	case .Update:
		return n.op == .Modify || b
	case .Call:
		return single_call(n, args, alt, changed)
	}
	return false
}

@(private)
single_call :: proc(n: ^Node, args, alt: bool, changed: ^bool) -> bool {
	fn := n.callee
	if n.ref.kind == .Param {
		return fn.params_single[n.ref.slot]
	}
	if fn != nil {
		for a, i in n.args {
			if !is_single(a) && fn.params_single[i] {
				fn.params_single[i] = false
				changed^ = true
			}
		}
		return fn.single
	}
	b := n.builtin
	if b == nil {
		return false
	}
	switch b.kind {
	case .Value:
		return args
	case .Single:
		return true
	case .Single_Args:
		return args
	case .Breaks:
		return !alt
	case .Generator:
	}
	return false
}

// Whether the native evaluator takes a node of `n`'s kind, given single children of its own kind.
// `[t[] | f]` or `[t[]]` with `t` and `f` native, which the native evaluator collects in one loop: `t`, `f` (nil for
// none) and whether `a` has that shape.
@(private)
map_parts :: proc(a: ^Node) -> (t: ^Node, f: ^Node, ok: bool) {
	if a == nil {
		return
	}
	it := a
	if a.kind == .Pipe {
		it, f = a.a, a.b
		if .Native not_in f.flags {
			return nil, nil, false
		}
	}
	if it.kind != .Iterate || .Native not_in it.a.flags {
		return nil, nil, false
	}
	return it.a, f, true
}

@(private)
has_distinct_literal_keys :: proc(n: ^Node) -> bool {
	if len(n.args) == 0 || len(n.args) > 32 {
		return false
	}
	for i := 0; i < len(n.args); i += 2 {
		k := n.args[i]
		if k == nil || k.kind != .Literal || k.value.kind != .String || n.args[i + 1] == nil {
			return false
		}
		ks := query.text_of(k.value)
		for j := 0; j < i; j += 2 {
			if query.text_of(n.args[j].value) == ks {
				return false
			}
		}
	}
	return true
}

// Whether `a` is a simple non-optional path chain `.`, `.k`, `.[expr]`, `.a.b[i]` (up to 8 steps) suitable for native update.
@(private)
simple_update_lhs :: proc(a: ^Node) -> bool {
	cur := a
	depth := 0
	for cur != nil {
		if cur.kind == .Identity {
			return true
		}
		if depth >= 8 || .Opt in cur.flags {
			return false
		}
		#partial switch cur.kind {
		case .Field:
			cur = cur.a
		case .Index:
			if cur.b == nil || .Native not_in cur.b.flags {
				return false
			}
			cur = cur.a
		case:
			return false
		}
		depth += 1
	}
	return false
}

@(private)
native_kind :: proc(n: ^Node) -> bool {
	#partial switch n.kind {
	case .Identity, .Field, .Index, .Slice, .Literal, .String, .Format, .Array, .Object, .Neg, .Pipe, .Binary, .And, .Or,
	     .Alt, .If, .Try:
		return true
	case .Var:
		return true
	case .Bind:
		return len(n.patterns) == 1
	case .Update:
		return simple_update_lhs(n.a)
	case .Call:
		return n.builtin != nil && n.builtin.native
	}
	return false
}

