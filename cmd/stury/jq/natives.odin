package jq

// Natives and generators (`Native_Sink`, `path`, `getpath`, `setpath`, `delpaths`, `limit`, `skip`, `first`, `last`,
// `isempty`, `range`, `recurse`, `@comment*`). The builtins themselves are here, the ones that read inputs and write
// messages are in io.odin; the regular-expression ones are in regex_natives.odin.

import "core:math"
import "core:strings"
import core_pkg "../../../core"

Native_Sink :: struct {
	using sink: Sink,
	ip:         ^Interp,
	n:          ^Node,
	env:        ^Env,
	track:      bool,
	out:        ^Sink,
	label:      int,
	count:      int,
	downstream: bool, // an output's consumer failed or broke, which a label lets pass
	last:       Item,
}

native_path :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	s := Native_Sink{sink = {emit = proc(s: ^Sink, it: Item) -> Signal {
				x := (^Native_Sink)(s)
				p, sig := path_of(x.ip, it)
				if sig != .Go {
					return sig
				}
				return emit_value(x.ip, x.out, Path(p) if p != nil else path_array(nil), x.track) // its array of keys, not made
			}}, ip = ip, track = track, out = out}
	return eval(ip, n.args[0], {v = input.v}, env, true, &s)
}

gen_getpath :: proc(ip: ^Interp, input: Item, args: []Value, track: bool, out: ^Sink) -> Signal {
	if kind(args[0]) != .Array {
		return fail(ip, "Path must be specified as an array")
	}
	if length_of(args[0]) > MAX_PATH_DEPTH {
		return fail(ip, "Path too deep")
	}
	path := elements(args[0])
	v, sig := getpath(ip, input.v, path)
	if sig != .Go {
		return sig
	}
	if !track {
		return out.emit(out, {v = v})
	}
	if pathless(input.path) {
		// jq's getpath steps along the path only from the value there.
		return out.emit(out, {v = v, path = path_from(input, v)})
	}
	p := input.path
	for k in path {
		p = extend(p, k)
	}
	return out.emit(out, {v = v, path = p})
}

fn_setpath :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	owned: Owned
	return setpath_value(ip, v, args[0], args[1], &owned)
}

fn_delpaths :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	owned: Owned
	return delpaths_value(ip, v, args[0], &owned)
}

// `limit` and `skip`, as jq writes them, for each value of the count in turn: `n.args[1]` run for a count
// above 0 (a label around `limit`'s), nothing for 0, and an error below, as jq's `$n > 0` and `$n == 0`
// order null, booleans and nan below 0. A count that is not a number fails at the first output it
// counts, where jq's `$n - 1` does.
count_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Native_Sink)(s)
	ip, n := x.ip, x.n
	limit := n.name == "limit"
	switch c := compare(it.v, num(0)); {
	case c == 0:
		return .Go if limit else eval(ip, n.args[1], x.last, x.env, x.track, x.out)
	case c < 0:
		return fail(ip, "%s doesn't support negative count", n.name)
	}
	run := Native_Sink{ip = ip, track = x.track, out = x.out, last = it}
	if f, is_num := number_of(it.v); !is_num {
		run.sink.emit = bad_count_emit
	} else if limit {
		run.sink.emit, run.count = limit_emit, int(math.ceil(f.f)) if f.f < 1e15 else max(int)
	} else {
		run.sink.emit, run.count = skip_emit, int(f.f) if f.f < 1e15 else max(int)
	}
	if limit {
		sig, _ := run_labelled(ip, n.args[1], x.last, x.env, x.track, &run)
		return sig
	}
	return eval(ip, n.args[1], x.last, x.env, x.track, &run)
}

bad_count_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Native_Sink)(s)
	_, sig := binary_op(x.ip, .Sub, x.last.v, num(1))
	return sig
}

