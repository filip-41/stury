package jq

// The evaluator. A filter is a generator: `eval` sends each output to a sink, and the sink's answer
// steers the generator. `.Go` asks for more, `.Break` unwinds to the label `Interp.brk` names (how
// `limit`, `first` and `label` stop a generator early), `.Fail` unwinds to the nearest `try` with the
// error in `Interp.err`.
//
// Path expressions run the same code with `track` set: every output also carries the path it was read
// at, which `path`, `paths`, `del` and the assignments build on.

import "core:fmt"
import "core:strings"

Signal :: enum u8 {
	Go,
	Break,
	Fail,
}

// An output: a value, and under `track` where it was read from the root (`nil` is the root itself).
Item :: struct {
	v:    Value,
	path: ^Path_Step,
}

// One step of a path read from the root, linked back toward it: `key` is the object key or array index.
Path_Step :: struct {
	parent: ^Path_Step,
	key:    Value,
}

// Where an evaluation's outputs go: `emit` takes one, and its `Signal` steers the generator.
Sink :: struct {
	emit: proc(s: ^Sink, it: Item) -> Signal,
}

// What a scope entry binds: a `$variable`, a `def`, a filter argument, or a `label`.
Env_Kind :: enum u8 {
	Var,
	Func,
	Closure,
	Label,
}

// The lexical scope, innermost first. A `Func` entry is its own body's scope, so it can recur. A `Closure` is a
// filter argument, run in the scope that wrote it.
Env :: struct {
	parent:     ^Env,
	kind:       Env_Kind,
	in_prelude: bool,   // a `Func` defined by the prelude rather than by the program
	name:       string,
	arity:      int,    // a `Func`'s parameter count, matched with its name
	value:      Value,  // a `Var`'s value
	fn:         ^Func,  // a `Func`'s definition
	node:       ^Node,  // a `Closure`'s filter argument
	scope:      ^Env,   // a `Closure`'s scope, the caller's
	label:      int,    // a `Label`'s id, which `Interp.brk` names to unwind to it
}

Input_Source :: struct {
	data:     rawptr,
	next:     proc(data: rawptr) -> (v: Value, msg: string, status: Parse_Status), // .More: no input is left
	position: proc(data: rawptr) -> (name: string, line: int), // the input being read, "" before any
}

Interp :: struct {
	err:          Value, // the error being raised, by `fail` or `error`
	raised:       int, // errors raised so far: tells one raise of `err` from another of the same value
	brk:          int, // the label id a `.Break` unwinds to; -1 for `halt`
	labels:       int, // label ids handed out so far (`fresh_label`)
	globals:      ^Env, // the prelude's functions and the command line's variables
	inputs:       Input_Source,
	env_obj:      Value, // $ENV, nil until `env_value` makes it
	halted:       Maybe(int), // `halt`'s exit code
	messages:     [dynamic]byte, // `debug` and `stderr` output, written by the caller
	debug_layout: Layout, // how `debug` prints its message: jq's output options, compact
	search_list:  []string, // -L's directories, nil for jq's default list
	prog_origin:  string, // under -f, the real path of the filter file's directory
	// jq's jv_load_file, which modules are read with: the file as one string (`raw`) or as the array of its
	// JSON texts, or jq's message for why not.
	load_file:    proc(path: string, raw: bool) -> (Value, string),
	// Scopes no evaluation reads any more, linked by `parent`, for `new_env` to hand out again. They live
	// in the input's memory, so the caller empties the list with it.
	free_envs:    ^Env,
	// The sink a caller prints outputs with, keeping none of them once it returns, or nil: what a pipe or
	// a binding feeding it makes for an output is emptied once that output is printed (`Output_Scope`).
	printer:      ^Sink,
	scope:        Output_Scope,
	owned:        ^Owned, // the innermost reduce or foreach whose update changes its state in place, or nil
	text:         Text_Count, // the code-point count a state that grows by `+` resumes from (`length`)
	recycler:     Input_Recycler,
}

fail :: proc(ip: ^Interp, format: string, args: ..any) -> Signal {
	ip.err = fmt.aprintf(format, ..args)
	ip.raised += 1
	return .Fail
}

