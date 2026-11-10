package jq

// The forms of a filter, typed (types.odin).

import "base:runtime"
import "core:strings"
import "../message"
import "../../../core/rules"

// What a name means where a form is typed: a variable, a definition, or a call of one, which holds its arguments, the
// caller's frame they are typed in, and the values of its `$` parameters.
@(private)
Frame :: struct {
	parent: ^Frame,
	name:   string, // a variable's
	value:  Ty,
	fn:     ^Func, // a definition's, a call's
	called: bool,
	args:   []^Node,
	values: []Ty,
	scope:  ^Frame,
	site:   Maybe(Loc),
}

// A node every output of `n` passes, on an input of `dot`.
@(private)
type_of :: proc(t: ^Typer, n: ^Node, dot: Ty, f: ^Frame) -> Ty {
	if n == nil {
		return dot
	}
	t.steps += 1
	if dot == t.never || t.steps > TYPE_STEPS || t.nesting >= MAX_NESTING {
		return t.never if dot == t.never else t.unknown
	}
	t.nesting += 1
	defer t.nesting -= 1
	// A form gives a node's index, so what it took from the temporary allocator ends with it.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	switch n.kind {
	case .Identity:
		return dot
	case .Field:
		return field(t, n, type_of(t, n.a, dot, f), n.name)
	case .Index:
		return index_type(t, n, type_of(t, n.a, dot, f), n.b, dot, f)
	case .Slice:
		base := type_of(t, n.a, dot, f)
		quietly(t, n.b, dot, f)
		quietly(t, n.c, dot, f)
		k, unknown := kinds_of(t, base)
		if !unknown && k & {.Array, .String, .Null} == {} && !n.opt {
			kind_refusal(t, n, "Cannot index %s with object", kinds_text(k))
		}
		return sliced(t, base, k)
	case .Iterate:
		base := type_of(t, n.a, dot, f)
		r := read_iterated(t, base)
		if !r.unknown && !r.holds && !n.opt {
			kind_refusal(t, n, "Cannot iterate over %s", kinds_text(r.others + ({.Null} if r.nulls else {})))
		}
		return r.value
	case .Literal:
		return value_type(t, n.value)
	case .String:
		for p in n.args {
			type_of(t, p, dot, f)
		}
		return kinds_node(t, {.String})
	case .Format:
		formatted(t, n, type_of(t, n.a, dot, f) if n.a != nil else dot)
		return kinds_node(t, {.String})
	case .Array:
		return array_of(t, type_of(t, n.a, dot, f) if n.a != nil else t.never)
	case .Object:
		return object_type(t, n, dot, f)
	case .Neg:
		v := type_of(t, n.a, dot, f)
		k, unknown := kinds_of(t, v)
		if unknown {
			return t.unknown
		}
		if k & closure({.Number}) == {} {
			kind_refusal(t, n, "%s cannot be negated", kinds_text(k))
		}
		// A NaN, which the null of a number's kinds may be, stays one.
		return kinds_node(t, k & closure({.Number}) + (k & {.Null} if k & closure({.Number}) != {} else {}))
	case .Pipe:
		return type_of(t, n.b, type_of(t, n.a, dot, f), f)
	case .Comma:
		return union_of(t, type_of(t, n.a, dot, f), type_of(t, n.b, dot, f))
	case .Binary:
		return binary(t, n, type_of(t, n.a, dot, f), type_of(t, n.b, dot, f))
	case .And, .Or:
		type_of(t, n.a, dot, f)
		type_of(t, n.b, dot, f)
		return kinds_node(t, {.Bool})
	case .Alt:
		t.quiet += 1
		a := type_of(t, n.a, dot, f)
		t.quiet -= 1
		k, unknown := kinds_of(t, a)
		kept := a if unknown else restrict(t, a, k - {.Null})
		return union_of(t, kept, type_of(t, n.b, dot, f))
	case .If:
		yes, no := narrowed(t, n.a, dot)
		type_of(t, n.a, dot, f)
		return union_of(t, type_of(t, n.b, yes, f), type_of(t, n.c, no, f) if n.c != nil else no)
	case .Try:
		t.quiet += 1
		a := type_of(t, n.a, dot, f)
		t.quiet -= 1
		return union_of(t, a, type_of(t, n.b, t.unknown, f) if n.b != nil else t.never)
	case .Reduce, .Foreach:
		return fold(t, n, dot, f)
	case .Def:
		return type_of(t, n.a, dot, &Frame{parent = f, fn = n.fn})
	case .Call:
		return call(t, n, dot, f)
	case .Var:
		return variable(t, n.name, f)
	case .Bind:
		return bind(t, n.patterns, type_of(t, n.a, dot, f), dot, f, n.b)
	case .Label:
		return type_of(t, n.a, dot, f)
	case .Break:
		return t.never
	case .Update:
		return update(t, n, dot, f)
	}
	return t.unknown
}

