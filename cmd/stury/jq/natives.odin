package jq

// Natives, generators, and the regular-expression builtins (`Native_Sink`, `path`, `getpath`, `setpath`, `delpaths`,
// `limit`, `skip`, `first`, `last`, `isempty`, `range`, `recurse`, `input`, `inputs`, `debug`, `stderr`,
// `halt_error`, `@comment*`, `test`, `match`, `capture`, `split/2`, `sub`, `gsub`). The builtins themselves are here.
// Compiling a pattern and finding its matches is regex.odin's.

import "core:math"
import "core:mem/virtual"
import "core:strings"
import json "../../../json"

// ---- Natives

Native_Sink :: struct {
	using sink: Sink,
	ip:         ^Interp,
	n:          ^Node,
	env:        ^Env,
	track:      bool,
	out:        ^Sink,
	label:      int,
	count:      int,
	found:      bool,
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
				return emit_value(x.ip, x.out, path_value(p), x.track)
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
kept_by_kind :: #force_inline proc(keep: bit_set[Kind], input: Item, out: ^Sink) -> Signal {
	return out.emit(out, input) if kind(input.v) in keep else .Go
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

// The kind selectors: each keeps the input when its kind is in the set (`kept_by_kind`).
native_values :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	return kept_by_kind(~{.Null}, input, out)
}

native_nulls :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	return kept_by_kind({.Null}, input, out)
}

native_booleans :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	return kept_by_kind({.False, .True}, input, out)
}

native_numbers :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	return kept_by_kind({.Number}, input, out)
}

native_strings :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	return kept_by_kind({.String}, input, out)
}

native_arrays :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	return kept_by_kind({.Array}, input, out)
}

native_objects :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	return kept_by_kind({.Object}, input, out)
}

native_iterables :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	return kept_by_kind({.Array, .Object}, input, out)
}

native_scalars :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	return kept_by_kind(~{.Array, .Object}, input, out)
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

// The next input, read into the arena `out` frees it with, if it has one (`item_arena`).
@(private = "file")
read_input :: proc(ip: ^Interp, out: ^Sink) -> (Value, string, Parse_Status) {
	a := item_arena(ip, out)
	context.allocator = virtual.arena_allocator(a) if a != nil else context.allocator
	return ip.inputs.next(ip.inputs.data)
}

// What reading an input gave: its value emitted, its error raised, and .Go when none is left.
input_signal :: #force_inline proc(ip: ^Interp, v: Value, msg: string, status: Parse_Status, input: Item, track: bool, out: ^Sink) -> Signal {
	switch status {
	case .Value:
		return emit_made(out, input, v, track)
	case .Error:
		return fail(ip, "%s", msg)
	case .More:
	}
	return .Go
}

native_input :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	if ip.inputs.next != nil {
		if v, msg, status := read_input(ip, out); status != .More {
			return input_signal(ip, v, msg, status, input, track, out)
		}
	}
	return fail(ip, "break") // what jq's `input` raises, and `inputs` catches
}

fn_input_position :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	file, line: = "", 0
	if ip.inputs.position != nil {
		file, line = ip.inputs.position(ip.inputs.data)
	}
	if name == "input_line_number" {
		return num(f64(line)), .Go
	}
	return file if file != "" else nil, .Go
}

native_inputs :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	if ip.inputs.next == nil {
		return .Go
	}
	if !track && item_arena(ip, out) == nil {
		if sig, recycled := recycled_inputs(ip, input, out); recycled {
			return sig
		}
	}
	for {
		v, msg, status := read_input(ip, out)
		if sig := input_signal(ip, v, msg, status, input, track, out); sig != .Go || status != .Value {
			return sig
		}
	}
}

// `["DEBUG:", .]`, printed as jq's debug callback prints it: with the output's options, compact.
native_debug :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	msg := new_array(2)
	append(&msg.items, "DEBUG:", input.v)
	write_value(&ip.messages, msg, ip.debug_layout)
	append(&ip.messages, '\n')
	return out.emit(out, input)
}