limit_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Native_Sink)(s)
	if sig := x.out.emit(x.out, it); sig != .Go {
		x.downstream = true
		return sig
	}
	x.count -= 1
	if x.count <= 0 {
		x.ip.brk = x.label
		return .Break
	}
	return .Go
}

skip_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Native_Sink)(s)
	if x.count > 0 {
		x.count -= 1
		return .Go
	}
	return x.out.emit(x.out, it)
}

// `f`'s outputs through `s` in a label of its own, as jq's `label $out | f | ...`: it ends at a break to
// the label, and at the error `{"__jq": label}` raised in `f` (not by what consumes the outputs).
@(private = "file")
run_labelled :: proc(ip: ^Interp, f: ^Node, input: Item, env: ^Env, track: bool, s: ^Native_Sink) -> (sig: Signal, broke: bool) {
	s.label = fresh_label(ip)
	sig = eval(ip, f, input, env, track, s)
	if sig == .Break && ip.brk == s.label || sig == .Fail && !s.downstream && breaks_to(ip.err, s.label) {
		return .Go, true
	}
	return sig, false
}

// `select(f)`: the input, its path kept, once for each truthy output of `f`, as jq's
// `if f then . else empty end` gives it.
native_select :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	s := Native_Sink{sink = {emit = proc(s: ^Sink, it: Item) -> Signal {
				x := (^Native_Sink)(s)
				if !truthy(it.v) {
					return .Go
				}
				return x.out.emit(x.out, x.last)
			}}, out = out, last = input}
	return eval(ip, n.args[0], input, env, false, &s)
}

// `arrays`, `nulls`, `values` and the other selections by type: the input when jq's
// `select(type == ...)` keeps it, as its kind is in `keep`.
@(private)
kept_by_kind :: proc($keep: bit_set[Kind]) -> Native {
	return proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
		return out.emit(out, input) if kind(input.v) in keep else .Go
	}
}

native_empty :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	return .Go
}

native_error :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	ip.err = input.v
	ip.raised += 1
	return .Fail
}

native_halt :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	ip.halted = 0
	ip.brk = -1
	return .Break
}

// `limit` and `skip`: each value of the count, through `count_emit`.
native_count :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	s := Native_Sink{sink = {emit = count_emit}, ip = ip, n = n, env = env, track = track, out = out, last = input}
	return eval(ip, n.args[0], input, env, false, &s)
}

native_first :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	s := Native_Sink{sink = {emit = limit_emit}, ip = ip, track = track, out = out, count = 1}
	sig, _ := run_labelled(ip, n.args[0], input, env, track, &s)
	return sig
}

native_last :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	s := Last_Sink{sink = {emit = last_emit}}
	if sig := eval(ip, n.args[0], input, env, track, &s); sig != .Go {
		return sig
	}
	if !s.found {
		return .Go
	}
	// jq's last(f) keeps the last output in a variable, read in the input's path state.
	return emit_made(out, input, s.it.v, track)
}

// jq's `first((g | false), true)`: false for an output of `g` (again for each a `?//` in `g` retries
// on the break), true when it has none.
native_isempty :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	s := Native_Sink{sink = {emit = isempty_emit}, ip = ip, track = track, out = out, count = 1}
	if sig, broke := run_labelled(ip, n.args[0], input, env, track, &s); sig != .Go || broke {
		return sig
	}
	return emit_made(out, input, true, track)
}

isempty_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Native_Sink)(s)
	return limit_emit(s, {v = false, path = path_from(it, false) if x.track else nil})
}

gen_range :: proc(ip: ^Interp, input: Item, args: []Value, track: bool, out: ^Sink) -> Signal {
	bounds: [3]f64 = {0, 0, 1}
	from := 0 if len(args) > 1 else 1
	for a, i in args {
		n, ok := number_of(a)
		if !ok {
			return fail(ip, "Range bounds must be numeric")
		}
		bounds[from + i] = n.f
	}
	lo, hi, by := bounds[0], bounds[1], bounds[2]
	// The first output is the start itself, as jq's is, and keeps a literal's identity (jv_identical):
	// `range(3) | path(round)` fails on 0 as jq's does.
	v := args[0] if len(args) > 1 else range_start
	for x := lo; (by > 0 && x < hi) || (by < 0 && x > hi); x += by {
		if sig := emit_made(out, input, v, track); sig != .Go {
			return sig
		}
		v = num(x + by)
	}
	return .Go
}

