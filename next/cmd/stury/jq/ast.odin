package jq

// The parsed program.

Node_Kind :: enum u8 {
	Identity, // .
	Field, // a.name; each of Field, Index, Slice and Iterate drops its own error when `opt` (`?`)
	Index, // a[b]
	Slice, // a[b:c], either bound may be nil
	Iterate, // a[]
	Literal, // value
	String, // interpolation: args are its parts, each a literal string or a Format
	Format, // @name applied to ., or in a String to each output of a ("text" for a plain `\(a)`)
	Array, // [a], a may be nil
	Object, // {k: v, ...}: args are each entry's key and value in turn, a nil value `{"key"}`, the input's member
	Neg, // -a
	Pipe, // a | b
	Comma, // a, b
	Binary, // a op b: arithmetic and comparison
	And, // a and b
	Or, // a or b
	Alt, // a // b
	If, // if a then b else c end; c nil is `.`
	Try, // try a catch b; b may be nil
	Reduce, // reduce a as patterns (b; c)
	Foreach, // foreach a as patterns (b; c; d), d may be nil
	Def, // def fn; a
	Call, // name(args)
	Var, // $name
	Bind, // a as patterns | b
	Label, // label $name | a
	Break, // break $name
	Update, // a op b: =, |=, +=, -=, *=, /=, %=, //=
}

Op :: enum u8 {
	None,
	Add,
	Sub,
	Mul,
	Div,
	Mod,
	Eq,
	Ne,
	Lt,
	Le,
	Gt,
	Ge,
	Assign, // =
	Modify, // |=
	Alt, // //=
}

Node :: struct {
	kind:    Node_Kind,
	op:      Op, // Binary's operator; Update's: Assign, Modify, Alt, or the arithmetic of `op=`
	name:    string,
	value:   Value,
	a, b, c, d: ^Node,
	args:    []^Node,
	// `as`'s patterns: one, or the alternatives of `?//`.
	patterns: []^Pattern,
	fn:      ^Func,
	loc:     Loc, // where it is in the program, for messages
	opt:     bool,
	// At most one output, and nothing after it (single.odin): the evaluator may run it to its output and
	// carry on outside its frames.
	single:  bool,
	// A call `check` bound before running: to the prelude definition it names, or to a builtin.
	def:     ^Env,
	native:  Maybe(Builtin),
	// A call to a jq function `check` resolved: the function, or with `is_param` the function whose
	// parameter `param` it names.
	callee:   ^Func,
	param:    int,
	is_param: bool,
}

Func :: struct {
	name:   string,
	params: []string, // a `$name` parameter binds a value; any other binds a filter
	body:   ^Node,
	// single.odin's results: the body's, and each parameter's (every argument passed to it is single).
	single:        bool,
	params_single: []bool,
}

Pattern_Kind :: enum u8 {
	Var,
	Array,
	Object,
}

// A destructuring pattern: `$name`, `[p, ...]`, `{key: p, $name, ...}`.
Pattern :: struct {
	kind:    Pattern_Kind,
	name:    string,
	elems:   []^Pattern,
	members: []Pattern_Member,
	// Every key in it single (single.odin): it binds a value at most one way.
	single:  bool,
}

// `{$name}` binds the member `name` to `$name`, `{$name: p}` also destructures it, `{key: p}` only destructures.
// `key` yields the member's name.
Pattern_Member :: struct {
	key:     ^Node,
	var:     string,
	pattern: ^Pattern,
}

// Whether `visit` holds for a child of `n`, each given as the field that holds it: its operands, arguments and its
// patterns' keys, but not a definition's body. The walk stops at the first that holds. A `visit` that never does sees
// every child.
any_child :: proc(n: ^Node, data: $T, visit: proc(child: ^^Node, data: T) -> bool) -> bool {
	if visit(&n.a, data) || visit(&n.b, data) || visit(&n.c, data) || visit(&n.d, data) {
		return true
	}
	for &a in n.args {
		if visit(&a, data) {
			return true
		}
	}
	for p in n.patterns {
		if any_key(p, data, visit) {
			return true
		}
	}
	return false
}

@(private = "file")
any_key :: proc(p: ^Pattern, data: $T, visit: proc(child: ^^Node, data: T) -> bool) -> bool {
	for e in p.elems {
		if any_key(e, data, visit) {
			return true
		}
	}
	for &m in p.members {
		if visit(&m.key, data) || m.pattern != nil && any_key(m.pattern, data, visit) {
			return true
		}
	}
	return false
}