// `v` as jq's messages show a value (jv_dump_string_trunc into `size` bytes): compact JSON, cut to fit
// with "..." and the closing quote or bracket, a long string first cut to 30 characters.
brief :: proc(v: Value, size := 30) -> string {
	v := v
	if text, is_str := string_of(v); is_str && len(text) > size {
		v = char_slice(&Char_Walk{}, text, 0, size)
	}
	s := to_json(v)
	if len(s) < size {
		return s
	}
	close := ""
	switch s[0] {
	case '"':
		close = `"`
	case '[':
		close = "]"
	case '{':
		close = "}"
	}
	cut := size - 4 - len(close)
	for cut > 0 && s[cut] & 0xc0 == 0x80 {
		cut -= 1
	}
	return strings.concatenate({s[:cut], "...", close})
}

// The next label's number. jq numbers each `label` it enters, its builtins' (`first`, `limit`, `isempty`,
// `|=`...) too, from 0 for the whole run, and its `break` raises `{"__jq": N}` as an error.
fresh_label :: proc(ip: ^Interp) -> int {
	ip.labels += 1
	return ip.labels - 1
}

// The error `break` to label `id` raises.
break_error :: proc(id: int) -> Value {
	o := new_object()
	object_put(o, "__jq", num(f64(id)))
	return o
}

// Whether `err` is a break to label `id`, as jq's label compares what it catches: `{"__jq": id}`.
breaks_to :: proc(err: Value, id: int) -> bool {
	if kind(err) != .Object || length_of(err) != 1 {
		return false
	}
	v, _ := object_get(err, "__jq")
	n, is_num := number_of(v)
	return is_num && n.f == f64(id)
}

// The dispatch keeps its locals few: a case's sinks live in the frame of the proc that runs it, so each
// level of a filter's recursion costs the stack of the cases it takes, not of every case. A tail (a
// pipe's right side after a single left one, an `if`'s branch, a comma's right side, a function's body)
// is a turn of the loop, not a call, so a recursion in tail position takes no stack (single.odin).
eval :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	n, input, env := n, input, env
	// The scopes this loop made since it last entered a body (its locals: binds and defs) lie between
	// `env` and `frame`.
	frame := env
	for {
		switch n.kind {
		case .Identity:
			return out.emit(out, input)
		case .Field, .Index, .Slice, .Iterate:
			if n.kind == .Field && n.a.kind == .Identity {
				return index_and_emit(ip, input, n.name, track, out, n.opt)
			}
			return eval_step(ip, n, input, env, track, out)
		case .Literal:
			return #force_no_inline emit_made(out, input, n.value, track)
		case .String:
			return eval_args(ip, n, nil, input, env, track, out)
		case .Format:
			return eval_format(ip, n, input, track, out)
		case .Array:
			return eval_array(ip, n, input, env, track, out)
		case .Object:
			return eval_object(ip, n, input, env, track, out)
		case .Pipe:
			if !track && n.a.kind == .Array && is_length(n.b) {
				return eval_count(ip, n.a, input, env, out)
			}
			if !n.a.single {
				return eval_pipe(ip, n, input, env, track, out)
			}
			if sig, found := pipe_head(ip, n, &input, env, track); !found {
				return sig
			}
			n = n.b
		case .If:
			if !n.a.single {
				return eval_if(ip, n, input, env, track, out)
			}
			branch, sig, found := if_branch(ip, n, input, env)
			if !found {
				return sig
			}
			if branch == nil {
				return out.emit(out, input)
			}
			n = branch
		case .Bind:
			if !n.a.single || !n.patterns[len(n.patterns) - 1].single {
				return eval_bind(ip, n, input, env, track, out)
			}
			if sig, bound := bind_head(ip, n, &input, &env, track, out); !bound {
				return sig
			}
			n = n.b
		case .Neg:
			return eval_neg(ip, n, input, env, track, out)
		case .Comma:
			if sig := comma_head(ip, n.a, input, env, track, out); sig != .Go {
				return sig
			}
			n = n.b
		case .Binary, .And, .Or:
			if n.kind == .Binary && n.a.single && n.b.single {
				return binary_single(ip, n, input, env, track, out)
			}
			return eval_binary(ip, n, input, env, track, out)
		case .Alt:
			return eval_alt(ip, n, input, env, track, out)
		case .Try:
			return eval_try(ip, n, input, env, track, out)
		case .Reduce:
			return eval_reduce(ip, n, input, env, track, out)
		case .Foreach:
			return eval_foreach(ip, n, input, env, track, out)
		case .Def:
			env = define(ip, n, env)
			n = n.a
		case .Label, .Break, .Var:
			return eval_scoped(ip, n, input, env, track, out)
		case .Call:
			if sig, entered := enter_call(ip, &n, input, &env, &frame, track, out); !entered {
				return sig
			}
		case .Update:
			return eval_update(ip, n, input, env, track, out)
		}
	}
}