// range/1's start, jq's `range(0; $upto)`: a literal 0 of the program.
@(private = "file", rodata)
range_start: Value = Number{lit = "0"}

// `..`: the input and everything inside it, depth first.
native_recurse :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	// The containers being walked, each with members left. One is dropped as its last member is taken, as
	// jq's `.[]` drops its fork point then, so a chain of lone members takes no room at any depth.
	Level :: struct {
		members: Members,
		array:   bool,
		path:    ^Path_Step,
	}
	levels: [dynamic]Level
	cur := input
	for {
		if sig := out.emit(out, cur); sig != .Go {
			return sig
		}
		if k := kind(cur.v); k == .Array || k == .Object {
			if track && pathless(cur.path) {
				return fail(ip, "Invalid path expression near attempt to iterate through %s", brief(cur.v))
			}
			append(&levels, Level{members = iterate(cur.v), array = k == .Array, path = cur.path})
		}
		for {
			if len(levels) == 0 {
				return .Go
			}
			l := &levels[len(levels) - 1]
			key, m, ok := next_member(&l.members)
			if !ok {
				pop(&levels)
				continue
			}
			cur = {v = m}
			if track {
				cur.path = extend(l.path, num(f64(l.members.i - 1)) if l.array else Value(key))
			}
			if l.members.i >= l.members.n {
				pop(&levels)
			}
			break
		}
	}
}

// `recurse(f)`: the input, then `recurse(f)` on each output of `f`. A loop when `f` is single.
native_recurse_f :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	if f := n.args[0]; f.single {
		it := input
		for {
			if sig := out.emit(out, it); sig != .Go {
				return sig
			}
			next, found, sig := eval_single(ip, f, it, env, track)
			if !found {
				return sig
			}
			it = next
		}
	}
	s := Native_Sink{sink = {emit = recurse_emit}, ip = ip, n = n.args[0], env = env, track = track, out = out}
	return recurse_emit(&s, input)
}

recurse_emit :: proc(s: ^Sink, it: Item) -> Signal {
	x := (^Native_Sink)(s)
	if sig := x.out.emit(x.out, it); sig != .Go {
		return sig
	}
	return eval(x.ip, x.n, it, x.env, x.track, s)
}

// The comments attached to a value of a JSONC document, as stury reads them: `@comment` its `Comment` facts,
// `@comment_inline` its `Comment_Inline` ones and `@comment_foot` its `Comment_Foot` ones, in source order, each
// one's text without its markers and a space next to each (`// a` and `/* a */` read "a"). Null when it has none, as
// any value the filter made has.
@(private)
fn_comments :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	r, is_ref := v.(Ref)
	if !is_ref || len(r.doc.facts) == 0 {
		return nil, .Go
	}
	role := core_pkg.Role.Comment
	switch name {
	case "@comment_inline":
		role = .Comment_Inline
	case "@comment_foot":
		role = .Comment_Foot
	}
	texts: ^Array
	it := core_pkg.facts_of(r.doc, r.node, role)
	for body in core_pkg.fact_next(&it) {
		text := strings.trim_prefix(body, " ")
		// A block comment's body follows its `/*`, a line comment's its `//`.
		if at := uintptr(raw_data(body)) - uintptr(raw_data(r.doc.src)); r.doc.src[at - 1] == '*' {
			text = strings.trim_suffix(text, " ")
		}
		if texts == nil {
			texts = new_array()
		}
		append(&texts.items, text)
	}
	if texts == nil {
		return nil, .Go
	}
	return texts, .Go
}