// A string's own text, anything else as compact JSON.
native_stderr :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	if s, is_str := string_of(input.v); is_str {
		append(&ip.messages, s)
	} else {
		write_value(&ip.messages, input.v, {})
	}
	return out.emit(out, input)
}

gen_halt_error :: proc(ip: ^Interp, input: Item, args: []Value, track: bool, out: ^Sink) -> Signal {
	code, ok := number_of(args[0])
	if !ok {
		return fail(ip, "halt_error/1: number required")
	}
	// jq's main prints a string as it is and null not at all.
	if s, is_str := string_of(input.v); is_str {
		append(&ip.messages, s)
	} else if kind(input.v) != .Null {
		write_value(&ip.messages, input.v, {})
		append(&ip.messages, '\n')
	}
	ip.halted = int(code.f)
	ip.brk = -1
	return .Break
}

// The comments attached to a value of a JSONC document, as stury reads them: `@comment` its `.Lead` ones (and a
// member's value's `.Inline` ones), `@comment_inline` its `.Trail` ones and `@comment_foot` its `.Foot` ones, in
// source order, each one's text without its markers and a space next to each (`// a` and `/* a */` read "a"). Null
// when it has none, as any value the filter made has.
@(private)
fn_comments :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	r, is_ref := v.(Ref)
	if !is_ref || len(r.doc.facts) == 0 {
		return nil, .Go
	}
	texts: ^Array
	for f in facts_of(r) {
		switch {
		case name == "@comment" && f.place != .Lead && f.place != .Inline:
			continue
		case name == "@comment_inline" && f.place != .Trail:
			continue
		case name == "@comment_foot" && f.place != .Foot:
			continue
		}
		text := json.fact_text(r.doc, f)
		text = strings.trim_prefix(text, " ")
		if r.doc.src[f.lo + 1] == '*' {
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

// ---- Regular expressions

@(private = "file")
regex_input :: proc(ip: ^Interp, v: Value) -> (string, Signal) {
	s, ok := string_of(v)
	if !ok {
		return "", fail(ip, "%s (%s) cannot be matched, as it is not a string", type_name(v), brief(v))
	}
	return s, .Go
}

// The regex `re` with `flags` and its matches in `s`: every one or the first as `global` says, else as the
// flags say.
@(private = "file")
regex_run :: proc(ip: ^Interp, re, flags: Value, s: string, global: Maybe(bool)) -> (r: Regex, ms: []Match, sig: Signal) {
	pattern, ok := string_of(re)
	if !ok {
		return {}, nil, fail(ip, "%s (%s) is not a string", type_name(re), brief(re))
	}
	if r, sig = compile_regex(ip, pattern, flags); sig != .Go {
		return
	}
	if g, set := global.?; set {
		r.global = g
	}
	ms, sig = matches(ip, &r, s)
	return
}

// The regex of `args`, the string it runs on and its matches there (regex_run), failing where jq does
// first: a 1-argument call's wrapper on its argument's type (`re` or `[re]` or `[re, flags]`), then
// `_match_impl` on the input, then on the regex.
@(private = "file")
regex_on :: proc(ip: ^Interp, v: Value, args: []Value, global: Maybe(bool) = nil) -> (r: Regex, s: string, ms: []Match, sig: Signal) {
	re, flags := args[0], args[1] if len(args) > 1 else nil
	if len(args) == 1 {
		#partial switch kind(re) {
		case .String:
		case .Array:
			n := length_of(re)
			if n == 0 {
				return {}, "", nil, fail(ip, "array not a string or array")
			}
			re, flags = array_at(re, 0), array_at(re, 1) if n > 1 else nil
		case:
			return {}, "", nil, fail(ip, "%s not a string or array", type_name(re))
		}
	}
	if s, sig = regex_input(ip, v); sig != .Go {
		return
	}
	r, ms, sig = regex_run(ip, re, flags, s, global)
	return
}

fn_test :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	_, _, ms, sig := regex_on(ip, v, args, false)
	return len(ms) > 0, sig
}

gen_match :: proc(ip: ^Interp, input: Item, args: []Value, track: bool, out: ^Sink) -> Signal {
	return each_match(ip, input, args, track, out, false)
}