// The output of `n`, a single node, run to its end, so that what follows runs outside its frames.
eval_single :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool) -> (Item, bool, Signal) {
	s := Last_Sink{sink = {emit = last_emit}}
	sig := eval(ip, n, input, env, track, &s)
	return s.it, s.found, sig
}

// A comma's left side. A single one runs to its end before its output goes on, so that a recursion
// through the output (`(.+1, empty) | f`) holds only this frame, not those that made the output.
@(private = "file")
comma_head :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	if !n.single {
		return eval(ip, n, input, env, track, out)
	}
	if n.kind == .Identity {
		return out.emit(out, input)
	}
	it, found, sig := eval_single(ip, n, input, env, track)
	if !found {
		return sig
	}
	return out.emit(out, it)
}

// `n`, a pipe's or a bind's left side, into the sink that runs the rest: a comma's parts one by one from
// here, so that a recursion through their outputs holds no frame of eval's for the comma.
@(private)
eval_commas :: #force_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	n := n
	for n.kind == .Comma {
		if sig := comma_head(ip, n.a, input, env, track, out); sig != .Go {
			return sig
		}
		n = n.b
	}
	return eval(ip, n, input, env, track, out)
}

// The output of a pipe's single left side, as the input of its right.
@(private = "file")
pipe_head :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: ^Item, env: ^Env, track: bool) -> (Signal, bool) {
	it, found, sig := eval_single(ip, n.a, input^, env, track)
	if found {
		input^ = it
	}
	return sig, found
}

// The branch an `if` with a single condition takes: nil for the missing `else`, which is `.`.
@(private = "file")
if_branch :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env) -> (^Node, Signal, bool) {
	cond, found, sig := eval_single(ip, n.a, input, env, false)
	if !found {
		return nil, sig, false
	}
	return n.b if truthy(cond.v) else n.c, .Go, true
}

// `-a`, `a | b`, `if`, and `a as $x | b`: `n.a`'s outputs into the sink that runs the rest. One proc
// each, so a level of recursion through one holds only its own sink.
@(private = "file")
eval_neg :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	s := Neg_Sink{sink = {emit = neg_emit}, ip = ip, track = track, out = out}
	return eval(ip, n.a, input, env, track, &s)
}

@(private = "file")
eval_pipe :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	s := Pipe_Sink{sink = {emit = pipe_emit}, ip = ip, n = n.b, env = env, track = track, out = out}
	if out == ip.printer && !track && !ip.scope.on {
		return eval_scoped_outputs(ip, n.a, input, env, &s)
	}
	return eval_commas(ip, n.a, input, env, track, &s)
}

@(private = "file")
eval_if :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	s := Node_Sink{sink = {emit = if_emit}, ip = ip, n = n, input = input, env = env, track = track, out = out}
	return eval(ip, n.a, input, env, false, &s)
}

// `def fn; ...`'s scope.
define :: #force_no_inline proc(ip: ^Interp, n: ^Node, env: ^Env) -> ^Env {
	e := new_env(ip)
	e^ = {parent = env, kind = .Func, name = n.fn.name, arity = len(n.fn.params), fn = n.fn}
	return e
}

new_env :: proc(ip: ^Interp) -> ^Env {
	if e := ip.free_envs; e != nil {
		ip.free_envs = e.parent
		return e
	}
	return new(Env)
}

// `label`, `break` and `$name`: the scope read or extended.
@(private = "file")
eval_scoped :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	#partial switch n.kind {
	case .Label:
		// jq's `try body catch if . == $label then empty else error end`: what the body's outputs raise
		// downstream passes.
		id := fresh_label(ip)
		e := Env{parent = env, kind = .Label, name = n.name, label = id}
		g := Guard_Sink{sink = {emit = guard_emit}, out = out, ip = ip}
		sig := eval(ip, n.a, input, &e, track, &g)
		if sig == .Fail && !consumer_failed(ip, &g) && breaks_to(ip.err, id) {
			return .Go
		}
		return sig
	case .Break:
		for e := env; e != nil; e = e.parent {
			if e.kind == .Label && e.name == n.name {
				ip.err = break_error(e.label)
				ip.raised += 1
				return .Fail
			}
		}
		return fail(ip, "$*label-%s is not defined", n.name)
	}
	v, sig := lookup_var(ip, n.name, env)
	if sig != .Go {
		return sig
	}
	return emit_made(out, input, v, track)
}

// ---- Sinks

Pipe_Sink :: struct {
	using sink: Sink,
	ip:         ^Interp,
	n:          ^Node,
	env:        ^Env,
	track:      bool,
	out:        ^Sink,
}