// `n` typed for its refusals only, where its kind errors are the filter's choice.
@(private)
quietly :: proc(t: ^Typer, n: ^Node, dot: Ty, f: ^Frame) -> Ty {
	t.quiet += 1
	defer t.quiet -= 1
	return type_of(t, n, dot, f)
}

@(private)
kind_refusal :: proc(t: ^Typer, n: ^Node, format: string, args: ..any) {
	if t.quiet == 0 {
		refuse(t, n.loc, format, ..args)
	}
}

// What `.name` gives on `base`, refused where no value of `base` has a member and where no object of it describes
// `name`.
@(private)
field :: proc(t: ^Typer, n: ^Node, base: Ty, name: string) -> Ty {
	r := read(t, base, .Member, name)
	if r.unknown {
		return r.value
	}
	if !r.holds && !r.nulls && !n.opt {
		kind_refusal(t, n, "Cannot index %s with %q", kinds_text(r.others), name)
	}
	if r.holds && !r.described && t.soft == 0 && t.site == nil {
		near := message.nearest(r.names[:], name)
		refuse(t, name_loc(t, n, name), "%q is not a member of the object the schema describes%s", name, message.build_temp(" (did you mean %q?)", near) if near != "" else "")
	}
	return union_of(t, r.value, t.null if r.absent || r.nulls else t.never)
}

// Where `name` is spelled in the step `n`: its last spelling there, or the whole step.
@(private = "file")
name_loc :: proc(t: ^Typer, n: ^Node, name: string) -> Loc {
	text := t.input.text
	if name != "" && 0 <= n.loc.start && n.loc.start <= n.loc.end && n.loc.end <= len(text) {
		if at := strings.last_index(text[n.loc.start:n.loc.end], name); at >= 0 {
			return {n.loc.start + at, n.loc.start + at + len(name)}
		}
	}
	return n.loc
}

// What a slice of `base`, a value of kinds `k`, gives: a part of a string or an array, or null.
@(private = "file")
sliced :: proc(t: ^Typer, base: Ty, k: rules.Kinds) -> Ty {
	return union_of(t, kinds_node(t, k & {.String, .Null}), array_of(t, items_of(t, base)) if .Array in k else t.never)
}

// Refuses a format of values of `v` that it never takes: `@csv` and `@tsv` take an array, `@sh` no object.
@(private = "file")
formatted :: proc(t: ^Typer, n: ^Node, v: Ty) {
	takes: rules.Kinds
	switch n.name {
	case "csv", "tsv":
		takes = {.Array}
	case "sh":
		takes = rules.EVERY_KIND - {.Object}
	case:
		return
	}
	if k, unknown := kinds_of(t, v); !unknown && k != {} && k & takes == {} {
		kind_refusal(t, n, "%s cannot be %s-formatted", kinds_text(k), n.name)
	}
}