gen_capture :: proc(ip: ^Interp, input: Item, args: []Value, track: bool, out: ^Sink) -> Signal {
	return each_match(ip, input, args, track, out, true)
}

// Every match as `match` gives it, or under `capture` as its named groups.
@(private = "file")
each_match :: proc(ip: ^Interp, input: Item, args: []Value, track: bool, out: ^Sink, capture: bool) -> Signal {
	r, s, ms, sig := regex_on(ip, input.v, args)
	if sig != .Go {
		return sig
	}
	if track {
		return match_path_error(ip, &r, s, ms)
	}
	walk: Char_Walk
	for m in ms {
		v: Value = capture_object(&r, s, m) if capture else match_object(&r, s, m, &walk)
		if sig = emit_made(out, input, v, track); sig != .Go {
			return sig
		}
	}
	return .Go
}

// jq's `match` is `_match_impl(...) | .[]`: under `path(...)` that `.[]` meets an array no path leads to.
@(private = "file")
match_path_error :: proc(ip: ^Interp, r: ^Regex, s: string, ms: []Match) -> Signal {
	a := new_array(len(ms))
	walk: Char_Walk
	for m in ms {
		append(&a.items, match_object(r, s, m, &walk))
	}
	return fail(ip, "Invalid path expression near attempt to iterate through %s", brief(a))
}

// `split/2` as jq defines it, cutting at its matches' character offsets. jq's `match($re; flags + "g")`
// adds the flags first, so a non-string fails as that addition before the input is validated.
fn_split_regex :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	flags, sig := add(ip, args[1], "g")
	if sig != .Go {
		return nil, sig
	}
	_, s, ms, rsig := regex_on(ip, v, {args[0], flags})
	if sig = rsig; sig != .Go {
		return nil, sig
	}
	a := new_array()
	cuts := Cuts{bytes = on_boundaries(s, ms)}
	for m in ms {
		append(&a.items, cut_before(&cuts, s, m))
	}
	append(&a.items, cut_rest(&cuts, s))
	return a, .Go
}

// `sub` and `gsub` as jq defines them: the replacement's k-th output on each match's captures goes into the k-th
// result, so the results run in lockstep and one past a match's outputs misses that match's text, with no result, the
// input.
native_sub :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	// jq binds `$re` and `$flags` before it reads the input.
	res, sig := collect(ip, n.args[0], input, env)
	if sig != .Go {
		return sig
	}
	flags := []Value{nil}
	if len(n.args) > 2 {
		if flags, sig = collect(ip, n.args[2], input, env); sig != .Go {
			return sig
		}
	}
	s: string
	if s, sig = regex_input(ip, input.v); sig != .Go {
		return sig
	}
	for re in res {
		for fl in flags {
			r, ms, rsig := regex_run(ip, re, fl, s, true if n.name == "gsub" else nil)
			if rsig != .Go {
				return rsig
			}
			if track {
				return match_path_error(ip, &r, s, ms)
			}
			results := make([dynamic]Value)
			owned: Owned // each result grows in place, as no other value holds it
			cuts := Cuts{bytes = on_boundaries(s, ms)}
			for m in ms {
				gap := cut_before(&cuts, s, m)
				inserts: []Value
				if inserts, sig = collect(ip, n.args[1], {v = capture_object(&r, s, m)}, env); sig != .Go {
					return sig
				}
				for ins, k in inserts {
					piece: Value
					if piece, sig = binary_op(ip, .Add, gap, ins); sig != .Go {
						return sig
					}
					if k == len(results) {
						append(&results, nil)
					}
					if results[k], sig = add(ip, results[k], piece, &owned); sig != .Go {
						return sig
					}
				}
			}
			tail := cut_rest(&cuts, s)
			if len(results) == 0 {
				append(&results, "")
				tail = s
			}
			for v in results {
				whole: Value
				if whole, sig = binary_op(ip, .Add, v, tail); sig != .Go {
					return sig
				}
				if sig = emit_made(out, input, whole, track); sig != .Go {
					return sig
				}
			}
		}
	}
	return .Go
}