pipe_emit :: proc(s: ^Sink, it: Item) -> Signal {
	p := (^Pipe_Sink)(s)
	return eval(p.ip, p.n, it, p.env, p.track, p.out)
}

Collect_Sink :: struct {
	using sink: Sink,
	into:       ^[dynamic]Value,
}

collect_emit :: proc(s: ^Sink, it: Item) -> Signal {
	c := (^Collect_Sink)(s)
	make_room(c.into)
	append(c.into, it.v)
	return .Go
}

collect_into :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, into: ^[dynamic]Value, track := false) -> Signal {
	s := Collect_Sink{sink = {emit = collect_emit}, into = into}
	return eval(ip, n, input, env, track, &s)
}

collect :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env) -> ([]Value, Signal) {
	vals := make([dynamic]Value)
	sig := collect_into(ip, n, input, env, &vals)
	return vals[:], sig
}

First_Sink :: struct {
	using sink: Sink,
	ip:         ^Interp,
	label:      int,
	got:        Item,
	outputs:    int,
}

first_emit :: proc(s: ^Sink, it: Item) -> Signal {
	f := (^First_Sink)(s)
	f.got = it
	f.outputs += 1
	f.ip.brk = f.label
	return .Break
}

// The first output of `n`, if any, without running it further: a label's body, `label` its number.
// A `?//` in `n` takes the break as an error and outputs again, so there may be more: `got` is the last.
first_of :: proc(ip: ^Interp, label: int, n: ^Node, input: Item, env: ^Env, track := false) -> (got: Item, outputs: int, sig: Signal) {
	s := First_Sink{sink = {emit = first_emit}, ip = ip, label = label}
	sig = eval(ip, n, input, env, track, &s)
	if sig == .Break && ip.brk == s.label || sig == .Fail && breaks_to(ip.err, s.label) {
		sig = .Go
	}
	return s.got, s.outputs, sig
}

// ---- Operators

Neg_Sink :: struct {
	using sink: Sink,
	ip:         ^Interp,
	track:      bool,
	out:        ^Sink,
}

neg_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Neg_Sink)(s)
	n, ok := number_of(it.v)
	if !ok {
		return fail(x.ip, "%s (%s) cannot be negated", type_name(it.v), brief(it.v))
	}
	return emit_made(x.out, it, negate(n), x.track)
}

negate :: proc(n: Number) -> Number {
	if n.lit == "" {
		return {f = -n.f}
	}
	if n.lit[0] == '-' {
		return {f = -n.f, lit = n.lit[1:]}
	}
	// decNumberMinus makes a zero +0, but a literal that underflows to 0.0 (1e-400) is no zero to it.
	if n.f == 0 {
		digits := strings.trim_left(n.lit, "0.")
		if digits == "" || digits[0] | 0x20 == 'e' {
			return n
		}
	}
	return {f = -n.f, lit = strings.concatenate({"-", n.lit})}
}

Binary_Sink :: struct {
	using sink: Sink,
	ip:         ^Interp,
	n:          ^Node,
	input:         Item,
	env:        ^Env,
	track:      bool,
	out:        ^Sink,
	rhs:        Value,
}

// Arithmetic or comparison of single operands, each run to its value: the left one, which may recur,
// nests no sink of the right one's.
binary_single :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	// One sink for both operands and the result, as each frame on a recursion's path counts.
	s := Last_Sink{sink = {emit = last_emit}}
	r: Value
	if n.b.kind == .Literal {
		r = n.b.value
	} else if sig := eval(ip, n.b, input, env, false, &s); sig != .Go || !s.found {
		return sig
	} else {
		r = s.it.v
	}
	s.found = false
	if n.a.kind == .Literal {
		s.it.v = n.a.value
	} else if sig := eval(ip, n.a, input, env, false, &s); sig != .Go || !s.found {
		return sig
	}
	sig: Signal
	if s.it.v, sig = #force_no_inline binary_op(ip, n.op, s.it.v, r); sig != .Go {
		return sig
	}
	s.it.path = path_from(input, s.it.v) if track else nil
	return out.emit(out, s.it)
}

// Arithmetic and comparison run the right operand outermost, as jq does. `and` and `or` the left, short-circuiting.
eval_binary :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	s := Binary_Sink{ip = ip, n = n, input = input, env = env, track = track, out = out}
	if n.kind == .Binary {
		s.sink.emit = binary_rhs_emit
		return eval(ip, n.b, input, env, false, &s)
	}
	s.sink.emit = logic_lhs_emit
	return eval(ip, n.a, input, env, track, &s)
}