@(private)
index_type :: proc(t: ^Typer, n: ^Node, base: Ty, key: ^Node, dot: Ty, f: ^Frame) -> Ty {
	if key.kind == .Literal {
		#partial switch kind(key.value) {
		case .String:
			s, _ := string_of(key.value)
			return field(t, n, base, s)
		case .Number:
			x, _ := number_of(key.value)
			r := read(t, base, .Element, at = int(x.f) if x.f >= 0 && x.f < f64(max(i32)) else -1)
			if !r.unknown && !r.holds && !r.nulls && !n.opt {
				kind_refusal(t, n, "Cannot index %s with number", kinds_text(r.others))
			}
			return union_of(t, r.value, t.null)
		}
	}
	k, unknown := kinds_of(t, type_of(t, key, dot, f))
	if unknown {
		return t.unknown
	}
	b, base_unknown := kinds_of(t, base)
	if base_unknown {
		return t.unknown
	}
	parts := make([dynamic]Ty, context.temp_allocator)
	if .String in k && .Object in b {
		append(&parts, read(t, base, .Values).value, t.null)
	}
	if k & closure({.Number}) != {} && .Array in b {
		append(&parts, items_of(t, base), t.null)
	}
	if .Null in b {
		append(&parts, t.null)
	}
	if .Array in k && .Array in b {
		append(&parts, array_of(t, kinds_node(t, {.Integer})))
	}
	// An object key is a slice's `{start, end}`.
	if .Object in k && b & {.Array, .String} != {} {
		append(&parts, sliced(t, base, b - {.Null}))
	}
	if len(parts) == 0 && !n.opt {
		kind_refusal(t, n, "Cannot index %s with %s", kinds_text(b), kinds_text(k))
	}
	return union_of(t, ..parts[:])
}

@(private = "file")
object_type :: proc(t: ^Typer, n: ^Node, dot: Ty, f: ^Frame) -> Ty {
	members := make([dynamic]rules.Member, context.temp_allocator)
	computed := make([dynamic]Ty, context.temp_allocator)
	for i := 0; i < len(n.args); i += 2 {
		key, value := n.args[i], n.args[i + 1]
		k := type_of(t, key, dot, f)
		name, constant := "", key.kind == .Literal
		if constant {
			name, constant = string_of(key.value)
		}
		v: Ty
		switch {
		case value != nil:
			v = type_of(t, value, dot, f)
		case constant:
			v = field(t, key, dot, name)
		case:
			v = union_of(t, read(t, dot, .Values).value, t.null)
		}
		if !constant {
			append(&computed, v)
			if kk, unknown := kinds_of(t, k); !unknown && .String not_in kk {
				kind_refusal(t, key, "Object keys must be strings")
			}
			continue
		}
		at := -1
		for m, j in members {
			if m.name == name {
				at = j
			}
		}
		if at >= 0 {
			members[at].node = v
		} else {
			append(&members, rules.Member{name = name, node = v, required = true})
		}
	}
	if len(computed) == 0 {
		return object_of(t, members[:], t.never)
	}
	// A computed key may name a member a constant key names.
	others := union_of(t, ..computed[:])
	for &m in members {
		m.node = union_of(t, m.node, others)
	}
	return object_of(t, members[:], others)
}

// What `if c` passes to its branches: under `type == "kind"` the values of that kind, and the rest.
@(private = "file")
narrowed :: proc(t: ^Typer, c: ^Node, dot: Ty) -> (yes, no: Ty) {
	kinds, ok := type_test(c)
	if !ok {
		return dot, dot
	}
	yes = restrict(t, dot, kinds)
	// A byte string is a string of the description that `type` names "bytes".
	no = dot if t.input.bytes && .String in kinds else restrict(t, dot, rules.EVERY_KIND - closure(kinds))
	return
}

// The kinds a test `type == "name"` passes, either way round.
@(private)
type_test :: proc(c: ^Node) -> (rules.Kinds, bool) {
	if c == nil || c.kind != .Binary || c.op != .Eq {
		return {}, false
	}
	call, lit := c.a, c.b
	if call.kind == .Literal {
		call, lit = lit, call
	}
	if call.kind != .Call || call.name != "type" || len(call.args) > 0 || call.callee != nil || lit.kind != .Literal {
		return {}, false
	}
	name, _ := string_of(lit.value)
	for k in JQ_KINDS {
		if k.name == name || k.name == "string" && name == "bytes" {
			return k.kinds, true
		}
	}
	return {}, true
}

