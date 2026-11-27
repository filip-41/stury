package jq

import "stury:lib/query"

// The parsed program. Nodes are made in the order the parser reduces them, so each node's children come before it in
// `Program.order`: a pass that needs its children done first is one loop over it, and no pass recurses.

@(private)
Node_Kind :: enum u8 {
	Identity, // .
	Field, // a.name; each of Field, Index, Slice and Iterate drops its own error when `.Opt`
	Index, // a[b]
	Slice, // a[b:c], either bound may be nil
	Iterate, // a[]
	Literal, // value
	String, // interpolation: args are its parts, each a literal string or a Format
	Format, // @name applied to ., or in a String to each output of a (`text` for a plain `\(a)`)
	Array, // [a], a may be nil
	Object, // {k: v, ...}: args are each entry's key and value in turn
	Neg, // -a
	Pipe, // a | b
	Comma, // a, b
	Binary, // a op b: arithmetic and comparison
	And, // a and b
	Or, // a or b
	Alt, // a // b
	If, // if a then b else c end, a nil c read as `.`
	Try, // try a catch b, b may be nil
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

@(private)
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

@(private)
Node_Flag :: enum u8 {
	Opt, // `?` after a step
	Single, // at most one output, and nothing after it
	Native, // single, no generator, no call of a jq function or filter argument, at most `NATIVE_HEIGHT` tall
	Distinct_Keys, // `.Object` whose keys are compile-time distinct string literals
}

@(private)
Node_Flags :: bit_set[Node_Flag; u8]

// The tallest subtree the native evaluator runs, so its native depth is bounded by a constant, not by the program.
@(private)
NATIVE_HEIGHT :: 32

@(private)
Node :: struct {
	kind:     Node_Kind,
	op:       Op, // Binary's operator; Update's: Assign, Modify, Alt, or the arithmetic of `op=`
	flags:    Node_Flags,
	height:   u8, // saturated at 255
	slots:    u16, // the slots of the scope a binding makes
	// How many scopes up the variable, label, filter argument or function's definition is: `Ref` gives where.
	ref:      Ref,
	a, b, c, d: ^Node,
	args:     []^Node,
	name:     string,
	value:    query.Value, // a literal, made once and held by the program
	patterns: []^Pattern, // `as`'s: one, or the alternatives of `?//`
	keys:     []^Node, // the key expressions of `patterns`, in order
	fn:       ^Func, // Def's function
	callee:   ^Func, // Call of a jq function
	builtin:  ^Builtin, // Call of a builtin
	loc:      Loc,
}

// Where a name a node uses is bound, counted in scopes from the node's: `hops` scopes up, slot `slot` of it. A
// function's definition is no scope at run time: a call reaches the scope its body was defined in, `hops` up.
@(private)
Ref :: struct {
	hops: u32,
	slot: u16,
	kind: Ref_Kind,
}

@(private)
Ref_Kind :: enum u8 {
	None,
	Var, // a variable's value
	Param, // a filter argument: the closure in the slot
	Def, // a jq function: `hops` up is the scope its definition is in
	Label,
	Global, // a variable the program was compiled with: `slot` of `Program.globals`
}

@(private)
Func :: struct {
	name:     string,
	params:   []string, // a `$name` parameter binds a value; any other binds a filter
	body:     ^Node,
	single:   bool, // the body has at most one output for any input
	prelude:  bool, // defined by the prelude, not the program
	inline:   Inline_State, // whether calls of it are replaced by its body, once known
	// The scope its body runs in, made by a call: one slot per parameter, a `$name` one taking two (its filter and its
	// value), none for a function with no parameter, whose call makes no scope.
	slots:    u16,
	loc:      Loc,
	params_single: []bool, // each filter parameter single, as every argument any call passes it is
	info:     rawptr, // binding's scratch
}

@(private)
Pattern_Kind :: enum u8 {
	Var,
	Array,
	Object,
}

// A destructuring pattern: `$name`, `[p, ...]`, `{key: p, $name, ...}`.
@(private)
Pattern :: struct {
	kind:    Pattern_Kind,
	name:    string,
	slot:    u16, // a Var's slot in the scope the binding makes
	elems:   []^Pattern,
	members: []Pattern_Member,
}

// `{$name}` binds the member `name` to `$name`, `{$name: p}` also destructures it, `{key: p}` only destructures.
@(private)
Pattern_Member :: struct {
	key:     ^Node,
	var:     string,
	slot:    u16,
	pattern: ^Pattern,
}

// The children of `n`, in evaluation order: its operands, arguments and its patterns' key expressions, but not a
// definition's body, which is its function's. `child(n, i)` for `i` below `child_count(n)`, nil for an absent operand.
@(private)
child_count :: #force_inline proc "contextless" (n: ^Node) -> int {
	return 4 + len(n.args) + len(n.keys)
}

@(private)
child :: #force_inline proc "contextless" (n: ^Node, i: int) -> ^Node #no_bounds_check {
	switch i {
	case 0:
		return n.a
	case 1:
		return n.b
	case 2:
		return n.c
	case 3:
		return n.d
	}
	if i - 4 < len(n.args) {
		return n.args[i - 4]
	}
	return n.keys[i - 4 - len(n.args)]
}