binary_rhs_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Binary_Sink)(s)
	inner := x^
	inner.rhs = it.v
	inner.sink.emit = binary_lhs_emit
	return eval(x.ip, x.n.a, x.input, x.env, false, &inner)
}

binary_lhs_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Binary_Sink)(s)
	v, sig := binary_op(x.ip, x.n.op, it.v, x.rhs)
	if sig != .Go {
		return sig
	}
	return emit_made(x.out, x.input, v, x.track)
}

// jq runs both operands path-tracked, not as subexpressions: the right one reads the input in the path
// state the left one's output left, and the boolean is made in the state of the operand that decided it.
logic_lhs_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Binary_Sink)(s)
	l := truthy(it.v)
	if x.n.kind == .And && !l || x.n.kind == .Or && l {
		return logic_rhs_emit(s, it)
	}
	inner := x^
	inner.sink.emit = logic_rhs_emit
	input := x.input
	if x.track {
		input.path = placed(state_of(it), input.v)
	}
	return eval(x.ip, x.n.b, input, x.env, x.track, &inner)
}

logic_rhs_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Binary_Sink)(s)
	v := truthy(it.v)
	return x.out.emit(x.out, {v = v, path = placed(state_of(it), v) if x.track else nil})
}

// A sink in front of `out` that remembers whether, and with which error, `out` failed or broke, so the
// generator it wraps can tell its own errors (which `try` catches) from those of what consumes its outputs
// (which it passes on). A `?//` in the generator may take a consumer's error as its cue for the next
// alternative, so the one in flight is the consumer's only if it is that error. `//` uses only `found`,
// whether `a` had a truthy output.
Guard_Sink :: struct {
	using sink: Sink,
	out:        ^Sink,
	ip:         ^Interp,
	downstream: bool,
	raised:     int, // `ip.raised` when `out` last failed
	found:      bool,
}

// Whether the error in flight is one the consumer of `g`'s outputs raised.
consumer_failed :: proc(ip: ^Interp, g: ^Guard_Sink) -> bool {
	return g.downstream && ip.raised == g.raised
}

guard_emit :: proc(s: ^Sink, it: Item) -> Signal {
	g := (^Guard_Sink)(s)
	sig := g.out.emit(g.out, it)
	if sig != .Go {
		g.downstream, g.raised = true, g.ip.raised
	}
	return sig
}

alt_emit :: proc(s: ^Sink, it: Item) -> Signal {
	g := (^Guard_Sink)(s)
	if !truthy(it.v) {
		return .Go
	}
	g.found = true
	return g.out.emit(g.out, it)
}

// `a // b`: the truthy outputs of `a`, or if it has none the outputs of `b`. An error in `a` is not
// caught: jq's DEFINEDOR forks with a plain FORK, which passes a raised error on.
eval_alt :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	g := Guard_Sink{sink = {emit = alt_emit}, out = out}
	if sig := eval(ip, n.a, input, env, track, &g); sig != .Go || g.found {
		return sig
	}
	return eval(ip, n.b, input, env, track, out)
}

eval_try :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	g := Guard_Sink{sink = {emit = guard_emit}, out = out, ip = ip}
	sig := eval(ip, n.a, input, env, track, &g)
	if sig != .Fail || consumer_failed(ip, &g) {
		return sig
	}
	if n.b == nil {
		return .Go
	}
	// the handler runs in the path state jq's backtrack restores, the try's.
	return eval(ip, n.b, {v = ip.err, path = path_from(input, ip.err) if track else nil}, env, track, out)
}

// The sink of a node's first part, which goes on with its other parts in the context the node ran in:
// an `if`'s branches, an update's assignment.
Node_Sink :: struct {
	using sink: Sink,
	ip:         ^Interp,
	n:          ^Node,
	input:         Item,
	env:        ^Env,
	track:      bool,
	out:        ^Sink,
}

if_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Node_Sink)(s)
	if truthy(it.v) {
		return eval(x.ip, x.n.b, x.input, x.env, x.track, x.out)
	}
	if x.n.c == nil {
		return x.out.emit(x.out, x.input)
	}
	return eval(x.ip, x.n.c, x.input, x.env, x.track, x.out)
}

Last_Sink :: struct {
	using sink: Sink,
	it:         Item,
	found:      bool,
}

last_emit :: proc(s: ^Sink, it: Item) -> Signal {
	l := (^Last_Sink)(s)
	l.it, l.found = it, true
	return .Go
}