@(private = "file")
binary :: proc(t: ^Typer, n: ^Node, a, b: Ty) -> Ty {
	if n.op >= .Eq {
		return kinds_node(t, {.Bool})
	}
	ka, ua := kinds_of(t, a)
	kb, ub := kinds_of(t, b)
	if ua || ub {
		return t.unknown
	}
	out, taken := arithmetic(t, n.op, a, b, ka, kb)
	if !taken {
		VERBS := #partial [Op]string {
			.Add = "added",
			.Sub = "subtracted",
			.Mul = "multiplied",
			.Div = "divided",
			.Mod = "divided",
		}
		kind_refusal(t, n, "%s and %s cannot be %s", kinds_text(ka), kinds_text(kb), VERBS[n.op])
	}
	return out
}

// What `a op b` gives for values of kinds `ka` and `kb`, and whether some pair of them is taken.
@(private)
arithmetic :: proc(t: ^Typer, op: Op, a, b: Ty, ka, kb: rules.Kinds) -> (out: Ty, taken: bool) {
	numbers := closure({.Number})
	parts := make([dynamic]Ty, context.temp_allocator)
	add :: proc(parts: ^[dynamic]Ty, taken: ^bool, ty: Ty) {
		append(parts, ty)
		taken^ = true
	}
	na, nb := ka & numbers != {}, kb & numbers != {}
	whole := op != .Div && ka & numbers == {.Integer} && kb & numbers == {.Integer}
	// A NaN is written null. A number of a node that also takes null may be one, and an infinite number, which a large
	// input or an operation may give, makes one with another infinite number or, multiplied, with zero.
	fa, za := finite(t, a)
	fb, zb := finite(t, b)
	free := fa && fb || op == .Mul && (fa && za || fb && zb) || op != .Mul && op != .Mod && (fa || fb) || op == .Mod
	nan := .Null in (ka + kb) || !free
	number := kinds_node(t, ({.Integer} if whole else {.Number}) + (rules.Kinds{.Null} if nan else {}))
	#partial switch op {
	case .Add:
		if .Null in ka {
			add(&parts, &taken, b)
		}
		if .Null in kb {
			add(&parts, &taken, a)
		}
		if na && nb {
			add(&parts, &taken, number)
		}
		if .String in ka && .String in kb {
			add(&parts, &taken, kinds_node(t, {.String}))
		}
		if .Array in ka && .Array in kb {
			add(&parts, &taken, array_of(t, union_of(t, items_of(t, a), items_of(t, b))))
		}
		if .Object in ka && .Object in kb {
			add(&parts, &taken, loose(t, {.Object}))
		}
	case .Sub:
		if na && nb {
			add(&parts, &taken, number)
		}
		if .Array in ka && .Array in kb {
			add(&parts, &taken, array_of(t, items_of(t, a)))
		}
	case .Mul:
		if na && nb {
			add(&parts, &taken, number)
		}
		if (.String in ka && nb) || (na && .String in kb) {
			add(&parts, &taken, kinds_node(t, {.String, .Null}))
		}
		if .Object in ka && .Object in kb {
			add(&parts, &taken, loose(t, {.Object}))
		}
	case .Div:
		if na && nb {
			add(&parts, &taken, number)
		}
		if .String in ka && .String in kb {
			add(&parts, &taken, array_of(t, kinds_node(t, {.String})))
		}
	case .Mod:
		if na && nb {
			add(&parts, &taken, kinds_node(t, {.Integer} + (rules.Kinds{.Null} if nan else {})))
		}
	}
	return union_of(t, ..parts[:]), taken
}

// An update gives its input with the values at its paths changed: a container stays one, and a null may become one.
// Where a path may be the input's own, `.` as `..` and `getpath([])` give it, the update may replace the input.
@(private = "file")
update :: proc(t: ^Typer, n: ^Node, dot: Ty, f: ^Frame) -> Ty {
	t.soft += 1
	at := type_of(t, n.a, dot, f)
	t.soft -= 1
	v := type_of(t, n.b, at if n.op == .Modify else dot, f)
	new: Ty
	#partial switch n.op {
	case .Assign:
		new = v
	case .Modify:
		// A path whose update gives nothing is deleted, and deleting the whole input gives null.
		new = v if yields_one(n.b) else union_of(t, v, t.null)
	case .Alt:
		new = union_of(t, restrict(t, at, rules.EVERY_KIND - {.Null}), v)
	case:
		new = binary(t, n, at, v)
	}
	if n.a.kind == .Identity {
		return new
	}
	k, unknown := kinds_of(t, dot)
	if unknown {
		return t.unknown
	}
	changed := loose(t, k + {.Array, .Object} if .Null in k else k)
	return changed if extends(n.a) else union_of(t, changed, new)
}

