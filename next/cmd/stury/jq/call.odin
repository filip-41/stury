package jq

// Calls: jq functions and filter arguments, entered by the evaluator's loop or run here.

// A tail call's locals, the scopes from `env` up to `frame`, given back as the call leaves them, unless
// the body it enters is among them (a function defined there): jq's TAIL_CALL_JQ pops the caller's frame
// alike, when no closure it passes refers to that frame. Nothing else holds a scope: no value does, and
// what the loop ran before this turn has returned.
@(private = "file")
release_locals :: #force_no_inline proc(ip: ^Interp, env: ^Env, frame: ^Env, body: ^Env) {
	for e := env; e != frame; e = e.parent {
		if e == body {
			return
		}
	}
	#force_inline release_scopes(ip, env, frame)
}

eval_call :: #force_no_inline proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	if n.def != nil {
		return call_func(ip, n.def, n, input, env, track, out)
	}
	if b, bound := n.native.?; bound {
		return call_builtin(ip, b, n, input, env, track, out)
	}
	// `enter_body` has searched the scopes for the name already.
	arity := len(n.args)
	if b, has := builtin(n.name, arity); has {
		return call_builtin(ip, b, n, input, env, track, out)
	}
	return fail(ip, "%s/%d is not defined", n.name, arity)
}

// Into the body of a call to a jq function or a filter argument: `n^` and `env^` made that body and the
// scope it runs in, for the evaluator to loop into. Otherwise the call runs here, and its signal is the
// answer: a builtin's call, one whose `$name` argument may have more than one value (`call_func`), and
// one whose `$name` argument has no value or fails.
//
// `frame^` is the loop's: the locals the caller leaves go back (`release_locals`) unless the scope it
// enters closes over them, and the body's scope starts the loop's next frame.
enter_call :: #force_no_inline proc(ip: ^Interp, n: ^^Node, input: Item, env: ^^Env, frame: ^^Env, track: bool, out: ^Sink) -> (Signal, bool) {
	caller := env^
	sig, entered, closes := enter_body(ip, n, input, env, track, out)
	if !entered {
		return sig, false
	}
	if caller != frame^ && !closes {
		release_locals(ip, caller, frame^, env^)
	}
	frame^ = env^
	return .Go, true
}

// The body a call enters and its scope, and whether that scope closes over the caller's (a filter
// argument's closure, or a `$name` argument's, does).
@(private = "file")
enter_body :: #force_inline proc(ip: ^Interp, n: ^^Node, input: Item, env: ^^Env, track: bool, out: ^Sink) -> (sig: Signal, entered: bool, closes: bool) {
	call, caller := n^, env^
	def := call.def
	if def == nil {
		if _, bound := call.native.?; bound {
			return eval_call(ip, call, input, caller, track, out), false, false
		}
		arity := len(call.args)
		find: for e := caller; e != nil; e = e.parent {
			if e.name != call.name || e.arity != arity {
				continue
			}
			#partial switch e.kind {
			case .Closure:
				n^, env^ = e.node, e.scope
				return .Go, true, false
			case .Func:
				def = e
				break find
			}
		}
		if def == nil {
			return eval_call(ip, call, input, caller, track, out), false, false
		}
	}
	params := def.fn.params
	for name, i in params {
		if name[0] == '$' && !call.args[i].single {
			return call_func(ip, def, call, input, caller, track, out), false, false
		}
	}
	scope := def
	for name, i in params {
		arg := call.args[i]
		if name[0] != '$' {
			scope = new_closure(ip, scope, name, arg, caller)
			continue
		}
		v, found, vsig := eval_single(ip, arg, input, caller, false)
		if !found {
			return vsig, false, true
		}
		scope = bind_var(ip, new_closure(ip, scope, name[1:], arg, caller), name[1:], v.v)
	}
	n^, env^ = def.fn.body, scope
	return .Go, true, len(params) > 0
}

Call_Sink :: struct {
	using sink: Sink,
	ip:         ^Interp,
	def:        ^Env,
	call:       ^Node,
	i:          int,
	scope:      ^Env,
	input:         Item,
	env:        ^Env,
	track:      bool,
	out:        ^Sink,
}

// A jq function: each filter parameter a closure over the caller's scope, each `$name` parameter also
// bound to every value of its argument in turn.
call_func :: proc(ip: ^Interp, def: ^Env, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	s := Call_Sink{ip = ip, def = def, call = n, scope = def, input = input, env = env, track = track, out = out}
	return call_param(&s, 0)
}

call_param :: proc(x: ^Call_Sink, i: int) -> Signal {
	params := x.def.fn.params
	if i == len(params) {
		return eval(x.ip, x.def.fn.body, x.input, x.scope, x.track, x.out)
	}
	name := params[i]
	arg := x.call.args[i]
	inner := x^
	inner.i = i
	if name[0] == '$' {
		inner.scope = new_closure(x.ip, x.scope, name[1:], arg, x.env)
		inner.sink.emit = call_value_emit
		return eval(x.ip, arg, x.input, x.env, false, &inner)
	}
	inner.scope = new_closure(x.ip, x.scope, name, arg, x.env)
	return call_param(&inner, i + 1)
}

// A filter argument `arg` bound to `name` on `parent`, run in the caller's scope `caller`.
@(private = "file")
new_closure :: proc(ip: ^Interp, parent: ^Env, name: string, arg: ^Node, caller: ^Env) -> ^Env {
	c := new_env(ip)
	c^ = {parent = parent, kind = .Closure, name = name, node = arg, scope = caller}
	return c
}

call_value_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Call_Sink)(s)
	inner := x^
	inner.scope = bind_var(x.ip, x.scope, x.def.fn.params[x.i][1:], it.v)
	return call_param(&inner, x.i + 1)
}