// Whether every path `n` gives is longer than its input's.
@(private)
extends :: proc(n: ^Node) -> bool {
	#partial switch n.kind {
	case .Field, .Index, .Slice, .Iterate:
		return true
	case .Pipe:
		return extends(n.a) || extends(n.b)
	case .Comma, .Alt:
		return extends(n.a) && extends(n.b)
	}
	return false
}

// A `reduce` or a `foreach`: its state widened over every value of its source until it holds still.
@(private = "file")
fold :: proc(t: ^Typer, n: ^Node, dot: Ty, f: ^Frame) -> Ty {
	state := type_of(t, n.b, dot, f)
	if !yields_one(n.c) {
		state = union_of(t, state, t.null)
	}
	s := Step{n = n, f = f, source = type_of(t, n.a, dot, f), out = t.never}
	state = settle(t, state, &s)
	return state if n.kind == .Reduce else s.out
}

// A step of a fixpoint: a fold's update over its `source`, or with no source a recursion's next values.
@(private)
Step :: struct {
	n:      ^Node,
	f:      ^Frame,
	source: Ty,
	out:    Ty, // a foreach's extract on the state settled on
}

// The least state that holds `start` and what a step gives on it, unknown past MAX_ROUNDS. The refusals of the rounds
// are held, and those of a last step on the state settled on are told.
@(private)
settle :: proc(t: ^Typer, start: Ty, s: ^Step) -> Ty {
	state := start
	t.held += 1
	for round := 0; ; round += 1 {
		if round == MAX_ROUNDS || state == t.unknown {
			t.held -= 1
			s.out = t.unknown
			return t.unknown
		}
		widened := union_of(t, state, step(t, state, s))
		if widened == state {
			break
		}
		state = widened
	}
	t.held -= 1
	step(t, state, s)
	if s.n.kind == .Foreach {
		s.out = bind(t, s.n.patterns, s.source, state, s.f, s.n.d) if s.n.d != nil else state
	}
	return state
}

@(private = "file")
step :: proc(t: ^Typer, state: Ty, s: ^Step) -> Ty {
	#partial switch s.n.kind {
	case .Reduce, .Foreach:
		return bind(t, s.n.patterns, s.source, state, s.f, s.n.c)
	case .Call:
		if len(s.n.args) > 0 {
			return type_of(t, s.n.args[0], state, s.f)
		}
	}
	return read_iterated(t, state).value
}

// Whether `n` gives exactly one output or fails, on any input.
@(private)
yields_one :: proc(n: ^Node) -> bool {
	if n == nil {
		return true
	}
	#partial switch n.kind {
	case .Identity, .Literal, .Var:
		return true
	case .Field, .Index, .Slice:
		return !n.opt && yields_one(n.a) && yields_one(n.b) && yields_one(n.c)
	case .String, .Format, .Object:
		for a in n.args {
			if !yields_one(a) {
				return false
			}
		}
		return yields_one(n.a)
	case .Array, .Reduce:
		return true
	case .Neg, .Pipe, .Binary, .And, .Or, .If, .Update, .Label:
		return yields_one(n.a) && yields_one(n.b) && (n.kind != .If || yields_one(n.c))
	case .Def:
		return yields_one(n.a)
	case .Call:
		b, native := n.native.?
		return native && b.native == nil && b.gen == nil
	}
	return false
}

// `body` on `dot` with the variables of `pats` bound to what destructuring `value` gives, over every alternative.
@(private)
bind :: proc(t: ^Typer, pats: []^Pattern, value, dot: Ty, f: ^Frame, body: ^Node) -> Ty {
	outs := make([dynamic]Ty, context.temp_allocator)
	for p, i in pats {
		inner := f
		// The other alternatives' variables are null.
		for q, j in pats {
			if j != i {
				each_var([]^Pattern{q}, &inner, proc(name: string, inner: ^^Frame) {
					inner^ = new_clone(Frame{parent = inner^, name = name, value = rules.NONE})
				})
			}
		}
		// A failure in an alternative but the last, in its destructuring or its body, moves to the next.
		last := i == len(pats) - 1
		t.quiet += 0 if last else 1
		inner = destructure(t, p, value, dot, inner)
		append(&outs, type_of(t, body, dot, inner))
		t.quiet -= 0 if last else 1
	}
	return union_of(t, ..outs[:])
}

@(private = "file")
destructure :: proc(t: ^Typer, p: ^Pattern, value, dot: Ty, f: ^Frame) -> ^Frame {
	f := f
	switch p.kind {
	case .Var:
		f = new_clone(Frame{parent = f, name = p.name, value = value})
	case .Array:
		for e, i in p.elems {
			r := read(t, value, .Element, at = i)
			f = destructure(t, e, union_of(t, r.value, t.null), dot, f)
		}
	case .Object:
		for m in p.members {
			key := m.key
			v: Ty
			if name, constant := string_of(key.value); key.kind == .Literal && constant {
				v = field(t, key, value, name)
			} else {
				type_of(t, key, dot, f)
				v = union_of(t, read(t, value, .Values).value, t.null)
			}
			if m.var != "" {
				f = new_clone(Frame{parent = f, name = m.var, value = v})
			}
			if m.pattern != nil {
				f = destructure(t, m.pattern, v, dot, f)
			}
		}
	}
	return f
}

@(private = "file")
variable :: proc(t: ^Typer, name: string, f: ^Frame) -> Ty {
	for g := f; g != nil; g = g.parent {
		if g.fn == nil && g.name == name {
			return t.null if g.value == rules.NONE else g.value
		}
		if g.called {
			for p, i in g.fn.params {
				if p[0] == '$' && p[1:] == name {
					return g.values[i]
				}
			}
		}
	}
	for v, i in t.input.names {
		if v == name {
			return value_type(t, t.input.values[i]) if i < len(t.input.values) else t.any
		}
	}
	switch name {
	case "ENV":
		return object_of(t, nil, kinds_node(t, {.String}))
	case "__loc__":
		return loose(t, {.Object})
	}
	return t.unknown
}

// A call: of a parameter, typed in its caller's frame, of a definition, typed through its body, or of a builtin. A
// definition of the prelude refuses at the call of it, and refuses no member.
@(private = "file")
call :: proc(t: ^Typer, n: ^Node, dot: Ty, f: ^Frame) -> Ty {
	if n.is_param {
		for g := f; g != nil; g = g.parent {
			if g.called && g.fn == n.callee {
				if g.fn.params[n.param][0] == '$' {
					return g.values[n.param]
				}
				site := t.site
				t.site = g.site
				defer t.site = site
				return type_of(t, g.args[n.param], dot, g.scope)
			}
		}
		return t.unknown
	}
	prelude := n.def != nil && n.def.in_prelude
	if out, typed := builtin_type(t, n, dot, f); typed {
		return out
	}
	fn := n.callee
	if fn == nil {
		for a in n.args {
			type_of(t, a, dot, f)
		}
		return t.unknown
	}
	if t.active[fn] >= MAX_RECURSION {
		return t.unknown
	}
	base: ^Frame
	for g := f; g != nil; g = g.parent {
		if !g.called && g.fn == fn {
			base = g
			break
		}
	}
	values := make([]Ty, len(fn.params))
	for p, i in fn.params {
		if p[0] == '$' {
			values[i] = type_of(t, n.args[i], dot, f)
		}
	}
	frame := &Frame{parent = base, fn = fn, called = true, args = n.args, values = values, scope = f, site = t.site}
	site := t.site
	if prelude && site == nil {
		t.site = n.loc
	}
	t.active[fn] += 1
	out := type_of(t, fn.body, dot, frame)
	t.active[fn] -= 1
	t.site = site
	return out
}
